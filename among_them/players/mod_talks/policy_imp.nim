## Imposter decision tree.
##
## Phase 1 port from v2:2760-2803 (fake-target helpers), v2:3550-3667
## (followee + fake-task die), v2:3669-3920 (`decideImposterMask`).
##
## Priority order (matches v2 / evidencebot strategy doc §5):
##   1. Body in view → self-report (if recent kill) or flee.
##   2. Lone non-teammate visible + kill ready + in range → kill.
##   3. Lone non-teammate visible + kill ready + out of range → hunt.
##   4. Active fake-task timer → continue holding fake task.
##   4.5. Forced central-room exit (v2 stuck mitigation).
##   5. Followee visible → maybe-start fake task or continue tailing.
##   6. Wander toward a random fake target.
##
## Q6 RNG: every randomized choice pulls from a dedicated substream in
## `bot.rngs` — `imposterTask` for fake-task die rolls / durations /
## random target picks, `imposterFollow` for followee swap selection.

import std/random

import protocol
import ../../sim

import types
import geometry
import path
import diag
import chat
import evidence
import tasks

const
  # Imposter follow-and-fake-task tuning.
  ImposterFollowSwapMinTicks* = 240
    ## Min ticks we hold a followee before swapping when 2+ visible.
  ImposterFollowApproachRadius* = 6
    ## Precise-approach radius for follow navigation.
  ImposterFakeTaskNearRadius* = 80
    ## World-px radius around a task center inside which we may roll
    ## the fake-task die (only on entering, not every frame inside).
  ImposterFakeTaskMinTicks* = 90
  ImposterFakeTaskMaxTicks* = 180
  ImposterFakeTaskCooldownTicks* = 240
  ImposterFakeTaskChance* = 1
  ImposterFakeTaskChanceDenom* = 12

  # Self-report tuning.
  ImposterSelfReportRecentTicks* = 30
    ## Window after a kill A-press during which a new body within
    ## `ImposterSelfReportRadius` of the victim's last position is
    ## treated as "ours" for self-report purposes.
  ImposterSelfReportRadius* = KillRange + 8

  # Vent escape tuning.
  ImposterVentCooldownTicks* = 60
    ## Bot-side ticks to wait before attempting to vent again after a
    ## successful vent press. The server enforces its own 30-tick
    ## ventCooldown; this more conservative gate prevents spamming
    ## ButtonB on every frame while standing on the destination vent.

  # Central-room stuck mitigation.
  ImposterCentralRoomStuckTicks* = 360
    ## Ticks of "in central room with crowd" before forcing a leave.
  ImposterCentralRoomLeaveTicks* = 240
    ## Forced-leave window length once triggered.
  ImposterCentralRoomMinCrewmates* = 2
    ## Visible non-teammate count that counts as "crowd".

# ---------------------------------------------------------------------------
# Fake-target helpers
# ---------------------------------------------------------------------------

proc fakeTargetCount*(bot: Bot): int =
  ## Tasks count + 1 for the emergency button.
  bot.sim.tasks.len + 1

proc fakeTargetGoalFor*(bot: Bot, index: int): TaskGoal =
  ## Returns an imposter fake goal for a task index or the button.
  if index == bot.sim.tasks.len:
    return bot.buttonGoal()
  bot.taskGoalFor(index, TaskMaybe)

proc randomFakeTargetIndex*(bot: var Bot): int =
  ## Pulls from `bot.rngs.imposterTask`.
  let count = bot.fakeTargetCount()
  if count == 0:
    return -1
  bot.rngs.imposterTask.rand(count - 1)

proc fakeTargetCenter*(bot: Bot, index: int): tuple[x: int, y: int] =
  if index == bot.sim.tasks.len:
    let button = bot.sim.gameMap.button
    return (button.x + button.w div 2, button.y + button.h div 2)
  bot.sim.tasks[index].taskCenter()

proc farthestFakeTargetIndexFrom*(bot: Bot, originX, originY: int): int =
  var bestDistance = low(int)
  result = -1
  for i in 0 ..< bot.fakeTargetCount():
    let center = bot.fakeTargetCenter(i)
    let distance = heuristic(originX, originY, center.x, center.y)
    if distance > bestDistance:
      bestDistance = distance
      result = i

proc farthestFakeTargetIndex*(bot: Bot): int =
  bot.farthestFakeTargetIndexFrom(bot.percep.playerWorldX(),
                                  bot.percep.playerWorldY())

# ---------------------------------------------------------------------------
# Vent helpers
# ---------------------------------------------------------------------------

proc ventCenter*(bot: Bot, index: int): tuple[x: int, y: int] =
  ## World coordinate center of the vent at `index`.
  let v = bot.sim.vents[index]
  (v.x + v.w div 2, v.y + v.h div 2)

proc inVentRange*(bot: Bot, ventX, ventY: int): bool =
  ## True when the player's collision center is within the server's
  ## `VentRange` of (ventX, ventY). Mirrors the range check in
  ## `sim.tryVent` so the bot only presses B when the server will
  ## actually honour the request.
  let
    px = bot.percep.playerWorldX() + CollisionW div 2
    py = bot.percep.playerWorldY() + CollisionH div 2
    dx = px - ventX
    dy = py - ventY
  dx * dx + dy * dy <= VentRange * VentRange

proc nearestVentIndex*(bot: Bot): int =
  ## Returns the index of the nearest vent (Manhattan distance from the
  ## player's collision centre), or -1 when the map has no vents.
  result = -1
  if bot.sim.vents.len == 0:
    return
  var bestDist = high(int)
  let
    px = bot.percep.playerWorldX() + CollisionW div 2
    py = bot.percep.playerWorldY() + CollisionH div 2
  for i, v in bot.sim.vents:
    let
      vx = v.x + v.w div 2
      vy = v.y + v.h div 2
      d = abs(px - vx) + abs(py - vy)
    if d < bestDist:
      bestDist = d
      result = i

# ---------------------------------------------------------------------------
# Visible-crewmate helpers
# ---------------------------------------------------------------------------

proc visibleNonTeammateCrewmates*(bot: Bot): seq[CrewmateMatch] =
  ## Returns visible crewmates that aren't self or known imposter
  ## teammates.
  result = @[]
  for crewmate in bot.percep.visibleCrewmates:
    let ci = crewmate.colorIndex
    if ci < 0:
      continue
    if ci == bot.identity.selfColor:
      continue
    if bot.knownImposterColor(ci):
      continue
    result.add(crewmate)

proc noCrewmatesWatching*(bot: Bot): bool =
  ## True when no non-teammate crewmate is visible on screen. The
  ## visible crewmate list is exactly "players whose sprites appear in
  ## our camera view", which is the closest the bot has to a line-of-
  ## sight predicate. Used as the safety gate before venting: the
  ## imposter only vents when no one on screen can witness it.
  bot.visibleNonTeammateCrewmates().len == 0

proc findVisibleByColor*(bot: Bot,
                        colorIndex: int): tuple[found: bool,
                                                crewmate: CrewmateMatch] =
  for crewmate in bot.percep.visibleCrewmates:
    if crewmate.colorIndex == colorIndex:
      return (true, crewmate)
  (false, CrewmateMatch())

proc pickFolloweeColor*(bot: var Bot): int =
  ## Picks the colour the imposter should follow this frame. Sticks
  ## with the current followee until `ImposterFollowSwapMinTicks`
  ## elapses; then with 2+ visible, may randomly swap. RNG pulls from
  ## `bot.rngs.imposterFollow`.
  let visible = bot.visibleNonTeammateCrewmates()
  if visible.len == 0:
    return bot.imposter.followeeColor

  let currentVisible =
    bot.imposter.followeeColor >= 0 and
    bot.findVisibleByColor(bot.imposter.followeeColor).found

  let canSwap =
    visible.len >= 2 and
    currentVisible and
    bot.frameTick - bot.imposter.followeeSinceTick >=
      ImposterFollowSwapMinTicks

  if canSwap:
    var alternatives: seq[CrewmateMatch] = @[]
    for cm in visible:
      if cm.colorIndex != bot.imposter.followeeColor:
        alternatives.add(cm)
    if alternatives.len > 0:
      let pick = alternatives[bot.rngs.imposterFollow.rand(
        alternatives.len - 1)]
      bot.imposter.followeeColor = pick.colorIndex
      bot.imposter.followeeSinceTick = bot.frameTick
      return bot.imposter.followeeColor

  if currentVisible:
    return bot.imposter.followeeColor

  # Followee not visible (or none yet): pick any visible.
  let pick = visible[bot.rngs.imposterFollow.rand(visible.len - 1)]
  bot.imposter.followeeColor = pick.colorIndex
  bot.imposter.followeeSinceTick = bot.frameTick
  bot.imposter.followeeColor

# ---------------------------------------------------------------------------
# Fake-task die roll
# ---------------------------------------------------------------------------

proc nearestTaskIndexWithinRadius*(bot: Bot,
                                  radius: int): tuple[found: bool, index: int,
                                                      x, y: int] =
  ## Returns the closest task whose centre is within `radius` world-px.
  ## Used to gate the fake-task roll: only consider passing-by tasks.
  result = (false, -1, 0, 0)
  let
    px = bot.percep.playerWorldX()
    py = bot.percep.playerWorldY()
    r2 = radius * radius
  var bestDist = high(int)
  for i, task in bot.sim.tasks:
    let center = task.taskCenter()
    let
      dx = center.x - px
      dy = center.y - py
      d2 = dx * dx + dy * dy
    if d2 <= r2 and d2 < bestDist:
      bestDist = d2
      result = (true, i, center.x, center.y)

proc maybeStartFakeTask*(bot: var Bot) =
  ## Rolls the fake-task die if eligible. Pulls from
  ## `bot.rngs.imposterTask`. Only rolls on the *transition into* a
  ## task radius — once inside, doesn't re-roll every frame.
  if bot.frameTick < bot.imposter.fakeTaskCooldownTick:
    return
  if bot.imposter.fakeTaskUntilTick > bot.frameTick:
    return
  let near = bot.nearestTaskIndexWithinRadius(ImposterFakeTaskNearRadius)
  if not near.found:
    bot.imposter.prevNearTaskIndex = -1
    return
  if near.index == bot.imposter.prevNearTaskIndex:
    return
  bot.imposter.prevNearTaskIndex = near.index
  if bot.rngs.imposterTask.rand(ImposterFakeTaskChanceDenom - 1) >=
      ImposterFakeTaskChance:
    return
  let span = ImposterFakeTaskMaxTicks - ImposterFakeTaskMinTicks
  let dur = ImposterFakeTaskMinTicks + bot.rngs.imposterTask.rand(span)
  bot.imposter.fakeTaskIndex = near.index
  bot.imposter.fakeTaskUntilTick = bot.frameTick + dur

# ---------------------------------------------------------------------------
# Imposter per-frame mask
# ---------------------------------------------------------------------------

proc decideImposterMask*(bot: var Bot): uint8 =
  ## Imposter path through the per-frame pipeline. Verbatim port of
  ## v2:3669-3920 modulo sub-record renames.
  bot.percep.radarDots.setLen(0)
  if bot.tasks.radar.len != bot.sim.tasks.len:
    bot.tasks.radar = newSeq[bool](bot.sim.tasks.len)
  if bot.tasks.checkout.len != bot.sim.tasks.len:
    bot.tasks.checkout = newSeq[bool](bot.sim.tasks.len)
  for i in 0 ..< bot.tasks.radar.len:
    bot.tasks.radar[i] = false
  for i in 0 ..< bot.tasks.checkout.len:
    bot.tasks.checkout[i] = false
  bot.tasks.holdTicks = 0
  bot.tasks.holdIndex = -1

  # Central-room stuck tracking.
  let visibleCount = bot.visibleNonTeammateCrewmates().len
  if bot.frameTick < bot.imposter.forceLeaveUntilTick:
    bot.imposter.centralRoomTicks = 0
  elif bot.percep.inCentralRoom(bot.sim) and
      visibleCount >= ImposterCentralRoomMinCrewmates:
    inc bot.imposter.centralRoomTicks
    if bot.imposter.centralRoomTicks >= ImposterCentralRoomStuckTicks:
      bot.imposter.forceLeaveUntilTick =
        bot.frameTick + ImposterCentralRoomLeaveTicks
      bot.imposter.centralRoomTicks = 0
      # Cancel any active fake task — forced-leave should leave.
      bot.imposter.fakeTaskUntilTick = 0
      bot.imposter.fakeTaskIndex = -1
  else:
    bot.imposter.centralRoomTicks = 0

  # 1. React to a visible body.
  let body = bot.nearestBody()
  if body.found:
    bot.queueBodySeen(body.x, body.y)

    # Sub-case (a): self-report if this is our recent kill.
    let recentKill =
      bot.imposter.lastKillTick > 0 and
      bot.frameTick - bot.imposter.lastKillTick <= ImposterSelfReportRecentTicks
    if recentKill:
      let
        dx = body.x - bot.imposter.lastKillX
        dy = body.y - bot.imposter.lastKillY
        matchR2 = ImposterSelfReportRadius * ImposterSelfReportRadius
      if dx * dx + dy * dy <= matchR2 and
          bot.inReportRange(body.x, body.y) and
          abs(bot.motion.velocityX) + abs(bot.motion.velocityY) <= 1:
        bot.imposter.lastKillTick = 0
        bot.imposter.fakeTaskUntilTick = 0
        bot.imposter.fakeTaskIndex = -1
        bot.imposter.fakeTaskCooldownTick =
          bot.frameTick + ImposterFakeTaskCooldownTicks
        bot.fired("policy_imp.body.self_report")
        bot.thought("self-reporting kill body")
        return bot.reportBodyAction(body.x, body.y)

    # Sub-case (b): unobserved body → vent escape. No non-teammate
    # crewmate is visible on screen, so no one can witness the teleport.
    # Navigate to the nearest vent; press B when in range.
    if bot.noCrewmatesWatching() and
        bot.sim.vents.len > 0 and
        bot.frameTick >= bot.imposter.ventCooldownTick:
      # Reuse the cached vent target when still valid; otherwise pick the
      # nearest vent fresh. Caching avoids oscillating between two equidistant
      # vents across consecutive frames.
      if bot.imposter.ventTargetIndex < 0 or
          bot.imposter.ventTargetIndex >= bot.sim.vents.len:
        bot.imposter.ventTargetIndex = bot.nearestVentIndex()
      let ventIdx = bot.imposter.ventTargetIndex
      if ventIdx >= 0:
        let vc = bot.ventCenter(ventIdx)
        if bot.inVentRange(vc.x, vc.y):
          # In range — press B to vent. Clear the target and set a cooldown
          # so we don't spam ButtonB on the destination vent next frame.
          bot.imposter.ventTargetIndex = -1
          bot.imposter.ventCooldownTick =
            bot.frameTick + ImposterVentCooldownTicks
          bot.imposter.fakeTaskUntilTick = 0
          bot.imposter.fakeTaskIndex = -1
          bot.fired("policy_imp.body.vent_escape",
            "vent escape from body at " &
            $body.x & "," & $body.y)
          bot.thought("body visible, unobserved — pressing B to vent")
          return ButtonB
        # Not yet in range — navigate toward the vent.
        bot.fired("policy_imp.body.vent_approach",
          "approach vent " & $ventIdx & " to escape body")
        bot.thought("approaching vent to escape body")
        return bot.navigateToPoint(vc.x, vc.y,
          "vent " & $ventIdx & " escape")

    # Sub-case (c): body visible with witnesses (or no vents) → flee on
    # foot to the farthest fake target. Clear any stale vent target so the
    # next unobserved opportunity starts fresh.
    bot.imposter.ventTargetIndex = -1
    bot.imposter.goalIndex = bot.farthestFakeTargetIndexFrom(body.x, body.y)
    let fleeGoal = bot.fakeTargetGoalFor(bot.imposter.goalIndex)
    if fleeGoal.found:
      bot.goal.index = fleeGoal.index
      bot.imposter.fakeTaskUntilTick = 0
      bot.imposter.fakeTaskIndex = -1
      bot.fired("policy_imp.body.flee")
      return bot.navigateToPoint(
        fleeGoal.x,
        fleeGoal.y,
        "flee body to " & fleeGoal.name
      )

  # 2/3. Hunt or kill a lone crewmate.
  let loneCrewmate = bot.loneVisibleCrewmate()
  if loneCrewmate.found and bot.imposter.killReady:
    let target = bot.percep.visibleCrewmateWorld(loneCrewmate.crewmate)
    if bot.inKillRange(target.x, target.y):
      bot.imposter.goalIndex = bot.farthestFakeTargetIndex()
      bot.fired("policy_imp.kill.in_range", "kill lone crewmate")
      bot.motion.desiredMask = ButtonA
      bot.motion.controllerMask = ButtonA
      bot.goal.hasPathStep = false
      bot.goal.path.setLen(0)
      bot.imposter.fakeTaskUntilTick = 0
      bot.imposter.fakeTaskIndex = -1
      bot.imposter.fakeTaskCooldownTick =
        bot.frameTick + ImposterFakeTaskCooldownTicks
      bot.imposter.lastKillTick = bot.frameTick
      bot.imposter.lastKillX = target.x
      bot.imposter.lastKillY = target.y
      bot.thought("lone crewmate in range, attacking")
      return ButtonA
    bot.goal.index = -2
    bot.imposter.fakeTaskUntilTick = 0
    bot.imposter.fakeTaskIndex = -1
    bot.fired("policy_imp.kill.hunt")
    return bot.navigateToPoint(
      target.x,
      target.y,
      "lone crewmate",
      KillApproachRadius
    )

  # 4. Continue an active fake-task action.
  if bot.imposter.fakeTaskUntilTick > bot.frameTick and
      bot.imposter.fakeTaskIndex >= 0 and
      bot.imposter.fakeTaskIndex < bot.sim.tasks.len:
    let task = bot.sim.tasks[bot.imposter.fakeTaskIndex]
    let center = task.taskCenter()
    let dist = heuristic(
      bot.percep.playerWorldX(),
      bot.percep.playerWorldY(),
      center.x,
      center.y
    )
    if dist <= TaskPreciseApproachRadius:
      bot.fired("policy_imp.fake_task.holding",
        "fake task at " & $bot.imposter.fakeTaskIndex)
      bot.motion.desiredMask = ButtonA
      bot.motion.controllerMask = ButtonA
      bot.goal.hasPathStep = false
      bot.goal.path.setLen(0)
      bot.thought("fake-tasking, holding action")
      return ButtonA
    bot.fired("policy_imp.fake_task.setup")
    return bot.navigateToPoint(
      center.x,
      center.y,
      "fake task setup",
      TaskPreciseApproachRadius
    )

  # 4.5. Forced central-room exit.
  if bot.frameTick < bot.imposter.forceLeaveUntilTick:
    let central = bot.sim.centralRoomCenter()
    bot.imposter.goalIndex = bot.farthestFakeTargetIndexFrom(
      central.x, central.y
    )
    let goal = bot.fakeTargetGoalFor(bot.imposter.goalIndex)
    if goal.found:
      bot.goal.index = goal.index
      bot.fired("policy_imp.central_room.force_leave")
      return bot.navigateToPoint(
        goal.x,
        goal.y,
        "leave central to " & goal.name
      )

  # 5. Follow a visible crewmate.
  let followee = bot.pickFolloweeColor()
  if followee >= 0:
    let visMatch = bot.findVisibleByColor(followee)
    if visMatch.found:
      bot.maybeStartFakeTask()
      if bot.imposter.fakeTaskUntilTick > bot.frameTick and
          bot.imposter.fakeTaskIndex >= 0 and
          bot.imposter.fakeTaskIndex < bot.sim.tasks.len:
        let task = bot.sim.tasks[bot.imposter.fakeTaskIndex]
        let center = task.taskCenter()
        bot.fired("policy_imp.fake_task.setup_in_tail")
        return bot.navigateToPoint(
          center.x,
          center.y,
          "fake task setup",
          TaskPreciseApproachRadius
        )
      let target = bot.percep.visibleCrewmateWorld(visMatch.crewmate)
      bot.goal.index = -3
      bot.fired("policy_imp.follow.tail")
      return bot.navigateToPoint(
        target.x,
        target.y,
        "follow " & playerColorName(followee),
        ImposterFollowApproachRadius
      )

  # 6. Wander.
  bot.maybeStartFakeTask()
  if bot.imposter.fakeTaskUntilTick > bot.frameTick and
      bot.imposter.fakeTaskIndex >= 0 and
      bot.imposter.fakeTaskIndex < bot.sim.tasks.len:
    let task = bot.sim.tasks[bot.imposter.fakeTaskIndex]
    let center = task.taskCenter()
    bot.fired("policy_imp.fake_task.setup_in_wander")
    return bot.navigateToPoint(
      center.x,
      center.y,
      "fake task setup",
      TaskPreciseApproachRadius
    )

  if bot.imposter.goalIndex < 0 or
      bot.imposter.goalIndex >= bot.fakeTargetCount():
    bot.imposter.goalIndex = bot.randomFakeTargetIndex()
  var goal = bot.fakeTargetGoalFor(bot.imposter.goalIndex)
  if not goal.found:
    bot.imposter.goalIndex = bot.randomFakeTargetIndex()
    goal = bot.fakeTargetGoalFor(bot.imposter.goalIndex)
  if not goal.found:
    bot.fired("policy_imp.wander.idle_unreachable",
      "imposter idle, unreachable fake target")
    bot.thought("imposter idle, unreachable fake target")
    return 0
  if heuristic(bot.percep.playerWorldX(), bot.percep.playerWorldY(),
               goal.x, goal.y) <= TaskPreciseApproachRadius:
    bot.imposter.goalIndex = bot.randomFakeTargetIndex()
    goal = bot.fakeTargetGoalFor(bot.imposter.goalIndex)
    if not goal.found:
      bot.fired("policy_imp.wander.idle_no_target",
        "imposter idle, no next fake target")
      bot.thought("imposter idle, no next fake target")
      return 0
  bot.goal.index = goal.index
  bot.fired("policy_imp.wander.next_target")
  bot.navigateToPoint(goal.x, goal.y, "fake target " & goal.name)

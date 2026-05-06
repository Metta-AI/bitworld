proc visibleNonTeammateCrewmates(
  bot: Bot
): seq[CrewmateMatch] =
  ## Returns visible crewmates that aren't self or known imposter teammates.
  result = @[]
  for crewmate in bot.visibleCrewmates:
    let ci = crewmate.colorIndex
    if ci < 0:
      continue
    if ci == bot.selfColorIndex:
      continue
    if bot.knownImposterColor(ci):
      continue
    result.add(crewmate)

proc findVisibleByColor(
  bot: Bot,
  colorIndex: int
): tuple[found: bool, crewmate: CrewmateMatch] =
  ## Returns the visible crewmate match for one color, if present.
  for crewmate in bot.visibleCrewmates:
    if crewmate.colorIndex == colorIndex:
      return (true, crewmate)
  (false, CrewmateMatch())

proc pickFolloweeColor(bot: var Bot): int =
  ## Picks the color the imposter should follow this frame.
  ##
  ## Behavior:
  ##   - If our current followee is still visible AND we've been following
  ##     them for less than ImposterFollowSwapMinTicks: stick with them.
  ##   - If multiple non-teammate crewmates are visible AND the swap window
  ##     has elapsed: pick a random different visible crewmate. This makes
  ##     the imposter naturally rotate its gaze in groups instead of glueing
  ##     itself to one player (which is the dead giveaway).
  ##   - If our followee left view: pick any currently visible crewmate.
  ##   - If nobody visible: keep the current followee color so we can
  ##     resume if they reappear; the caller falls back to wandering.
  let visible = bot.visibleNonTeammateCrewmates()
  if visible.len == 0:
    return bot.imposterFolloweeColor

  let currentVisible =
    bot.imposterFolloweeColor >= 0 and
    bot.findVisibleByColor(bot.imposterFolloweeColor).found

  let canSwap =
    visible.len >= 2 and
    currentVisible and
    bot.frameTick - bot.imposterFolloweeSinceTick >=
      ImposterFollowSwapMinTicks

  if canSwap:
    var alternatives: seq[CrewmateMatch] = @[]
    for cm in visible:
      if cm.colorIndex != bot.imposterFolloweeColor:
        alternatives.add(cm)
    if alternatives.len > 0:
      let pick = alternatives[bot.rng.rand(alternatives.len - 1)]
      bot.imposterFolloweeColor = pick.colorIndex
      bot.imposterFolloweeSinceTick = bot.frameTick
      return bot.imposterFolloweeColor

  if currentVisible:
    return bot.imposterFolloweeColor

  # Followee not visible (or none yet): pick any visible.
  let pick = visible[bot.rng.rand(visible.len - 1)]
  bot.imposterFolloweeColor = pick.colorIndex
  bot.imposterFolloweeSinceTick = bot.frameTick
  bot.imposterFolloweeColor

proc nearestTaskIndexWithinRadius(
  bot: Bot,
  radius: int
): tuple[found: bool, index: int, x: int, y: int] =
  ## Returns the closest sim task whose center is within `radius` world px.
  ##
  ## Used to gate the fake-task roll: the imposter only considers
  ## fake-tasking when it's actually passing by a task station.
  result = (false, -1, 0, 0)
  let
    px = bot.playerWorldX()
    py = bot.playerWorldY()
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

proc maybeStartFakeTask(bot: var Bot) =
  ## Rolls the fake-task die if eligible; sets imposterFakeTask{Index,UntilTick}
  ## on success. Only rolls on the tick we *enter* a task's radius so the
  ## imposter doesn't re-roll every frame it lingers near the same station.
  if bot.frameTick < bot.imposterFakeTaskCooldownTick:
    return
  if bot.imposterFakeTaskUntilTick > bot.frameTick:
    return
  let near = bot.nearestTaskIndexWithinRadius(ImposterFakeTaskNearRadius)
  if not near.found:
    bot.imposterPrevNearTaskIndex = -1
    return
  # Only roll on transition into a (new) task radius.
  if near.index == bot.imposterPrevNearTaskIndex:
    return
  bot.imposterPrevNearTaskIndex = near.index
  if bot.rng.rand(ImposterFakeTaskChanceDenom - 1) >= ImposterFakeTaskChance:
    return
  let span = ImposterFakeTaskMaxTicks - ImposterFakeTaskMinTicks
  let dur = ImposterFakeTaskMinTicks + bot.rng.rand(span)
  bot.imposterFakeTaskIndex = near.index
  bot.imposterFakeTaskUntilTick = bot.frameTick + dur

proc decideImposterMask(bot: var Bot): uint8 =
  ## Chooses imposter movement and kill behavior.
  ##
  ## Priority order, evaluated each frame:
  ##   1. Body in view → flee (and queue a deflection chat).
  ##   2. Lone non-teammate crewmate in kill range AND kill ready → KILL.
  ##   3. Lone non-teammate crewmate visible AND kill ready → close in for
  ##      the kill (existing hunt behaviour).
  ##   4. Active fake-task timer → navigate to / stand on the task,
  ##      pressing A so we look like a crewmate doing it.
  ##   5. Any non-teammate crewmate visible → follow one (swapping
  ##      between targets in groups), with a chance to interrupt for a
  ##      fake task when passing a task station.
  ##   6. Nobody visible → wander to a random fake target, with the same
  ##      chance to interrupt for a fake task.
  bot.radarDots.setLen(0)
  if bot.radarTasks.len != bot.sim.tasks.len:
    bot.radarTasks = newSeq[bool](bot.sim.tasks.len)
  if bot.checkoutTasks.len != bot.sim.tasks.len:
    bot.checkoutTasks = newSeq[bool](bot.sim.tasks.len)
  for i in 0 ..< bot.radarTasks.len:
    bot.radarTasks[i] = false
  for i in 0 ..< bot.checkoutTasks.len:
    bot.checkoutTasks[i] = false
  bot.taskHoldTicks = 0
  bot.taskHoldIndex = -1

  # 1. React to a visible body. Two sub-cases:
  #    a) The body is one we just made → SELF-REPORT (press A). The meeting
  #       opens, our queued random-innocent chat fires first, and we look
  #       like the helpful finder. Best-case imposter play.
  #    b) Otherwise → flee normally and queue chat.
  let body = bot.nearestBody()
  if body.found:
    # queueBodySeen dedupes via sameBody, so this only builds the message
    # once per distinct body — but having pendingChat set before voting
    # opens means we're first to chat when the meeting starts. Other
    # nottoodumb-style bots read chat with chatSusColorIndex and tier-1
    # bandwagon onto whoever's named first, so being first is the entire
    # game.
    bot.queueBodySeen(body.x, body.y)

    # Sub-case (a): is this the body we just made?
    let recentKill =
      bot.imposterLastKillTick > 0 and
      bot.frameTick - bot.imposterLastKillTick <= ImposterSelfReportRecentTicks
    if recentKill:
      let
        dx = body.x - bot.imposterLastKillX
        dy = body.y - bot.imposterLastKillY
        matchR2 = ImposterSelfReportRadius * ImposterSelfReportRadius
      if dx * dx + dy * dy <= matchR2 and
          bot.inReportRange(body.x, body.y) and
          abs(bot.velocityX) + abs(bot.velocityY) <= 1:
        # One-shot: clear so we don't re-trigger if the meeting somehow
        # doesn't open on this press.
        bot.imposterLastKillTick = 0
        bot.imposterFakeTaskUntilTick = 0
        bot.imposterFakeTaskIndex = -1
        # After self-reporting we're the "alarm" — keep a fake-task
        # cooldown so the immediate next round we don't pivot to a task
        # the moment voting ends, which is its own tell.
        bot.imposterFakeTaskCooldownTick =
          bot.frameTick + ImposterFakeTaskCooldownTicks
        bot.thought("self-reporting kill body")
        return bot.reportBodyAction(body.x, body.y)

    # Sub-case (b): not our kill (or out of report range / moving) → flee.
    bot.imposterGoalIndex = bot.farthestFakeTargetIndexFrom(body.x, body.y)
    let fleeGoal = bot.fakeTargetGoalFor(bot.imposterGoalIndex)
    if fleeGoal.found:
      bot.goalIndex = fleeGoal.index
      # Body sighting cancels any in-progress fake task; getting away
      # from the body is more urgent than maintaining the alibi.
      bot.imposterFakeTaskUntilTick = 0
      bot.imposterFakeTaskIndex = -1
      return bot.navigateToPoint(
        fleeGoal.x,
        fleeGoal.y,
        "flee body to " & fleeGoal.name
      )

  # 2/3. Hunt or kill a lone crewmate. This trumps fake-task and follow.
  let loneCrewmate = bot.loneVisibleCrewmate()
  if loneCrewmate.found and bot.imposterKillReady:
    let target = bot.visibleCrewmateWorld(loneCrewmate.crewmate)
    if bot.inKillRange(target.x, target.y):
      bot.imposterGoalIndex = bot.farthestFakeTargetIndex()
      bot.intent = "kill lone crewmate"
      bot.desiredMask = ButtonA
      bot.controllerMask = ButtonA
      bot.hasPathStep = false
      bot.path.setLen(0)
      # Killing immediately starts a fake-task cooldown so we don't pivot
      # into "do a task" right after a kill — that pattern is suspicious.
      bot.imposterFakeTaskUntilTick = 0
      bot.imposterFakeTaskIndex = -1
      bot.imposterFakeTaskCooldownTick =
        bot.frameTick + ImposterFakeTaskCooldownTicks
      # Record the kill so next frame's body-visible branch self-reports
      # instead of fleeing. The body draws at the victim's last position.
      bot.imposterLastKillTick = bot.frameTick
      bot.imposterLastKillX = target.x
      bot.imposterLastKillY = target.y
      bot.thought("lone crewmate in range, attacking")
      return ButtonA
    bot.goalIndex = -2
    # Hunting overrides any active fake task.
    bot.imposterFakeTaskUntilTick = 0
    bot.imposterFakeTaskIndex = -1
    return bot.navigateToPoint(
      target.x,
      target.y,
      "lone crewmate",
      KillApproachRadius
    )

  # 4. Continue an active fake-task action.
  if bot.imposterFakeTaskUntilTick > bot.frameTick and
      bot.imposterFakeTaskIndex >= 0 and
      bot.imposterFakeTaskIndex < bot.sim.tasks.len:
    let task = bot.sim.tasks[bot.imposterFakeTaskIndex]
    let center = task.taskCenter()
    let dist = heuristic(
      bot.playerWorldX(),
      bot.playerWorldY(),
      center.x,
      center.y
    )
    if dist <= TaskPreciseApproachRadius:
      # In range — stand still and hold A so we look like we're doing
      # the task. The sim ignores task input from imposters but visually
      # other crewmates can't tell.
      bot.intent = "fake task at " & $bot.imposterFakeTaskIndex
      bot.desiredMask = ButtonA
      bot.controllerMask = ButtonA
      bot.hasPathStep = false
      bot.path.setLen(0)
      bot.thought("fake-tasking, holding action")
      return ButtonA
    return bot.navigateToPoint(
      center.x,
      center.y,
      "fake task setup",
      TaskPreciseApproachRadius
    )

  # 5. Follow a visible crewmate, swapping between targets in groups.
  let followee = bot.pickFolloweeColor()
  if followee >= 0:
    let visMatch = bot.findVisibleByColor(followee)
    if visMatch.found:
      # Roll for a fake-task interruption while passing through a task.
      bot.maybeStartFakeTask()
      if bot.imposterFakeTaskUntilTick > bot.frameTick and
          bot.imposterFakeTaskIndex >= 0 and
          bot.imposterFakeTaskIndex < bot.sim.tasks.len:
        let task = bot.sim.tasks[bot.imposterFakeTaskIndex]
        let center = task.taskCenter()
        return bot.navigateToPoint(
          center.x,
          center.y,
          "fake task setup",
          TaskPreciseApproachRadius
        )
      let target = bot.visibleCrewmateWorld(visMatch.crewmate)
      bot.goalIndex = -3
      return bot.navigateToPoint(
        target.x,
        target.y,
        "follow " & playerColorName(followee),
        ImposterFollowApproachRadius
      )

  # 6. Nobody to follow — wander toward a random fake target, with the same
  # passing-by-task fake-task roll.
  bot.maybeStartFakeTask()
  if bot.imposterFakeTaskUntilTick > bot.frameTick and
      bot.imposterFakeTaskIndex >= 0 and
      bot.imposterFakeTaskIndex < bot.sim.tasks.len:
    let task = bot.sim.tasks[bot.imposterFakeTaskIndex]
    let center = task.taskCenter()
    return bot.navigateToPoint(
      center.x,
      center.y,
      "fake task setup",
      TaskPreciseApproachRadius
    )

  if bot.imposterGoalIndex < 0 or
      bot.imposterGoalIndex >= bot.fakeTargetCount():
    bot.imposterGoalIndex = bot.randomFakeTargetIndex()
  var goal = bot.fakeTargetGoalFor(bot.imposterGoalIndex)
  if not goal.found:
    bot.imposterGoalIndex = bot.randomFakeTargetIndex()
    goal = bot.fakeTargetGoalFor(bot.imposterGoalIndex)
  if not goal.found:
    bot.intent = "imposter idle, unreachable fake target"
    bot.thought("imposter idle, unreachable fake target")
    return 0
  if heuristic(bot.playerWorldX(), bot.playerWorldY(), goal.x, goal.y) <=
      TaskPreciseApproachRadius:
    bot.imposterGoalIndex = bot.randomFakeTargetIndex()
    goal = bot.fakeTargetGoalFor(bot.imposterGoalIndex)
    if not goal.found:
      bot.intent = "imposter idle, no next fake target"
      bot.thought("imposter idle, no next fake target")
      return 0
  bot.goalIndex = goal.index
  bot.navigateToPoint(goal.x, goal.y, "fake target " & goal.name)

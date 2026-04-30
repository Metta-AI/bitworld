## Task model: icon scan, radar projection, the four-state machine
## (NotDoing / Maybe / Mandatory / Completed), the v2 `resolved` latch,
## and the standing-still-with-A hold timer.
##
## Phase 1 port from v2:2146-2370 (radar projection + state updates),
## v2:2465-2488 (counting / button-fallback predicate), v2:3419-3502
## (task-ready / hold action / report-body action). v2:2490-2499
## (`rememberHome`) lives here too because it's tightly coupled to
## task-state lifecycle (it gates `gameStarted` which the rest of the
## bot reads).

import std/monotimes, std/times

import protocol
import ../../sim

import types
import geometry
import sprite_match
import actors  # scanRadarDots, scanTaskIcons, TaskIconExpectedSearchRadius
import path
import motion
import diag
import chat

const
  HomeSearchRadius* = 20
    ## Pixels around the remembered home point we'll search for a
    ## passable tile when the home pixel itself is blocked.
  RadarMatchTolerance* = 2
    ## Pixels of slack when matching a radar dot to a task's projected
    ## edge position.
  TaskIconSearchRadius* = 2
    ## Dedup / overlap radius for icon match comparisons.
  TaskIconInspectSize* = 16
    ## Side length of the rectangle around an expected icon position
    ## that we consider "the inspection area".
  TaskClearScreenMargin* = 8
    ## Pixels of slack required around the inspection rect for it to
    ## count as fully on-screen.
  TaskIconMissThreshold* = 24
    ## Frames a previously-`TaskMandatory` task can have its icon
    ## absent before we drop it to `TaskCompleted`.
  TaskInnerMargin* = 6
    ## How far inside a task rect the player must stand to be
    ## "on the task" — protects against a one-pixel drift dropping us
    ## off the task during the A-hold.
  TaskHoldPadding* = 8
    ## Extra ticks to hold A beyond `taskCompleteTicks` to absorb
    ## sim-side latency.
  TaskPreciseApproachRadius* = 12
    ## World pixels at which we switch to `preciseMaskForGoal`.
  KillApproachRadius* = 3
    ## Tight precise-approach radius for the imposter kill final
    ## approach.

# ---------------------------------------------------------------------------
# Radar / icon projection
# ---------------------------------------------------------------------------

proc projectedRadarDot*(bot: Bot,
                       task: TaskStation): tuple[visible: bool,
                                                 x: int, y: int] =
  ## If the task icon is on screen, returns its centre. Otherwise
  ## projects the offscreen icon position to the screen edge along the
  ## player→icon vector — that's where a radar dot should appear.
  if not bot.percep.localized:
    return
  let
    iconSx = task.x + task.w div 2 - SpriteSize div 2 - bot.percep.cameraX
    iconSy = task.y - SpriteSize - 2 - bot.percep.cameraY
    iconX = iconSx + SpriteSize div 2
    iconY = iconSy + SpriteSize div 2
  if iconSx + SpriteSize > 0 and iconSy + SpriteSize > 0 and
      iconSx < ScreenWidth and iconSy < ScreenHeight:
    return (true, iconX, iconY)
  let
    px = float(bot.percep.playerWorldX() + CollisionW div 2 - bot.percep.cameraX)
    py = float(bot.percep.playerWorldY() + CollisionH div 2 - bot.percep.cameraY)
    dx = float(iconX) - px
    dy = float(iconY) - py
  if abs(dx) < 0.5 and abs(dy) < 0.5:
    return
  let
    minX = 0.0
    maxX = float(ScreenWidth - 1)
    minY = 0.0
    maxY = float(ScreenHeight - 1)
  var
    ex: float
    ey: float
  if abs(dx) > abs(dy):
    if dx > 0:
      ex = maxX
    else:
      ex = minX
    ey = py + dy * (ex - px) / dx
    ey = clamp(ey, minY, maxY)
  else:
    if dy > 0:
      ey = maxY
    else:
      ey = minY
    ex = px + dx * (ey - py) / dy
    ex = clamp(ex, minX, maxX)
  (false, int(ex), int(ey))

proc projectedTaskIcon*(bot: Bot, task: TaskStation,
                       bobY: int): tuple[visible: bool, x: int, y: int] =
  ## Returns the expected on-screen position for a task icon at the
  ## given vertical-bob offset. Returns visible=false when the icon is
  ## fully off-screen.
  if not bot.percep.localized:
    return
  let
    iconX = task.x + task.w div 2 - SpriteSize div 2 - bot.percep.cameraX
    iconY = task.y - SpriteSize - 2 + bobY - bot.percep.cameraY
  if iconX + SpriteSize < 0 or iconY + SpriteSize < 0 or
      iconX >= ScreenWidth or iconY >= ScreenHeight:
    return
  (true, iconX, iconY)

proc taskIconInspectRect*(bot: Bot,
                         task: TaskStation): tuple[x, y, w, h: int] =
  ## Screen rectangle the icon should occupy. Used by
  ## `taskIconClearAreaVisible` to decide whether we have a clean
  ## look.
  (
    task.x + task.w div 2 - TaskIconInspectSize div 2 - bot.percep.cameraX,
    task.y - TaskIconInspectSize - bot.percep.cameraY,
    TaskIconInspectSize,
    TaskIconInspectSize
  )

proc taskIconRenderable*(bot: Bot, task: TaskStation): bool =
  ## True when the task's centre is on screen — i.e. the server could
  ## have rendered the icon if the task is assigned to us.
  let
    center = task.taskCenter()
    sx = center.x - bot.percep.cameraX
    sy = center.y - bot.percep.cameraY
  sx >= 0 and sx < ScreenWidth and sy >= 0 and sy < ScreenHeight

proc taskIconClearAreaVisible*(bot: Bot, task: TaskStation): bool =
  ## True when the full inspection rect is on screen with margin.
  ## Required before the v2 latch will fire.
  let rect = bot.taskIconInspectRect(task)
  rect.x >= TaskClearScreenMargin and
    rect.y >= TaskClearScreenMargin and
    rect.x + rect.w + TaskClearScreenMargin <= ScreenWidth and
    rect.y + rect.h + TaskClearScreenMargin <= ScreenHeight

proc taskIconMaybeVisibleFor*(bot: Bot, task: TaskStation): bool =
  ## Loose icon presence check using `maybeMatchesSprite` and the same
  ## search box as `scanTaskIcons`. Used as the second negative gate
  ## before the v2 latch.
  let
    baseX = task.x + task.w div 2 - SpriteSize div 2 - bot.percep.cameraX
    baseY = task.y - SpriteSize - 2 - bot.percep.cameraY
  for bobY in -1 .. 1:
    let expectedY = baseY + bobY
    for dy in -TaskIconExpectedSearchRadius .. TaskIconExpectedSearchRadius:
      for dx in -TaskIconExpectedSearchRadius .. TaskIconExpectedSearchRadius:
        if maybeMatchesSprite(bot.io.unpacked, bot.sprites.task,
                              baseX + dx, expectedY + dy):
          return true
  false

proc taskIconVisibleFor*(bot: Bot, task: TaskStation): bool =
  ## True when an icon strictly visible at one of the bob positions
  ## is in `bot.percep.visibleTaskIcons` near the projected location.
  for bobY in -1 .. 1:
    let projected = bot.projectedTaskIcon(task, bobY)
    if not projected.visible:
      continue
    for icon in bot.percep.visibleTaskIcons:
      if abs(icon.x - projected.x) <= TaskIconSearchRadius and
          abs(icon.y - projected.y) <= TaskIconSearchRadius:
        return true
  false

# ---------------------------------------------------------------------------
# Per-frame state updates
# ---------------------------------------------------------------------------

proc updateTaskGuesses*(bot: var Bot) =
  ## Updates ephemeral task candidates from radar dots. The `resolved`
  ## latch (v2 change) is enforced here: resolved tasks are skipped
  ## entirely — radar projection ambiguity cannot lure us back.
  ##
  ## Verbatim port of v2:2192-2225 modulo the sub-record renames.
  if bot.tasks.states.len != bot.sim.tasks.len:
    bot.tasks.states = newSeq[TaskState](bot.sim.tasks.len)
  if bot.tasks.radar.len != bot.sim.tasks.len:
    bot.tasks.radar = newSeq[bool](bot.sim.tasks.len)
  if bot.tasks.checkout.len != bot.sim.tasks.len:
    bot.tasks.checkout = newSeq[bool](bot.sim.tasks.len)
  if bot.tasks.resolved.len != bot.sim.tasks.len:
    bot.tasks.resolved = newSeq[bool](bot.sim.tasks.len)
  for i in 0 ..< bot.tasks.radar.len:
    bot.tasks.radar[i] = false
  if not bot.percep.localized:
    return
  bot.scanRadarDots()
  if bot.percep.radarDots.len == 0:
    return
  for i in 0 ..< bot.sim.tasks.len:
    if bot.tasks.resolved[i]:
      continue
    let projected = bot.projectedRadarDot(bot.sim.tasks[i])
    if projected.visible:
      continue
    for dot in bot.percep.radarDots:
      if abs(dot.x - projected.x) <= RadarMatchTolerance and
          abs(dot.y - projected.y) <= RadarMatchTolerance:
        bot.tasks.radar[i] = true
        bot.tasks.checkout[i] = true
        if bot.tasks.states[i] == TaskCompleted:
          bot.tasks.states[i] = TaskMaybe

proc updateTaskIcons*(bot: var Bot) =
  ## Updates task states from visible task icons. Implements the v2
  ## three-change-bundle: eager checkout cleanup, decoupled miss
  ## counter, and the `resolved` latch on three trigger paths
  ## (eager confirm, slow Mandatory→Completed, hold-A finish).
  ##
  ## Verbatim port of v2:2299-2370 modulo the sub-record renames.
  if bot.tasks.states.len != bot.sim.tasks.len:
    bot.tasks.states = newSeq[TaskState](bot.sim.tasks.len)
  if bot.tasks.iconMisses.len != bot.sim.tasks.len:
    bot.tasks.iconMisses = newSeq[int](bot.sim.tasks.len)
  if bot.tasks.checkout.len != bot.sim.tasks.len:
    bot.tasks.checkout = newSeq[bool](bot.sim.tasks.len)
  if bot.tasks.resolved.len != bot.sim.tasks.len:
    bot.tasks.resolved = newSeq[bool](bot.sim.tasks.len)
  if not bot.percep.localized:
    return
  bot.scanTaskIcons()
  for i in 0 ..< bot.sim.tasks.len:
    let task = bot.sim.tasks[i]
    if bot.taskIconVisibleFor(task):
      bot.tasks.states[i] = TaskMandatory
      bot.tasks.iconMisses[i] = 0
      # Real icon overrides any prior latch (transient false negative
      # recovery).
      if bot.tasks.resolved.len == bot.sim.tasks.len:
        bot.tasks.resolved[i] = false
    elif bot.tasks.holdTicks == 0 and
        bot.taskIconClearAreaVisible(task) and
        not bot.taskIconMaybeVisibleFor(task) and
        bot.tasks.holdIndex != i:
      # Clear view + no icon (strict + fuzzy) = definitive
      # confirmation.
      if bot.tasks.states[i] == TaskMandatory:
        inc bot.tasks.iconMisses[i]
        if bot.tasks.iconMisses[i] >= TaskIconMissThreshold:
          bot.tasks.states[i] = TaskCompleted
          bot.tasks.checkout[i] = false
          bot.tasks.iconMisses[i] = 0
          bot.tasks.resolved[i] = true
      elif not bot.tasks.resolved[i]:
        # Aggressive latch: any clear-view confirmation marks
        # resolved-not-mine for the round.
        bot.tasks.resolved[i] = true
        bot.tasks.checkout[i] = false
        bot.tasks.iconMisses[i] = 0
    else:
      bot.tasks.iconMisses[i] = 0

# ---------------------------------------------------------------------------
# Counting / fallback predicate
# ---------------------------------------------------------------------------

proc taskStateCount*(bot: Bot, state: TaskState): int =
  for s in bot.tasks.states:
    if s == state:
      inc result

proc radarTaskCount*(bot: Bot): int =
  for r in bot.tasks.radar:
    if r:
      inc result

proc checkoutTaskCount*(bot: Bot): int =
  for c in bot.tasks.checkout:
    if c:
      inc result

proc buttonFallbackReady*(bot: Bot): bool =
  ## True when no useful task remains and the home/button is the only
  ## sensible goal.
  bot.percep.radarDots.len == 0 and
    bot.radarTaskCount() == 0 and
    bot.checkoutTaskCount() == 0 and
    bot.taskStateCount(TaskMandatory) == 0

# ---------------------------------------------------------------------------
# Home memory
# ---------------------------------------------------------------------------

proc rememberHome*(bot: var Bot) =
  ## Records the first reliable round position as this bot's home.
  if not bot.percep.localized or bot.percep.interstitial:
    return
  bot.percep.gameStarted = true
  if bot.percep.homeSet:
    return
  bot.percep.homeX = bot.percep.playerWorldX()
  bot.percep.homeY = bot.percep.playerWorldY()
  bot.percep.homeSet = true

# ---------------------------------------------------------------------------
# Task-readiness queries
# ---------------------------------------------------------------------------

proc taskReady*(bot: Bot, task: TaskStation): bool =
  ## True when the player is inside the task's inner rect and almost
  ## stationary. The "inner rect" margin (`TaskInnerMargin`) protects
  ## against a one-pixel drift dropping us off the task while we're
  ## holding A.
  let
    x = bot.percep.playerWorldX()
    y = bot.percep.playerWorldY()
    innerX0 = task.x + TaskInnerMargin
    innerY0 = task.y + TaskInnerMargin
    innerX1 = task.x + task.w - TaskInnerMargin
    innerY1 = task.y + task.h - TaskInnerMargin
  if x < innerX0 or x >= innerX1 or y < innerY0 or y >= innerY1:
    return false
  abs(bot.motion.velocityX) + abs(bot.motion.velocityY) <= 1

proc taskReadyAtGoal*(bot: Bot, index, goalX, goalY: int): bool =
  ## True when a task can be held at the given selected goal (allows
  ## the goal to be slightly outside the inner rect if we're at it).
  if index < 0 or index >= bot.sim.tasks.len:
    return false
  let
    task = bot.sim.tasks[index]
    x = bot.percep.playerWorldX()
    y = bot.percep.playerWorldY()
  if x < task.x or x >= task.x + task.w or
      y < task.y or y >= task.y + task.h:
    return false
  if abs(bot.motion.velocityX) + abs(bot.motion.velocityY) > 1:
    return false
  bot.taskReady(task) or
    (abs(x - goalX) + abs(y - goalY)) <= 1

proc taskGoalReady*(bot: Bot,
                   goal: tuple[found: bool, index: int,
                              x, y: int, name: string,
                              state: TaskState]): bool =
  ## True when the selected goal is ready for hold-A action.
  if not goal.found:
    return false
  bot.taskReadyAtGoal(goal.index, goal.x, goal.y)

# ---------------------------------------------------------------------------
# Hold-A action
# ---------------------------------------------------------------------------

proc holdTaskAction*(bot: var Bot, name: string): uint8 =
  ## Holds only the action button while completing a task. On the
  ## last frame of the hold, verifies the icon disappeared and
  ## promotes the task to TaskCompleted (latching `resolved`); else
  ## reverts to TaskMandatory.
  bot.diag.intent = "doing task at " & name & " hold=" & $bot.tasks.holdTicks
  bot.motion.desiredMask = ButtonA
  bot.motion.controllerMask = ButtonA
  bot.goal.hasPathStep = false
  bot.goal.path.setLen(0)
  if bot.tasks.holdTicks > 0:
    dec bot.tasks.holdTicks
  if bot.tasks.holdTicks == 0 and
      bot.tasks.holdIndex >= 0 and
      bot.tasks.holdIndex < bot.tasks.states.len:
    let task = bot.sim.tasks[bot.tasks.holdIndex]
    if not bot.taskIconVisibleFor(task) and bot.taskIconClearAreaVisible(task):
      bot.tasks.states[bot.tasks.holdIndex] = TaskCompleted
      if bot.tasks.checkout.len == bot.sim.tasks.len:
        bot.tasks.checkout[bot.tasks.holdIndex] = false
      # v2: latch resolved on successful completion.
      if bot.tasks.resolved.len == bot.sim.tasks.len:
        bot.tasks.resolved[bot.tasks.holdIndex] = true
    else:
      bot.tasks.states[bot.tasks.holdIndex] = TaskMandatory
    bot.tasks.holdIndex = -1
  bot.thought("at task " & name & ", holding action")
  ButtonA

# ---------------------------------------------------------------------------
# Range predicates
# ---------------------------------------------------------------------------

proc inReportRange*(bot: Bot, targetX, targetY: int): bool =
  ## True when (targetX, targetY) is within `sim.config.reportRange` of
  ## the player. Squared-distance comparison.
  let
    ax = bot.percep.playerWorldX() + CollisionW div 2
    ay = bot.percep.playerWorldY() + CollisionH div 2
    bx = targetX + CollisionW div 2
    by = targetY + CollisionH div 2
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy <= bot.sim.config.reportRange * bot.sim.config.reportRange

proc inKillRange*(bot: Bot, targetX, targetY: int): bool =
  ## True when (targetX, targetY) is within `sim.config.killRange` of
  ## the player.
  let
    ax = bot.percep.playerWorldX() + CollisionW div 2
    ay = bot.percep.playerWorldY() + CollisionH div 2
    bx = targetX + CollisionW div 2
    by = targetY + CollisionH div 2
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy <= bot.sim.config.killRange * bot.sim.config.killRange

# ---------------------------------------------------------------------------
# Goal selection helpers (used by both crewmate and imposter policies)
# ---------------------------------------------------------------------------

type
  TaskGoal* = tuple[
    found: bool,
    index: int,
    x, y: int,
    name: string,
    state: TaskState
  ]

proc taskGoalFor*(bot: Bot, index: int, state: TaskState): TaskGoal =
  ## Returns a reachable goal pixel inside one task rectangle. Tries
  ## three increasingly relaxed search regions:
  ##   1. inner rect, only pixels where the icon would be on screen
  ##   2. inner rect, no icon-visibility constraint
  ##   3. full task rect, no icon-visibility constraint
  ## Verbatim port of v2:2639-2706.
  if index < 0 or index >= bot.sim.tasks.len:
    return
  let
    task = bot.sim.tasks[index]
    center = task.taskCenter()
  var
    bestDistance = high(int)
    bestX = 0
    bestY = 0
  proc iconVisibleAt(x, y: int): bool =
    let
      cameraX = x - PlayerWorldOffX
      cameraY = y - PlayerWorldOffY
      iconWorldX = task.x + task.w div 2 - SpriteSize div 2
      iconWorldY = task.y - SpriteSize - 2
    for bobY in -1 .. 1:
      let
        iconX = iconWorldX - cameraX
        iconY = iconWorldY + bobY - cameraY
      if iconX < 0 or iconY < 0 or
          iconX + SpriteSize > ScreenWidth or
          iconY + SpriteSize > ScreenHeight:
        return false
    true
  template considerRange(x0, y0, x1, y1: int, requireIcon: bool) =
    for y in max(task.y, y0) ..< min(task.y + task.h, y1):
      for x in max(task.x, x0) ..< min(task.x + task.w, x1):
        if not bot.sim.passable(x, y):
          continue
        if requireIcon and not iconVisibleAt(x, y):
          continue
        let distance = heuristic(center.x, center.y, x, y)
        if distance < bestDistance:
          bestDistance = distance
          bestX = x
          bestY = y
  considerRange(
    task.x + TaskInnerMargin,
    task.y + TaskInnerMargin,
    task.x + task.w - TaskInnerMargin,
    task.y + task.h - TaskInnerMargin,
    true
  )
  if bestDistance == high(int):
    considerRange(
      task.x + TaskInnerMargin,
      task.y + TaskInnerMargin,
      task.x + task.w - TaskInnerMargin,
      task.y + task.h - TaskInnerMargin,
      false
    )
  if bestDistance == high(int):
    considerRange(
      task.x,
      task.y,
      task.x + task.w,
      task.y + task.h,
      false
    )
  if bestDistance == high(int):
    return
  (true, index, bestX, bestY, task.name, state)

proc buttonGoal*(bot: Bot): TaskGoal =
  ## Returns a passable point inside the emergency button rectangle.
  ## Used as the home fallback when no home is yet recorded.
  let
    button = bot.sim.gameMap.button
    centerX = button.x + button.w div 2
    centerY = button.y + button.h div 2
  var
    bestDistance = high(int)
    bestX = 0
    bestY = 0
  for y in button.y ..< button.y + button.h:
    for x in button.x ..< button.x + button.w:
      if not bot.sim.passable(x, y):
        continue
      let distance = heuristic(centerX, centerY, x, y)
      if distance < bestDistance:
        bestDistance = distance
        bestX = x
        bestY = y
  if bestDistance == high(int):
    return
  (true, -1, bestX, bestY, "Button", TaskMaybe)

proc homeGoal*(bot: Bot): TaskGoal =
  ## Returns this bot's remembered cafeteria home point, or the button
  ## as a fallback. Ghost players are allowed to home directly even on
  ## non-passable pixels (they fly through walls).
  if not bot.percep.homeSet:
    return bot.buttonGoal()
  if bot.isGhost or bot.sim.passable(bot.percep.homeX, bot.percep.homeY):
    return (true, -1, bot.percep.homeX, bot.percep.homeY, "Home", TaskMaybe)
  var
    bestDistance = high(int)
    bestX = 0
    bestY = 0
  for y in max(0, bot.percep.homeY - HomeSearchRadius) ..
      min(MapHeight - 1, bot.percep.homeY + HomeSearchRadius):
    for x in max(0, bot.percep.homeX - HomeSearchRadius) ..
        min(MapWidth - 1, bot.percep.homeX + HomeSearchRadius):
      if not bot.sim.passable(x, y):
        continue
      let distance = heuristic(bot.percep.homeX, bot.percep.homeY, x, y)
      if distance < bestDistance:
        bestDistance = distance
        bestX = x
        bestY = y
  if bestDistance == high(int):
    return bot.buttonGoal()
  (true, -1, bestX, bestY, "Home", TaskMaybe)

# ---------------------------------------------------------------------------
# Navigation primitives
# ---------------------------------------------------------------------------

proc reportBodyAction*(bot: var Bot, x, y: int): uint8 =
  ## Presses A to call a meeting on a visible dead body. Queues the
  ## body-room chat line for the upcoming voting screen.
  bot.diag.intent = "reporting dead body"
  bot.motion.desiredMask = ButtonA
  bot.motion.controllerMask = ButtonA
  bot.goal.hasPathStep = false
  bot.goal.path.setLen(0)
  bot.tasks.holdTicks = 0
  bot.tasks.holdIndex = -1
  bot.queueBodyReport(x, y)
  bot.thought("reporting dead body")
  ButtonA

proc navigateToPoint*(bot: var Bot, x, y: int, name: string,
                     preciseRadius = TaskPreciseApproachRadius): uint8 =
  ## Plans an A* path to (x, y), picks a lookahead waypoint, converts
  ## that to a button mask via the momentum-aware controller, applies
  ## anti-stuck jiggle, and writes the final mask.
  ##
  ## Ghosts skip A* and use straight-line precise steering.
  bot.goal.has = true
  bot.goal.x = x
  bot.goal.y = y
  bot.goal.name = name
  if bot.isGhost:
    bot.goal.path.setLen(0)
    bot.goal.hasPathStep = false
    bot.perf.astarMicros = 0
    bot.diag.intent = "ghost direct to " & name
    bot.motion.desiredMask = preciseMaskForGoal(bot.percep, bot.motion, x, y)
  else:
    let astarStart = getMonoTime()
    bot.goal.path = findPath(bot.percep, bot.sim, x, y)
    bot.perf.astarMicros = int((getMonoTime() - astarStart).inMicroseconds)
    bot.goal.pathStep = choosePathStep(bot.goal.path)
    bot.goal.hasPathStep = bot.goal.pathStep.found
    bot.diag.intent = "A* to " & name & " path=" & $bot.goal.path.len
    if heuristic(bot.percep.playerWorldX(), bot.percep.playerWorldY(),
                 x, y) <= preciseRadius:
      bot.diag.intent = "precise approach to " & name
      bot.motion.desiredMask = preciseMaskForGoal(bot.percep, bot.motion, x, y)
    else:
      bot.motion.desiredMask = maskForWaypoint(bot.percep, bot.motion,
                                              bot.goal.pathStep)
  bot.motion.controllerMask = bot.motion.desiredMask
  let mask = bot.motion.applyJiggle(bot.motion.controllerMask)
  let prefix =
    if bot.role == RoleImposter:
      "imposter "
    elif bot.isGhost:
      "ghost "
    else:
      "map lock "
  bot.thought(
    prefix & cameraLockName(bot.percep.cameraLock) & " at camera (" &
    $bot.percep.cameraX & ", " & $bot.percep.cameraY & "), next " &
    movementName(mask)
  )
  mask

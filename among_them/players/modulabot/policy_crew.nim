## Crewmate decision tree.
##
## Phase 1 port from v2:3251-3336 (`nearestTaskGoal`) and the crewmate
## path through v2's `decideNextMask` (v2:3964-4032).
##
## Priority order (matches v2 / evidencebot strategy doc §4):
##   1. Body in view → queue chat, report if in range, else navigate.
##   2. Active task hold → continue holding A.
##   3. Visible mandatory task icons (highest tier).
##   4. Sticky existing mandatory task goal.
##   5. Nearest mandatory task.
##   6. Sticky existing checkout task goal.
##   7. Nearest non-completed checkout task.
##   8. Sticky radar task goal.
##   9. Nearest radar task.
##  10. Home / button fallback.

import std/monotimes, std/times

import ../../sim

import types
import geometry
import path
import motion
import diag
import chat
import evidence
import tasks

# ---------------------------------------------------------------------------
# Goal picking
# ---------------------------------------------------------------------------

proc nearestTaskGoal*(bot: Bot): TaskGoal =
  ## Returns the closest known active task station goal under the
  ## eight-tier fallback. Return is `(found: false, ...)` only when
  ## absolutely nothing is known and we don't even have a button
  ## fallback.
  ##
  ## Verbatim port of v2:3251-3336 modulo sub-record renames.
  var bestDistance = high(int)
  # Tier 1: visible mandatory icons.
  for i in 0 ..< bot.sim.tasks.len:
    if not bot.taskIconVisibleFor(bot.sim.tasks[i]):
      continue
    let goal = bot.taskGoalFor(i, TaskMandatory)
    if not goal.found:
      continue
    let distance = goalDistance(bot.percep, bot.sim, bot.isGhost,
                                goal.x, goal.y)
    if distance < bestDistance:
      bestDistance = distance
      result = goal
  if result.found:
    return
  # Tier 2: sticky previous mandatory goal.
  if bot.goal.index >= 0 and
      bot.goal.index < bot.sim.tasks.len and
      bot.tasks.states.len == bot.sim.tasks.len and
      bot.tasks.states[bot.goal.index] == TaskMandatory:
    let goal = bot.taskGoalFor(bot.goal.index, TaskMandatory)
    if goal.found:
      return goal
  # Tier 3: nearest mandatory.
  bestDistance = high(int)
  for i in 0 ..< bot.sim.tasks.len:
    if bot.tasks.states.len == bot.sim.tasks.len and
        bot.tasks.states[i] != TaskMandatory:
      continue
    let goal = bot.taskGoalFor(i, TaskMandatory)
    if not goal.found:
      continue
    let distance = goalDistance(bot.percep, bot.sim, bot.isGhost,
                                goal.x, goal.y)
    if distance < bestDistance:
      bestDistance = distance
      result = goal
  if result.found:
    return
  # Tier 4: sticky checkout goal.
  if bot.goal.index >= 0 and
      bot.goal.index < bot.sim.tasks.len and
      bot.tasks.states.len == bot.sim.tasks.len and
      bot.tasks.states[bot.goal.index] != TaskCompleted and
      bot.tasks.checkout.len == bot.sim.tasks.len and
      bot.tasks.checkout[bot.goal.index]:
    let goal = bot.taskGoalFor(bot.goal.index, TaskMaybe)
    if goal.found:
      return goal
  # Tier 5: nearest non-completed checkout.
  bestDistance = high(int)
  for i in 0 ..< bot.sim.tasks.len:
    if bot.tasks.checkout.len != bot.sim.tasks.len or
        not bot.tasks.checkout[i]:
      continue
    if bot.tasks.states.len == bot.sim.tasks.len and
        bot.tasks.states[i] == TaskCompleted:
      continue
    let goal = bot.taskGoalFor(i, TaskMaybe)
    if not goal.found:
      continue
    let distance = goalDistance(bot.percep, bot.sim, bot.isGhost,
                                goal.x, goal.y)
    if distance < bestDistance:
      bestDistance = distance
      result = goal
  if result.found:
    return
  # Tier 6: sticky radar goal.
  if bot.goal.index >= 0 and
      bot.goal.index < bot.sim.tasks.len and
      bot.tasks.radar.len == bot.sim.tasks.len and
      bot.tasks.radar[bot.goal.index]:
    let goal = bot.taskGoalFor(bot.goal.index, TaskMaybe)
    if goal.found:
      return goal
  # Tier 7: nearest radar task.
  bestDistance = high(int)
  for i in 0 ..< bot.sim.tasks.len:
    if bot.tasks.radar.len != bot.sim.tasks.len or not bot.tasks.radar[i]:
      continue
    let goal = bot.taskGoalFor(i, TaskMaybe)
    if not goal.found:
      continue
    let distance = goalDistance(bot.percep, bot.sim, bot.isGhost,
                                goal.x, goal.y)
    if distance < bestDistance:
      bestDistance = distance
      result = goal
  if result.found:
    return
  # Tier 8: home/button fallback if nothing else is useful.
  if bot.buttonFallbackReady():
    return bot.homeGoal()

# ---------------------------------------------------------------------------
# Crewmate per-frame mask
# ---------------------------------------------------------------------------

proc decideCrewmateMask*(bot: var Bot): uint8 =
  ## Crewmate path through the per-frame pipeline. Called by the
  ## orchestrator after perception, motion, evidence, and home-memory
  ## updates have run, and only when role != RoleImposter.
  ##
  ## Verbatim port of v2:3964-4032 modulo sub-record renames.
  if not bot.isGhost:
    let body = bot.nearestBody()
    if body.found:
      bot.queueBodySeen(body.x, body.y)
      if bot.inReportRange(body.x, body.y) and
          abs(bot.motion.velocityX) + abs(bot.motion.velocityY) <= 1:
        return bot.reportBodyAction(body.x, body.y)
      return bot.navigateToPoint(
        body.x,
        body.y,
        "dead body",
        KillApproachRadius
      )
  if bot.tasks.holdTicks > 0:
    return bot.holdTaskAction(
      if bot.goal.name.len > 0:
        bot.goal.name
      else:
        "task"
    )
  let goal = bot.nearestTaskGoal()
  if not goal.found:
    bot.diag.intent = "localized, no task goal"
    bot.thought("localized near (" & $bot.percep.playerWorldX() & ", " &
      $bot.percep.playerWorldY() & ")")
    return 0
  bot.goal.has = true
  bot.goal.x = goal.x
  bot.goal.y = goal.y
  bot.goal.index = goal.index
  bot.goal.name = goal.name
  if goal.state == TaskMandatory and bot.taskGoalReady(goal):
    bot.tasks.holdTicks = bot.sim.config.taskCompleteTicks + TaskHoldPadding
    bot.tasks.holdIndex = goal.index
    return bot.holdTaskAction(goal.name)
  if bot.isGhost:
    return bot.navigateToPoint(goal.x, goal.y, goal.name)
  let astarStart = getMonoTime()
  bot.goal.path = findPath(bot.percep, bot.sim, goal.x, goal.y)
  bot.perf.astarMicros = int((getMonoTime() - astarStart).inMicroseconds)
  bot.goal.pathStep = choosePathStep(bot.goal.path)
  bot.goal.hasPathStep = bot.goal.pathStep.found
  bot.diag.intent =
    if goal.index < 0:
      "gather at " & goal.name & " path=" & $bot.goal.path.len
    else:
      "A* to " & goal.name & " path=" & $bot.goal.path.len &
        " state=" & $goal.state
  if goal.state == TaskMandatory and
      heuristic(bot.percep.playerWorldX(), bot.percep.playerWorldY(),
                goal.x, goal.y) <= TaskPreciseApproachRadius:
    bot.diag.intent = "precise task approach to " & goal.name &
      " state=" & $goal.state
    bot.motion.desiredMask = preciseMaskForGoal(bot.percep, bot.motion,
                                               goal.x, goal.y)
  else:
    bot.motion.desiredMask = maskForWaypoint(bot.percep, bot.motion,
                                            bot.goal.pathStep)
  bot.motion.controllerMask = bot.motion.desiredMask
  let mask = bot.motion.applyJiggle(bot.motion.controllerMask)
  bot.thought(
    "map lock " & cameraLockName(bot.percep.cameraLock) & " at camera (" &
    $bot.percep.cameraX & ", " & $bot.percep.cameraY & "), next " &
    movementName(mask)
  )
  mask

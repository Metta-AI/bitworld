proc decideNextMask(bot: var Bot): uint8 =
  ## Updates perception and chooses the next input mask.
  let centerStart = getMonoTime()
  bot.updateLocation()
  bot.centerMicros = int((getMonoTime() - centerStart).inMicroseconds)
  bot.astarMicros = 0
  if bot.interstitial:
    bot.updateMotionState()
    bot.hasGoal = false
    bot.hasPathStep = false
    bot.path.setLen(0)
    if bot.voting:
      return bot.decideVotingMask()
    bot.desiredMask = 0
    bot.controllerMask = 0
    bot.intent =
      if bot.interstitialText.len > 0:
        "interstitial: " & bot.interstitialText
      else:
        "interstitial screen mode"
    bot.thought(bot.intent)
    return 0
  bot.updateMotionState()
  bot.rememberVisibleMap()
  bot.updateTaskGuesses()
  bot.updateTaskIcons()
  bot.hasGoal = false
  bot.hasPathStep = false
  bot.path.setLen(0)
  bot.desiredMask = 0
  bot.controllerMask = 0
  bot.intent = "localizing"
  if not bot.localized:
    bot.thought("waiting for a reliable map lock")
    return 0
  # Update evidence tracking BEFORE acting on it. Both crewmate accusations
  # and imposter random-blame depend on up-to-date sightings; this only
  # touches per-color tick stamps and previous-frame snapshots.
  bot.updateEvidence()
  bot.rememberHome()
  if bot.role == RoleImposter and not bot.isGhost:
    return bot.decideImposterMask()
  if not bot.isGhost:
    let body = bot.nearestBody()
    if body.found:
      bot.queueBodySeen(body.x, body.y)
      if bot.inReportRange(body.x, body.y) and
          abs(bot.velocityX) + abs(bot.velocityY) <= 1:
        return bot.reportBodyAction(body.x, body.y)
      return bot.navigateToPoint(
        body.x,
        body.y,
        "dead body",
        KillApproachRadius
      )
  if bot.taskHoldTicks > 0:
    return bot.holdTaskAction(
      if bot.goalName.len > 0:
        bot.goalName
      else:
        "task"
    )
  let goal = bot.nearestTaskGoal()
  if not goal.found:
    bot.intent = "localized, no task goal"
    bot.thought("localized near (" & $bot.playerWorldX() & ", " &
      $bot.playerWorldY() & ")")
    return 0
  bot.hasGoal = true
  bot.goalX = goal.x
  bot.goalY = goal.y
  bot.goalIndex = goal.index
  bot.goalName = goal.name
  if goal.state == TaskMandatory and
      bot.taskGoalReady(goal):
    bot.taskHoldTicks = bot.sim.config.taskCompleteTicks + TaskHoldPadding
    bot.taskHoldIndex = goal.index
    return bot.holdTaskAction(goal.name)
  if bot.isGhost:
    return bot.navigateToPoint(goal.x, goal.y, goal.name)
  let astarStart = getMonoTime()
  bot.path = bot.findPath(goal.x, goal.y)
  bot.astarMicros = int((getMonoTime() - astarStart).inMicroseconds)
  bot.pathStep = bot.choosePathStep()
  bot.hasPathStep = bot.pathStep.found
  bot.intent =
    if goal.index < 0:
      "gather at " & goal.name & " path=" & $bot.path.len
    else:
      "A* to " & goal.name & " path=" & $bot.path.len &
        " state=" & $goal.state
  if goal.state == TaskMandatory and
      heuristic(
        bot.playerWorldX(),
        bot.playerWorldY(),
        goal.x,
        goal.y
      ) <= TaskPreciseApproachRadius:
    bot.intent = "precise task approach to " & goal.name &
      " state=" & $goal.state
    bot.desiredMask = bot.preciseMaskForGoal(goal.x, goal.y)
  else:
    bot.desiredMask = bot.maskForWaypoint(bot.pathStep)
  bot.controllerMask = bot.desiredMask
  let mask = bot.applyJiggle(bot.controllerMask)
  bot.thought(
    "map lock " & cameraLockName(bot.cameraLock) & " at camera (" &
    $bot.cameraX & ", " & $bot.cameraY & "), next " &
    movementName(mask)
  )
  mask


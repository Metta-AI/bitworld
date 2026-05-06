proc clearVotingState(bot: var Bot) =
  ## Clears the parsed voting screen state.
  bot.voting = false
  bot.votePlayerCount = 0
  bot.voteCursor = VoteUnknown
  bot.voteSelfSlot = VoteUnknown
  bot.voteTarget = VoteUnknown
  bot.voteStartTick = -1
  bot.voteChatSusColor = VoteUnknown
  bot.voteChatText = ""
  for i in 0 ..< bot.voteSlots.len:
    bot.voteSlots[i].colorIndex = VoteUnknown
    bot.voteSlots[i].alive = false
  for i in 0 ..< bot.voteChoices.len:
    bot.voteChoices[i] = VoteUnknown

proc resetRoundState(bot: var Bot) =
  ## Clears per-round bot state after a detected game-over screen.
  bot.localized = false
  bot.gameStarted = false
  bot.homeSet = false
  bot.homeX = 0
  bot.homeY = 0
  bot.role = RoleCrewmate
  bot.isGhost = false
  bot.ghostIconFrames = 0
  bot.imposterKillReady = false
  bot.imposterGoalIndex = -1
  bot.imposterFolloweeColor = -1
  bot.imposterFolloweeSinceTick = 0
  bot.imposterFakeTaskIndex = -1
  bot.imposterFakeTaskUntilTick = 0
  bot.imposterFakeTaskCooldownTick = 0
  bot.imposterPrevNearTaskIndex = -1
  bot.imposterLastKillTick = 0
  bot.imposterLastKillX = 0
  bot.imposterLastKillY = 0
  bot.cameraLock = NoLock
  bot.cameraScore = 0
  bot.haveMotionSample = false
  bot.velocityX = 0
  bot.velocityY = 0
  bot.stuckFrames = 0
  bot.jiggleTicks = 0
  bot.jiggleSide = 0
  bot.desiredMask = 0
  bot.controllerMask = 0
  bot.taskHoldTicks = 0
  bot.taskHoldIndex = -1
  bot.pendingChat = ""
  bot.lastBodySeenX = low(int)
  bot.lastBodySeenY = low(int)
  bot.lastBodyReportX = low(int)
  bot.lastBodyReportY = low(int)
  bot.selfColorIndex = -1
  bot.clearVotingState()
  for i in 0 ..< bot.lastSeenTicks.len:
    bot.lastSeenTicks[i] = 0
  for i in 0 ..< bot.knownImposters.len:
    bot.knownImposters[i] = false
  for i in 0 ..< PlayerColorCount:
    bot.nearBodyTicks[i] = 0
    bot.witnessedKillTicks[i] = 0
    bot.prevVisibleCrewmateX[i] = -1
    bot.prevVisibleCrewmateY[i] = -1
  bot.prevVisibleBodies.setLen(0)
  bot.goalIndex = -1
  bot.goalName = ""
  bot.hasGoal = false
  bot.hasPathStep = false
  bot.path.setLen(0)
  bot.radarDots.setLen(0)
  bot.visibleTaskIcons.setLen(0)
  bot.visibleCrewmates.setLen(0)
  bot.visibleBodies.setLen(0)
  bot.visibleGhosts.setLen(0)
  if bot.radarTasks.len != bot.sim.tasks.len:
    bot.radarTasks = newSeq[bool](bot.sim.tasks.len)
  else:
    for i in 0 ..< bot.radarTasks.len:
      bot.radarTasks[i] = false
  if bot.checkoutTasks.len != bot.sim.tasks.len:
    bot.checkoutTasks = newSeq[bool](bot.sim.tasks.len)
  else:
    for i in 0 ..< bot.checkoutTasks.len:
      bot.checkoutTasks[i] = false
  if bot.taskStates.len != bot.sim.tasks.len:
    bot.taskStates = newSeq[TaskState](bot.sim.tasks.len)
  else:
    for i in 0 ..< bot.taskStates.len:
      bot.taskStates[i] = TaskNotDoing
  if bot.taskIconMisses.len != bot.sim.tasks.len:
    bot.taskIconMisses = newSeq[int](bot.sim.tasks.len)
  else:
    for i in 0 ..< bot.taskIconMisses.len:
      bot.taskIconMisses[i] = 0
  if bot.taskResolved.len != bot.sim.tasks.len:
    bot.taskResolved = newSeq[bool](bot.sim.tasks.len)
  else:
    for i in 0 ..< bot.taskResolved.len:
      bot.taskResolved[i] = false


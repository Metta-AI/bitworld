proc stepUnpackedFrame*(bot: var Bot, frame: openArray[uint8]): uint8 =
  ## Steps the bot from one unpacked 4-bit framebuffer and returns an input mask.
  if frame.len != ScreenWidth * ScreenHeight:
    return 0
  if bot.unpacked.len != frame.len:
    bot.unpacked.setLen(frame.len)
  for i, value in frame:
    bot.unpacked[i] = value and 0x0f
  inc bot.frameTick
  result = bot.decideNextMask()
  bot.lastMask = result

proc stepPackedFrame*(bot: var Bot, frame: openArray[uint8]): uint8 =
  ## Steps the bot from one packed 4-bit framebuffer and returns an input mask.
  if frame.len != ProtocolBytes:
    return 0
  if bot.packed.len != frame.len:
    bot.packed.setLen(frame.len)
  for i, value in frame:
    bot.packed[i] = value
  unpack4bpp(bot.packed, bot.unpacked)
  inc bot.frameTick
  result = bot.decideNextMask()
  bot.lastMask = result

proc sheetSprite(sheet: Image, cellX, cellY: int): Sprite =
  ## Extracts one 12x12 sprite from the local sprite sheet.
  spriteFromImage(
    sheet.subImage(cellX * SpriteSize, cellY * SpriteSize, SpriteSize, SpriteSize)
  )

proc initBot(mapPath = ""): Bot =
  ## Builds a bot and loads all map and sprite data.
  setCurrentDir(gameDir())
  var config = defaultGameConfig()
  if mapPath.len > 0:
    config.mapPath = mapPath
  result.sim = initSimServer(config)
  let sheet = loadSpriteSheet()
  result.playerSprite = sheet.sheetSprite(0, 0)
  result.bodySprite = sheet.sheetSprite(1, 0)
  result.killButtonSprite = sheet.sheetSprite(3, 0)
  result.taskSprite = sheet.sheetSprite(4, 0)
  result.ghostSprite = sheet.sheetSprite(6, 0)
  result.ghostIconSprite = sheet.sheetSprite(7, 0)
  result.rng = initRand(getTime().toUnix() xor int64(getCurrentProcessId()))
  result.packed = newSeq[uint8](ProtocolBytes)
  result.unpacked = newSeq[uint8](ScreenWidth * ScreenHeight)
  result.mapTiles = newSeq[TileKnowledge](MapWidth * MapHeight)
  result.radarTasks = newSeq[bool](result.sim.tasks.len)
  result.checkoutTasks = newSeq[bool](result.sim.tasks.len)
  result.taskStates = newSeq[TaskState](result.sim.tasks.len)
  result.taskIconMisses = newSeq[int](result.sim.tasks.len)
  result.taskResolved = newSeq[bool](result.sim.tasks.len)
  result.buildPatchEntries()
  result.cameraX = result.sim.buttonCameraX()
  result.cameraY = result.sim.buttonCameraY()
  result.lastCameraX = result.cameraX
  result.lastCameraY = result.cameraY
  result.taskHoldIndex = -1
  result.imposterGoalIndex = -1
  result.imposterFolloweeColor = -1
  result.imposterFolloweeSinceTick = 0
  result.imposterFakeTaskIndex = -1
  result.imposterFakeTaskUntilTick = 0
  result.imposterFakeTaskCooldownTick = 0
  result.imposterPrevNearTaskIndex = -1
  result.imposterLastKillTick = 0
  result.imposterLastKillX = 0
  result.imposterLastKillY = 0
  result.goalIndex = -1
  result.lastBodySeenX = low(int)
  result.lastBodySeenY = low(int)
  result.lastBodyReportX = low(int)
  result.lastBodyReportY = low(int)
  result.cameraLock = NoLock
  result.role = RoleCrewmate
  result.selfColorIndex = -1
  result.clearVotingState()
  result.intent = "waiting for first frame"

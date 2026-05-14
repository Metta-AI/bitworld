import
  std/[json, os],
  ../global, ../sim

setCurrentDir(currentSourcePath().parentDir().parentDir())

proc readU16(packet: openArray[uint8], offset: int): int =
  ## Reads one little endian unsigned 16 bit value from a packet.
  int(uint16(packet[offset]) or (uint16(packet[offset + 1]) shl 8))

proc readU32(packet: openArray[uint8], offset: int): int =
  ## Reads one little endian unsigned 32 bit value from a packet.
  int(uint32(packet[offset]) or
    (uint32(packet[offset + 1]) shl 8) or
    (uint32(packet[offset + 2]) shl 16) or
    (uint32(packet[offset + 3]) shl 24))

proc spritePacketObjectIds(packet: openArray[uint8]): seq[int] =
  ## Returns all object ids defined in one sprite protocol packet.
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01'u8:
      doAssert offset + 10 <= packet.len
      let compressedLen = packet.readU32(offset + 6)
      offset += 10 + compressedLen
      doAssert offset + 2 <= packet.len
      let labelLen = packet.readU16(offset)
      offset += 2 + labelLen
    of 0x02'u8:
      doAssert offset + 11 <= packet.len
      result.add packet.readU16(offset)
      offset += 11
    of 0x03'u8:
      offset += 2
    of 0x04'u8:
      discard
    of 0x05'u8:
      offset += 5
    of 0x06'u8:
      offset += 3
    else:
      doAssert false, "unknown sprite protocol message"

echo "Testing default lifecycle config"
let lifecycleConfig = defaultSimConfig()
doAssert lifecycleConfig.planetCount == 47
doAssert lifecycleConfig.maxTicks == TargetFps * 60 * 5
doAssert lifecycleConfig.maxGames == 0

echo "Testing single player does not win before anyone is left"
var soloConfig = defaultSimConfig()
soloConfig.planetCount = 3
soloConfig.maxTicks = 0
var soloGame = initSimServer(123, soloConfig)
discard soloGame.addPlayer("solo")
soloGame.step([])
doAssert not soloGame.gameOver

echo "Testing remaining player wins with neutral planets ignored"
var remainingConfig = defaultSimConfig()
remainingConfig.planetCount = 4
remainingConfig.maxTicks = 0
var remainingGame = initSimServer(124, remainingConfig)
let
  winnerIndex = remainingGame.addPlayer("winner")
  loserIndex = remainingGame.addPlayer("loser")
  winnerId = remainingGame.players[winnerIndex].id
  loserId = remainingGame.players[loserIndex].id
remainingGame.step([])
doAssert not remainingGame.gameOver
for planet in remainingGame.planets.mitems:
  if planet.ownerId == loserId:
    planet.ownerId = 0
remainingGame.step([])
let remainingJson = parseJson(remainingGame.playerScoresJson())
doAssert remainingGame.gameOver
doAssert remainingGame.winnerPlayerId == winnerId
doAssert remainingJson["win"][winnerIndex].getBool()

echo "Testing in-flight ships keep a player active"
var shipConfig = defaultSimConfig()
shipConfig.planetCount = 4
shipConfig.maxTicks = 0
var shipGame = initSimServer(125, shipConfig)
let
  shipWinnerIndex = shipGame.addPlayer("winner")
  shipLoserIndex = shipGame.addPlayer("loser")
  shipWinnerId = shipGame.players[shipWinnerIndex].id
  shipLoserId = shipGame.players[shipLoserIndex].id
shipGame.step([])
for planet in shipGame.planets.mitems:
  if planet.ownerId == shipLoserId:
    planet.ownerId = 0
shipGame.ships.add Ship(
  ownerId: shipLoserId,
  targetPlanet: shipGame.planets[0].id,
  duration: 100
)
shipGame.step([])
doAssert not shipGame.gameOver
shipGame.ships.setLen(0)
shipGame.step([])
doAssert shipGame.gameOver
doAssert shipGame.winnerPlayerId == shipWinnerId

echo "Testing max ticks end"
var timedConfig = defaultSimConfig()
timedConfig.maxTicks = 3
timedConfig.maxGames = 0
var timedGame = initSimServer(456, timedConfig)
for _ in 0 ..< timedConfig.maxTicks:
  timedGame.step([])
doAssert timedGame.gameOver
doAssert timedGame.winnerPlayerId == 0

echo "Testing init packets clear stale objects"
var initGame = initSimServer(789, defaultSimConfig())
var nextState: GlobalViewerState
let initPacket = initGame.buildSpriteProtocolUpdates(
  initGlobalViewerState(),
  nextState
)
doAssert initPacket.len > 0
doAssert initPacket[0] == 0x04'u8

echo "Testing cursor chat bubbles render and expire"
var chatGame = initSimServer(790, defaultSimConfig())
let chatPlayerIndex = chatGame.addPlayer("speaker")
chatGame.addChatMessage(chatPlayerIndex, "hello")
doAssert chatGame.chatMessages.len == 1
var nextPlayerState: PlayerViewerState
let chatPacket = chatGame.buildSpriteProtocolPlayerUpdates(
  chatPlayerIndex,
  initPlayerViewerState(),
  nextPlayerState
)
doAssert chatPacket.len > 0
for _ in 0 ..< ChatBubbleTicks:
  chatGame.step([])
doAssert chatGame.chatMessages.len == 0

echo "Testing eliminated player cursor visibility"
var cursorConfig = defaultSimConfig()
cursorConfig.planetCount = 4
cursorConfig.maxTicks = 0
var cursorGame = initSimServer(791, cursorConfig)
let
  viewerIndex = cursorGame.addPlayer("viewer")
  hiddenIndex = cursorGame.addPlayer("hidden")
  viewerId = cursorGame.players[viewerIndex].id
  hiddenId = cursorGame.players[hiddenIndex].id
cursorGame.players[hiddenIndex].cursorX = cursorGame.players[viewerIndex].cursorX
cursorGame.players[hiddenIndex].cursorY = cursorGame.players[viewerIndex].cursorY
for planet in cursorGame.planets.mitems:
  if planet.ownerId == hiddenId:
    planet.ownerId = 0
var
  viewerState: PlayerViewerState
  hiddenState: PlayerViewerState
let
  hiddenCursorObjectId = 12000 + hiddenId
  viewerPacket = cursorGame.buildSpriteProtocolPlayerUpdates(
    viewerIndex,
    initPlayerViewerState(),
    viewerState
  )
  hiddenPacket = cursorGame.buildSpriteProtocolPlayerUpdates(
    hiddenIndex,
    initPlayerViewerState(),
    hiddenState
  )
doAssert cursorGame.countOwnedPlanets(hiddenId) == 0
doAssert cursorGame.countOwnedPlanets(viewerId) > 0
doAssert hiddenCursorObjectId notin viewerPacket.spritePacketObjectIds()
doAssert hiddenCursorObjectId in hiddenPacket.spritePacketObjectIds()

echo "Testing cursor accelerates over long holds"
var speedGame = initSimServer(792, cursorConfig)
let speedPlayerIndex = speedGame.addPlayer("speed")
speedGame.players[speedPlayerIndex].cursorX = WorldWidthPixels div 2
speedGame.players[speedPlayerIndex].cursorY = WorldHeightPixels div 2
for _ in 0 ..< TargetFps:
  speedGame.applyInput(speedPlayerIndex, PlayerInput(right: true))
doAssert speedGame.players[speedPlayerIndex].cursorVelX > CursorMaxSpeed
doAssert speedGame.players[speedPlayerIndex].cursorVelX <= CursorBoostMaxSpeed

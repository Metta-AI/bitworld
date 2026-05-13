import
  std/[json, os],
  ../global, ../sim

setCurrentDir(currentSourcePath().parentDir().parentDir())

echo "Testing default lifecycle config"
let lifecycleConfig = defaultSimConfig()
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

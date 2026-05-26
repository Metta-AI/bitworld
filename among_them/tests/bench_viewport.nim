import
  std/[os],
  benchy,
  bitworld/protocol,
  ../sim

const
  GameDir = currentSourcePath.parentDir.parentDir
  BenchPlayers = MaxPlayers
  BenchTasksPerPlayer = 8

var benchSink = 0

proc initAmongThemForBench(): SimServer =
  ## Initializes a playing Among Them simulation for viewport benchmarking.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var config = defaultGameConfig()
    config.minPlayers = BenchPlayers
    config.imposterCount = 2
    config.autoImposterCount = false
    config.roleRevealTicks = 0
    config.startWaitTicks = 0
    config.tasksPerPlayer = BenchTasksPerPlayer
    config.showTaskArrows = true
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

  for i in 0 ..< BenchPlayers:
    discard result.addPlayer("player" & $(i + 1))
  result.startGame()

proc printBenchSetup(sim: SimServer) =
  ## Prints the fixed simulation setup for this benchmark.
  let view = sim.playerView(0)
  echo "viewport bench setup:"
  echo "  players: ", sim.players.len
  echo "  tasks per player: ", BenchTasksPerPlayer
  echo "  map: ", sim.config.mapPath
  echo "  frame pixels: ", ScreenWidth, "x", ScreenHeight
  echo "  packed frame bytes: ", ProtocolBytes
  echo "  player 0 camera: ", view.cameraX, ",", view.cameraY
  echo "  player 0 origin: ", view.originMx, ",", view.originMy

proc frameChecksum(frame: openArray[uint8]): int =
  ## Returns a tiny checksum so render output cannot be optimized away.
  result = frame.len
  for i in countup(0, frame.high, 257):
    result = result xor (int(frame[i]) shl (i and 7))

var game = initAmongThemForBench()
let firstFrame = game.render(0)
doAssert firstFrame.len == ProtocolBytes
game.printBenchSetup()

timeIt "render one /player viewport":
  let frame = game.render(0)
  benchSink = benchSink xor frame.frameChecksum()

timeIt "render all /player viewports":
  var checksum = 0
  for i in 0 ..< game.players.len:
    checksum = checksum xor game.render(i).frameChecksum()
  benchSink = benchSink xor checksum

echo "bench sink: ", benchSink

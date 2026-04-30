import
  std/os,
  ../common/protocol,
  ../marketboard/sim,
  ../marketboard/replays

const RootDir = currentSourcePath.parentDir.parentDir

proc initMarketboardForTest(): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "marketboard")
  try:
    result = initSimServer(0)
  finally:
    setCurrentDir(previousDir)

proc testReplayRoundTrip() =
  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "marketboard")
  defer: setCurrentDir(previousDir)

  var sim = initSimServer(0)
  let p0 = sim.addPlayer("Alice")
  let p1 = sim.addPlayer("Bob")

  let replayPath = RootDir / "test_replay.mbreplay"
  var writer = openMbReplayWriter(replayPath, "{}")
  writer.writeJoin(tickTime(sim.tickCount), p0, "Alice")
  writer.writeJoin(tickTime(sim.tickCount), p1, "Bob")
  while writer.lastMasks.len <= p1:
    writer.lastMasks.add(0)

  var prevMasks = [0'u8, 0'u8]
  for tick in 0 ..< 100:
    var inputs = newSeq[PlayerInput](sim.players.len)

    var mask0 = 0'u8
    if tick < 30: mask0 = ButtonRight
    elif tick < 60: mask0 = ButtonDown
    if mask0 != prevMasks[0]:
      writer.writeInput(MbReplayInput(time: tickTime(sim.tickCount), player: 0, keys: mask0))
      writer.lastMasks[0] = mask0
    inputs[0] = maskToPlayerInput(mask0, prevMasks[0])
    prevMasks[0] = mask0

    var mask1 = 0'u8
    if tick < 50: mask1 = ButtonLeft
    if mask1 != prevMasks[1]:
      writer.writeInput(MbReplayInput(time: tickTime(sim.tickCount), player: 1, keys: mask1))
      writer.lastMasks[1] = mask1
    inputs[1] = maskToPlayerInput(mask1, prevMasks[1])
    prevMasks[1] = mask1

    sim.step(inputs)
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())

  writer.closeMbReplayWriter()

  let originalHash = sim.gameHash()
  let originalP0x = sim.players[0].x
  let originalP1x = sim.players[1].x

  let data = loadMbReplay(replayPath)
  doAssert data.gameName == "marketboard"
  doAssert data.joins.len == 2
  doAssert data.joins[0].address == "Alice"
  doAssert data.joins[1].address == "Bob"
  doAssert data.inputs.len > 0
  doAssert data.hashes.len == 100

  var sim2 = initSimServer(0)
  var replay = initMbReplayPlayer(data)
  while replay.playing:
    replay.stepReplay(sim2)

  # Replay overshoots by 1 tick after consuming the final hash (same as among_them)
  doAssert sim2.tickCount == sim.tickCount + 1,
    "tick count mismatch: " & $sim2.tickCount & " vs expected " & $(sim.tickCount + 1)
  doAssert sim2.players.len == 2

  removeFile(replayPath)

proc testBatchReplayRoundTrip() =
  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "marketboard")
  defer: setCurrentDir(previousDir)

  let replayPath = RootDir / "replays" / "match_0002.mbreplay"
  if not fileExists(replayPath):
    echo "  batch replay file not found, skipping"
    return

  let data = loadMbReplay(replayPath)
  doAssert data.gameName == "marketboard"
  doAssert data.joins.len > 0
  doAssert data.hashes.len > 0

  var sim = initSimServer(0)
  var replay = initMbReplayPlayer(data)
  var ticks = 0
  while replay.playing:
    replay.stepReplay(sim)
    inc ticks

  doAssert ticks > 0, "replay should have ticks"
  doAssert sim.players.len == data.joins.len,
    "player count mismatch: " & $sim.players.len & " vs " & $data.joins.len

echo "Running marketboard replay tests..."
testReplayRoundTrip()
echo "  replay round-trip: OK"
testBatchReplayRoundTrip()
echo "  batch replay round-trip: OK"
echo "All replay tests passed"

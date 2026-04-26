import
  std/os,
  ../common/protocol,
  ../among_them/sim

const RootDir = currentSourcePath.parentDir.parentDir

proc initAmongThemForTest(config: GameConfig): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "among_them")
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc unpackPackedFrame(packed: seq[uint8]): seq[uint8] =
  doAssert packed.len == ProtocolBytes, "packed frame size should match protocol"
  result = newSeq[uint8](ScreenWidth * ScreenHeight)
  for i, value in packed:
    result[i * 2] = value and 0x0f
    result[i * 2 + 1] = value shr 4

proc assertFrameMatchesDrawn(frame: seq[uint8], indices: seq[uint8], label: string) =
  let unpacked = frame.unpackPackedFrame()
  doAssert indices.len == unpacked.len, label & " index count should match"
  for i in 0 ..< unpacked.len:
    doAssert indices[i] == unpacked[i],
      label & " pixel " & $i & " should match draw-only output"

proc assertRenderMatchesDraw(sim: var SimServer, playerIndex: int, label: string) =
  let frame = sim.render(playerIndex)
  sim.drawObservation(playerIndex)
  assertFrameMatchesDrawn(frame, sim.fb.indices, label)

proc addPlayers(sim: var SimServer, count: int) =
  for i in 0 ..< count:
    discard sim.addPlayer("player" & $(i + 1))

proc initVotingState(sim: var SimServer) =
  let n = sim.players.len
  sim.phase = Voting
  sim.voteState.votes = newSeq[int](n)
  sim.voteState.cursor = newSeq[int](n)
  sim.voteState.voteTimer = sim.config.voteTimerTicks
  for i in 0 ..< n:
    sim.voteState.votes[i] = -1
    sim.voteState.cursor[i] = 0

proc testDrawObservationMatchesRender() =
  var lobbyConfig = defaultGameConfig()
  lobbyConfig.minPlayers = 3
  var lobbySim = initAmongThemForTest(lobbyConfig)
  lobbySim.addPlayers(2)
  lobbySim.assertRenderMatchesDraw(0, "lobby")

  var config = defaultGameConfig()
  config.minPlayers = 3
  config.tasksPerPlayer = 1
  var sim = initAmongThemForTest(config)
  sim.addPlayers(3)
  var inputs = newSeq[InputState](sim.players.len)
  sim.step(inputs, inputs)
  doAssert sim.phase == Playing, "test game should have entered play"

  sim.assertRenderMatchesDraw(0, "playing")

  sim.initVotingState()
  sim.assertRenderMatchesDraw(0, "voting")

  sim.phase = VoteResult
  sim.voteState.ejectedPlayer = -1
  sim.voteState.resultTimer = sim.config.voteResultTicks
  sim.assertRenderMatchesDraw(0, "vote result")

  sim.finishGame(Crewmate)
  sim.assertRenderMatchesDraw(0, "game over")

testDrawObservationMatchesRender()
echo "All tests passed"

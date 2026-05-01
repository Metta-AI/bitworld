import
  std/[os, unittest],
  ../../common/protocol,
  ../sim

const GameDir = currentSourcePath.parentDir.parentDir

proc initAmongThemForTest(config: GameConfig): SimServer =
  ## Initializes Among Them from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc unpackPackedFrame(packed: seq[uint8]): seq[uint8] =
  ## Unpacks one protocol frame into raw palette indices.
  require packed.len == ProtocolBytes
  result = newSeq[uint8](ScreenWidth * ScreenHeight)
  for i, value in packed:
    result[i * 2] = value and 0x0f
    result[i * 2 + 1] = value shr 4

proc assertFrameMatchesIndices(
  frame: seq[uint8],
  indices: seq[uint8],
  label: string
) =
  ## Checks that a packed render matches the framebuffer state.
  let unpacked = frame.unpackPackedFrame()
  checkpoint label
  require indices.len == unpacked.len
  for i in 0 ..< unpacked.len:
    checkpoint label & " pixel " & $i
    check indices[i] == unpacked[i]

proc assertRenderLeavesFramebuffer(
  sim: var SimServer,
  playerIndex: int,
  label: string
) =
  ## Checks that rendering leaves framebuffer indices matching output.
  let frame = sim.render(playerIndex)
  assertFrameMatchesIndices(frame, sim.fb.indices, label)

proc addPlayers(sim: var SimServer, count: int) =
  ## Adds test players to the simulation.
  for i in 0 ..< count:
    discard sim.addPlayer("player" & $(i + 1))

proc initVotingState(sim: var SimServer) =
  ## Initializes a minimal voting state.
  let n = sim.players.len
  sim.phase = Voting
  sim.voteState.votes = newSeq[int](n)
  sim.voteState.cursor = newSeq[int](n)
  sim.voteState.voteTimer = sim.config.voteTimerTicks
  for i in 0 ..< n:
    sim.voteState.votes[i] = -1
    sim.voteState.cursor[i] = 0

suite "render framebuffer":
  test "render leaves framebuffer matching output":
    var lobbyConfig = defaultGameConfig()
    lobbyConfig.minPlayers = 3
    var lobbySim = initAmongThemForTest(lobbyConfig)
    lobbySim.addPlayers(2)
    lobbySim.assertRenderLeavesFramebuffer(0, "lobby")

    var config = defaultGameConfig()
    config.minPlayers = 3
    config.imposterCount = 1
    config.autoImposterCount = false
    config.tasksPerPlayer = 1
    config.roleRevealTicks = 2
    config.startWaitTicks = 0
    var sim = initAmongThemForTest(config)
    sim.addPlayers(3)
    var inputs = newSeq[InputState](sim.players.len)
    sim.step(inputs, inputs)
    check sim.phase == RoleReveal
    sim.assertRenderLeavesFramebuffer(0, "role reveal")

    for _ in 0 ..< sim.config.roleRevealTicks:
      sim.step(inputs, inputs)
    check sim.phase == Playing

    sim.assertRenderLeavesFramebuffer(0, "playing")

    sim.initVotingState()
    sim.assertRenderLeavesFramebuffer(0, "voting")

    sim.phase = VoteResult
    sim.voteState.ejectedPlayer = -1
    sim.voteState.resultTimer = sim.config.voteResultTicks
    sim.assertRenderLeavesFramebuffer(0, "vote result")

    sim.finishGame(Crewmate)
    sim.assertRenderLeavesFramebuffer(0, "game over")

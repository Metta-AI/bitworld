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

proc addPlayers(sim: var SimServer, count: int) =
  ## Adds test players to the simulation.
  for _ in 0 ..< count:
    discard sim.addPlayer("player" & $(sim.players.len + 1))

proc countImposters(sim: SimServer): int =
  ## Counts impostors in the current player list.
  for player in sim.players:
    if player.role == Imposter:
      inc result

suite "start wait":
  test "default config":
    var config = defaultGameConfig()
    check config.startWaitTicks == 5 * TargetFps

    config.update("""{"startWaitTicks":7}""")
    check config.startWaitTicks == 7

    config.update("""{"gameStartWaitTicks":9}""")
    check config.startWaitTicks == 9

  test "late joiners count before game starts":
    var config = defaultGameConfig()
    config.minPlayers = 5
    config.roleRevealTicks = 0
    config.startWaitTicks = 3
    config.tasksPerPlayer = 1

    var sim = initAmongThemForTest(config)
    sim.addPlayers(5)

    var inputs = newSeq[InputState](sim.players.len)
    sim.step(inputs, inputs)
    check sim.phase == Lobby
    check sim.startWaitTimer == 2

    sim.addPlayers(2)
    inputs = newSeq[InputState](sim.players.len)
    sim.step(inputs, inputs)
    check sim.phase == Lobby
    check sim.players.len == 7

    sim.step(inputs, inputs)
    check sim.phase == Playing
    check sim.countImposters() == 2

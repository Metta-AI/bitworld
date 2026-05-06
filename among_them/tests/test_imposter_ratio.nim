import
  std/[os, unittest],
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
  for i in 0 ..< count:
    discard sim.addPlayer("player" & $(i + 1))

proc countImposters(sim: SimServer): int =
  ## Counts impostors in the current player list.
  for player in sim.players:
    if player.role == Imposter:
      inc result

suite "imposter ratio":
  test "default counts":
    let expected = [
      0, 0, 0, 0, 0, 1, 1, 2, 2,
      3, 3, 4, 4, 5, 5, 6, 6
    ]
    for count in 0 .. MaxPlayers:
      checkpoint "player count " & $count
      check ratioImposterCount(count) == expected[count]

  test "effective config":
    var config = defaultGameConfig()
    check config.autoImposterCount
    check config.effectiveImposterCount(9) == 3

    config.update("""{"imposterCount":2}""")
    check not config.autoImposterCount
    check config.effectiveImposterCount(9) == 2

    config.update("""{"autoImposterCount":true}""")
    check config.autoImposterCount
    check config.effectiveImposterCount(9) == 3

    config.update("""{"imposterCount":2,"imposterRatio":true}""")
    check config.autoImposterCount
    check config.effectiveImposterCount(9) == 3

    config.autoImposterCount = false
    config.imposterCount = 99
    check config.effectiveImposterCount(4) == 3

  test "start game uses auto ratio":
    var config = defaultGameConfig()
    config.minPlayers = 9
    config.roleRevealTicks = 0
    config.tasksPerPlayer = 1

    var sim = initAmongThemForTest(config)
    sim.addPlayers(9)
    sim.startGame()
    check sim.countImposters() == 3

  test "small games have no imposters":
    var config = defaultGameConfig()
    config.minPlayers = 4
    config.roleRevealTicks = 0
    config.tasksPerPlayer = 1

    var sim = initAmongThemForTest(config)
    sim.addPlayers(4)
    sim.startGame()
    check sim.countImposters() == 0
    sim.checkWinCondition()
    check sim.phase == Playing

  test "fixed count overrides ratio":
    var config = defaultGameConfig()
    config.minPlayers = 9
    config.imposterCount = 2
    config.autoImposterCount = false
    config.roleRevealTicks = 0
    config.tasksPerPlayer = 1

    var sim = initAmongThemForTest(config)
    sim.addPlayers(9)
    sim.startGame()
    check sim.countImposters() == 2

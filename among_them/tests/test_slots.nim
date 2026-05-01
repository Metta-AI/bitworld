import
  std/[json, os, unittest],
  ../replays,
  ../sim

const
  GameDir = currentSourcePath.parentDir.parentDir
  ExampleSlotsJson = """{"slots":[
    {"name":"player1","token":"0xBADA55_0","role":"crewmate","color":"red"},
    {"name":"player2","token":"0xBADA55_1","role":"crewmate","color":"blue"},
    {"name":"player3","token":"0xBADA55_2","role":"crewmate","color":"green"},
    {"name":"player4","token":"0xBADA55_3","role":"crewmate","color":"yellow"},
    {"name":"player5","token":"0xBADA55_4","role":"crewmate","color":"lime"},
    {"name":"player6","token":"0xBADA55_5","role":"crewmate","color":"cyan"},
    {"name":"player7","token":"0xBADA55_6","role":"imposter","color":"pink"},
    {"name":"player8","token":"0xBADA55_7","role":"imposter","color":"orange"}
  ]}"""

proc initAmongThemForTest(config: GameConfig): SimServer =
  ## Initializes Among Them from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc roleFor(sim: SimServer, address: string): PlayerRole =
  ## Returns the role for one test player address.
  for player in sim.players:
    if player.address == address:
      return player.role
  raise newException(AmongThemError, "Missing test player " & address & ".")

suite "player slots":
  test "config parses example slots":
    var config = defaultGameConfig()
    config.update(ExampleSlotsJson)

    check config.slots.len == 8
    check config.slots[0].name == "player1"
    check config.slots[0].token == "0xBADA55_0"
    check config.slots[0].hasRole
    check config.slots[0].role == Crewmate
    check config.slots[0].hasColor
    check config.slots[0].color == PlayerColors[0]
    check config.slots[5].hasColor
    check config.slots[5].color == PlayerColors[3]
    check config.slots[7].name == "player8"
    check config.slots[7].hasRole
    check config.slots[7].role == Imposter
    check config.slots[7].color == PlayerColors[1]

    let serialized = parseJson(config.configJson())
    check serialized["slots"].len == 8
    check serialized["slots"][5]["color"].getStr() == "light blue"

    var roundTrip = defaultGameConfig()
    roundTrip.update($serialized)
    check roundTrip.slots.len == 8
    check roundTrip.slots[7].role == Imposter
    check roundTrip.slots[7].color == PlayerColors[1]

  test "matching name and token assigns configured slot":
    var config = defaultGameConfig()
    config.update(ExampleSlotsJson)
    var sim = initAmongThemForTest(config)

    let playerIndex = sim.addPlayer("player7", -1, "0xBADA55_6")
    check sim.players[playerIndex].joinOrder == 6
    check sim.players[playerIndex].color == PlayerColors[4]

  test "trusted replay join uses configured name":
    var config = defaultGameConfig()
    config.update(ExampleSlotsJson)
    var sim = initAmongThemForTest(config)

    let playerIndex = sim.addPlayer("player8", trusted = true)
    check sim.players[playerIndex].joinOrder == 7
    check sim.players[playerIndex].color == PlayerColors[1]

  test "bad configured name or token is rejected":
    var config = defaultGameConfig()
    config.update(ExampleSlotsJson)
    var sim = initAmongThemForTest(config)

    expect AmongThemError:
      discard sim.addPlayer("player7", -1, "bad")
    expect AmongThemError:
      discard sim.addPlayer("intruder", -1, "0xBADA55_6")
    expect AmongThemError:
      discard sim.addPlayer("player7", 6, "bad")

  test "duplicate configured names and tokens are rejected":
    var config = defaultGameConfig()

    expect AmongThemError:
      config.update("""{"slots":[{"name":"same"},{"name":"same"}]}""")
    expect AmongThemError:
      config.update("""{"slots":[{"token":"same"},{"token":"same"}]}""")

  test "bad configured color is rejected":
    var config = defaultGameConfig()

    expect AmongThemError:
      config.update("""{"slots":[{"color":"ultraviolet"}]}""")

  test "duplicate player names are rejected":
    let config = defaultGameConfig()
    var sim = initAmongThemForTest(config)

    discard sim.addPlayer("same-name")
    expect AmongThemError:
      discard sim.addPlayer("same-name")

  test "replay join stores name slot and token":
    let path = getTempDir() / "among_them_slots_replay.bitreplay"
    if fileExists(path):
      removeFile(path)

    var writer = openReplayWriter(path, "{}")
    writer.writeJoin(12'u32, 0, "player1", -1, "")
    writer.writeJoin(24'u32, 1, "player2", 3, "0xBADA55")
    writer.closeReplayWriter()

    let data = parseReplayBytes(readFile(path))
    check data.joins.len == 2
    check data.joins[0].name == "player1"
    check data.joins[0].slot == -1
    check data.joins[0].token == ""
    check data.joins[1].name == "player2"
    check data.joins[1].slot == 3
    check data.joins[1].token == "0xBADA55"

    removeFile(path)

  test "automatic slots skip restricted slots":
    var config = defaultGameConfig()
    config.update("""{"slots":[{"name":"reserved","token":"secret"}]}""")
    var sim = initAmongThemForTest(config)

    let playerIndex = sim.addPlayer("open")
    check sim.players[playerIndex].joinOrder == 1

  test "manual slot preserves auto slot zero":
    let config = defaultGameConfig()
    var sim = initAmongThemForTest(config)

    let manualIndex = sim.addPlayer("manual", 5)
    let autoIndex = sim.addPlayer("auto")
    check sim.players[manualIndex].joinOrder == 5
    check sim.players[autoIndex].joinOrder == 0

  test "configured roles override random roles":
    var config = defaultGameConfig()
    config.minPlayers = 2
    config.roleRevealTicks = 0
    config.tasksPerPlayer = 1
    config.update("""{"slots":[
      {"name":"crew","token":"crew-token","role":"crewmate"},
      {"name":"imp","token":"imp-token","role":"imposter"}
    ]}""")
    var sim = initAmongThemForTest(config)

    discard sim.addPlayer("imp", -1, "imp-token")
    discard sim.addPlayer("crew", -1, "crew-token")
    sim.startGame()

    check sim.roleFor("imp") == Imposter
    check sim.roleFor("crew") == Crewmate

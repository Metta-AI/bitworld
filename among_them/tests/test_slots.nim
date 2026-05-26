import
  std/[json, os, unittest],
  ../replays,
  ../server,
  ../sim

const
  GameDir = currentSourcePath.parentDir.parentDir
  ExampleSlotsJson = """{"tokens":[
    "0xBADA55_0",
    "0xBADA55_1",
    "0xBADA55_2",
    "0xBADA55_3",
    "0xBADA55_4",
    "0xBADA55_5",
    "0xBADA55_6",
    "0xBADA55_7"
  ],"slots":[
    {"name":"player1","role":"crew","color":"red"},
    {"name":"player2","role":"crew","color":"blue"},
    {"name":"player3","role":"crew","color":"green"},
    {"name":"player4","role":"crew","color":"yellow"},
    {"name":"player5","role":"crew","color":"lime"},
    {"name":"player6","role":"crew","color":"cyan"},
    {"name":"player7","role":"imposter","color":"pink"},
    {"name":"player8","role":"imposter","color":"orange"}
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

proc addExamplePlayers(sim: var SimServer, count: int) =
  ## Adds configured example players from the first slot.
  for i in 0 ..< count:
    discard sim.addPlayer(
      "player" & $(i + 1),
      -1,
      "0xBADA55_" & $i
    )

suite "player slots":
  test "config parses example slots and tokens":
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
    check serialized["tokens"].len == 8
    check serialized["tokens"][6].getStr() == "0xBADA55_6"
    check serialized["slots"].len == 8
    check not serialized["slots"][6].hasKey("token")
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

    sim.addExamplePlayers(6)
    let playerIndex = sim.addPlayer("player7", -1, "0xBADA55_6")
    check sim.players[playerIndex].joinOrder == 6
    check sim.players[playerIndex].color == PlayerColors[4]

  test "trusted replay join uses configured name":
    var config = defaultGameConfig()
    config.update(ExampleSlotsJson)
    var sim = initAmongThemForTest(config)

    sim.addExamplePlayers(7)
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

  test "configured token can be checked before websocket upgrade":
    var config = defaultGameConfig()
    config.update("""{"tokens":["secret"]}""")

    check config.slots[0].name == ""
    check config.playerJoinAllowed("Ivotewell1", 0, "secret")
    check config.playerJoinAllowed("Player1", 0, "secret")
    check not config.playerJoinAllowed("Ivotewell1", 0, "bad")
    check not config.playerJoinAllowed("Player1", MaxPlayers, "secret")
    check config.configuredPlayerName(0, "secret") == ""
    check config.configuredPlayerName(-1, "secret") == ""

  test "closed rosters require named tokenized slots":
    var config = defaultGameConfig()
    config.minPlayers = 1
    config.update("""{"tokens":["secret"],"closedRoster":true}""")

    check config.slots[0].name == "Player1"
    check config.slots[0].token == "secret"
    check config.playerJoinAllowed("Player1", -1, "secret")
    check not config.playerJoinAllowed("Player1", -1, "bad")
    check not config.playerJoinAllowed("intruder", -1, "secret")
    check not config.playerJoinAllowed("extra", -1, "")

    var missingName = defaultGameConfig()
    missingName.minPlayers = 1
    expect AmongThemError:
      missingName.update("""{"slots":[{"token":"secret"}],"closedRoster":true}""")

    var missingToken = defaultGameConfig()
    missingToken.minPlayers = 1
    expect AmongThemError:
      missingToken.update("""{"slots":[{"name":"Player1"}],"closedRoster":true}""")

  test "duplicate configured names and tokens are rejected":
    var config = defaultGameConfig()

    expect AmongThemError:
      config.update("""{"slots":[{"name":"same"},{"name":"same"}]}""")
    expect AmongThemError:
      config.update("""{"slots":[{"token":"same"},{"token":"same"}]}""")
    expect AmongThemError:
      config.update("""{"tokens":["same","same"]}""")
    expect AmongThemError:
      config.update("""{"tokens":["new"],"slots":[{"token":"old"}]}""")

  test "bad configured color is rejected":
    var config = defaultGameConfig()

    expect AmongThemError:
      config.update("""{"slots":[{"color":"ultraviolet"}]}""")

  test "configured crew role must use canonical crew spelling":
    var config = defaultGameConfig()

    expect AmongThemError:
      config.update("""{"slots":[{"role":"crewmate"}]}""")

  test "duplicate player names are rejected":
    let config = defaultGameConfig()
    var sim = initAmongThemForTest(config)

    discard sim.addPlayer("same-name")
    expect AmongThemError:
      discard sim.addPlayer("same-name")

  test "anonymous player names are unique":
    var nextIndex = 1

    check anonymousPlayerIdentity(nextIndex, []) == "Player1"
    check anonymousPlayerIdentity(nextIndex, ["Player2"]) == "Player3"
    check nextIndex == 4

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

  test "replay records chat packets":
    let path = getTempDir() / "among_them_chat_replay.bitreplay"
    if fileExists(path):
      removeFile(path)

    var writer = openReplayWriter(path, "{}")
    writer.writeChat(36'u32, 2, "body in Nav sus yellow")
    writer.closeReplayWriter()

    let data = parseReplayBytes(readFile(path))
    check data.chats.len == 1
    check data.chats[0].time == 36'u32
    check data.chats[0].player == 2'u8
    check data.chats[0].message == "body in Nav sus yellow"

    removeFile(path)

  test "automatic slots wait behind restricted slots":
    var config = defaultGameConfig()
    config.update("""{"slots":[{"name":"reserved","token":"secret"}]}""")
    var sim = initAmongThemForTest(config)

    expect AmongThemError:
      discard sim.addPlayer("open")
    let reservedIndex = sim.addPlayer("reserved", -1, "secret")
    let playerIndex = sim.addPlayer("open")
    check sim.players[reservedIndex].joinOrder == 0
    check sim.players[playerIndex].joinOrder == 1

  test "automatic slots stay open for configured rosters by default":
    var config = defaultGameConfig()
    config.minPlayers = 2
    config.update("""{"tokens":["crew-token","imp-token"]}""")
    var sim = initAmongThemForTest(config)

    discard sim.addPlayer("Player1", -1, "crew-token")
    discard sim.addPlayer("Player2", -1, "imp-token")
    let extraIndex = sim.addPlayer("extra")
    check sim.players[extraIndex].joinOrder == 2

  test "automatic slots stop at an explicitly closed configured roster":
    var config = defaultGameConfig()
    config.minPlayers = 2
    config.update("""{"tokens":["crew-token","imp-token"],"closedRoster":true}""")
    var sim = initAmongThemForTest(config)

    discard sim.addPlayer("Player1", -1, "crew-token")
    discard sim.addPlayer("Player2", -1, "imp-token")
    check not sim.canAddPlayer()
    expect AmongThemError:
      discard sim.addPlayer("extra")

  test "closed configured roster rejects explicit slots outside roster":
    var config = defaultGameConfig()
    config.minPlayers = 2
    config.update("""{"tokens":["crew-token","imp-token"],"closedRoster":true}""")
    var sim = initAmongThemForTest(config)

    check not config.playerJoinAllowed("extra", 2, "")
    expect AmongThemError:
      discard sim.addPlayer("extra", 2)

  test "manual slot must match next player index":
    let config = defaultGameConfig()
    var sim = initAmongThemForTest(config)

    expect AmongThemError:
      discard sim.addPlayer("manual", 5)
    let manualIndex = sim.addPlayer("manual", 0)
    let autoIndex = sim.addPlayer("auto")
    check sim.players[manualIndex].joinOrder == 0
    check sim.players[autoIndex].joinOrder == 1

  test "configured roles override random roles":
    var config = defaultGameConfig()
    config.minPlayers = 2
    config.roleRevealTicks = 0
    config.tasksPerPlayer = 1
    config.update("""{"slots":[
      {"name":"crew","token":"crew-token","role":"crew"},
      {"name":"imp","token":"imp-token","role":"imposter"}
    ]}""")
    var sim = initAmongThemForTest(config)

    discard sim.addPlayer("crew", -1, "crew-token")
    discard sim.addPlayer("imp", -1, "imp-token")
    sim.startGame()

    check sim.roleFor("imp") == Imposter
    check sim.roleFor("crew") == Crewmate

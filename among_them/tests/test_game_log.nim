import
  std/[json, os, strutils, unittest],
  ../sim,
  ../game_log

const GameDir = currentSourcePath.parentDir.parentDir

proc initAmongThemForTest(config: GameConfig): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc makeTestSim(): SimServer =
  var config = defaultGameConfig()
  config.minPlayers = 3
  config.imposterCount = 1
  config.autoImposterCount = false
  config.tasksPerPlayer = 1
  config.roleRevealTicks = 0
  config.startWaitTicks = 0
  config.slots = @[
    PlayerSlotConfig(name: "imp", role: Imposter, hasRole: true),
    PlayerSlotConfig(name: "crew1", role: Crewmate, hasRole: true),
    PlayerSlotConfig(name: "crew2", role: Crewmate, hasRole: true),
  ]
  result = initAmongThemForTest(config)
  discard result.addPlayer("imp", 0)
  discard result.addPlayer("crew1", 1)
  discard result.addPlayer("crew2", 2)
  result.startGame()

suite "game log":
  test "phase name covers every game phase":
    check phaseLogName(Lobby) == "lobby"
    check phaseLogName(RoleReveal) == "role_reveal"
    check phaseLogName(Playing) == "playing"
    check phaseLogName(Voting) == "voting"
    check phaseLogName(VoteResult) == "vote_result"
    check phaseLogName(GameOver) == "game_over"

  test "tick line is one line of valid JSON":
    let sim = makeTestSim()
    let line = buildTickLogLine(sim)
    check '\n' notin line
    let parsed = parseJson(line)
    check parsed.kind == JObject
    check parsed.hasKey("t")
    check parsed.hasKey("phase")
    check parsed.hasKey("players")

  test "playing phase records all required agent fields":
    let sim = makeTestSim()
    let parsed = parseJson(buildTickLogLine(sim))
    check parsed["phase"].getStr() == "playing"
    let players = parsed["players"]
    check players.len == 3
    for entry in players:
      check entry.hasKey("i")
      check entry.hasKey("name")
      check entry.hasKey("x")
      check entry.hasKey("y")
      check entry.hasKey("room")
      check entry.hasKey("alive")
      check entry.hasKey("role")
      check entry.hasKey("tasks")
      check entry["alive"].getBool()
      let role = entry["role"].getStr()
      check role in ["crew", "imposter"]
      if role == "imposter":
        check entry.hasKey("kill_cd")
        check entry.hasKey("kill_ready")
      else:
        check not entry.hasKey("kill_cd")

  test "imposter kill cooldown surfaces accurately":
    var sim = makeTestSim()
    var impIndex = -1
    for i in 0 ..< sim.players.len:
      if sim.players[i].role == Imposter:
        impIndex = i
    require impIndex >= 0
    sim.players[impIndex].killCooldown = 0
    let readyLine = parseJson(buildTickLogLine(sim))
    check readyLine["players"][impIndex]["kill_ready"].getBool()
    check readyLine["players"][impIndex]["kill_cd"].getInt() == 0

    sim.players[impIndex].killCooldown = 42
    let coolingLine = parseJson(buildTickLogLine(sim))
    check not coolingLine["players"][impIndex]["kill_ready"].getBool()
    check coolingLine["players"][impIndex]["kill_cd"].getInt() == 42

  test "dead player is reflected in the log":
    var sim = makeTestSim()
    sim.players[1].alive = false
    let parsed = parseJson(buildTickLogLine(sim))
    check not parsed["players"][1]["alive"].getBool()

  test "lobby phase before startGame has no players":
    var config = defaultGameConfig()
    config.minPlayers = 3
    config.startWaitTicks = 0
    var sim = initAmongThemForTest(config)
    let parsed = parseJson(buildTickLogLine(sim))
    check parsed["phase"].getStr() == "lobby"
    check parsed["players"].len == 0
    check parsed["num_players"].getInt() == 0

  test "game over phase records winner":
    var sim = makeTestSim()
    sim.finishGame(Crewmate)
    let parsed = parseJson(buildTickLogLine(sim))
    check parsed["phase"].getStr() == "game_over"
    check parsed["winner"].getStr() == "crew"

  test "tasks include name and per-player completion":
    var sim = makeTestSim()
    let taskIndex = sim.players[1].assignedTasks[0]
    check sim.tasks[taskIndex].name.len > 0
    sim.completeTask(1, taskIndex)
    let parsed = parseJson(buildTickLogLine(sim))
    let p1Tasks = parsed["players"][1]["tasks"]
    check p1Tasks.len == 1
    check p1Tasks[0]["i"].getInt() == taskIndex
    check p1Tasks[0]["name"].getStr() == sim.tasks[taskIndex].name
    check p1Tasks[0]["done"].getBool()

  test "file sink writes newline-terminated lines":
    let tmpPath = getTempDir() / "among_them_test_log_" & $getCurrentProcessId() & ".jsonl"
    if fileExists(tmpPath):
      removeFile(tmpPath)
    let sink = openGameLogSink(tmpPath)
    check sink.enabled
    check sink.kind == glsFile
    sink.writeGameLogLine("""{"t":1}""")
    sink.writeGameLogLine("""{"t":2}""")
    sink.flushGameLogSink()
    sink.closeGameLogSink()
    let contents = readFile(tmpPath)
    let lines = contents.strip().splitLines()
    check lines.len == 2
    check parseJson(lines[0])["t"].getInt() == 1
    check parseJson(lines[1])["t"].getInt() == 2
    removeFile(tmpPath)

  test "empty uri falls back to stdout":
    let sink = openGameLogSink("")
    check sink.enabled
    check sink.kind == glsStdout
    sink.flushGameLogSink()
    sink.closeGameLogSink()
    check sink.kind == glsDisabled

  test "disabled sink ignores all writes":
    let sink = disabledGameLogSink()
    check not sink.enabled
    check sink.kind == glsDisabled
    sink.writeGameLogLine("ignored")
    sink.flushGameLogSink()
    sink.closeGameLogSink()
    check sink.kind == glsDisabled

  test "file:// uri is honored":
    let tmpPath = getTempDir() / "among_them_test_log_uri_" & $getCurrentProcessId() & ".jsonl"
    if fileExists(tmpPath):
      removeFile(tmpPath)
    let sink = openGameLogSink("file://" & tmpPath)
    check sink.enabled
    check sink.kind == glsFile
    check sink.filePath == tmpPath
    sink.writeGameLogLine("""{"hello":"world"}""")
    sink.closeGameLogSink()
    check fileExists(tmpPath)
    let contents = readFile(tmpPath)
    check contents.contains("hello")
    removeFile(tmpPath)

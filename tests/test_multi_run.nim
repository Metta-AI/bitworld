import
  std/[json, os, tables, times],
  bitworld/multiruns

proc tempRoot(name: string): string =
  ## Builds a unique temporary test directory path.
  getTempDir() / (name & "_" & $getTime().toUnix() & "_" & $getCurrentProcessId())

proc sampleManifest(path: string, withRole: bool) =
  ## Writes a small Coworld manifest for config and role tests.
  let
    root = newJObject()
    game = newJObject()
    runnable = newJObject()
    schema = newJObject()
    properties = newJObject()
    slots = newJObject()
    items = newJObject()
    slotProperties = newJObject()
    role = newJObject()
    roleEnum = newJArray()
    closedRoster = newJObject()
    minPlayers = newJObject()
    maxGames = newJObject()
    imposterCount = newJObject()
    autoImposterCount = newJObject()
  runnable["image"] = %"example/game:latest"
  runnable["run"] = %["/bin/game"]
  game["name"] = %"crewrift"
  game["owner"] = %"treeform@softmax.com"
  game["runnable"] = runnable
  minPlayers["default"] = %8
  maxGames["default"] = %0
  imposterCount["default"] = %2
  autoImposterCount["default"] = %true
  closedRoster["default"] = %false
  properties["minPlayers"] = minPlayers
  properties["maxGames"] = maxGames
  properties["imposterCount"] = imposterCount
  properties["autoImposterCount"] = autoImposterCount
  properties["closedRoster"] = closedRoster
  if withRole:
    roleEnum.add(%"crew")
    roleEnum.add(%"imposter")
    role["enum"] = roleEnum
    slotProperties["role"] = role
    items["properties"] = slotProperties
    slots["items"] = items
    properties["slots"] = slots
  schema["properties"] = properties
  game["config_schema"] = schema
  root["game"] = game
  writeFile(path, $root)

proc samplePlayersManifest(path: string) =
  ## Writes a Coworld manifest using separate players and slots arrays.
  let
    root = newJObject()
    game = newJObject()
    runnable = newJObject()
    schema = newJObject()
    properties = newJObject()
    tokens = newJObject()
    players = newJObject()
    playerItems = newJObject()
    playerProperties = newJObject()
    playerName = newJObject()
    slots = newJObject()
    slotItems = newJObject()
    slotProperties = newJObject()
    token = newJObject()
    role = newJObject()
    roleEnum = newJArray()
    closedRoster = newJObject()
  runnable["image"] = %"example/game:latest"
  runnable["run"] = %["/bin/game"]
  game["name"] = %"crewrift"
  game["owner"] = %"treeform@softmax.com"
  game["runnable"] = runnable
  tokens["type"] = %"array"
  closedRoster["default"] = %false
  playerName["type"] = %"string"
  playerProperties["name"] = playerName
  playerItems["type"] = %"object"
  playerItems["properties"] = playerProperties
  players["type"] = %"array"
  players["items"] = playerItems
  token["type"] = %"string"
  roleEnum.add(%"crew")
  roleEnum.add(%"imposter")
  role["enum"] = roleEnum
  slotProperties["token"] = token
  slotProperties["role"] = role
  slotItems["type"] = %"object"
  slotItems["additionalProperties"] = %false
  slotItems["properties"] = slotProperties
  slots["type"] = %"array"
  slots["items"] = slotItems
  properties["tokens"] = tokens
  properties["players"] = players
  properties["slots"] = slots
  properties["closedRoster"] = closedRoster
  schema["properties"] = properties
  game["config_schema"] = schema
  root["game"] = game
  writeFile(path, $root)

proc hasArg(args: openArray[string], value: string): bool =
  ## Returns true when an argument list contains one exact value.
  for arg in args:
    if arg == value:
      return true

proc closeEnough(a, b: float): bool =
  ## Returns true when two floats are close enough for score tests.
  abs(a - b) < 0.0001

proc testBotParsing() =
  ## Checks BOT:N and BOT:N:ROLE parsing.
  let plain = parseBotGroup("notsus:8")
  doAssert plain.name == "notsus"
  doAssert plain.count == 8
  doAssert plain.role == ""
  let role = parseBotGroup("notsus:6:crew")
  doAssert role.name == "notsus"
  doAssert role.count == 6
  doAssert role.role == "crew"
  var failed = false
  try:
    discard parseBotGroup("notsus")
  except MultiRunError:
    failed = true
  doAssert failed

proc testStablePlayerNames() =
  ## Checks visible player names stay stable between games.
  let launches = @[
    BotLaunch(
      player: PlayerManifest(name: "notsus"),
      count: 3
    ),
    BotLaunch(
      player: PlayerManifest(name: "truecrew"),
      count: 1
    )
  ]
  let
    firstGame = buildSlots("run_000001", 1, launches)
    hundredthGame = buildSlots("run_000001", 100, launches)
  doAssert firstGame[0].playerName == "notsus-1"
  doAssert firstGame[1].playerName == "notsus-2"
  doAssert firstGame[2].playerName == "notsus-3"
  doAssert firstGame[3].playerName == "truecrew-4"
  doAssert hundredthGame[0].playerName == "notsus-1"
  doAssert hundredthGame[2].playerName == "notsus-3"

proc testRunAllocation() =
  ## Checks generated run id increments.
  let root = tempRoot("multi_run_ids")
  createDir(root)
  createDir(root / "run_000001")
  createDir(root / "run_000009")
  doAssert nextRunName(root) == "run_000010"
  removeDir(root)

proc testQueueCounts() =
  ## Checks bounded queue accounting.
  let counts = queueCounts(50, 22, 5, 17, 0)
  doAssert counts.running == 5
  doAssert counts.finished == 17
  doAssert counts.queued == 28

proc testConfigAndRoles() =
  ## Checks role validation and generated fixed-roster config.
  let root = tempRoot("multi_run_config")
  createDir(root)
  let manifest = root / "coworld_manifest.json"
  sampleManifest(manifest, true)
  let groups = @[
    parseBotGroup("notsus:1:crew"),
    parseBotGroup("truecrew:1:imposter")
  ]
  validateRoles(manifest, groups)
  var failed = false
  try:
    validateRoles(manifest, @[parseBotGroup("notsus:1:detective")])
  except MultiRunError:
    failed = true
  doAssert failed
  let slots = @[
    PlayerSlot(
      player: "notsus",
      playerName: "notsus-1",
      role: "crew",
      slotIndex: 0,
      token: "tok1"
    ),
    PlayerSlot(
      player: "truecrew",
      playerName: "truecrew-2",
      role: "imposter",
      slotIndex: 1,
      token: "tok2"
    )
  ]
  let config = parseJson(buildGameConfigJson(manifest, slots))
  doAssert config["minPlayers"].getInt() == 2
  doAssert config["maxGames"].getInt() == 1
  doAssert config["imposterCount"].getInt() == 1
  doAssert config["autoImposterCount"].getBool() == false
  doAssert config["tokens"].len == 2
  doAssert config["closedRoster"].getBool() == true
  doAssert config["slots"][0]["role"].getStr() == "crew"
  let noRoleManifest = root / "no_role.json"
  sampleManifest(noRoleManifest, false)
  failed = false
  try:
    validateRoles(noRoleManifest, groups)
  except MultiRunError:
    failed = true
  doAssert failed
  let playersManifest = root / "players_manifest.json"
  samplePlayersManifest(playersManifest)
  validateRoles(playersManifest, groups)
  let playerConfig = parseJson(buildGameConfigJson(playersManifest, slots))
  doAssert playerConfig["players"].len == 2
  doAssert playerConfig["closedRoster"].getBool() == true
  doAssert playerConfig["players"][0]["name"].getStr() == "notsus-1"
  doAssert playerConfig["slots"][0].hasKey("token")
  doAssert not playerConfig["slots"][0].hasKey("name")
  doAssert playerConfig["slots"][0]["role"].getStr() == "crew"
  removeDir(root)

proc testReplayDockerArgs() =
  ## Checks replay-server launch arguments.
  let root = tempRoot("multi_run_replay")
  createDir(root)
  let manifest = root / "coworld_manifest.json"
  sampleManifest(manifest, false)
  let game = readGameManifest(manifest)
  let meta = GameMeta(
    runId: "run_000001",
    gameIndex: 1,
    gameName: "crewrift",
    replay: "multi_runs/run_000001/game_0001.bitreplay",
    results: "multi_runs/run_000001/game_0001.scores.json",
    config: "multi_runs/run_000001/game_0001.config.json"
  )
  let args = replayDockerArgs(root, game, meta, 2345, 42)
  doAssert args.hasArg(KindLabel & "=" & ReplayKind)
  doAssert args.hasArg(PortLabel & "=2345")
  doAssert args.hasArg(root & ":" & ContainerReplayDir & ":ro")
  doAssert args.hasArg(
    CogameLoadReplayUriEnv & "=file://" &
      (ContainerReplayDir / "game_0001.bitreplay")
  )
  doAssert args.hasArg("example/game:latest")
  removeDir(root)

proc testGameScoreAverages() =
  ## Checks per-game score averages by player kind.
  let root = tempRoot("multi_run_game_scores")
  createDir(root)
  let meta = GameMeta(
    runId: "run_000001",
    gameIndex: 1,
    gameName: "crewrift",
    containerName: "game",
    status: "finished",
    results: "multi_runs/run_000001/game_0001.scores.json",
    slots: @[
      PlayerSlot(
        player: "notsus",
        playerName: "notsus-1",
        slotIndex: 0
      ),
      PlayerSlot(
        player: "notsus",
        playerName: "notsus-2",
        slotIndex: 1
      ),
      PlayerSlot(
        player: "truecrew",
        playerName: "truecrew-3",
        slotIndex: 2
      )
    ]
  )
  let scores = %*{
    "names": ["notsus-1", "notsus-2", "truecrew-3"],
    "scores": [10.0, 14.0, 4.0]
  }
  writeFile(root / "game_0001.scores.json", $scores)
  let averages = averageGameScores(root, meta)
  doAssert averages.hasKey("notsus")
  doAssert averages.hasKey("truecrew")
  doAssert closeEnough(averages["notsus"], 12.0)
  doAssert closeEnough(averages["truecrew"], 4.0)
  removeDir(root)

proc testScoreHistograms() =
  ## Checks raw score histogram buckets by player kind.
  let root = tempRoot("multi_run_histograms")
  createDir(root)
  let meta = GameMeta(
    runId: "run_000001",
    gameIndex: 1,
    gameName: "crewrift",
    containerName: "game",
    status: "finished",
    results: "multi_runs/run_000001/game_0001.scores.json",
    slots: @[
      PlayerSlot(
        player: "notsus",
        playerName: "notsus-1",
        slotIndex: 0
      ),
      PlayerSlot(
        player: "notsus",
        playerName: "notsus-2",
        slotIndex: 1
      ),
      PlayerSlot(
        player: "truecrew",
        playerName: "truecrew-3",
        slotIndex: 2
      ),
      PlayerSlot(
        player: "truecrew",
        playerName: "truecrew-4",
        slotIndex: 3
      )
    ]
  )
  writeGameMeta(root, meta)
  let scores = %*{
    "names": [
      "notsus-1",
      "notsus-2",
      "truecrew-3",
      "truecrew-4"
    ],
    "scores": [-11.0, -1.0, 10.0, 129.0]
  }
  writeFile(root / "game_0001.scores.json", $scores)
  let
    labels = scoreHistogramLabels(-20, 120)
    histograms = runScoreHistograms(root)
  doAssert scoreBucketStart(-11.0) == -20
  doAssert scoreBucketStart(-1.0) == -10
  doAssert scoreBucketIndex(10.0, -20) == 3
  doAssert labels.len == 15
  doAssert labels[0] == "-20"
  doAssert labels[2] == "0"
  doAssert labels[14] == "120"
  doAssert histograms.len == 2
  doAssert histograms[0].player == "notsus"
  doAssert histograms[0].bucketMin == -20
  doAssert histograms[0].total == 2
  doAssert histograms[0].bins[0] == 1
  doAssert histograms[0].bins[1] == 1
  doAssert histograms[1].player == "truecrew"
  doAssert histograms[1].bucketMin == -20
  doAssert histograms[1].total == 2
  doAssert histograms[1].bins[3] == 1
  doAssert histograms[1].bins[14] == 1
  removeDir(root)

proc testScoreFilters() =
  ## Checks score row filtering and filtered aggregates.
  let root = tempRoot("multi_run_filters")
  createDir(root)
  let meta1 = GameMeta(
    runId: "run_000001",
    gameIndex: 1,
    gameName: "crewrift",
    containerName: "game",
    status: "finished",
    results: "multi_runs/run_000001/game_0001.scores.json",
    slots: @[
      PlayerSlot(
        player: "notsus",
        playerName: "notsus-1",
        role: "crew",
        slotIndex: 0
      ),
      PlayerSlot(
        player: "truecrew",
        playerName: "truecrew-2",
        role: "imposter",
        slotIndex: 1
      )
    ]
  )
  let meta2 = GameMeta(
    runId: "run_000001",
    gameIndex: 2,
    gameName: "crewrift",
    containerName: "game",
    status: "finished",
    results: "multi_runs/run_000001/game_0002.scores.json",
    slots: @[
      PlayerSlot(
        player: "notsus",
        playerName: "notsus-1",
        role: "crew",
        slotIndex: 0
      ),
      PlayerSlot(
        player: "truecrew",
        playerName: "truecrew-2",
        role: "imposter",
        slotIndex: 1
      )
    ]
  )
  writeGameMeta(root, meta1)
  writeGameMeta(root, meta2)
  let scores1 = %*{
    "names": ["notsus-1", "truecrew-2"],
    "scores": [10.0, 4.0],
    "win": [true, false],
    "tasks": [3, 1],
    "kills": [0, 1],
    "imposter": [0, 1],
    "crew": [1, 0],
    "vote_players": [2, 1],
    "vote_skip": [0, 1],
    "vote_timeout": [0, 0],
    "connect_timeout": [0, 5],
    "disconnect_timeout": [0, 0]
  }
  let scores2 = %*{
    "names": ["notsus-1", "truecrew-2"],
    "scores": [13.0, 2.0],
    "win": [true, false],
    "tasks": [5, 1],
    "kills": [0, 1],
    "imposter": [0, 1],
    "crew": [1, 0],
    "vote_players": [1, 0],
    "vote_skip": [0, 0],
    "vote_timeout": [1, 0],
    "connect_timeout": [2, 5],
    "disconnect_timeout": [1, 0]
  }
  writeFile(root / "game_0001.scores.json", $scores1)
  writeFile(root / "game_0002.scores.json", $scores2)
  let parsed = parseScores(root / "game_0002.scores.json")
  doAssert parsed[0].scoreNumberFieldExists("connect_timeout")
  doAssert closeEnough(parsed[0].scoreNumberFieldValue("connect_timeout"), 2)
  doAssert "disconnect_timeout" in scoreNumberFieldNames(parsed)
  var filter: ScoreFilter
  filter.players = @["notsus"]
  filter.tasks.hasMin = true
  filter.tasks.minValue = 4
  let records = filteredScoreRecords(root, filter)
  doAssert scoreFilterActive(filter)
  doAssert records.len == 1
  doAssert records[0].gameIndex == 2
  doAssert records[0].player == "notsus"
  let averages = averageGameScores(records, 2)
  doAssert averages.hasKey("notsus")
  doAssert not averages.hasKey("truecrew")
  doAssert closeEnough(averages["notsus"], 13.0)
  let aggregate = aggregateRunScores(root, filter)
  doAssert aggregate.len == 1
  doAssert aggregate[0].player == "notsus"
  doAssert aggregate[0].games == 1
  doAssert aggregate[0].tasksSum == 5
  doAssert closeEnough(
    aggregate[0].scoreNumberAverage("connect_timeout"),
    2
  )
  var customFilter: ScoreFilter
  customFilter.players = @["notsus"]
  customFilter.setScoreFilterNumberRange(
    "connect_timeout",
    ScoreRange(hasMin: true, minValue: 2)
  )
  let customRecords = filteredScoreRecords(root, customFilter)
  doAssert customRecords.len == 1
  doAssert customRecords[0].gameIndex == 2
  var winFilter: ScoreFilter
  winFilter.wins = @["false"]
  doAssert filteredScoreRecords(root, winFilter).len == 2
  removeDir(root)

proc testLabelParsing() =
  ## Checks Docker inspect label parsing.
  let line = "/multi_run_run_000001_game_1\trunning\t0\tgame\trun_000001\t" &
    "2\tcrewrift\t0\tnotsus\tcrew\t" &
    "multi_runs/run_000001/game_0002.bitreplay\t" &
    "multi_runs/run_000001/game_0002.scores.json\t" &
    "multi_runs/run_000001/game_0002.config.json\t2345\t42\t1"
  let info = inspectLine(line)
  doAssert info.name == "multi_run_run_000001_game_1"
  doAssert info.status == "running"
  doAssert info.kind == "game"
  doAssert info.runId == "run_000001"
  doAssert info.gameIndex == 2
  doAssert info.role == "crew"
  doAssert info.port == 2345

proc testScoreAggregation() =
  ## Checks durable score aggregation through game metadata.
  let root = tempRoot("multi_run_scores")
  createDir(root)
  let meta1 = GameMeta(
    runId: "run_000001",
    gameIndex: 1,
    gameName: "crewrift",
    containerName: "game",
    status: "finished",
    results: "multi_runs/run_000001/game_0001.scores.json",
    slots: @[
      PlayerSlot(
        player: "notsus",
        playerName: "notsus-1",
        role: "crew",
        slotIndex: 0
      ),
      PlayerSlot(
        player: "truecrew",
        playerName: "truecrew-2",
        role: "imposter",
        slotIndex: 1
      )
    ]
  )
  let meta2 = GameMeta(
    runId: "run_000001",
    gameIndex: 2,
    gameName: "crewrift",
    containerName: "game",
    status: "finished",
    results: "multi_runs/run_000001/game_0002.scores.json",
    slots: @[
      PlayerSlot(
        player: "notsus",
        playerName: "notsus-1",
        role: "crew",
        slotIndex: 0
      ),
      PlayerSlot(
        player: "truecrew",
        playerName: "truecrew-2",
        role: "imposter",
        slotIndex: 1
      )
    ]
  )
  writeGameMeta(root, meta1)
  writeGameMeta(root, meta2)
  let scores1 = %*{
    "names": ["notsus-1", "truecrew-2"],
    "scores": [10.5, 4.0],
    "win": [true, false],
    "tasks": [3, 1],
    "kills": [0, 1],
    "imposter": [0, 1],
    "crew": [1, 0],
    "vote_players": [2, 1],
    "vote_skip": [0, 1],
    "vote_timeout": [0, 0],
    "connect_timeout": [1, 0],
    "disconnect_timeout": [0, 1]
  }
  let scores2 = %*{
    "names": ["notsus-1", "truecrew-2"],
    "scores": [13.5, 2.0],
    "win": [true, false],
    "tasks": [5, 1],
    "kills": [0, 1],
    "imposter": [0, 1],
    "crew": [1, 0],
    "vote_players": [1, 0],
    "vote_skip": [0, 0],
    "vote_timeout": [1, 0],
    "connect_timeout": [3, 0],
    "disconnect_timeout": [2, 1]
  }
  writeFile(root / "game_0001.scores.json", $scores1)
  writeFile(root / "game_0002.scores.json", $scores2)
  let records = scoreRecords(root)
  doAssert "connect_timeout" in scoreNumberFieldNames(records)
  doAssert "disconnect_timeout" in scoreNumberFieldNames(records)
  let aggregate = aggregateRunScores(root)
  doAssert aggregate.len == 2
  doAssert aggregate[0].player == "notsus"
  doAssert aggregate[0].games == 2
  doAssert aggregate[0].wins == 2
  doAssert aggregate[0].tasksSum == 8
  doAssert closeEnough(aggregate[0].scoreAverage(), 12.0)
  doAssert closeEnough(aggregate[0].scoreStdDev(), 1.5)
  doAssert closeEnough(aggregate[0].scoreMin, 10.5)
  doAssert closeEnough(aggregate[0].scoreMax, 13.5)
  doAssert closeEnough(
    aggregate[0].scoreNumberAverage("connect_timeout"),
    2
  )
  doAssert closeEnough(
    aggregate[0].scoreNumberAverage("disconnect_timeout"),
    1
  )
  removeDir(root)

echo "Testing multi-run bot parsing"
testBotParsing()
echo "Testing multi-run stable player names"
testStablePlayerNames()
echo "Testing multi-run run allocation"
testRunAllocation()
echo "Testing multi-run queue counts"
testQueueCounts()
echo "Testing multi-run config and roles"
testConfigAndRoles()
echo "Testing multi-run replay Docker args"
testReplayDockerArgs()
echo "Testing multi-run per-game score averages"
testGameScoreAverages()
echo "Testing multi-run score histograms"
testScoreHistograms()
echo "Testing multi-run score filters"
testScoreFilters()
echo "Testing multi-run label parsing"
testLabelParsing()
echo "Testing multi-run score aggregation"
testScoreAggregation()
echo "Multi-run tests passed"

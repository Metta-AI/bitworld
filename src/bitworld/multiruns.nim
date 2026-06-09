import
  std/[algorithm, httpclient, json, math, net, os, osproc, strutils, sysrand,
    tables, times]

const
  MultiRunLabelPrefix* = "bitworld.multi_run"
  OwnerLabelKey* = MultiRunLabelPrefix
  OwnerLabelValue* = "1"
  KindLabel* = MultiRunLabelPrefix & ".kind"
  RunLabel* = MultiRunLabelPrefix & ".run"
  GameIndexLabel* = MultiRunLabelPrefix & ".game_index"
  GameLabel* = MultiRunLabelPrefix & ".game"
  SlotLabel* = MultiRunLabelPrefix & ".slot"
  PlayerLabel* = MultiRunLabelPrefix & ".player"
  RoleLabel* = MultiRunLabelPrefix & ".role"
  ReplayLabel* = MultiRunLabelPrefix & ".replay"
  ResultsLabel* = MultiRunLabelPrefix & ".results"
  ConfigLabel* = MultiRunLabelPrefix & ".config"
  PortLabel* = MultiRunLabelPrefix & ".port"
  CreatedLabel* = MultiRunLabelPrefix & ".created"
  GameKind* = "game"
  PlayerKind* = "player"
  CoworldManifestName* = "coworld_manifest.json"
  CoplayerManifestName* = "coplayer_manifest.json"
  ReplayDirEnv* = "GAMES_SERVER_REPLAY_DIR"
  DockerBinEnv* = "MULTI_RUN_DOCKER"
  SharedDockerBinEnv* = "GAMES_SERVER_DOCKER"
  GameContainerPort* = 8080
  ContainerReplayDir* = "/replays"
  HealthPath* = "/healthz"
  CogameReplayUriEnv* = "COGAME_SAVE_REPLAY_URI"
  CogameResultsUriEnv* = "COGAME_RESULTS_URI"
  CogameConfigUriEnv* = "COGAME_CONFIG_URI"
  CogameLoadReplayUriEnv* = "COGAME_LOAD_REPLAY_URI"
  CogameHostEnv* = "COGAME_HOST"
  CogamePortEnv* = "COGAME_PORT"
  EngineWsEnv* = "COGAMES_ENGINE_WS_URL"
  BotHost* = "host.docker.internal"
  RunPrefix* = "run_"
  MultiRunsDirName* = "multi_runs"
  ReplayKind* = "replay"
  ScoreHistogramBinSize* = 10
  InspectBatchSize* = 100
  SlotTokenBytes = 16
  HexChars = "0123456789abcdef"
  AiKeyEnvNames = ["CLAUDE_KEY", "GEMINI_KEY", "OPENAI_KEY", "XAI_KEY"]

type
  MultiRunError* = object of CatchableError

  CommandResult* = object
    output*: string
    code*: int

  BotGroup* = object
    name*: string
    count*: int
    role*: string

  GameManifest* = object
    key*: string
    path*: string
    name*: string
    author*: string
    imageUri*: string
    command*: seq[string]
    env*: seq[(string, string)]

  PlayerManifest* = object
    key*: string
    path*: string
    name*: string
    author*: string
    imageUri*: string
    command*: seq[string]
    env*: seq[(string, string)]
    games*: seq[string]

  BotLaunch* = object
    player*: PlayerManifest
    count*: int
    role*: string

  PlayerSlot* = object
    player*: string
    playerName*: string
    role*: string
    slotIndex*: int
    token*: string
    containerName*: string
    log*: string

  RunPaths* = object
    replayRoot*: string
    runsRoot*: string
    runId*: string
    runDir*: string

  RunMeta* = object
    runId*: string
    manifest*: string
    gameName*: string
    totalGames*: int
    maxGames*: int
    botCount*: int
    created*: int64

  GameMeta* = object
    runId*: string
    gameIndex*: int
    gameName*: string
    containerName*: string
    port*: int
    status*: string
    exitCode*: int
    replay*: string
    results*: string
    config*: string
    created*: int64
    finished*: int64
    slots*: seq[PlayerSlot]

  QueueCounts* = object
    total*: int
    running*: int
    finished*: int
    failed*: int
    queued*: int
    started*: int

  ContainerInfo* = object
    name*: string
    status*: string
    exitCode*: int
    kind*: string
    runId*: string
    gameIndex*: int
    gameName*: string
    slot*: int
    player*: string
    role*: string
    replay*: string
    results*: string
    config*: string
    port*: int
    created*: int64

  ScoreNumberField* = object
    name*: string
    value*: float

  ScoreTextField* = object
    name*: string
    value*: string

  ScoreRow* = object
    name*: string
    score*: float
    win*: bool
    tasks*: int
    kills*: int
    imposter*: int
    crew*: int
    votePlayers*: int
    voteSkip*: int
    voteTimeout*: int
    numbers*: seq[ScoreNumberField]
    texts*: seq[ScoreTextField]

  ScoreRange* = object
    hasMin*: bool
    minValue*: float
    hasMax*: bool
    maxValue*: float

  ScoreNumberRange* = object
    name*: string
    scoreRange*: ScoreRange

  ScoreTextValues* = object
    name*: string
    values*: seq[string]

  ScoreFilter* = object
    names*: seq[string]
    players*: seq[string]
    roles*: seq[string]
    wins*: seq[string]
    score*: ScoreRange
    tasks*: ScoreRange
    kills*: ScoreRange
    imposter*: ScoreRange
    crew*: ScoreRange
    votePlayers*: ScoreRange
    voteSkip*: ScoreRange
    voteTimeout*: ScoreRange
    numberRanges*: seq[ScoreNumberRange]
    textValues*: seq[ScoreTextValues]

  ScoreRecord* = object
    gameIndex*: int
    row*: ScoreRow
    player*: string
    role*: string

  PlayerAggregate* = object
    player*: string
    role*: string
    games*: int
    wins*: int
    scoreSum*: float
    scoreSquaresSum*: float
    scoreMin*: float
    scoreMax*: float
    tasksSum*: int
    killsSum*: int
    imposterSum*: int
    crewSum*: int
    votePlayersSum*: int
    voteSkipSum*: int
    voteTimeoutSum*: int
    numberSums*: seq[ScoreNumberField]

  ScoreHistogram* = object
    player*: string
    bucketMin*: int
    bins*: seq[int]
    total*: int

proc envValue*(name, defaultValue: string): string =
  ## Reads one environment variable with empty values treated as missing.
  result = getEnv(name, defaultValue).strip()
  if result.len == 0:
    result = defaultValue

proc repoRoot*(): string =
  ## Returns the Bitworld repository root for this source tree.
  parentDir(parentDir(parentDir(currentSourcePath())))

proc defaultReplayRoot*(): string =
  ## Returns the default replay directory used by game server tools.
  repoRoot() / "games_server" / "replays"

proc replayRoot*(): string =
  ## Returns the shared replay directory for multi-run artifacts.
  envValue(ReplayDirEnv, defaultReplayRoot())

proc multiRunsRoot*(root = replayRoot()): string =
  ## Returns the root directory that stores generated multi-run folders.
  root / MultiRunsDirName

proc dockerBin*(): string =
  ## Returns the Docker-compatible CLI to use for local launches.
  let configured = envValue(
    DockerBinEnv,
    envValue(SharedDockerBinEnv, "docker")
  )
  if configured != "docker":
    return configured
  result = findExe("docker")
  if result.len > 0:
    return
  for path in [
    "/opt/homebrew/bin/docker",
    "/usr/local/bin/docker",
    "/Applications/Docker.app/Contents/Resources/bin/docker"
  ]:
    if fileExists(path):
      return path
  result = "docker"

proc cleanFileName*(value: string): string =
  ## Returns a conservative file-safe name.
  for c in value:
    if c.isAlphaNumeric() or c in {'_', '-', '.'}:
      result.add(c)
    else:
      result.add('_')
  while result.contains("__"):
    result = result.replace("__", "_")
  result = result.strip(chars = {'_'})

proc cleanContainerName*(value: string): string =
  ## Returns a Docker-name-safe lowercase identifier.
  result = cleanFileName(value).toLowerAscii()
  if result.len == 0:
    result = "multi_run"

proc parsePositiveInt*(value, label: string): int =
  ## Parses one positive integer command-line value.
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(MultiRunError, label & " must be an integer.")
  if result <= 0:
    raise newException(MultiRunError, label & " must be greater than zero.")

proc parseIntSafe*(value: string): int =
  ## Parses an integer, returning zero on malformed input.
  try:
    result = parseInt(value)
  except ValueError:
    result = 0

proc parseInt64Safe*(value: string): int64 =
  ## Parses a 64-bit integer, returning zero on malformed input.
  try:
    result = parseBiggestInt(value)
  except ValueError:
    result = 0

proc parseBotGroup*(value: string): BotGroup =
  ## Parses BOT:N or BOT:N:ROLE into one requested bot group.
  let parts = value.strip().split(':')
  if parts.len notin {2, 3}:
    raise newException(
      MultiRunError,
      "--bots must use BOT:N or BOT:N:ROLE."
    )
  result.name = parts[0].strip()
  if result.name.len == 0:
    raise newException(MultiRunError, "--bots source cannot be empty.")
  result.count = parsePositiveInt(parts[1].strip(), "--bots count")
  if parts.len == 3:
    result.role = parts[2].strip()
    if result.role.len == 0:
      raise newException(MultiRunError, "--bots role cannot be empty.")

proc queueCounts*(
  total,
  started,
  running,
  finished,
  failed: int
): QueueCounts =
  ## Builds queue accounting for display and tests.
  result.total = total
  result.started = started
  result.running = running
  result.finished = finished
  result.failed = failed
  result.queued = max(0, total - started)

proc runNumber(name: string): int =
  ## Parses the numeric suffix from a generated run directory name.
  if not name.startsWith(RunPrefix):
    return 0
  let raw = name[RunPrefix.len .. ^1]
  if raw.len == 0:
    return 0
  for c in raw:
    if c notin {'0' .. '9'}:
      return 0
  parseIntSafe(raw)

proc nextRunName*(root: string): string =
  ## Returns the next generated run folder name under a root directory.
  var nextId = 1
  if dirExists(root):
    for kind, path in walkDir(root):
      if kind != pcDir:
        continue
      nextId = max(nextId, runNumber(path.extractFilename()) + 1)
  RunPrefix & align($nextId, 6, '0')

proc allocateRunPaths*(): RunPaths =
  ## Creates and returns the next durable multi-run artifact directory.
  result.replayRoot = replayRoot()
  result.runsRoot = multiRunsRoot(result.replayRoot)
  createDir(result.runsRoot)
  result.runId = nextRunName(result.runsRoot)
  result.runDir = result.runsRoot / result.runId
  createDir(result.runDir)

proc runArtifactRelativePath*(runId, name: string): string =
  ## Returns an artifact path relative to the shared replay root.
  (MultiRunsDirName / runId / name).replace("\\", "/")

proc artifactRelativePath*(paths: RunPaths, name: string): string =
  ## Returns an artifact path relative to the shared replay root.
  runArtifactRelativePath(paths.runId, name)

proc artifactHostPath*(paths: RunPaths, name: string): string =
  ## Returns an artifact path on the host filesystem.
  paths.runDir / name

proc artifactContainerPath*(name: string): string =
  ## Returns an artifact path inside launched game containers.
  ContainerReplayDir / name

proc gameFileName*(gameIndex: int, ext: string): string =
  ## Builds one per-game artifact file name.
  "game_" & align($gameIndex, 4, '0') & ext

proc playerLogFileName*(
  gameIndex,
  slotIndex: int,
  playerName: string
): string =
  ## Builds one per-player log artifact file name.
  "game_" & align($gameIndex, 4, '0') & "." &
    cleanFileName(playerName) & ".slot_" & $slotIndex & ".log"

proc randomHexToken*(): string =
  ## Generates a secure random hex token.
  var bytes = newSeq[byte](SlotTokenBytes)
  if not urandom(bytes):
    raise newException(MultiRunError, "could not generate random token.")
  for value in bytes:
    let n = int(value)
    result.add(HexChars[n shr 4])
    result.add(HexChars[n and 0x0f])

proc manifestObject(node: JsonNode, key: string): JsonNode =
  ## Reads one optional JSON object child.
  if node != nil and node.kind == JObject and node.hasKey(key) and
      node[key].kind == JObject:
    return node[key]

proc manifestString(
  node: JsonNode,
  key,
  defaultValue: string
): string =
  ## Reads one optional string field.
  if node != nil and node.kind == JObject and node.hasKey(key) and
      node[key].kind == JString:
    return node[key].getStr()
  defaultValue

proc manifestStringArray(node: JsonNode, key: string): seq[string] =
  ## Reads one optional string array field.
  if node == nil or node.kind != JObject or not node.hasKey(key) or
      node[key].kind != JArray:
    return
  for item in node[key]:
    if item.kind == JString:
      result.add(item.getStr())

proc manifestEnv(node: JsonNode): seq[(string, string)] =
  ## Reads one optional environment object as name/value pairs.
  let env = node.manifestObject("env")
  if env.isNil:
    return
  for key, value in env.pairs:
    if value.kind == JString:
      result.add((key, value.getStr()))

proc manifestImage(node: JsonNode): string =
  ## Reads a Coworld image from a game or player manifest node.
  let runnable = node.manifestObject("runnable")
  if not runnable.isNil:
    result = runnable.manifestString("image", "")
  if result.len == 0:
    result = node.manifestString("image_uri", "")
  if result.len == 0:
    result = node.manifestString("image", "")

proc manifestRunCommand(
  node: JsonNode,
  path: string,
  required = true
): seq[string] =
  ## Reads a run command from a Coworld manifest node.
  let runnable = node.manifestObject("runnable")
  if not runnable.isNil:
    result = runnable.manifestStringArray("run")
  if result.len == 0:
    result = node.manifestStringArray("run")
  if result.len == 0:
    let binary = node.manifestString("binary", "")
    if binary.len > 0:
      result.add(binary)
  if result.len == 0 and required:
    raise newException(MultiRunError, path & " missing run.")

proc requireManifestString(node: JsonNode, key, path: string): string =
  ## Reads one required manifest string.
  result = node.manifestString(key, "")
  if result.len == 0:
    raise newException(MultiRunError, path & " missing " & key & ".")

proc manifestKey*(path: string): string =
  ## Builds a stable repo-relative manifest key when possible.
  let
    root = repoRoot()
    prefix = root & DirSep
  if path.startsWith(prefix):
    result = path[prefix.len .. ^1]
  else:
    result = path
  result = result.replace("\\", "/")

proc readGameManifest*(path: string): GameManifest =
  ## Reads one Coworld game manifest.
  try:
    let
      manifest = parseJson(readFile(path))
      game = manifest.manifestObject("game")
    if game.isNil:
      raise newException(MultiRunError, "coworld missing game.")
    let
      name = game.requireManifestString("name", "coworld.game")
      image = game.manifestImage()
    if image.len == 0:
      raise newException(MultiRunError, "coworld.game missing image.")
    result = GameManifest(
      key: manifestKey(path),
      path: path,
      name: name,
      author: game.manifestString("author", game.manifestString("owner", "-")),
      imageUri: image,
      command: game.manifestRunCommand(
        "coworld.game.runnable",
        required = false
      ),
      env: game.manifestEnv()
    )
  except CatchableError as e:
    raise newException(
      MultiRunError,
      "could not read Coworld manifest " & path & ": " & e.msg
    )

proc readStandalonePlayer*(path: string): PlayerManifest =
  ## Reads one standalone coplayer manifest.
  try:
    let node = parseJson(readFile(path))
    let name = node.requireManifestString("name", path)
    let image = node.manifestImage()
    if image.len == 0:
      raise newException(MultiRunError, path & " missing image.")
    result = PlayerManifest(
      key: manifestKey(path),
      path: path,
      name: name,
      author: node.manifestString("author", node.manifestString("owner", "-")),
      imageUri: image,
      command: node.manifestRunCommand(path, required = false),
      env: node.manifestEnv(),
      games: node.manifestStringArray("games")
    )
  except CatchableError as e:
    raise newException(
      MultiRunError,
      "could not read player manifest " & path & ": " & e.msg
    )

proc readCoworldPlayers*(path: string): seq[PlayerManifest] =
  ## Reads player entries embedded in a Coworld game manifest.
  try:
    let
      manifest = parseJson(readFile(path))
      game = readGameManifest(path)
    if manifest.kind != JObject or not manifest.hasKey("player") or
        manifest["player"].kind != JArray:
      return
    for player in manifest["player"]:
      if player.kind != JObject:
        continue
      let name = player.manifestString(
        "id",
        player.manifestString("name", "")
      )
      if name.len == 0:
        continue
      let image = player.manifestImage()
      if image.len == 0:
        continue
      result.add(PlayerManifest(
        key: manifestKey(path) & "#player/" & name,
        path: path,
        name: name,
        author: player.manifestString(
          "author",
          player.manifestString("owner", "-")
        ),
        imageUri: image,
        command: player.manifestRunCommand(
          "coworld.player[" & name & "].runnable",
          required = false
        ),
        env: player.manifestEnv(),
        games: @[game.name]
      ))
  except CatchableError as e:
    raise newException(
      MultiRunError,
      "could not read Coworld players " & path & ": " & e.msg
    )

proc supportsGame*(player: PlayerManifest, gameName: string): bool =
  ## Returns true when a player manifest supports one game.
  if player.games.len == 0:
    return true
  for game in player.games:
    if game == gameName:
      return true

proc addUniquePlayer(players: var seq[PlayerManifest], player: PlayerManifest) =
  ## Adds a player manifest once by player name.
  for existing in players:
    if existing.name == player.name:
      return
  players.add(player)

proc listPlayerManifests*(gameName, gameManifestPath: string): seq[PlayerManifest] =
  ## Lists standalone and embedded player manifests for one game.
  let playersDir = repoRoot() / "games_server" / "players"
  if dirExists(playersDir):
    for dir in walkDirs(playersDir / "*"):
      let path = dir / CoplayerManifestName
      if not fileExists(path):
        continue
      let player = readStandalonePlayer(path)
      if player.supportsGame(gameName):
        result.addUniquePlayer(player)
  for player in readCoworldPlayers(gameManifestPath):
    if player.supportsGame(gameName):
      result.addUniquePlayer(player)
  result.sort(proc(a, b: PlayerManifest): int = cmp(a.name, b.name))

proc findPlayerManifest*(
  gameName,
  gameManifestPath,
  key: string
): PlayerManifest =
  ## Finds one player manifest by name, key, or manifest path.
  let cleanKey = key.strip()
  for player in listPlayerManifests(gameName, gameManifestPath):
    if player.name == cleanKey or player.key == cleanKey or
        player.path == cleanKey:
      return player
  raise newException(MultiRunError, "unknown Coworld player: " & cleanKey)

proc resolveBotLaunches*(
  game: GameManifest,
  groups: openArray[BotGroup]
): seq[BotLaunch] =
  ## Resolves requested bot groups to supported player manifests.
  for group in groups:
    result.add(BotLaunch(
      player: findPlayerManifest(game.name, game.path, group.name),
      count: group.count,
      role: group.role
    ))

proc objectChild(node: JsonNode, key: string): JsonNode =
  ## Reads an object child from a JSON object.
  if node != nil and node.kind == JObject and node.hasKey(key) and
      node[key].kind == JObject:
    return node[key]

proc arrayChild(node: JsonNode, key: string): JsonNode =
  ## Reads an array child from a JSON object.
  if node != nil and node.kind == JObject and node.hasKey(key) and
      node[key].kind == JArray:
    return node[key]

proc roleEnumFromManifest*(manifestPath: string): seq[string] =
  ## Reads supported slot role names from a game config schema.
  let
    manifest = parseJson(readFile(manifestPath))
    game = manifest.objectChild("game")
    schema = game.objectChild("config_schema")
    properties = schema.objectChild("properties")
    slots = properties.objectChild("slots")
    items = slots.objectChild("items")
    slotProperties = items.objectChild("properties")
    role = slotProperties.objectChild("role")
    roleEnum = role.arrayChild("enum")
  if roleEnum.isNil:
    return
  for item in roleEnum:
    if item.kind == JString:
      result.add(item.getStr())

proc validateRoles*(manifestPath: string, groups: openArray[BotGroup]) =
  ## Validates requested slot roles against the game manifest schema.
  var requested: seq[string]
  for group in groups:
    if group.role.len > 0 and group.role notin requested:
      requested.add(group.role)
  if requested.len == 0:
    return
  let allowed = roleEnumFromManifest(manifestPath)
  if allowed.len == 0:
    raise newException(
      MultiRunError,
      "manifest does not advertise slots[].role support."
    )
  for role in requested:
    if role notin allowed:
      raise newException(
        MultiRunError,
        "unsupported role " & role & "; expected one of " & allowed.join(", ")
      )

proc botCount*(launches: openArray[BotLaunch]): int =
  ## Counts total player slots requested by bot groups.
  for launch in launches:
    result += launch.count

proc visiblePlayerName*(playerName: string, slot: int): string =
  ## Builds the in-game visible player name for one launched bot.
  playerName & "-" & $slot

proc gameContainerName*(runId: string, gameIndex: int): string =
  ## Builds one Docker game container name.
  cleanContainerName("multi_run_" & runId & "_game_" & $gameIndex)

proc playerContainerName*(
  runId,
  player: string,
  gameIndex,
  slot: int
): string =
  ## Builds one Docker player container name.
  cleanContainerName(
    "multi_run_" & runId & "_player_" & player & "_" &
      $gameIndex & "_" & $slot
  )

proc replayContainerName*(runId: string, gameIndex, port: int): string =
  ## Builds one Docker replay-server container name.
  cleanContainerName(
    "multi_run_" & runId & "_replay_" & $gameIndex & "_" & $port
  )

proc buildSlots*(
  runId: string,
  gameIndex: int,
  launches: openArray[BotLaunch]
): seq[PlayerSlot] =
  ## Builds fixed player slots for one game.
  var slot = 0
  for launch in launches:
    for _ in 0 ..< launch.count:
      inc slot
      let playerName = visiblePlayerName(launch.player.name, slot)
      result.add(PlayerSlot(
        player: launch.player.name,
        playerName: playerName,
        role: launch.role,
        slotIndex: slot - 1,
        token: randomHexToken(),
        containerName: playerContainerName(
          runId,
          launch.player.name,
          gameIndex,
          slot
        ),
        log: runArtifactRelativePath(
          runId,
          playerLogFileName(gameIndex, slot - 1, playerName)
        )
      ))

proc variantDefaults(manifest: JsonNode): JsonNode =
  ## Reads the first variant's game_config defaults.
  result = newJObject()
  if manifest == nil or not manifest.hasKey("variants") or
      manifest["variants"].kind != JArray or manifest["variants"].len == 0:
    return
  let variant = manifest["variants"][0]
  if variant.kind == JObject and variant.hasKey("game_config") and
      variant["game_config"].kind == JObject:
    result = variant["game_config"].copy()

proc schemaHasProperty(game: JsonNode, key: string): bool =
  ## Returns true when config_schema.properties contains a key.
  let
    schema = game.objectChild("config_schema")
    properties = schema.objectChild("properties")
  properties != nil and properties.hasKey(key)

proc slotSchemaHasProperty(game: JsonNode, key: string): bool =
  ## Returns true when config_schema.properties.slots.items supports a key.
  let
    schema = game.objectChild("config_schema")
    properties = schema.objectChild("properties")
    slots = properties.objectChild("slots")
    items = slots.objectChild("items")
    slotProperties = items.objectChild("properties")
  slotProperties != nil and slotProperties.hasKey(key)

proc applySchemaDefaults(node: var JsonNode, game: JsonNode) =
  ## Applies config_schema default values not already present.
  let
    schema = game.objectChild("config_schema")
    properties = schema.objectChild("properties")
  if properties.isNil:
    return
  for key, property in properties.pairs:
    if not node.hasKey(key) and property.kind == JObject and
        property.hasKey("default"):
      node[key] = property["default"].copy()

proc buildGameConfigJson*(
  manifestPath: string,
  slots: openArray[PlayerSlot]
): string =
  ## Builds one fixed-roster game config JSON document.
  let
    manifest = parseJson(readFile(manifestPath))
    game = manifest.objectChild("game")
  var node = variantDefaults(manifest)
  node.applySchemaDefaults(game)
  let
    slotArray = newJArray()
    tokenArray = newJArray()
  var imposterCount = 0
  let playerArray = newJArray()
  let
    hasPlayers = game.schemaHasProperty("players")
    hasSlots = game.schemaHasProperty("slots")
    slotHasName = game.slotSchemaHasProperty("name")
    slotHasToken = game.slotSchemaHasProperty("token")
    slotHasRole = game.slotSchemaHasProperty("role")
  for slot in slots:
    if hasPlayers:
      let player = newJObject()
      player["name"] = %slot.playerName
      playerArray.add(player)
    let item = newJObject()
    if slotHasName:
      item["name"] = %slot.playerName
    if slotHasToken:
      item["token"] = %slot.token
    if slot.role.len > 0 and slotHasRole:
      item["role"] = %slot.role
      if slot.role == "imposter":
        inc imposterCount
    slotArray.add(item)
    tokenArray.add(%slot.token)
  node["tokens"] = tokenArray
  if hasPlayers:
    node["players"] = playerArray
  if hasSlots:
    node["slots"] = slotArray
  node["seed"] = %int(epochTime() * 1000)
  node["minPlayers"] = %slots.len
  node["maxGames"] = %1
  if game.schemaHasProperty("closedRoster"):
    node["closedRoster"] = %true
  if imposterCount > 0 and game.schemaHasProperty("imposterCount"):
    node["imposterCount"] = %imposterCount
  if imposterCount > 0 and game.schemaHasProperty("autoImposterCount"):
    node["autoImposterCount"] = %false
  $node

proc labelArg*(key, value: string): seq[string] =
  ## Builds Docker CLI args for one label.
  @["--label", key & "=" & value]

proc addAiEnvArgs(args: var seq[string]) =
  ## Adds available AI provider key environment variables.
  for key in AiKeyEnvNames:
    let value = getEnv(key)
    if value.len > 0:
      args.add("-e")
      args.add(key & "=" & value)

proc addEnvArgs(args: var seq[string], env: openArray[(string, string)]) =
  ## Adds environment variables to Docker arguments.
  for (key, value) in env:
    args.add("-e")
    args.add(key & "=" & value)

proc encodeUrlComponent*(value: string): string =
  ## Encodes a string for use as one URL query parameter value.
  for c in value:
    case c
    of 'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_', '.', '~':
      result.add(c)
    else:
      result.add('%')
      result.add(ord(c).toHex(2))

proc playerWsUrl*(port: int, slot: PlayerSlot): string =
  ## Builds the bot websocket URL for one player slot.
  "ws://" & BotHost & ":" & $port & "/player?name=" &
    encodeUrlComponent(slot.playerName) & "&slot=" & $slot.slotIndex &
    "&token=" & encodeUrlComponent(slot.token)

proc gameDockerArgs*(
  paths: RunPaths,
  game: GameManifest,
  meta: GameMeta
): seq[string] =
  ## Builds Docker args for one multi-run game container.
  let
    replayName = meta.replay.extractFilename()
    resultsName = meta.results.extractFilename()
    configName = meta.config.extractFilename()
  result = @[
    "run",
    "-d",
    "--init",
    "--name",
    meta.containerName,
    "-p",
    $meta.port & ":" & $GameContainerPort,
    "--label",
    OwnerLabelKey & "=" & OwnerLabelValue,
    "--label",
    KindLabel & "=" & GameKind,
    "--label",
    RunLabel & "=" & meta.runId,
    "--label",
    GameIndexLabel & "=" & $meta.gameIndex,
    "--label",
    GameLabel & "=" & game.name,
    "--label",
    ReplayLabel & "=" & meta.replay,
    "--label",
    ResultsLabel & "=" & meta.results,
    "--label",
    ConfigLabel & "=" & meta.config,
    "--label",
    PortLabel & "=" & $meta.port,
    "--label",
    CreatedLabel & "=" & $meta.created,
    "-v",
    paths.runDir & ":" & ContainerReplayDir,
    "-e",
    CogameReplayUriEnv & "=file://" & artifactContainerPath(replayName),
    "-e",
    CogameResultsUriEnv & "=file://" & artifactContainerPath(resultsName),
    "-e",
    CogameConfigUriEnv & "=file://" & artifactContainerPath(configName),
    "-e",
    CogameHostEnv & "=0.0.0.0",
    "-e",
    CogamePortEnv & "=" & $GameContainerPort
  ]
  result.addAiEnvArgs()
  result.addEnvArgs(game.env)
  result.add(game.imageUri)
  for token in game.command:
    result.add(token)

proc replayDockerArgs*(
  runDir: string,
  game: GameManifest,
  meta: GameMeta,
  port: int,
  created: int64
): seq[string] =
  ## Builds Docker args for one multi-run replay server.
  let
    replayName = meta.replay.extractFilename()
    containerName = replayContainerName(meta.runId, meta.gameIndex, port)
  result = @[
    "run",
    "-d",
    "--init",
    "--add-host",
    "host.docker.internal:host-gateway",
    "--name",
    containerName,
    "-p",
    $port & ":" & $GameContainerPort,
    "--label",
    OwnerLabelKey & "=" & OwnerLabelValue,
    "--label",
    KindLabel & "=" & ReplayKind,
    "--label",
    RunLabel & "=" & meta.runId,
    "--label",
    GameIndexLabel & "=" & $meta.gameIndex,
    "--label",
    GameLabel & "=" & game.name,
    "--label",
    ReplayLabel & "=" & meta.replay,
    "--label",
    ResultsLabel & "=" & meta.results,
    "--label",
    ConfigLabel & "=" & meta.config,
    "--label",
    PortLabel & "=" & $port,
    "--label",
    CreatedLabel & "=" & $created,
    "-v",
    runDir & ":" & ContainerReplayDir & ":ro",
    "-e",
    CogameLoadReplayUriEnv & "=file://" & artifactContainerPath(replayName),
    "-e",
    CogameHostEnv & "=0.0.0.0",
    "-e",
    CogamePortEnv & "=" & $GameContainerPort
  ]
  result.addAiEnvArgs()
  result.addEnvArgs(game.env)
  result.add(game.imageUri)
  for token in game.command:
    result.add(token)

proc playerDockerArgs*(
  player: PlayerManifest,
  meta: GameMeta,
  slot: PlayerSlot
): seq[string] =
  ## Builds Docker args for one multi-run player container.
  result = @[
    "run",
    "-d",
    "--init",
    "--name",
    slot.containerName,
    "--add-host",
    "host.docker.internal:host-gateway",
    "--label",
    OwnerLabelKey & "=" & OwnerLabelValue,
    "--label",
    KindLabel & "=" & PlayerKind,
    "--label",
    RunLabel & "=" & meta.runId,
    "--label",
    GameIndexLabel & "=" & $meta.gameIndex,
    "--label",
    GameLabel & "=" & meta.gameName,
    "--label",
    SlotLabel & "=" & $slot.slotIndex,
    "--label",
    PlayerLabel & "=" & player.name,
    "--label",
    RoleLabel & "=" & slot.role,
    "--label",
    ReplayLabel & "=" & meta.replay,
    "--label",
    ResultsLabel & "=" & meta.results,
    "--label",
    ConfigLabel & "=" & meta.config,
    "--label",
    PortLabel & "=" & $meta.port,
    "--label",
    CreatedLabel & "=" & $meta.created,
    "-e",
    EngineWsEnv & "=" & playerWsUrl(meta.port, slot)
  ]
  result.addAiEnvArgs()
  result.addEnvArgs(player.env)
  result.add(player.imageUri)
  for token in player.command:
    result.add(token)

proc dockerResult*(args: openArray[string]): CommandResult =
  ## Runs Docker and captures merged stdout and stderr.
  try:
    let command = quoteShellCommand(@[dockerBin()] & @args)
    let res = execCmdEx(
      command,
      options = {poEvalCommand, poStdErrToStdOut}
    )
    result.output = res.output
    result.code = res.exitCode
  except OSError as e:
    raise newException(MultiRunError, "could not run Docker: " & e.msg)

proc requireDocker*(args: openArray[string]): string =
  ## Runs Docker and raises on failure.
  let res = dockerResult(args)
  if res.code != 0:
    raise newException(
      MultiRunError,
      "docker " & args.join(" ") & " failed: " & res.output.strip()
    )
  res.output

proc findOpenPort*(): int =
  ## Asks the OS to reserve and report one free host port.
  var socket = newSocket()
  try:
    socket.setSockOpt(OptReuseAddr, true)
    socket.bindAddr(Port(0), "0.0.0.0")
    let (_, port) = socket.getLocalAddr()
    result = port.int
  except OSError as e:
    raise newException(
      MultiRunError,
      "could not ask OS for a free port: " & e.msg
    )
  finally:
    socket.close()
  if result <= 0:
    raise newException(MultiRunError, "OS returned an invalid free port.")

proc gameHealthUrl*(port: int): string =
  ## Builds a local game health URL.
  "http://127.0.0.1:" & $port & HealthPath

proc waitForHealthy*(port: int, timeoutSec = 30): bool =
  ## Polls a game health endpoint until it answers.
  let deadline = epochTime() + timeoutSec.float
  while epochTime() < deadline:
    var client = newHttpClient(timeout = 500)
    try:
      discard client.getContent(gameHealthUrl(port))
      return true
    except CatchableError:
      discard
    finally:
      client.close()
    sleep(250)

proc runMetaPath*(runDir: string): string =
  ## Returns the run metadata file path.
  runDir / "run.json"

proc gameMetaFileName*(gameIndex: int): string =
  ## Returns the game metadata file name.
  gameFileName(gameIndex, ".meta.json")

proc gameMetaPath*(runDir: string, gameIndex: int): string =
  ## Returns the game metadata file path.
  runDir / gameMetaFileName(gameIndex)

proc slotJson(slot: PlayerSlot): JsonNode =
  ## Converts one player slot to metadata JSON.
  result = newJObject()
  result["player"] = %slot.player
  result["playerName"] = %slot.playerName
  result["role"] = %slot.role
  result["slotIndex"] = %slot.slotIndex
  result["token"] = %slot.token
  result["containerName"] = %slot.containerName
  result["log"] = %slot.log

proc slotFromJson(node: JsonNode): PlayerSlot =
  ## Reads one player slot from metadata JSON.
  if node == nil or node.kind != JObject:
    return
  result = PlayerSlot(
    player: node.manifestString("player", ""),
    playerName: node.manifestString("playerName", ""),
    role: node.manifestString("role", ""),
    slotIndex: parseIntSafe($node.getOrDefault("slotIndex")),
    token: node.manifestString("token", ""),
    containerName: node.manifestString("containerName", ""),
    log: node.manifestString("log", "")
  )

proc writeRunMeta*(runDir: string, meta: RunMeta) =
  ## Writes durable metadata for one multi-run invocation.
  let node = newJObject()
  node["runId"] = %meta.runId
  node["manifest"] = %meta.manifest
  node["gameName"] = %meta.gameName
  node["totalGames"] = %meta.totalGames
  node["maxGames"] = %meta.maxGames
  node["botCount"] = %meta.botCount
  node["created"] = %meta.created
  writeFile(runMetaPath(runDir), $node)

proc readRunMeta*(runDir: string): RunMeta =
  ## Reads durable metadata for one multi-run invocation.
  let path = runMetaPath(runDir)
  if not fileExists(path):
    result.runId = runDir.extractFilename()
    return
  let node = parseJson(readFile(path))
  result = RunMeta(
    runId: node.manifestString("runId", runDir.extractFilename()),
    manifest: node.manifestString("manifest", ""),
    gameName: node.manifestString("gameName", ""),
    totalGames: parseIntSafe($node.getOrDefault("totalGames")),
    maxGames: parseIntSafe($node.getOrDefault("maxGames")),
    botCount: parseIntSafe($node.getOrDefault("botCount")),
    created: parseInt64Safe($node.getOrDefault("created")),
  )

proc writeGameMeta*(runDir: string, meta: GameMeta) =
  ## Writes durable metadata for one multi-run game.
  let node = newJObject()
  let slots = newJArray()
  node["runId"] = %meta.runId
  node["gameIndex"] = %meta.gameIndex
  node["gameName"] = %meta.gameName
  node["containerName"] = %meta.containerName
  node["port"] = %meta.port
  node["status"] = %meta.status
  node["exitCode"] = %meta.exitCode
  node["replay"] = %meta.replay
  node["results"] = %meta.results
  node["config"] = %meta.config
  node["created"] = %meta.created
  node["finished"] = %meta.finished
  for slot in meta.slots:
    slots.add(slot.slotJson())
  node["slots"] = slots
  writeFile(gameMetaPath(runDir, meta.gameIndex), $node)

proc readGameMeta*(path: string): GameMeta =
  ## Reads durable metadata for one multi-run game.
  let node = parseJson(readFile(path))
  result = GameMeta(
    runId: node.manifestString("runId", ""),
    gameIndex: parseIntSafe($node.getOrDefault("gameIndex")),
    gameName: node.manifestString("gameName", ""),
    containerName: node.manifestString("containerName", ""),
    port: parseIntSafe($node.getOrDefault("port")),
    status: node.manifestString("status", ""),
    exitCode: parseIntSafe($node.getOrDefault("exitCode")),
    replay: node.manifestString("replay", ""),
    results: node.manifestString("results", ""),
    config: node.manifestString("config", ""),
    created: parseInt64Safe($node.getOrDefault("created")),
    finished: parseInt64Safe($node.getOrDefault("finished")),
  )
  let slots = node.arrayChild("slots")
  if slots != nil:
    for slot in slots:
      result.slots.add(slot.slotFromJson())

proc readGameMetas*(runDir: string): seq[GameMeta] =
  ## Reads all game metadata files in one run folder.
  if not dirExists(runDir):
    return
  for path in walkFiles(runDir / "game_*.meta.json"):
    try:
      result.add(readGameMeta(path))
    except CatchableError:
      discard
  result.sort(proc(a, b: GameMeta): int = cmp(a.gameIndex, b.gameIndex))

proc inspectLine*(line: string): ContainerInfo =
  ## Parses one Docker inspect output line for a multi-run container.
  let parts = line.split('\t')
  if parts.len < 16:
    raise newException(MultiRunError, "invalid docker inspect output.")
  result = ContainerInfo(
    name: parts[0].strip(chars = {'/'}),
    status: parts[1],
    exitCode: parseIntSafe(parts[2]),
    kind: parts[3],
    runId: parts[4],
    gameIndex: parseIntSafe(parts[5]),
    gameName: parts[6],
    slot: parseIntSafe(parts[7]),
    player: parts[8],
    role: parts[9],
    replay: parts[10],
    results: parts[11],
    config: parts[12],
    port: parseIntSafe(parts[13]),
    created: parseInt64Safe(parts[14])
  )

proc inspectFormat(): string =
  ## Returns the Docker inspect format for multi-run labels.
  "{{.Name}}\t{{.State.Status}}\t{{.State.ExitCode}}\t" &
    "{{index .Config.Labels \"" & KindLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & RunLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & GameIndexLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & GameLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & SlotLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & PlayerLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & RoleLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & ReplayLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & ResultsLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & ConfigLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & PortLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & CreatedLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & OwnerLabelKey & "\"}}"

proc inspectContainer*(name: string): ContainerInfo =
  ## Reads Docker state and multi-run labels for one container.
  let text = requireDocker(@["inspect", "-f", inspectFormat(), name]).strip()
  result = inspectLine(text)

proc inspectContainers(names: openArray[string]): seq[ContainerInfo] =
  ## Reads Docker state and labels for a batch of containers.
  if names.len == 0:
    return
  var args = @["inspect", "-f", inspectFormat()]
  args.add(names)
  let res = dockerResult(args)
  if res.code != 0:
    for name in names:
      try:
        result.add(inspectContainer(name))
      except CatchableError:
        discard
    return
  for line in res.output.splitLines():
    let text = line.strip()
    if text.len == 0:
      continue
    try:
      result.add(inspectLine(text))
    except CatchableError:
      discard

proc listMultiRunContainers*(runId = ""): seq[ContainerInfo] =
  ## Lists Docker containers with multi-run labels.
  var args = @[
    "ps",
    "-a",
    "--filter",
    "label=" & OwnerLabelKey & "=" & OwnerLabelValue
  ]
  if runId.len > 0:
    args.add("--filter")
    args.add("label=" & RunLabel & "=" & runId)
  args.add(@[
    "--format",
    "{{.Names}}"
  ])
  let res = dockerResult(args)
  if res.code != 0:
    return
  var names: seq[string]
  for line in res.output.splitLines():
    let name = line.strip()
    if name.len == 0:
      continue
    names.add(name)
  var i = 0
  while i < names.len:
    let last = min(i + InspectBatchSize, names.len)
    result.add(inspectContainers(names[i ..< last]))
    i = last

proc isActiveContainer*(container: ContainerInfo): bool =
  ## Returns true when a container is still active.
  container.status in ["created", "restarting", "running"]

proc normalExit*(container: ContainerInfo): bool =
  ## Returns true when a stopped container has a normal exit code.
  container.exitCode == 0 or container.exitCode == 143

proc scoreNumber(items: JsonNode, index: int): float =
  ## Reads one numeric score array value.
  if items == nil or index >= items.len:
    return 0
  case items[index].kind
  of JInt:
    result = items[index].getInt().float
  of JFloat:
    result = items[index].getFloat()
  else:
    result = 0

proc scoreInt(items: JsonNode, index: int): int =
  ## Reads one integer score array value.
  if items == nil or index >= items.len:
    return 0
  case items[index].kind
  of JInt:
    result = items[index].getInt()
  of JFloat:
    result = items[index].getFloat().int
  of JBool:
    if items[index].getBool():
      result = 1
  else:
    result = 0

proc scoreString(items: JsonNode, index: int): string =
  ## Reads one string score array value.
  if items != nil and index < items.len and items[index].kind == JString:
    result = items[index].getStr()

proc scoreBool(items: JsonNode, index: int): bool =
  ## Reads one boolean score array value.
  if items != nil and index < items.len and items[index].kind == JBool:
    result = items[index].getBool()

proc jsonArray(node: JsonNode, key: string): JsonNode =
  ## Reads one optional JSON array.
  if node != nil and node.kind == JObject and node.hasKey(key) and
      node[key].kind == JArray:
    return node[key]
  newJArray()

proc jsonArrayAny(node: JsonNode, keys: openArray[string]): JsonNode =
  ## Reads the first present optional JSON array from several keys.
  for key in keys:
    let items = node.jsonArray(key)
    if items.len > 0:
      return items
  newJArray()

proc canonicalScoreField*(name: string): string =
  ## Returns the normalized score field name used by multi-run.
  case name.strip()
  of "names":
    return "name"
  of "scores":
    return "score"
  of "imposters":
    return "imposter"
  of "vote_player":
    return "vote_players"
  else:
    return name.strip()

proc scoreFieldLabel*(name: string): string =
  ## Returns a readable score field label.
  case canonicalScoreField(name)
  of "score":
    return "Score"
  of "tasks":
    return "Tasks"
  of "kills":
    return "Kills"
  of "imposter":
    return "Imposter"
  of "crew":
    return "Crew"
  of "vote_players":
    return "Votes"
  of "vote_skip":
    return "Skips"
  of "vote_timeout":
    return "Timeouts"
  else:
    for part in canonicalScoreField(name).split('_'):
      let clean = part.strip()
      if clean.len == 0:
        continue
      if result.len > 0:
        result.add(" ")
      result.add(clean[0].toUpperAscii())
      if clean.len > 1:
        result.add(clean[1 .. ^1])

proc standardScoreNumberField(name: string): bool =
  ## Returns true for score fields stored on fixed ScoreRow columns.
  case canonicalScoreField(name)
  of "tasks", "kills", "imposter", "crew", "vote_players", "vote_skip",
      "vote_timeout":
    true
  else:
    false

proc hiddenScoreField(name: string): bool =
  ## Returns true for score fields that are not rendered as custom columns.
  case canonicalScoreField(name)
  of "name", "score", "win":
    true
  else:
    false

proc scoreArrayIsNumber(items: JsonNode): bool =
  ## Returns true when a JSON score array is numeric.
  if items == nil or items.kind != JArray:
    return false
  var hasValue = false
  for item in items:
    case item.kind
    of JInt, JFloat:
      hasValue = true
    of JNull:
      discard
    else:
      return false
  hasValue

proc scoreArrayIsText(items: JsonNode): bool =
  ## Returns true when a JSON score array is textual.
  if items == nil or items.kind != JArray:
    return false
  var hasValue = false
  for item in items:
    case item.kind
    of JString, JBool:
      hasValue = true
    of JNull:
      discard
    else:
      return false
  hasValue

proc scoreText(items: JsonNode, index: int): string =
  ## Reads one textual score array value.
  if items == nil or index >= items.len:
    return
  case items[index].kind
  of JString:
    return items[index].getStr()
  of JBool:
    return $items[index].getBool()
  else:
    return ""

proc scoreRowCount(node: JsonNode): int =
  ## Returns the largest score array length in one scores file.
  if node == nil or node.kind != JObject:
    return
  for _, value in node.pairs:
    if value.kind == JArray:
      result = max(result, value.len)

proc addScoreNumberField(
  fields: var seq[ScoreNumberField],
  name: string,
  value: float
) =
  ## Adds one numeric score field to a row or aggregate.
  let key = canonicalScoreField(name)
  for i in 0 ..< fields.len:
    if fields[i].name == key:
      fields[i].value += value
      return
  fields.add(ScoreNumberField(name: key, value: value))

proc addScoreTextField(
  fields: var seq[ScoreTextField],
  name,
  value: string
) =
  ## Adds one text score field to a row.
  fields.add(ScoreTextField(name: canonicalScoreField(name), value: value))

proc addScoreFieldName(fields: var seq[string], name: string) =
  ## Adds one score field name once, preserving discovery order.
  let key = canonicalScoreField(name)
  if key.len == 0:
    return
  for field in fields:
    if field == key:
      return
  fields.add(key)

proc scoreNumberFieldExists*(row: ScoreRow, name: string): bool =
  ## Returns true when a score row has one numeric field.
  let key = canonicalScoreField(name)
  case key
  of "score", "tasks", "kills", "imposter", "crew", "vote_players",
      "vote_skip", "vote_timeout":
    return true
  else:
    for field in row.numbers:
      if field.name == key:
        return true

proc scoreNumberFieldValue*(row: ScoreRow, name: string): float =
  ## Returns one numeric score field value.
  let key = canonicalScoreField(name)
  case key
  of "score":
    return row.score
  of "tasks":
    return row.tasks.float
  of "kills":
    return row.kills.float
  of "imposter":
    return row.imposter.float
  of "crew":
    return row.crew.float
  of "vote_players":
    return row.votePlayers.float
  of "vote_skip":
    return row.voteSkip.float
  of "vote_timeout":
    return row.voteTimeout.float
  else:
    for field in row.numbers:
      if field.name == key:
        return field.value

proc scoreTextFieldExists*(row: ScoreRow, name: string): bool =
  ## Returns true when a score row has one text field.
  let key = canonicalScoreField(name)
  case key
  of "name", "win":
    return true
  else:
    for field in row.texts:
      if field.name == key:
        return true

proc scoreTextFieldValue*(row: ScoreRow, name: string): string =
  ## Returns one text score field value.
  let key = canonicalScoreField(name)
  case key
  of "name":
    return row.name
  of "win":
    return $row.win
  else:
    for field in row.texts:
      if field.name == key:
        return field.value

proc scoreNumberFieldNames*(rows: openArray[ScoreRow]): seq[string] =
  ## Returns custom numeric score field names in discovery order.
  for row in rows:
    for field in row.numbers:
      result.addScoreFieldName(field.name)

proc scoreTextFieldNames*(rows: openArray[ScoreRow]): seq[string] =
  ## Returns custom text score field names in discovery order.
  for row in rows:
    for field in row.texts:
      result.addScoreFieldName(field.name)

proc parseScores*(path: string): seq[ScoreRow] =
  ## Parses one Coworld scores file.
  let node = parseJson(readFile(path))
  let
    names = node.jsonArray("names")
    scores = node.jsonArray("scores")
    wins = node.jsonArray("win")
    tasks = node.jsonArray("tasks")
    kills = node.jsonArray("kills")
    imposters = node.jsonArrayAny(["imposters", "imposter"])
    crews = node.jsonArray("crew")
    votePlayers = node.jsonArrayAny(["vote_player", "vote_players"])
    voteSkips = node.jsonArray("vote_skip")
    voteTimeouts = node.jsonArray("vote_timeout")
    rowCount = node.scoreRowCount()
  for i in 0 ..< rowCount:
    var row = ScoreRow(
      name: names.scoreString(i),
      score: scores.scoreNumber(i),
      win: wins.scoreBool(i),
      tasks: tasks.scoreInt(i),
      kills: kills.scoreInt(i),
      imposter: imposters.scoreInt(i),
      crew: crews.scoreInt(i),
      votePlayers: votePlayers.scoreInt(i),
      voteSkip: voteSkips.scoreInt(i),
      voteTimeout: voteTimeouts.scoreInt(i)
    )
    if node != nil and node.kind == JObject:
      for key, items in node.pairs:
        let field = canonicalScoreField(key)
        if items.kind != JArray or field.hiddenScoreField() or
            field.standardScoreNumberField():
          continue
        if items.scoreArrayIsNumber():
          row.numbers.addScoreNumberField(field, items.scoreNumber(i))
        elif items.scoreArrayIsText():
          row.texts.addScoreTextField(field, items.scoreText(i))
    result.add(row)

proc slotByScoreName*(
  meta: GameMeta,
  name: string
): PlayerSlot =
  ## Finds the configured slot that produced one score row name.
  for slot in meta.slots:
    if slot.playerName == name:
      return slot
  for slot in meta.slots:
    if name.startsWith(slot.player & "-m"):
      return slot

proc scoreFilterActive*(filter: ScoreFilter): bool =
  ## Returns true when a score filter has at least one constraint.
  if filter.names.len > 0 or filter.players.len > 0 or
      filter.roles.len > 0 or filter.wins.len > 0 or
      filter.score.hasMin or filter.score.hasMax or
      filter.tasks.hasMin or filter.tasks.hasMax or
      filter.kills.hasMin or filter.kills.hasMax or
      filter.imposter.hasMin or filter.imposter.hasMax or
      filter.crew.hasMin or filter.crew.hasMax or
      filter.votePlayers.hasMin or filter.votePlayers.hasMax or
      filter.voteSkip.hasMin or filter.voteSkip.hasMax or
      filter.voteTimeout.hasMin or filter.voteTimeout.hasMax:
    return true
  for item in filter.numberRanges:
    if item.scoreRange.hasMin or item.scoreRange.hasMax:
      return true
  for item in filter.textValues:
    if item.values.len > 0:
      return true

proc scoreRangeMatches*(value: float, scoreRange: ScoreRange): bool =
  ## Returns true when one numeric score field passes a range filter.
  if scoreRange.hasMin and value < scoreRange.minValue:
    return false
  if scoreRange.hasMax and value > scoreRange.maxValue:
    return false
  true

proc scoreTextMatches(value: string, values: openArray[string]): bool =
  ## Returns true when a text score field passes a checkbox filter.
  if values.len == 0:
    return true
  value in values

proc scoreRangeActive(scoreRange: ScoreRange): bool =
  ## Returns true when a numeric score range has at least one bound.
  scoreRange.hasMin or scoreRange.hasMax

proc scoreFilterNumberRange*(
  filter: ScoreFilter,
  name: string
): ScoreRange =
  ## Returns one custom numeric score filter range.
  let key = canonicalScoreField(name)
  for item in filter.numberRanges:
    if item.name == key:
      return item.scoreRange

proc setScoreFilterNumberRange*(
  filter: var ScoreFilter,
  name: string,
  scoreRange: ScoreRange
) =
  ## Sets one custom numeric score filter range.
  let key = canonicalScoreField(name)
  for i in 0 ..< filter.numberRanges.len:
    if filter.numberRanges[i].name == key:
      filter.numberRanges[i].scoreRange = scoreRange
      return
  filter.numberRanges.add(ScoreNumberRange(
    name: key,
    scoreRange: scoreRange
  ))

proc addScoreFilterTextValue*(
  filter: var ScoreFilter,
  name,
  value: string
) =
  ## Adds one custom text score filter value.
  let
    key = canonicalScoreField(name)
    text = value.strip()
  if key.len == 0 or text.len == 0:
    return
  for i in 0 ..< filter.textValues.len:
    if filter.textValues[i].name == key:
      filter.textValues[i].values.add(text)
      return
  filter.textValues.add(ScoreTextValues(name: key, values: @[text]))

proc scoreRecordMatches*(
  record: ScoreRecord,
  filter: ScoreFilter
): bool =
  ## Returns true when one score record passes a score filter.
  if not scoreTextMatches(record.row.name, filter.names):
    return false
  if not scoreTextMatches(record.player, filter.players):
    return false
  if not scoreTextMatches(record.role, filter.roles):
    return false
  if not scoreTextMatches($record.row.win, filter.wins):
    return false
  if not scoreRangeMatches(record.row.score, filter.score):
    return false
  if not scoreRangeMatches(record.row.tasks.float, filter.tasks):
    return false
  if not scoreRangeMatches(record.row.kills.float, filter.kills):
    return false
  if not scoreRangeMatches(record.row.imposter.float, filter.imposter):
    return false
  if not scoreRangeMatches(record.row.crew.float, filter.crew):
    return false
  if not scoreRangeMatches(
    record.row.votePlayers.float,
    filter.votePlayers
  ):
    return false
  if not scoreRangeMatches(record.row.voteSkip.float, filter.voteSkip):
    return false
  if not scoreRangeMatches(record.row.voteTimeout.float, filter.voteTimeout):
    return false
  for item in filter.numberRanges:
    if not item.scoreRange.scoreRangeActive():
      continue
    if not record.row.scoreNumberFieldExists(item.name):
      return false
    if not scoreRangeMatches(
      record.row.scoreNumberFieldValue(item.name),
      item.scoreRange
    ):
      return false
  for item in filter.textValues:
    if item.values.len == 0:
      continue
    if not record.row.scoreTextFieldExists(item.name):
      return false
    if not scoreTextMatches(
      record.row.scoreTextFieldValue(item.name),
      item.values
    ):
      return false
  true

proc scoreRecords*(runDir: string): seq[ScoreRecord] =
  ## Reads all score rows with game, player, and role metadata.
  for meta in readGameMetas(runDir):
    let path = runDir / meta.results.extractFilename()
    if not fileExists(path):
      continue
    for row in parseScores(path):
      let slot = meta.slotByScoreName(row.name)
      let player =
        if slot.player.len > 0:
          slot.player
        else:
          row.name
      result.add(ScoreRecord(
        gameIndex: meta.gameIndex,
        row: row,
        player: player,
        role: slot.role
      ))

proc scoreRecords*(runDir: string, meta: GameMeta): seq[ScoreRecord] =
  ## Reads score rows with metadata for one game.
  let path = runDir / meta.results.extractFilename()
  if not fileExists(path):
    return
  for row in parseScores(path):
    let slot = meta.slotByScoreName(row.name)
    let player =
      if slot.player.len > 0:
        slot.player
      else:
        row.name
    result.add(ScoreRecord(
      gameIndex: meta.gameIndex,
      row: row,
      player: player,
      role: slot.role
    ))

proc scoreNumberFieldNames*(records: openArray[ScoreRecord]): seq[string] =
  ## Returns custom numeric score field names in discovery order.
  for record in records:
    for field in record.row.numbers:
      result.addScoreFieldName(field.name)

proc scoreTextFieldNames*(records: openArray[ScoreRecord]): seq[string] =
  ## Returns custom text score field names in discovery order.
  for record in records:
    for field in record.row.texts:
      result.addScoreFieldName(field.name)

proc filterScoreRecords*(
  records: openArray[ScoreRecord],
  filter: ScoreFilter
): seq[ScoreRecord] =
  ## Returns score records that pass a score filter.
  if not scoreFilterActive(filter):
    for record in records:
      result.add(record)
    return
  for record in records:
    if record.scoreRecordMatches(filter):
      result.add(record)

proc filteredScoreRecords*(
  runDir: string,
  filter: ScoreFilter
): seq[ScoreRecord] =
  ## Reads score records and applies a score filter.
  filterScoreRecords(scoreRecords(runDir), filter)

proc applyScore(
  aggregates: var Table[string, PlayerAggregate],
  key: string,
  player: string,
  role: string,
  row: ScoreRow
) =
  ## Applies one score row to an aggregate table.
  var item = aggregates.getOrDefault(key)
  if item.player.len == 0:
    item.player = player
    item.role = role
  inc item.games
  if row.win:
    inc item.wins
  item.scoreSum += row.score
  item.scoreSquaresSum += row.score * row.score
  if item.games == 1:
    item.scoreMin = row.score
    item.scoreMax = row.score
  else:
    item.scoreMin = min(item.scoreMin, row.score)
    item.scoreMax = max(item.scoreMax, row.score)
  item.tasksSum += row.tasks
  item.killsSum += row.kills
  item.imposterSum += row.imposter
  item.crewSum += row.crew
  item.votePlayersSum += row.votePlayers
  item.voteSkipSum += row.voteSkip
  item.voteTimeoutSum += row.voteTimeout
  for field in row.numbers:
    item.numberSums.addScoreNumberField(field.name, field.value)
  aggregates[key] = item

proc scoreAverage*(item: PlayerAggregate): float =
  ## Returns the average score for one aggregate player row.
  if item.games <= 0:
    return 0
  item.scoreSum / item.games.float

proc scoreStdDev*(item: PlayerAggregate): float =
  ## Returns the population standard deviation for a player's scores.
  if item.games <= 0:
    return 0
  let
    mean = item.scoreAverage()
    variance = item.scoreSquaresSum / item.games.float - mean * mean
  sqrt(max(0.0, variance))

proc scoreNumberSum*(item: PlayerAggregate, name: string): float =
  ## Returns the total value for one aggregate numeric score field.
  case canonicalScoreField(name)
  of "score":
    return item.scoreSum
  of "tasks":
    return item.tasksSum.float
  of "kills":
    return item.killsSum.float
  of "imposter":
    return item.imposterSum.float
  of "crew":
    return item.crewSum.float
  of "vote_players":
    return item.votePlayersSum.float
  of "vote_skip":
    return item.voteSkipSum.float
  of "vote_timeout":
    return item.voteTimeoutSum.float
  else:
    for field in item.numberSums:
      if field.name == canonicalScoreField(name):
        return field.value

proc scoreNumberAverage*(item: PlayerAggregate, name: string): float =
  ## Returns the per-game average for one aggregate numeric score field.
  if item.games <= 0:
    return 0
  item.scoreNumberSum(name) / item.games.float

proc scoreBucketStart*(score: float): int =
  ## Returns the lower bound for one ten-point score bucket.
  floor(score / ScoreHistogramBinSize.float).int * ScoreHistogramBinSize

proc scoreHistogramLabel*(start: int): string =
  ## Returns one score bucket lower-bound label.
  $start

proc scoreHistogramLabels*(bucketMin, bucketMax: int): seq[string] =
  ## Returns score histogram labels for a dynamic bucket range.
  if bucketMax < bucketMin:
    return
  var start = bucketMin
  while start <= bucketMax:
    result.add(scoreHistogramLabel(start))
    start += ScoreHistogramBinSize

proc scoreBucketIndex*(score: float, bucketMin: int): int =
  ## Returns the bucket index for one score in a dynamic bucket range.
  (scoreBucketStart(score) - bucketMin) div ScoreHistogramBinSize

proc applyHistogramScore(
  histograms: var Table[string, ScoreHistogram],
  player: string,
  score: float,
  bucketMin: int,
  bucketCount: int
) =
  ## Adds one raw score to a player histogram.
  if bucketCount <= 0:
    return
  var item = histograms.getOrDefault(player)
  if item.player.len == 0:
    item.player = player
    item.bucketMin = bucketMin
    item.bins = newSeq[int](bucketCount)
  let index = clamp(scoreBucketIndex(score, bucketMin), 0, bucketCount - 1)
  inc item.bins[index]
  inc item.total
  histograms[player] = item

proc averageGameScores*(
  records: openArray[ScoreRecord],
  gameIndex: int
): Table[string, float] =
  ## Returns average score by bot/player kind for one game index.
  var
    sums: Table[string, float]
    counts: Table[string, int]
  for record in records:
    if record.gameIndex != gameIndex:
      continue
    sums[record.player] = sums.getOrDefault(record.player) + record.row.score
    counts[record.player] = counts.getOrDefault(record.player) + 1
  for player, sum in sums.pairs:
    let count = counts.getOrDefault(player)
    if count > 0:
      result[player] = sum / count.float

proc averageGameScores*(
  runDir: string,
  meta: GameMeta,
  filter: ScoreFilter = ScoreFilter()
): Table[string, float] =
  ## Returns filtered average score by bot/player kind for one game.
  averageGameScores(
    filterScoreRecords(scoreRecords(runDir, meta), filter),
    meta.gameIndex
  )

proc scoreHistograms*(
  records: openArray[ScoreRecord]
): seq[ScoreHistogram] =
  ## Builds raw score histograms by bot/player kind from score records.
  var
    scores: seq[tuple[player: string, score: float]]
    bucketMin: int
    bucketMax: int
    hasScore = false
  for record in records:
    let bucket = scoreBucketStart(record.row.score)
    scores.add((record.player, record.row.score))
    if not hasScore:
      bucketMin = bucket
      bucketMax = bucket
      hasScore = true
    else:
      bucketMin = min(bucketMin, bucket)
      bucketMax = max(bucketMax, bucket)
  if not hasScore:
    return
  let bucketCount =
    (bucketMax - bucketMin) div ScoreHistogramBinSize + 1
  var histograms: Table[string, ScoreHistogram]
  for item in scores:
    histograms.applyHistogramScore(
      item.player,
      item.score,
      bucketMin,
      bucketCount
    )
  for _, item in histograms.pairs:
    result.add(item)
  result.sort(proc(a, b: ScoreHistogram): int = cmp(a.player, b.player))

proc runScoreHistograms*(
  runDir: string,
  filter: ScoreFilter = ScoreFilter()
): seq[ScoreHistogram] =
  ## Builds filtered raw score histograms by bot/player kind for one run.
  scoreHistograms(filteredScoreRecords(runDir, filter))

proc aggregateScoreRecords*(
  records: openArray[ScoreRecord]
): seq[PlayerAggregate] =
  ## Aggregates score records by bot/player kind.
  var aggregates: Table[string, PlayerAggregate]
  for record in records:
    let role =
      if record.role.len > 0:
        record.role
      else:
        "-"
    aggregates.applyScore(record.player, record.player, role, record.row)
  for _, item in aggregates.pairs:
    result.add(item)
  result.sort(proc(a, b: PlayerAggregate): int =
    result = cmp(b.scoreAverage(), a.scoreAverage())
    if result != 0:
      return
    result = cmp(a.player, b.player)
  )

proc aggregateRunScores*(
  runDir: string,
  filter: ScoreFilter = ScoreFilter()
): seq[PlayerAggregate] =
  ## Aggregates filtered scores in one durable multi-run folder.
  aggregateScoreRecords(filteredScoreRecords(runDir, filter))

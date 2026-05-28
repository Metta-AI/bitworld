import
  std/[
    algorithm, httpclient, json, net, os, osproc, parseopt, strutils, sysrand,
    times, uri
  ]

const
  DockerBinEnv = "GAMES_SERVER_DOCKER"
  ReplayDirEnv = "GAMES_SERVER_REPLAY_DIR"
  GameMemoryEnv = "GAMES_SERVER_GAME_MEMORY"
  GameCpusEnv = "GAMES_SERVER_GAME_CPUS"
  GamePidsEnv = "GAMES_SERVER_GAME_PIDS"
  BotMemoryEnv = "GAMES_SERVER_BOT_MEMORY"
  BotCpusEnv = "GAMES_SERVER_BOT_CPUS"
  BotPidsEnv = "GAMES_SERVER_BOT_PIDS"
  DefaultGameMemory = "6g"
  DefaultGameCpus = "4"
  DefaultGamePids = "512"
  DefaultBotMemory = "1g"
  DefaultBotCpus = "1"
  DefaultBotPids = "128"
  GameContainerPort = 8080
  CoworldManifestName = "coworld_manifest.json"
  CoplayerManifestName = "coplayer_manifest.json"
  GamesDir = "games_server" / "games"
  PlayersDir = "games_server" / "players"
  ReplaysDir = "games_server" / "replays"
  ReplayMountDir = "/replays"
  ServerLabelKey = "bitworld.games_server"
  ServerLabelValue = "among_them"
  BotLabelValue = "among_them_bot"
  ServerLabel = ServerLabelKey & "=" & ServerLabelValue
  BotLabel = ServerLabelKey & "=" & BotLabelValue
  PortLabel = "bitworld.games_server.port"
  CreatedLabel = "bitworld.games_server.created"
  ReplayLabel = "bitworld.games_server.replay"
  KindLabel = "bitworld.games_server.kind"
  GameManifestLabel = "bitworld.games_server.manifest"
  GameNameLabel = "bitworld.games_server.game_name"
  BotGameLabel = "bitworld.games_server.game"
  BotKindLabel = "bitworld.games_server.bot"
  LiveKind = "game"
  CogameReplayUriEnv = "COGAME_SAVE_REPLAY_URI"
  CogameResultsUriEnv = "COGAME_RESULTS_URI"
  CogameConfigUriEnv = "COGAME_CONFIG_URI"
  CogameHostEnv = "COGAME_HOST"
  CogamePortEnv = "COGAME_PORT"
  EngineWsEnv = "COGAMES_ENGINE_WS_URL"
  PlayerWebSocketPath = "/player"
  HealthPath = "/healthz"
  BotHost = "host.docker.internal"
  AiKeyEnvNames = ["CLAUDE_KEY", "GEMINI_KEY", "OPENAI_KEY", "XAI_KEY"]
  MaxBotsPerGame = 64
  DefaultHealthTimeoutSeconds = 45.0

type
  StartAllGamesError = object of CatchableError

  LaunchSpec = object
    game: string
    bot: string
    count: int

  ToolArgs = object
    repoRoot: string
    replayDir: string
    dockerBin: string
    dryRun: bool
    skipPull: bool
    onlyGame: string
    healthTimeoutSeconds: float

  GameManifest = object
    key: string
    path: string
    name: string
    image: string
    command: seq[string]
    env: seq[(string, string)]
    configSchema: JsonNode
    variantConfig: JsonNode

  PlayerManifest = object
    path: string
    name: string
    image: string
    command: seq[string]
    env: seq[(string, string)]
    games: seq[string]

  GameLaunch = object
    name: string
    port: int
    created: int64
    replay: string
    config: string
    tokens: seq[string]
    manifest: GameManifest

  DockerResult = object
    code: int
    output: string

const
  Launches = [
    LaunchSpec(game: "asteroid_arena", bot: "shooter", count: 4),
    LaunchSpec(game: "among_them", bot: "ivotewell", count: 8),
    LaunchSpec(game: "big_adventure", bot: "konrad", count: 4),
    LaunchSpec(game: "crewrift", bot: "notsus", count: 8),
    LaunchSpec(game: "heartleaf", bot: "villager", count: 9),
    LaunchSpec(game: "infinite_blocks", bot: "stacker", count: 4),
    LaunchSpec(game: "jumper", bot: "dalli", count: 7),
    LaunchSpec(game: "planet_wars", bot: "skurge", count: 8),
  ]

proc fail(message: string) =
  ## Raises one start-all-games error.
  raise newException(StartAllGamesError, message)

proc repoRoot(): string =
  ## Returns the BitWorld repository root containing this tool.
  parentDir(parentDir(currentSourcePath()))

proc envValue(name, defaultValue: string): string =
  ## Reads one environment value with a fallback.
  result = getEnv(name, defaultValue).strip()
  if result.len == 0:
    result = defaultValue

proc usage(): string =
  ## Returns command-line usage text.
  """
Usage:
  start_all_games [options]

Options:
  --game:<name>       Start only one configured game.
  --repo:<path>       BitWorld repo root. Default: this repo.
  --replays:<path>    Replay/config output directory.
  --docker:<path>     Docker command. Default: docker or env override.
  --timeout:<seconds> Health check timeout. Default: 45.
  --skip-pull         Do not pull Docker images before starting.
  --dry-run           Print Docker commands without running them.
  --help              Show this help.
"""

proc parseFloatOption(value, option: string): float =
  ## Parses one floating-point option.
  try:
    result = value.parseFloat()
  except ValueError:
    fail(option & " must be a number")

proc parseArgs(): ToolArgs =
  ## Parses command-line arguments.
  result.repoRoot = repoRoot()
  result.replayDir = envValue(ReplayDirEnv, repoRoot() / ReplaysDir)
  result.dockerBin = envValue(DockerBinEnv, "docker")
  result.healthTimeoutSeconds = DefaultHealthTimeoutSeconds
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "game":
        result.onlyGame = val.strip()
      of "repo":
        result.repoRoot = absolutePath(val)
      of "replays":
        result.replayDir = absolutePath(val)
      of "docker":
        result.dockerBin = val
      of "timeout":
        result.healthTimeoutSeconds = parseFloatOption(val, "--timeout")
      of "skip-pull":
        result.skipPull = true
      of "dry-run":
        result.dryRun = true
      of "help":
        echo usage()
        quit(0)
      else:
        fail("unknown option: --" & key)
    of cmdShortOption:
      case key
      of "h":
        echo usage()
        quit(0)
      else:
        fail("unknown option: -" & key)
    of cmdArgument:
      fail("unexpected argument: " & key)
    of cmdEnd:
      discard
  result.repoRoot = result.repoRoot.normalizedPath()
  result.replayDir = result.replayDir.normalizedPath()

proc cleanContainerName(value: string): string =
  ## Keeps only Docker-safe container name characters.
  for c in value:
    if c.isAlphaNumeric() or c == '_' or c == '-' or c == '.':
      result.add(c)
  if result.len > 128:
    result = result[0 .. 127]

proc displayWord(value: string): string =
  ## Converts one manifest word into a display word.
  if value.len == 0:
    return ""
  result.add(value[0].toUpperAscii())
  if value.len > 1:
    result.add(value[1 .. ^1].toLowerAscii())

proc botDisplayName(name: string): string =
  ## Builds a compact display base name for one bot.
  var words: seq[string]
  for part in name.split({'-', '_', '.', ' '}):
    if part.len > 0:
      words.add(displayWord(part))
  if words.len == 0:
    return "Bot"
  words.join("")

proc botPlayerName(botName: string, slot: int): string =
  ## Builds one visible in-game bot name.
  botDisplayName(botName) & $(slot + 1)

proc readJson(path: string): JsonNode =
  ## Reads one JSON object from disk.
  try:
    result = parseFile(path)
  except CatchableError as e:
    fail("could not parse " & path & ": " & e.msg)
  if result.kind != JObject:
    fail(path & " must contain a JSON object")

proc manifestString(node: JsonNode, key, defaultValue: string): string =
  ## Reads one optional string field.
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    return node[key].getStr()
  defaultValue

proc requireString(node: JsonNode, key, path: string): string =
  ## Reads one required non-empty string field.
  result = node.manifestString(key, "")
  if result.len == 0:
    fail(path & " missing " & key)

proc manifestObject(node: JsonNode, key: string): JsonNode =
  ## Reads one optional object field.
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JObject:
    return node[key]

proc manifestStringArray(node: JsonNode, key: string): seq[string] =
  ## Reads one optional string array field.
  if node.kind != JObject or not node.hasKey(key) or node[key].kind != JArray:
    return
  for item in node[key]:
    if item.kind == JString:
      result.add(item.getStr())

proc manifestImage(node: JsonNode): string =
  ## Reads a game or player image from a manifest node.
  let runnable = node.manifestObject("runnable")
  if not runnable.isNil:
    result = runnable.manifestString("image", "")
  if result.len == 0:
    result = node.manifestString("image", "")
  if result.len == 0:
    result = node.manifestString("image_uri", "")

proc manifestCommand(node: JsonNode): seq[string] =
  ## Reads the run command from a manifest node.
  let runnable = node.manifestObject("runnable")
  if not runnable.isNil:
    result = runnable.manifestStringArray("run")
  if result.len == 0:
    result = node.manifestStringArray("run")
  if result.len == 0:
    let binary = node.manifestString("binary", "")
    if binary.len > 0:
      result.add(binary)

proc manifestEnv(node: JsonNode): seq[(string, string)] =
  ## Reads string environment entries from a manifest node.
  if node.kind != JObject or not node.hasKey("env") or node["env"].kind != JObject:
    return
  for key, value in node["env"].pairs:
    if value.kind == JString:
      result.add((key, value.getStr()))

proc manifestKey(repoRoot, path: string): string =
  ## Returns the game-server manifest key for one path.
  let prefix = (repoRoot / GamesDir) & DirSep
  if path.startsWith(prefix):
    result = path[prefix.len .. ^1]
  else:
    result = path
  result = result.replace("\\", "/")

proc firstVariantConfig(manifest: JsonNode): JsonNode =
  ## Reads the first Coworld variant config object.
  result = newJObject()
  if manifest.kind != JObject or not manifest.hasKey("variants") or
      manifest["variants"].kind != JArray:
    return
  for variant in manifest["variants"]:
    if variant.kind == JObject and variant.hasKey("game_config") and
        variant["game_config"].kind == JObject:
      return variant["game_config"]

proc readGameManifest(repoRoot, path: string): GameManifest =
  ## Reads one Coworld game manifest.
  let
    manifest = readJson(path)
    game = manifest.manifestObject("game")
  if game.isNil:
    fail(path & " missing game")
  result.name = game.requireString("name", path & ".game")
  result.image = game.manifestImage()
  if result.image.len == 0:
    fail(path & " missing game image")
  result.key = manifestKey(repoRoot, path)
  result.path = path
  result.command = game.manifestCommand()
  result.env = game.manifestEnv()
  if game.hasKey("config_schema") and game["config_schema"].kind == JObject:
    result.configSchema = game["config_schema"]
  else:
    result.configSchema = newJObject()
  result.variantConfig = firstVariantConfig(manifest)

proc readEmbeddedPlayers(path: string, gameName: string): seq[PlayerManifest] =
  ## Reads embedded Coworld player manifests from one game manifest.
  let manifest = readJson(path)
  if not manifest.hasKey("player") or manifest["player"].kind != JArray:
    return
  for player in manifest["player"]:
    if player.kind != JObject:
      continue
    let
      name = player.manifestString("id", player.manifestString("name", ""))
      image = player.manifestImage()
    if name.len == 0 or image.len == 0:
      continue
    result.add(PlayerManifest(
      path: path,
      name: name,
      image: image,
      command: player.manifestCommand(),
      env: player.manifestEnv(),
      games: @[gameName]
    ))

proc readPlayerManifest(path: string): PlayerManifest =
  ## Reads one standalone Coplayer manifest.
  let manifest = readJson(path)
  result.path = path
  result.name = manifest.requireString("name", path)
  result.image = manifest.manifestImage()
  if result.image.len == 0:
    fail(path & " missing image")
  result.command = manifest.manifestCommand()
  result.env = manifest.manifestEnv()
  result.games = manifest.manifestStringArray("games")

proc listGames(args: ToolArgs): seq[GameManifest] =
  ## Lists game manifests from games_server/games.
  for path in walkFiles(args.repoRoot / GamesDir / "*" / CoworldManifestName):
    result.add(readGameManifest(args.repoRoot, path))
  result.sort(proc(a, b: GameManifest): int = cmp(a.name, b.name))

proc listPlayers(args: ToolArgs): seq[PlayerManifest] =
  ## Lists standalone and embedded player manifests.
  for path in walkFiles(args.repoRoot / PlayersDir / "*" / CoplayerManifestName):
    result.add(readPlayerManifest(path))
  for game in listGames(args):
    for player in readEmbeddedPlayers(game.path, game.name):
      var exists = false
      for existing in result:
        if existing.name == player.name:
          exists = true
          break
      if not exists:
        result.add(player)

proc supports(player: PlayerManifest, game: string): bool =
  ## Returns true when a player supports one game.
  for supported in player.games:
    if supported == game:
      return true

proc findGame(games: openArray[GameManifest], name: string): GameManifest =
  ## Finds one game manifest by name.
  for game in games:
    if game.name == name:
      return game
  fail("unknown game manifest: " & name)

proc findPlayer(
  players: openArray[PlayerManifest],
  game,
  name: string
): PlayerManifest =
  ## Finds one player manifest by game and name.
  for player in players:
    if player.name == name and player.supports(game):
      return player
  fail("unknown player " & name & " for game " & game)

proc randomToken(): string =
  ## Generates one opaque player token.
  var bytes: array[16, byte]
  if not urandom(bytes):
    fail("could not generate player token")
  for b in bytes:
    result.add(b.toHex(2).toLowerAscii())

proc schemaProperty(schema: JsonNode, key: string): JsonNode =
  ## Returns one config schema property when present.
  if schema.kind != JObject or not schema.hasKey("properties") or
      schema["properties"].kind != JObject:
    return nil
  if schema["properties"].hasKey(key) and schema["properties"][key].kind == JObject:
    return schema["properties"][key]

proc propertyInt(node: JsonNode, key: string, defaultValue: int): int =
  ## Reads one integer property value.
  if node != nil and node.kind == JObject and node.hasKey(key) and
      node[key].kind == JInt:
    return node[key].getInt()
  defaultValue

proc propertyDefault(node: JsonNode): JsonNode =
  ## Reads a JSON schema default value.
  if node != nil and node.kind == JObject and node.hasKey("default"):
    return node["default"].copy()
  nil

proc propertyType(node: JsonNode): string =
  ## Reads one JSON schema property type.
  if node != nil and node.kind == JObject:
    return node.manifestString("type", "string")
  "string"

proc defaultValue(property: JsonNode): JsonNode =
  ## Builds a neutral default value for one schema property.
  let value = property.propertyDefault()
  if value != nil:
    return value
  case property.propertyType()
  of "integer":
    %0
  of "number":
    %0.0
  of "boolean":
    %false
  of "array":
    newJArray()
  of "object":
    newJObject()
  else:
    %""

proc tokenCount(game: GameManifest, botCount: int): int =
  ## Returns how many player tokens should be generated.
  let tokens = game.configSchema.schemaProperty("tokens")
  if tokens.isNil:
    return 0
  result = max(botCount, tokens.propertyInt("minItems", 0))
  let maxItems = tokens.propertyInt("maxItems", 0)
  if maxItems > 0:
    result = min(result, maxItems)

proc buildConfig(game: GameManifest, botCount: int): string =
  ## Builds one default game config JSON string.
  var config = newJObject()
  if game.configSchema.kind == JObject and game.configSchema.hasKey("properties") and
      game.configSchema["properties"].kind == JObject:
    for name, property in game.configSchema["properties"].pairs:
      if name == "tokens":
        let tokens = newJArray()
        for _ in 0 ..< game.tokenCount(botCount):
          tokens.add(%randomToken())
        config[name] = tokens
      elif game.variantConfig.kind == JObject and game.variantConfig.hasKey(name):
        config[name] = game.variantConfig[name].copy()
      else:
        config[name] = property.defaultValue()
  $config

proc configTokens(config: string): seq[string] =
  ## Reads player tokens from one config JSON string.
  let node = parseJson(config)
  if node.kind != JObject or not node.hasKey("tokens") or
      node["tokens"].kind != JArray:
    return
  for item in node["tokens"]:
    if item.kind == JString:
      result.add(item.getStr())

proc replayName(containerName: string): string =
  ## Builds one replay file name.
  cleanContainerName(containerName) & ".bitreplay"

proc scoresName(replay: string): string =
  ## Builds one scores file name.
  if replay.endsWith(".bitreplay"):
    replay[0 ..< replay.len - ".bitreplay".len] & ".scores.json"
  else:
    replay & ".scores.json"

proc configName(replay: string): string =
  ## Builds one config file name.
  if replay.endsWith(".bitreplay"):
    replay[0 ..< replay.len - ".bitreplay".len] & ".config.json"
  else:
    replay & ".config.json"

proc findOpenPort(): int =
  ## Asks the OS to reserve and report one free host port.
  var socket = newSocket()
  try:
    socket.setSockOpt(OptReuseAddr, true)
    socket.bindAddr(Port(0), "0.0.0.0")
    let (_, port) = socket.getLocalAddr()
    result = port.int
  finally:
    socket.close()
  if result <= 0:
    fail("OS returned an invalid free port")

proc addResourceArgs(
  dockerArgs: var seq[string],
  memory,
  cpus,
  pids: string
) =
  ## Adds Docker resource limit arguments.
  if memory.len > 0:
    dockerArgs.add("--memory")
    dockerArgs.add(memory)
    dockerArgs.add("--memory-swap")
    dockerArgs.add(memory)
  if cpus.len > 0:
    dockerArgs.add("--cpus")
    dockerArgs.add(cpus)
  if pids.len > 0:
    dockerArgs.add("--pids-limit")
    dockerArgs.add(pids)

proc addAiEnvArgs(dockerArgs: var seq[string]) =
  ## Adds Docker environment forwarding for configured AI keys.
  for name in AiKeyEnvNames:
    if getEnv(name).len > 0:
      dockerArgs.add("-e")
      dockerArgs.add(name)

proc containerPath(replayDir, fileName: string): string =
  ## Returns one path inside the game container replay mount.
  ReplayMountDir / fileName

proc dockerRunGameArgs(args: ToolArgs, launch: GameLaunch): seq[string] =
  ## Builds Docker arguments for one game container.
  result = @[
    "run",
    "-d",
    "--init",
    "--add-host=host.docker.internal:host-gateway",
    "--name", launch.name,
    "-p", $launch.port & ":" & $GameContainerPort,
    "--label", ServerLabel,
    "--label", PortLabel & "=" & $launch.port,
    "--label", CreatedLabel & "=" & $launch.created,
    "--label", ReplayLabel & "=" & launch.replay,
    "--label", KindLabel & "=" & LiveKind,
    "--label", GameNameLabel & "=" & launch.manifest.name,
    "--label", GameManifestLabel & "=" & launch.manifest.key,
  ]
  result.addResourceArgs(
    envValue(GameMemoryEnv, DefaultGameMemory),
    envValue(GameCpusEnv, DefaultGameCpus),
    envValue(GamePidsEnv, DefaultGamePids)
  )
  result.add("-v")
  result.add(args.replayDir & ":" & ReplayMountDir)
  result.add("-e")
  result.add(CogameHostEnv & "=0.0.0.0")
  result.add("-e")
  result.add(CogamePortEnv & "=" & $GameContainerPort)
  result.add("-e")
  result.add(CogameReplayUriEnv & "=file://" & containerPath(
    args.replayDir,
    launch.replay
  ))
  result.add("-e")
  result.add(CogameResultsUriEnv & "=file://" & containerPath(
    args.replayDir,
    scoresName(launch.replay)
  ))
  result.add("-e")
  result.add(CogameConfigUriEnv & "=file://" & containerPath(
    args.replayDir,
    configName(launch.replay)
  ))
  result.addAiEnvArgs()
  for (key, value) in launch.manifest.env:
    result.add("-e")
    result.add(key & "=" & value)
  result.add(launch.manifest.image)
  for token in launch.manifest.command:
    result.add(token)

proc playerWsUrl(
  host: string,
  port: int,
  playerName: string,
  slot: int,
  token: string
): string =
  ## Builds the player WebSocket URL for one bot.
  var query = "name=" & encodeUrl(playerName, false)
  query.add("&slot=" & encodeUrl($slot, false))
  if token.len > 0:
    query.add("&token=" & encodeUrl(token, false))
  "ws://" & host & ":" & $port & PlayerWebSocketPath & "?" & query

proc launchStamp(index: int): string =
  ## Builds one compact unique launch suffix.
  $(int64(epochTime() * 1000)) & "_" & $index

proc botContainerName(
  game: GameLaunch,
  player: PlayerManifest,
  index: int
): string =
  ## Builds one bot container name.
  game.manifest.name & "_bot_" & cleanContainerName(player.name) & "_" &
    $game.port & "_" & launchStamp(index)

proc dockerRunBotArgs(
  game: GameLaunch,
  player: PlayerManifest,
  slot: int,
  token: string,
  name: string
): seq[string] =
  ## Builds Docker arguments for one bot container.
  let
    created = getTime().toUnix()
    displayName = botPlayerName(player.name, slot)
    endpoint = playerWsUrl(BotHost, game.port, displayName, slot, token)
  result = @[
    "run",
    "-d",
    "--init",
    "--add-host=host.docker.internal:host-gateway",
    "--name", name,
    "--label", BotLabel,
    "--label", BotGameLabel & "=" & game.name,
    "--label", BotKindLabel & "=" & player.name,
    "--label", CreatedLabel & "=" & $created,
  ]
  result.addResourceArgs(
    envValue(BotMemoryEnv, DefaultBotMemory),
    envValue(BotCpusEnv, DefaultBotCpus),
    envValue(BotPidsEnv, DefaultBotPids)
  )
  result.addAiEnvArgs()
  result.add("-e")
  result.add(EngineWsEnv & "=" & endpoint)
  for (key, value) in player.env:
    result.add("-e")
    result.add(key & "=" & value)
  result.add(player.image)
  for token in player.command:
    result.add(token)

proc runDocker(args: ToolArgs, dockerArgs: openArray[string]): DockerResult =
  ## Runs Docker with captured output.
  let command = quoteShellCommand(@[args.dockerBin] & @dockerArgs)
  if args.dryRun:
    echo command
    return DockerResult(code: 0, output: "")
  let (output, exitCode) = execCmdEx(command)
  result.output = output
  result.code = exitCode

proc requireDocker(args: ToolArgs, dockerArgs: openArray[string]) =
  ## Runs Docker and raises on failure.
  try:
    let result = runDocker(args, dockerArgs)
    if result.output.strip().len > 0:
      echo result.output.strip()
    if result.code != 0:
      fail(
        "docker " & dockerArgs.join(" ") &
          " exited with " & $result.code
      )
  except CatchableError as e:
    fail("docker " & dockerArgs.join(" ") & " failed: " & e.msg)

proc pullImage(args: ToolArgs, image: string) =
  ## Pulls one Docker image unless disabled.
  if args.skipPull:
    echo "Skipping Docker image pull: ", image
    return
  echo "Pulling ", image
  args.requireDocker(@["pull", image])

proc healthUrl(port: int): string =
  ## Builds one local game health URL.
  "http://127.0.0.1:" & $port & HealthPath

proc waitForHealthy(port: int, timeoutSeconds: float): bool =
  ## Waits until one game container answers health checks.
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    try:
      let client = newHttpClient(timeout = 1000)
      try:
        let body = client.getContent(healthUrl(port))
        if body.len >= 0:
          return true
      finally:
        client.close()
    except CatchableError:
      discard
    sleep(250)

proc removeContainers(args: ToolArgs, names: openArray[string]) =
  ## Removes containers after a failed launch.
  for name in names:
    if name.len > 0:
      try:
        args.requireDocker(@["rm", "-f", name])
      except CatchableError:
        discard

proc makeLaunch(
  game: GameManifest,
  botCount: int
): GameLaunch =
  ## Builds one game launch record.
  let
    port = findOpenPort()
    created = getTime().toUnix()
    name = cleanContainerName(game.name) & "_game_" & $port & "_" & $created
    replay = replayName(name)
    config = buildConfig(game, botCount)
  GameLaunch(
    name: name,
    port: port,
    created: created,
    replay: replay,
    config: config,
    tokens: configTokens(config),
    manifest: game
  )

proc writeConfig(args: ToolArgs, launch: GameLaunch) =
  ## Writes one launch config into the replay directory.
  if args.dryRun:
    return
  createDir(args.replayDir)
  writeFile(args.replayDir / configName(launch.replay), launch.config)

proc launchGame(
  args: ToolArgs,
  game: GameManifest,
  player: PlayerManifest,
  count: int
) =
  ## Starts one game and its configured bots.
  let launch = makeLaunch(game, count)
  var launched: seq[string]
  echo "Starting ", game.name, " on port ", launch.port,
    " with ", count, " ", player.name, " bots"
  args.pullImage(game.image)
  args.pullImage(player.image)
  writeConfig(args, launch)
  try:
    args.requireDocker(dockerRunGameArgs(args, launch))
    launched.add(launch.name)
    if not args.dryRun and not waitForHealthy(
      launch.port,
      args.healthTimeoutSeconds
    ):
      fail("game " & launch.name & " did not become healthy")
    for i in 0 ..< count:
      let
        token =
          if i < launch.tokens.len:
            launch.tokens[i]
          else:
            ""
        botName = botContainerName(launch, player, i + 1)
      args.requireDocker(dockerRunBotArgs(
        launch,
        player,
        i,
        token,
        botName
      ))
      launched.add(botName)
    echo "Started ", launch.name, " replay=", launch.replay
  except CatchableError:
    if not args.dryRun:
      args.removeContainers(launched)
    raise

proc selectedLaunches(args: ToolArgs): seq[LaunchSpec] =
  ## Returns launch specs selected by the command line.
  for spec in Launches:
    if args.onlyGame.len == 0 or spec.game == args.onlyGame:
      result.add(spec)
  if result.len == 0:
    fail("no configured game matched: " & args.onlyGame)

proc run() =
  ## Runs the start-all-games tool.
  let
    args = parseArgs()
    games = listGames(args)
    players = listPlayers(args)
  if not args.dryRun:
    createDir(args.replayDir)
  for spec in selectedLaunches(args):
    if spec.count < 0 or spec.count > MaxBotsPerGame:
      fail("invalid bot count for " & spec.game)
    let
      game = findGame(games, spec.game)
      player = findPlayer(players, spec.game, spec.bot)
    launchGame(args, game, player, spec.count)

try:
  run()
except StartAllGamesError as e:
  stderr.writeLine("start_all_games failed: " & e.msg)
  quit(1)
except CatchableError as e:
  stderr.writeLine("start_all_games failed: " & e.msg)
  quit(1)

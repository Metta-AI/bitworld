import
  std/[algorithm, exitprocs, json, monotimes, net, os, osproc, parseopt,
    strutils, times]

const
  CoworldManifestName = "coworld_manifest.json"
  CoplayerManifestName = "coplayer_manifest.json"
  SpriteProtocolSpec = "sprite_v1.md"
  ServerReadyTimeoutMs = 5000
  PollIntervalMs = 100
  DefaultBindAddress = "0.0.0.0"
  DefaultConnectAddress = "localhost"
  DefaultPort = 8080
  MaxPlayers = 32
  MaxBots = 256
  IgnoredManifestDirs = [
    ".git",
    ".github",
    "__pycache__",
    "nimcache",
    "node_modules",
    "out",
    "replays",
    "tmp"
  ]

var
  serverProcess: Process
  botProcesses: seq[Process]
  cleanupStarted = false

type
  ClientProtocol = enum
    FrameClient
    SpriteClient

  BotGroup = object
    source: string
    count: int

  GameManifest = object
    key: string
    path: string
    name: string
    playerProtocol: ClientProtocol
    hasGlobalProtocol: bool

  GameLaunch = object
    sourceRelative: string
    workDir: string
    label: string
    name: string
    playerProtocol: ClientProtocol
    hasGlobalProtocol: bool

  CoplayerManifest = object
    key: string
    path: string
    name: string
    games: seq[string]

  QuickRunConfig = object
    gameFolder: string
    address: string
    port: int
    players: int
    playersSet: bool
    connect: bool
    reconnectSeconds: string
    saveReplayPath: string
    configJson: string
    configPath: string
    serverArgs: seq[string]
    botGroups: seq[BotGroup]
    botGui: bool
    botNamePrefix: string
    botMapPath: string

  BotLaunch = object
    sourceRelative: string
    workDir: string
    label: string
    count: int

proc repoRoot(): string =
  absolutePath(getCurrentDir())

proc usage(): string =
  "Usage: quick_run <game_folder> [--connect] [--address:ADDR] " &
    "[--port:N] [--players:N] [--bots:BOT:N] [--bot-gui] " &
    "[--bot-name-prefix:NAME] [--bot-map:PATH] [--reconnect:N]\n" &
    "Human clients open in the browser from the game's /client routes.\n" &
    "Unknown options are passed to the game server when quick_run starts it.\n" &
    "Examples:\n" &
    "  quick_run fancy_cookout\n" &
    "  quick_run among_them --players:2 --bots:nottoodumb:6\n" &
    "  quick_run among_them --connect --port:2000 --bots:nottoodumb:8"

proc parsePort(value: string): int =
  result = parseInt(value)
  if result < 1 or result > 65535:
    raise newException(ValueError, "Port must be between 1 and 65535.")

proc parsePlayers(value: string): int =
  result = parseInt(value)
  if result < 0 or result > MaxPlayers:
    raise newException(
      ValueError,
      "--players must be between 0 and " & $MaxPlayers & "."
    )

proc parseBotCount(value: string): int =
  result = parseInt(value)
  if result < 0 or result > MaxBots:
    raise newException(
      ValueError,
      "Bot count must be between 0 and " & $MaxBots & "."
    )

proc parseReconnect(value: string): string =
  let seconds = parseFloat(value)
  if not (seconds >= 0):
    raise newException(ValueError, "--reconnect must be 0 or greater.")
  value

proc trimTrailingSeparators(value: string): string =
  result = value.strip()
  while result.len > 0 and result[^1] in {'/', '\\'}:
    result.setLen(result.len - 1)

proc cleanRelativePath(value: string): string =
  ## Normalizes one repository-relative path for manifest matching.
  result = trimTrailingSeparators(value).replace("\\", "/")
  while result.startsWith("./"):
    result = result[2 .. ^1]

proc relativeManifestKey(rootDir, path: string): string =
  ## Returns a stable repository-relative manifest key.
  if path.isAbsolute():
    result = path.relativePath(rootDir)
  else:
    result = path
  result = result.cleanRelativePath()

proc normalizeManifestName(value: string): string =
  ## Normalizes names so CLI keys can use dashes or underscores.
  for c in value.strip():
    if c.isAlphaNumeric():
      result.add(c.toLowerAscii())
    elif c in {'_', '-', ' ', '/', '\\'}:
      result.add('_')

proc shouldScanManifestDir(path: string): bool =
  ## Returns true when a directory can contain launcher manifests.
  let name = path.extractFilename()
  name.len == 0 or (
    name notin IgnoredManifestDirs and
    not name.startsWith(".")
  )

proc addManifestPath(rootDir, path: string, paths: var seq[string]) =
  ## Adds one manifest path by repository-relative identity.
  if not fileExists(path):
    return
  let key = relativeManifestKey(rootDir, path)
  for existing in paths:
    if relativeManifestKey(rootDir, existing) == key:
      return
  paths.add(path)

proc scanManifestPaths(
  rootDir,
  dir,
  fileName: string,
  paths: var seq[string]
) =
  ## Recursively scans for manifest files under useful directories.
  addManifestPath(rootDir, dir / fileName, paths)
  for kind, path in walkDir(dir):
    case kind
    of pcDir:
      if path.shouldScanManifestDir():
        scanManifestPaths(rootDir, path, fileName, paths)
    else:
      discard

proc manifestPaths(rootDir, fileName: string): seq[string] =
  ## Returns sorted manifest paths under the repository root.
  scanManifestPaths(rootDir, rootDir, fileName, result)
  result.sort(proc(a, b: string): int =
    cmp(relativeManifestKey(rootDir, a), relativeManifestKey(rootDir, b))
  )

proc loadManifestObject(path: string): JsonNode =
  ## Loads a manifest JSON object from disk.
  try:
    result = parseJson(readFile(path))
  except CatchableError as e:
    raise newException(
      ValueError,
      "Could not read manifest " & path & ": " & e.msg
    )
  if result.kind != JObject:
    raise newException(ValueError, "Manifest must be a JSON object: " & path)

proc manifestString(
  node: JsonNode,
  key,
  defaultValue: string
): string =
  ## Reads one string field from a manifest object.
  if node.kind == JObject and node.hasKey(key) and
    node[key].kind == JString:
      return node[key].getStr()
  defaultValue

proc manifestStringArray(node: JsonNode, key: string): seq[string] =
  ## Reads one string array field from a manifest object.
  if node.kind != JObject or not node.hasKey(key) or
    node[key].kind != JArray:
      return
  for item in node[key].items:
    if item.kind == JString:
      result.add(item.getStr())

proc manifestProtocol(node: JsonNode, key: string): string =
  ## Reads one protocol spec path from a Coworld manifest.
  if node.kind != JObject or not node.hasKey("protocols"):
    return
  let protocols = node["protocols"]
  if protocols.kind == JObject and protocols.hasKey(key) and
    protocols[key].kind == JString:
      return protocols[key].getStr()

proc isSpriteProtocolSpec(path: string): bool =
  ## Returns true when a protocol path names the sprite protocol spec.
  let cleanPath = path.toLowerAscii()
  cleanPath.extractFilename() == SpriteProtocolSpec or
    cleanPath.contains("sprite_v1")

proc clientProtocolFromManifest(node: JsonNode): ClientProtocol =
  ## Returns the human client protocol advertised by a Coworld manifest.
  if node.manifestProtocol("player").isSpriteProtocolSpec():
    SpriteClient
  else:
    FrameClient

proc gameNode(node: JsonNode): JsonNode =
  ## Returns the embedded Coworld game object.
  if node.kind == JObject and node.hasKey("game") and
      node["game"].kind == JObject:
    return node["game"]
  node

proc readGameManifest(rootDir, path: string): GameManifest =
  ## Reads one Coworld manifest summary from disk.
  let
    node = loadManifestObject(path)
    game = node.gameNode()
    name = game.manifestString("name", path.parentDir().extractFilename())
  result = GameManifest(
    key: relativeManifestKey(rootDir, path),
    path: path,
    name: name,
    playerProtocol: clientProtocolFromManifest(game),
    hasGlobalProtocol: game.manifestProtocol("global").len > 0
  )

proc listGameManifests(rootDir: string): seq[GameManifest] =
  ## Scans repository folders for Coworld manifests.
  for path in manifestPaths(rootDir, CoworldManifestName):
    result.add(readGameManifest(rootDir, path))

proc findGameManifest(
  rootDir,
  folderName: string
): tuple[found: bool, manifest: GameManifest] =
  ## Finds a Coworld manifest matching a CLI game key.
  let
    cleanKey = folderName.cleanRelativePath()
    cleanName = cleanKey.normalizeManifestName()
  for manifest in listGameManifests(rootDir):
    let manifestDir = manifest.key.parentDir().cleanRelativePath()
    if manifest.key == cleanKey or
      manifestDir == cleanKey or
      manifest.name.normalizeManifestName() == cleanName:
        return (found: true, manifest: manifest)

proc gameSourceRelative(folderName: string): string =
  let normalized = trimTrailingSeparators(folderName)
  if normalized.len == 0:
    raise newException(ValueError, "Game folder name cannot be empty.")

  let parts = normalized.split({'/', '\\'})
  if parts.len == 0 or parts[^1].len == 0:
    raise newException(ValueError, "Game folder name cannot be empty.")

  normalized / (parts[^1] & ".nim")

proc ensureGameFolder(rootDir, folderName: string): GameLaunch =
  ## Validates and describes one game source folder.
  let normalized = trimTrailingSeparators(folderName)
  if normalized.len == 0:
    raise newException(ValueError, "Game folder name cannot be empty.")

  let manifestLookup = findGameManifest(rootDir, normalized)
  let gameFolder =
    if manifestLookup.found and not dirExists(rootDir / normalized):
      manifestLookup.manifest.key.parentDir()
    else:
      normalized
  let
    workDir = absolutePath(rootDir / gameFolder)
    sourceRelative = gameSourceRelative(gameFolder)
    sourcePath = absolutePath(rootDir / sourceRelative)
  if not dirExists(workDir):
    raise newException(ValueError, "Game folder not found: " & gameFolder)
  if not fileExists(sourcePath):
    raise newException(
      ValueError,
      "Game entry file not found: " & sourceRelative
    )
  result = GameLaunch(
    sourceRelative: sourceRelative,
    workDir: workDir,
    label: splitPath(gameFolder).tail,
    name: splitPath(gameFolder).tail,
    playerProtocol: FrameClient,
    hasGlobalProtocol: false
  )
  if manifestLookup.found:
    result.name = manifestLookup.manifest.name
    result.playerProtocol = manifestLookup.manifest.playerProtocol
    result.hasGlobalProtocol = manifestLookup.manifest.hasGlobalProtocol

proc hasPathSeparator(value: string): bool =
  ## Returns true when a value looks like a path.
  value.contains('/') or value.contains('\\')

proc withNimExt(path: string): string =
  ## Adds the Nim source extension when no extension is present.
  result = path
  if result.splitFile().ext.len == 0:
    result.add(".nim")

proc parseBotGroup(value: string): BotGroup =
  ## Parses BOT or BOT:N into one bot launch group.
  let spec = value.strip()
  if spec.len == 0:
    raise newException(ValueError, "--bots requires a bot name or path.")
  let split = spec.rfind(':')
  if split >= 0 and split + 1 < spec.len:
    let countText = spec[split + 1 .. ^1]
    if countText.allCharsInSet({'0' .. '9'}):
      result.source = spec[0 ..< split]
      result.count = parseBotCount(countText)
      if result.source.len == 0:
        raise newException(ValueError, "--bots source cannot be empty.")
      return
  result.source = spec
  result.count = 1

proc botCandidates(gameFolder, source: string): seq[string] =
  ## Returns repository-relative candidate source paths for one bot.
  let sourcePath = trimTrailingSeparators(source)
  if sourcePath.hasPathSeparator():
    result.add(sourcePath.withNimExt())
    let split = sourcePath.withNimExt().splitFile()
    result.add(split.dir / split.name / (split.name & split.ext))
  else:
    result.add(gameFolder / "players" / sourcePath / (sourcePath & ".nim"))
    result.add(gameFolder / "players" / (sourcePath & ".nim"))

proc readCoplayerManifest(rootDir, path: string): CoplayerManifest =
  ## Reads one CoPlayer manifest summary from disk.
  let
    node = loadManifestObject(path)
    name = node.manifestString("name", path.parentDir().extractFilename())
  result = CoplayerManifest(
    key: relativeManifestKey(rootDir, path),
    path: path,
    name: name,
    games: node.manifestStringArray("games")
  )

proc supportsGame(bot: CoplayerManifest, gameName: string): bool =
  ## Returns true when a CoPlayer manifest supports one game.
  let normalizedGame = gameName.normalizeManifestName()
  for supported in bot.games:
    if supported == gameName or
      supported.normalizeManifestName() == normalizedGame:
        return true

proc listCoplayerManifests(
  rootDir,
  gameName: string
): seq[CoplayerManifest] =
  ## Scans repository folders for CoPlayer manifests.
  for path in manifestPaths(rootDir, CoplayerManifestName):
    let bot = readCoplayerManifest(rootDir, path)
    if bot.supportsGame(gameName):
      result.add(bot)

proc botSourceFromManifest(
  rootDir: string,
  bot: CoplayerManifest
): tuple[sourceRelative, workDir, label: string] =
  ## Finds the local Nim source that belongs to one CoPlayer manifest.
  let
    manifestDir = bot.path.parentDir()
    playersDir = manifestDir.parentDir()
    folderName = manifestDir.extractFilename()
  var sourceNames: seq[string]
  if bot.name.len > 0:
    sourceNames.add(bot.name)
  if folderName.len > 0 and folderName notin sourceNames:
    sourceNames.add(folderName)

  for sourceName in sourceNames:
    for sourcePath in [
      manifestDir / (sourceName & ".nim"),
      playersDir / (sourceName & ".nim")
    ]:
      if fileExists(sourcePath):
        let sourceRelative = relativeManifestKey(rootDir, sourcePath)
        return (
          sourceRelative: sourceRelative,
          workDir: sourcePath.parentDir(),
          label: sourcePath.splitFile().name
        )

proc findCoplayerSource(
  rootDir,
  gameName,
  source: string
): tuple[found: bool, sourceRelative, workDir, label: string] =
  ## Finds a local bot source by scanning CoPlayer manifests.
  let cleanKey = source.cleanRelativePath()
  if cleanKey.hasPathSeparator():
    return
  let normalizedKey = cleanKey.normalizeManifestName()
  for bot in listCoplayerManifests(rootDir, gameName):
    let
      botDir = bot.key.parentDir()
      botFolder = botDir.extractFilename()
    if bot.name == cleanKey or
      bot.key == cleanKey or
      botDir == cleanKey or
      bot.name.normalizeManifestName() == normalizedKey or
      botFolder.normalizeManifestName() == normalizedKey:
        let sourceInfo = botSourceFromManifest(rootDir, bot)
        if sourceInfo.sourceRelative.len == 0:
          raise newException(
            ValueError,
            "CoPlayer manifest has no local Nim source: " & bot.key
          )
        return (
          found: true,
          sourceRelative: sourceInfo.sourceRelative,
          workDir: sourceInfo.workDir,
          label: sourceInfo.label
        )

proc ensureBotFile(
  rootDir,
  gameFolder,
  gameName,
  source: string
): tuple[sourceRelative, workDir, label: string] =
  ## Validates and describes one bot source file.
  let manifestBot = findCoplayerSource(rootDir, gameName, source)
  if manifestBot.found:
    return (
      sourceRelative: manifestBot.sourceRelative,
      workDir: manifestBot.workDir,
      label: manifestBot.label
    )

  for sourceRelative in botCandidates(gameFolder, source):
    let sourcePath = absolutePath(rootDir / sourceRelative)
    if fileExists(sourcePath):
      return (
        sourceRelative: sourceRelative,
        workDir: sourcePath.parentDir(),
        label: sourcePath.splitFile().name
      )
  raise newException(ValueError, "Bot file not found: " & source)

proc exePathFor(rootDir, sourceRelative: string): string =
  ## Mirrors `--outdir:./out` from config.nims.
  let exeName = sourceRelative.splitFile().name.addFileExt(ExeExts[0])
  absolutePath(rootDir / "out" / exeName)

proc clientConnectAddress(address: string): string =
  ## Returns a local address suitable for launched clients.
  if address == "0.0.0.0" or address == "::":
    return "127.0.0.1"
  address

proc encodeUrlComponent(value: string): string =
  ## Encodes a string for use as one URL query value.
  for c in value:
    case c
    of 'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_', '.', '~':
      result.add(c)
    else:
      result.add('%')
      result.add(ord(c).toHex(2))

proc browserHost(address: string): string =
  ## Returns a host string suitable for browser URLs.
  result = clientConnectAddress(address)
  if result.contains(':') and not result.startsWith("["):
    result = "[" & result & "]"

proc browserUrl(
  address: string,
  port: int,
  path: string,
  params: openArray[(string, string)]
): string =
  ## Builds a local browser URL for one game client route.
  result = "http://" & browserHost(address) & ":" & $port & path
  var first = true
  for param in params:
    let
      key = param[0]
      value = param[1]
    if value.len == 0:
      continue
    if first:
      result.add('?')
      first = false
    else:
      result.add('&')
    result.add(key.encodeUrlComponent())
    result.add('=')
    result.add(value.encodeUrlComponent())

proc stopManagedProcess(processRef: var Process, label: string) =
  if processRef.isNil:
    return

  try:
    if processRef.peekExitCode() == -1:
      echo "Stopping ", label, "..."
      processRef.terminate()
      for _ in 0 ..< 20:
        if processRef.peekExitCode() != -1:
          break
        sleep(PollIntervalMs)
      if processRef.peekExitCode() == -1:
        processRef.kill()
  except CatchableError:
    discard

  try:
    processRef.close()
  except CatchableError:
    discard
  processRef = nil

proc cleanupChildren() =
  if cleanupStarted:
    return
  cleanupStarted = true
  for i in countdown(botProcesses.high, 0):
    stopManagedProcess(botProcesses[i], "bot " & $(i + 1))
  botProcesses.setLen(0)
  stopManagedProcess(serverProcess, "server")

proc cleanupAtExit() {.noconv.} =
  cleanupChildren()

proc controlCHook() {.noconv.} =
  echo ""
  echo "Ctrl+C received, shutting down child processes..."
  cleanupChildren()
  quit(130)

proc runProcessAndWait(
  executable: string,
  workingDir: string,
  args: openArray[string]
): int =
  var process: Process
  try:
    process = startProcess(
      executable,
      workingDir = workingDir,
      args = args,
      options = {poParentStreams}
    )
    result = process.waitForExit()
  finally:
    if not process.isNil:
      try:
        process.close()
      except CatchableError:
        discard

proc openBrowser(url: string): bool =
  ## Opens one URL in the user's default browser.
  when defined(macosx):
    let opener = findExe("open")
    if opener.len == 0:
      return false
    result = runProcessAndWait(opener, getCurrentDir(), [url]) == 0
  elif defined(windows):
    let opener = getEnv("ComSpec", "cmd")
    result = runProcessAndWait(
      opener,
      getCurrentDir(),
      ["/c", "start", "", url]
    ) == 0
  else:
    let opener = findExe("xdg-open")
    if opener.len == 0:
      return false
    result = runProcessAndWait(opener, getCurrentDir(), [url]) == 0

proc openHtmlClient(label, url: string) =
  ## Opens one HTML client and prints a fallback URL.
  echo "Opening ", label, ": ", url
  if not openBrowser(url):
    echo "Open this URL in your browser: ", url

proc compileTarget(
  nimExe: string,
  rootDir: string,
  label: string,
  sourceRelative: string
): int =
  echo "Compiling ", label, "..."
  result = runProcessAndWait(nimExe, rootDir, ["c", sourceRelative])
  if result != 0:
    echo label, " compile failed with exit code ", result, "."

proc launchManagedProcess(
  label: string,
  executable: string,
  workingDir: string,
  args: openArray[string]
): Process =
  echo "Starting ", label, "..."
  result = startProcess(
    executable,
    workingDir = workingDir,
    args = args,
    options = {poParentStreams}
  )

proc childExitCode(processRef: Process): int =
  if processRef.isNil:
    return 1
  try:
    result = processRef.peekExitCode()
  except CatchableError:
    result = 1

proc waitForServerReady(address: string, port: int, managedServer: bool): bool =
  ## Waits until the target server accepts TCP connections.
  let
    startedAt = getMonoTime()
    timeout = initDuration(milliseconds = ServerReadyTimeoutMs)
    connectAddress = clientConnectAddress(address)

  while getMonoTime() - startedAt < timeout:
    if managedServer and
      not serverProcess.isNil and
      serverProcess.peekExitCode() != -1:
        echo "Server exited before it became ready."
        return false

    var socket: Socket
    try:
      socket = newSocket()
      socket.connect(connectAddress, Port(port))
      socket.close()
      return true
    except CatchableError:
      if not socket.isNil:
        try:
          socket.close()
        except CatchableError:
          discard
      sleep(PollIntervalMs)

  echo "Timed out waiting for ", connectAddress, ":", port, "."
  false

proc waitForChildren(managedServer: bool): int =
  ## Waits until a managed child exits, then stops the rest.
  if not managedServer and botProcesses.len == 0:
    echo "No server or bot processes are managed by this run."
    return 0

  while true:
    var
      serverExitCode = -1
      serverRunning = true
    if managedServer:
      serverExitCode = childExitCode(serverProcess)
      serverRunning = serverExitCode == -1

    var exitedBotIndex = -1
    var botExitCode = -1
    for i, processRef in botProcesses:
      let exitCode = childExitCode(processRef)
      if exitCode != -1:
        exitedBotIndex = i
        botExitCode = exitCode
        break

    if (managedServer and not serverRunning) or exitedBotIndex != -1:
      if managedServer and not serverRunning:
        echo "Server exited with code ", serverExitCode, "."
      if exitedBotIndex != -1:
        echo "Bot ", exitedBotIndex + 1,
          " exited with code ", botExitCode, "."
      cleanupChildren()
      if exitedBotIndex != -1:
        return botExitCode
      return serverExitCode

    sleep(PollIntervalMs)

proc longOptionArg(key, val: string): string =
  ## Rebuilds one long option for forwarding to the game server.
  if val.len > 0:
    "--" & key & ":" & val
  else:
    "--" & key

proc shortOptionArg(key, val: string): string =
  ## Rebuilds one short option for forwarding to the game server.
  if val.len > 0:
    "-" & key & ":" & val
  else:
    "-" & key

proc parseArgs(): QuickRunConfig =
  var positional: seq[string]
  var
    portSet = false
  result.port = DefaultPort

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      positional.add(key)
    of cmdLongOption:
      case key
      of "players":
        if val.len == 0:
          raise newException(ValueError, "--players requires a value.")
        result.players = parsePlayers(val)
        result.playersSet = true
      of "bots", "bot":
        if val.len == 0:
          raise newException(ValueError, "--bots requires a value.")
        result.botGroups.add(parseBotGroup(val))
      of "connect":
        result.connect = true
      of "html":
        discard
      of "bot-gui":
        result.botGui = true
      of "bot-name-prefix", "name-prefix":
        if val.len == 0:
          raise newException(ValueError, "--bot-name-prefix requires a value.")
        result.botNamePrefix = val
      of "bot-map":
        if val.len == 0:
          raise newException(ValueError, "--bot-map requires a value.")
        result.botMapPath = val
      of "address":
        if val.len == 0:
          raise newException(ValueError, "--address requires a value.")
        result.address = val
      of "port":
        if val.len == 0:
          raise newException(ValueError, "--port requires a value.")
        result.port = parsePort(val)
        portSet = true
      of "save-replay":
        if val.len == 0:
          raise newException(ValueError, "--save-replay requires a value.")
        result.saveReplayPath = val
      of "config":
        if val.len == 0:
          raise newException(ValueError, "--config requires a value.")
        result.configJson = val
      of "config-file":
        if val.len == 0:
          raise newException(ValueError, "--config-file requires a value.")
        result.configPath = val
      of "reconnect":
        if val.len == 0:
          raise newException(ValueError, "--reconnect requires a value.")
        result.reconnectSeconds = parseReconnect(val)
      else:
        result.serverArgs.add(longOptionArg(key, val))
    of cmdShortOption:
      result.serverArgs.add(shortOptionArg(key, val))
    of cmdEnd:
      discard

  if positional.len == 2:
    if portSet:
      raise newException(ValueError, "Port was provided twice.")
    result.port = parsePort(positional[1])
    positional.setLen(1)
  if positional.len != 1:
    raise newException(ValueError, "Expected <game_folder>.")
  if result.address.len == 0:
    result.address =
      if result.connect:
        DefaultConnectAddress
      else:
        DefaultBindAddress
  if not result.playersSet:
    result.players =
      if result.botGroups.len > 0:
        0
      else:
        1

  result.gameFolder = positional[0]

proc botMapArg(rootDir, path: string): string =
  ## Returns a normalized bot map argument or an empty string.
  if path.len == 0:
    return ""
  if path.isAbsolute():
    "--map:" & path
  else:
    "--map:" & absolutePath(rootDir / path)

proc htmlParams(config: QuickRunConfig): seq[(string, string)] =
  ## Returns query parameters for browser clients.
  if config.reconnectSeconds.len > 0:
    result.add(("reconnect", config.reconnectSeconds))

proc openHtmlClients(config: QuickRunConfig, game: GameLaunch) =
  ## Opens browser clients for one quick-run game.
  if game.playerProtocol == SpriteClient and game.hasGlobalProtocol:
    openHtmlClient(
      game.name & " global",
      browserUrl(
        config.address,
        config.port,
        "/client/global",
        htmlParams(config)
      )
    )

  if config.players <= 0:
    return

  for i in 1 .. config.players:
    var params = htmlParams(config)
    params.add(("name", "player" & $i))
    params.add(("joystick", $i))
    openHtmlClient(
      game.name & " player " & $i,
      browserUrl(config.address, config.port, "/client/player", params)
    )

proc runQuickRun(config: QuickRunConfig): int =
  let
    rootDir = repoRoot()
    nimExe = findExe("nim")
  if nimExe.len == 0:
    echo "Unable to find 'nim' on PATH."
    return 1

  let
    game = ensureGameFolder(rootDir, config.gameFolder)
    gameFolderRelative = game.sourceRelative.splitFile().dir
    gameExe = exePathFor(rootDir, game.sourceRelative)
    portArg = "--port:" & $config.port
    addressArg = "--address:" & config.address

  var botLaunches: seq[BotLaunch]
  for group in config.botGroups:
    if group.count == 0:
      continue
    let bot = ensureBotFile(
      rootDir,
      gameFolderRelative,
      game.name,
      group.source
    )
    botLaunches.add(BotLaunch(
      sourceRelative: bot.sourceRelative,
      workDir: bot.workDir,
      label: bot.label,
      count: group.count
    ))

  var serverArgs = @[portArg, addressArg]
  if config.saveReplayPath.len > 0:
    serverArgs.add("--save-replay:" & config.saveReplayPath)
  if config.configJson.len > 0:
    serverArgs.add("--config:" & config.configJson)
  if config.configPath.len > 0:
    serverArgs.add("--config-file:" & config.configPath)
  for arg in config.serverArgs:
    serverArgs.add(arg)

  echo "Using ", clientConnectAddress(config.address), ":", config.port, "."

  if not config.connect:
    result = compileTarget(
      nimExe,
      rootDir,
      game.label & " server",
      game.sourceRelative
    )
    if result != 0:
      return result

  var compiledBots: seq[string]
  for bot in botLaunches:
    if bot.sourceRelative in compiledBots:
      continue
    result = compileTarget(
      nimExe,
      rootDir,
      bot.label & " bot",
      bot.sourceRelative
    )
    if result != 0:
      return result
    compiledBots.add(bot.sourceRelative)

  if config.connect:
    echo "Connecting to existing server."
  else:
    try:
      serverProcess = launchManagedProcess(
        game.label & " server",
        gameExe,
        game.workDir,
        serverArgs
      )
    except CatchableError as e:
      echo "Failed to start server: ", e.msg
      cleanupChildren()
      return 1

  if not waitForServerReady(config.address, config.port, not config.connect):
    cleanupChildren()
    return 1

  openHtmlClients(config, game)

  let mapArg = botMapArg(rootDir, config.botMapPath)
  var globalBotIndex = 0
  for bot in botLaunches:
    let
      botExe = exePathFor(rootDir, bot.sourceRelative)
      prefix =
        if config.botNamePrefix.len > 0:
          config.botNamePrefix
        else:
          bot.label
    for i in 0 ..< bot.count:
      inc globalBotIndex
      let nameIndex =
        if config.botNamePrefix.len > 0:
          globalBotIndex
        else:
          i + 1
      var botArgs = @[
        "--address:" & clientConnectAddress(config.address),
        "--port:" & $config.port,
        "--name:" & prefix & $nameIndex
      ]
      if config.botGui:
        botArgs.add("--gui")
      if mapArg.len > 0:
        botArgs.add(mapArg)
      try:
        botProcesses.add(
          launchManagedProcess(
            bot.label & " bot " & $(i + 1),
            botExe,
            bot.workDir,
            botArgs
          )
        )
      except CatchableError as e:
        echo "Failed to start bot ", globalBotIndex, ": ", e.msg
        cleanupChildren()
        return 1

  result = waitForChildren(not config.connect)
  cleanupChildren()

when isMainModule:
  addExitProc(cleanupAtExit)
  setControlCHook(controlCHook)

  try:
    quit(runQuickRun(parseArgs()))
  except ValueError as e:
    echo e.msg
    echo usage()
    quit(1)

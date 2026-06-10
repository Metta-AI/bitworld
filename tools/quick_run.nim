import
  std/[json, monotimes, net, os, osproc, parseopt, strutils, sysrand, times]

when isMainModule:
  import std/exitprocs

const
  GlobalClientSourceRelative = "client" / "global_client.nim"
  PlayerClientSourceRelative = "client" / "player_client.nim"
  CoworldManifestName = "coworld_manifest.json"
  SpriteProtocolSpec = "sprite_v1.md"
  ServerReadyTimeoutMs = 5000
  PollIntervalMs = 100
  DefaultBindAddress = "0.0.0.0"
  DefaultConnectAddress = "localhost"
  DefaultPort = 8080
  HighestPort = 65535
  MaxPlayers = 32
  MaxBots = 256
  SlotTokenBytes = 16
  HexChars = "0123456789abcdef"

var
  serverProcess: Process
  clientProcesses: seq[Process]
  botProcesses: seq[Process]
  cleanupStarted = false

type
  ClientProtocol = enum
    FrameClient
    SpriteClient

  BotGroup = object
    source: string
    count: int
    role: string

  GameManifest = object
    key: string
    path: string
    name: string
    playerProtocol: ClientProtocol
    hasGlobalProtocol: bool
    slotNamesInPlayers: bool
    hasSlotRoles: bool

  GameLaunch = object
    sourceRelative: string
    buildDir: string
    workDir: string
    botSearchDir: string
    label: string
    name: string
    playerProtocol: ClientProtocol
    hasGlobalProtocol: bool
    slotNamesInPlayers: bool
    hasSlotRoles: bool

  ClientLaunch = object
    sourceRelative: string
    buildDir: string
    workDir: string

  QuickRunConfig = object
    gameFolder: string
    address: string
    port: int
    portSet: bool
    players: int
    playersSet: bool
    connect: bool
    globalViewer: bool
    htmlViewer: bool
    reconnectSeconds: string
    saveReplayPath: string
    configJson: string
    configPath: string
    seed: int
    seedSet: bool
    serverArgs: seq[string]
    botGroups: seq[BotGroup]
    botGui: bool
    botNamePrefix: string
    botMapPath: string
    slots: bool

  BotLaunch = object
    sourceRelative: string
    buildDir: string
    workDir: string
    label: string
    count: int
    role: string

  SlotAssignment = object
    name: string
    token: string
    role: string

proc currentRoot(): string =
  ## Returns the directory quick_run was invoked from.
  absolutePath(getCurrentDir())

proc toolRoot(): string =
  ## Returns the BitWorld repository directory containing quick_run.
  absolutePath(currentSourcePath().parentDir().parentDir())

proc usage(): string =
  "Usage: quick_run <game_folder_or_file> [--connect] [--address:ADDR] " &
    "[--port:N] [--player] [--players:N] [--bots:BOT:N[:ROLE]] " &
    "[--global] " &
    "[--html] [--slots] " &
    "[--bot-gui] [--seed:N] " &
    "[--bot-name-prefix:NAME] [--bot-map:PATH] [--reconnect:N]\n" &
    "Human clients open as native Nim windows by default.\n" &
    "--global opens a global viewer and defaults humans to zero.\n" &
    "--html opens human and global clients in the browser instead.\n" &
    "--slots creates slot tokens and passes them to launched players.\n" &
    "Unknown options are passed to the game server when quick_run starts " &
    "it.\n" &
    "Examples:\n" &
    "  quick_run ./fancy_cookout\n" &
    "  quick_run ../cogame-planet-wars --bots:skurge:4 --global --html\n" &
    "  quick_run /Users/me/p/cogame-planet-wars/src/planet_wars.nim\n" &
    "  quick_run ./among_them --players:2 --bots:nottoodumb:6\n" &
    "  quick_run ./crewrift --bots:notsus:6:crew " &
    "--bots:truecrew:2:imposter --global\n" &
    "  quick_run ./among_them --connect --port:2000 --bots:nottoodumb:8"

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

proc parseSeed*(value: string): int =
  ## Parses one optional game seed.
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(ValueError, "--seed must be an integer.")
  if result < -1:
    raise newException(ValueError, "--seed must be -1 or greater.")

proc parseBotRole(value: string): string =
  ## Parses one optional bot role.
  case value.strip().toLowerAscii()
  of "":
    ""
  of "crew":
    "crew"
  of "imp", "imposter", "impostor":
    "imposter"
  else:
    raise newException(ValueError, "--bots role must be crew or imposter.")

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

proc manifestProtocol(node: JsonNode, key: string): string =
  ## Reads one protocol spec path from a Coworld manifest.
  if node.kind != JObject or not node.hasKey("protocols"):
    return
  let protocols = node["protocols"]
  if protocols.kind != JObject or not protocols.hasKey(key):
    return
  let protocol = protocols[key]
  if protocol.kind == JString:
    return protocol.getStr()
  if protocol.kind == JObject and protocol.hasKey("value") and
      protocol["value"].kind == JString:
    return protocol["value"].getStr()

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

proc configProperties(node: JsonNode): JsonNode =
  ## Returns a Coworld config schema properties object.
  if node.kind != JObject or not node.hasKey("config_schema"):
    return
  let schema = node["config_schema"]
  if schema.kind != JObject or not schema.hasKey("properties"):
    return
  let properties = schema["properties"]
  if properties.kind == JObject:
    return properties

proc slotItemProperties(node: JsonNode): JsonNode =
  ## Returns Coworld slots item properties.
  let properties = node.configProperties()
  if properties.kind != JObject or not properties.hasKey("slots"):
    return
  let slots = properties["slots"]
  if slots.kind != JObject or not slots.hasKey("items"):
    return
  let items = slots["items"]
  if items.kind != JObject or not items.hasKey("properties"):
    return
  let slotProperties = items["properties"]
  if slotProperties.kind == JObject:
    return slotProperties

proc manifestHasConfigProperty(node: JsonNode, name: string): bool =
  ## Returns true when one config schema property is advertised.
  let properties = node.configProperties()
  properties.kind == JObject and properties.hasKey(name)

proc manifestHasSlotProperty(node: JsonNode, name: string): bool =
  ## Returns true when one slots item schema property is advertised.
  let properties = node.slotItemProperties()
  properties.kind == JObject and properties.hasKey(name)

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
    hasGlobalProtocol: game.manifestProtocol("global").len > 0,
    slotNamesInPlayers: game.manifestHasConfigProperty("players"),
    hasSlotRoles: game.manifestHasSlotProperty("role")
  )

proc hasPathSeparator(value: string): bool =
  ## Returns true when a value looks like a path.
  value.contains('/') or value.contains('\\')

proc withNimExt(path: string): string =
  ## Adds the Nim source extension when no extension is present.
  result = path
  if result.splitFile().ext.len == 0:
    result.add(".nim")

proc sourceArg(buildDir, sourcePath: string): string =
  ## Returns a Nim source argument relative to the build directory.
  if sourcePath.startsWith(buildDir / ""):
    sourcePath.relativePath(buildDir)
  else:
    sourcePath

proc sourceCandidate(rootDir, source: string): string =
  ## Returns the absolute path for one possible game source.
  let sourcePath = source.withNimExt()
  if sourcePath.isAbsolute():
    sourcePath
  else:
    absolutePath(rootDir / sourcePath)

proc pathFromArg(rootDir, value: string): string =
  ## Returns one absolute filesystem path from a CLI path argument.
  if value.isAbsolute():
    value
  else:
    absolutePath(rootDir / value)

proc projectRootForSource(sourcePath: string): string =
  ## Finds the closest build root for one external source path.
  result = sourcePath.parentDir()
  var dir = result
  while true:
    if fileExists(dir / "config.nims"):
      return dir
    for kind, path in walkDir(dir):
      if kind == pcFile and path.splitFile().ext == ".nimble":
        return dir
    let parent = dir.parentDir()
    if parent == dir or parent.len == 0:
      break
    dir = parent

proc manifestPathForRoot(rootDir: string): string =
  ## Returns the Coworld manifest path beside one explicit game root.
  rootDir / CoworldManifestName

proc botSearchDirFor(buildDir, workDir: string): string =
  ## Returns the bot lookup directory relative to the build root.
  if workDir.startsWith(buildDir / ""):
    workDir.relativePath(buildDir)
  else:
    "."

proc workDirForSource(buildDir, sourcePath: string): string =
  ## Returns the runtime working directory for one explicit source file.
  if fileExists(buildDir.manifestPathForRoot()) or dirExists(buildDir / "data"):
    buildDir
  else:
    sourcePath.parentDir()

proc nimbleSourceNames(dir: string): seq[string] =
  ## Returns source names declared by top-level Nimble package files.
  for kind, path in walkDir(dir):
    if kind == pcFile and path.splitFile().ext == ".nimble":
      result.add(path.splitFile().name)

proc sourceCandidatesForDir(dir: string): seq[string] =
  ## Returns entry source candidates inside one explicit game directory.
  let tail = dir.extractFilename()
  if tail.len > 0:
    result.add(dir / (tail & ".nim"))
    result.add(dir / "src" / (tail & ".nim"))
  for name in nimbleSourceNames(dir):
    result.add(dir / "src" / (name & ".nim"))
    result.add(dir / (name & ".nim"))
  let srcDir = dir / "src"
  if dirExists(srcDir):
    for kind, path in walkDir(srcDir):
      if kind == pcFile and path.splitFile().ext == ".nim":
        result.add(path)

proc firstExistingSource(dir: string): string =
  ## Returns the first existing entry source inside one game directory.
  for path in sourceCandidatesForDir(dir):
    if fileExists(path):
      return path

proc ensureGameSource(rootDir, source: string): GameLaunch =
  ## Validates and describes one game source file.
  let sourcePath = sourceCandidate(rootDir, source)
  if not fileExists(sourcePath):
    raise newException(ValueError, "Game entry file not found: " & source)

  let
    buildDir = projectRootForSource(sourcePath)
    workDir = workDirForSource(buildDir, sourcePath)
    sourceRelative = sourceArg(buildDir, sourcePath)
    manifestPath = buildDir.manifestPathForRoot()
    label = sourcePath.splitFile().name

  result = GameLaunch(
    sourceRelative: sourceRelative,
    buildDir: buildDir,
    workDir: workDir,
    botSearchDir: botSearchDirFor(buildDir, workDir),
    label: label,
    name: label,
    playerProtocol: FrameClient,
    hasGlobalProtocol: false,
    slotNamesInPlayers: false,
    hasSlotRoles: false
  )
  if fileExists(manifestPath):
    let manifest = readGameManifest(buildDir, manifestPath)
    result.name = manifest.name
    result.playerProtocol = manifest.playerProtocol
    result.hasGlobalProtocol = manifest.hasGlobalProtocol
    result.slotNamesInPlayers = manifest.slotNamesInPlayers
    result.hasSlotRoles = manifest.hasSlotRoles

proc ensureGameFolder(rootDir, folderName: string): GameLaunch =
  ## Validates and describes one game source folder.
  let normalized = trimTrailingSeparators(folderName)
  if normalized.len == 0:
    raise newException(ValueError, "Game folder name cannot be empty.")

  let
    workDir = pathFromArg(rootDir, normalized)
    sourcePath = firstExistingSource(workDir)
  if not dirExists(workDir):
    raise newException(ValueError, "Game folder not found: " & normalized)
  if sourcePath.len == 0:
    raise newException(
      ValueError,
      "Game entry file not found in: " & normalized
    )
  let
    buildDir = projectRootForSource(sourcePath)
    sourceRelative = sourceArg(buildDir, sourcePath)
    manifestPath = buildDir.manifestPathForRoot()
    label = sourcePath.splitFile().name
  result = GameLaunch(
    sourceRelative: sourceRelative,
    buildDir: buildDir,
    workDir: workDir,
    botSearchDir: botSearchDirFor(buildDir, workDir),
    label: label,
    name: label,
    playerProtocol: FrameClient,
    hasGlobalProtocol: false,
    slotNamesInPlayers: false,
    hasSlotRoles: false
  )
  if fileExists(manifestPath):
    let manifest = readGameManifest(buildDir, manifestPath)
    result.name = manifest.name
    result.playerProtocol = manifest.playerProtocol
    result.hasGlobalProtocol = manifest.hasGlobalProtocol
    result.slotNamesInPlayers = manifest.slotNamesInPlayers
    result.hasSlotRoles = manifest.hasSlotRoles

proc findGame(
  currentDir,
  source: string
): tuple[found: bool, game: GameLaunch] =
  ## Finds a game by explicit source path or folder path.
  let candidate = sourceCandidate(currentDir, source)
  if fileExists(candidate):
    return (found: true, game: ensureGameSource(currentDir, source))

  if dirExists(pathFromArg(currentDir, source)):
    return (found: true, game: ensureGameFolder(currentDir, source))

proc parseBotGroup(value: string): BotGroup =
  ## Parses BOT, BOT:N, or BOT:N:ROLE into one bot launch group.
  let spec = value.strip()
  if spec.len == 0:
    raise newException(ValueError, "--bots requires a bot name or path.")
  let
    lastSplit = spec.rfind(':')
    lastPart =
      if lastSplit >= 0 and lastSplit + 1 < spec.len:
        spec[lastSplit + 1 .. ^1]
      else:
        ""
    hasRole = lastPart.len > 0 and
      not lastPart.allCharsInSet({'0' .. '9'})
    possibleRole =
      if hasRole:
        lastPart.parseBotRole()
      else:
        ""
    countSpec =
      if hasRole:
        spec[0 ..< lastSplit]
      else:
        spec
    split = countSpec.rfind(':')
  if split >= 0 and split + 1 < countSpec.len:
    let countText = countSpec[split + 1 .. ^1]
    if countText.allCharsInSet({'0' .. '9'}):
      result.source = countSpec[0 ..< split]
      result.count = parseBotCount(countText)
      result.role = possibleRole
      if result.source.len == 0:
        raise newException(ValueError, "--bots source cannot be empty.")
      return
  if possibleRole.len > 0:
    raise newException(ValueError, "--bots role requires a bot count.")
  result.source = countSpec
  result.count = 1

proc botCandidates(rootDir, gameFolder, source: string): seq[string] =
  ## Returns candidate source paths for one bot.
  let sourcePath = trimTrailingSeparators(source)
  if sourcePath.hasPathSeparator():
    result.add(sourcePath.withNimExt())
    let split = sourcePath.withNimExt().splitFile()
    result.add(split.dir / split.name / (split.name & split.ext))
  else:
    result.add(gameFolder / "players" / sourcePath / (sourcePath & ".nim"))
    result.add(gameFolder / "players" / (sourcePath & ".nim"))
    result.add(
      rootDir.parentDir() / sourcePath / "src" / (sourcePath & ".nim")
    )
    result.add(rootDir.parentDir() / sourcePath / (sourcePath & ".nim"))

proc absoluteSourcePath(rootDir, source: string): string =
  ## Returns an absolute source path for a repository or external path.
  if source.isAbsolute():
    source
  else:
    absolutePath(rootDir / source)

proc ensureBotFile(
  rootDir,
  gameFolder,
  source: string
): tuple[sourceRelative, buildDir, workDir, label: string] =
  ## Validates and describes one bot source file.
  for sourceRelative in botCandidates(rootDir, gameFolder, source):
    let sourcePath = absoluteSourcePath(rootDir, sourceRelative)
    if fileExists(sourcePath):
      let
        external = not sourcePath.startsWith(rootDir / "")
        buildDir =
          if source.hasPathSeparator() or
              external:
            projectRootForSource(sourcePath)
          else:
            rootDir
        workDir =
          if external:
            rootDir
          else:
            sourcePath.parentDir()
        buildSource = sourceArg(buildDir, sourcePath)
      return (
        sourceRelative: buildSource,
        buildDir: buildDir,
        workDir: workDir,
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

proc urlWithParams(
  base: string,
  params: openArray[(string, string)]
): string =
  ## Builds a URL with encoded query parameters.
  result = base
  var first = '?' notin result
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

proc browserUrl(
  address: string,
  port: int,
  path: string,
  params: openArray[(string, string)]
): string =
  ## Builds a local browser URL for one game client route.
  urlWithParams("http://" & browserHost(address) & ":" & $port & path, params)

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
  for i in countdown(clientProcesses.high, 0):
    stopManagedProcess(clientProcesses[i], "client " & $(i + 1))
  clientProcesses.setLen(0)
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
  sourceRelative,
  outputPath: string
): int =
  echo "Compiling ", label, "..."
  createDir(outputPath.parentDir())
  var args = @["c", "--out:" & outputPath]
  let sourceDir = rootDir / "src"
  if dirExists(sourceDir):
    args.add("--path:" & sourceDir)
  args.add(sourceRelative)
  result = runProcessAndWait(
    nimExe,
    rootDir,
    args
  )
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

proc tcpPortInUse(address: string, port: int): bool =
  ## Returns true when a local TCP listener accepts a connection.
  let connectAddress = clientConnectAddress(address)
  var socket: Socket
  try:
    socket = newSocket()
    socket.connect(connectAddress, Port(port))
    result = true
  except CatchableError:
    result = false
  if not socket.isNil:
    try:
      socket.close()
    except CatchableError:
      discard

proc firstOpenPort(address: string, startPort: int): int =
  ## Finds the first port without a local TCP listener.
  result = startPort
  while result <= HighestPort:
    if not tcpPortInUse(address, result):
      return result
    inc result
  raise newException(
    ValueError,
    "No available TCP port found at or above " & $startPort & "."
  )

proc waitForChildren(managedServer: bool): int =
  ## Waits until a managed child exits, then stops the rest.
  if not managedServer and clientProcesses.len == 0 and botProcesses.len == 0:
    echo "No server, client, or bot processes are managed by this run."
    return 0

  while true:
    var
      serverExitCode = -1
      serverRunning = true
    if managedServer:
      serverExitCode = childExitCode(serverProcess)
      serverRunning = serverExitCode == -1

    var
      exitedClientIndex = -1
      clientExitCode = -1
      exitedBotIndex = -1
      botExitCode = -1
    for i, processRef in clientProcesses:
      let exitCode = childExitCode(processRef)
      if exitCode != -1:
        exitedClientIndex = i
        clientExitCode = exitCode
        break
    for i, processRef in botProcesses:
      let exitCode = childExitCode(processRef)
      if exitCode != -1:
        exitedBotIndex = i
        botExitCode = exitCode
        break

    if (managedServer and not serverRunning) or
        exitedClientIndex != -1 or
        exitedBotIndex != -1:
      if managedServer and not serverRunning:
        echo "Server exited with code ", serverExitCode, "."
      if exitedClientIndex != -1:
        echo "Client ", exitedClientIndex + 1,
          " exited with code ", clientExitCode, "."
      if exitedBotIndex != -1:
        echo "Bot ", exitedBotIndex + 1,
          " exited with code ", botExitCode, "."
      cleanupChildren()
      if exitedClientIndex != -1:
        return clientExitCode
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
  result.port = DefaultPort

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      positional.add(key)
    of cmdLongOption:
      case key
      of "player":
        result.players =
          if val.len == 0:
            1
          else:
            parsePlayers(val)
        result.playersSet = true
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
      of "global":
        result.globalViewer = true
      of "html":
        result.htmlViewer = true
      of "slots":
        if val.len > 0:
          raise newException(ValueError, "--slots does not take a value.")
        result.slots = true
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
        result.portSet = true
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
      of "seed":
        if val.len == 0:
          raise newException(ValueError, "--seed requires a value.")
        result.seed = parseSeed(val)
        result.seedSet = true
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
    if result.portSet:
      raise newException(ValueError, "Port was provided twice.")
    result.port = parsePort(positional[1])
    result.portSet = true
    positional.setLen(1)
  if positional.len != 1:
    raise newException(ValueError, "Expected <game_folder_or_file>.")
  if result.address.len == 0:
    result.address =
      if result.connect:
        DefaultConnectAddress
      else:
        DefaultBindAddress
  if result.globalViewer and not result.playersSet:
    result.players = 0
  elif not result.playersSet:
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

proc botSlotName(
  config: QuickRunConfig,
  bot: BotLaunch,
  localIndex,
  globalIndex: int
): string =
  ## Returns the configured quick-run name for one bot.
  let prefix =
    if config.botNamePrefix.len > 0:
      config.botNamePrefix
    else:
      bot.label
  let nameIndex =
    if config.botNamePrefix.len > 0:
      globalIndex
    else:
      localIndex + 1
  prefix & $nameIndex

proc randomHexToken(): string =
  ## Returns a secure random hex token for a quick-run slot.
  var bytes = newSeq[byte](SlotTokenBytes)
  if not sysrand.urandom(bytes):
    raise newException(ValueError, "Could not generate random slot token.")
  for value in bytes:
    let n = int(value)
    result.add(HexChars[n shr 4])
    result.add(HexChars[n and 0x0f])

proc initSlotAssignment(name, role: string): SlotAssignment =
  ## Creates one quick-run slot assignment with a random token.
  SlotAssignment(
    name: name,
    token: randomHexToken(),
    role: role
  )

proc botGroupsHaveRoles(groups: openArray[BotGroup]): bool =
  ## Returns true when at least one bot group pins a role.
  for group in groups:
    if group.role.len > 0:
      return true

proc buildSlotAssignments(
  config: QuickRunConfig,
  botLaunches: openArray[BotLaunch]
): seq[SlotAssignment] =
  ## Creates slot names and tokens for launched quick-run players.
  for i in 0 ..< config.players:
    result.add(initSlotAssignment("player" & $(i + 1), ""))
  var globalBotIndex = 0
  for bot in botLaunches:
    for i in 0 ..< bot.count:
      inc globalBotIndex
      result.add(initSlotAssignment(
        config.botSlotName(bot, i, globalBotIndex),
        bot.role
      ))

proc slotAssignmentAt(
  assignments: openArray[SlotAssignment],
  index: int
): SlotAssignment =
  ## Returns one slot assignment or an empty assignment.
  if index >= 0 and index < assignments.len:
    return assignments[index]
  SlotAssignment()

proc slotsConfigJson(
  assignments: openArray[SlotAssignment],
  namesInPlayers: bool
): string =
  ## Builds the server config JSON for quick-run slots.
  var
    root = newJObject()
    players = newJArray()
    tokens = newJArray()
    slots = newJArray()
  for assignment in assignments:
    var slot = newJObject()
    if namesInPlayers:
      players.add(%*{"name": assignment.name})
    else:
      slot["name"] = %assignment.name
    if assignment.role.len > 0:
      slot["role"] = %assignment.role
    tokens.add(%assignment.token)
    slots.add(slot)
  root["tokens"] = tokens
  if namesInPlayers:
    root["players"] = players
  root["slots"] = slots
  $root

proc configObject(text, source: string): JsonNode =
  ## Parses one quick-run config object.
  try:
    result = parseJson(text)
  except JsonParsingError as e:
    raise newException(
      ValueError,
      "Could not parse " & source & ": " & e.msg
    )
  if result.kind != JObject:
    raise newException(ValueError, source & " must be a JSON object.")

proc mergeConfigObject(target: JsonNode, source: JsonNode) =
  ## Merges top-level config fields from source into target.
  for key, value in source:
    target[key] = value

proc mergedConfigJson*(
  slotsJson,
  configJson,
  configPath: string,
  seedSet: bool,
  seed: int
): string =
  ## Builds one inline config object from quick-run config sources.
  var
    root = newJObject()
    hasConfig = false
  if slotsJson.len > 0:
    root.mergeConfigObject(slotsJson.configObject("slot config"))
    hasConfig = true
  if configPath.len > 0:
    root.mergeConfigObject(readFile(configPath).configObject(configPath))
    hasConfig = true
  if configJson.len > 0:
    root.mergeConfigObject(configJson.configObject("--config"))
    hasConfig = true
  if seedSet:
    root["seed"] = %seed
    hasConfig = true
  if hasConfig:
    result = $root

proc htmlParams(config: QuickRunConfig): seq[(string, string)] =
  ## Returns query parameters for browser clients.
  if config.reconnectSeconds.len > 0:
    result.add(("reconnect", config.reconnectSeconds))

proc globalWsAddress(config: QuickRunConfig): string =
  ## Returns the websocket address for the global viewer.
  "ws://" & browserHost(config.address) & ":" & $config.port & "/global"

proc playerWsAddress(
  config: QuickRunConfig,
  slotIndex = -1,
  assignment = SlotAssignment()
): string =
  ## Returns the websocket address for a player client.
  var params: seq[(string, string)] = @[]
  if assignment.name.len > 0:
    params.add(("name", assignment.name))
  if slotIndex >= 0:
    params.add(("slot", $slotIndex))
  if assignment.token.len > 0:
    params.add(("token", assignment.token))
  urlWithParams(
    "ws://" & browserHost(config.address) & ":" & $config.port & "/player",
    params
  )

proc playerClientSource(game: GameLaunch): string =
  ## Returns the native player client source for one game.
  case game.playerProtocol
  of SpriteClient:
    GlobalClientSourceRelative
  of FrameClient:
    PlayerClientSourceRelative

proc localClientSource(game: GameLaunch, sourceRelative: string): string =
  ## Returns a game-local native client source when one exists.
  let direct = game.buildDir / sourceRelative
  if fileExists(direct):
    return direct

  let packaged = game.buildDir / "src" / game.name / sourceRelative
  if fileExists(packaged):
    return packaged

  let
    sourceName = sourceRelative.extractFilename()
    srcDir = game.buildDir / "src"
  if dirExists(srcDir):
    for path in walkDirRec(srcDir):
      if path.extractFilename() == sourceName and
          path.parentDir().extractFilename() == "client":
        return path

proc clientWorkDir(buildDir, sourcePath: string): string =
  ## Returns the working directory with native client data assets.
  let clientDir = buildDir / "client"
  if dirExists(clientDir / "data"):
    clientDir
  else:
    sourcePath.parentDir()

proc clientLaunch(
  game: GameLaunch,
  launcherDir,
  sourceRelative: string
): ClientLaunch =
  ## Resolves the source, build root, and working directory for a client.
  let localSource = game.localClientSource(sourceRelative)
  if localSource.len > 0:
    return ClientLaunch(
      sourceRelative: sourceArg(game.buildDir, localSource),
      buildDir: game.buildDir,
      workDir: clientWorkDir(game.buildDir, localSource)
    )

  let launcherSource = launcherDir / sourceRelative
  ClientLaunch(
    sourceRelative: sourceRelative,
    buildDir: launcherDir,
    workDir: clientWorkDir(launcherDir, launcherSource)
  )

proc globalPalettePath(rootDir: string, game: GameLaunch): string =
  ## Returns the palette path for the native global viewer.
  let gamePalettePath = game.workDir / "data" / "pallete.png"
  if fileExists(gamePalettePath):
    return gamePalettePath
  rootDir / "client" / "data" / "pallete.png"

proc openHtmlGlobalViewer(config: QuickRunConfig, game: GameLaunch) =
  ## Opens the browser global viewer for one quick-run game.
  openHtmlClient(
    game.name & " global",
    browserUrl(
      config.address,
      config.port,
      "/client/global",
      htmlParams(config)
    )
  )

proc openHtmlClients(
  config: QuickRunConfig,
  game: GameLaunch,
  assignments: openArray[SlotAssignment]
) =
  ## Opens browser clients for one quick-run game.
  if config.players <= 0:
    return

  for i in 1 .. config.players:
    var params = htmlParams(config)
    let assignment = assignments.slotAssignmentAt(i - 1)
    if assignment.name.len > 0:
      params.add(("name", assignment.name))
      params.add(("slot", $(i - 1)))
      params.add(("token", assignment.token))
    else:
      params.add(("name", "player" & $i))
    params.add(("joystick", $i))
    openHtmlClient(
      game.name & " player " & $i,
      browserUrl(config.address, config.port, "/client/player", params)
    )

proc launchNativePlayerClients(
  config: QuickRunConfig,
  game: GameLaunch,
  launcherDir: string,
  assignments: openArray[SlotAssignment]
): bool =
  ## Starts native player client processes for one quick-run game.
  if config.players <= 0:
    return true

  let
    client = clientLaunch(game, launcherDir, game.playerClientSource())
    playerExe = exePathFor(client.buildDir, client.sourceRelative)
  for i in 1 .. config.players:
    let assignment = assignments.slotAssignmentAt(i - 1)
    let slotIndex =
      if assignment.name.len > 0:
        i - 1
      else:
        -1
    var args = @[
      "--address:" & playerWsAddress(config, slotIndex, assignment),
      "--title:" & game.name & " player " & $i,
      "--joystick:" & $i
    ]
    if game.playerProtocol == SpriteClient:
      args.add("--player")
      args.add("--palette:" & globalPalettePath(launcherDir, game))
    if config.reconnectSeconds.len > 0:
      args.add("--reconnect:" & config.reconnectSeconds)
    try:
      clientProcesses.add(
        launchManagedProcess(
          game.name & " player " & $i & " client",
          playerExe,
          client.workDir,
          args
        )
      )
    except CatchableError as e:
      echo "Failed to start player ", i, ": ", e.msg
      return false
  true

proc launchNativeGlobalViewer(
  config: QuickRunConfig,
  game: GameLaunch,
  launcherDir: string
): bool =
  ## Starts the native global viewer process.
  let
    client = clientLaunch(game, launcherDir, GlobalClientSourceRelative)
    globalExe = exePathFor(client.buildDir, client.sourceRelative)
  var args = @[
    "--address:" & globalWsAddress(config),
    "--title:" & game.name & " global",
    "--palette:" & globalPalettePath(launcherDir, game)
  ]
  if config.reconnectSeconds.len > 0:
    args.add("--reconnect:" & config.reconnectSeconds)
  try:
    clientProcesses.add(
      launchManagedProcess(
        game.name & " global client",
        globalExe,
        client.workDir,
        args
      )
    )
    result = true
  except CatchableError as e:
    echo "Failed to start global viewer: ", e.msg

proc runQuickRun(input: QuickRunConfig): int =
  var config = input
  let
    runDir = currentRoot()
    launcherDir = toolRoot()
    nimExe = findExe("nim")
  if nimExe.len == 0:
    echo "Unable to find 'nim' on PATH."
    return 1

  let gameLookup = findGame(runDir, config.gameFolder)
  if not gameLookup.found:
    echo "Game folder or file not found from current directory: ",
      config.gameFolder
    echo usage()
    return 1

  if not config.connect and not config.portSet:
    let openPort = firstOpenPort(config.address, config.port)
    if openPort != config.port:
      echo "Port ", config.port, " is busy; using ", openPort, " instead."
      config.port = openPort

  let
    game = gameLookup.game
    gameExe = exePathFor(game.buildDir, game.sourceRelative)
    portArg = "--port:" & $config.port
    hostArg = "--host:" & config.address
  if config.globalViewer and not game.hasGlobalProtocol:
    echo "Game does not advertise a global protocol: ", game.name
    return 1

  var botLaunches: seq[BotLaunch]
  for group in config.botGroups:
    if group.count == 0:
      continue
    let bot = ensureBotFile(
      game.buildDir,
      game.botSearchDir,
      group.source
    )
    botLaunches.add(BotLaunch(
      sourceRelative: bot.sourceRelative,
      buildDir: bot.buildDir,
      workDir: bot.workDir,
      label: bot.label,
      count: group.count,
      role: group.role
    ))

  let rolesRequested = config.botGroups.botGroupsHaveRoles()
  if rolesRequested and not game.hasSlotRoles:
    echo "Game does not advertise slot roles: ", game.name
    return 1

  var slotAssignments: seq[SlotAssignment]
  if config.slots or rolesRequested:
    slotAssignments = config.buildSlotAssignments(botLaunches)

  var
    serverArgs = @[portArg, hostArg]
    slotConfigJson = ""
  if (config.slots or rolesRequested) and slotAssignments.len > 0:
    slotConfigJson = slotsConfigJson(
      slotAssignments,
      game.slotNamesInPlayers
    )
  if config.saveReplayPath.len > 0:
    serverArgs.add("--save-replay:" & config.saveReplayPath)
  let shouldMergeConfig =
    slotConfigJson.len > 0 or config.seedSet or (
      config.configJson.len > 0 and config.configPath.len > 0
    )
  if shouldMergeConfig:
    let inlineConfig = mergedConfigJson(
      slotConfigJson,
      config.configJson,
      config.configPath,
      config.seedSet,
      config.seed
    )
    if inlineConfig.len > 0:
      serverArgs.add("--config:" & inlineConfig)
  else:
    if config.configJson.len > 0:
      serverArgs.add("--config:" & config.configJson)
    if config.configPath.len > 0:
      serverArgs.add("--config-path:" & config.configPath)
  for arg in config.serverArgs:
    serverArgs.add(arg)

  echo "Using ", clientConnectAddress(config.address), ":", config.port, "."

  if not config.connect:
    result = compileTarget(
      nimExe,
      game.buildDir,
      game.label & " server",
      game.sourceRelative,
      gameExe
    )
    if result != 0:
      return result

  var compiledClientSources: seq[string]
  if config.globalViewer and not config.htmlViewer:
    let client = clientLaunch(game, launcherDir, GlobalClientSourceRelative)
    result = compileTarget(
      nimExe,
      client.buildDir,
      game.name & " global client",
      client.sourceRelative,
      exePathFor(client.buildDir, client.sourceRelative)
    )
    if result != 0:
      return result
    compiledClientSources.add(client.buildDir & "\0" & client.sourceRelative)

  if config.players > 0 and not config.htmlViewer:
    let client = clientLaunch(game, launcherDir, game.playerClientSource())
    let clientKey = client.buildDir & "\0" & client.sourceRelative
    if clientKey notin compiledClientSources:
      result = compileTarget(
        nimExe,
        client.buildDir,
        game.name & " player client",
        client.sourceRelative,
        exePathFor(client.buildDir, client.sourceRelative)
      )
      if result != 0:
        return result
      compiledClientSources.add(clientKey)

  var compiledBots: seq[string]
  for bot in botLaunches:
    let
      botKey = bot.buildDir & "\0" & bot.sourceRelative
      botExe = exePathFor(bot.buildDir, bot.sourceRelative)
    if botKey in compiledBots:
      continue
    result = compileTarget(
      nimExe,
      bot.buildDir,
      bot.label & " bot",
      bot.sourceRelative,
      botExe
    )
    if result != 0:
      return result
    compiledBots.add(botKey)

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

  if config.globalViewer:
    if config.htmlViewer:
      openHtmlGlobalViewer(config, game)
    elif not launchNativeGlobalViewer(config, game, launcherDir):
      cleanupChildren()
      return 1

  if config.htmlViewer:
    openHtmlClients(config, game, slotAssignments)
  elif not launchNativePlayerClients(config, game, launcherDir, slotAssignments):
    cleanupChildren()
    return 1

  let mapArg = botMapArg(runDir, config.botMapPath)
  var globalBotIndex = 0
  for bot in botLaunches:
    let botExe = exePathFor(bot.buildDir, bot.sourceRelative)
    for i in 0 ..< bot.count:
      inc globalBotIndex
      let
        name = config.botSlotName(bot, i, globalBotIndex)
        assignmentIndex = config.players + globalBotIndex - 1
        assignment = slotAssignments.slotAssignmentAt(assignmentIndex)
      var botArgs = @[
        "--address:" & clientConnectAddress(config.address),
        "--port:" & $config.port,
        "--name:" & name
      ]
      if assignment.name.len > 0:
        botArgs.add("--slot:" & $assignmentIndex)
        botArgs.add("--token:" & assignment.token)
        botArgs.add(
          "--url:" & playerWsAddress(config, assignmentIndex, assignment)
        )
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

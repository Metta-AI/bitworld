import std/[exitprocs, monotimes, net, os, osproc, parseopt, strutils, times]
import windy

const
  PlayerClientSourceRelative = "clients" / "player_client.nim"
  GlobalClientSourceRelative = "clients" / "global_client.nim"
  ServerReadyTimeoutMs = 5000
  PollIntervalMs = 100
  ClientScreenOnlyWidth = 384
  ClientScreenOnlyHeight = 384
  ClientWindowMargin = 50
  DefaultBindAddress = "0.0.0.0"
  DefaultConnectAddress = "localhost"
  DefaultPort = 8080
  MaxPlayers = 32
  MaxBots = 256

var
  serverProcess: Process
  clientProcesses: seq[Process]
  cleanupStarted = false

type
  BotGroup = object
    source: string
    count: int

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

  ClientLaunch = object
    title: string
    x: int
    y: int

proc repoRoot(): string =
  absolutePath(getCurrentDir())

proc usage(): string =
  "Usage: quick_run <game_folder> [--connect] [--address:ADDR] " &
    "[--port:N] [--players:N] [--bots:BOT:N] [--bot-gui] " &
    "[--bot-name-prefix:NAME] [--bot-map:PATH] [--reconnect:N]\n" &
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

proc gameSourceRelative(folderName: string): string =
  let normalized = trimTrailingSeparators(folderName)
  if normalized.len == 0:
    raise newException(ValueError, "Game folder name cannot be empty.")

  let parts = normalized.split({'/', '\\'})
  if parts.len == 0 or parts[^1].len == 0:
    raise newException(ValueError, "Game folder name cannot be empty.")

  normalized / (parts[^1] & ".nim")

proc ensureGameFolder(rootDir, folderName: string): tuple[sourceRelative, workDir, label: string] =
  let normalized = trimTrailingSeparators(folderName)
  if normalized.len == 0:
    raise newException(ValueError, "Game folder name cannot be empty.")

  let
    workDir = absolutePath(rootDir / normalized)
    sourceRelative = gameSourceRelative(normalized)
    sourcePath = absolutePath(rootDir / sourceRelative)
  if not dirExists(workDir):
    raise newException(ValueError, "Game folder not found: " & normalized)
  if not fileExists(sourcePath):
    raise newException(
      ValueError,
      "Game entry file not found: " & sourceRelative
    )
  (sourceRelative: sourceRelative, workDir: workDir, label: splitPath(normalized).tail)

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

proc ensureBotFile(
  rootDir,
  gameFolder,
  source: string
): tuple[sourceRelative, workDir, label: string] =
  ## Validates and describes one bot source file.
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

proc humanizeLabel(label: string): string =
  for part in label.split({'_', '-', ' '}):
    if part.len == 0:
      continue
    if result.len > 0:
      result.add(' ')
    result.add(part[0].toUpperAscii())
    if part.len > 1:
      result.add(part[1 .. ^1].toLowerAscii())

proc primaryScreen(): Screen =
  when declared(getScreens):
    let screens = getScreens()
    if screens.len > 0:
      for screen in screens:
        if screen.primary:
          return screen
      return screens[0]
  Screen(left: 0, right: 1920, top: 0, bottom: 1080, primary: true)

proc usesSpritePlayerClient(label: string): bool =
  ## Returns true when a game uses the global sprite player protocol.
  label in [
    "big_adventure",
    "party_progressor",
    "infinite_blocks",
    "planet_wars"
  ]

proc clientConnectAddress(address: string): string =
  ## Returns a local address suitable for launched clients.
  if address == "0.0.0.0" or address == "::":
    return "127.0.0.1"
  address

proc websocketUrl(address: string, port: int, path: string): string =
  ## Builds a local websocket URL for one game endpoint.
  "ws://" & clientConnectAddress(address) & ":" & $port & path

proc clientLaunches(gameTitle: string, players: int): seq[ClientLaunch] =
  ## Returns human client window positions in a centered grid.
  if players <= 0:
    return
  let screen = primaryScreen()
  var columns = 1
  while columns * columns < players:
    inc columns
  let rows = (players + columns - 1) div columns

  let
    totalHeight =
      rows * ClientScreenOnlyHeight +
      max(0, rows - 1) * ClientWindowMargin
    startY = screen.top + (screen.bottom - screen.top - totalHeight) div 2

  for rowIndex in 0 ..< rows:
    let rowStart = rowIndex * columns
    let rowCount = min(columns, players - rowStart)
    let
      rowWidth =
        rowCount * ClientScreenOnlyWidth +
        max(0, rowCount - 1) * ClientWindowMargin
      startX = screen.left + (screen.right - screen.left - rowWidth) div 2
      y = startY + rowIndex * (ClientScreenOnlyHeight + ClientWindowMargin)

    for col in 0 ..< rowCount:
      let playerNumber = result.len + 1
      result.add(ClientLaunch(
        title: gameTitle & " Player " & $playerNumber,
        x: startX + col * (ClientScreenOnlyWidth + ClientWindowMargin),
        y: y
      ))

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
  if not managedServer and clientProcesses.len == 0:
    echo "No server or client processes are managed by this run."
    return 0

  while true:
    var
      serverExitCode = -1
      serverRunning = true
    if managedServer:
      serverExitCode = childExitCode(serverProcess)
      serverRunning = serverExitCode == -1

    var exitedClientIndex = -1
    var clientExitCode = -1
    for i, processRef in clientProcesses:
      let exitCode = childExitCode(processRef)
      if exitCode != -1:
        exitedClientIndex = i
        clientExitCode = exitCode
        break

    if (managedServer and not serverRunning) or exitedClientIndex != -1:
      if managedServer and not serverRunning:
        echo "Server exited with code ", serverExitCode, "."
      if exitedClientIndex != -1:
        echo "Client ", exitedClientIndex + 1,
          " exited with code ", clientExitCode, "."
      cleanupChildren()
      if exitedClientIndex != -1:
        return clientExitCode
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
    spritePlayerClient = usesSpritePlayerClient(game.label)
    playerPath =
      if spritePlayerClient:
        "/sprite_player"
      else:
        "/player"
    gameTitle = humanizeLabel(game.label)
    gameExe = exePathFor(rootDir, game.sourceRelative)
    clientSourceRelative =
      if spritePlayerClient:
        GlobalClientSourceRelative
      else:
        PlayerClientSourceRelative
    clientExe = exePathFor(rootDir, clientSourceRelative)
    clientWorkDir = absolutePath(rootDir / "clients")
    portArg = "--port:" & $config.port
    addressArg = "--address:" & config.address

  var botLaunches: seq[BotLaunch]
  for group in config.botGroups:
    if group.count == 0:
      continue
    let bot = ensureBotFile(rootDir, gameFolderRelative, group.source)
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

  if config.players > 0 or spritePlayerClient:
    result = compileTarget(nimExe, rootDir, "client", clientSourceRelative)
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

  if spritePlayerClient:
    try:
      var globalArgs = @[
        "--address:" & websocketUrl(config.address, config.port, "/global"),
        "--title:" & gameTitle & " Global"
      ]
      if config.reconnectSeconds.len > 0:
        globalArgs.add("--reconnect:" & config.reconnectSeconds)
      clientProcesses.add(
        launchManagedProcess(
          "global client",
          clientExe,
          clientWorkDir,
          globalArgs
        )
      )
    except CatchableError as e:
      echo "Failed to start global client: ", e.msg
      cleanupChildren()
      return 1

  if config.players == 1:
    try:
      var clientArgs =
        if spritePlayerClient:
          @[
            "--address:" & websocketUrl(
              config.address,
              config.port,
              playerPath & "?name=player1"
            ),
            "--player",
            "--title:" & gameTitle
          ]
        else:
          @[
            "--address:" & websocketUrl(
              config.address,
              config.port,
              playerPath & "?name=player1"
            ),
            "--title:" & gameTitle
          ]
      if config.reconnectSeconds.len > 0:
        clientArgs.add("--reconnect:" & config.reconnectSeconds)
      clientProcesses.add(
        launchManagedProcess(
          "client",
          clientExe,
          clientWorkDir,
          clientArgs
        )
      )
    except CatchableError as e:
      echo "Failed to start client: ", e.msg
      cleanupChildren()
      return 1
  elif config.players > 1:
    let launches = clientLaunches(gameTitle, config.players)
    for i, launch in launches:
      try:
        var clientArgs =
          if spritePlayerClient:
            @[
              "--address:" & websocketUrl(
                config.address,
                config.port,
                playerPath & "?name=player" & $(i + 1)
              ),
              "--player",
              "--title:" & launch.title,
              "--joystick:" & $(i + 1),
              "--x:" & $launch.x,
              "--y:" & $launch.y
            ]
          else:
            @[
              "--address:" & websocketUrl(
                config.address,
                config.port,
                playerPath & "?name=player" & $(i + 1)
              ),
              "--screen-only",
              "--title:" & launch.title,
              "--joystick:" & $(i + 1),
              "--x:" & $launch.x,
              "--y:" & $launch.y
            ]
        if config.reconnectSeconds.len > 0:
          clientArgs.add("--reconnect:" & config.reconnectSeconds)
        clientProcesses.add(
          launchManagedProcess(
            "client " & $(i + 1),
            clientExe,
            clientWorkDir,
            clientArgs
          )
        )
      except CatchableError as e:
        echo "Failed to start client ", i + 1, ": ", e.msg
        cleanupChildren()
        return 1

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
        clientProcesses.add(
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

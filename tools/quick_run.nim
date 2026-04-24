import std/[exitprocs, monotimes, net, os, osproc, parseopt, random, strutils, times]
import windy

const
  ClientSourceRelative = "client" / "client.nim"
  ServerReadyTimeoutMs = 5000
  PollIntervalMs = 100
  RandomPortMin = 5000
  RandomPortMax = 10000
  ClientScreenOnlyWidth = 384
  ClientScreenOnlyHeight = 384
  ClientWindowMargin = 50
  MaxPlayers = 6

var
  serverProcess: Process
  clientProcesses: seq[Process]
  cleanupStarted = false

type
  QuickRunConfig = object
    gameFolder: string
    address: string
    port: int
    players: int

  ClientLaunch = object
    title: string
    x: int
    y: int

proc repoRoot(): string =
  absolutePath(getCurrentDir())

proc usage(): string =
  "Usage: quick_run <game_folder> [port] [--players:N] [--address:ADDR]\nIf port is omitted, quick_run picks a random port between 5000 and 10000.\nWhen players is greater than 1, quick_run launches centered screen-only clients and binds joysticks 1..N.\nExample: quick_run fancy_cookout 8080 --players:4 --address:0.0.0.0"

proc parsePort(value: string): int =
  result = parseInt(value)
  if result < 1 or result > 65535:
    raise newException(ValueError, "Port must be between 1 and 65535.")

proc chooseRandomPort(): int =
  rand(RandomPortMin .. RandomPortMax)

proc parsePlayers(value: string): int =
  result = parseInt(value)
  if result < 1 or result > MaxPlayers:
    raise newException(
      ValueError,
      "--players must be between 1 and " & $MaxPlayers & "."
    )

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

proc exePathFor(rootDir, sourceRelative: string): string =
  absolutePath(rootDir / sourceRelative.changeFileExt(ExeExts[0]))

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
  let screens = getScreens()
  if screens.len == 0:
    return Screen(left: 0, right: 1920, top: 0, bottom: 1080, primary: true)
  for screen in screens:
    if screen.primary:
      return screen
  screens[0]

proc clientLaunches(gameTitle: string, players: int): seq[ClientLaunch] =
  let screen = primaryScreen()
  let rowCounts =
    case players
    of 1: @[1]
    of 2: @[2]
    of 3: @[3]
    of 4: @[2, 2]
    of 5: @[3, 2]
    of 6: @[3, 3]
    else:
      raise newException(
        ValueError,
        "Unsupported player count: " & $players
      )

  let
    totalHeight =
      rowCounts.len * ClientScreenOnlyHeight +
      max(0, rowCounts.len - 1) * ClientWindowMargin
    startY = screen.top + (screen.bottom - screen.top - totalHeight) div 2

  for rowIndex, rowCount in rowCounts:
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

proc waitForServerReady(port: int): bool =
  let
    startedAt = getMonoTime()
    timeout = initDuration(milliseconds = ServerReadyTimeoutMs)

  while getMonoTime() - startedAt < timeout:
    if not serverProcess.isNil and serverProcess.peekExitCode() != -1:
      echo "Server exited before it became ready."
      return false

    var socket: Socket
    try:
      socket = newSocket()
      socket.connect("127.0.0.1", Port(port))
      socket.close()
      return true
    except CatchableError:
      if not socket.isNil:
        try:
          socket.close()
        except CatchableError:
          discard
      sleep(PollIntervalMs)

  echo "Timed out waiting for the server to start listening on port ", port, "."
  false

proc waitForChildren(): int =
  # Keep quick_run alive only while both child processes are alive.
  # If either side exits, tear the other one down immediately and
  # return the first observed exit code.
  while true:
    let
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

    if not serverRunning or exitedClientIndex != -1:
      if not serverRunning:
        echo "Server exited with code ", serverExitCode, "."
      if exitedClientIndex != -1:
        echo "Client ", exitedClientIndex + 1, " exited with code ", clientExitCode, "."
      cleanupChildren()
      if exitedClientIndex != -1:
        return clientExitCode
      return serverExitCode

    sleep(PollIntervalMs)

proc parseArgs(): QuickRunConfig =
  var positional: seq[string]
  result.players = 1
  result.address = "localhost"

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
      of "address":
        if val.len == 0:
          raise newException(ValueError, "--address requires a value.")
        result.address = val
      else:
        raise newException(ValueError, "Unknown option: --" & key)
    of cmdShortOption:
      raise newException(ValueError, "Unknown option: -" & key)
    of cmdEnd:
      discard

  if positional.len < 1 or positional.len > 2:
    raise newException(ValueError, "Expected <game_folder> and optional [port].")

  result.gameFolder = positional[0]
  result.port =
    if positional.len >= 2:
      parsePort(positional[1])
    else:
      chooseRandomPort()

proc runQuickRun(config: QuickRunConfig): int =
  let
    rootDir = repoRoot()
    nimExe = findExe("nim")
  if nimExe.len == 0:
    echo "Unable to find 'nim' on PATH."
    return 1

  let
    game = ensureGameFolder(rootDir, config.gameFolder)
    gameTitle = humanizeLabel(game.label)
    gameExe = exePathFor(rootDir, game.sourceRelative)
    clientExe = exePathFor(rootDir, ClientSourceRelative)
    clientWorkDir = absolutePath(rootDir / "client")
    portArg = "--port:" & $config.port
    addressArg = "--address:" & config.address

  echo "Using ", config.address, ":", config.port, "."

  result = compileTarget(nimExe, rootDir, game.label & " server", game.sourceRelative)
  if result != 0:
    return result

  result = compileTarget(nimExe, rootDir, "client", ClientSourceRelative)
  if result != 0:
    return result

  try:
    serverProcess = launchManagedProcess(game.label & " server", gameExe, game.workDir, [portArg, addressArg])
  except CatchableError as e:
    echo "Failed to start server: ", e.msg
    cleanupChildren()
    return 1

  if not waitForServerReady(config.port):
    cleanupChildren()
    return 1

  if config.players <= 1:
    try:
      clientProcesses.add(
        launchManagedProcess(
          "client",
          clientExe,
          clientWorkDir,
          [portArg, "--title:" & gameTitle]
        )
      )
    except CatchableError as e:
      echo "Failed to start client: ", e.msg
      cleanupChildren()
      return 1
  else:
    let launches = clientLaunches(gameTitle, config.players)
    for i, launch in launches:
      try:
        clientProcesses.add(
          launchManagedProcess(
            "client " & $(i + 1),
            clientExe,
            clientWorkDir,
            [
              portArg,
              "--screen-only",
              "--title:" & launch.title,
              "--joystick:" & $(i + 1),
              "--x:" & $launch.x,
              "--y:" & $launch.y
            ]
          )
        )
      except CatchableError as e:
        echo "Failed to start client ", i + 1, ": ", e.msg
        cleanupChildren()
        return 1

  result = waitForChildren()
  cleanupChildren()

when isMainModule:
  addExitProc(cleanupAtExit)
  setControlCHook(controlCHook)
  randomize()

  try:
    quit(runQuickRun(parseArgs()))
  except ValueError as e:
    echo e.msg
    echo usage()
    quit(1)

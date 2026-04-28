import std/[exitprocs, os, osproc, parseopt, strutils]

const
  DefaultAddress = "localhost"
  DefaultPort = 2000
  MaxPlayers = 32
  PollIntervalMs = 100
  PlayerFolderRelative = "among_them" / "players"

type
  QuickPlayerConfig = object
    playerFile: string
    players: int
    address: string
    port: int
    gui: bool
    namePrefix: string
    mapPath: string

var
  playerProcesses: seq[Process]
  cleanupStarted = false

proc repoRoot(): string =
  ## Returns the repository root for this tool.
  absolutePath(getCurrentDir())

proc usage(): string =
  ## Returns command-line usage text.
  "Usage: quick_player <player_nim_file> --players:N " &
    "[--address:ADDR] [--port:N] [--gui] [--name-prefix:NAME] " &
    "[--map:PATH]\n" &
    "Example: quick_player nottoodumb --players:4 " &
    "--address:0.0.0.0 --port:2000\n" &
    "Example: quick_player among_them/players/nottoodumb.nim " &
    "--players:2 --gui"

proc parsePort(value: string): int =
  ## Parses and validates a TCP port.
  result = parseInt(value)
  if result < 1 or result > 65535:
    raise newException(ValueError, "Port must be between 1 and 65535.")

proc parsePlayers(value: string): int =
  ## Parses and validates the player count.
  result = parseInt(value)
  if result < 1 or result > MaxPlayers:
    raise newException(
      ValueError,
      "--players must be between 1 and " & $MaxPlayers & "."
    )

proc trimTrailingSeparators(value: string): string =
  ## Removes trailing path separators from a path.
  result = value.strip()
  while result.len > 0 and result[^1] in {'/', '\\'}:
    result.setLen(result.len - 1)

proc normalizePlayerFile(value: string): string =
  ## Returns a repository-relative player source path.
  let normalized = trimTrailingSeparators(value)
  if normalized.len == 0:
    raise newException(ValueError, "Player file cannot be empty.")
  if normalized.contains('/') or normalized.contains('\\'):
    result = normalized
  else:
    result = PlayerFolderRelative / normalized
  if result.splitFile().ext.len == 0:
    result.add(".nim")

proc ensurePlayerFile(
  rootDir,
  playerFile: string
): tuple[sourceRelative, workDir, label: string] =
  ## Validates and describes one player source file.
  let
    sourceRelative = normalizePlayerFile(playerFile)
    sourcePath = absolutePath(rootDir / sourceRelative)
    workDir = sourcePath.parentDir()
    label = sourcePath.splitFile().name
  if not fileExists(sourcePath):
    raise newException(ValueError, "Player file not found: " & sourceRelative)
  (sourceRelative: sourceRelative, workDir: workDir, label: label)

proc exePathFor(rootDir, sourceRelative: string): string =
  ## Returns the compiled executable path for one source file.
  absolutePath(rootDir / sourceRelative.changeFileExt(ExeExts[0]))

proc stopManagedProcess(processRef: var Process, label: string) =
  ## Stops and closes one managed process.
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
  ## Stops all managed player processes.
  if cleanupStarted:
    return
  cleanupStarted = true
  for i in countdown(playerProcesses.high, 0):
    stopManagedProcess(playerProcesses[i], "player " & $(i + 1))
  playerProcesses.setLen(0)

proc cleanupAtExit() {.noconv.} =
  ## Cleans up child processes at process exit.
  cleanupChildren()

proc controlCHook() {.noconv.} =
  ## Handles Ctrl+C by stopping child processes.
  echo ""
  echo "Ctrl+C received, shutting down player processes..."
  cleanupChildren()
  quit(130)

proc runProcessAndWait(
  executable: string,
  workingDir: string,
  args: openArray[string]
): int =
  ## Runs one process to completion and returns its exit code.
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

proc compilePlayer(
  nimExe,
  rootDir,
  label,
  sourceRelative: string
): int =
  ## Compiles one player source file.
  echo "Compiling ", label, "..."
  result = runProcessAndWait(nimExe, rootDir, ["c", sourceRelative])
  if result != 0:
    echo label, " compile failed with exit code ", result, "."

proc launchManagedProcess(
  label,
  executable,
  workingDir: string,
  args: openArray[string]
): Process =
  ## Starts one managed player process.
  echo "Starting ", label, "..."
  result = startProcess(
    executable,
    workingDir = workingDir,
    args = args,
    options = {poParentStreams}
  )

proc childExitCode(processRef: Process): int =
  ## Returns one child process exit code or -1 when running.
  if processRef.isNil:
    return 1
  try:
    result = processRef.peekExitCode()
  except CatchableError:
    result = 1

proc waitForPlayers(): int =
  ## Waits until any player exits, then stops the rest.
  while true:
    for i, processRef in playerProcesses:
      let exitCode = childExitCode(processRef)
      if exitCode != -1:
        echo "Player ", i + 1, " exited with code ", exitCode, "."
        cleanupChildren()
        return exitCode
    sleep(PollIntervalMs)

proc parseArgs(): QuickPlayerConfig =
  ## Parses command-line arguments.
  var positional: seq[string]
  var
    playersSet = false
    pendingPlayers = false
  result.address = DefaultAddress
  result.port = DefaultPort
  result.namePrefix = "player"
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if pendingPlayers:
        result.players = parsePlayers(key)
        playersSet = true
        pendingPlayers = false
      else:
        positional.add(key)
    of cmdLongOption:
      case key
      of "players":
        if val.len == 0:
          pendingPlayers = true
        else:
          result.players = parsePlayers(val)
          playersSet = true
      of "address":
        if val.len == 0:
          raise newException(ValueError, "--address requires a value.")
        result.address = val
      of "port":
        if val.len == 0:
          raise newException(ValueError, "--port requires a value.")
        result.port = parsePort(val)
      of "gui":
        result.gui = true
      of "name-prefix":
        if val.len == 0:
          raise newException(ValueError, "--name-prefix requires a value.")
        result.namePrefix = val
      of "map":
        if val.len == 0:
          raise newException(ValueError, "--map requires a value.")
        result.mapPath = val
      else:
        raise newException(ValueError, "Unknown option: --" & key)
    of cmdShortOption:
      raise newException(ValueError, "Unknown option: -" & key)
    of cmdEnd:
      discard
  if pendingPlayers:
    raise newException(
      ValueError,
      "--players requires a value."
    )
  if positional.len != 1:
    raise newException(ValueError, "Expected <player_nim_file>.")
  if not playersSet:
    raise newException(ValueError, "Expected --players:N.")
  result.playerFile = positional[0]

proc runQuickPlayer(config: QuickPlayerConfig): int =
  ## Compiles and launches multiple AI player processes.
  let
    rootDir = repoRoot()
    nimExe = findExe("nim")
  if nimExe.len == 0:
    echo "Unable to find 'nim' on PATH."
    return 1
  let
    player = ensurePlayerFile(rootDir, config.playerFile)
    playerExe = exePathFor(rootDir, player.sourceRelative)
    addressArg = "--address:" & config.address
    portArg = "--port:" & $config.port
    mapArg =
      if config.mapPath.len == 0:
        ""
      elif config.mapPath.isAbsolute():
        "--map:" & config.mapPath
      else:
        "--map:" & absolutePath(rootDir / config.mapPath)
  echo "Using ", config.address, ":", config.port, "."
  result = compilePlayer(
    nimExe,
    rootDir,
    player.label & " player",
    player.sourceRelative
  )
  if result != 0:
    return result
  for i in 0 ..< config.players:
    var args = @[
      addressArg,
      portArg,
      "--name:" & config.namePrefix & $(i + 1)
    ]
    if config.gui:
      args.add("--gui")
    if mapArg.len > 0:
      args.add(mapArg)
    try:
      playerProcesses.add(
        launchManagedProcess(
          player.label & " player " & $(i + 1),
          playerExe,
          player.workDir,
          args
        )
      )
    except CatchableError as e:
      echo "Failed to start player ", i + 1, ": ", e.msg
      cleanupChildren()
      return 1
  result = waitForPlayers()
  cleanupChildren()

when isMainModule:
  addExitProc(cleanupAtExit)
  setControlCHook(controlCHook)
  try:
    quit(runQuickPlayer(parseArgs()))
  except ValueError as e:
    echo e.msg
    echo usage()
    quit(1)

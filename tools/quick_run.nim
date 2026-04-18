import std/[exitprocs, monotimes, net, os, osproc, random, strutils, times]

const
  ClientSourceRelative = "client" / "client.nim"
  ServerReadyTimeoutMs = 5000
  PollIntervalMs = 100
  RandomPortMin = 5000
  RandomPortMax = 10000

var
  serverProcess: Process
  clientProcess: Process
  cleanupStarted = false

proc repoRoot(): string =
  absolutePath(getAppDir() / "..")

proc usage(): string =
  "Usage: quick_run <game_folder> [port]\nIf port is omitted, quick_run picks a random port between 5000 and 10000.\nExample: quick_run fancy_cookout 8080"

proc parsePort(value: string): int =
  result = parseInt(value)
  if result < 1 or result > 65535:
    raise newException(ValueError, "Port must be between 1 and 65535.")

proc chooseRandomPort(): int =
  rand(RandomPortMin .. RandomPortMax)

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
  stopManagedProcess(clientProcess, "client")
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
      clientExitCode = childExitCode(clientProcess)
      serverRunning = serverExitCode == -1
      clientRunning = clientExitCode == -1

    if not serverRunning or not clientRunning:
      if not serverRunning:
        echo "Server exited with code ", serverExitCode, "."
      if not clientRunning:
        echo "Client exited with code ", clientExitCode, "."
      cleanupChildren()
      if not clientRunning:
        return clientExitCode
      return serverExitCode

    sleep(PollIntervalMs)

proc runQuickRun(gameFolder: string, port: int): int =
  let
    rootDir = repoRoot()
    nimExe = findExe("nim")
  if nimExe.len == 0:
    echo "Unable to find 'nim' on PATH."
    return 1

  let
    game = ensureGameFolder(rootDir, gameFolder)
    gameExe = exePathFor(rootDir, game.sourceRelative)
    clientExe = exePathFor(rootDir, ClientSourceRelative)
    clientWorkDir = absolutePath(rootDir / "client")
    portArg = "--port=" & $port

  echo "Using port ", port, "."

  result = compileTarget(nimExe, rootDir, game.label & " server", game.sourceRelative)
  if result != 0:
    return result

  result = compileTarget(nimExe, rootDir, "client", ClientSourceRelative)
  if result != 0:
    return result

  try:
    serverProcess = launchManagedProcess(game.label & " server", gameExe, game.workDir, [portArg])
  except CatchableError as e:
    echo "Failed to start server: ", e.msg
    cleanupChildren()
    return 1

  if not waitForServerReady(port):
    cleanupChildren()
    return 1

  try:
    clientProcess = launchManagedProcess("client", clientExe, clientWorkDir, [portArg])
  except CatchableError as e:
    echo "Failed to start client: ", e.msg
    cleanupChildren()
    return 1

  result = waitForChildren()
  cleanupChildren()

when isMainModule:
  addExitProc(cleanupAtExit)
  setControlCHook(controlCHook)
  randomize()

  if paramCount() < 1 or paramCount() > 2:
    echo usage()
    quit(1)

  try:
    let gameFolder = paramStr(1)
    let port =
      if paramCount() >= 2:
        parsePort(paramStr(2))
      else:
        chooseRandomPort()
    quit(runQuickRun(gameFolder, port))
  except ValueError as e:
    echo e.msg
    echo usage()
    quit(1)

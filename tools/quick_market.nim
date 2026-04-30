import std/[exitprocs, monotimes, net, os, osproc, parseopt, sequtils, strutils, times]

const
  ServerSource = "marketboard" / "marketboard.nim"
  ClientSource = "clients" / "player_client.nim"
  BotSources = [
    ("StillForge", "marketboard" / "players" / "still_forge.nim"),
  ]
  ServerReadyTimeoutMs = 5000
  PollIntervalMs = 100

var
  serverProcess: Process
  clientProcess: Process
  botProcesses: seq[Process]
  botNames: seq[string]
  cleanupStarted = false

type
  QuickMarketConfig = object
    address: string
    port: int
    bots: seq[string]

proc repoRoot(): string =
  absolutePath(getCurrentDir())

proc usage(): string =
  "Usage: quick_market [--address:ADDR] [--port:N] [--bots:StillForge,...]\n" &
  "Launches the marketboard server, a player client, and bot players.\n" &
  "Available bots: " & BotSources.mapIt(it[0]).join(", ")

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
    stopManagedProcess(botProcesses[i], botNames[i])
  botProcesses.setLen(0)
  botNames.setLen(0)
  stopManagedProcess(clientProcess, "client")
  stopManagedProcess(serverProcess, "server")

proc cleanupAtExit() {.noconv.} =
  cleanupChildren()

proc controlCHook() {.noconv.} =
  echo ""
  echo "Ctrl+C received, shutting down..."
  cleanupChildren()
  quit(130)

proc compileTarget(nimExe, rootDir, label, sourceRelative: string): int =
  echo "Compiling ", label, "..."
  var process: Process
  try:
    process = startProcess(
      nimExe,
      workingDir = rootDir,
      args = ["c", sourceRelative],
      options = {poParentStreams}
    )
    result = process.waitForExit()
  finally:
    if not process.isNil:
      try: process.close()
      except CatchableError: discard
  if result != 0:
    echo label, " compile failed with exit code ", result, "."

proc exePathFor(rootDir, sourceRelative: string): string =
  absolutePath(rootDir / sourceRelative.changeFileExt(ExeExts[0]))

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
        try: socket.close()
        except CatchableError: discard
      sleep(PollIntervalMs)
  echo "Timed out waiting for server on port ", port, "."
  false

proc findBotSource(name: string): string =
  for (botName, source) in BotSources:
    if botName.toLowerAscii() == name.toLowerAscii():
      return source
  raise newException(ValueError, "Unknown bot: " & name & ". Available: " &
    BotSources.mapIt(it[0]).join(", "))

proc waitForChildren(): int =
  while true:
    let serverExit = if serverProcess.isNil: 1
                     else: (try: serverProcess.peekExitCode() except: 1)
    if serverExit != -1:
      echo "Server exited with code ", serverExit, "."
      cleanupChildren()
      return serverExit

    let clientExit = if clientProcess.isNil: -1
                     else: (try: clientProcess.peekExitCode() except: 1)
    if clientExit != -1:
      echo "Client exited with code ", clientExit, "."
      cleanupChildren()
      return clientExit

    sleep(PollIntervalMs)

proc parseArgs(): QuickMarketConfig =
  result.address = "localhost"
  result.port = 8080
  result.bots = @["StillForge"]

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        if val.len > 0: result.address = val
      of "port":
        if val.len > 0: result.port = parseInt(val)
      of "bots":
        if val.len > 0:
          result.bots = val.split(',')
      of "no-bots":
        result.bots = @[]
      else:
        raise newException(ValueError, "Unknown option: --" & key)
    of cmdArgument:
      discard
    else:
      discard

proc run(config: QuickMarketConfig): int =
  let
    rootDir = repoRoot()
    nimExe = findExe("nim")
  if nimExe.len == 0:
    echo "Unable to find 'nim' on PATH."
    return 1

  let
    serverExe = exePathFor(rootDir, ServerSource)
    clientExe = exePathFor(rootDir, ClientSource)
    clientWorkDir = absolutePath(rootDir / "clients")
    serverWorkDir = absolutePath(rootDir / "marketboard")

  result = compileTarget(nimExe, rootDir, "server", ServerSource)
  if result != 0: return

  result = compileTarget(nimExe, rootDir, "client", ClientSource)
  if result != 0: return

  var botExes: seq[tuple[name, exe, workDir: string]]
  for botName in config.bots:
    let source = findBotSource(botName)
    result = compileTarget(nimExe, rootDir, botName, source)
    if result != 0: return
    botExes.add (botName, exePathFor(rootDir, source),
                 absolutePath(rootDir / source.parentDir))

  echo "Starting server on ", config.address, ":", config.port, "..."
  try:
    serverProcess = startProcess(
      serverExe,
      workingDir = serverWorkDir,
      args = ["--port:" & $config.port, "--address:" & config.address],
      options = {poParentStreams}
    )
  except CatchableError as e:
    echo "Failed to start server: ", e.msg
    return 1

  if not waitForServerReady(config.port):
    cleanupChildren()
    return 1

  echo "Starting player client..."
  let clientAddr = "--address:ws://" & config.address & ":" & $config.port & "/player"
  try:
    clientProcess = startProcess(
      clientExe,
      workingDir = clientWorkDir,
      args = [clientAddr, "--title:Marketboard"],
      options = {poParentStreams}
    )
  except CatchableError as e:
    echo "Failed to start client: ", e.msg
    cleanupChildren()
    return 1

  sleep(500)

  for bot in botExes:
    echo "Starting bot: ", bot.name, "..."
    try:
      let p = startProcess(
        bot.exe,
        workingDir = bot.workDir,
        args = ["--address:" & config.address, "--port:" & $config.port,
                "--name:" & bot.name],
        options = {poParentStreams}
      )
      botProcesses.add p
      botNames.add bot.name
    except CatchableError as e:
      echo "Failed to start bot ", bot.name, ": ", e.msg
      cleanupChildren()
      return 1

  echo "All processes running. Close the client window or Ctrl+C to stop."
  result = waitForChildren()
  cleanupChildren()

when isMainModule:
  addExitProc(cleanupAtExit)
  setControlCHook(controlCHook)
  try:
    quit(run(parseArgs()))
  except ValueError as e:
    echo e.msg
    echo usage()
    quit(1)

import
  std/[
    json, monotimes, net, os, osproc, parseopt, strtabs, strutils, times
  ]

const
  DefaultHost = "127.0.0.1"
  DefaultTimeoutSeconds = 10.0
  PollMs = 100
  ConfigEnv = "COGAME_CONFIG_URI"
  ResultsEnv = "COGAME_RESULTS_URI"
  ResultsMethodEnv = "COGAME_RESULTS_METHOD"
  SaveReplayEnv = "COGAME_SAVE_REPLAY_URI"
  SaveReplayMethodEnv = "COGAME_SAVE_REPLAY_METHOD"
  LoadReplayEnv = "COGAME_LOAD_REPLAY_URI"
  ReplayServerEnv = "COGAME_REPLAY_SERVER"
  LogEnv = "COGAME_LOG_URI"
  HostEnv = "COGAME_HOST"
  PortEnv = "COGAME_PORT"
  LegacyReplayDownloadEnv = "REPLAY_DOWNLOAD_URL"
  DefaultConfigJson = "{}"
  DefaultReplayBytes = "cogame-certify-replay"

type
  CogameCertifyError = object of CatchableError

  CertStatus = enum
    CertPass,
    CertFail,
    CertSkip

  CertPhase = enum
    PhaseAll,
    PhaseLive,
    PhaseReplay

  Criterion = object
    id: string
    name: string
    status: CertStatus
    message: string

  CertifyArgs = object
    target: string
    workspace: string
    timeoutSeconds: float
    phase: CertPhase
    configJson: string
    replayPath: string
    nimBin: string

  LaunchTarget = object
    executable: string
    workDir: string

  ServerArgs = object
    workspace: string
    port: int
    configJson: string
    replayData: string

  ProbePaths = object
    workspace: string
    requestLog: string
    configHit: string
    resultsBody: string
    resultsMethod: string
    replayBody: string
    replayMethod: string
    loadReplayHit: string
    legacyReplayHit: string
    logBody: string

  HttpRequest = object
    httpMethod: string
    path: string
    body: string

proc fail(message: string) =
  ## Raises one Cogame certification error.
  raise newException(CogameCertifyError, message)

proc repoRoot(): string =
  ## Returns the BitWorld repository root containing this tool.
  parentDir(parentDir(currentSourcePath()))

proc usage(): string =
  ## Returns command-line usage text.
  """
Usage:
  cogame_certify [options] <executable-or-nim-file>

Options:
  --timeout:<seconds>  Probe timeout. Default: 10.
  --workspace:<path>   Artifact workspace. Default: bitworld/tmp.
  --phase:<name>       all, live, or replay. Default: all.
  --config:<json>      Config JSON served from COGAME_CONFIG_URI.
  --replay:<path>      Replay bytes served from COGAME_LOAD_REPLAY_URI.
  --nim:<path>         Nim compiler. Default: nim.
  --help               Show this help.

Examples:
  cogame_certify ./out/my_game
  cogame_certify games/thing/thing.nim --timeout:20
"""

proc statusText(status: CertStatus): string =
  ## Returns a display label for one criterion status.
  case status
  of CertPass:
    "PASS"
  of CertFail:
    "FAIL"
  of CertSkip:
    "SKIP"

proc addCriterion(
  criteria: var seq[Criterion],
  id,
  name: string,
  status: CertStatus,
  message = ""
) =
  ## Appends one certification criterion.
  criteria.add(Criterion(
    id: id,
    name: name,
    status: status,
    message: message
  ))

proc passCriterion(
  criteria: var seq[Criterion],
  id,
  name,
  message: string
) =
  ## Appends one passing certification criterion.
  criteria.addCriterion(id, name, CertPass, message)

proc failCriterion(
  criteria: var seq[Criterion],
  id,
  name,
  message: string
) =
  ## Appends one failing certification criterion.
  criteria.addCriterion(id, name, CertFail, message)

proc skipCriterion(
  criteria: var seq[Criterion],
  id,
  name,
  message: string
) =
  ## Appends one skipped certification criterion.
  criteria.addCriterion(id, name, CertSkip, message)

proc printCriteria(criteria: openArray[Criterion]) =
  ## Prints all certification criteria.
  echo "Cogame certification criteria:"
  for criterion in criteria:
    var line = "[" & statusText(criterion.status) & "] " & criterion.id
    line.add(" - " & criterion.name)
    if criterion.message.len > 0:
      line.add(": " & criterion.message)
    echo line

proc parseFloatOption(value, option: string): float =
  ## Parses one floating-point command-line option.
  try:
    result = value.parseFloat()
  except ValueError:
    fail(option & " must be a number")

proc parsePhase(value: string): CertPhase =
  ## Parses one phase option.
  case value.toLowerAscii()
  of "all":
    result = PhaseAll
  of "live":
    result = PhaseLive
  of "replay":
    result = PhaseReplay
  else:
    fail("--phase must be all, live, or replay")

proc defaultWorkspace(): string =
  ## Returns a default artifact workspace path.
  repoRoot() / "tmp" / ("cogame-cert-" & $getTime().toUnix())

proc parseArgs(): CertifyArgs =
  ## Parses command-line arguments.
  result.timeoutSeconds = DefaultTimeoutSeconds
  result.phase = PhaseAll
  result.configJson = DefaultConfigJson
  result.nimBin = "nim"
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if result.target.len > 0:
        fail("only one executable or Nim file may be provided")
      result.target = key
    of cmdLongOption:
      case key
      of "timeout":
        result.timeoutSeconds = parseFloatOption(val, "--timeout")
      of "workspace":
        result.workspace = val
      of "phase":
        result.phase = parsePhase(val)
      of "config":
        result.configJson = val
      of "replay":
        result.replayPath = val
      of "nim":
        result.nimBin = val
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
    of cmdEnd:
      discard
  if result.target.len == 0:
    echo usage()
    quit(1)
  if result.workspace.len == 0:
    result.workspace = defaultWorkspace()

proc paths(workspace: string): ProbePaths =
  ## Returns all probe artifact paths.
  result.workspace = workspace
  result.requestLog = workspace / "requests.log"
  result.configHit = workspace / "config.hit"
  result.resultsBody = workspace / "results.body"
  result.resultsMethod = workspace / "results.method"
  result.replayBody = workspace / "save_replay.body"
  result.replayMethod = workspace / "save_replay.method"
  result.loadReplayHit = workspace / "load_replay.hit"
  result.legacyReplayHit = workspace / "legacy_replay.hit"
  result.logBody = workspace / "log.body"

proc httpUri(port: int, path: string): string =
  ## Returns one local HTTP probe URI.
  "http://" & DefaultHost & ":" & $port & path

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

proc statusCodeText(status: int): string =
  ## Returns the HTTP status line text.
  case status
  of 200:
    "OK"
  of 404:
    "Not Found"
  else:
    "OK"

proc sendHttp(socket: Socket, status: int, body, contentType: string) =
  ## Sends one HTTP response.
  let response =
    "HTTP/1.1 " & $status & " " & statusCodeText(status) & "\r\n" &
    "Content-Type: " & contentType & "\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    "Connection: close\r\n\r\n" &
    body
  socket.send(response)

proc readHttpRequest(socket: Socket): HttpRequest =
  ## Reads one small HTTP request.
  var raw = ""
  while "\r\n\r\n" notin raw:
    let chunk = socket.recv(1, 5000)
    if chunk.len == 0:
      break
    raw.add(chunk)
    if raw.len > 1024 * 1024:
      break
  let headerEnd = raw.find("\r\n\r\n")
  if headerEnd < 0:
    return
  let
    headerText = raw[0 ..< headerEnd]
    lines = headerText.split("\r\n")
    parts = lines[0].splitWhitespace()
  if parts.len >= 2:
    result.httpMethod = parts[0]
    result.path = parts[1]
  var contentLength = 0
  for i in 1 ..< lines.len:
    let line = lines[i]
    if line.toLowerAscii().startsWith("content-length:"):
      contentLength = line.split(":", 1)[1].strip().parseInt()
  result.body = raw[(headerEnd + 4) .. ^1]
  while result.body.len < contentLength:
    let chunk = socket.recv(contentLength - result.body.len, 5000)
    if chunk.len == 0:
      break
    result.body.add(chunk)

proc cleanPathOnly(path: string): string =
  ## Returns the path without query parameters.
  let queryAt = path.find('?')
  if queryAt >= 0:
    path[0 ..< queryAt]
  else:
    path

proc appendFile(path, data: string) =
  ## Appends data to one file.
  var file = open(path, fmAppend)
  try:
    file.write(data)
  finally:
    file.close()

proc mark(path, text: string) =
  ## Writes one probe marker file.
  writeFile(path, text)

proc handleProbeRequest(
  request: HttpRequest,
  probePaths: ProbePaths,
  configJson,
  replayData: string
): bool =
  ## Handles one probe server request and returns true when shutting down.
  let path = cleanPathOnly(request.path)
  appendFile(
    probePaths.requestLog,
    request.httpMethod & " " & request.path & "\n"
  )
  case path
  of "/healthz":
    discard
  of "/shutdown":
    return true
  of "/config":
    mark(probePaths.configHit, $getTime().toUnix())
  of "/results":
    mark(probePaths.resultsMethod, request.httpMethod)
    mark(probePaths.resultsBody, request.body)
  of "/save-replay":
    mark(probePaths.replayMethod, request.httpMethod)
    mark(probePaths.replayBody, request.body)
  of "/load-replay":
    mark(probePaths.loadReplayHit, $getTime().toUnix())
  of "/legacy-replay":
    mark(probePaths.legacyReplayHit, $getTime().toUnix())
  of "/log":
    appendFile(probePaths.logBody, request.body)
  else:
    discard
  false

proc respondProbeRequest(
  socket: Socket,
  request: HttpRequest,
  configJson,
  replayData: string
) =
  ## Sends one response for a probe server request.
  case cleanPathOnly(request.path)
  of "/healthz", "/shutdown":
    socket.sendHttp(200, "ok\n", "text/plain")
  of "/config":
    socket.sendHttp(200, configJson, "application/json")
  of "/load-replay", "/legacy-replay":
    socket.sendHttp(200, replayData, "application/octet-stream")
  of "/results", "/save-replay", "/log":
    socket.sendHttp(200, """{"status":"ok"}""" & "\n", "application/json")
  else:
    socket.sendHttp(404, "not found\n", "text/plain")

proc runProbeServer(args: ServerArgs) =
  ## Runs the local HTTP probe server.
  createDir(args.workspace)
  let probePaths = paths(args.workspace)
  var server = newSocket()
  try:
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(args.port), DefaultHost)
    server.listen()
    while true:
      var client: owned(Socket)
      server.accept(client)
      try:
        let request = client.readHttpRequest()
        let stop = handleProbeRequest(
          request,
          probePaths,
          args.configJson,
          args.replayData
        )
        client.respondProbeRequest(request, args.configJson, args.replayData)
        if stop:
          break
      finally:
        client.close()
  finally:
    server.close()

proc parseServerArgs(): ServerArgs =
  ## Parses hidden probe-server arguments.
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "workspace":
        result.workspace = val
      of "port":
        result.port = val.parseInt()
      of "config":
        result.configJson = val
      of "replay":
        result.replayData = readFile(val)
      else:
        discard
    else:
      discard
  if result.workspace.len == 0 or result.port <= 0:
    fail("probe server requires --workspace and --port")
  if result.configJson.len == 0:
    result.configJson = DefaultConfigJson
  if result.replayData.len == 0:
    result.replayData = DefaultReplayBytes

proc runProcessAndWait(
  executable: string,
  workingDir: string,
  args: openArray[string]
): int =
  ## Runs one command with inherited streams.
  var process: Process
  try:
    process = startProcess(
      executable,
      workingDir = workingDir,
      args = args,
      options = {poParentStreams, poUsePath}
    )
    result = process.waitForExit()
  finally:
    if not process.isNil:
      process.close()

proc compileIfNeeded(args: CertifyArgs): LaunchTarget =
  ## Compiles a Nim target or returns an executable launch target.
  let targetPath = absolutePath(args.target)
  if not fileExists(targetPath):
    fail("target does not exist: " & args.target)
  if targetPath.splitFile().ext != ".nim":
    return LaunchTarget(
      executable: targetPath,
      workDir: targetPath.parentDir()
    )

  let outputPath =
    args.workspace / "bin" / targetPath.splitFile().name
  createDir(outputPath.parentDir())
  let exitCode = runProcessAndWait(
    args.nimBin,
    getCurrentDir(),
    ["c", "--out:" & outputPath, targetPath]
  )
  if exitCode != 0:
    fail("Nim compile failed with exit code " & $exitCode)
  LaunchTarget(
    executable: outputPath,
    workDir: targetPath.parentDir()
  )

proc envWithProbe(
  serverPort,
  gamePort: int,
  phase: CertPhase
): StringTableRef =
  ## Builds child environment variables for one probe phase.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result[HostEnv] = DefaultHost
  result[PortEnv] = $gamePort
  result[ConfigEnv] = httpUri(serverPort, "/config")
  result[LogEnv] = httpUri(serverPort, "/log")
  case phase
  of PhaseLive:
    result[ResultsEnv] = httpUri(serverPort, "/results")
    result[ResultsMethodEnv] = "PUT"
    result[SaveReplayEnv] = httpUri(serverPort, "/save-replay")
    result[SaveReplayMethodEnv] = "PUT"
  of PhaseReplay:
    result[LoadReplayEnv] = httpUri(serverPort, "/load-replay")
    result[ReplayServerEnv] = "1"
    result[LegacyReplayDownloadEnv] = httpUri(serverPort, "/legacy-replay")
  of PhaseAll:
    discard

proc fetchStatus(port: int, path: string): int =
  ## Fetches one HTTP status code from a local server.
  var socket = newSocket()
  try:
    socket.connect(DefaultHost, Port(port), timeout = 500)
    socket.send(
      "GET " & path & " HTTP/1.1\r\n" &
      "Host: " & DefaultHost & "\r\n" &
      "Connection: close\r\n\r\n"
    )
    let response = socket.recv(256, 500)
    let firstLine = response.split("\r\n")[0]
    let parts = firstLine.splitWhitespace()
    if parts.len >= 2:
      return parts[1].parseInt()
  except CatchableError:
    discard
  finally:
    socket.close()
  0

proc waitForHttp(port: int, timeoutSeconds: float): bool =
  ## Waits for a local server to answer GET /healthz.
  let
    startedAt = getMonoTime()
    timeout = initDuration(milliseconds = max(1, int(timeoutSeconds * 1000)))
  while getMonoTime() - startedAt < timeout:
    let status = fetchStatus(port, "/healthz")
    if status >= 200 and status < 300:
      return true
    sleep(PollMs)
  false

proc processRunning(process: Process): bool =
  ## Returns true when a process still appears to be running.
  try:
    process.peekExitCode() == -1
  except CatchableError:
    false

proc stopProcess(process: Process) =
  ## Stops one child process.
  if process.isNil:
    return
  try:
    if process.processRunning():
      process.terminate()
      discard process.waitForExit(1000)
    if process.processRunning():
      process.kill()
      discard process.waitForExit(1000)
  except CatchableError:
    discard

proc runGamePhase(
  target: LaunchTarget,
  serverPort: int,
  phase: CertPhase,
  timeoutSeconds: float,
  criteria: var seq[Criterion]
) =
  ## Runs one executable probe phase.
  let
    phaseName =
      if phase == PhaseLive:
        "live"
      else:
        "replay"
    gamePort = findOpenPort()
    env = envWithProbe(serverPort, gamePort, phase)
  var process: Process
  try:
    process = startProcess(
      target.executable,
      workingDir = target.workDir,
      env = env,
      options = {poParentStreams}
    )
    criteria.passCriterion(
      phaseName & ".process",
      "Process starts",
      "pid " & $process.processID()
    )
    let healthy = waitForHttp(gamePort, min(timeoutSeconds, 5.0))
    if healthy:
      criteria.passCriterion(
        phaseName & ".http",
        "COGAME_HOST and COGAME_PORT",
        "GET /healthz answered on " & DefaultHost & ":" & $gamePort
      )
    else:
      criteria.failCriterion(
        phaseName & ".http",
        "COGAME_HOST and COGAME_PORT",
        "GET /healthz did not answer on " & DefaultHost & ":" & $gamePort
      )
    if phase == PhaseReplay:
      if healthy:
        criteria.passCriterion(
          "env.replay_server",
          "COGAME_REPLAY_SERVER",
          "replay server answered while set to 1"
        )
      else:
        criteria.failCriterion(
          "env.replay_server",
          "COGAME_REPLAY_SERVER",
          "replay server did not answer while set to 1"
        )
    sleep(max(0, int(timeoutSeconds * 1000)))
  except CatchableError as e:
    criteria.failCriterion(
      phaseName & ".process",
      "Process starts",
      e.msg
    )
  finally:
    if not process.isNil:
      process.stopProcess()
      process.close()

proc checkFileHit(
  criteria: var seq[Criterion],
  id,
  name,
  path: string
) =
  ## Checks that one probe file was written.
  if fileExists(path):
    criteria.passCriterion(id, name, path)
  else:
    criteria.failCriterion(id, name, "not observed")

proc checkMethod(
  criteria: var seq[Criterion],
  id,
  name,
  path,
  expected: string
) =
  ## Checks one observed HTTP method.
  if not fileExists(path):
    criteria.failCriterion(id, name, "not observed")
    return
  let actual = readFile(path).strip().toUpperAscii()
  if actual == expected:
    criteria.passCriterion(id, name, actual)
  else:
    criteria.failCriterion(id, name, "expected " & expected & ", got " & actual)

proc checkProbeArtifacts(
  args: CertifyArgs,
  criteria: var seq[Criterion]
) =
  ## Adds criteria from observed probe server artifacts.
  let probePaths = paths(args.workspace)
  criteria.checkFileHit(
    "env.config.read",
    "COGAME_CONFIG_URI read",
    probePaths.configHit
  )
  if args.phase in {PhaseAll, PhaseLive}:
    criteria.checkFileHit(
      "env.results.write",
      "COGAME_RESULTS_URI write",
      probePaths.resultsBody
    )
    criteria.checkMethod(
      "env.results.method",
      "COGAME_RESULTS_METHOD",
      probePaths.resultsMethod,
      "PUT"
    )
    criteria.checkFileHit(
      "env.save_replay.write",
      "COGAME_SAVE_REPLAY_URI write",
      probePaths.replayBody
    )
    criteria.checkMethod(
      "env.save_replay.method",
      "COGAME_SAVE_REPLAY_METHOD",
      probePaths.replayMethod,
      "PUT"
    )
  if args.phase in {PhaseAll, PhaseReplay}:
    criteria.checkFileHit(
      "env.load_replay.read",
      "COGAME_LOAD_REPLAY_URI read",
      probePaths.loadReplayHit
    )
    criteria.checkFileHit(
      "env.legacy_replay_download.read",
      "REPLAY_DOWNLOAD_URL read",
      probePaths.legacyReplayHit
    )
  criteria.skipCriterion(
    "env.log.write",
    "COGAME_LOG_URI",
    "optional diagnostic stream"
  )

proc startProbeServer(args: CertifyArgs, port: int): Process =
  ## Starts the local HTTP probe server process.
  var serverArgs = @[
    "--serve",
    "--workspace:" & args.workspace,
    "--port:" & $port,
    "--config:" & args.configJson
  ]
  if args.replayPath.len > 0:
    serverArgs.add("--replay:" & absolutePath(args.replayPath))
  result = startProcess(
    getAppFilename(),
    workingDir = getCurrentDir(),
    args = serverArgs,
    options = {poParentStreams}
  )

proc shutdownProbeServer(port: int) =
  ## Asks the local probe server to shut down.
  discard fetchStatus(port, "/shutdown")

proc runCertifier(args: CertifyArgs) =
  ## Runs Cogame executable certification.
  createDir(args.workspace)
  let
    target = compileIfNeeded(args)
    serverPort = findOpenPort()
  var
    criteria: seq[Criterion]
    serverProcess: Process
  try:
    serverProcess = startProbeServer(args, serverPort)
    if waitForHttp(serverPort, 5.0):
      criteria.passCriterion(
        "probe.http",
        "Probe HTTP server",
        "listening on " & DefaultHost & ":" & $serverPort
      )
    else:
      criteria.failCriterion(
        "probe.http",
        "Probe HTTP server",
        "did not answer"
      )
      printCriteria(criteria)
      return

    case args.phase
    of PhaseAll:
      runGamePhase(target, serverPort, PhaseLive, args.timeoutSeconds, criteria)
      runGamePhase(target, serverPort, PhaseReplay, args.timeoutSeconds, criteria)
    of PhaseLive:
      runGamePhase(target, serverPort, PhaseLive, args.timeoutSeconds, criteria)
    of PhaseReplay:
      runGamePhase(target, serverPort, PhaseReplay, args.timeoutSeconds, criteria)

    checkProbeArtifacts(args, criteria)
    printCriteria(criteria)
    echo "Workspace: ", args.workspace
  finally:
    shutdownProbeServer(serverPort)
    if not serverProcess.isNil:
      serverProcess.stopProcess()
      serverProcess.close()

proc isServerMode(): bool =
  ## Returns true when hidden probe-server mode was requested.
  for kind, key, val in getopt():
    discard val
    if kind == cmdLongOption and key == "serve":
      return true
  false

proc main() =
  ## Runs the Cogame certifier entry point.
  try:
    if isServerMode():
      runProbeServer(parseServerArgs())
    else:
      runCertifier(parseArgs())
  except CogameCertifyError as e:
    stderr.writeLine("cogame_certify failed: " & e.msg)
    quit(1)
  except CatchableError as e:
    stderr.writeLine("cogame_certify failed: " & e.msg)
    quit(1)

main()

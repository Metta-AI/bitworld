import
  std/[
    algorithm, net, os, osproc, parseopt, strutils, times
  ],
  mummy,
  taggy

from std/httpclient import close, getContent, newHttpClient

const
  DefaultHost = "0.0.0.0"
  DefaultPort = 2080
  GamePortStart = 2100
  GamePortEnd = 2199
  DockerBinEnv = "GAMES_SERVER_DOCKER"
  DockerImageEnv = "GAMES_SERVER_IMAGE"
  DockerModeEnv = "GAMES_SERVER_MODE"
  ReplayDirEnv = "GAMES_SERVER_REPLAY_DIR"
  WorkspaceRootEnv = "GAMES_SERVER_WORKSPACE_ROOT"
  NotTooDumbImageEnv = "GAMES_SERVER_NOTTOODUMB_IMAGE"
  IVoteALotImageEnv = "GAMES_SERVER_IVOTEALOT_IMAGE"
  DefaultDockerImage = "bitworld-among-them"
  DefaultDockerMode = "release"
  DefaultNotTooDumbImage = "bitworld-nottoodumb"
  DefaultIVoteALotImage = "bitworld-ivotewell"
  ContainerReplayDir = "/replays"
  ReplayPathPrefix = "/replays/"
  ReplayPlayPath = "/replays/play"
  LogsPath = "/logs"
  HealthPath = "/healthz"
  CogameReplayEnv = "COGAME_SAVE_REPLAY_PATH"
  ServerLabelKey = "bitworld.games_server"
  ServerLabelValue = "among_them"
  BotLabelValue = "among_them_bot"
  ServerLabel = ServerLabelKey & "=" & ServerLabelValue
  BotLabel = ServerLabelKey & "=" & BotLabelValue
  PortLabel = "bitworld.games_server.port"
  CreatedLabel = "bitworld.games_server.created"
  ReplayLabel = "bitworld.games_server.replay"
  KindLabel = "bitworld.games_server.kind"
  BotGameLabel = "bitworld.games_server.game"
  BotKindLabel = "bitworld.games_server.bot"
  LiveKind = "game"
  ReplayKind = "replay"
  NotTooDumbBot = "nottoodumb"
  IVoteALotBot = "ivotealot"
  BotHost = "host.docker.internal"
  PageCss = """
body {
  margin: 0;
  background: #9090bb;
  color: #000020;
  font-family: Verdana, Helvetica, Arial, sans-serif;
  font-size: 11px;
}
a {
  color: #0000c0;
  text-decoration: none;
}
a:hover {
  color: #e23e3e;
  text-decoration: underline;
}
.page {
  width: min(1120px, calc(100vw - 24px));
  margin: 12px auto;
  padding: 12px;
  border: 1px solid #000;
  background: #f8f8f8;
}
.title {
  margin: 0;
  font: bold 26px/1.15 "Trebuchet MS", Verdana, sans-serif;
}
.small {
  font-size: 11px;
}
.large {
  font-size: 13px;
}
table {
  width: 100%;
  border-collapse: collapse;
}
td,
th {
  padding: 4px;
  border: 1px solid #707096;
  vertical-align: top;
}
.head {
  background: #9090bb;
  color: #eeeeff;
  font-weight: 700;
}
.cat {
  background: #7676a8;
  color: #fff788;
  font-weight: 700;
}
.row1 {
  background: #e8e8e8;
}
.row2 {
  background: #f1f1f1;
}
.right {
  text-align: right;
}
.center {
  text-align: center;
}
.nowrap {
  white-space: nowrap;
}
.button {
  border: 1px solid #303050;
  background: #eeeeff;
  color: #000020;
  font: 11px Verdana, Helvetica, Arial, sans-serif;
  padding: 2px 8px;
}
.input {
  width: 64px;
  border: 1px solid #707096;
  font: 11px Verdana, Helvetica, Arial, sans-serif;
}
.notice {
  margin: 8px 0;
}
.footer {
  margin: 12px 0 0;
}
.logs {
  margin: 0;
  padding: 8px;
  border: 1px solid #707096;
  background: #000020;
  color: #eeeeff;
  font: 11px Monaco, Consolas, monospace;
  overflow: auto;
  white-space: pre-wrap;
}
"""

type
  GamesServerError = object of CatchableError

  CommandResult = object
    output: string
    code: int

  ContainerKind = enum
    LiveGame
    ReplayServer

  BotKind = enum
    NotTooDumb
    IVoteALot

  GameContainer = object
    name: string
    status: string
    port: int
    created: int64
    replay: string
    kind: ContainerKind

  BotContainer = object
    name: string
    status: string
    game: string
    bot: BotKind
    created: int64

  ReplayFile = object
    name: string
    size: int64
    modified: int64

proc esc(text: string): string =
  ## Escapes HTML special characters.
  result = text
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")

proc parseIntSafe(value: string): int =
  ## Parses an integer and returns zero on failure.
  try:
    result = value.strip().parseInt()
  except ValueError:
    result = 0

proc parseInt64Safe(value: string): int64 =
  ## Parses an int64 and returns zero on failure.
  try:
    result = value.strip().parseBiggestInt().int64
  except ValueError:
    result = 0

proc clampInt(value, low, high: int): int =
  ## Restricts an integer to an inclusive range.
  if value < low:
    return low
  if value > high:
    return high
  value

proc hexValue(c: char): int =
  ## Converts one hex character to its integer value.
  case c
  of '0' .. '9':
    ord(c) - ord('0')
  of 'a' .. 'f':
    10 + ord(c) - ord('a')
  of 'A' .. 'F':
    10 + ord(c) - ord('A')
  else:
    -1

proc decodeUrlComponent(value: string): string =
  ## Decodes a URL form component.
  var i = 0
  while i < value.len:
    if value[i] == '+':
      result.add(' ')
      inc i
    elif value[i] == '%' and i + 2 < value.len:
      let
        high = hexValue(value[i + 1])
        low = hexValue(value[i + 2])
      if high >= 0 and low >= 0:
        result.add(char(high * 16 + low))
        i += 3
      else:
        result.add(value[i])
        inc i
    else:
      result.add(value[i])
      inc i

proc parseUrlPairs(value: string): seq[(string, string)] =
  ## Parses URL encoded key/value pairs.
  if value.len == 0:
    return
  for piece in value.split('&'):
    if piece.len == 0:
      continue
    let splitAt = piece.find('=')
    if splitAt < 0:
      result.add((decodeUrlComponent(piece), ""))
    else:
      let
        rawKey =
          if splitAt > 0:
            piece[0 ..< splitAt]
          else:
            ""
        rawValue =
          if splitAt + 1 < piece.len:
            piece[splitAt + 1 .. ^1]
          else:
            ""
      result.add((
        decodeUrlComponent(rawKey),
        decodeUrlComponent(rawValue)
      ))

proc envValue(name, defaultValue: string): string =
  ## Reads an environment setting with a fallback.
  result = getEnv(name, defaultValue).strip()
  if result.len == 0:
    result = defaultValue

proc dockerBin(): string =
  ## Returns the Docker-compatible CLI path.
  envValue(DockerBinEnv, "docker")

proc dockerImage(): string =
  ## Returns the image used for new Among Them containers.
  envValue(DockerImageEnv, DefaultDockerImage)

proc dockerMode(): string =
  ## Returns the container launch mode.
  envValue(DockerModeEnv, DefaultDockerMode).toLowerAscii()

proc botImage(kind: BotKind): string =
  ## Returns the Docker image for one bot kind.
  case kind
  of NotTooDumb:
    envValue(NotTooDumbImageEnv, DefaultNotTooDumbImage)
  of IVoteALot:
    envValue(IVoteALotImageEnv, DefaultIVoteALotImage)

proc defaultWorkspaceRoot(): string =
  ## Returns the host workspace root mounted by runner containers.
  parentDir(parentDir(parentDir(currentSourcePath())))

proc workspaceRoot(): string =
  ## Returns the configured host workspace root.
  envValue(WorkspaceRootEnv, defaultWorkspaceRoot())

proc defaultReplayDir(): string =
  ## Returns the default host replay directory.
  parentDir(currentSourcePath()) / "replays"

proc replayDir(): string =
  ## Returns the configured host replay directory.
  envValue(ReplayDirEnv, defaultReplayDir())

proc ensureReplayDir() =
  ## Creates the replay directory when it is missing.
  try:
    createDir(replayDir())
  except OSError as e:
    raise newException(
      GamesServerError,
      "could not create replay directory: " & e.msg
    )

proc dockerResult(args: openArray[string]): CommandResult =
  ## Runs Docker and captures its merged stdout and stderr.
  try:
    let command = quoteShellCommand(@[dockerBin()] & @args)
    let res = execCmdEx(
      command,
      options = {poEvalCommand, poStdErrToStdOut}
    )
    result.output = res.output
    result.code = res.exitCode
  except OSError as e:
    raise newException(
      GamesServerError,
      "could not run Docker: " & e.msg
    )

proc requireDocker(args: openArray[string]): string =
  ## Runs Docker and raises a library-specific error on failure.
  let res = dockerResult(args)
  if res.code != 0:
    raise newException(
      GamesServerError,
      "docker " & args.join(" ") & " failed: " & res.output.strip()
    )
  res.output.strip()

proc portAvailable(port: int): bool =
  ## Returns true when the host can bind a TCP port.
  var socket = newSocket()
  try:
    socket.setSockOpt(OptReuseAddr, true)
    socket.bindAddr(Port(port), "0.0.0.0")
    result = true
  except OSError:
    result = false
  finally:
    socket.close()

proc cleanContainerName(value: string): string =
  ## Keeps only Docker-safe container name characters.
  for c in value:
    if c.isAlphaNumeric() or c == '_' or c == '-':
      result.add(c)
  if result.len > 96:
    result = result[0 .. 95]

proc logUrl(name: string): string =
  ## Builds the log viewer URL for one container.
  LogsPath & "?name=" & cleanContainerName(name)

proc botKindLabel(kind: BotKind): string =
  ## Returns the stable form value for one bot kind.
  case kind
  of NotTooDumb:
    NotTooDumbBot
  of IVoteALot:
    IVoteALotBot

proc botKindTitle(kind: BotKind): string =
  ## Returns the display label for one bot kind.
  case kind
  of NotTooDumb:
    "nottoodumb"
  of IVoteALot:
    "ivotealot"

proc botBinary(kind: BotKind): string =
  ## Returns the executable path inside one bot image.
  case kind
  of NotTooDumb:
    "/bin/nottoodumb"
  of IVoteALot:
    "/bin/ivotewell"

proc parseBotKind(value: string): BotKind =
  ## Converts a form value or Docker label into a bot kind.
  case value.strip().toLowerAscii()
  of NotTooDumbBot:
    NotTooDumb
  of IVoteALotBot, "ivotewell":
    IVoteALot
  else:
    raise newException(GamesServerError, "unknown bot kind")

proc containerKindLabel(kind: ContainerKind): string =
  ## Returns the Docker label value for one container kind.
  case kind
  of LiveGame:
    LiveKind
  of ReplayServer:
    ReplayKind

proc parseContainerKind(value, name: string): ContainerKind =
  ## Converts Docker metadata into a container kind.
  let cleanValue = value.strip().toLowerAscii()
  if cleanValue == ReplayKind or name.startsWith("among_them_replay_"):
    return ReplayServer
  LiveGame

proc splitInspectLine(line: string): GameContainer =
  ## Converts one Docker inspect line to a game container row.
  let parts = line.split('\t')
  if parts.len >= 1:
    result.name = parts[0].strip(chars = {'/'})
  if parts.len >= 2:
    result.status = parts[1].strip()
  if parts.len >= 3:
    result.port = parseIntSafe(parts[2])
  if parts.len >= 4:
    result.created = parseInt64Safe(parts[3])
  if parts.len >= 5:
    result.replay = parts[4].strip()
  if parts.len >= 6:
    result.kind = parseContainerKind(parts[5], result.name)
  else:
    result.kind = parseContainerKind("", result.name)

proc inspectGame(name: string): GameContainer =
  ## Reads one managed container from Docker inspect.
  let safeName = cleanContainerName(name)
  if safeName.len == 0:
    raise newException(GamesServerError, "missing container name")
  let format =
    "{{.Name}}\t{{.State.Status}}\t" &
    "{{index .Config.Labels \"" & PortLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & CreatedLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & ReplayLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & KindLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & ServerLabelKey & "\"}}"
  let output = requireDocker(@["inspect", "--format", format, safeName])
  let parts = output.split('\t')
  if parts.len < 7 or parts[6].strip() != ServerLabelValue:
    raise newException(
      GamesServerError,
      "container is not managed by games_server"
    )
  result = splitInspectLine(output)

proc listGames(): seq[GameContainer] =
  ## Lists all containers created by this game server.
  let output = requireDocker(@[
    "ps",
    "-aq",
    "--filter",
    "label=" & ServerLabel
  ])
  for line in output.splitLines():
    let id = line.strip()
    if id.len == 0:
      continue
    try:
      result.add(inspectGame(id))
    except GamesServerError:
      discard

proc safeListGames(): seq[GameContainer] =
  ## Lists games for fallback error rendering.
  try:
    result = listGames()
  except GamesServerError:
    result = @[]

proc liveGames(containers: seq[GameContainer]): seq[GameContainer] =
  ## Filters managed containers down to live game servers.
  for container in containers:
    if container.kind == LiveGame:
      result.add(container)

proc replayServers(containers: seq[GameContainer]): seq[GameContainer] =
  ## Filters managed containers down to replay servers.
  for container in containers:
    if container.kind == ReplayServer:
      result.add(container)

proc splitBotLine(line: string): BotContainer =
  ## Converts one Docker inspect line to a bot container row.
  let parts = line.split('\t')
  if parts.len >= 1:
    result.name = parts[0].strip(chars = {'/'})
  if parts.len >= 2:
    result.status = parts[1].strip()
  if parts.len >= 3:
    result.game = parts[2].strip()
  if parts.len >= 4:
    result.bot = parseBotKind(parts[3])
  if parts.len >= 5:
    result.created = parseInt64Safe(parts[4])

proc inspectBot(name: string): BotContainer =
  ## Reads one managed bot container from Docker inspect.
  let safeName = cleanContainerName(name)
  if safeName.len == 0:
    raise newException(GamesServerError, "missing bot name")
  let format =
    "{{.Name}}\t{{.State.Status}}\t" &
    "{{index .Config.Labels \"" & BotGameLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & BotKindLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & CreatedLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & ServerLabelKey & "\"}}"
  let output = requireDocker(@["inspect", "--format", format, safeName])
  let parts = output.split('\t')
  if parts.len < 6 or parts[5].strip() != BotLabelValue:
    raise newException(
      GamesServerError,
      "container is not managed by games_server"
    )
  result = splitBotLine(output)

proc listBots(): seq[BotContainer] =
  ## Lists all bot containers created by this game server.
  let output = requireDocker(@[
    "ps",
    "-aq",
    "--filter",
    "label=" & BotLabel
  ])
  for line in output.splitLines():
    let id = line.strip()
    if id.len == 0:
      continue
    try:
      result.add(inspectBot(id))
    except GamesServerError:
      discard

proc safeListBots(): seq[BotContainer] =
  ## Lists bots for fallback rendering.
  try:
    result = listBots()
  except GamesServerError:
    result = @[]

proc botsForGame(
  bots: seq[BotContainer],
  gameName: string
): seq[BotContainer] =
  ## Filters bot containers down to one parent game.
  for bot in bots:
    if bot.game == gameName:
      result.add(bot)

proc managedContainerName(name: string): string =
  ## Validates that a container belongs to this game server.
  let safeName = cleanContainerName(name)
  if safeName.len == 0 or safeName != name:
    raise newException(GamesServerError, "invalid container name")
  try:
    discard inspectGame(safeName)
    return safeName
  except GamesServerError:
    discard
  try:
    discard inspectBot(safeName)
    return safeName
  except GamesServerError:
    discard
  raise newException(
    GamesServerError,
    "container is not managed by games_server"
  )

proc containerLogs(name: string): string =
  ## Reads current Docker logs for one managed container.
  requireDocker(@["logs", managedContainerName(name)])

proc cleanReplayName(value: string): string =
  ## Keeps only replay file name characters.
  for c in value:
    if c.isAlphaNumeric() or c == '_' or c == '-' or c == '.':
      result.add(c)
  if result.len > 128:
    result = result[0 .. 127]

proc replayPath(name: string): string =
  ## Returns the host path for one replay file.
  replayDir() / cleanReplayName(name)

proc replayFileFromPath(path: string): ReplayFile =
  ## Reads replay file metadata from disk.
  result.name = extractFilename(path)
  result.size = getFileSize(path).int64
  result.modified = getLastModificationTime(path).toUnix()

proc listReplays(): seq[ReplayFile] =
  ## Lists replay files saved by game containers.
  ensureReplayDir()
  for path in walkFiles(replayDir() / "*.bitreplay"):
    try:
      result.add(replayFileFromPath(path))
    except OSError:
      discard
  result.sort(proc(a, b: ReplayFile): int = cmp(b.modified, a.modified))

proc safeListReplays(): seq[ReplayFile] =
  ## Lists replays for fallback error rendering.
  try:
    result = listReplays()
  except GamesServerError:
    result = @[]

proc formValue(form: seq[(string, string)], key: string): string =
  ## Returns the first form value for a key.
  for (formKey, value) in form:
    if formKey == key:
      return value

proc findOpenPort(): int =
  ## Finds the first available game host port.
  for port in GamePortStart .. GamePortEnd:
    if portAvailable(port):
      return port
  raise newException(GamesServerError, "no free game ports are available")

proc gameName(port: int): string =
  ## Builds a unique Docker container name.
  "among_them_game_" & $port & "_" & $getTime().toUnix()

proc replayGameName(port: int): string =
  ## Builds a unique replay Docker container name.
  "among_them_replay_" & $port & "_" & $getTime().toUnix()

proc botContainerName(game: GameContainer, bot: BotKind): string =
  ## Builds a unique bot Docker container name.
  "among_them_bot_" & botKindLabel(bot) & "_" &
    $game.port & "_" & $getTime().toUnix()

proc botPlayerName(game: GameContainer, bot: BotKind): string =
  ## Builds a visible in-game name for one bot.
  botKindTitle(bot) & "-" & $game.port & "-" & $getTime().toUnix()

proc replayName(name: string): string =
  ## Builds the replay file name for one game.
  cleanContainerName(name) & ".bitreplay"

proc cleanConfigValue(
  form: seq[(string, string)],
  key: string,
  defaultValue,
  low,
  high: int
): int =
  ## Reads one integer form value with safe bounds.
  result = defaultValue
  for (formKey, value) in form:
    if formKey == key:
      result = parseIntSafe(value)
      break
  result = clampInt(result, low, high)

proc configJson(form: seq[(string, string)]): string =
  ## Builds the Among Them JSON config from form values.
  let
    minPlayers = cleanConfigValue(form, "minPlayers", 1, 1, 32)
    imposterCount = cleanConfigValue(form, "imposterCount", 0, 0, 8)
    tasksPerPlayer = cleanConfigValue(form, "tasksPerPlayer", 1, 0, 32)
    voteTimerTicks = cleanConfigValue(form, "voteTimerTicks", 360, 24, 7200)
  result =
    "{" &
    "\"minPlayers\":" & $minPlayers & "," &
    "\"imposterCount\":" & $imposterCount & "," &
    "\"tasksPerPlayer\":" & $tasksPerPlayer & "," &
    "\"voteTimerTicks\":" & $voteTimerTicks &
    "}"

proc baseDockerArgs(
  name: string,
  port: int,
  created: int64,
  replay: string,
  kind: ContainerKind,
  saveReplay: bool
): seq[string] =
  ## Builds Docker arguments common to every launch mode.
  result = @[
    "run",
    "-d",
    "--init",
    "--name",
    name,
    "-p",
    $port & ":2000",
    "--label",
    ServerLabel,
    "--label",
    PortLabel & "=" & $port,
    "--label",
    CreatedLabel & "=" & $created,
    "--label",
    ReplayLabel & "=" & replay,
    "--label",
    KindLabel & "=" & containerKindLabel(kind),
    "-v",
    replayDir() & ":" & ContainerReplayDir
  ]
  if saveReplay:
    result.add("-e")
    result.add(CogameReplayEnv & "=" & ContainerReplayDir / replay)

proc runnerScript(config: string, loadReplay: string): string =
  ## Builds the shell command for the local Nim runner image.
  result =
    "mkdir -p /tmp/bitworld-out /tmp/bitworld-nimcache && " &
    "nim r --nimcache:/tmp/bitworld-nimcache " &
    "--outdir:/tmp/bitworld-out among_them.nim " &
    "--address:0.0.0.0 --port:2000"
  if loadReplay.len > 0:
    result.add(" --load-replay:'" & ContainerReplayDir / loadReplay & "'")
  else:
    result.add(" --config:'" & config & "'")

proc dockerRunArgs(
  name: string,
  port: int,
  created: int64,
  replay: string,
  kind: ContainerKind,
  saveReplay: bool,
  loadReplay: string,
  config: string
): seq[string] =
  ## Builds Docker arguments for one new Among Them container.
  result = baseDockerArgs(name, port, created, replay, kind, saveReplay)
  case dockerMode()
  of "release":
    result.add(dockerImage())
    result.add("/bin/among_them")
    result.add("--address:0.0.0.0")
    result.add("--port:2000")
    if loadReplay.len > 0:
      result.add("--load-replay:" & ContainerReplayDir / loadReplay)
    else:
      result.add("--config:" & config)
  else:
    result.add("-v")
    result.add(workspaceRoot() & ":/workspace:ro")
    result.add("-w")
    result.add("/workspace/bitworld/among_them")
    result.add("-e")
    result.add("HOME=/tmp")
    result.add(dockerImage())
    result.add("sh")
    result.add("-lc")
    result.add(runnerScript(config, loadReplay))

proc botRunArgs(
  name: string,
  game: GameContainer,
  bot: BotKind,
  created: int64
): seq[string] =
  ## Builds Docker arguments for one bot container.
  result = @[
    "run",
    "-d",
    "--init",
    "--name",
    name,
    "--label",
    BotLabel,
    "--label",
    BotGameLabel & "=" & game.name,
    "--label",
    BotKindLabel & "=" & botKindLabel(bot),
    "--label",
    CreatedLabel & "=" & $created,
    botImage(bot),
    botBinary(bot),
    "--address:" & BotHost,
    "--port:" & $game.port,
    "--name:" & botPlayerName(game, bot)
  ]

proc createGame(form: seq[(string, string)]): GameContainer =
  ## Starts a new Among Them Docker container.
  ensureReplayDir()
  let
    port = findOpenPort()
    created = getTime().toUnix()
    name = gameName(port)
    replay = replayName(name)
    config = configJson(form)
  discard requireDocker(dockerRunArgs(
    name,
    port,
    created,
    replay,
    LiveGame,
    true,
    "",
    config
  ))
  result = inspectGame(name)

proc createReplayGame(replay: string): GameContainer =
  ## Starts an Among Them Docker container in replay mode.
  ensureReplayDir()
  let cleanReplay = cleanReplayName(replay)
  if cleanReplay.len == 0 or cleanReplay != replay:
    raise newException(GamesServerError, "invalid replay file name")
  if not fileExists(replayPath(cleanReplay)):
    raise newException(GamesServerError, "replay file does not exist")
  let
    port = findOpenPort()
    created = getTime().toUnix()
    name = replayGameName(port)
  discard requireDocker(dockerRunArgs(
    name,
    port,
    created,
    cleanReplay,
    ReplayServer,
    false,
    cleanReplay,
    ""
  ))
  result = inspectGame(name)

proc stopBotsForGame(gameName: string) =
  ## Stops running bot containers attached to one game.
  for bot in botsForGame(safeListBots(), gameName):
    if bot.status == "running":
      discard requireDocker(@["stop", bot.name])

proc stopBot(name: string) =
  ## Stops one running managed bot container.
  let bot = inspectBot(name)
  if bot.status == "running":
    discard requireDocker(@["stop", bot.name])

proc stopGame(name: string) =
  ## Stops a running managed game container.
  let game = inspectGame(name)
  stopBotsForGame(game.name)
  if game.status == "running":
    discard requireDocker(@["stop", game.name])

proc parseFormBody(request: Request): seq[(string, string)] =
  ## Parses an application/x-www-form-urlencoded request body.
  parseUrlPairs(request.body)

proc queryValue(request: Request, key: string): string =
  ## Reads one query string value.
  let queryStart = request.uri.find('?')
  if queryStart < 0 or queryStart + 1 >= request.uri.len:
    return
  for (queryKey, value) in parseUrlPairs(request.uri[queryStart + 1 .. ^1]):
    if queryKey == key:
      return value

proc hostName(request: Request): string =
  ## Extracts the browser-visible host without a port.
  let raw = request.headers["Host"].strip()
  if raw.len == 0:
    return "localhost"
  if raw[0] == '[':
    let endAt = raw.find(']')
    if endAt > 0:
      return raw[0 .. endAt]
  let colon = raw.find(':')
  if colon > 0:
    return raw[0 ..< colon]
  raw

proc gameUrl(request: Request, game: GameContainer, page: string): string =
  ## Builds a browser URL for a game client page.
  "http://" & request.hostName() & ":" & $game.port & "/client/" & page

proc healthUrl(game: GameContainer): string =
  ## Builds the local health URL for one game container.
  "http://127.0.0.1:" & $game.port & HealthPath

proc gameHealthy(game: GameContainer): bool =
  ## Returns true when the game's health endpoint answers healthy.
  if game.status != "running" or game.port <= 0:
    return false
  var client = newHttpClient(timeout = 500)
  try:
    result = client.getContent(healthUrl(game)).strip() == "healthy"
  except CatchableError:
    result = false
  finally:
    client.close()

proc waitForHealth(game: GameContainer): bool =
  ## Waits briefly for a newly started game to become healthy.
  let deadline = epochTime() + 45.0
  while epochTime() < deadline:
    if gameHealthy(game):
      return true
    sleep(250)

proc createBot(gameName: string, bot: BotKind): BotContainer =
  ## Starts one bot Docker container for a live game.
  let game = inspectGame(gameName)
  if game.kind != LiveGame:
    raise newException(GamesServerError, "bots can only join live games")
  if not gameHealthy(game):
    raise newException(GamesServerError, "game is not healthy yet")
  let
    created = getTime().toUnix()
    name = botContainerName(game, bot)
  discard requireDocker(botRunArgs(name, game, bot, created))
  result = inspectBot(name)

proc fmtCreated(created: int64): string =
  ## Formats a Unix timestamp for display.
  if created <= 0:
    return "unknown"
  fromUnix(created).utc().format("yyyy-MM-dd HH:mm:ss") & " UTC"

proc fmtBytes(size: int64): string =
  ## Formats a byte count for display.
  if size < 1024:
    return $size & " B"
  if size < 1024 * 1024:
    return $(size div 1024) & " KB"
  $(size div (1024 * 1024)) & " MB"

proc renderCreateForm(): string =
  ## Renders the compact create-game form.
  renderFragment:
    table:
      tr:
        td ".cat":
          colspan "2"
          say "Create new game"
      tr:
        td ".row1":
          form:
            action "/games/create"
            tmethod "post"
            span ".small":
              say "min players "
            input ".input":
              ttype "number"
              name "minPlayers"
              value "1"
              min "1"
              max "32"
            say " "
            span ".small":
              say "imposters "
            input ".input":
              ttype "number"
              name "imposterCount"
              value "0"
              min "0"
              max "8"
            say " "
            span ".small":
              say "tasks "
            input ".input":
              ttype "number"
              name "tasksPerPlayer"
              value "1"
              min "0"
              max "32"
            say " "
            span ".small":
              say "vote ticks "
            input ".input":
              ttype "number"
              name "voteTimerTicks"
              value "360"
              min "24"
              max "7200"
            say " "
            button ".button":
              ttype "submit"
              say "Create"
        td ".row2 small":
          say "Image: " & esc(dockerImage()) & " | Mode: " & esc(dockerMode())

proc renderGamesTable(
  request: Request,
  games: seq[GameContainer],
  bots: seq[BotContainer]
): string =
  ## Renders the active and stopped game list.
  renderFragment:
    table:
      tr:
        th ".head":
          say "Game"
        th ".head":
          say "Status"
        th ".head":
          say "Port"
        th ".head":
          say "Join"
        th ".head":
          say "Replay"
        th ".head":
          say "Bots"
        th ".head":
          say "Created"
        th ".head":
          say "Control"
        th ".head":
          say "Logs"
      if games.len == 0:
        tr:
          td ".row1 center":
            colspan "9"
            say "No games created yet."
      for i, game in games:
        let
          rowClass = if i mod 2 == 0: ".row1" else: ".row2"
          healthy = gameHealthy(game)
          gameBots = botsForGame(bots, game.name)
        tr:
          td rowClass:
            say esc(game.name)
          td rowClass & " nowrap":
            say esc(game.status)
          td rowClass & " center":
            if game.port > 0:
              say $game.port
            else:
              say "-"
          td rowClass & " nowrap":
            if healthy:
              a:
                href gameUrl(request, game, "global.html")
                target "_blank"
                say "global"
              say " | "
              a:
                href gameUrl(request, game, "player.html")
                target "_blank"
                say "player"
            elif game.status == "running":
              say "starting"
            else:
              say "offline"
          td rowClass & " nowrap":
            if game.replay.len > 0:
              form:
                action ReplayPlayPath
                tmethod "post"
                target "_blank"
                input:
                  ttype "hidden"
                  name "name"
                  value game.replay
                button ".button":
                  ttype "submit"
                  say "play"
            else:
              say "-"
          td rowClass & " nowrap":
            if healthy:
              form:
                action "/games/bot"
                tmethod "post"
                input:
                  ttype "hidden"
                  name "name"
                  value game.name
                select:
                  name "bot"
                  option:
                    value botKindLabel(NotTooDumb)
                    say botKindTitle(NotTooDumb)
                  option:
                    value botKindLabel(IVoteALot)
                    say botKindTitle(IVoteALot)
                say " "
                button ".button":
                  ttype "submit"
                  say "Add bot"
            elif game.status == "running":
              say "wait"
            elif gameBots.len == 0:
              say "-"
            else:
              say ""
          td rowClass & " nowrap":
            say fmtCreated(game.created)
          td rowClass & " center":
            if game.status == "running":
              form:
                action "/games/stop"
                tmethod "post"
                input:
                  ttype "hidden"
                  name "name"
                  value game.name
                button ".button":
                  ttype "submit"
                  say "Stop"
            else:
              say "Stopped"
          td rowClass & " center":
            a:
              href logUrl(game.name)
              target "_blank"
              say "logs"
        for bot in gameBots:
          tr:
            td rowClass:
              say ""
            td rowClass & " nowrap":
              say esc(bot.status)
            td rowClass:
              say ""
            td rowClass:
              say ""
            td rowClass:
              say ""
            td rowClass & " nowrap":
              say esc(bot.name)
            td rowClass & " nowrap":
              say fmtCreated(bot.created)
            td rowClass & " center":
              if bot.status == "running":
                form:
                  action "/games/bot/stop"
                  tmethod "post"
                  input:
                    ttype "hidden"
                    name "name"
                    value bot.name
                  button ".button":
                    ttype "submit"
                    say "Stop"
              else:
                say "Stopped"
            td rowClass & " center":
              a:
                href logUrl(bot.name)
                target "_blank"
                say "logs"

proc renderReplayServersTable(
  request: Request,
  servers: seq[GameContainer]
): string =
  ## Renders replay playback containers.
  renderFragment:
    table:
      tr:
        th ".head":
          say "Replay server"
        th ".head":
          say "Status"
        th ".head":
          say "Port"
        th ".head":
          say "Viewer"
        th ".head":
          say "Replay"
        th ".head":
          say "Created"
        th ".head":
          say "Control"
        th ".head":
          say "Logs"
      if servers.len == 0:
        tr:
          td ".row1 center":
            colspan "8"
            say "No replay servers started yet."
      for i, server in servers:
        let
          rowClass = if i mod 2 == 0: ".row1" else: ".row2"
          healthy = gameHealthy(server)
        tr:
          td rowClass:
            say esc(server.name)
          td rowClass & " nowrap":
            say esc(server.status)
          td rowClass & " center":
            if server.port > 0:
              say $server.port
            else:
              say "-"
          td rowClass & " nowrap":
            if healthy:
              a:
                href gameUrl(request, server, "global.html")
                target "_blank"
                say "global"
            elif server.status == "running":
              say "starting"
            else:
              say "offline"
          td rowClass:
            if server.replay.len > 0:
              say esc(server.replay)
            else:
              say "-"
          td rowClass & " nowrap":
            say fmtCreated(server.created)
          td rowClass & " center":
            if server.status == "running":
              form:
                action "/games/stop"
                tmethod "post"
                input:
                  ttype "hidden"
                  name "name"
                  value server.name
                button ".button":
                  ttype "submit"
                  say "Stop"
            else:
              say "Stopped"
          td rowClass & " center":
            a:
              href logUrl(server.name)
              target "_blank"
              say "logs"

proc renderReplaysTable(replays: seq[ReplayFile]): string =
  ## Renders the saved replay file list.
  renderFragment:
    table:
      tr:
        th ".head":
          say "Replay"
        th ".head":
          say "Size"
        th ".head":
          say "Modified"
        th ".head":
          say "Play"
      if replays.len == 0:
        tr:
          td ".row1 center":
            colspan "4"
            say "No replay files saved yet."
      for i, replay in replays:
        let rowClass = if i mod 2 == 0: ".row1" else: ".row2"
        tr:
          td rowClass:
            say esc(replay.name)
          td rowClass & " right nowrap":
            say fmtBytes(replay.size)
          td rowClass & " nowrap":
            say fmtCreated(replay.modified)
          td rowClass & " nowrap":
            form:
              action ReplayPlayPath
              tmethod "post"
              target "_blank"
              input:
                ttype "hidden"
                name "name"
                value replay.name
              button ".button":
                ttype "submit"
                say "Open global"

proc renderPage(
  request: Request,
  games: seq[GameContainer],
  replayServers: seq[GameContainer],
  bots: seq[BotContainer],
  replays: seq[ReplayFile],
  notice = ""
): string =
  ## Renders the full games server page.
  let
    createForm = renderCreateForm()
    gamesTable = renderGamesTable(request, games, bots)
    replayServersTable = renderReplayServersTable(request, replayServers)
    replaysTable = renderReplaysTable(replays)
  render:
    html:
      head:
        title:
          say "Bitworld Games Server"
        say "<style>"
        say PageCss
        say "</style>"
      body:
        tdiv ".page":
          table:
            tr:
              td ".row2":
                h1 ".title":
                  say "Bitworld Games Server"
                p ".small":
                  say "Among Them containers, old board style."
              td ".row2 right small":
                a:
                  href "/"
                  say "Refresh"
          if notice.len > 0:
            p ".notice small":
              b:
                say esc(notice)
          say createForm
          p ".small":
            say " "
          table:
            tr:
              td ".cat":
                say "Games"
          say gamesTable
          p ".small":
            say " "
          table:
            tr:
              td ".cat":
                say "Replay servers"
          say replayServersTable
          p ".small":
            say " "
          table:
            tr:
              td ".cat":
                say "Replays"
          say replaysTable
          p ".footer small":
            say "Docker label: " & ServerLabel & ". Ports: " &
              $GamePortStart & "-" & $GamePortEnd & "."

proc renderLogsPage(name, logText: string): string =
  ## Renders current Docker logs for one container.
  let cleanLog =
    if logText.len == 0:
      "(no logs yet)"
    else:
      logText
  render:
    html:
      head:
        title:
          say "Logs: " & esc(name)
        say "<style>"
        say PageCss
        say "</style>"
      body:
        tdiv ".page":
          table:
            tr:
              td ".row2":
                h1 ".title":
                  say "Logs"
                p ".small":
                  say esc(name)
              td ".row2 right small":
                a:
                  href logUrl(name)
                  say "Refresh"
                say " | "
                a:
                  href "/"
                  say "Back"
          p ".small":
            say " "
          pre ".logs":
            say esc(cleanLog)

proc htmlHeaders(): HttpHeaders =
  ## Builds standard HTML response headers.
  result["Content-Type"] = "text/html; charset=utf-8"
  result["Cache-Control"] = "no-cache"

proc redirectHeaders(location: string): HttpHeaders =
  ## Builds redirect headers.
  result = htmlHeaders()
  result["Location"] = location

proc respondHtml(request: Request, status: int, body: string) =
  ## Sends an HTML response.
  request.respond(status, htmlHeaders(), body)

proc respondRedirect(request: Request, location: string) =
  ## Sends a redirect response.
  request.respond(303, redirectHeaders(location), "")

proc respondReplayNotFound(request: Request) =
  ## Sends a replay missing page.
  let containers = safeListGames()
  request.respondHtml(404, renderPage(
    request,
    liveGames(containers),
    replayServers(containers),
    safeListBots(),
    safeListReplays(),
    "replay not found"
  ))

proc respondPlayReplay(request: Request, rawName: string) =
  ## Starts a replay container and redirects to its global viewer.
  let name = cleanReplayName(rawName)
  if name.len == 0 or name != rawName:
    request.respondReplayNotFound()
    return
  if not fileExists(replayPath(name)):
    request.respondReplayNotFound()
    return
  let game = createReplayGame(name)
  if waitForHealth(game):
    request.respondRedirect(gameUrl(request, game, "global.html"))
  else:
    request.respondRedirect("/?notice=started+" & game.name)

proc replayPathHandler(request: Request) =
  ## Redirects old replay GET paths without starting containers.
  request.respondRedirect("/?notice=use+the+play+button")

proc replayPlayHandler(request: Request) =
  ## Handles replay play form submissions.
  let name = formValue(parseFormBody(request), "name")
  if name.len == 0:
    request.respondReplayNotFound()
    return
  request.respondPlayReplay(name)

proc respondIndex(request: Request, notice = "") =
  ## Sends the index page.
  let
    containers = listGames()
    bots = listBots()
    replays = listReplays()
  request.respondHtml(200, renderPage(
    request,
    liveGames(containers),
    replayServers(containers),
    bots,
    replays,
    notice
  ))

proc indexHandler(request: Request) =
  ## Handles the index route.
  request.respondIndex(queryValue(request, "notice"))

proc createHandler(request: Request) =
  ## Handles create-game requests.
  let game = createGame(parseFormBody(request))
  request.respondRedirect("/?notice=created+" & game.name)

proc stopHandler(request: Request) =
  ## Handles stop-game requests.
  let form = parseFormBody(request)
  var name = ""
  for (key, value) in form:
    if key == "name":
      name = value
      break
  stopGame(name)
  request.respondRedirect("/?notice=stopped+" & cleanContainerName(name))

proc botHandler(request: Request) =
  ## Handles add-bot requests.
  let form = parseFormBody(request)
  let
    name = formValue(form, "name")
    bot = parseBotKind(formValue(form, "bot"))
    container = createBot(name, bot)
  request.respondRedirect("/?notice=started+" & container.name)

proc stopBotHandler(request: Request) =
  ## Handles stop-bot requests.
  let name = formValue(parseFormBody(request), "name")
  stopBot(name)
  request.respondRedirect("/?notice=stopped+" & cleanContainerName(name))

proc logsHandler(request: Request) =
  ## Handles Docker log viewer requests.
  let name = queryValue(request, "name")
  if name.len == 0:
    raise newException(GamesServerError, "missing container name")
  request.respondHtml(200, renderLogsPage(name, containerLogs(name)))

proc notFoundHandler(request: Request) =
  ## Handles unknown routes.
  let containers = safeListGames()
  request.respondHtml(
    404,
    renderPage(
      request,
      liveGames(containers),
      replayServers(containers),
      safeListBots(),
      safeListReplays(),
      "not found"
    )
  )

proc errorHandler(request: Request, e: ref Exception) =
  ## Handles expected and unexpected server errors.
  stderr.writeLine("[games_server] ", e.msg)
  let containers = safeListGames()
  request.respondHtml(
    500,
    renderPage(
      request,
      liveGames(containers),
      replayServers(containers),
      safeListBots(),
      safeListReplays(),
      e.msg
    )
  )

proc httpHandler(request: Request) =
  ## Routes all HTTP requests.
  try:
    if request.path == "/" and request.httpMethod == "GET":
      request.indexHandler()
    elif request.path == LogsPath and request.httpMethod == "GET":
      request.logsHandler()
    elif request.path == "/games/create" and request.httpMethod == "POST":
      request.createHandler()
    elif request.path == "/games/bot" and request.httpMethod == "POST":
      request.botHandler()
    elif request.path == "/games/bot/stop" and request.httpMethod == "POST":
      request.stopBotHandler()
    elif request.path == "/games/stop" and request.httpMethod == "POST":
      request.stopHandler()
    elif request.path == ReplayPlayPath and request.httpMethod == "POST":
      request.replayPlayHandler()
    elif request.path.startsWith(ReplayPathPrefix) and
        request.httpMethod == "GET":
      request.replayPathHandler()
    else:
      request.notFoundHandler()
  except GamesServerError as e:
    request.errorHandler(e)
  except Exception as e:
    request.errorHandler(e)

proc runServer(address = DefaultHost, port = DefaultPort) =
  ## Runs the games control web server.
  let server = newServer(httpHandler, workerThreads = 4)
  echo "Games server listening on http://", address, ":", port
  server.serve(Port(port), address)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = val
      of "port":
        port = parseInt(val)
      else:
        discard
    else:
      discard
  runServer(address, port)

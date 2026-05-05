import
  std/[
    algorithm, json, net, os, osproc, parseopt, strutils, times
  ],
  mummy,
  taggy

from std/httpclient import close, getContent, newHttpClient

const
  DefaultHost = "0.0.0.0"
  DefaultPort = 2080
  MaxBotLaunchCount = 16
  DockerBinEnv = "GAMES_SERVER_DOCKER"
  DockerImageEnv = "GAMES_SERVER_IMAGE"
  DockerModeEnv = "GAMES_SERVER_MODE"
  ReplayDirEnv = "GAMES_SERVER_REPLAY_DIR"
  WorkspaceRootEnv = "GAMES_SERVER_WORKSPACE_ROOT"
  NotTooDumbImageEnv = "GAMES_SERVER_NOTTOODUMB_IMAGE"
  IVoteALotImageEnv = "GAMES_SERVER_IVOTEALOT_IMAGE"
  ITalkALotImageEnv = "GAMES_SERVER_ITALKALOT_IMAGE"
  DefaultDockerImage = "ghcr.io/treeform/bitworld-among-them-runner:latest"
  DefaultDockerMode = "release"
  DefaultNotTooDumbImage = "ghcr.io/treeform/bitworld-nottoodumb:latest"
  DefaultIVoteALotImage = "ghcr.io/treeform/bitworld-ivotewell:latest"
  DefaultITalkALotImage = "ghcr.io/treeform/bitworld-italkalot:latest"
  ContainerReplayDir = "/replays"
  ReplayPathPrefix = "/replays/"
  ReplayPlayPath = "/replays/play"
  ScoresPath = "/scores"
  LogsPath = "/logs"
  HealthPath = "/healthz"
  ClientPath = "/client/"
  CreatePath = "/games/create"
  CogameReplayEnv = "COGAME_SAVE_REPLAY_PATH"
  CogameResultsEnv = "COGAME_RESULTS_PATH"
  ManifestPathEnv = "GAMES_SERVER_MANIFEST"
  AiKeyEnvNames = ["CLAUDE_KEY", "GEMINI_KEY", "OPENAI_KEY", "XAI_KEY"]
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
  ITalkALotBot = "italkalot"
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
.textInput {
  width: 220px;
  border: 1px solid #707096;
  font: 11px Verdana, Helvetica, Arial, sans-serif;
}
.textarea {
  width: min(620px, calc(100vw - 96px));
  height: 68px;
  border: 1px solid #707096;
  font: 11px Monaco, Consolas, monospace;
}
.fieldName {
  width: 180px;
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
    ITalkALot

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

  ScoreRow = object
    name: string
    score: string
    win: bool
    tasks: string
    kills: string

var
  aiKeyEnvMask = 0

proc loadAiKeyEnvs() =
  ## Loads AI key environment names once at server startup.
  aiKeyEnvMask = 0
  var names: seq[string]
  for i, name in AiKeyEnvNames:
    if getEnv(name).len > 0:
      aiKeyEnvMask = aiKeyEnvMask or (1 shl i)
      names.add(name)
  if names.len > 0:
    echo "AI env keys loaded: ", names.join(", ")
  else:
    echo "AI env keys loaded: none"

proc addAiEnvArgs(args: var seq[string]) =
  ## Adds Docker env forwarding args for configured AI keys.
  for i, name in AiKeyEnvNames:
    if (aiKeyEnvMask and (1 shl i)) != 0:
      args.add("-e")
      args.add(name)

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

proc encodeUrlComponent(value: string): string =
  ## Encodes a string for use as one URL query value.
  for c in value:
    case c
    of 'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_', '.', '~':
      result.add(c)
    else:
      result.add('%')
      result.add(ord(c).toHex(2))

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
  of ITalkALot:
    envValue(ITalkALotImageEnv, DefaultITalkALotImage)

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

proc defaultManifestPath(): string =
  ## Returns the default Among Them manifest path.
  parentDir(parentDir(currentSourcePath())) /
    "among_them" / "cogame_manifest.json"

proc manifestPath(): string =
  ## Returns the configured Among Them manifest path.
  envValue(ManifestPathEnv, defaultManifestPath())

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

proc pullDockerImage(image: string) =
  ## Pulls the latest version of one Docker image.
  discard requireDocker(@["pull", image])

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
  of ITalkALot:
    ITalkALotBot

proc botKindTitle(kind: BotKind): string =
  ## Returns the display label for one bot kind.
  case kind
  of NotTooDumb:
    "nottoodumb"
  of IVoteALot:
    "ivotealot"
  of ITalkALot:
    "italkalot"

proc botBinary(kind: BotKind): string =
  ## Returns the executable path inside one bot image.
  case kind
  of NotTooDumb:
    "/bin/nottoodumb"
  of IVoteALot:
    "/bin/ivotewell"
  of ITalkALot:
    "/bin/italkalot"

proc parseBotKind(value: string): BotKind =
  ## Converts a form value or Docker label into a bot kind.
  case value.strip().toLowerAscii()
  of NotTooDumbBot:
    NotTooDumb
  of IVoteALotBot, "ivotewell":
    IVoteALot
  of ITalkALotBot:
    ITalkALot
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

proc containerLogState(name: string): string =
  ## Reads current Docker state for one managed container.
  let safeName = managedContainerName(name)
  let format =
    "status={{.State.Status}}\n" &
    "exit={{.State.ExitCode}}\n" &
    "oom={{.State.OOMKilled}}\n" &
    "error={{.State.Error}}\n" &
    "started={{.State.StartedAt}}\n" &
    "finished={{.State.FinishedAt}}"
  requireDocker(@["inspect", "--format", format, safeName])

proc containerLogs(name: string): string =
  ## Reads current Docker stdout and stderr logs for one managed container.
  let safeName = managedContainerName(name)
  containerLogState(safeName) &
    "\n\n--- docker logs stdout and stderr ---\n" &
    requireDocker(@["logs", "--timestamps", safeName])

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

proc botCountField(bot: BotKind): string =
  ## Returns the create-form count field for one bot kind.
  botKindLabel(bot) & "Bots"

proc findOpenPort(): int =
  ## Asks the OS to reserve and report one free host port.
  var socket = newSocket()
  try:
    socket.setSockOpt(OptReuseAddr, true)
    socket.bindAddr(Port(0), "0.0.0.0")
    let (_, port) = socket.getLocalAddr()
    result = port.int
  except OSError as e:
    raise newException(
      GamesServerError,
      "could not ask OS for a free port: " & e.msg
    )
  finally:
    socket.close()
  if result <= 0:
    raise newException(GamesServerError, "OS returned an invalid free port")

proc gameName(port: int): string =
  ## Builds a unique Docker container name.
  "among_them_game_" & $port & "_" & $getTime().toUnix()

proc replayGameName(port: int): string =
  ## Builds a unique replay Docker container name.
  "among_them_replay_" & $port & "_" & $getTime().toUnix()

proc launchStamp(index: int): string =
  ## Builds a compact unique suffix for batch launches.
  $(int64(epochTime() * 1000)) & "_" & $index

proc botContainerName(
  game: GameContainer,
  bot: BotKind,
  stamp: string
): string =
  ## Builds a unique bot Docker container name.
  "among_them_bot_" & botKindLabel(bot) & "_" &
    $game.port & "_" & stamp

proc botPlayerName(
  game: GameContainer,
  bot: BotKind,
  stamp: string
): string =
  ## Builds a visible in-game name for one bot.
  botKindTitle(bot) & "-" & $game.port & "-" & stamp

proc replayName(name: string): string =
  ## Builds the replay file name for one game.
  cleanContainerName(name) & ".bitreplay"

proc scoresName(replay: string): string =
  ## Builds the scores file name for one replay file.
  if replay.endsWith(".bitreplay"):
    replay[0 ..< replay.len - ".bitreplay".len] & ".scores.json"
  else:
    replay & ".scores.json"

proc scoreFileName(replay: string): string =
  ## Builds the clean scores file name for one replay file.
  cleanReplayName(scoresName(replay))

proc scoreFileExists(replay: string): bool =
  ## Returns true when the score file for a replay exists.
  fileExists(replayPath(scoreFileName(replay)))

proc scoreUrl(replay: string): string =
  ## Builds a browser URL for one scores file.
  ScoresPath & "?name=" & scoreFileName(replay)

proc rawScoreUrl(name: string): string =
  ## Builds a browser URL for one raw scores file.
  ScoresPath & "?name=" & cleanReplayName(name) & "&raw=1"

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

proc createBotCounts(
  form: seq[(string, string)]
): array[BotKind, int] =
  ## Reads create-form bot counts.
  var total = 0
  for bot in low(BotKind) .. high(BotKind):
    result[bot] = cleanConfigValue(
      form,
      botCountField(bot),
      0,
      0,
      MaxBotLaunchCount
    )
    total += result[bot]
  if total > MaxBotLaunchCount:
    raise newException(
      GamesServerError,
      "cannot start more than " & $MaxBotLaunchCount & " bots"
    )

proc configSchema(): JsonNode =
  ## Reads the config schema from the Among Them manifest.
  try:
    let manifest = parseJson(readFile(manifestPath()))
    if manifest.kind != JObject or not manifest.hasKey("config_schema"):
      raise newException(GamesServerError, "manifest missing config_schema")
    result = manifest["config_schema"]
    if result.kind != JObject or not result.hasKey("properties") or
        result["properties"].kind != JObject:
      raise newException(
        GamesServerError,
        "manifest config_schema missing properties"
      )
  except GamesServerError:
    raise
  except CatchableError as e:
    raise newException(
      GamesServerError,
      "could not read manifest config schema: " & e.msg
    )

proc propertyString(
  property: JsonNode,
  key,
  defaultValue: string
): string =
  ## Reads one string value from a JSON schema property.
  if property.kind == JObject and property.hasKey(key) and
      property[key].kind == JString:
    return property[key].getStr()
  defaultValue

proc propertyInt(
  property: JsonNode,
  key: string,
  defaultValue: int
): int =
  ## Reads one integer value from a JSON schema property.
  if property.kind == JObject and property.hasKey(key) and
      property[key].kind == JInt:
    return property[key].getInt()
  defaultValue

proc hasPropertyInt(property: JsonNode, key: string): bool =
  ## Returns true when a JSON schema property has an integer value.
  property.kind == JObject and property.hasKey(key) and
    property[key].kind == JInt

proc propertyBool(
  property: JsonNode,
  key: string,
  defaultValue: bool
): bool =
  ## Reads one boolean value from a JSON schema property.
  if property.kind == JObject and property.hasKey(key) and
      property[key].kind == JBool:
    return property[key].getBool()
  defaultValue

proc propertyType(property: JsonNode): string =
  ## Returns the JSON schema type for one property.
  property.propertyString("type", "string")

proc itemType(property: JsonNode): string =
  ## Returns the JSON schema item type for one array property.
  if property.kind == JObject and property.hasKey("items") and
      property["items"].kind == JObject:
    return property["items"].propertyString("type", "")
  ""

proc defaultText(property: JsonNode): string =
  ## Returns the schema default value as form text.
  if property.kind != JObject or not property.hasKey("default"):
    return
  let value = property["default"]
  case value.kind
  of JString:
    result = value.getStr()
  of JInt:
    result = $value.getInt()
  of JFloat:
    result = $value.getFloat()
  of JBool:
    result =
      if value.getBool():
        "true"
      else:
        "false"
  of JArray, JObject:
    result = $value
  of JNull:
    result = ""

proc fieldLabel(name: string): string =
  ## Converts one camelCase config key into a compact label.
  for i, c in name:
    if c in {'A' .. 'Z'}:
      if i > 0:
        result.add(' ')
      result.add(c.toLowerAscii())
    else:
      result.add(c)

proc checkArrayBounds(
  name: string,
  items,
  property: JsonNode
) =
  ## Raises when an array config value is outside schema bounds.
  if hasPropertyInt(property, "minItems") and
      items.len < property.propertyInt("minItems", 0):
    raise newException(
      GamesServerError,
      "Config field " & name & " needs at least " &
        $property.propertyInt("minItems", 0) & " entries."
    )
  if hasPropertyInt(property, "maxItems") and
      items.len > property.propertyInt("maxItems", 0):
    raise newException(
      GamesServerError,
      "Config field " & name & " cannot have more than " &
        $property.propertyInt("maxItems", 0) & " entries."
    )

proc parseStringArray(
  name,
  text: string,
  property: JsonNode
): JsonNode =
  ## Parses a string array from JSON, commas, or lines.
  result = newJArray()
  let cleanText = text.strip()
  if cleanText.len == 0:
    checkArrayBounds(name, result, property)
    return
  if cleanText[0] == '[':
    try:
      result = parseJson(cleanText)
    except CatchableError as e:
      raise newException(
        GamesServerError,
        "Config field " & name & " could not parse as JSON: " & e.msg
      )
    if result.kind != JArray:
      raise newException(
        GamesServerError,
        "Config field " & name & " must be an array."
      )
    for i, item in result.elems:
      if item.kind != JString:
        raise newException(
          GamesServerError,
          "Config field " & name & "[" & $i & "] must be a string."
        )
    checkArrayBounds(name, result, property)
    return
  for line in cleanText.splitLines():
    for part in line.split(','):
      let item = part.strip()
      if item.len > 0:
        result.add(%item)
  checkArrayBounds(name, result, property)

proc parseJsonArray(
  name,
  text: string,
  property: JsonNode
): JsonNode =
  ## Parses a JSON array config field.
  let cleanText = text.strip()
  if cleanText.len == 0:
    result = newJArray()
    checkArrayBounds(name, result, property)
    return
  try:
    result = parseJson(cleanText)
  except CatchableError as e:
    raise newException(
      GamesServerError,
      "Config field " & name & " could not parse as JSON: " & e.msg
    )
  if result.kind != JArray:
    raise newException(
      GamesServerError,
      "Config field " & name & " must be a JSON array."
    )
  checkArrayBounds(name, result, property)

proc intConfigValue(
  form: seq[(string, string)],
  name: string,
  property: JsonNode
): int =
  ## Reads one integer config value from a form.
  result = property.propertyInt("default", 0)
  let value = formValue(form, name).strip()
  if value.len > 0:
    result = parseIntSafe(value)
  if hasPropertyInt(property, "minimum") and
      result < property.propertyInt("minimum", 0):
    result = property.propertyInt("minimum", 0)
  if hasPropertyInt(property, "maximum") and
      result > property.propertyInt("maximum", 0):
    result = property.propertyInt("maximum", 0)

proc boolConfigValue(
  form: seq[(string, string)],
  name: string,
  property: JsonNode
): bool =
  ## Reads one boolean config value from a form.
  let value = formValue(form, name).strip().toLowerAscii()
  if value.len == 0:
    return property.propertyBool("default", false)
  value in ["true", "1", "yes", "on"]

proc stringConfigValue(
  form: seq[(string, string)],
  name: string,
  property: JsonNode
): string =
  ## Reads one string config value from a form.
  result = property.defaultText()
  let value = formValue(form, name)
  if value.len > 0:
    result = value.strip()

proc scoreArray(node: JsonNode, key: string): JsonNode =
  ## Reads one required scores array.
  if node.kind != JObject or not node.hasKey(key) or
      node[key].kind != JArray:
    raise newException(
      GamesServerError,
      "scores file missing " & key & " array"
    )
  node[key]

proc scoreString(items: JsonNode, index: int): string =
  ## Reads one score table string cell.
  if index >= items.len:
    return ""
  let item = items[index]
  case item.kind
  of JString:
    result = item.getStr()
  of JInt:
    result = $item.getInt()
  of JFloat:
    result = $item.getFloat()
  of JBool:
    result =
      if item.getBool():
        "true"
      else:
        "false"
  else:
    result = ""

proc scoreBool(items: JsonNode, index: int): bool =
  ## Reads one score table boolean cell.
  if index < items.len and items[index].kind == JBool:
    return items[index].getBool()

proc maxScoreRows(
  names,
  scores,
  wins,
  tasks,
  kills: JsonNode
): int =
  ## Returns the longest score array length.
  max(
    max(names.len, scores.len),
    max(max(wins.len, tasks.len), kills.len)
  )

proc parseScoreRows(text: string): seq[ScoreRow] =
  ## Parses saved score JSON into table rows.
  let node = parseJson(text)
  let
    names = node.scoreArray("names")
    scores = node.scoreArray("scores")
    wins = node.scoreArray("win")
    tasks = node.scoreArray("tasks")
    kills = node.scoreArray("kills")
    rowCount = maxScoreRows(names, scores, wins, tasks, kills)
  for i in 0 ..< rowCount:
    result.add(ScoreRow(
      name: names.scoreString(i),
      score: scores.scoreString(i),
      win: wins.scoreBool(i),
      tasks: tasks.scoreString(i),
      kills: kills.scoreString(i)
    ))

proc configJson(form: seq[(string, string)]): string =
  ## Builds the Among Them JSON config from form values.
  let schema = configSchema()
  var node = newJObject()
  for name, property in schema["properties"].pairs:
    let value = formValue(form, name).strip()
    if name == "tokens" and (value.len == 0 or value == "[]"):
      continue
    case property.propertyType()
    of "integer":
      node[name] = %intConfigValue(form, name, property)
    of "boolean":
      node[name] = %boolConfigValue(form, name, property)
    of "array":
      if property.itemType() == "string":
        node[name] = parseStringArray(
          name,
          formValue(form, name),
          property
        )
      else:
        node[name] = parseJsonArray(
          name,
          formValue(form, name),
          property
        )
    else:
      node[name] = %stringConfigValue(form, name, property)
  $node

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
    let scores = ContainerReplayDir / scoresName(replay)
    result.add("-e")
    result.add(CogameReplayEnv & "=" & ContainerReplayDir / replay)
    result.add("-e")
    result.add(CogameResultsEnv & "=" & scores)
  addAiEnvArgs(result)

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
  created: int64,
  stamp: string
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
    CreatedLabel & "=" & $created
  ]
  addAiEnvArgs(result)
  result.add(botImage(bot))
  result.add(botBinary(bot))
  result.add("--address:" & BotHost)
  result.add("--port:" & $game.port)
  result.add("--name:" & botPlayerName(game, bot, stamp))

proc pullNeededBotImages(counts: array[BotKind, int]) =
  ## Pulls the bot images requested by a create form.
  for bot in low(BotKind) .. high(BotKind):
    if counts[bot] > 0:
      pullDockerImage(botImage(bot))

proc removeContainers(names: seq[string]) =
  ## Removes containers created during a failed launch.
  for name in names:
    if name.len > 0:
      discard dockerResult(@["rm", "-f", name])

proc startWaitingBots(
  game: GameContainer,
  counts: array[BotKind, int],
  launchedNames: var seq[string]
): seq[BotContainer] =
  ## Starts bot containers before their game container exists.
  for bot in low(BotKind) .. high(BotKind):
    for _ in 0 ..< counts[bot]:
      let
        created = getTime().toUnix()
        stamp = launchStamp(launchedNames.len + 1)
        name = botContainerName(game, bot, stamp)
      discard requireDocker(botRunArgs(name, game, bot, created, stamp))
      launchedNames.add(name)
      result.add(inspectBot(name))

proc createGame(form: seq[(string, string)]): GameContainer =
  ## Starts a new Among Them Docker container.
  ensureReplayDir()
  let
    port = findOpenPort()
    created = getTime().toUnix()
    name = gameName(port)
    replay = replayName(name)
    config = configJson(form)
    botCounts = createBotCounts(form)
    pendingGame = GameContainer(
      name: name,
      status: "pending",
      port: port,
      created: created,
      replay: replay,
      kind: LiveGame
    )
  var launchedBots: seq[string]
  pullDockerImage(dockerImage())
  pullNeededBotImages(botCounts)
  try:
    discard startWaitingBots(pendingGame, botCounts, launchedBots)
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
  except CatchableError:
    removeContainers(launchedBots)
    raise

proc createReplayGame(replay: string): GameContainer =
  ## Starts an Among Them Docker container in replay mode.
  ensureReplayDir()
  pullDockerImage(dockerImage())
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

proc stopBotsForStoppedGames(
  containers: seq[GameContainer],
  bots: seq[BotContainer]
): int =
  ## Stops running bots whose parent game container has stopped.
  for bot in bots:
    if bot.status != "running":
      continue
    for game in containers:
      if game.name != bot.game:
        continue
      if game.kind == LiveGame and game.status != "running":
        discard requireDocker(@["stop", bot.name])
        inc result
      break

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

proc hostHeader(request: Request): string =
  ## Extracts the browser-visible host with its port.
  result = request.headers["Host"].strip()
  if result.len == 0:
    result = "localhost:" & $DefaultPort

proc gameWebSocketUrl(
  request: Request,
  game: GameContainer,
  path: string
): string =
  ## Builds a browser websocket URL for a game endpoint.
  "ws://" & request.hostName() & ":" & $game.port & path

proc gameUrl(request: Request, game: GameContainer, page: string): string =
  ## Builds a browser URL for a game client page.
  let socketPath =
    case page
    of "player.html":
      "/player"
    of "rewards.html", "reward.html", "stats.html":
      "/reward"
    else:
      "/global"
  "http://" & request.hostHeader() & ClientPath & page &
    "?address=" & encodeUrlComponent(
      gameWebSocketUrl(request, game, socketPath)
    )

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

proc createBots(
  gameName: string,
  bot: BotKind,
  count: int
): seq[BotContainer] =
  ## Starts one or more bot Docker containers for a live game.
  let game = inspectGame(gameName)
  if game.kind != LiveGame:
    raise newException(GamesServerError, "bots can only join live games")
  if not gameHealthy(game):
    raise newException(GamesServerError, "game is not healthy yet")
  let cleanCount = clampInt(count, 1, MaxBotLaunchCount)
  pullDockerImage(botImage(bot))
  for i in 1 .. cleanCount:
    let
      created = getTime().toUnix()
      stamp = launchStamp(i)
      name = botContainerName(game, bot, stamp)
    discard requireDocker(botRunArgs(name, game, bot, created, stamp))
    result.add(inspectBot(name))

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

proc renderConfigInput(name: string, property: JsonNode): string =
  ## Renders one manifest-backed config input.
  let
    kind = property.propertyType()
    defaultValue = property.defaultText()
    titleText = property.propertyString("description", name)
  case kind
  of "integer":
    result = renderFragment:
      input ".input":
        ttype "number"
        name name
        title titleText
        value defaultValue
        if hasPropertyInt(property, "minimum"):
          min $property.propertyInt("minimum", 0)
        if hasPropertyInt(property, "maximum"):
          max $property.propertyInt("maximum", 0)
  of "boolean":
    let otherValue =
      if defaultValue == "true":
        "false"
      else:
        "true"
    result = renderFragment:
      select:
        name name
        title titleText
        option:
          value defaultValue
          say defaultValue
        option:
          value otherValue
          say otherValue
  of "array":
    result = renderFragment:
      textarea ".textarea":
        name name
        title titleText
        rows "4"
        cols "60"
        say esc(defaultValue)
  else:
    result = renderFragment:
      input ".textInput":
        ttype "text"
        name name
        title titleText
        value defaultValue

proc renderConfigRows(schema: JsonNode): string =
  ## Renders all config form rows from a manifest schema.
  var index = 0
  for name, property in schema["properties"].pairs:
    let
      rowClass = if index mod 2 == 0: ".row1" else: ".row2"
      inputHtml = renderConfigInput(name, property)
    let rowHtml = renderFragment:
      tr:
        td rowClass & " fieldName nowrap":
          say esc(fieldLabel(name))
        td rowClass:
          say inputHtml
    result.add(rowHtml)
    inc index

proc renderBotCountSelect(bot: BotKind): string =
  ## Renders one create-form bot count selector.
  renderFragment:
    select:
      name botCountField(bot)
      for count in 0 .. MaxBotLaunchCount:
        option:
          value $count
          say $count

proc renderCreateBotRows(): string =
  ## Renders bot count rows for the create-game form.
  var index = 0
  for bot in low(BotKind) .. high(BotKind):
    let
      rowClass = if index mod 2 == 0: ".row1" else: ".row2"
      selectHtml = renderBotCountSelect(bot)
    let rowHtml = renderFragment:
      tr:
        td rowClass & " fieldName nowrap":
          say esc(botKindTitle(bot) & " bots")
        td rowClass:
          say selectHtml
    result.add(rowHtml)
    inc index

proc renderCreateLink(): string =
  ## Renders the index-page create game link.
  renderFragment:
    table:
      tr:
        td ".cat":
          colspan "2"
          say "Create new game"
      tr:
        td ".row1":
          a ".button":
            href CreatePath
            say "Create game"
        td ".row2 small":
          say "Image: " & esc(dockerImage()) & " | Mode: " & esc(dockerMode())

proc renderCreateForm(): string =
  ## Renders the manifest-backed create-game form.
  let
    schema = configSchema()
    rows = renderConfigRows(schema)
    botRows = renderCreateBotRows()
  renderFragment:
    form:
      action CreatePath
      tmethod "post"
      table:
        tr:
          td ".cat":
            colspan "2"
            say "Create new game"
        say rows
        tr:
          td ".cat":
            colspan "2"
            say "Bots"
        say botRows
        tr:
          td ".row1":
            say ""
          td ".row1":
            button ".button":
              ttype "submit"
              say "Create"
            say " "
            a ".button":
              href "/"
              say "Cancel"

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
          say "Scores"
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
            colspan "10"
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
            if game.replay.len > 0 and scoreFileExists(game.replay):
              a:
                href scoreUrl(game.replay)
                target "_blank"
                say "scores"
            elif game.status == "running":
              say "pending"
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
                  option:
                    value botKindLabel(ITalkALot)
                    say botKindTitle(ITalkALot)
                say " "
                select:
                  name "count"
                  for count in 1 .. MaxBotLaunchCount:
                    option:
                      value $count
                      say $count
                say " "
                button ".button":
                  ttype "submit"
                  say "Add"
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
          say "Scores"
        th ".head":
          say "Created"
        th ".head":
          say "Control"
        th ".head":
          say "Logs"
      if servers.len == 0:
        tr:
          td ".row1 center":
            colspan "9"
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
            if server.replay.len > 0 and scoreFileExists(server.replay):
              a:
                href scoreUrl(server.replay)
                target "_blank"
                say "scores"
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
        th ".head":
          say "Scores"
      if replays.len == 0:
        tr:
          td ".row1 center":
            colspan "5"
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
          td rowClass & " nowrap":
            if scoreFileExists(replay.name):
              a:
                href scoreUrl(replay.name)
                target "_blank"
                say "scores"
            else:
              say "-"

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
    createLink = renderCreateLink()
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
          say createLink
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
            say "Docker label: " & ServerLabel & ". Ports: OS assigned."

proc renderCreatePage(notice = ""): string =
  ## Renders the create-game page.
  let createForm = renderCreateForm()
  render:
    html:
      head:
        title:
          say "Create Game"
        say "<style>"
        say PageCss
        say "</style>"
      body:
        tdiv ".page":
          table:
            tr:
              td ".row2":
                h1 ".title":
                  say "Create Game"
                p ".small":
                  say "Among Them config from manifest."
              td ".row2 right small":
                a:
                  href "/"
                  say "Back"
          if notice.len > 0:
            p ".notice small":
              b:
                say esc(notice)
          p ".small":
            say " "
          say createForm
          p ".footer small":
            say "Manifest: " & esc(manifestPath()) & "."

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

proc renderScoresTable(rows: seq[ScoreRow]): string =
  ## Renders parsed score rows.
  renderFragment:
    table:
      tr:
        th ".head":
          say "Player"
        th ".head":
          say "Score"
        th ".head":
          say "Win"
        th ".head":
          say "Tasks"
        th ".head":
          say "Kills"
      if rows.len == 0:
        tr:
          td ".row1 center":
            colspan "5"
            say "No score rows saved."
      for i, row in rows:
        let rowClass = if i mod 2 == 0: ".row1" else: ".row2"
        tr:
          td rowClass:
            if row.name.len > 0:
              say esc(row.name)
            else:
              say "-"
          td rowClass & " right nowrap":
            if row.score.len > 0:
              say esc(row.score)
            else:
              say "-"
          td rowClass & " center nowrap":
            if row.win:
              b:
                say "yes"
            else:
              say "no"
          td rowClass & " right nowrap":
            if row.tasks.len > 0:
              say esc(row.tasks)
            else:
              say "-"
          td rowClass & " right nowrap":
            if row.kills.len > 0:
              say esc(row.kills)
            else:
              say "-"

proc renderScoresPage(name: string, rows: seq[ScoreRow]): string =
  ## Renders a parsed scores page.
  let scoresTable = renderScoresTable(rows)
  render:
    html:
      head:
        title:
          say "Scores: " & esc(name)
        say "<style>"
        say PageCss
        say "</style>"
      body:
        tdiv ".page":
          table:
            tr:
              td ".row2":
                h1 ".title":
                  say "Scores"
                p ".small":
                  say esc(name)
              td ".row2 right small":
                a:
                  href rawScoreUrl(name)
                  target "_blank"
                  say "Raw"
                say " | "
                a:
                  href "/"
                  say "Back"
          p ".small":
            say " "
          say scoresTable

proc clientRoot(): string =
  ## Returns the shared client asset directory.
  parentDir(parentDir(currentSourcePath())) / "clients"

proc clientAsset(path: string): string =
  ## Maps one public client route to a local asset path.
  case path
  of "/client/global.html", "/client/global_client.html":
    clientRoot() / "global_client.html"
  of "/client/player.html", "/client/player_client.html":
    clientRoot() / "player_client.html"
  of "/client/reward.html", "/client/rewards.html",
      "/client/reward_client.html":
    clientRoot() / "reward_client.html"
  of "/client/stats.html":
    clientRoot() / "stats.html"
  of "/client/snappyjs.min.js":
    clientRoot() / "snappyjs.min.js"
  of "/client/qrcode.min.js":
    clientRoot() / "qrcode.min.js"
  else:
    ""

proc clientContentType(path: string): string =
  ## Returns a content type for one shared client asset.
  if path.endsWith(".js"):
    "text/javascript; charset=utf-8"
  else:
    "text/html; charset=utf-8"

proc htmlHeaders(): HttpHeaders =
  ## Builds standard HTML response headers.
  result["Content-Type"] = "text/html; charset=utf-8"
  result["Cache-Control"] = "no-cache"

proc contentHeaders(contentType: string): HttpHeaders =
  ## Builds standard static content response headers.
  result["Content-Type"] = contentType
  result["Cache-Control"] = "no-cache"

proc redirectHeaders(location: string): HttpHeaders =
  ## Builds redirect headers.
  result = htmlHeaders()
  result["Location"] = location

proc respondHtml(request: Request, status: int, body: string) =
  ## Sends an HTML response.
  request.respond(status, htmlHeaders(), body)

proc respondContent(
  request: Request,
  status: int,
  contentType,
  body: string
) =
  ## Sends a static content response.
  request.respond(status, contentHeaders(contentType), body)

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
    replays = listReplays()
  var bots = listBots()
  if stopBotsForStoppedGames(containers, bots) > 0:
    bots = listBots()
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

proc createFormHandler(request: Request) =
  ## Handles the create-game form route.
  request.respondHtml(200, renderCreatePage(queryValue(request, "notice")))

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
    count = cleanConfigValue(form, "count", 1, 1, MaxBotLaunchCount)
    containers = createBots(name, bot, count)
  if containers.len == 1:
    request.respondRedirect("/?notice=started+" & containers[0].name)
  else:
    request.respondRedirect("/?notice=started+" & $containers.len & "+bots")

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

proc scoresHandler(request: Request) =
  ## Handles saved score file requests.
  let
    rawName = queryValue(request, "name")
    name = cleanReplayName(rawName)
  if name.len == 0 or name != rawName or
      not name.endsWith(".scores.json") or
      not fileExists(replayPath(name)):
    request.respondContent(
      404,
      "text/plain; charset=utf-8",
      "scores not found\n"
    )
    return
  let text = readFile(replayPath(name))
  if queryValue(request, "raw").len > 0:
    request.respondContent(
      200,
      "text/plain; charset=utf-8",
      text
    )
    return
  request.respondContent(
    200,
    "text/html; charset=utf-8",
    renderScoresPage(name, parseScoreRows(text))
  )

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

proc clientHandler(request: Request) =
  ## Handles shared client asset requests.
  let path = clientAsset(request.path)
  if path.len == 0 or not fileExists(path):
    request.notFoundHandler()
    return
  request.respondContent(
    200,
    clientContentType(path),
    readFile(path)
  )

proc errorHandler(request: Request, e: ref Exception) =
  ## Handles expected and unexpected server errors.
  stderr.writeLine("[games_server] ", e.msg)
  if request.path == CreatePath:
    request.respondHtml(500, renderCreatePage(e.msg))
    return
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

proc httpHandlerUnsafe(request: Request) =
  ## Routes all HTTP requests.
  try:
    if request.path == "/" and request.httpMethod == "GET":
      request.indexHandler()
    elif request.path == CreatePath and request.httpMethod == "GET":
      request.createFormHandler()
    elif request.path == LogsPath and request.httpMethod == "GET":
      request.logsHandler()
    elif request.path == ScoresPath and request.httpMethod == "GET":
      request.scoresHandler()
    elif request.path.startsWith(ClientPath) and request.httpMethod == "GET":
      request.clientHandler()
    elif request.path == CreatePath and request.httpMethod == "POST":
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

proc httpHandler(request: Request) {.gcsafe.} =
  ## Adapts the route handler to mummy's RequestHandler signature.
  {.gcsafe.}:
    request.httpHandlerUnsafe()

proc runServer(address = DefaultHost, port = DefaultPort) =
  ## Runs the games control web server.
  loadAiKeyEnvs()
  let server = newServer(httpHandler, workerThreads = 1)
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

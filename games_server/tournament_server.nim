import
  std/[
    algorithm, json, locks, math, net, os, osproc, parseopt, random,
    strutils, tables, times, uri
  ],
  mummy,
  taggy

from std/httpclient import close, getContent, newHttpClient

const
  DefaultHost = "0.0.0.0"
  DefaultPort = 2081
  DefaultActiveGames = 2
  DefaultPlayersPerGame = 8
  DefaultTickMillis = 2000
  CleanupDeadSeconds = 10 * 60
  InspectBatchSize = 100
  DefaultMmr = 1000.0
  MmrK = 64.0
  MinMmr = 100.0
  PriorityGameCount = 30
  PriorityBaseWeight = 9.0
  SelectionTopRatio = 8.0
  SelectionCurve = 2.0
  DockerBinEnv = "TOURNAMENT_DOCKER"
  ManifestPathEnv = "TOURNAMENT_MANIFEST"
  PlayerListEnv = "TOURNAMENT_PLAYERS"
  ReplayDirEnv = "TOURNAMENT_REPLAY_DIR"
  SharedReplayDirEnv = "GAMES_SERVER_REPLAY_DIR"
  GamesServerPortEnv = "TOURNAMENT_GAMES_SERVER_PORT"
  CogameManifestName = "cogame_manifest.json"
  CoplayerManifestName = "coplayer_manifest.json"
  GameContainerPort = 8080
  ContainerReplayDir = "/replays"
  CogameReplayEnv = "COGAME_SAVE_REPLAY_PATH"
  CogameResultsEnv = "COGAME_SAVE_RESULTS_PATH"
  HealthPath = "/healthz"
  LogsPath = "/logs"
  ScoresPath = "/scores"
  ClientPath = "/client/"
  PlayersTablePath = "/players/table"
  BulkStopPath = "/containers/stop"
  BulkRemovePath = "/containers/remove"
  AiKeyEnvNames = ["CLAUDE_KEY", "GEMINI_KEY", "OPENAI_KEY", "XAI_KEY"]
  ServerLabelKey = "bitworld.tournament_server"
  ServerLabelValue = "tournament"
  ServerLabel = ServerLabelKey & "=" & ServerLabelValue
  KindLabel = "bitworld.tournament_server.kind"
  GameKind = "game"
  PlayerKind = "player"
  PortLabel = "bitworld.tournament_server.port"
  CreatedLabel = "bitworld.tournament_server.created"
  GameIdLabel = "bitworld.tournament_server.game_id"
  GameNameLabel = "bitworld.tournament_server.game"
  PlayerLabel = "bitworld.tournament_server.player"
  PlayerNameLabel = "bitworld.tournament_server.player_name"
  ReplayLabel = "bitworld.tournament_server.replay"
  ResultsLabel = "bitworld.tournament_server.results"
  ContainerInspectFormat =
    "{{.Name}}\t{{.State.Status}}\t" &
    "{{.State.ExitCode}}\t{{.State.FinishedAt}}\t" &
    "{{index .Config.Labels \"" & KindLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & PortLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & CreatedLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & GameIdLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & GameNameLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & PlayerLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & PlayerNameLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & ReplayLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & ResultsLabel & "\"}}"
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
table {
  width: 100%;
  border-collapse: collapse;
}
form {
  margin: 0;
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
.selectCell {
  width: 24px;
  text-align: center;
}
.bulkBar {
  margin: 8px 0;
  text-align: right;
}
.button {
  display: inline-block;
  box-sizing: border-box;
  min-width: 58px;
  height: 19px;
  margin: 0;
  border: 1px solid #303050;
  border-radius: 0;
  appearance: none;
  -webkit-appearance: none;
  background: #eeeeff;
  color: #000020;
  cursor: pointer;
  font: 11px/13px Verdana, Helvetica, Arial, sans-serif;
  padding: 2px 8px;
  text-align: center;
  text-decoration: none;
  vertical-align: middle;
}
.button:hover {
  text-decoration: none;
}
.ok {
  color: #006000;
  font-weight: 700;
}
.bad {
  color: #a00000;
  font-weight: 700;
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
  BulkScript = """
<script>
document.addEventListener("DOMContentLoaded", function () {
  var boxes = Array.prototype.slice.call(
    document.querySelectorAll(".bulkCheck")
  );
  var anchor = null;
  window.confirmRemoveContainers = function () {
    var count = boxes.filter(function (box) {
      return box.checked;
    }).length;
    return confirm(
      "Going to remove " + count + " containers (can't be undone) ok?"
    );
  };
  boxes.forEach(function (box) {
    box.addEventListener("click", function (event) {
      if (event.shiftKey && anchor) {
        var a = boxes.indexOf(anchor);
        var b = boxes.indexOf(box);
        var start = Math.min(a, b);
        var stop = Math.max(a, b);
        var checked = box.checked;
        for (var i = start; i <= stop; i++) {
          boxes[i].checked = checked;
        }
      } else {
        anchor = box;
      }
    });
  });
});
</script>
"""
  PlayerTableScript = """
<script>
setInterval(function () {
  fetch("/players/table").then(function (r) { return r.ok ? r.text() : ""; })
  .then(function (h) { if (h.indexOf("<table") >= 0) document.getElementById("playerTable").innerHTML = h; })
  .catch(function () {});
}, 60000);
</script>
"""

type
  TournamentError = object of CatchableError

  CommandResult = object
    output: string
    code: int

  GameManifest = object
    key: string
    path: string
    name: string
    author: string
    imageUri: string
    binary: string

  PlayerManifest = object
    key: string
    path: string
    name: string
    author: string
    imageUri: string
    binary: string
    games: seq[string]

  TournamentConfig = object
    address: string
    port: int
    activeGames: int
    playersPerGame: int
    tickMillis: int
    manifestPath: string
    playerList: string

  ContainerKind = enum
    ManagedGame,
    ManagedPlayer

  TournamentContainer = object
    name: string
    status: string
    exitCode: int
    finished: int64
    kind: ContainerKind
    port: int
    created: int64
    gameId: int
    gameName: string
    player: string
    playerName: string
    replay: string
    results: string

  PlayerSlot = object
    player: string
    playerName: string
    containerName: string

  GameRun = object
    id: int
    name: string
    port: int
    created: int64
    replay: string
    results: string
    slots: seq[PlayerSlot]

  ScoreRow = object
    name: string
    score: float
    win: bool
    tasks: int
    kills: int
    imposter: int
    crew: int
    votePlayers: int
    voteSkip: int
    voteTimeout: int

  ScoreFile = object
    path: string
    name: string
    created: int64
    modified: int64

  GameOutcome = object
    wins: int
    losses: int

  PlayerStats = object
    name: string
    author: string
    imageUri: string
    games: int
    wins: int
    scoreSum: float
    tasksSum: int
    killsSum: int
    imposterSum: int
    crewSum: int
    votePlayersSum: int
    voteSkipSum: int
    voteTimeoutSum: int
    mmr: float

  TournamentState = object
    lock: Lock
    nextGameId: int
    started: int64
    lastError: string
    pulledImages: seq[string]
    games: seq[GameRun]

var
  state: TournamentState
  scheduler: Thread[TournamentConfig]

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

proc monthFromNumber(value: int): Month =
  ## Converts a one-based month number into a Month enum.
  case value
  of 1:
    mJan
  of 2:
    mFeb
  of 3:
    mMar
  of 4:
    mApr
  of 5:
    mMay
  of 6:
    mJun
  of 7:
    mJul
  of 8:
    mAug
  of 9:
    mSep
  of 10:
    mOct
  of 11:
    mNov
  of 12:
    mDec
  else:
    mJan

proc parseDockerTime(value: string): int64 =
  ## Parses a Docker timestamp into Unix seconds.
  let text = value.strip()
  if text.len < 20 or text.startsWith("0001-"):
    return 0
  try:
    let
      year = text[0 .. 3].parseInt()
      month = text[5 .. 6].parseInt()
      monthDay = text[8 .. 9].parseInt()
      hour = text[11 .. 12].parseInt()
      minute = text[14 .. 15].parseInt()
      second = text[17 .. 18].parseInt()
    if month < 1 or month > 12:
      return 0
    result = dateTime(
      year,
      monthFromNumber(month),
      monthDay,
      hour,
      minute,
      second,
      0,
      utc()
    ).toTime().toUnix()
  except ValueError:
    result = 0

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
    let splitAt = piece.find('=')
    if splitAt < 0:
      result.add((decodeUrl(piece.replace("+", " ")), ""))
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
        decodeUrl(rawKey.replace("+", " ")),
        decodeUrl(rawValue.replace("+", " "))
      ))

proc envValue(name, defaultValue: string): string =
  ## Reads an environment setting with a fallback.
  result = getEnv(name, defaultValue).strip()
  if result.len == 0:
    result = defaultValue

proc gamesServerPort(): int =
  ## Returns the CoGame server port used for shared score pages.
  let port = parseIntSafe(envValue(GamesServerPortEnv, "2080"))
  if port <= 0:
    2080
  else:
    port

proc dockerBin(): string =
  ## Returns the Docker-compatible CLI path.
  envValue(DockerBinEnv, "docker")

proc gamesRoot(): string =
  ## Returns the local Bitworld games root.
  parentDir(parentDir(currentSourcePath()))

proc defaultManifestPath(): string =
  ## Returns the default tournament game manifest.
  gamesRoot() / "among_them" / CogameManifestName

proc manifestPath(): string =
  ## Returns the configured tournament game manifest.
  envValue(ManifestPathEnv, defaultManifestPath())

proc defaultReplayDir(): string =
  ## Returns the shared replay and score directory.
  parentDir(currentSourcePath()) / "replays"

proc replayDir(): string =
  ## Returns the configured shared replay and score directory.
  envValue(
    ReplayDirEnv,
    envValue(SharedReplayDirEnv, defaultReplayDir())
  )

proc ensureReplayDir() =
  ## Creates the tournament replay directory.
  try:
    createDir(replayDir())
  except OSError as e:
    raise newException(
      TournamentError,
      "could not create replay dir: " & e.msg
    )

proc manifestKey(path: string): string =
  ## Builds a stable relative key for one manifest path.
  let
    root = gamesRoot()
    prefix = root & DirSep
  if path.startsWith(prefix):
    result = path[prefix.len .. ^1]
  else:
    result = path
  result = result.replace("\\", "/")

proc manifestString(
  node: JsonNode,
  key,
  defaultValue: string
): string =
  ## Reads one top-level manifest string.
  if node.kind == JObject and node.hasKey(key) and
      node[key].kind == JString:
    return node[key].getStr()
  defaultValue

proc manifestStringArray(node: JsonNode, key: string): seq[string] =
  ## Reads one top-level string array from a manifest.
  if node.kind != JObject or not node.hasKey(key) or
      node[key].kind != JArray:
    return
  for item in node[key].items:
    if item.kind == JString:
      result.add(item.getStr())

proc defaultManifestName(path: string): string =
  ## Returns a display name for a manifest path.
  splitPath(parentDir(path)).tail

proc readGameManifest(path: string): GameManifest =
  ## Reads one CoGame manifest summary from disk.
  try:
    let
      manifest = parseJson(readFile(path))
      name = manifest.manifestString(
        "name",
        defaultManifestName(path)
      )
    result = GameManifest(
      key: manifestKey(path),
      path: path,
      name: name,
      author: manifest.manifestString(
        "author",
        manifest.manifestString("owner", "-")
      ),
      imageUri: manifest.manifestString("image_uri", ""),
      binary: manifest.manifestString("binary", "/bin/" & name)
    )
  except CatchableError as e:
    raise newException(
      TournamentError,
      "could not read game manifest " & path & ": " & e.msg
    )

proc readPlayerManifest(path: string): PlayerManifest =
  ## Reads one CoPlayer manifest summary from disk.
  try:
    let
      manifest = parseJson(readFile(path))
      name = manifest.manifestString(
        "name",
        defaultManifestName(path)
      )
    result = PlayerManifest(
      key: manifestKey(path),
      path: path,
      name: name,
      author: manifest.manifestString("author", "-"),
      imageUri: manifest.manifestString("image_uri", ""),
      binary: manifest.manifestString("binary", "/bin/" & name),
      games: manifest.manifestStringArray("games")
    )
  except CatchableError as e:
    raise newException(
      TournamentError,
      "could not read player manifest " & path & ": " & e.msg
    )

proc addManifestPath(paths: var seq[string], path: string) =
  ## Adds one manifest path if it exists and is not already present.
  if path.len == 0 or not fileExists(path):
    return
  let key = manifestKey(path)
  for existing in paths:
    if manifestKey(existing) == key:
      return
  paths.add(path)

proc listPlayerManifests(): seq[PlayerManifest] =
  ## Scans game folders for CoPlayer manifests.
  var paths: seq[string]
  for dir in walkDirs(gamesRoot() / "*"):
    for path in walkFiles(dir / "players" / "*" / CoplayerManifestName):
      paths.addManifestPath(path)
  paths.sort(proc(a, b: string): int = cmp(manifestKey(a), manifestKey(b)))
  for path in paths:
    result.add(readPlayerManifest(path))

proc supportsGame(player: PlayerManifest, gameName: string): bool =
  ## Returns true when one player manifest supports one game.
  for game in player.games:
    if game == gameName:
      return true

proc addPlayerPolicy(
  players: var seq[PlayerManifest],
  player: PlayerManifest
) =
  ## Adds one player manifest when its policy name is not already present.
  for existing in players:
    if existing.name == player.name:
      return
  players.add(player)

proc selectedPlayers(
  config: TournamentConfig,
  game: GameManifest
): seq[PlayerManifest] =
  ## Returns tournament players selected by config.
  let players = listPlayerManifests()
  if config.playerList.strip().len == 0:
    for player in players:
      if player.supportsGame(game.name):
        result.addPlayerPolicy(player)
    result.sort(proc(a, b: PlayerManifest): int = cmp(a.name, b.name))
    return

  for raw in config.playerList.split(','):
    let key = raw.strip()
    if key.len == 0:
      continue
    var found = false
    for player in players:
      if player.supportsGame(game.name) and
          (player.name == key or player.key == key or player.path == key):
        result.addPlayerPolicy(player)
        found = true
        break
    if not found:
      raise newException(TournamentError, "unknown player manifest: " & key)
  if result.len == 0:
    raise newException(TournamentError, "no tournament players selected")

proc stripImageTag(image: string): string =
  ## Removes a Docker image tag or digest.
  let
    slashAt = image.rfind('/')
    colonAt = image.rfind(':')
    digestAt = image.find('@')
  var stop = image.len
  if digestAt >= 0:
    stop = digestAt
  elif colonAt > slashAt:
    stop = colonAt
  image[0 ..< stop]

proc imageTag(image: string): string =
  ## Returns a Docker image tag suffix when present.
  let
    slashAt = image.rfind('/')
    colonAt = image.rfind(':')
  if colonAt > slashAt:
    image[colonAt .. ^1]
  else:
    ""

proc runnerImageUri(imageUri: string): string =
  ## Converts a manifest image name to the registry runner image.
  let
    cleanImage = imageUri.strip()
    tag = imageTag(cleanImage)
  var
    owner = "treeform"
    packageName = stripImageTag(cleanImage)
  if packageName.startsWith("ghcr.io/"):
    let parts = packageName.split('/')
    if parts.len >= 3:
      owner = parts[1]
      packageName = parts[2 .. ^1].join("/")
  elif packageName.contains('/'):
    packageName = packageName.split('/')[^1]
  if packageName.len == 0:
    packageName = "bitworld-among-them"
  if not packageName.endsWith("-runner"):
    packageName.add("-runner")
  "ghcr.io/" & owner & "/" & packageName & tag

proc dockerResult(args: openArray[string]): CommandResult =
  ## Runs Docker and captures merged stdout and stderr.
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
      TournamentError,
      "could not run Docker: " & e.msg
    )

proc requireDocker(args: openArray[string]): string =
  ## Runs Docker and raises a tournament error on failure.
  let res = dockerResult(args)
  if res.code != 0:
    raise newException(
      TournamentError,
      "docker " & args.join(" ") & " failed: " & res.output.strip()
    )
  res.output.strip()

proc cleanContainerName(value: string): string =
  ## Keeps only Docker-safe container name characters.
  for c in value:
    if c.isAlphaNumeric() or c == '_' or c == '-':
      result.add(c)
  if result.len > 120:
    result = result[0 .. 119]

proc cleanFileName(value: string): string =
  ## Keeps only safe replay and result file name characters.
  for c in value:
    if c.isAlphaNumeric() or c == '_' or c == '-' or c == '.':
      result.add(c)
  if result.len > 160:
    result = result[0 .. 159]

proc splitInspectLine(line: string): seq[string] =
  ## Splits a Docker inspect line into tab-separated fields.
  result = line.split('\t')
  while result.len < 13:
    result.add("")

proc parseContainerKind(value: string): ContainerKind =
  ## Parses a tournament Docker container kind label.
  if value == PlayerKind:
    ManagedPlayer
  else:
    ManagedGame

proc parseContainerLine(line: string): TournamentContainer =
  ## Parses one tab-separated Docker inspect line.
  let parts = splitInspectLine(line)
  result = TournamentContainer(
    name: parts[0].strip(chars = {'/'}),
    status: parts[1],
    exitCode: parseIntSafe(parts[2]),
    finished: parseDockerTime(parts[3]),
    kind: parseContainerKind(parts[4]),
    port: parseIntSafe(parts[5]),
    created: parseInt64Safe(parts[6]),
    gameId: parseIntSafe(parts[7]),
    gameName: parts[8],
    player: parts[9],
    playerName: parts[10],
    replay: parts[11],
    results: parts[12]
  )

proc inspectContainer(name: string): TournamentContainer =
  ## Reads one tournament-managed Docker container.
  let line = requireDocker(@[
    "inspect",
    "--format",
    ContainerInspectFormat,
    name
  ]).strip()
  result = parseContainerLine(line)

proc missingObjectLine(line: string): bool =
  ## Returns true for a Docker inspect race on a removed container.
  let text = line.toLowerAscii()
  text.contains("no such object") or text.contains("no such container")

proc inspectContainerBatch(names: openArray[string]): seq[TournamentContainer] =
  ## Reads a batch of tournament-managed Docker containers.
  if names.len == 0:
    return
  let res = dockerResult(
    @["inspect", "--format", ContainerInspectFormat] & @names
  )
  var errors: seq[string]
  for line in res.output.splitLines():
    let cleanLine = line.strip()
    if cleanLine.len == 0:
      continue
    if not cleanLine.startsWith("/"):
      if not missingObjectLine(cleanLine):
        errors.add(cleanLine)
      continue
    try:
      result.add(parseContainerLine(cleanLine))
    except CatchableError:
      errors.add(cleanLine)
  if res.code != 0 and result.len == 0 and errors.len > 0:
    raise newException(
      TournamentError,
      "docker inspect failed: " & errors.join("\n")
    )

proc listContainers(): seq[TournamentContainer] =
  ## Lists Docker containers owned by the tournament server.
  let output = requireDocker(@[
    "ps",
    "-a",
    "--filter",
    "label=" & ServerLabel,
    "--format",
    "{{.Names}}"
  ])
  var names: seq[string]
  for line in output.splitLines():
    let name = line.strip()
    if name.len > 0:
      names.add(name)
  var index = 0
  while index < names.len:
    let stop = min(index + InspectBatchSize, names.len)
    result.add(inspectContainerBatch(names[index ..< stop]))
    index = stop
  result.sort(proc(a, b: TournamentContainer): int =
    cmp(b.created, a.created)
  )

proc listGames(
  containers: openArray[TournamentContainer]
): seq[TournamentContainer] =
  ## Filters tournament game containers.
  for container in containers:
    if container.kind == ManagedGame:
      result.add(container)

proc listPlayers(
  containers: openArray[TournamentContainer]
): seq[TournamentContainer] =
  ## Filters tournament player containers.
  for container in containers:
    if container.kind == ManagedPlayer:
      result.add(container)

proc containerLogState(name: string): string =
  ## Reads current Docker state for one managed container.
  let format =
    "status={{.State.Status}}\n" &
    "exit={{.State.ExitCode}}\n" &
    "oom={{.State.OOMKilled}}\n" &
    "error={{.State.Error}}\n" &
    "started={{.State.StartedAt}}\n" &
    "finished={{.State.FinishedAt}}"
  requireDocker(@["inspect", "--format", format, name])

proc tournamentLabelValue(name: string): string =
  ## Reads the tournament ownership label for one container.
  requireDocker(@[
    "inspect",
    "--format",
    "{{index .Config.Labels \"" & ServerLabelKey & "\"}}",
    name
  ]).strip()

proc managedContainerName(name: string): string =
  ## Validates that one name belongs to this tournament server.
  let safeName = cleanContainerName(name)
  if safeName.len == 0 or safeName != name:
    raise newException(TournamentError, "invalid container name")
  if tournamentLabelValue(safeName) != ServerLabelValue:
    raise newException(
      TournamentError,
      "container is not managed by tournament_server"
    )
  let container = inspectContainer(safeName)
  if container.name != safeName:
    raise newException(TournamentError, "container inspect mismatch")
  safeName

proc containerLogs(name: string): string =
  ## Reads current Docker stdout and stderr logs for one container.
  let safeName = managedContainerName(name)
  containerLogState(safeName) &
    "\n\n--- docker logs stdout and stderr ---\n" &
    requireDocker(@["logs", "--timestamps", safeName])

proc playersForGame(gameName: string): seq[TournamentContainer] =
  ## Lists player containers attached to one tournament game.
  for player in listPlayers(listContainers()):
    if player.gameName == gameName:
      result.add(player)

proc stopManagedContainer(name: string) =
  ## Stops one tournament game or player container.
  let
    safeName = managedContainerName(name)
    container = inspectContainer(safeName)
  if container.kind == ManagedGame:
    for player in playersForGame(container.name):
      if player.status == "running":
        discard dockerResult(@["stop", player.name])
  if container.status == "running":
    discard requireDocker(@["stop", container.name])

proc removeManagedContainer(name: string): seq[string] =
  ## Removes one tournament game or player container.
  let
    safeName = managedContainerName(name)
    container = inspectContainer(safeName)
  if container.kind == ManagedGame:
    for player in playersForGame(container.name):
      discard dockerResult(@["rm", "-f", player.name])
      result.add(player.name)
  discard requireDocker(@["rm", "-f", container.name])
  result.add(container.name)

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
      TournamentError,
      "could not ask OS for a free port: " & e.msg
    )
  finally:
    socket.close()
  if result <= 0:
    raise newException(TournamentError, "OS returned an invalid free port")

proc fmtCreated(created: int64): string =
  ## Formats a Unix timestamp for display.
  if created <= 0:
    return "unknown"
  fromUnix(created).utc().format("yyyy-MM-dd HH:mm:ss") & " UTC"

proc fmtFloat(value: float): string =
  ## Formats one score or MMR value.
  value.formatFloat(ffDecimal, 2)

proc replayName(gameName: string): string =
  ## Builds the replay file name for one tournament game.
  cleanFileName(gameName) & ".bitreplay"

proc resultsName(gameName: string): string =
  ## Builds the scores file name for one tournament game.
  cleanFileName(gameName) & ".scores.json"

proc replayPath(name: string): string =
  ## Builds an absolute path for one replay or score file.
  replayDir() / cleanFileName(name)

proc addAiEnvArgs(args: var seq[string]) =
  ## Adds Docker env forwarding args for configured AI keys.
  for name in AiKeyEnvNames:
    if getEnv(name).len > 0:
      args.add("-e")
      args.add(name)

proc stateHasPulled(image: string): bool =
  ## Returns true when an image has been pulled this server run.
  acquire(state.lock)
  try:
    result = image in state.pulledImages
  finally:
    release(state.lock)

proc markImagePulled(image: string) =
  ## Marks one image as pulled for this server run.
  acquire(state.lock)
  try:
    if image notin state.pulledImages:
      state.pulledImages.add(image)
  finally:
    release(state.lock)

proc pullImageOnce(image: string) =
  ## Pulls one Docker image at most once per server run.
  if image.len == 0 or stateHasPulled(image):
    return
  discard requireDocker(@["pull", image])
  markImagePulled(image)

proc nextGameId(): int =
  ## Allocates the next in-memory tournament game id.
  acquire(state.lock)
  try:
    inc state.nextGameId
    result = state.nextGameId
  finally:
    release(state.lock)

proc updateLastError(message: string) =
  ## Stores the most recent scheduler error.
  acquire(state.lock)
  try:
    state.lastError = message
  finally:
    release(state.lock)

proc clearLastError() =
  ## Clears the most recent scheduler error.
  updateLastError("")

proc rebuildStatsTable(
  players: openArray[PlayerManifest]
): Table[string, PlayerStats]

proc defaultConfigJson(
  manifest: GameManifest,
  playersPerGame: int,
  slots: openArray[PlayerSlot]
): string =
  ## Builds a practical tournament config JSON object.
  let manifestNode = parseJson(readFile(manifest.path))
  var node = newJObject()
  if manifestNode.hasKey("config_schema"):
    let schema = manifestNode["config_schema"]
    if schema.kind == JObject and schema.hasKey("properties") and
        schema["properties"].kind == JObject:
      for key, property in schema["properties"].pairs:
        if property.kind == JObject and property.hasKey("default"):
          node[key] = property["default"].copy()

  let slotArray = newJArray()
  for slot in slots:
    let item = newJObject()
    item["name"] = %slot.playerName
    slotArray.add(item)

  node["tokens"] = newJArray()
  node["slots"] = slotArray
  node["seed"] = %rand(1_000_000_000)
  node["minPlayers"] = %playersPerGame
  node["imposterCount"] = %max(0, min(playersPerGame - 1, playersPerGame div 4))
  node["autoImposterCount"] = %false
  node["maxGames"] = %1
  $node

proc gameContainerName(port, gameId: int): string =
  ## Builds a tournament game Docker container name.
  "tournament_game_" & $port & "_" & $getTime().toUnix() & "_" & $gameId

proc playerContainerName(
  player: PlayerManifest,
  port,
  gameId,
  slot: int
): string =
  ## Builds a tournament player Docker container name.
  cleanContainerName(
    "tournament_player_" & player.name & "_" & $port & "_" &
      $gameId & "_" & $slot
  )

proc visiblePlayerName(
  player: PlayerManifest,
  gameId,
  slot: int
): string =
  ## Builds the in-game visible tournament player name.
  player.name & "-t" & $gameId & "-" & $slot

proc addGameRun(game: GameRun) =
  ## Adds one in-memory game run.
  acquire(state.lock)
  try:
    state.games.add(game)
  finally:
    release(state.lock)

proc removeContainers(names: openArray[string]) =
  ## Removes containers created during a failed launch.
  for name in names:
    if name.len > 0:
      discard dockerResult(@["rm", "-f", name])

proc gameDockerArgs(
  game: GameManifest,
  name: string,
  port: int,
  run: GameRun,
  config: string
): seq[string] =
  ## Builds Docker args for one tournament game container.
  result = @[
    "run",
    "-d",
    "--init",
    "--name",
    name,
    "-p",
    $port & ":" & $GameContainerPort,
    "--label",
    ServerLabel,
    "--label",
    KindLabel & "=" & GameKind,
    "--label",
    PortLabel & "=" & $port,
    "--label",
    CreatedLabel & "=" & $run.created,
    "--label",
    GameIdLabel & "=" & $run.id,
    "--label",
    GameNameLabel & "=" & name,
    "--label",
    ReplayLabel & "=" & run.replay,
    "--label",
    ResultsLabel & "=" & run.results,
    "-v",
    replayDir() & ":" & ContainerReplayDir,
    "-e",
    CogameReplayEnv & "=" & ContainerReplayDir / run.replay,
    "-e",
    CogameResultsEnv & "=" & ContainerReplayDir / run.results
  ]
  result.addAiEnvArgs()
  result.add(runnerImageUri(game.imageUri))
  result.add(game.binary)
  result.add("--address:0.0.0.0")
  result.add("--port:" & $GameContainerPort)
  result.add("--config:" & config)

proc playerDockerArgs(
  player: PlayerManifest,
  containerName: string,
  run: GameRun,
  slot: PlayerSlot
): seq[string] =
  ## Builds Docker args for one tournament player container.
  result = @[
    "run",
    "-d",
    "--init",
    "--name",
    containerName,
    "--add-host",
    "host.docker.internal:host-gateway",
    "--label",
    ServerLabel,
    "--label",
    KindLabel & "=" & PlayerKind,
    "--label",
    CreatedLabel & "=" & $run.created,
    "--label",
    GameIdLabel & "=" & $run.id,
    "--label",
    GameNameLabel & "=" & run.name,
    "--label",
    PlayerLabel & "=" & player.name,
    "--label",
    PlayerNameLabel & "=" & slot.playerName
  ]
  result.addAiEnvArgs()
  result.add(player.imageUri)
  result.add(player.binary)
  result.add("--address:" & BotHost)
  result.add("--port:" & $run.port)
  result.add("--name:" & slot.playerName)

proc mmrWeight(mmr, minMmr, maxMmr: float): float =
  ## Returns a weighted-random policy selection weight.
  if maxMmr <= minMmr:
    return 1.0
  var position = (mmr - minMmr) / (maxMmr - minMmr)
  if position < 0.0:
    position = 0.0
  elif position > 1.0:
    position = 1.0
  1.0 + (SelectionTopRatio - 1.0) * pow(position, SelectionCurve)

proc priorityWeight(games: int): float =
  ## Returns a stronger selection weight for under-tested policies.
  if games >= PriorityGameCount:
    return 0.0
  PriorityBaseWeight + float(PriorityGameCount - games)

proc playerWeights(
  players: openArray[PlayerManifest]
): seq[float] =
  ## Returns weights biased toward new policies and then higher MMR.
  let stats = rebuildStatsTable(players)
  var
    mmrs: seq[float]
    games: seq[int]
    minRating = DefaultMmr
    maxRating = DefaultMmr
  for i, player in players:
    var
      mmr = DefaultMmr
      gameCount = 0
    if stats.hasKey(player.name):
      mmr = stats[player.name].mmr
      gameCount = stats[player.name].games
    if i == 0:
      minRating = mmr
      maxRating = mmr
    else:
      minRating = min(minRating, mmr)
      maxRating = max(maxRating, mmr)
    mmrs.add(mmr)
    games.add(gameCount)
  for i, mmr in mmrs:
    let priority = priorityWeight(games[i])
    if priority > 0.0:
      result.add(priority)
    else:
      result.add(mmrWeight(mmr, minRating, maxRating))

proc maxPolicyCopies(count, policyCount: int): int =
  ## Returns the per-policy player cap for one tournament game.
  if policyCount <= 1:
    return count
  max(1, count div 2)

proc policyCount(players: openArray[PlayerManifest]): int =
  ## Counts unique player policy names.
  var names: seq[string]
  for player in players:
    if player.name notin names:
      names.add(player.name)
  names.len

proc cappedWeights(
  players: openArray[PlayerManifest],
  weights: openArray[float],
  picks: Table[string, int],
  maxCopies: int
): seq[float] =
  ## Returns selection weights after applying per-game policy caps.
  for i, weight in weights:
    let picked = picks.getOrDefault(players[i].name)
    if picked >= maxCopies:
      result.add(0.0)
    else:
      result.add(weight)

proc chooseWeightedPlayer(weights: openArray[float]): int =
  ## Chooses one player index from a positive weight vector.
  var total = 0.0
  for weight in weights:
    total += max(0.0, weight)
  if total <= 0.0:
    return rand(max(0, weights.len - 1))
  let target = rand(total)
  var cursor = 0.0
  for i, weight in weights:
    cursor += max(0.0, weight)
    if target <= cursor:
      return i
  max(0, weights.len - 1)

proc choosePlayers(
  players: openArray[PlayerManifest],
  count,
  gameId,
  port: int
): tuple[slots: seq[PlayerSlot], manifests: seq[PlayerManifest]] =
  ## Chooses weighted-random players with replacement for one game.
  if players.len == 0:
    raise newException(TournamentError, "no players available")
  let
    weights = playerWeights(players)
    policies = policyCount(players)
    maxCopies = maxPolicyCopies(count, policies)
  if maxCopies * policies < count:
    raise newException(
      TournamentError,
      "not enough policies to enforce the 50% tournament cap"
    )
  var picks: Table[string, int]
  for slot in 0 ..< count:
    let
      availableWeights = cappedWeights(players, weights, picks, maxCopies)
      playerIndex = chooseWeightedPlayer(availableWeights)
      player = players[playerIndex]
    picks[player.name] = picks.getOrDefault(player.name) + 1
    let playerName = visiblePlayerName(player, gameId, slot + 1)
    result.manifests.add(player)
    result.slots.add(PlayerSlot(
      player: player.name,
      playerName: playerName,
      containerName: playerContainerName(player, port, gameId, slot + 1)
    ))

proc startTournamentGame(
  config: TournamentConfig,
  game: GameManifest,
  players: openArray[PlayerManifest]
) =
  ## Starts one tournament game and its player containers.
  ensureReplayDir()
  let
    gameId = nextGameId()
    port = findOpenPort()
    created = getTime().toUnix()
    name = gameContainerName(port, gameId)
    chosen = choosePlayers(players, config.playersPerGame, gameId, port)
    replay = replayName(name)
    results = resultsName(name)
  var run = GameRun(
    id: gameId,
    name: name,
    port: port,
    created: created,
    replay: replay,
    results: results,
    slots: chosen.slots
  )
  let gameConfig = defaultConfigJson(game, config.playersPerGame, run.slots)
  var launched: seq[string]

  pullImageOnce(runnerImageUri(game.imageUri))
  for player in chosen.manifests:
    pullImageOnce(player.imageUri)

  try:
    for i, slot in run.slots:
      discard requireDocker(playerDockerArgs(
        chosen.manifests[i],
        slot.containerName,
        run,
        slot
      ))
      launched.add(slot.containerName)
    discard requireDocker(gameDockerArgs(game, name, port, run, gameConfig))
    launched.add(name)
    addGameRun(run)
    clearLastError()
  except CatchableError:
    removeContainers(launched)
    raise

proc stopPlayersForStoppedGames(
  games,
  players: openArray[TournamentContainer]
) =
  ## Stops running players attached to games that are no longer running.
  var runningGames: seq[string]
  for game in games:
    if game.status == "running":
      runningGames.add(game.name)
  for player in players:
    if player.status == "running" and player.gameName notin runningGames:
      discard dockerResult(@["stop", player.name])

proc normalDeadExit(container: TournamentContainer): bool =
  ## Returns true for normal exits that do not need debugging.
  if container.exitCode == 0:
    return true
  container.exitCode == 143

proc expiredDeadContainer(
  container: TournamentContainer,
  now: int64
): bool =
  ## Returns true when one dead container is old enough to remove.
  container.status == "exited" and
    container.finished > 0 and
    now - container.finished >= CleanupDeadSeconds and
    container.normalDeadExit()

proc cleanupNormalDeadContainers(
  containers: openArray[TournamentContainer]
): int =
  ## Removes old normally exited tournament containers.
  let now = getTime().toUnix()
  for container in containers:
    if not container.expiredDeadContainer(now):
      continue
    let res = dockerResult(@["rm", container.name])
    if res.code == 0:
      inc result
    else:
      updateLastError(
        "could not remove old container " & container.name & ": " &
          res.output.strip()
      )

proc scoreNumber(items: JsonNode, index: int): float =
  ## Reads one numeric score array value.
  if index >= items.len:
    return 0
  case items[index].kind
  of JInt:
    result = items[index].getInt().float
  of JFloat:
    result = items[index].getFloat()
  else:
    result = 0

proc scoreInt(items: JsonNode, index: int): int =
  ## Reads one integer score array value.
  if index >= items.len:
    return 0
  case items[index].kind
  of JInt:
    result = items[index].getInt()
  of JFloat:
    result = items[index].getFloat().int
  of JBool:
    if items[index].getBool():
      result = 1
  else:
    result = 0

proc scoreString(items: JsonNode, index: int): string =
  ## Reads one string score array value.
  if index < items.len and items[index].kind == JString:
    result = items[index].getStr()

proc scoreBool(items: JsonNode, index: int): bool =
  ## Reads one boolean score array value.
  if index < items.len and items[index].kind == JBool:
    result = items[index].getBool()

proc jsonArray(node: JsonNode, key: string): JsonNode =
  ## Reads one optional JSON array.
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JArray:
    return node[key]
  newJArray()

proc jsonArrayAny(node: JsonNode, keys: openArray[string]): JsonNode =
  ## Reads the first present optional JSON array from several keys.
  for key in keys:
    let items = node.jsonArray(key)
    if items.len > 0:
      return items
  newJArray()

proc parseScores(path: string): seq[ScoreRow] =
  ## Parses one tournament scores file.
  let node = parseJson(readFile(path))
  let
    names = node.jsonArray("names")
    scores = node.jsonArray("scores")
    wins = node.jsonArray("win")
    tasks = node.jsonArray("tasks")
    kills = node.jsonArray("kills")
    imposters = node.jsonArrayAny(["imposters", "imposter"])
    crews = node.jsonArray("crew")
    votePlayers = node.jsonArrayAny(["vote_player", "vote_players"])
    voteSkips = node.jsonArray("vote_skip")
    voteTimeouts = node.jsonArray("vote_timeout")
    rowCount = max(
      max(max(names.len, scores.len), max(wins.len, tasks.len)),
      max(
        max(kills.len, max(imposters.len, crews.len)),
        max(votePlayers.len, max(voteSkips.len, voteTimeouts.len))
      )
    )
  for i in 0 ..< rowCount:
    result.add(ScoreRow(
      name: names.scoreString(i),
      score: scores.scoreNumber(i),
      win: wins.scoreBool(i),
      tasks: tasks.scoreInt(i),
      kills: kills.scoreInt(i),
      imposter: imposters.scoreInt(i),
      crew: crews.scoreInt(i),
      votePlayers: votePlayers.scoreInt(i),
      voteSkip: voteSkips.scoreInt(i),
      voteTimeout: voteTimeouts.scoreInt(i)
    ))

proc scoreFileModified(path: string): int64 =
  ## Returns the score file modification time as a Unix timestamp.
  try:
    result = getLastModificationTime(path).toUnix()
  except OSError:
    result = 0

proc scoreFileCreated(name: string, modified: int64): int64 =
  ## Reads a tournament game creation timestamp from a score file name.
  let
    suffix = ".scores.json"
    base =
      if name.endsWith(suffix):
        name[0 ..< name.len - suffix.len]
      else:
        name
    parts = base.split('_')
  if parts.len >= 5 and parts[0] == "tournament" and parts[1] == "game":
    let created = parseInt64Safe(parts[3])
    if created > 0:
      return created
  modified

proc listScoreFiles(): seq[ScoreFile] =
  ## Lists tournament score files in game order.
  if not dirExists(replayDir()):
    return
  for path in walkFiles(replayDir() / "tournament_game_*.scores.json"):
    let
      name = extractFilename(path)
      modified = scoreFileModified(path)
    result.add(ScoreFile(
      path: path,
      name: name,
      created: scoreFileCreated(name, modified),
      modified: modified
    ))
  result.sort(proc(a, b: ScoreFile): int =
    result = cmp(a.created, b.created)
    if result != 0:
      return
    result = cmp(a.modified, b.modified)
    if result != 0:
      return
    result = cmp(a.name, b.name)
  )

proc policyForScoreName(
  players: openArray[PlayerManifest],
  scoreName: string
): string =
  ## Maps one score row name back to a player manifest name.
  for player in players:
    if scoreName == player.name:
      return player.name
  for player in players:
    if scoreName.startsWith(player.name & "-t") or
        scoreName.startsWith(player.name & "-"):
      if player.name.len > result.len:
        result = player.name

proc newStatsTable(
  players: openArray[PlayerManifest]
): Table[string, PlayerStats] =
  ## Builds an empty stats table for selected tournament policies.
  for player in players:
    if not result.hasKey(player.name):
      result[player.name] = PlayerStats(
        name: player.name,
        author: player.author,
        imageUri: player.imageUri,
        mmr: DefaultMmr
      )

proc updateMmr(
  stats: var Table[string, PlayerStats],
  outcomes: Table[string, GameOutcome]
) =
  ## Moves small MMR amounts from losing policies to winning policies.
  var
    winners: seq[string]
    losers: seq[string]
  for player, outcome in outcomes.pairs:
    for _ in 0 ..< outcome.wins:
      winners.add(player)
    for _ in 0 ..< outcome.losses:
      losers.add(player)
  if winners.len == 0 or losers.len == 0:
    return

  let pairScale = MmrK / float(winners.len * losers.len)
  var deltas: Table[string, float]
  for winner in winners:
    for loser in losers:
      if winner == loser:
        continue
      if not stats.hasKey(winner) or not stats.hasKey(loser):
        continue
      let
        winnerMmr = stats[winner].mmr
        loserMmr = stats[loser].mmr
        expectedWinner = 1.0 / (
          1.0 + pow(10.0, (loserMmr - winnerMmr) / 400.0)
        )
        transfer = pairScale * (1.0 - expectedWinner)
      deltas[winner] = deltas.getOrDefault(winner) + transfer
      deltas[loser] = deltas.getOrDefault(loser) - transfer

  for player, delta in deltas.pairs:
    if stats.hasKey(player):
      var row = stats[player]
      row.mmr = max(MinMmr, row.mmr + delta)
      stats[player] = row

proc applyScoreRows(
  stats: var Table[string, PlayerStats],
  players: openArray[PlayerManifest],
  rows: openArray[ScoreRow]
) =
  ## Adds one completed score file to aggregate stats and MMR.
  var outcomes: Table[string, GameOutcome]
  for score in rows:
    let player = policyForScoreName(players, score.name)
    if player.len == 0 or not stats.hasKey(player):
      continue

    var row = stats[player]
    inc row.games
    row.scoreSum += score.score
    row.tasksSum += score.tasks
    row.killsSum += score.kills
    row.imposterSum += score.imposter
    row.crewSum += score.crew
    row.votePlayersSum += score.votePlayers
    row.voteSkipSum += score.voteSkip
    row.voteTimeoutSum += score.voteTimeout
    if score.win:
      inc row.wins
    stats[player] = row

    var outcome = outcomes.getOrDefault(player)
    if score.win:
      inc outcome.wins
    else:
      inc outcome.losses
    outcomes[player] = outcome

  updateMmr(stats, outcomes)

proc rebuildStatsTable(
  players: openArray[PlayerManifest]
): Table[string, PlayerStats] =
  ## Rebuilds tournament stats by replaying score files oldest to newest.
  result = newStatsTable(players)
  for scoreFile in listScoreFiles():
    try:
      applyScoreRows(result, players, parseScores(scoreFile.path))
    except CatchableError as e:
      updateLastError(
        "could not read scores file " & scoreFile.name & ": " & e.msg
      )

proc snapshotStats(config: TournamentConfig): seq[PlayerStats] =
  ## Returns current stats rebuilt from durable tournament score files.
  let
    gameManifest = readGameManifest(config.manifestPath)
    playerManifests = selectedPlayers(config, gameManifest)
    stats = rebuildStatsTable(playerManifests)
  for _, player in stats.pairs:
    result.add(player)
  result.sort(proc(a, b: PlayerStats): int =
    result = cmp(b.mmr, a.mmr)
    if result != 0:
      return
    result = cmp(a.name, b.name)
  )

proc activeGameCount(games: openArray[TournamentContainer]): int =
  ## Counts game containers that are still running.
  for game in games:
    if game.status == "running":
      inc result

proc tournamentTick(config: TournamentConfig) =
  ## Advances the tournament scheduler once.
  let
    gameManifest = readGameManifest(config.manifestPath)
    playerManifests = selectedPlayers(config, gameManifest)
  var
    containers = listContainers()
    games = listGames(containers)
    players = listPlayers(containers)
  stopPlayersForStoppedGames(games, players)
  if cleanupNormalDeadContainers(containers) > 0:
    containers = listContainers()
    games = listGames(containers)
  var active = activeGameCount(games)
  while active < config.activeGames:
    startTournamentGame(config, gameManifest, playerManifests)
    inc active

proc schedulerLoop(config: TournamentConfig) {.thread.} =
  ## Runs the tournament scheduler loop.
  while true:
    {.gcsafe.}:
      try:
        tournamentTick(config)
      except CatchableError as e:
        updateLastError(e.msg)
    sleep(max(250, config.tickMillis))

proc snapshotRuns(): tuple[started: int64, lastError: string] =
  ## Returns small scheduler state for rendering.
  acquire(state.lock)
  try:
    result.started = state.started
    result.lastError = state.lastError
  finally:
    release(state.lock)

proc healthUrl(container: TournamentContainer): string =
  ## Builds the local health URL for one game container.
  "http://127.0.0.1:" & $container.port & HealthPath

proc gameHealthy(container: TournamentContainer): bool =
  ## Returns true when a game container health endpoint answers healthy.
  if container.status != "running" or container.port <= 0:
    return false
  var client = newHttpClient(timeout = 300)
  try:
    result = client.getContent(healthUrl(container)).strip() == "healthy"
  except CatchableError:
    result = false
  finally:
    client.close()

proc logUrl(name: string): string =
  ## Builds a log viewer URL for one container.
  LogsPath & "?name=" & cleanContainerName(name)

proc renderContainerCheckbox(name: string): string =
  ## Renders one bulk action checkbox for a managed container.
  let safeName = cleanContainerName(name)
  "<input class=\"bulkCheck\" type=\"checkbox\" name=\"name\" value=\"" &
    esc(safeName) & "\" form=\"bulkForm\" title=\"Select " &
    esc(safeName) & "\">"

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
  game: TournamentContainer
): string =
  ## Builds a browser websocket URL for a tournament game.
  "ws://" & request.hostName() & ":" & $game.port & "/global"

proc gameUrl(request: Request, game: TournamentContainer): string =
  ## Builds a browser URL for the shared global client page.
  "http://" & request.hostHeader() & ClientPath & "global.html" &
    "?address=" & encodeUrlComponent(gameWebSocketUrl(request, game))

proc scoreUrl(request: Request, resultName: string): string =
  ## Builds a CoGame server score page URL for one score file.
  "http://" & request.hostName() & ":" & $gamesServerPort() &
    ScoresPath & "?name=" & encodeUrlComponent(cleanFileName(resultName))

proc scoreFileExists(resultName: string): bool =
  ## Returns true when a shared score file exists.
  fileExists(replayPath(cleanFileName(resultName)))

proc renderBulkControls(): string =
  ## Renders the bulk container action controls.
  renderFragment:
    form ".bulkBar":
      id "bulkForm"
      action BulkStopPath
      tmethod "post"
      button ".button":
        ttype "submit"
        formaction BulkStopPath
        say "Stop"
      say " "
      button ".button":
        ttype "submit"
        formaction BulkRemovePath
        onclick "return confirmRemoveContainers()"
        say "Remove"

proc renderContainersTable(
  request: Request,
  games,
  players: seq[TournamentContainer]
): string =
  ## Renders game and player Docker containers.
  renderFragment:
    table:
      tr:
        th ".head selectCell":
          say ""
        th ".head":
          say "Game"
        th ".head":
          say "Status"
        th ".head":
          say "Port"
        th ".head":
          say "Join"
        th ".head":
          say "Bots"
        th ".head":
          say "Created"
        th ".head":
          say "Scores"
        th ".head":
          say "Logs"
      if games.len == 0 and players.len == 0:
        tr:
          td ".row1 center":
            colspan "9"
            say "No tournament containers yet."
      var index = 0
      for game in games:
        let
          rowClass = if index mod 2 == 0: ".row1" else: ".row2"
          healthy = gameHealthy(game)
        tr:
          td rowClass & " selectCell":
            say renderContainerCheckbox(game.name)
          td rowClass:
            say esc(game.name)
          td rowClass & " nowrap":
            if healthy:
              span ".ok":
                say "healthy"
            else:
              say esc(game.status)
          td rowClass & " center":
            if game.port > 0:
              say $game.port
            else:
              say "-"
          td rowClass & " nowrap":
            if healthy:
              a:
                href gameUrl(request, game)
                target "_blank"
                say "global"
            elif game.status == "running":
              say "starting"
            else:
              say "offline"
          td rowClass:
            say ""
          td rowClass & " nowrap":
            say fmtCreated(game.created)
          td rowClass & " nowrap":
            if scoreFileExists(game.results):
              a:
                href scoreUrl(request, game.results)
                target "_blank"
                say "scores"
            elif game.status == "running":
              say "pending"
            else:
              say "-"
          td rowClass & " center":
            a:
              href logUrl(game.name)
              target "_blank"
              say "logs"
        for player in players:
          if player.gameName != game.name:
            continue
          tr:
            td rowClass & " selectCell":
              say renderContainerCheckbox(player.name)
            td rowClass:
              say ""
            td rowClass & " nowrap":
              say esc(player.status)
            td rowClass:
              say ""
            td rowClass:
              say ""
            td rowClass & " nowrap":
              say esc(player.player)
            td rowClass:
              say fmtCreated(player.created)
            td rowClass:
              say "-"
            td rowClass & " center":
              a:
                href logUrl(player.name)
                target "_blank"
                say "logs"
        inc index

proc renderStatsTable(stats: seq[PlayerStats]): string =
  ## Renders aggregate tournament player stats.
  renderFragment:
    table:
      tr:
        th ".head":
          say "Player"
        th ".head":
          say "Rank"
        th ".head":
          say "Games"
        th ".head":
          say "Wins"
        th ".head":
          say "Score sum"
        th ".head":
          say "Tasks"
        th ".head":
          say "Kills"
        th ".head":
          say "Imposters"
        th ".head":
          say "Crew"
        th ".head":
          say "Vote player"
        th ".head":
          say "Vote skip"
        th ".head":
          say "Vote timeout"
        th ".head":
          say "MMR"
        th ".head":
          say "Image"
      if stats.len == 0:
        tr:
          td ".row1 center":
            colspan "14"
            say "No player stats yet."
      for i, player in stats:
        let rowClass = if i mod 2 == 0: ".row1" else: ".row2"
        tr:
          td rowClass:
            say esc(player.name)
          td rowClass & " center":
            say $(i + 1)
          td rowClass & " center":
            say $player.games
          td rowClass & " center":
            say $player.wins
          td rowClass & " right nowrap":
            say fmtFloat(player.scoreSum)
          td rowClass & " center":
            say $player.tasksSum
          td rowClass & " center":
            say $player.killsSum
          td rowClass & " center":
            say $player.imposterSum
          td rowClass & " center":
            say $player.crewSum
          td rowClass & " center":
            say $player.votePlayersSum
          td rowClass & " center":
            say $player.voteSkipSum
          td rowClass & " center":
            say $player.voteTimeoutSum
          td rowClass & " right nowrap":
            say fmtFloat(player.mmr)
          td rowClass:
            say esc(player.imageUri)

proc renderPage(request: Request, config: TournamentConfig): string =
  ## Renders the tournament server page.
  let
    containers = listContainers()
    games = listGames(containers)
    players = listPlayers(containers)
    stats = snapshotStats(config)
    snapshot = snapshotRuns()
    running = activeGameCount(games)
    bulkHtml = renderBulkControls()
    containersHtml = renderContainersTable(request, games, players)
    statsHtml = renderStatsTable(stats)
  render:
    html:
      head:
        title:
          say "CoGame Tournament Server"
        say "<style>"
        say PageCss
        say "</style>"
        say BulkScript
        say PlayerTableScript
      body:
        tdiv ".page":
          table:
            tr:
              td ".row2":
                h1 ".title":
                  say "CoGame Tournament Server"
                p ".small":
                  say "Automatic CoGame rounds and ratings."
              td ".row2 right small":
                a:
                  href "/"
                  say "Refresh"
          p ".small":
            say "Active games: "
            say $running
            say " / "
            say $config.activeGames
            say ". Players per game: "
            say $config.playersPerGame
            say ". Tick: "
            say $config.tickMillis
            say " ms."
          p ".small":
            say "Manifest: "
            say esc(config.manifestPath)
          if snapshot.lastError.len > 0:
            p ".small bad":
              say esc(snapshot.lastError)
          table:
            tr:
              td ".cat":
                say "Players"
          tdiv:
            id "playerTable"
            say statsHtml
          p ".small":
            say " "
          say bulkHtml
          table:
            tr:
              td ".cat":
                say "Tournament containers"
          say containersHtml
          p ".footer small":
            say "Started: "
            say fmtCreated(snapshot.started)
            say ". Docker label: "
            say ServerLabel
            say "."

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
  ## Sends a POST/redirect/get response.
  request.respond(303, redirectHeaders(location), "")

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

proc clientRoot(): string =
  ## Returns the shared client asset directory.
  parentDir(parentDir(currentSourcePath())) / "clients"

proc clientAsset(path: string): string =
  ## Maps one public client route to a local asset path.
  case path
  of "/client/global.html", "/client/global_client.html":
    clientRoot() / "global_client.html"
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

proc indexHandler(request: Request, config: TournamentConfig) =
  ## Handles the index route.
  request.respondHtml(200, renderPage(request, config))

proc playersTableHandler(request: Request, config: TournamentConfig) =
  ## Handles the player stats table fragment route.
  request.respondHtml(200, renderStatsTable(snapshotStats(config)))

proc logsHandler(request: Request) =
  ## Handles Docker log viewer requests.
  let name = queryValue(request, "name")
  if name.len == 0:
    raise newException(TournamentError, "missing container name")
  request.respondHtml(200, renderLogsPage(name, containerLogs(name)))

proc bulkContainerNames(form: seq[(string, string)]): seq[string] =
  ## Reads selected tournament container names from a bulk action form.
  for (key, value) in form:
    if key != "name":
      continue
    let name = cleanContainerName(value)
    if name.len == 0 or name != value:
      raise newException(TournamentError, "invalid container name")
    if name notin result:
      result.add(name)

proc bulkStopHandler(request: Request) =
  ## Handles selected container stop requests.
  let names = bulkContainerNames(parseFormBody(request))
  if names.len == 0:
    request.respondRedirect("/")
    return
  for name in names:
    stopManagedContainer(name)
  request.respondRedirect("/")

proc bulkRemoveHandler(request: Request) =
  ## Handles selected container remove requests.
  let names = bulkContainerNames(parseFormBody(request))
  if names.len == 0:
    request.respondRedirect("/")
    return
  var removed: seq[string]
  for name in names:
    if name in removed:
      continue
    for removedName in removeManagedContainer(name):
      if removedName notin removed:
        removed.add(removedName)
  request.respondRedirect("/")

proc clientHandler(request: Request) =
  ## Handles shared global client asset requests.
  let path = clientAsset(request.path)
  if path.len == 0 or not fileExists(path):
    request.respondHtml(404, "client asset not found")
    return
  request.respondContent(
    200,
    clientContentType(path),
    readFile(path)
  )

proc errorHandler(request: Request, config: TournamentConfig, e: ref Exception) =
  ## Handles expected and unexpected server errors.
  discard config
  stderr.writeLine("[tournament_server] ", e.msg)
  let body = render:
    html:
      head:
        title:
          say "Tournament Error"
        say "<style>"
        say PageCss
        say "</style>"
      body:
        tdiv ".page":
          table:
            tr:
              td ".row2":
                h1 ".title":
                  say "Tournament Error"
                p ".small bad":
                  say esc(e.msg)
              td ".row2 right small":
                a:
                  href "/"
                  say "Back"
  request.respondHtml(500, body)

proc httpHandlerUnsafe(request: Request, config: TournamentConfig) =
  ## Routes all HTTP requests.
  try:
    if request.path == "/" and request.httpMethod == "GET":
      request.indexHandler(config)
    elif request.path == PlayersTablePath and request.httpMethod == "GET":
      request.playersTableHandler(config)
    elif request.path == LogsPath and request.httpMethod == "GET":
      request.logsHandler()
    elif request.path.startsWith(ClientPath) and request.httpMethod == "GET":
      request.clientHandler()
    elif request.path == BulkStopPath and request.httpMethod == "POST":
      request.bulkStopHandler()
    elif request.path == BulkRemovePath and request.httpMethod == "POST":
      request.bulkRemoveHandler()
    else:
      request.respondHtml(404, renderPage(request, config))
  except TournamentError as e:
    request.errorHandler(config, e)
  except Exception as e:
    request.errorHandler(config, e)

proc makeHandler(config: TournamentConfig): RequestHandler =
  ## Builds a mummy request handler bound to server config.
  result = proc(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      request.httpHandlerUnsafe(config)

proc initState() =
  ## Initializes tournament shared state.
  initLock(state.lock)
  state.nextGameId = 0
  state.started = getTime().toUnix()
  state.lastError = ""
  state.pulledImages = @[]
  state.games = @[]

proc defaultConfig(): TournamentConfig =
  ## Returns the default tournament server config.
  TournamentConfig(
    address: DefaultHost,
    port: DefaultPort,
    activeGames: DefaultActiveGames,
    playersPerGame: DefaultPlayersPerGame,
    tickMillis: DefaultTickMillis,
    manifestPath: manifestPath(),
    playerList: envValue(PlayerListEnv, "")
  )

proc parseArgs(): TournamentConfig =
  ## Parses command-line options.
  result = defaultConfig()
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        result.address = val
      of "port":
        result.port = parseIntSafe(val)
      of "games":
        result.activeGames = max(0, parseIntSafe(val))
      of "players-per-game":
        result.playersPerGame = max(1, parseIntSafe(val))
      of "tick-ms":
        result.tickMillis = max(250, parseIntSafe(val))
      of "manifest":
        result.manifestPath = val
      of "players":
        result.playerList = val
      else:
        discard
    else:
      discard

proc runServer(config: TournamentConfig) =
  ## Runs the tournament web server and scheduler.
  randomize()
  initState()
  createThread(scheduler, schedulerLoop, config)
  let server = newServer(makeHandler(config), workerThreads = 1)
  echo "Tournament server listening on http://", config.address, ":", config.port
  echo "Tournament active games: ", config.activeGames
  echo "Tournament players per game: ", config.playersPerGame
  server.serve(Port(config.port), config.address)

when isMainModule:
  runServer(parseArgs())

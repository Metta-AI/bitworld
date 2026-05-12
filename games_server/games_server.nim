import
  std/[
    algorithm, json, net, os, osproc, parseopt, strutils, sysrand, tables, times
  ],
  mummy,
  taggy,
  cogame_validator,
  ecs_backend

from std/httpclient import close, getContent, newHttpClient

const
  DefaultHost = "0.0.0.0"
  DefaultPort = 2080
  MaxBotLaunchCount = 16
  DockerBinEnv = "GAMES_SERVER_DOCKER"
  DockerModeEnv = "GAMES_SERVER_MODE"
  ReplayDirEnv = "GAMES_SERVER_REPLAY_DIR"
  WorkspaceRootEnv = "GAMES_SERVER_WORKSPACE_ROOT"
  DefaultDockerMode = "release"
  GameContainerPort = 8080
  ReplayPathPrefix = "/replays/"
  ReplayPlayPath = "/replays/play"
  ScoresPath = "/scores"
  LogsPath = "/logs"
  BulkStopPath = "/containers/stop"
  BulkRemovePath = "/containers/remove"
  BulkGridPath = "/containers/grid"
  HealthPath = "/healthz"
  ClientPath = "/client/"
  CreatePath = "/games/create"
  ValidationPath = "/games/validate"
  ManifestViewPath = "/manifests"
  CogameReplayEnv = "COGAME_SAVE_REPLAY_PATH"
  CogameResultsEnv = "COGAME_SAVE_RESULTS_PATH"
  CogamesEngineWsEnv = "COGAMES_ENGINE_WS_URL"
  ManifestPathEnv = "GAMES_SERVER_MANIFEST"
  CoworldManifestName = "coworld_manifest.json"
  CoplayerManifestName = "coplayer_manifest.json"
  AiKeyEnvNames = ["CLAUDE_KEY", "GEMINI_KEY", "OPENAI_KEY", "XAI_KEY"]
  ReplayUploadPath = "/api/replay/upload"
  ReplayScoresUploadPath = "/api/replay/upload/scores"
  ReplayDownloadPath = "/api/replay/download/"
  GamesServerUrlEnv = "GAMES_SERVER_URL"
  UploadTokenTtlSeconds = 600
  UploadTokenBytes = 32
  ServerLabelKey = "bitworld.games_server"
  ServerLabelValue = "among_them"
  BotLabelValue = "among_them_bot"
  ServerLabel = ServerLabelKey & "=" & ServerLabelValue
  BotLabel = ServerLabelKey & "=" & BotLabelValue
  PortLabel = "bitworld.games_server.port"
  CreatedLabel = "bitworld.games_server.created"
  ReplayLabel = "bitworld.games_server.replay"
  KindLabel = "bitworld.games_server.kind"
  GameManifestLabel = "bitworld.games_server.manifest"
  GameNameLabel = "bitworld.games_server.game_name"
  BotGameLabel = "bitworld.games_server.game"
  BotKindLabel = "bitworld.games_server.bot"
  LiveKind = "game"
  ReplayKind = "replay"
  BotHost = "host.docker.internal"
  PlayerWebSocketPath = "/player"
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
.message {
  white-space: pre-wrap;
}
.pass {
  color: #006000;
  font-weight: 700;
}
.fail {
  color: #a00000;
  font-weight: 700;
}
.skip {
  color: #606060;
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
.gridPage {
  width: 100vw;
  height: 100vh;
  margin: 0;
  padding: 0;
  border: 0;
  background: #000;
  overflow: hidden;
}
.viewerGrid {
  width: 100vw;
  height: 100vh;
  display: grid;
  gap: 0;
  padding: 0;
  background: #000;
}
.viewerCell {
  min-width: 0;
  min-height: 0;
  overflow: hidden;
  background: #000;
}
.viewerFrame {
  width: 100%;
  height: 100%;
  border: 0;
  display: block;
  background: #fff;
}
.gridEmpty {
  width: 100vw;
  height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #000;
  color: #eeeeff;
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

# TODO: Task TTL / orphan cleanup.
# ECS has no built-in task TTL. If a game container hangs or games_server
# restarts, tasks stay running with a public IP — that's attack surface
# sitting in the VPC indefinitely. Options:
#   1. Generous hard TTL (e.g. 24h) as a safety net for abandoned tasks.
#   2. Periodic sweep: stop tasks with no active websocket connections
#      for >30 minutes (never kills a live game with spectators).
# Either way, legitimate games should never hit the limit. This is about
# cleaning up forgotten containers, not restricting game length.

type
  GamesServerError = object of CatchableError

  CommandResult = object
    output: string
    code: int

  ContainerKind = enum
    LiveGame
    ReplayServer

  GameContainer = object
    name: string
    status: string
    port: int
    created: int64
    replay: string
    kind: ContainerKind
    manifestKey: string
    cogameName: string
    ip: string

  BotContainer = object
    name: string
    status: string
    game: string
    bot: string
    created: int64

  ReplayFile = object
    name: string
    size: int64
    modified: int64

  UploadToken = object
    replayName: string
    used: bool
    scoresUploaded: bool
    expiresAt: float

  GameManifest = object
    key: string
    path: string
    name: string
    author: string
    imageUri: string
    binary: string
    playerProtocol: string

  CoplayerManifest = object
    key: string
    path: string
    name: string
    author: string
    imageUri: string
    binary: string
    arch: string  # "X86_64" or "ARM64"
    games: seq[string]

  BotLaunchCount = object
    bot: CoplayerManifest
    count: int

  ScoreRow = object
    name: string
    score: string
    win: bool
    tasks: string
    kills: string
    imposter: string
    crew: string
    votePlayers: string
    voteSkip: string
    voteTimeout: string

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

proc dockerMode(): string =
  ## Returns the container launch mode.
  envValue(DockerModeEnv, DefaultDockerMode).toLowerAscii()

proc defaultWorkspaceRoot(): string =
  ## Returns the host workspace root mounted by runner containers.
  parentDir(parentDir(parentDir(currentSourcePath())))

proc workspaceRoot(): string =
  ## Returns the configured host workspace root.
  envValue(WorkspaceRootEnv, defaultWorkspaceRoot())

# TODO: Replace local disk storage with S3.
# Currently replays land on the local filesystem. When games_server moves
# to EC2, local disk works but is ephemeral (lost if instance terminates).
# Migrate to S3 (bucket and policy are sketched in infra/security.tf):
#   - Upload handler writes to S3 instead of replayDir()
#   - Dashboard serves replays via presigned GET URLs
#   - Replay playback containers download from S3 at launch
#   - EC2 instance role gets s3:PutObject + s3:GetObject on the bucket

proc defaultReplayDir(): string =
  ## Returns the default host replay directory.
  parentDir(currentSourcePath()) / "replays"

proc replayDir(): string =
  ## Returns the configured host replay directory.
  envValue(ReplayDirEnv, defaultReplayDir())

proc gamesRoot(): string =
  ## Returns the local Bitworld games root.
  parentDir(parentDir(currentSourcePath()))

proc defaultManifestPath(): string =
  ## Returns the default Coworld manifest path.
  gamesRoot() / "among_them" / CoworldManifestName

proc manifestPath(): string =
  ## Returns the configured Coworld manifest path.
  envValue(ManifestPathEnv, defaultManifestPath())

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

proc requireManifestString(node: JsonNode, key, path: string): string =
  ## Reads one required manifest string.
  result = node.manifestString(key, "")
  if result.len == 0:
    raise newException(GamesServerError, path & " missing " & key)

proc manifestObject(node: JsonNode, key: string): JsonNode =
  ## Reads one optional object field from a manifest.
  if node.kind == JObject and node.hasKey(key) and
      node[key].kind == JObject:
    return node[key]

proc manifestImage(node: JsonNode): string =
  ## Reads a game or player image from a Coworld manifest node.
  let runnable = node.manifestObject("runnable")
  if not runnable.isNil:
    result = runnable.manifestString("image", "")
  if result.len == 0:
    result = node.manifestString("image", "")
  if result.len == 0:
    result = node.manifestString("image_uri", "")

proc manifestProtocol(node: JsonNode, key: string): string =
  ## Reads one protocol spec path from a Coworld manifest.
  if node.kind != JObject or not node.hasKey("protocols"):
    return
  let protocols = node["protocols"]
  if protocols.kind == JObject and protocols.hasKey(key) and
      protocols[key].kind == JString:
    return protocols[key].getStr()

proc defaultManifestName(path: string): string =
  ## Returns a display name for a manifest path.
  splitPath(parentDir(path)).tail

proc readGameManifest(path: string): GameManifest =
  ## Reads one Coworld manifest summary from disk.
  try:
    let
      manifest = parseJson(readFile(path))
      game = manifest.manifestObject("game")
    if game.isNil:
      raise newException(GamesServerError, "coworld missing game")
    let
      name = game.requireManifestString("name", "coworld.game")
      author = game.manifestString(
        "author",
        game.manifestString("owner", "-")
      )
      image = game.manifestImage()
    if image.len == 0:
      raise newException(GamesServerError, "coworld.game missing image")
    result = GameManifest(
      key: manifestKey(path),
      path: path,
      name: name,
      author: author,
      imageUri: image,
      binary: game.manifestString("binary", "/bin/" & name),
      playerProtocol: game.manifestProtocol("player")
    )
  except CatchableError as e:
    raise newException(
      GamesServerError,
      "could not read Coworld manifest " & path & ": " & e.msg
    )

proc manifestStringArray(node: JsonNode, key: string): seq[string] =
  ## Reads one top-level string array from a manifest.
  if node.kind != JObject or not node.hasKey(key) or
      node[key].kind != JArray:
    return
  for item in node[key].items:
    if item.kind == JString:
      result.add(item.getStr())

proc readCoplayerManifest(path: string): CoplayerManifest =
  ## Reads one CoPlayer manifest summary from disk.
  try:
    let
      manifest = parseJson(readFile(path))
      name = manifest.manifestString(
        "name",
        defaultManifestName(path)
      )
    result = CoplayerManifest(
      key: manifestKey(path),
      path: path,
      name: name,
      author: manifest.manifestString("author", "-"),
      imageUri: manifest.manifestString("image_uri", ""),
      binary: manifest.manifestString("binary", "/bin/" & name),
      arch: manifest.manifestString("arch", "X86_64"),
      games: manifest.manifestStringArray("games")
    )
  except CatchableError as e:
    raise newException(
      GamesServerError,
      "could not read CoPlayer manifest " & path & ": " & e.msg
    )

proc readCoworldPlayers(path: string): seq[CoplayerManifest] =
  ## Reads CoPlayer entries embedded in one Coworld manifest.
  try:
    let
      manifest = parseJson(readFile(path))
      game = readGameManifest(path)
    if manifest.kind != JObject or not manifest.hasKey("player") or
        manifest["player"].kind != JArray:
      return
    for player in manifest["player"]:
      if player.kind != JObject:
        continue
      let id = player.manifestString(
        "id",
        player.manifestString("name", "")
      )
      if id.len == 0:
        continue
      result.add(CoplayerManifest(
        key: manifestKey(path) & "#player/" & id,
        path: path,
        name: id,
        author: player.manifestString(
          "author",
          player.manifestString("owner", "-")
        ),
        imageUri: player.manifestImage(),
        binary: player.manifestString("binary", "/bin/" & id),
        arch: player.manifestString("arch", "X86_64"),
        games: @[game.name]
      ))
  except CatchableError as e:
    raise newException(
      GamesServerError,
      "could not read Coworld players " & path & ": " & e.msg
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

proc listGameManifests(): seq[GameManifest] =
  ## Scans game folders for Coworld manifests.
  var paths: seq[string]
  for dir in walkDirs(gamesRoot() / "*"):
    paths.addManifestPath(dir / CoworldManifestName)
  paths.addManifestPath(manifestPath())
  paths.sort(proc(a, b: string): int = cmp(manifestKey(a), manifestKey(b)))
  for path in paths:
    try:
      result.add(readGameManifest(path))
    except GamesServerError as e:
      echo "Skipping Coworld manifest ", path, ": ", e.msg
  if result.len == 0:
    raise newException(GamesServerError, "no Coworld manifests found")

proc listCoplayerManifests(): seq[CoplayerManifest] =
  ## Scans game folders for CoPlayer manifests.
  var paths: seq[string]
  for dir in walkDirs(gamesRoot() / "*"):
    let coworldPath = dir / CoworldManifestName
    if fileExists(coworldPath):
      try:
        for player in readCoworldPlayers(coworldPath):
          result.add(player)
      except GamesServerError as e:
        echo "Skipping Coworld players ", coworldPath, ": ", e.msg
    for path in walkFiles(dir / "players" / "*" / CoplayerManifestName):
      paths.addManifestPath(path)
  paths.sort(proc(a, b: string): int = cmp(manifestKey(a), manifestKey(b)))
  for path in paths:
    result.add(readCoplayerManifest(path))

proc findGameManifest(key: string): GameManifest =
  ## Finds a scanned Coworld manifest by key.
  let
    manifests = listGameManifests()
    cleanKey = key.strip()
  if cleanKey.len == 0:
    return manifests[0]
  for manifest in manifests:
    if manifest.key == cleanKey or manifest.path == cleanKey:
      return manifest
  raise newException(
    GamesServerError,
    "unknown Coworld manifest: " & cleanKey
  )

proc supportsGame(bot: CoplayerManifest, gameName: string): bool =
  ## Returns true when a CoPlayer manifest supports a game.
  for supported in bot.games:
    if supported == gameName:
      return true

proc supportedCoplayerManifests(gameName: string): seq[CoplayerManifest] =
  ## Lists CoPlayer manifests that support one game.
  for bot in listCoplayerManifests():
    if bot.supportsGame(gameName):
      var exists = false
      for existing in result:
        if existing.name == bot.name:
          exists = true
          break
      if not exists:
        result.add(bot)
  result.sort(proc(a, b: CoplayerManifest): int = cmp(a.name, b.name))

proc findCoplayerManifest(
  gameName,
  botKey: string
): CoplayerManifest =
  ## Finds a supported CoPlayer manifest by name or key.
  let cleanKey = botKey.strip()
  for bot in supportedCoplayerManifests(gameName):
    if bot.name == cleanKey or bot.key == cleanKey:
      return bot
    if cleanKey == "ivotealot" and bot.name == "ivotewell":
      return bot
  raise newException(
    GamesServerError,
    "unknown CoPlayer manifest: " & cleanKey
  )

proc manifestUrl(manifest: GameManifest): string =
  ## Builds a raw manifest viewer URL.
  ManifestViewPath & "?path=" & encodeUrlComponent(manifest.key)

proc createUrl(manifest: GameManifest): string =
  ## Builds a create-game URL for one manifest.
  CreatePath & "?manifest=" & encodeUrlComponent(manifest.key)

proc validationStatusText(status: CriterionStatus): string =
  ## Returns the display label for one validation status.
  case status
  of CriterionPass:
    result = "PASS"
  of CriterionFail:
    result = "FAIL"
  of CriterionSkip:
    result = "SKIP"

proc validationStatusClass(status: CriterionStatus): string =
  ## Returns the CSS class for one validation status.
  case status
  of CriterionPass:
    result = "pass"
  of CriterionFail:
    result = "fail"
  of CriterionSkip:
    result = "skip"

proc runValidation(manifest: GameManifest): CertificationResult =
  ## Runs the Coworld validator library for one manifest.
  var config = defaultValidatorConfig()
  config.dockerBin = dockerBin()
  certifyCoworld(manifest.path, config)

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

proc gameDockerImage(manifest: GameManifest): string =
  ## Returns the Docker image for one Coworld manifest.
  manifest.imageUri

proc dockerPackageUrl(imageUri: string): string =
  ## Builds a GitHub Packages URL from a resolved Docker image name.
  let image = imageUri.strip()
  var
    owner = "treeform"
    packageName = stripImageTag(image)
  if packageName.startsWith("ghcr.io/"):
    let parts = packageName.split('/')
    if parts.len >= 3:
      owner = parts[1]
      packageName = parts[2 .. ^1].join("/")
  elif packageName.contains('/'):
    packageName = packageName.split('/')[^1]
  "https://github.com/users/" & owner &
    "/packages/container/package/" & encodeUrlComponent(packageName)

proc coplayerImage(bot: CoplayerManifest): string =
  ## Returns the Docker image for one CoPlayer.
  bot.imageUri

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

var skipPull* = false
var useEcs* = false
var uploadTokens: Table[string, UploadToken]
var ec2PrivateIp = ""

proc fetchEc2PrivateIp(): string =
  ## Fetches this instance's private IP from EC2 instance metadata (IMDSv1).
  ## Returns "" if not running on EC2. Uses a raw socket with short timeout
  ## to avoid hanging on non-EC2 machines where 169.254.169.254 is unroutable.
  var sock = newSocket()
  defer: sock.close()
  try:
    sock.connect("169.254.169.254", Port(80), timeout = 500)
  except CatchableError:
    return ""
  sock.close()
  let client = newHttpClient(timeout = 2000)
  defer: client.close()
  try:
    result = client.getContent("http://169.254.169.254/latest/meta-data/local-ipv4").strip()
  except CatchableError:
    result = ""

proc buildLocalImages() =
  ## Builds native Docker images locally using tools/docker_build.nim.
  let
    root = getCurrentDir()
    buildTool = root / "tools" / "docker_build.nim"
  if not fileExists(buildTool):
    echo "Error: ", buildTool, " not found. Run from the repo root."
    quit(1)
  echo "Building local Docker images..."
  let code = execCmd("nim r " & buildTool &
    " --platform:linux/" & hostCPU &
    " among_them nottoodumb ivotewell italkalot")
  if code != 0:
    echo "Error: local image build failed."
    quit(1)
  echo "Local images built successfully."

proc pullDockerImage(image: string) =
  ## Pulls the latest version of one Docker image.
  if skipPull:
    echo "Skipping Docker image pull: ", image
    return
  echo "Pulling latest Docker image: ", image
  let pulled = requireDocker(@["pull", image])
  if pulled.len > 0:
    echo pulled

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

proc renderContainerCheckbox(name: string): string =
  ## Renders one bulk action checkbox for a managed container.
  let safeName = cleanContainerName(name)
  "<input class=\"bulkCheck\" type=\"checkbox\" name=\"name\" value=\"" &
    esc(safeName) & "\" form=\"bulkForm\" title=\"Select " &
    esc(name) & "\">"

proc cleanLabelValue(value: string): string =
  ## Normalizes a Docker label value.
  result = value.strip()
  if result == "<no value>":
    result = ""

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
    result.replay = cleanLabelValue(parts[4])
  if parts.len >= 6:
    result.kind = parseContainerKind(cleanLabelValue(parts[5]), result.name)
  else:
    result.kind = parseContainerKind("", result.name)
  if parts.len >= 7:
    result.cogameName = cleanLabelValue(parts[6])
  if parts.len >= 8:
    result.manifestKey = cleanLabelValue(parts[7])
  if result.cogameName.len == 0 and result.kind == LiveGame:
    result.cogameName = "among_them"

proc inspectGame(name: string): GameContainer =
  ## Reads one managed container from Docker inspect.
  if useEcs:
    let info = ecsInspectGame(name)
    return GameContainer(
      name: info.taskArn,
      status: info.status,
      port: info.port,
      created: info.created,
      replay: info.replay,
      kind: if info.kind == "replay": ReplayServer else: LiveGame,
      manifestKey: info.manifestKey,
      cogameName: info.cogameName,
      ip: info.publicIp,
    )
  let safeName = cleanContainerName(name)
  if safeName.len == 0:
    raise newException(GamesServerError, "missing container name")
  let format =
    "{{.Name}}\t{{.State.Status}}\t" &
    "{{index .Config.Labels \"" & PortLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & CreatedLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & ReplayLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & KindLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & GameNameLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & GameManifestLabel & "\"}}\t" &
    "{{index .Config.Labels \"" & ServerLabelKey & "\"}}"
  let output = requireDocker(@["inspect", "--format", format, safeName])
  let parts = output.split('\t')
  if parts.len < 9 or cleanLabelValue(parts[8]) != ServerLabelValue:
    raise newException(
      GamesServerError,
      "container is not managed by games_server"
    )
  result = splitInspectLine(output)

proc listGames(): seq[GameContainer] =
  ## Lists all containers created by this game server.
  if useEcs:
    for info in ecsListGames():
      result.add(GameContainer(
        name: info.taskArn,
        status: info.status,
        port: info.port,
        created: info.created,
        replay: info.replay,
        kind: if info.kind == "replay": ReplayServer else: LiveGame,
        manifestKey: info.manifestKey,
        cogameName: info.cogameName,
        ip: info.publicIp,
      ))
    return
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
    result.bot = cleanLabelValue(parts[3])
  if parts.len >= 5:
    result.created = parseInt64Safe(parts[4])

proc inspectBot(name: string): BotContainer =
  ## Reads one managed bot container from Docker inspect.
  if useEcs:
    let info = ecsInspectBot(name)
    return BotContainer(
      name: info.taskArn,
      status: info.status,
      game: info.gameTaskArn,
      bot: info.botName,
      created: info.created,
    )
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
  if useEcs:
    for info in ecsListBots():
      result.add(BotContainer(
        name: info.taskArn,
        status: info.status,
        game: info.gameTaskArn,
        bot: info.botName,
        created: info.created,
      ))
    return
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
  if useEcs:
    return ecsContainerLogs(name)
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

proc botCountField(bot: CoplayerManifest): string =
  ## Returns the create-form count field for one CoPlayer.
  cleanContainerName(bot.name) & "Bots"

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

proc gameName(cogameName: string, port: int): string =
  ## Builds a unique Docker container name.
  let cleanName = cleanContainerName(cogameName)
  if cleanName.len > 0:
    cleanName & "_game_" & $port & "_" & $getTime().toUnix()
  else:
    "cogame_game_" & $port & "_" & $getTime().toUnix()

proc replayGameName(cogameName: string, port: int): string =
  ## Builds a unique replay Docker container name.
  let cleanName = cleanContainerName(cogameName)
  if cleanName.len > 0:
    cleanName & "_replay_" & $port & "_" & $getTime().toUnix()
  else:
    "cogame_replay_" & $port & "_" & $getTime().toUnix()

proc gamePrefix(game: GameContainer): string =
  ## Returns the clean game prefix used for child container names.
  result = cleanContainerName(game.cogameName)
  if result.len > 0:
    return
  let
    gameMarker = game.name.find("_game_")
    replayMarker = game.name.find("_replay_")
    marker =
      if gameMarker >= 0:
        gameMarker
      else:
        replayMarker
  if marker > 0:
    result = cleanContainerName(game.name[0 ..< marker])
  if result.len == 0:
    result = "cogame"

proc launchStamp(index: int): string =
  ## Builds a compact unique suffix for batch launches.
  $(int64(epochTime() * 1000)) & "_" & $index

proc botContainerName(
  game: GameContainer,
  bot: CoplayerManifest,
  stamp: string
): string =
  ## Builds a unique bot Docker container name.
  game.gamePrefix() & "_bot_" & cleanContainerName(bot.name) & "_" &
    $game.port & "_" & stamp

proc botPlayerName(
  game: GameContainer,
  bot: CoplayerManifest,
  stamp: string
): string =
  ## Builds a visible in-game name for one bot.
  bot.name & "-" & $game.port & "-" & stamp

proc playerWsUrl(
  host: string,
  port: int,
  playerName: string,
  slot: int,
  token: string
): string =
  ## Builds the sprite player WebSocket URL for one launched bot.
  var query = "name=" & encodeUrlComponent(playerName)
  if slot >= 0:
    query.add("&slot=" & encodeUrlComponent($slot))
  if token.len > 0:
    query.add("&token=" & encodeUrlComponent(token))
  "ws://" & host & ":" & $port & PlayerWebSocketPath & "?" & query

proc replayName(name: string): string =
  ## Builds the replay file name for one game.
  cleanContainerName(name) & ".bitreplay"

proc replayManifest(replay: string): GameManifest =
  ## Infers the Coworld manifest that wrote one replay file.
  let cleanReplay = cleanReplayName(replay)
  for manifest in listGameManifests():
    let prefix = cleanContainerName(manifest.name) & "_game_"
    if cleanReplay.startsWith(prefix):
      return manifest
  findGameManifest("")

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

proc gamesServerUrl(): string =
  ## Returns the URL game containers use to reach this server.
  ## Returns "" in ECS mode when not running on EC2 (no reachable IP).
  result = getEnv(GamesServerUrlEnv)
  if result.len == 0:
    if useEcs:
      if ec2PrivateIp.len > 0:
        result = "http://" & ec2PrivateIp & ":" & $DefaultPort
    else:
      result = "http://host.docker.internal:" & $DefaultPort

proc generateUploadToken(replayName: string): string =
  ## Generates a cryptographic one-time token for replay upload.
  var bytes: array[UploadTokenBytes, byte]
  if not urandom(bytes):
    raise newException(GamesServerError, "could not generate upload token")
  for b in bytes:
    result.add(b.toHex(2).toLowerAscii())
  uploadTokens[result] = UploadToken(
    replayName: replayName,
    used: false,
    scoresUploaded: false,
    expiresAt: epochTime() + float(UploadTokenTtlSeconds),
  )

proc validateUploadToken(request: Request): (string, ptr UploadToken) =
  ## Extracts and validates the Bearer token from the request.
  let authHeader = request.headers["Authorization"]
  if not authHeader.startsWith("Bearer "):
    raise newException(GamesServerError, "missing or invalid authorization")
  let token = authHeader[7 .. ^1].strip()
  if token notin uploadTokens:
    raise newException(GamesServerError, "unknown upload token")
  result = (token, addr uploadTokens[token])
  if result[1].expiresAt < epochTime():
    uploadTokens.del(token)
    raise newException(GamesServerError, "upload token expired")

proc validateReplayFormat(body: string): bool =
  ## Validates BITWORLD magic bytes and format version.
  if body.len < 10:
    return false
  if body[0 ..< 8] != "BITWORLD":
    return false
  let version = uint16(body[8].byte) or (uint16(body[9].byte) shl 8)
  version >= 1'u16 and version <= 3'u16

proc replayUploadHandler(request: Request) =
  ## Handles POST /api/replay/upload — receives replay binary from game containers.
  let (_, entry) = validateUploadToken(request)
  if entry.used:
    request.respond(409, @[("Content-Type", "text/plain")], "replay already uploaded\n")
    return
  entry.used = true
  let body = request.body
  if not validateReplayFormat(body):
    entry.used = false
    request.respond(422, @[("Content-Type", "text/plain")], "invalid replay format\n")
    return
  ensureReplayDir()
  let finalPath = replayPath(cleanReplayName(entry.replayName))
  writeFile(finalPath, body)
  entry.expiresAt = epochTime() + float(UploadTokenTtlSeconds)
  echo "Replay uploaded: ", entry.replayName, " (", body.len, " bytes)"
  request.respond(200, @[("Content-Type", "application/json")],
    """{"status":"ok","replay":""" & "\"" & entry.replayName & "\"}\n")

proc scoresUploadHandler(request: Request) =
  ## Handles POST /api/replay/upload/scores — receives scores JSON.
  let (token, entry) = validateUploadToken(request)
  if not entry.used:
    request.respond(400, @[("Content-Type", "text/plain")], "replay must be uploaded first\n")
    return
  if entry.scoresUploaded:
    request.respond(409, @[("Content-Type", "text/plain")], "scores already uploaded\n")
    return
  let body = request.body
  try:
    discard parseJson(body)
  except JsonParsingError:
    request.respond(422, @[("Content-Type", "text/plain")], "invalid JSON\n")
    return
  ensureReplayDir()
  let scoresFileName = cleanReplayName(scoresName(entry.replayName))
  writeFile(replayPath(scoresFileName), body)
  entry.scoresUploaded = true
  uploadTokens.del(token)
  echo "Scores uploaded: ", scoresFileName, " (", body.len, " bytes)"
  request.respond(200, @[("Content-Type", "application/json")],
    """{"status":"ok","scores":""" & "\"" & scoresFileName & "\"}\n")

proc replayDownloadHandler(request: Request) =
  ## Handles GET /api/replay/download/<name> — serves replay file for playback containers.
  let name = request.path[ReplayDownloadPath.len .. ^1]
  let clean = cleanReplayName(name)
  if clean.len == 0 or not fileExists(replayPath(clean)):
    request.respond(404, @[("Content-Type", "text/plain")], "replay not found\n")
    return
  let body = readFile(replayPath(clean))
  request.respond(200, @[("Content-Type", "application/octet-stream")], body)

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
  form: seq[(string, string)],
  gameName: string
): seq[BotLaunchCount] =
  ## Reads create-form CoPlayer counts.
  var total = 0
  for bot in supportedCoplayerManifests(gameName):
    let count = cleanConfigValue(
      form,
      botCountField(bot),
      0,
      0,
      MaxBotLaunchCount
    )
    if count > 0:
      result.add(BotLaunchCount(bot: bot, count: count))
    total += count
  if total > MaxBotLaunchCount:
    raise newException(
      GamesServerError,
      "cannot start more than " & $MaxBotLaunchCount & " bots"
    )

proc configSchema(manifestInfo: GameManifest): JsonNode =
  ## Reads the config schema from one Coworld manifest.
  try:
    let manifest = parseJson(readFile(manifestInfo.path))
    let game = manifest.manifestObject("game")
    if game.isNil or not game.hasKey("config_schema"):
      raise newException(GamesServerError, "manifest missing game.config_schema")
    result = game["config_schema"]
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

proc optionalScoreArray(node: JsonNode, key: string): JsonNode =
  ## Reads one optional scores array.
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JArray:
    return node[key]
  newJArray()

proc optionalScoreArrayAny(node: JsonNode, keys: openArray[string]): JsonNode =
  ## Reads the first present optional scores array from several keys.
  for key in keys:
    let items = node.optionalScoreArray(key)
    if items.len > 0:
      return items
  newJArray()

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
  kills,
  imposters,
  crews,
  votePlayers,
  voteSkips,
  voteTimeouts: JsonNode
): int =
  ## Returns the longest score array length.
  max(
    max(max(names.len, scores.len), max(wins.len, tasks.len)),
    max(
      max(kills.len, max(imposters.len, crews.len)),
      max(votePlayers.len, max(voteSkips.len, voteTimeouts.len))
    )
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
    imposters = node.optionalScoreArrayAny(["imposters", "imposter"])
    crews = node.optionalScoreArray("crew")
    votePlayers = node.optionalScoreArrayAny(["vote_player", "vote_players"])
    voteSkips = node.optionalScoreArray("vote_skip")
    voteTimeouts = node.optionalScoreArray("vote_timeout")
    rowCount = maxScoreRows(
      names,
      scores,
      wins,
      tasks,
      kills,
      imposters,
      crews,
      votePlayers,
      voteSkips,
      voteTimeouts
    )
  for i in 0 ..< rowCount:
    result.add(ScoreRow(
      name: names.scoreString(i),
      score: scores.scoreString(i),
      win: wins.scoreBool(i),
      tasks: tasks.scoreString(i),
      kills: kills.scoreString(i),
      imposter: imposters.scoreString(i),
      crew: crews.scoreString(i),
      votePlayers: votePlayers.scoreString(i),
      voteSkip: voteSkips.scoreString(i),
      voteTimeout: voteTimeouts.scoreString(i)
    ))

proc configJson(
  form: seq[(string, string)],
  manifestInfo: GameManifest
): string =
  ## Builds the Coworld game config from form values.
  let schema = configSchema(manifestInfo)
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

proc configTokens(config: string): seq[string] =
  ## Reads configured player tokens from one game config JSON object.
  if config.len == 0:
    return
  let node = parseJson(config)
  if node.kind != JObject or not node.hasKey("tokens") or
      node["tokens"].kind != JArray:
    return
  for item in node["tokens"]:
    if item.kind == JString:
      result.add(item.getStr())

proc baseDockerArgs(
  name: string,
  port: int,
  created: int64,
  replay: string,
  kind: ContainerKind,
  saveReplay: bool,
  cogameName,
  manifestKey: string
): seq[string] =
  ## Builds Docker arguments common to every launch mode.
  result = @[
    "run",
    "-d",
    "--init",
    "--add-host=host.docker.internal:host-gateway",
    "--name",
    name,
    "-p",
    $port & ":" & $GameContainerPort,
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
    "--label",
    GameNameLabel & "=" & cogameName,
    "--label",
    GameManifestLabel & "=" & manifestKey,
  ]
  if saveReplay:
    let scores = "/tmp/" & scoresName(replay)
    result.add("-e")
    result.add(CogameReplayEnv & "=" & "/tmp/" & replay)
    result.add("-e")
    result.add(CogameResultsEnv & "=" & scores)
    let token = generateUploadToken(replay)
    let uploadUrl = gamesServerUrl() & ReplayUploadPath
    result.add("-e")
    result.add("REPLAY_UPLOAD_URL=" & uploadUrl)
    result.add("-e")
    result.add("REPLAY_UPLOAD_TOKEN=" & token)
  addAiEnvArgs(result)

proc runnerScript(config: string): string =
  ## Builds the shell command for the local Nim runner image.
  result =
    "mkdir -p /tmp/bitworld-out /tmp/bitworld-nimcache && " &
    "nim r --nimcache:/tmp/bitworld-nimcache " &
    "--outdir:/tmp/bitworld-out among_them.nim " &
    "--address:0.0.0.0 --port:" & $GameContainerPort
  if config.len > 0:
    result.add(" --config:'" & config & "'")

proc dockerRunArgs(
  name: string,
  port: int,
  created: int64,
  replay: string,
  kind: ContainerKind,
  saveReplay: bool,
  config: string,
  image: string,
  binary: string,
  cogameName = "",
  manifestKey = ""
): seq[string] =
  ## Builds Docker arguments for one new CoGame container.
  result = baseDockerArgs(
    name,
    port,
    created,
    replay,
    kind,
    saveReplay,
    cogameName,
    manifestKey
  )
  case dockerMode()
  of "release":
    result.add(image)
    result.add(binary)
    result.add("--address:0.0.0.0")
    result.add("--port:" & $GameContainerPort)
    if config.len > 0:
      result.add("--config:" & config)
  else:
    result.add("-v")
    result.add(workspaceRoot() & ":/workspace:ro")
    result.add("-w")
    result.add("/workspace/bitworld/among_them")
    result.add("-e")
    result.add("HOME=/tmp")
    result.add(image)
    result.add("sh")
    result.add("-lc")
    result.add(runnerScript(config))

proc botRunArgs(
  name: string,
  game: GameContainer,
  bot: CoplayerManifest,
  created: int64,
  stamp: string,
  slot = -1,
  token = ""
): seq[string] =
  ## Builds Docker arguments for one bot container.
  let
    playerName = botPlayerName(game, bot, stamp)
    endpoint = playerWsUrl(BotHost, game.port, playerName, slot, token)
  result = @[
    "run",
    "-d",
    "--init",
    "--add-host=host.docker.internal:host-gateway",
    "--name",
    name,
    "--label",
    BotLabel,
    "--label",
    BotGameLabel & "=" & game.name,
    "--label",
    BotKindLabel & "=" & bot.name,
    "--label",
    CreatedLabel & "=" & $created
  ]
  addAiEnvArgs(result)
  result.add("-e")
  result.add(CogamesEngineWsEnv & "=" & endpoint)
  result.add(coplayerImage(bot))
  result.add(bot.binary)
  result.add("--address:" & BotHost)
  result.add("--port:" & $game.port)
  result.add("--name:" & playerName)
  result.add("--url:" & endpoint)
  if slot >= 0:
    result.add("--slot:" & $slot)
  if token.len > 0:
    result.add("--token:" & token)

proc pullNeededBotImages(counts: seq[BotLaunchCount]) =
  ## Pulls the CoPlayer images requested by a create form.
  for item in counts:
    if item.count > 0:
      pullDockerImage(coplayerImage(item.bot))

proc removeContainers(names: seq[string]) =
  ## Removes containers created during a failed launch.
  for name in names:
    if name.len > 0:
      discard dockerResult(@["rm", "-f", name])

proc startWaitingBots(
  game: GameContainer,
  counts: seq[BotLaunchCount],
  tokens: seq[string],
  launchedNames: var seq[string]
): seq[BotContainer] =
  ## Starts bot containers before their game container exists.
  for item in counts:
    for _ in 0 ..< item.count:
      let
        created = getTime().toUnix()
        slot = launchedNames.len
        token =
          if slot < tokens.len:
            tokens[slot]
          else:
            ""
        stamp = launchStamp(launchedNames.len + 1)
        name = botContainerName(game, item.bot, stamp)
      discard requireDocker(botRunArgs(
        name,
        game,
        item.bot,
        created,
        stamp,
        slot,
        token
      ))
      launchedNames.add(name)
      result.add(inspectBot(name))

proc createGame(form: seq[(string, string)]): GameContainer =
  ## Starts a new Coworld game container (or ECS task).
  let manifestInfo = findGameManifest(formValue(form, "manifest"))
  if useEcs:
    echo "  Creating ECS game: ", manifestInfo.name
    let
      config = configJson(form, manifestInfo)
      image = gameDockerImage(manifestInfo)
      created = getTime().toUnix()
      replay = "ecs_game_" & $created & ".bitreplay"
      serverUrl = gamesServerUrl()
      saveReplay = serverUrl.len > 0
      token = if saveReplay: generateUploadToken(replay) else: ""
      uploadUrl = if saveReplay: serverUrl & ReplayUploadPath else: ""
      playerTokens = configTokens(config)
    echo "  Replay upload: ", if saveReplay: "enabled" else: "disabled (no EC2 IP)"
    echo "  Launching game task..."
    let (taskArn, publicIp, privateIp) = ecsCreateGame(
      image,
      config,
      manifestInfo.name,
      manifestInfo.key,
      replay,
      saveReplay = saveReplay,
      uploadUrl = uploadUrl,
      uploadToken = token,
    )
    echo "  Game task: ", taskArn, " ip=", publicIp
    result = GameContainer(
      name: taskArn,
      status: "running",
      port: GameContainerPort,
      created: created,
      replay: replay,
      kind: LiveGame,
      manifestKey: manifestInfo.key,
      cogameName: manifestInfo.name,
      ip: publicIp,
    )
    let botCounts = createBotCounts(form, manifestInfo.name)
    var slot = 0
    for item in botCounts:
      for i in 0 ..< item.count:
        let
          stamp = launchStamp(i + 1)
          playerName = item.bot.name & "-" & $GameContainerPort & "-" & stamp
          playerToken =
            if slot < playerTokens.len:
              playerTokens[slot]
            else:
              ""
        echo "  Launching bot: ", item.bot.name, " #", i + 1
        discard ecsCreateBot(
          coplayerImage(item.bot),
          taskArn,
          privateIp,
          item.bot.name,
          playerName,
          item.bot.binary,
          slot,
          playerToken,
        )
        inc slot
    echo "  ECS game created with ", botCounts.len, " bot types"
    return
  ensureReplayDir()
  let
    port = findOpenPort()
    created = getTime().toUnix()
    name = gameName(manifestInfo.name, port)
    replay = replayName(name)
    config = configJson(form, manifestInfo)
    playerTokens = configTokens(config)
    botCounts = createBotCounts(form, manifestInfo.name)
    image = gameDockerImage(manifestInfo)
    pendingGame = GameContainer(
      name: name,
      status: "pending",
      port: port,
      created: created,
      replay: replay,
      kind: LiveGame,
      manifestKey: manifestInfo.key,
      cogameName: manifestInfo.name
    )
  var launchedBots: seq[string]
  pullDockerImage(image)
  pullNeededBotImages(botCounts)
  try:
    discard startWaitingBots(pendingGame, botCounts, playerTokens, launchedBots)
    discard requireDocker(dockerRunArgs(
      name,
      port,
      created,
      replay,
      LiveGame,
      true,
      config,
      image,
      manifestInfo.binary,
      manifestInfo.name,
      manifestInfo.key
    ))
    result = inspectGame(name)
  except CatchableError:
    removeContainers(launchedBots)
    raise

proc createReplayGame(replay: string): GameContainer =
  ## Starts a container in replay mode (Docker or ECS).
  ## The container downloads the replay via HTTP from games_server.
  ensureReplayDir()
  let cleanReplay = cleanReplayName(replay)
  if cleanReplay.len == 0 or cleanReplay != replay:
    raise newException(GamesServerError, "invalid replay file name")
  if not fileExists(replayPath(cleanReplay)):
    raise newException(GamesServerError, "replay file does not exist")
  let
    manifestInfo = replayManifest(cleanReplay)
    image = gameDockerImage(manifestInfo)
    serverUrl = gamesServerUrl()
  if useEcs:
    if serverUrl.len == 0:
      raise newException(GamesServerError,
        "replay playback requires GAMES_SERVER_URL or EC2 metadata")
    let downloadUrl = serverUrl & ReplayDownloadPath & cleanReplay
    var env: seq[tuple[name, value: string]]
    env.add((name: "REPLAY_DOWNLOAD_URL", value: downloadUrl))
    let (taskArn, publicIp, _) = ecsCreateReplayGame(
      image,
      cleanReplay,
      env,
    )
    result = GameContainer(
      name: taskArn,
      status: "running",
      port: GameContainerPort,
      created: getTime().toUnix(),
      replay: cleanReplay,
      kind: ReplayServer,
      ip: publicIp,
    )
    return
  let
    port = findOpenPort()
    created = getTime().toUnix()
    name = replayGameName(manifestInfo.name, port)
  pullDockerImage(image)
  var args = baseDockerArgs(
    name, port, created, cleanReplay, ReplayServer, false,
    manifestInfo.name, manifestInfo.key
  )
  let downloadUrl = serverUrl & ReplayDownloadPath & cleanReplay
  args.add("-e")
  args.add("REPLAY_DOWNLOAD_URL=" & downloadUrl)
  case dockerMode()
  of "release":
    args.add(image)
    args.add(manifestInfo.binary)
    args.add("--address:0.0.0.0")
    args.add("--port:" & $GameContainerPort)
  else:
    args.add("-v")
    args.add(workspaceRoot() & ":/workspace:ro")
    args.add("-w")
    args.add("/workspace/bitworld/among_them")
    args.add("-e")
    args.add("HOME=/tmp")
    args.add(image)
    args.add("sh")
    args.add("-lc")
    args.add(runnerScript(""))
  discard requireDocker(args)
  result = inspectGame(name)

proc stopBotsForGame(gameName: string) =
  ## Stops running bot containers attached to one game.
  for bot in botsForGame(safeListBots(), gameName):
    if bot.status == "running":
      discard requireDocker(@["stop", bot.name])

proc stopBot(name: string) =
  ## Stops one running managed bot container.
  if useEcs:
    ecsStopBot(name)
    return
  let bot = inspectBot(name)
  if bot.status == "running":
    discard requireDocker(@["stop", bot.name])

proc stopGame(name: string) =
  ## Stops a running managed game container.
  if useEcs:
    ecsStopGame(name)
    return
  let game = inspectGame(name)
  stopBotsForGame(game.name)
  if game.status == "running":
    discard requireDocker(@["stop", game.name])

proc stopManagedContainer(name: string) =
  ## Stops one managed game, replay server, or bot container.
  let safeName = cleanContainerName(name)
  if safeName.len == 0 or safeName != name:
    raise newException(GamesServerError, "invalid container name")
  try:
    stopGame(safeName)
    return
  except GamesServerError:
    discard
  try:
    stopBot(safeName)
    return
  except GamesServerError:
    discard
  raise newException(
    GamesServerError,
    "container is not managed by games_server"
  )

proc removeManagedGame(game: GameContainer): seq[string] =
  ## Removes one managed game container and its bot containers.
  if useEcs:
    return ecsRemoveGame(game.name)
  for bot in botsForGame(safeListBots(), game.name):
    discard dockerResult(@["rm", "-f", bot.name])
    result.add(bot.name)
  discard requireDocker(@["rm", "-f", game.name])
  result.add(game.name)

proc removeManagedBot(bot: BotContainer): seq[string] =
  ## Removes one managed bot container.
  if useEcs:
    return ecsRemoveBot(bot.name)
  discard requireDocker(@["rm", "-f", bot.name])
  result.add(bot.name)

proc removeManagedContainer(name: string): seq[string] =
  ## Removes one managed game, replay server, or bot container.
  let safeName = cleanContainerName(name)
  if safeName.len == 0 or safeName != name:
    raise newException(GamesServerError, "invalid container name")
  try:
    return removeManagedGame(inspectGame(safeName))
  except GamesServerError:
    discard
  try:
    return removeManagedBot(inspectBot(safeName))
  except GamesServerError:
    discard
  raise newException(
    GamesServerError,
    "container is not managed by games_server"
  )

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

proc gameHttpUrl(
  request: Request,
  game: GameContainer,
  path: string
): string =
  ## Builds a browser HTTP URL for a game container client route.
  if useEcs and game.ip.len > 0:
    return "http://" & game.ip & ":" & $GameContainerPort & path
  "http://" & request.hostName() & ":" & $game.port & path

proc clientPagePath(page: string): string =
  ## Returns the per-game browser client path for one endpoint page.
  case page
  of "player.html":
    "/client/player"
  of "rewards.html", "reward.html":
    "/client/reward"
  of "admin.html":
    "/client/admin"
  else:
    "/client/global"

proc gameUrl(request: Request, game: GameContainer, page: string): string =
  ## Builds a per-game browser client URL for one game container.
  request.gameHttpUrl(game, clientPagePath(page))

proc healthUrl(game: GameContainer): string =
  ## Builds the local health URL for one game container.
  if useEcs and game.ip.len > 0:
    return "http://" & game.ip & ":" & $GameContainerPort & HealthPath
  "http://127.0.0.1:" & $game.port & HealthPath

proc gameHealthy(game: GameContainer): bool =
  ## Returns true when the game's health endpoint answers healthy.
  if useEcs:
    return ecsGameHealthy(game.ip)
  if game.status != "running" or game.port <= 0:
    return false
  var client = newHttpClient(timeout = 500)
  try:
    result = client.getContent(healthUrl(game)).strip() == "healthy"
  except CatchableError:
    result = false
  finally:
    client.close()


proc createBots(
  gameName: string,
  botKey: string,
  count: int
): seq[BotContainer] =
  ## Starts one or more bot Docker containers for a live game.
  if useEcs:
    let gameInfo = ecsInspectGame(gameName)
    if gameInfo.kind != "game":
      raise newException(GamesServerError, "bots can only join live games")
    if not ecsGameHealthy(gameInfo.publicIp):
      raise newException(GamesServerError, "game is not healthy yet")
    let
      bot = findCoplayerManifest(gameInfo.cogameName, botKey)
      cleanCount = clampInt(count, 1, MaxBotLaunchCount)
    for i in 1 .. cleanCount:
      let
        stamp = launchStamp(i)
        playerName = bot.name & "-" & $GameContainerPort & "-" & stamp
        botArn = ecsCreateBot(
          coplayerImage(bot),
          gameName,
          gameInfo.privateIp,
          bot.name,
          playerName,
          bot.binary,
          i - 1,
          "",
          bot.arch,
        )
      result.add(BotContainer(
        name: botArn,
        status: "running",
        game: gameName,
        bot: bot.name,
        created: getTime().toUnix(),
      ))
    return
  let game = inspectGame(gameName)
  if game.kind != LiveGame:
    raise newException(GamesServerError, "bots can only join live games")
  if not gameHealthy(game):
    raise newException(GamesServerError, "game is not healthy yet")
  let
    bot = findCoplayerManifest(game.cogameName, botKey)
    cleanCount = clampInt(count, 1, MaxBotLaunchCount)
  pullDockerImage(coplayerImage(bot))
  for i in 1 .. cleanCount:
    let
      created = getTime().toUnix()
      stamp = launchStamp(i)
      name = botContainerName(game, bot, stamp)
    discard requireDocker(botRunArgs(
      name,
      game,
      bot,
      created,
      stamp,
      i - 1,
      ""
    ))
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

proc renderBotCountSelect(bot: CoplayerManifest): string =
  ## Renders one create-form CoPlayer count selector.
  renderFragment:
    select:
      name botCountField(bot)
      for count in 0 .. MaxBotLaunchCount:
        option:
          value $count
          say $count

proc renderCreateBotRows(manifestInfo: GameManifest): string =
  ## Renders bot count rows for the create-game form.
  var index = 0
  let bots = supportedCoplayerManifests(manifestInfo.name)
  if bots.len == 0:
    return renderFragment:
      tr:
        td ".row1":
          colspan "2"
          say "No supported CoPlayers found."
  for bot in bots:
    let
      rowClass = if index mod 2 == 0: ".row1" else: ".row2"
      selectHtml = renderBotCountSelect(bot)
    let rowHtml = renderFragment:
      tr:
        td rowClass & " fieldName nowrap":
          say esc(bot.name & " bots")
        td rowClass:
          say selectHtml
    result.add(rowHtml)
    inc index

proc renderManifestTable(): string =
  ## Renders the index-page Coworld manifest launcher table.
  let manifests = listGameManifests()
  renderFragment:
    table:
      tr:
        td ".cat":
          colspan "6"
          say "Create new game"
      tr:
        th ".head":
          say "Name"
        th ".head":
          say "Author"
        th ".head":
          say "Manifest"
        th ".head":
          say "Docker"
        th ".head":
          say "Launch"
        th ".head":
          say "Validate"
      for i, manifest in manifests:
        let
          rowClass = if i mod 2 == 0: ".row1" else: ".row2"
          image = gameDockerImage(manifest)
        tr:
          td rowClass:
            say esc(manifest.name)
          td rowClass:
            say esc(manifest.author)
          td rowClass & " nowrap":
            a:
              href manifestUrl(manifest)
              target "_blank"
              say esc(manifest.key)
          td rowClass & " nowrap":
            a:
              href dockerPackageUrl(image)
              target "_blank"
              say esc(image)
          td rowClass & " nowrap":
            a ".button":
              href createUrl(manifest)
              say "Launch"
          td rowClass & " nowrap":
            form:
              action ValidationPath
              tmethod "post"
              input:
                ttype "hidden"
                name "manifest"
                value manifest.key
              button ".button":
                ttype "submit"
                say "Validate"

proc renderCreateForm(manifestInfo: GameManifest): string =
  ## Renders the manifest-backed create-game form.
  let
    schema = configSchema(manifestInfo)
    rows = renderConfigRows(schema)
    botRows = renderCreateBotRows(manifestInfo)
  renderFragment:
    form:
      action CreatePath
      tmethod "post"
      input:
        ttype "hidden"
        name "manifest"
        value manifestInfo.key
      table:
        tr:
          td ".cat":
            colspan "2"
            say "Create " & esc(manifestInfo.name)
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

proc renderBulkControls(): string =
  ## Renders the bulk container action controls.
  renderFragment:
    form ".bulkBar":
      id "bulkForm"
      action BulkStopPath
      tmethod "post"
      say "<button class=\"button\" type=\"submit\" formaction=\"" &
        BulkGridPath & "\" formtarget=\"_blank\">Grid View</button>"
      say " "
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

proc renderGamesTable(
  request: Request,
  games: seq[GameContainer],
  bots: seq[BotContainer]
): string =
  ## Renders the active and stopped game list.
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
          say "Replay"
        th ".head":
          say "Scores"
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
          td rowClass & " selectCell":
            say renderContainerCheckbox(game.name)
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
              say " | "
              a:
                href gameUrl(request, game, "admin.html")
                target "_blank"
                say "admin"
            elif game.status == "running":
              say "starting"
            else:
              say "offline"
          td rowClass & " nowrap":
            if healthy:
              let supportedBots = supportedCoplayerManifests(game.cogameName)
              if supportedBots.len == 0:
                say "-"
              else:
                form:
                  action "/games/bot"
                  tmethod "post"
                  input:
                    ttype "hidden"
                    name "name"
                    value game.name
                  select:
                    name "bot"
                    for bot in supportedBots:
                      option:
                        value bot.name
                        say bot.name
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
                  say "Launch"
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
          td rowClass & " center":
            a:
              href logUrl(game.name)
              target "_blank"
              say "logs"
        for bot in gameBots:
          tr:
            td rowClass & " selectCell":
              say renderContainerCheckbox(bot.name)
            td rowClass:
              say ""
            td rowClass & " nowrap":
              say esc(bot.status)
            td rowClass:
              say ""
            td rowClass:
              say ""
            td rowClass & " nowrap":
              say esc(bot.name)
            td rowClass & " nowrap":
              say fmtCreated(bot.created)
            td rowClass:
              say ""
            td rowClass:
              say ""
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
        th ".head selectCell":
          say ""
        th ".head":
          say "Replay server"
        th ".head":
          say "Status"
        th ".head":
          say "Port"
        th ".head":
          say "Viewer"
        th ".head":
          say "Created"
        th ".head":
          say "Replay"
        th ".head":
          say "Scores"
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
          td rowClass & " selectCell":
            say renderContainerCheckbox(server.name)
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
          td rowClass & " nowrap":
            say fmtCreated(server.created)
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
          say "Replay"
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
                say "Launch"
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
    manifestTable = renderManifestTable()
    bulkControls = renderBulkControls()
    gamesTable = renderGamesTable(request, games, bots)
    replayServersTable = renderReplayServersTable(request, replayServers)
    replaysTable = renderReplaysTable(replays)
  render:
    html:
      head:
        title:
          say "CoGame Server"
        say "<style>"
        say PageCss
        say "</style>"
        say BulkScript
      body:
        tdiv ".page":
          table:
            tr:
              td ".row2":
                h1 ".title":
                  say "CoGame Server"
                p ".small":
                  say "If not CoGame why CoGame shaped?"
              td ".row2 right small":
                a:
                  href "/"
                  say "Refresh"
          if notice.len > 0:
            p ".notice small":
              b:
                say esc(notice)
          say bulkControls
          say manifestTable
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

proc renderCreatePage(notice = "", manifestKey = ""): string =
  ## Renders the create-game page.
  let
    manifestInfo = findGameManifest(manifestKey)
    createForm = renderCreateForm(manifestInfo)
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
                  say "CoGame config from manifest."
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
            say "Manifest: "
            a:
              href manifestUrl(manifestInfo)
              target "_blank"
              say esc(manifestInfo.key)
            say "."

proc renderValidationTable(
  criteria: seq[ValidationCriterion]
): string =
  ## Renders validator criteria as a pass/fail table.
  renderFragment:
    table:
      tr:
        th ".head":
          say "Status"
        th ".head":
          say "Criterion"
        th ".head":
          say "Name"
        th ".head":
          say "Message"
      if criteria.len == 0:
        tr:
          td ".row1":
            colspan "4"
            say "No validation criteria were produced."
      for i, criterion in criteria:
        let rowClass = if i mod 2 == 0: ".row1" else: ".row2"
        tr:
          td rowClass & " nowrap":
            span "." & validationStatusClass(criterion.status):
              say validationStatusText(criterion.status)
          td rowClass & " nowrap":
            say esc(criterion.id)
          td rowClass:
            say esc(criterion.name)
          td rowClass & " message":
            if criterion.message.len > 0:
              say esc(criterion.message)
            else:
              say "-"

proc renderValidationArtifacts(cert: CertificationResult): string =
  ## Renders artifact paths produced by validation.
  if cert.artifacts.workspace.len == 0:
    return ""
  renderFragment:
    table:
      tr:
        td ".cat":
          colspan "2"
          say "Artifacts"
      tr:
        td ".row1 fieldName nowrap":
          say "Workspace"
        td ".row1":
          say esc(cert.artifacts.workspace)
      tr:
        td ".row2 fieldName nowrap":
          say "Results"
        td ".row2":
          say esc(cert.artifacts.resultsPath)
      tr:
        td ".row1 fieldName nowrap":
          say "Replay"
        td ".row1":
          say esc(cert.artifacts.replayPath)
      tr:
        td ".row2 fieldName nowrap":
          say "Logs"
        td ".row2":
          say esc(cert.artifacts.logsDir)

proc renderValidationPage(
  manifestInfo: GameManifest,
  cert: CertificationResult
): string =
  ## Renders one Coworld validation result page.
  let
    tableHtml = renderValidationTable(cert.criteria)
    artifactHtml = renderValidationArtifacts(cert)
    status =
      if cert.validationPassed():
        "Validation passed."
      else:
        "Validation failed."
  render:
    html:
      head:
        title:
          say "Validation: " & esc(manifestInfo.name)
        say "<style>"
        say PageCss
        say "</style>"
      body:
        tdiv ".page":
          table:
            tr:
              td ".row2":
                h1 ".title":
                  say "Validation"
                p ".small":
                  say esc(manifestInfo.name)
              td ".row2 right small":
                a:
                  href "/"
                  say "Back"
          p ".notice small":
            b:
              say esc(status)
          table:
            tr:
              td ".cat":
                say "Criteria"
          say tableHtml
          if artifactHtml.len > 0:
            p ".small":
              say " "
            say artifactHtml
          p ".footer small":
            say "Manifest: "
            a:
              href manifestUrl(manifestInfo)
              target "_blank"
              say esc(manifestInfo.key)
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
      if rows.len == 0:
        tr:
          td ".row1 center":
            colspan "10"
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
          td rowClass & " right nowrap":
            if row.imposter.len > 0:
              say esc(row.imposter)
            else:
              say "-"
          td rowClass & " right nowrap":
            if row.crew.len > 0:
              say esc(row.crew)
            else:
              say "-"
          td rowClass & " right nowrap":
            if row.votePlayers.len > 0:
              say esc(row.votePlayers)
            else:
              say "-"
          td rowClass & " right nowrap":
            if row.voteSkip.len > 0:
              say esc(row.voteSkip)
            else:
              say "-"
          td rowClass & " right nowrap":
            if row.voteTimeout.len > 0:
              say esc(row.voteTimeout)
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

proc gridColumnCount(count: int): int =
  ## Returns a practical column count for a viewer grid.
  if count <= 0:
    return 1
  if count <= 3:
    return count
  result = 1
  while result * result < count:
    inc result

proc renderGridPage(
  request: Request,
  games: seq[GameContainer]
): string =
  ## Renders selected game global viewers in a responsive grid.
  let
    columns = gridColumnCount(games.len)
    rows = max(1, (games.len + columns - 1) div columns)
  render:
    html:
      head:
        title:
          say "Grid View"
        say "<style>"
        say PageCss
        say "html, body { width: 100%; height: 100%; overflow: hidden; }"
        say "</style>"
      body:
        tdiv ".gridPage":
          if games.len == 0:
            tdiv ".gridEmpty":
              say "No games selected."
          else:
            tdiv ".viewerGrid":
              style "grid-template-columns: repeat(" &
                $columns & ", minmax(0, 1fr)); " &
                "grid-template-rows: repeat(" &
                $rows & ", minmax(0, 1fr));"
              for game in games:
                let url = gameUrl(request, game, "global.html")
                tdiv ".viewerCell":
                  iframe ".viewerFrame":
                    src url
                    title game.name

proc clientRoot(): string =
  ## Returns the shared client asset directory.
  parentDir(parentDir(currentSourcePath())) / "clients"

proc clientAsset(path: string): string =
  ## Maps one public client route to a local asset path.
  case path
  of "/client/global", "/client/global.html", "/client/global_client.html":
    clientRoot() / "global_client.html"
  of "/client/player", "/client/player.html", "/client/player_client.html":
    clientRoot() / "player_client.html"
  of "/client/reward", "/client/rewards", "/client/reward.html",
      "/client/rewards.html",
      "/client/reward_client.html":
    clientRoot() / "reward_client.html"
  of "/client/admin", "/client/admin.html":
    clientRoot() / "admin_client.html"
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
  ## Redirects immediately — the viewer JS reconnects until the container is up.
  let name = cleanReplayName(rawName)
  if name.len == 0 or name != rawName:
    request.respondReplayNotFound()
    return
  if not fileExists(replayPath(name)):
    request.respondReplayNotFound()
    return
  let game = createReplayGame(name)
  request.respondRedirect(gameUrl(request, game, "global.html"))

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

proc requestManifestKey(request: Request): string =
  ## Reads the selected manifest key from a create request.
  if request.httpMethod == "POST":
    return formValue(parseFormBody(request), "manifest")
  queryValue(request, "manifest")

proc createFormHandler(request: Request) =
  ## Handles the create-game form route.
  request.respondHtml(200, renderCreatePage(
    queryValue(request, "notice"),
    request.requestManifestKey()
  ))

proc createHandler(request: Request) =
  ## Handles create-game requests.
  let game = createGame(parseFormBody(request))
  request.respondRedirect("/?notice=created+" & game.name)

proc validationHandler(request: Request) =
  ## Handles Coworld validation requests.
  let
    manifestInfo = findGameManifest(
      formValue(parseFormBody(request), "manifest")
    )
    cert = runValidation(manifestInfo)
  request.respondHtml(200, renderValidationPage(manifestInfo, cert))

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
    bot = formValue(form, "bot")
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

proc bulkContainerNames(form: seq[(string, string)]): seq[string] =
  ## Reads selected managed container names from a bulk action form.
  for (key, value) in form:
    if key != "name":
      continue
    let name = cleanContainerName(value)
    if name.len == 0 or name != value:
      raise newException(GamesServerError, "invalid container name")
    if name notin result:
      result.add(name)

proc bulkGridGames(form: seq[(string, string)]): seq[GameContainer] =
  ## Reads selected game containers from a bulk action form.
  for name in bulkContainerNames(form):
    try:
      let game = inspectGame(name)
      result.add(game)
    except GamesServerError:
      discard

proc bulkStopHandler(request: Request) =
  ## Handles selected container stop requests.
  let names = bulkContainerNames(parseFormBody(request))
  if names.len == 0:
    request.respondRedirect("/?notice=nothing+selected")
    return
  for name in names:
    stopManagedContainer(name)
  request.respondRedirect("/?notice=stopped+" & $names.len & "+containers")

proc bulkRemoveHandler(request: Request) =
  ## Handles selected container remove requests.
  let names = bulkContainerNames(parseFormBody(request))
  if names.len == 0:
    request.respondRedirect("/?notice=nothing+selected")
    return
  var removed: seq[string]
  for name in names:
    if name in removed:
      continue
    for removedName in removeManagedContainer(name):
      if removedName notin removed:
        removed.add(removedName)
  request.respondRedirect("/?notice=removed+" & $removed.len & "+containers")

proc bulkGridHandler(request: Request) =
  ## Handles selected game grid viewer requests.
  request.respondHtml(200, renderGridPage(
    request,
    bulkGridGames(parseFormBody(request))
  ))

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

proc manifestHandler(request: Request) =
  ## Handles raw Coworld manifest requests.
  let manifestInfo = findGameManifest(queryValue(request, "path"))
  request.respondContent(
    200,
    "application/json; charset=utf-8",
    readFile(manifestInfo.path)
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
    request.respondHtml(500, renderCreatePage(
      e.msg,
      request.requestManifestKey()
    ))
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
  let t0 = epochTime()
  echo request.httpMethod, " ", request.path
  defer:
    let ms = int((epochTime() - t0) * 1000)
    if ms > 100:
      echo "  ", request.path, " took ", ms, "ms"
  try:
    if request.path == "/" and request.httpMethod == "GET":
      request.indexHandler()
    elif request.path == CreatePath and request.httpMethod == "GET":
      request.createFormHandler()
    elif request.path == LogsPath and request.httpMethod == "GET":
      request.logsHandler()
    elif request.path == ScoresPath and request.httpMethod == "GET":
      request.scoresHandler()
    elif request.path == ManifestViewPath and request.httpMethod == "GET":
      request.manifestHandler()
    elif request.path.startsWith(ClientPath) and request.httpMethod == "GET":
      request.clientHandler()
    elif request.path == CreatePath and request.httpMethod == "POST":
      request.createHandler()
    elif request.path == ValidationPath and request.httpMethod == "POST":
      request.validationHandler()
    elif request.path == "/games/bot" and request.httpMethod == "POST":
      request.botHandler()
    elif request.path == "/games/bot/stop" and request.httpMethod == "POST":
      request.stopBotHandler()
    elif request.path == "/games/stop" and request.httpMethod == "POST":
      request.stopHandler()
    elif request.path == BulkStopPath and request.httpMethod == "POST":
      request.bulkStopHandler()
    elif request.path == BulkRemovePath and request.httpMethod == "POST":
      request.bulkRemoveHandler()
    elif request.path == BulkGridPath and request.httpMethod == "POST":
      request.bulkGridHandler()
    elif request.path == ReplayPlayPath and request.httpMethod == "POST":
      request.replayPlayHandler()
    elif request.path.startsWith(ReplayPathPrefix) and
        request.httpMethod == "GET":
      request.replayPathHandler()
    elif request.path == ReplayUploadPath and request.httpMethod == "POST":
      request.replayUploadHandler()
    elif request.path == ReplayScoresUploadPath and request.httpMethod == "POST":
      request.scoresUploadHandler()
    elif request.path.startsWith(ReplayDownloadPath) and request.httpMethod == "GET":
      request.replayDownloadHandler()
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
      of "no-pull":
        skipPull = true
      of "build":
        buildLocalImages()
        skipPull = true
      of "ecs":
        useEcs = true
      else:
        discard
    else:
      discard
  if useEcs:
    echo "ECS mode enabled"
    loadEcsConfig()
    ec2PrivateIp = fetchEc2PrivateIp()
    if ec2PrivateIp.len > 0:
      echo "EC2 private IP: ", ec2PrivateIp
    else:
      echo "Not on EC2 — replay upload/download disabled"
  runServer(address, port)

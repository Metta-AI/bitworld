import
  std/[algorithm, json, os, parseopt, strutils]

const
  CoworldManifestName = "coworld_manifest.json"
  CoplayerManifestName = "coplayer_manifest.json"
  GamesServerDir = "games_server"
  GamesDir = GamesServerDir / "games"
  PlayersDir = GamesServerDir / "players"

type
  UpdateManifestError = object of CatchableError

  ManifestKind = enum
    GameManifest,
    PlayerManifest

  UpdateMode = enum
    UpdateAll,
    UpdateGames,
    UpdatePlayers

  UpdateArgs = object
    sourceRoot: string
    repoRoot: string
    mode: UpdateMode
    dryRun: bool

  ManifestSource = object
    kind: ManifestKind
    name: string
    sourcePath: string
    destPath: string

  UpdateStats = object
    found: int
    created: int
    updated: int
    unchanged: int

proc fail(message: string) =
  ## Raises one update-manifest error.
  raise newException(UpdateManifestError, message)

proc repoRoot(): string =
  ## Returns the BitWorld repository root containing this tool.
  parentDir(parentDir(currentSourcePath()))

proc defaultSourceRoot(): string =
  ## Returns the default sibling-project search root.
  parentDir(repoRoot())

proc usage(): string =
  ## Returns command-line usage text.
  """
Usage:
  update_manifest [options]

Options:
  --root:<path>       Source root to scan. Default: parent of bitworld repo.
  --repo:<path>       BitWorld repo to update. Default: this repo.
  --games-only        Update only Coworld game manifests.
  --players-only      Update only Coplayer manifests.
  --dry-run           Print changes without writing files.
  --help              Show this help.

The scan is intentionally shallow:
  <root>/*/coworld_manifest.json
  <root>/*/coplayer_manifest.json

Only main Git checkouts are scanned. Linked worktrees usually have a `.git`
file instead of a `.git` directory, and are skipped.
"""

proc cleanDirName(value: string): string =
  ## Returns a safe manifest directory name.
  for c in value.strip():
    if c.isAlphaNumeric() or c == '_' or c == '-':
      result.add(c)
    else:
      result.add('_')
  while "__" in result:
    result = result.replace("__", "_")
  result = result.strip(chars = {'_'})
  if result.len == 0:
    fail("manifest name is not directory-safe: " & value)

proc manifestObject(node: JsonNode, key, path: string): JsonNode =
  ## Returns one required JSON object field.
  if node.kind != JObject:
    fail(path & " must be a JSON object")
  if not node.hasKey(key):
    fail(path & " missing required field " & key)
  result = node[key]
  if result.kind != JObject:
    fail(path & "." & key & " must be a JSON object")

proc manifestString(node: JsonNode, key, path: string): string =
  ## Returns one required non-empty JSON string field.
  if node.kind != JObject:
    fail(path & " must be a JSON object")
  if not node.hasKey(key):
    fail(path & " missing required field " & key)
  let child = node[key]
  if child.kind != JString or child.getStr().strip().len == 0:
    fail(path & "." & key & " must be a non-empty string")
  child.getStr().strip()

proc readJsonObject(path: string): JsonNode =
  ## Reads one JSON object from disk.
  try:
    result = parseFile(path)
  except CatchableError as e:
    fail("could not parse " & path & ": " & e.msg)
  if result.kind != JObject:
    fail(path & " must contain a JSON object")

proc gameName(path: string): string =
  ## Reads the Coworld game name from one manifest.
  let
    node = readJsonObject(path)
    game = node.manifestObject("game", path)
  game.manifestString("name", path & ".game")

proc playerName(path: string): string =
  ## Reads the Coplayer name from one manifest.
  readJsonObject(path).manifestString("name", path)

proc makeSource(
  kind: ManifestKind,
  sourcePath,
  repoRoot: string
): ManifestSource =
  ## Builds one manifest source and destination pair.
  result.kind = kind
  result.sourcePath = sourcePath
  case kind
  of GameManifest:
    result.name = gameName(sourcePath)
    result.destPath =
      repoRoot / GamesDir / cleanDirName(result.name) / CoworldManifestName
  of PlayerManifest:
    result.name = playerName(sourcePath)
    result.destPath =
      repoRoot / PlayersDir / cleanDirName(result.name) / CoplayerManifestName

proc shouldScan(args: UpdateArgs, kind: ManifestKind): bool =
  ## Returns true when a manifest kind should be updated.
  case args.mode
  of UpdateAll:
    true
  of UpdateGames:
    kind == GameManifest
  of UpdatePlayers:
    kind == PlayerManifest

proc isMainRepo(path: string): bool =
  ## Returns true when a directory looks like a main Git checkout.
  dirExists(path / ".git")

proc scanSources(args: UpdateArgs): seq[ManifestSource] =
  ## Scans source root children for game and player manifests.
  if not dirExists(args.sourceRoot):
    fail("source root does not exist: " & args.sourceRoot)
  for kind, path in walkDir(args.sourceRoot):
    if kind != pcDir:
      continue
    if path.normalizedPath() == args.repoRoot.normalizedPath():
      continue
    if not path.isMainRepo():
      continue
    let
      coworldPath = path / CoworldManifestName
      coplayerPath = path / CoplayerManifestName
    if args.shouldScan(GameManifest) and fileExists(coworldPath):
      result.add(makeSource(GameManifest, coworldPath, args.repoRoot))
    if args.shouldScan(PlayerManifest) and fileExists(coplayerPath):
      result.add(makeSource(PlayerManifest, coplayerPath, args.repoRoot))

proc duplicateKey(source: ManifestSource): string =
  ## Returns a duplicate-detection key for one source.
  $source.kind & ":" & cleanDirName(source.name)

proc checkDuplicates(sources: openArray[ManifestSource]) =
  ## Raises when multiple sources map to the same destination.
  var seen: seq[(string, string)]
  for source in sources:
    let key = duplicateKey(source)
    for (seenKey, seenPath) in seen:
      if seenKey == key:
        fail(
          "multiple manifests map to " & source.destPath &
          ": " & seenPath & " and " & source.sourcePath
        )
    seen.add((key, source.sourcePath))

proc statusName(source: ManifestSource): string =
  ## Returns a display name for one source kind.
  case source.kind
  of GameManifest:
    "game"
  of PlayerManifest:
    "player"

proc copyManifest(source: ManifestSource, dryRun: bool): string =
  ## Copies one manifest when it differs and returns an action label.
  let sourceText = readFile(source.sourcePath)
  if fileExists(source.destPath):
    let destText = readFile(source.destPath)
    if sourceText == destText:
      return "same"
    if not dryRun:
      writeFile(source.destPath, sourceText)
    return "update"
  if not dryRun:
    createDir(parentDir(source.destPath))
    writeFile(source.destPath, sourceText)
  "create"

proc updateSources(
  sources: openArray[ManifestSource],
  dryRun: bool
): UpdateStats =
  ## Updates all scanned manifests and returns summary counts.
  result.found = sources.len
  for source in sources:
    let action = copyManifest(source, dryRun)
    case action
    of "same":
      inc result.unchanged
    of "update":
      inc result.updated
    of "create":
      inc result.created
    else:
      discard
    echo action, " ", source.statusName(), " ", source.name
    echo "  from ", source.sourcePath
    echo "  to   ", source.destPath

proc parseArgs(): UpdateArgs =
  ## Parses command-line arguments.
  result.sourceRoot = defaultSourceRoot()
  result.repoRoot = repoRoot()
  result.mode = UpdateAll
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "root":
        result.sourceRoot = absolutePath(val)
      of "repo":
        result.repoRoot = absolutePath(val)
      of "games-only":
        result.mode = UpdateGames
      of "players-only":
        result.mode = UpdatePlayers
      of "dry-run":
        result.dryRun = true
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
    of cmdArgument:
      fail("unexpected argument: " & key)
    of cmdEnd:
      discard
  result.sourceRoot = result.sourceRoot.normalizedPath()
  result.repoRoot = result.repoRoot.normalizedPath()

proc run() =
  ## Runs the update-manifest tool.
  let args = parseArgs()
  var sources = scanSources(args)
  sources.sort(proc(a, b: ManifestSource): int =
    cmp(a.destPath, b.destPath)
  )
  checkDuplicates(sources)
  let stats = updateSources(sources, args.dryRun)
  echo "Summary: found=", stats.found,
    " created=", stats.created,
    " updated=", stats.updated,
    " unchanged=", stats.unchanged
  if args.dryRun:
    echo "Dry run: no files were written."

try:
  run()
except UpdateManifestError as e:
  stderr.writeLine("update_manifest failed: " & e.msg)
  quit(1)
except CatchableError as e:
  stderr.writeLine("update_manifest failed: " & e.msg)
  quit(1)

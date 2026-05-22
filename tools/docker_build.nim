## Builds multi-arch Docker images for bitworld.
##
## games_server/games_server.nim pulls images from manifest image paths at
## runtime to launch game and bot containers. Dockerfiles live beside their
## game or player manifests.
##
## This tool wraps `docker buildx` to produce a multi-arch OCI manifest so
## the same image tag works on both x86_64 (AWS/Linux) and arm64 (macOS).
## Without multi-arch, pulling on the wrong host falls back to slow QEMU
## binfmt emulation instead of running natively.
##
## Usage:
##   nim r tools/docker_build.nim --push              # build + push all
##   nim r tools/docker_build.nim --push among_them   # just the game server
##   nim r tools/docker_build.nim --push infinite_blocks --bots
##                                                   # game plus its bots
##   nim r tools/docker_build.nim --list              # show targets
##
## Prerequisites:
##   - docker buildx.
##   - On Linux, docker-buildx-plugin may need to be installed.
##   - Registry auth for any manifest image path you push.

import
  std/[algorithm, json, os, osproc, parseopt, strutils, tables]

const
  DefaultRegistry = ""
  DefaultPlatforms = "linux/amd64,linux/arm64"
  CoworldManifestName = "coworld_manifest.json"
  ManifestNames = [CoworldManifestName]
  IgnoredDirs = [
    ".git",
    ".github",
    "__pycache__",
    "nimcache",
    "node_modules",
    "out",
    "replays",
    "tmp"
  ]

type
  DockerTarget = object
    name: string
    imageName: string
    imageRepo: string
    dockerFile: string
    contextDir: string
    bitworldContext: string
    games: seq[string]
    isGame: bool

proc usage() =
  ## Prints usage and exits.
  echo """Usage: docker_build [OPTIONS] [TARGETS...]

Build multi-arch Docker images for bitworld.

Targets are discovered from Dockerfile locations.
Targets may also be paths to a Dockerfile or a directory containing one.

Options:
  --push            Push images after building
  --bots            Also build bots for selected game targets
  --platform:STR    Platforms to build (default: linux/amd64,linux/arm64)
  --tag:STR         Image tag (default: latest)
  --registry:STR    Override manifest registry prefix
  --list            List available targets and exit
  --help            Show this help"""
  quit(0)

proc hasPathSeparator(value: string): bool =
  ## Returns true when a value looks like a filesystem path.
  value.contains('/') or value.contains('\\')

proc repoRoot(): string =
  ## Returns the repository root directory.
  currentSourcePath().parentDir.parentDir

proc samePath(a, b: string): bool =
  ## Returns true when two paths refer to the same directory.
  cmpPaths(absolutePath(a), absolutePath(b)) == 0

proc pathExists(path: string): bool =
  ## Returns true when a filesystem path exists.
  fileExists(path) or dirExists(path)

proc normalizeTargetName(name: string): string =
  ## Normalizes a manifest name into a command-line target name.
  for c in name:
    if c.isAlphaNumeric() or c == '_':
      result.add(c.toLowerAscii())
    elif c == '-' or c == ' ':
      result.add('_')

proc stripImageTag(image: string): string =
  ## Removes a Docker image tag or digest from an image URI.
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

proc imageNameFromUri(imageUri: string): string =
  ## Returns the package name part from a Docker image URI.
  let cleanImage = stripImageTag(imageUri.strip())
  if cleanImage.len == 0:
    return ""
  cleanImage.split('/')[^1]

proc imageRepoFromUri(imageUri: string): string =
  ## Returns the repository path from a Docker image URI.
  stripImageTag(imageUri.strip())

proc nodeImageUri(node: JsonNode): string =
  ## Reads one Docker image URI from a manifest object.
  if node.kind != JObject:
    return ""
  if node.hasKey("runnable") and node["runnable"].kind == JObject:
    let runnable = node["runnable"]
    if runnable.hasKey("image") and runnable["image"].kind == JString:
      return runnable["image"].getStr()
  if node.hasKey("image") and node["image"].kind == JString:
    return node["image"].getStr()
  if node.hasKey("image_uri") and node["image_uri"].kind == JString:
    return node["image_uri"].getStr()
  ""

proc manifestPath(dir: string): string =
  ## Returns the first game or player manifest beside a Dockerfile.
  for fileName in ManifestNames:
    let path = dir / fileName
    if fileExists(path):
      return path
  var parent = dir.parentDir()
  while parent.len > 0 and parent != dir:
    let path = parent / CoworldManifestName
    if fileExists(path):
      return path
    let nextParent = parent.parentDir()
    if nextParent == parent:
      break
    parent = nextParent

proc manifestString(path, key: string): string =
  ## Reads one string field from a JSON manifest.
  if path.len == 0:
    return ""
  let node = parseFile(path)
  if key == "image_uri":
    let imageUri = nodeImageUri(node)
    if imageUri.len > 0:
      return imageUri
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    return node[key].getStr()
  if node.kind == JObject and node.hasKey("game") and
      node["game"].kind == JObject:
    let game = node["game"]
    if key == "image_uri":
      let imageUri = nodeImageUri(game)
      if imageUri.len > 0:
        return imageUri
    if game.hasKey(key) and game[key].kind == JString:
      return game[key].getStr()
  ""

proc nodeString(node: JsonNode, key: string): string =
  ## Reads one string field from a JSON node.
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr()
  else:
    ""

proc coworldPlayerImage(
  manifestPath,
  dirName: string
): tuple[name, imageUri: string] =
  ## Reads a Coworld player image that matches one Dockerfile directory.
  if manifestPath.len == 0 or
      manifestPath.extractFilename() != CoworldManifestName:
    return
  let node = parseFile(manifestPath)
  if node.kind != JObject or not node.hasKey("player") or
      node["player"].kind != JArray:
    return
  let
    cleanDir = normalizeTargetName(dirName)
    genericPlayerDirs = ["ai", "bot", "bots", "player", "players"]
  var
    first: JsonNode
    matched: JsonNode
  for player in node["player"]:
    if player.kind != JObject:
      continue
    if first.isNil:
      first = player
    let
      id = player.nodeString("id")
      name = player.nodeString("name")
    if normalizeTargetName(id) == cleanDir or
        normalizeTargetName(name) == cleanDir:
      matched = player
      break
  if matched.isNil and node["player"].len == 1 and
      cleanDir in genericPlayerDirs:
    matched = first
  if not matched.isNil:
    let
      id = matched.nodeString("id")
      rawName = matched.nodeString("name")
      name = if rawName.len > 0: rawName else: id
      imageUri = matched.nodeImageUri()
    if imageUri.len > 0:
      result = (name: name, imageUri: imageUri)

proc imageNameForTarget(
  targetName: string,
  manifestImageUri: string
): string =
  ## Returns the package name for one Docker target.
  result = imageNameFromUri(manifestImageUri)
  if result.len == 0:
    result = "bitworld-" & targetName.replace('_', '-')

proc imageRepoForTarget(
  targetName: string,
  manifestImageUri: string
): string =
  ## Returns the image repository path for one Docker target.
  result = imageRepoFromUri(manifestImageUri)
  if result.len == 0:
    result = "bitworld-" & targetName.replace('_', '-')

proc shouldScanDir(path: string): bool =
  ## Returns true when a directory can contain useful Dockerfiles.
  let name = path.extractFilename()
  if name.len == 0:
    return true
  name notin IgnoredDirs and not name.startsWith(".")

proc addDockerFile(
  root,
  contextDir,
  bitworldContext,
  dockerFile: string,
  targets: var seq[DockerTarget]
) =
  ## Adds one Dockerfile when it belongs to a known game or manifest.
  let
    dir = dockerFile.parentDir()
    manifest = manifestPath(dir)
    playerImage = coworldPlayerImage(manifest, dir.extractFilename())
    gameName = manifestString(manifest, "name")
  var
    manifestName = gameName
    manifestImageUri = manifestString(manifest, "image_uri")
    games: seq[string]
    isGame =
      manifest.len > 0 and
      manifest.extractFilename() == CoworldManifestName and
      manifest.parentDir() == dir
  if manifest.len > 0 and manifest.parentDir() != dir and
      playerImage.imageUri.len > 0:
    manifestName = playerImage.name
    manifestImageUri = playerImage.imageUri
    if gameName.len > 0:
      games.add(gameName)
  if manifestName.len == 0 or manifestImageUri.len == 0:
    return
  var targetName =
    normalizeTargetName(manifestName)

  if targetName.len == 0:
    return

  targets.add DockerTarget(
    name: targetName,
    imageName: imageNameForTarget(targetName, manifestImageUri),
    imageRepo: imageRepoForTarget(targetName, manifestImageUri),
    dockerFile: dockerFile.relativePath(contextDir),
    contextDir: contextDir,
    bitworldContext: bitworldContext,
    games: games,
    isGame: isGame
  )

proc scanDockerFiles(
  root,
  dir: string,
  contextDir: string,
  bitworldContext: string,
  targets: var seq[DockerTarget]
) =
  ## Recursively scans for Dockerfiles under non-generated directories.
  for kind, path in walkDir(dir):
    case kind
    of pcDir:
      if shouldScanDir(path):
        scanDockerFiles(root, path, contextDir, bitworldContext, targets)
    of pcFile, pcLinkToFile:
      if path.extractFilename() == "Dockerfile":
        addDockerFile(root, contextDir, bitworldContext, path, targets)
    else:
      discard

proc discoverTargets(root: string, bitworldContext = ""): seq[DockerTarget] =
  ## Discovers all Docker build targets in the repository.
  let scanRoot = absolutePath(root)
  scanDockerFiles(scanRoot, scanRoot, scanRoot, bitworldContext, result)
  result.sort(proc(a, b: DockerTarget): int =
    cmp(a.name, b.name)
  )

proc targetMap(targets: openArray[DockerTarget]): Table[string, DockerTarget] =
  ## Builds a lookup table using the first target for each name.
  for target in targets:
    if target.name notin result:
      result[target.name] = target

proc targetFiles(
  targets: openArray[DockerTarget],
  name: string
): seq[string] =
  ## Returns Dockerfiles for targets with one normalized name.
  for target in targets:
    if target.name == name:
      result.add(target.contextDir / target.dockerFile)

proc dockerTargetFromPath(
  root,
  path: string
): tuple[found: bool, target: DockerTarget, message: string] =
  ## Reads one Docker target from an explicit path argument.
  let
    currentPath =
      if path.isAbsolute():
        path
      else:
        absolutePath(path)
    rootPath =
      if path.isAbsolute():
        path
      else:
        absolutePath(root / path)
  if path notin [".", ".."] and
      not path.hasPathSeparator() and
      not currentPath.pathExists() and
      not rootPath.pathExists():
    return

  let rawPath =
    if path.isAbsolute():
      path
    elif path in [".", ".."] or
        path.hasPathSeparator() or
        currentPath.pathExists():
      currentPath
    else:
      rootPath
  let dockerFile =
    if dirExists(rawPath):
      rawPath / "Dockerfile"
    else:
      rawPath
  if not fileExists(dockerFile):
    return (
      found: false,
      target: DockerTarget(),
      message: "Dockerfile not found: " & dockerFile
    )

  let contextDir = dockerFile.parentDir()
  var targets: seq[DockerTarget]
  addDockerFile(root, contextDir, root, dockerFile, targets)
  if targets.len == 0:
    return (
      found: false,
      target: DockerTarget(),
      message: "No manifest found for Dockerfile: " & dockerFile
    )

  result = (found: true, target: targets[0], message: "")

proc supportsGame(target: DockerTarget, gameName: string): bool =
  ## Returns true when a target is a bot for one normalized game name.
  let normalizedGame = normalizeTargetName(gameName)
  for game in target.games:
    if normalizeTargetName(game) == normalizedGame:
      return true

proc addUniqueTarget(
  targets: var seq[DockerTarget],
  target: DockerTarget
) =
  ## Adds one target if its Dockerfile is not already selected.
  for existing in targets:
    if existing.contextDir == target.contextDir and
        existing.dockerFile == target.dockerFile:
      return
  targets.add(target)

proc addBotTargets(
  result: var seq[DockerTarget],
  targets: openArray[DockerTarget],
  game: DockerTarget
) =
  ## Adds all discovered bot targets that support one game target.
  if not game.isGame:
    return
  for target in targets:
    if target.isGame:
      continue
    if target.supportsGame(game.name):
      result.addUniqueTarget(target)

const
  TournamentArgs = ["name", "token", "slot"]
  TournamentEnv = "COGAMES_ENGINE_WS_URL"

proc checkTournamentArgs(root: string, targets: openArray[DockerTarget]) =
  ## Verifies bot source files accept --name, --token, --slot, and the env var.
  var failed = false
  for target in targets:
    if target.isGame:
      continue
    let nimFile = target.contextDir / target.name & ".nim"
    if not fileExists(nimFile):
      continue
    let source = readFile(nimFile)
    if "getopt" notin source:
      continue
    for arg in TournamentArgs:
      if ("of \"" & arg & "\"") notin source:
        echo "Error: ", nimFile.relativePath(root),
          " does not handle --", arg,
          " (required for tournaments)"
        failed = true
    if TournamentEnv notin source:
      echo "Error: ", nimFile.relativePath(root),
        " does not read ", TournamentEnv,
        " (required for tournaments)"
      failed = true
  if failed:
    echo ""
    echo "Bot players must accept --name, --token, --slot and read"
    echo TournamentEnv, " to work in tournaments."
    echo "See metta/packages/coworld/src/coworld/GAME_RUNTIME_README.md"
    quit(1)

proc ensureBuildx() =
  ## Verifies that docker buildx is available.
  let (output, code) = execCmdEx("docker buildx version")
  if code != 0:
    echo "Error: docker buildx not available."
    echo "Install with: docker buildx install"
    quit(1)
  echo "buildx: ", output.strip()

proc ensureBuilder() =
  ## Creates or uses a buildx builder that supports multi-platform.
  let (output, _) = execCmdEx("docker buildx ls")
  if "bitworld-builder" notin output:
    echo "Creating buildx builder 'bitworld-builder'..."
    let code = execCmd(
      "docker buildx create --name bitworld-builder --use --bootstrap"
    )
    if code != 0:
      echo "Error: failed to create buildx builder."
      quit(1)
  else:
    discard execCmd("docker buildx use bitworld-builder")

proc fullImageTag(
  target: DockerTarget,
  registry,
  tag: string
): string =
  ## Returns the full Docker image tag for one target.
  let cleanRegistry = registry.strip().strip(chars = {'/'})
  let imageRepo =
    if cleanRegistry.len > 0:
      cleanRegistry & "/" & target.imageName
    else:
      target.imageRepo
  imageRepo & ":" & tag

proc buildCommand(
  root: string,
  target: DockerTarget,
  fullTag,
  platforms: string,
  push: bool
): string =
  ## Builds the docker buildx command for one target.
  let dockerFile = target.contextDir / target.dockerFile
  var args = @["docker", "buildx", "build"]

  if push or "," notin platforms:
    args.add("--platform")
    args.add(platforms)

  args.add("-f")
  args.add(dockerFile)
  if target.bitworldContext.len > 0:
    args.add("--build-context")
    args.add("bitworld=" & target.bitworldContext)
  args.add("-t")
  args.add(fullTag)
  args.add("--provenance=false")
  args.add("--sbom=false")
  if push:
    args.add("--push")
  else:
    args.add("--load")
  args.add(target.contextDir)

  quoteShellCommand(args)

proc buildImage(
  root: string,
  target: DockerTarget,
  registry: string,
  tag: string,
  platforms: string,
  push: bool
) =
  ## Builds one Docker image with buildx.
  let
    dockerFile = target.contextDir / target.dockerFile
    imageTag = target.fullImageTag(registry, tag)

  if not fileExists(dockerFile):
    echo "Error: ", dockerFile, " not found."
    quit(1)

  echo ""
  echo "Building ", imageTag
  echo "  target:     ", target.name
  echo "  dockerfile: ", dockerFile.relativePath(root)
  echo "  context:    ", target.contextDir.relativePath(root)
  if target.bitworldContext.len > 0:
    echo "  bitworld:   ", target.bitworldContext.relativePath(root)
  echo "  platforms:  ", platforms
  echo "  push:       ", push

  if not push and "," in platforms:
    echo "  Note: --load only supports single platform."
    echo "  Building for native arch only."

  let code = execCmd(
    buildCommand(root, target, imageTag, platforms, push)
  )
  if code != 0:
    echo "Error: build failed for ", target.name
    quit(1)

  echo "  Done: ", imageTag

proc selectedTargets(
  root: string,
  targets: openArray[DockerTarget],
  names: openArray[string],
  includeBots: bool
): seq[DockerTarget] =
  ## Selects requested targets or returns every discovered target.
  if names.len == 0:
    return @targets

  let targetsByName = targetMap(targets)
  for name in names:
    let normalized = normalizeTargetName(name)
    let files = targetFiles(targets, normalized)
    if files.len > 1:
      echo "Error: ambiguous Docker target: ", name
      for file in files:
        echo "  ", file
      quit(1)
    if normalized notin targetsByName:
      let pathTarget = dockerTargetFromPath(root, name)
      if pathTarget.found:
        result.addUniqueTarget(pathTarget.target)
        if includeBots:
          result.addBotTargets(targets, pathTarget.target)
        continue
      if pathTarget.message.len > 0:
        echo "Error: ", pathTarget.message
        quit(1)
      echo "Error: unknown Docker target: ", name
      echo "Run with --list to see available targets."
      quit(1)
    let target = targetsByName[normalized]
    result.addUniqueTarget(target)
    if includeBots:
      result.addBotTargets(targets, target)

proc printTargets(root: string, targets: openArray[DockerTarget]) =
  ## Prints all discovered Docker targets.
  echo "Available targets:"
  for target in targets:
    echo "  ", target.name, " -> ", target.imageRepo
    echo "    ", (target.contextDir / target.dockerFile).relativePath(root)
    if target.bitworldContext.len > 0:
      echo "    context: ", target.contextDir.relativePath(root)
    if target.games.len > 0:
      echo "    games: ", target.games.join(", ")

proc targetNames(targets: openArray[DockerTarget]): string =
  ## Formats target names for status output.
  var names: seq[string]
  for target in targets:
    names.add(target.name)
  names.join(", ")

proc main() =
  ## Parses command line options and builds requested Docker targets.
  let
    root = repoRoot()
    currentRoot = absolutePath(getCurrentDir())
  var
    push = false
    platforms = DefaultPlatforms
    tag = "latest"
    registry = DefaultRegistry
    includeBots = false
    names: seq[string]

    targets = discoverTargets(root)
  if not currentRoot.samePath(root):
    for target in discoverTargets(currentRoot, root):
      targets.addUniqueTarget(target)
    targets.sort(proc(a, b: DockerTarget): int =
      cmp(a.name, b.name)
    )

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "push":
        push = true
      of "bots":
        includeBots = true
      of "platform":
        platforms = val
      of "tag":
        tag = val
      of "registry":
        registry = val
      of "list":
        printTargets(root, targets)
        quit(0)
      of "help":
        usage()
      else:
        echo "Unknown option: --", key
        usage()
    of cmdShortOption:
      case key
      of "h":
        usage()
      else:
        echo "Unknown option: -", key
        usage()
    of cmdArgument:
      names.add(key)
    of cmdEnd:
      discard

  let chosen = selectedTargets(root, targets, names, includeBots)
  let registryLabel =
    if registry.len > 0:
      registry
    else:
      "from manifests"

  echo "docker_build"
  echo "  registry:  ", registryLabel
  echo "  tag:       ", tag
  echo "  platforms: ", platforms
  echo "  push:      ", push
  echo "  bots:      ", includeBots
  echo "  targets:   ", targetNames(chosen)

  checkTournamentArgs(root, chosen)

  ensureBuildx()
  if push or "," in platforms:
    ensureBuilder()

  for target in chosen:
    buildImage(root, target, registry, tag, platforms, push)

  echo ""
  echo "All builds complete."

main()

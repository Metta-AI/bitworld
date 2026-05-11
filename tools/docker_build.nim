## Builds multi-arch Docker images for bitworld and pushes them to GHCR.
##
## games_server/games_server.nim pulls images from GHCR at runtime to launch
## game and bot containers (e.g. ghcr.io/treeform/bitworld-among-them-runner).
## Dockerfiles live beside their game or player manifests.
##
## This tool wraps `docker buildx` to produce a multi-arch OCI manifest so
## the same image tag works on both x86_64 (AWS/Linux) and arm64 (macOS).
## Without multi-arch, pulling on the wrong host falls back to slow QEMU
## binfmt emulation instead of running natively.
##
## Usage:
##   nim r tools/docker_build.nim --push              # build + push all
##   nim r tools/docker_build.nim --push among_them   # just the game server
##   nim r tools/docker_build.nim --list              # show targets
##
## Prerequisites:
##   - docker buildx.
##   - On Linux, docker-buildx-plugin may need to be installed.
##   - GHCR auth: echo $PAT | docker login ghcr.io -u USERNAME --password-stdin

import
  std/[algorithm, json, os, osproc, parseopt, strutils, tables]

const
  Registry = "ghcr.io/treeform"
  DefaultPlatforms = "linux/amd64,linux/arm64"
  CoworldManifestName = "coworld_manifest.json"
  CoplayerManifestName = "coplayer_manifest.json"
  ManifestNames = [CoworldManifestName, CoplayerManifestName]
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
    dockerFile: string

proc usage() =
  ## Prints usage and exits.
  echo """Usage: docker_build [OPTIONS] [TARGETS...]

Build multi-arch Docker images for bitworld.

Targets are discovered from Dockerfile locations.

Options:
  --push            Push images to GHCR after building
  --platform:STR    Platforms to build (default: linux/amd64,linux/arm64)
  --tag:STR         Image tag (default: latest)
  --registry:STR    Registry prefix (default: ghcr.io/treeform)
  --list            List available targets and exit
  --help            Show this help"""
  quit(0)

proc repoRoot(): string =
  ## Returns the repository root directory.
  currentSourcePath().parentDir.parentDir

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
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    return node[key].getStr()
  if node.kind == JObject and node.hasKey("game") and
      node["game"].kind == JObject:
    let game = node["game"]
    if game.hasKey(key) and game[key].kind == JString:
      return game[key].getStr()
    if key == "image_uri" and game.hasKey("runnable") and
        game["runnable"].kind == JObject:
      let runnable = game["runnable"]
      if runnable.hasKey("image") and runnable["image"].kind == JString:
        return runnable["image"].getStr()
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
    genericPlayerDirs = ["ai", "bot", "bots", "coplayer", "player", "players"]
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
      imageUri = matched.nodeString("image_uri")
    if imageUri.len > 0:
      result = (name: name, imageUri: imageUri)

proc imageNameForTarget(
  targetName: string,
  manifestImageUri: string
): string =
  ## Returns the GHCR package name for one Docker target.
  result = imageNameFromUri(manifestImageUri)
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
  dockerFile: string,
  targets: var seq[DockerTarget]
) =
  ## Adds one Dockerfile when it belongs to a known game or manifest.
  let
    dir = dockerFile.parentDir()
    manifest = manifestPath(dir)
    playerImage = coworldPlayerImage(manifest, dir.extractFilename())
  var
    manifestName = manifestString(manifest, "name")
    manifestImageUri = manifestString(manifest, "image_uri")
  if manifest.len > 0 and manifest.parentDir() != dir and playerImage.imageUri.len > 0:
    manifestName = playerImage.name
    manifestImageUri = playerImage.imageUri
  if manifestName.len == 0 or manifestImageUri.len == 0:
    return
  var targetName =
    normalizeTargetName(manifestName)

  if targetName.len == 0:
    return

  targets.add DockerTarget(
    name: targetName,
    imageName: imageNameForTarget(targetName, manifestImageUri),
    dockerFile: dockerFile.relativePath(root)
  )

proc scanDockerFiles(
  root,
  dir: string,
  targets: var seq[DockerTarget]
) =
  ## Recursively scans for Dockerfiles under non-generated directories.
  for kind, path in walkDir(dir):
    case kind
    of pcDir:
      if shouldScanDir(path):
        scanDockerFiles(root, path, targets)
    of pcFile, pcLinkToFile:
      if path.extractFilename() == "Dockerfile":
        addDockerFile(root, path, targets)
    else:
      discard

proc discoverTargets(root: string): seq[DockerTarget] =
  ## Discovers all Docker build targets in the repository.
  scanDockerFiles(root, root, result)
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
      result.add(target.dockerFile)

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
  registry & "/" & target.imageName & ":" & tag

proc buildCommand(
  root: string,
  target: DockerTarget,
  fullTag,
  platforms: string,
  push: bool
): string =
  ## Builds the docker buildx command for one target.
  let dockerFile = root / target.dockerFile
  var args = @["docker", "buildx", "build"]

  if push or "," notin platforms:
    args.add("--platform")
    args.add(platforms)

  args.add("-f")
  args.add(dockerFile)
  args.add("-t")
  args.add(fullTag)
  if push:
    args.add("--push")
  else:
    args.add("--load")
  args.add(root)

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
    dockerFile = root / target.dockerFile
    imageTag = target.fullImageTag(registry, tag)

  if not fileExists(dockerFile):
    echo "Error: ", dockerFile, " not found."
    quit(1)

  echo ""
  echo "Building ", imageTag
  echo "  target:     ", target.name
  echo "  dockerfile: ", target.dockerFile
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
  targets: openArray[DockerTarget],
  names: openArray[string]
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
      echo "Error: unknown Docker target: ", name
      echo "Run with --list to see available targets."
      quit(1)
    result.add(targetsByName[normalized])

proc printTargets(targets: openArray[DockerTarget]) =
  ## Prints all discovered Docker targets.
  echo "Available targets:"
  for target in targets:
    echo "  ", target.name, " -> ", target.imageName
    echo "    ", target.dockerFile

proc targetNames(targets: openArray[DockerTarget]): string =
  ## Formats target names for status output.
  var names: seq[string]
  for target in targets:
    names.add(target.name)
  names.join(", ")

proc main() =
  ## Parses command line options and builds requested Docker targets.
  let root = repoRoot()
  var
    push = false
    platforms = DefaultPlatforms
    tag = "latest"
    registry = Registry
    names: seq[string]

  let targets = discoverTargets(root)

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "push":
        push = true
      of "platform":
        platforms = val
      of "tag":
        tag = val
      of "registry":
        registry = val
      of "list":
        printTargets(targets)
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

  let chosen = selectedTargets(targets, names)

  echo "docker_build"
  echo "  registry:  ", registry
  echo "  tag:       ", tag
  echo "  platforms: ", platforms
  echo "  push:      ", push
  echo "  targets:   ", targetNames(chosen)

  ensureBuildx()
  if push or "," in platforms:
    ensureBuilder()

  for target in chosen:
    buildImage(root, target, registry, tag, platforms, push)

  echo ""
  echo "All builds complete."

main()

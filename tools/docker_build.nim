## Builds multi-arch Docker images for bitworld and pushes them to GHCR.
##
## games_server/games_server.nim pulls images from GHCR at runtime to launch
## game and bot containers (e.g. ghcr.io/treeform/bitworld-among-them-runner).
## Dockerfiles live beside their game or player manifests, or in the owning
## game directory for older games that do not have manifests yet.
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
  ManifestNames = ["cogame_manifest.json", "coplayer_manifest.json"]
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
  KnownImageNames = {
    "among_them": "bitworld-among-them-runner",
    "nottoodumb": "bitworld-nottoodumb",
    "ivotewell": "bitworld-ivotewell",
    "italkalot": "bitworld-italkalot",
    "evidencebot_v2": "bitworld-evidencebot-v2",
    "lively_lecun": "bitworld-lively-lecun",
    "evidencebot_v2": "bitworld-evidencebot-v2",
    "big_adventure": "bitworld-big-adventure",
    "party_progressor": "bitworld-party-progressor",
    "fancy_cookout": "bitworld-fancy-cookout",
    "infinite_factory": "bitworld-infinite-factory",
    "planet_wars": "bitworld-planet-wars",
  }.toTable

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

proc manifestString(path, key: string): string =
  ## Reads one string field from a JSON manifest.
  if path.len == 0:
    return ""
  let node = parseFile(path)
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr()
  else:
    ""

proc fallbackTargetName(dir: string): string =
  ## Returns the target name for older Dockerfiles without manifests.
  let name = dir.extractFilename()
  if name == "boundless_factory":
    "infinite_factory"
  else:
    normalizeTargetName(name)

proc imageNameForTarget(
  targetName: string,
  manifestImageUri: string
): string =
  ## Returns the GHCR package name for one Docker target.
  if targetName in KnownImageNames:
    return KnownImageNames[targetName]
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
    manifestName = manifestString(manifest, "name")
    manifestImageUri = manifestString(manifest, "image_uri")
  var targetName =
    if manifestName.len > 0:
      normalizeTargetName(manifestName)
    else:
      fallbackTargetName(dir)

  if targetName.len == 0:
    return
  if manifest.len == 0 and targetName notin KnownImageNames:
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
  ## Builds a lookup table and rejects duplicate target names.
  for target in targets:
    if target.name in result:
      echo "Error: duplicate Docker target: ", target.name
      echo "  ", result[target.name].dockerFile
      echo "  ", target.dockerFile
      quit(1)
    result[target.name] = target

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

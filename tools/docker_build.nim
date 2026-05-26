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
##   nim r tools/docker_build.nim --push ../cogame-jumper
##   nim r tools/docker_build.nim players/nottoodumb/Dockerfile
##
## Prerequisites:
##   - docker buildx.
##   - On Linux, docker-buildx-plugin may need to be installed.
##   - Registry auth for any manifest image path you push.

import
  std/[json, os, osproc, parseopt, strutils]

const
  DefaultRegistry = ""
  DefaultPlatforms = "linux/amd64,linux/arm64"
  EcrProfileName = "sandbox-andre"
  CoworldManifestName = "coworld_manifest.json"
  ManifestNames = [CoworldManifestName]

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
  echo """Usage: docker_build [OPTIONS] PATH...

Build multi-arch Docker images for bitworld.

Each PATH must be a Dockerfile or a directory containing one.

Options:
  --push            Push images after building
  --platform:STR    Platforms to build (default: linux/amd64,linux/arm64)
  --tag:STR         Image tag (default: latest)
  --registry:STR    Override manifest registry prefix
  --help            Show this help"""
  quit(0)

proc pathExists(path: string): bool =
  ## Returns true when a filesystem path exists.
  fileExists(path) or dirExists(path)

proc contextRootForDockerfile(dockerFile: string): string =
  ## Returns the repository context for one explicit Dockerfile path.
  result = dockerFile.parentDir()
  var dir = result
  while true:
    var hasNimble = false
    for kind, path in walkDir(dir):
      if kind == pcFile and path.splitFile().ext == ".nimble":
        hasNimble = true
        break
    if hasNimble or fileExists(dir / CoworldManifestName):
      return dir
    let parent = dir.parentDir()
    if parent == dir or parent.len == 0:
      break
    dir = parent

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

proc dockerTargetFromPath(
  root,
  path: string
): tuple[found: bool, target: DockerTarget, message: string] =
  ## Reads one Docker target from an explicit path argument.
  let rawPath =
    if path.isAbsolute():
      path
    else:
      absolutePath(root / path)
  if not rawPath.pathExists():
    return (
      found: false,
      target: DockerTarget(),
      message: "Path not found: " & rawPath
    )
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

  let contextDir = contextRootForDockerfile(dockerFile)
  var targets: seq[DockerTarget]
  addDockerFile(root, contextDir, "", dockerFile, targets)
  if targets.len == 0:
    return (
      found: false,
      target: DockerTarget(),
      message: "No manifest found for Dockerfile: " & dockerFile
    )

  result = (found: true, target: targets[0], message: "")

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

const
  TournamentArgs = ["name", "token", "slot"]
  TournamentEnv = "COWORLD_PLAYER_WS_URL"

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

proc isEcrRegistry(imageUri: string): bool =
  ## Returns true when an image URI targets any ECR registry (public or private).
  (".dkr.ecr." in imageUri and ".amazonaws.com" in imageUri) or
    imageUri.startsWith("public.ecr.aws/")

proc ecrEndpoint(imageUri: string): string =
  ## Extracts the ECR endpoint (host) from a full image URI.
  let parts = imageUri.strip().split('/')
  if parts.len > 0:
    return parts[0]

proc ecrRegion(endpoint: string): string =
  ## Parses the AWS region from a private ECR endpoint hostname.
  let parts = endpoint.split('.')
  for i, part in parts:
    if part == "ecr" and i + 1 < parts.len:
      return parts[i + 1]
  "us-east-1"

proc ensureEcrAuth(endpoint: string) =
  ## Authenticates Docker to an ECR endpoint using sandbox-andre.
  ## Public ECR (public.ecr.aws) and private ECR use different auth commands.
  let isPublic = endpoint == "public.ecr.aws"
  let region = if isPublic: "us-east-1" else: ecrRegion(endpoint)
  echo "Authenticating to ECR: ", endpoint, " (", region, ")"
  let cmd =
    if isPublic:
      "aws ecr-public get-login-password --profile " & EcrProfileName &
        " --region " & region
    else:
      "aws ecr get-login-password --profile " & EcrProfileName &
        " --region " & region
  let (password, code) = execCmdEx(cmd)
  if code != 0:
    echo "Error: ECR auth failed."
    echo "Run: aws sso login --profile ", EcrProfileName
    quit(1)
  let loginCode = execCmd(
    "echo " & quoteShell(password.strip()) &
    " | docker login --username AWS --password-stdin " & endpoint
  )
  if loginCode != 0:
    echo "Error: docker login to ECR failed."
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

proc targetNames(targets: openArray[DockerTarget]): string =
  ## Formats target names for status output.
  var names: seq[string]
  for target in targets:
    names.add(target.name)
  names.join(", ")

proc main() =
  ## Parses command line options and builds requested Docker targets.
  let root = absolutePath(getCurrentDir())
  var
    push = false
    platforms = DefaultPlatforms
    tag = "latest"
    registry = DefaultRegistry
    names: seq[string]

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

  if names.len == 0:
    echo "Error: docker_build requires at least one explicit path."
    usage()

  var chosen: seq[DockerTarget]
  for name in names:
    let target = dockerTargetFromPath(root, name)
    if target.found:
      chosen.addUniqueTarget(target.target)
    else:
      echo "Error: ", target.message
      quit(1)

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
  echo "  targets:   ", targetNames(chosen)

  checkTournamentArgs(root, chosen)

  if push:
    var needsAws = false
    for target in chosen:
      if isEcrRegistry(target.fullImageTag(registry, tag)):
        needsAws = true
        break
    if needsAws:
      let (_, awsCode) = execCmdEx("aws --version")
      if awsCode != 0:
        echo "Error: aws CLI is required for ECR push but not found in PATH."
        quit(1)

  ensureBuildx()
  if push or "," in platforms:
    ensureBuilder()

  if push:
    var authedEcrEndpoints: seq[string]
    for target in chosen:
      let imageTag = target.fullImageTag(registry, tag)
      if isEcrRegistry(imageTag):
        let endpoint = ecrEndpoint(imageTag)
        if endpoint notin authedEcrEndpoints:
          ensureEcrAuth(endpoint)
          authedEcrEndpoints.add(endpoint)

  for target in chosen:
    buildImage(root, target, registry, tag, platforms, push)

  echo ""
  echo "All builds complete."

main()

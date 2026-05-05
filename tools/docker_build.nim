## Builds multi-arch Docker images for bitworld and pushes them to GHCR.
##
## games_server/games_server.nim pulls images from GHCR at runtime to launch
## game and bot containers (e.g. ghcr.io/treeform/bitworld-among-them-runner).
## The Dockerfiles live in games_server/*.docker and already handle both
## amd64 and arm64 via architecture-conditional nimby downloads.
##
## This tool wraps `docker buildx` to produce a multi-arch OCI manifest so
## the same image tag works on both x86_64 (AWS/Linux) and arm64 (macOS).
## Without multi-arch, pulling on the wrong host falls back to slow QEMU
## binfmt emulation instead of running natively.
##
## Usage:
##   nim r tools/docker_build.nim -- --push              # build + push all
##   nim r tools/docker_build.nim -- --push among_them   # just the game server
##   nim r tools/docker_build.nim -- --list              # show targets
##
## Prerequisites:
##   - docker buildx (ships with Docker Desktop; on Linux: apt install docker-buildx-plugin)
##   - GHCR auth: echo $PAT | docker login ghcr.io -u USERNAME --password-stdin

import std/[os, osproc, parseopt, strutils, tables]

const
  Registry = "ghcr.io/treeform"
  DefaultPlatforms = "linux/amd64,linux/arm64"

  # Maps dockerfile basenames to their GHCR image names.
  # These must match the constants in games_server/games_server.nim
  # (DefaultDockerImage, DefaultNotTooDumbImage, etc).
  ImageNames = {
    "among_them": "bitworld-among-them-runner",
    "nottoodumb": "bitworld-nottoodumb",
    "ivotewell": "bitworld-ivotewell",
    "italkalot": "bitworld-italkalot",
    "big_adventure": "bitworld-big-adventure",
    "fancy_cookout": "bitworld-fancy-cookout",
    "infinite_factory": "bitworld-infinite-factory",
    "planet_wars": "bitworld-planet-wars",
  }.toTable

proc usage() =
  ## Prints usage and exits.
  echo """Usage: docker_build [OPTIONS] [TARGETS...]

Build multi-arch Docker images for bitworld.

Targets are dockerfile basenames (e.g. "among_them", "nottoodumb").
If no targets are given, all images are built.

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

proc buildImage(
  target: string,
  registry: string,
  tag: string,
  platforms: string,
  push: bool
) =
  ## Builds one Docker image with buildx.
  let
    root = repoRoot()
    dockerFile = root / "games_server" / (target & ".docker")
    imageName = if target in ImageNames: ImageNames[target]
                else: "bitworld-" & target
    fullTag = registry & "/" & imageName & ":" & tag

  if not fileExists(dockerFile):
    echo "Error: ", dockerFile, " not found."
    quit(1)

  echo ""
  echo "Building ", fullTag
  echo "  dockerfile: ", dockerFile
  echo "  platforms:  ", platforms
  echo "  push:       ", push

  var cmd = "docker buildx build" &
    " --platform " & platforms &
    " -f " & dockerFile &
    " -t " & fullTag

  if push:
    cmd &= " --push"
  else:
    cmd &= " --load"

  cmd &= " " & root

  # --load doesn't work with multi-platform, fall back to single build.
  if not push and "," in platforms:
    echo "  Note: --load only supports single platform. Building for native arch only."
    cmd = "docker buildx build" &
      " -f " & dockerFile &
      " -t " & fullTag &
      " --load " & root

  let code = execCmd(cmd)
  if code != 0:
    echo "Error: build failed for ", target
    quit(1)

  echo "  Done: ", fullTag

proc main() =
  var
    push = false
    platforms = DefaultPlatforms
    tag = "latest"
    registry = Registry
    targets: seq[string]

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "push": push = true
      of "platform": platforms = val
      of "tag": tag = val
      of "registry": registry = val
      of "list":
        echo "Available targets:"
        for k in ImageNames.keys:
          echo "  ", k, " -> ", ImageNames[k]
        quit(0)
      of "help": usage()
      else:
        echo "Unknown option: --", key
        usage()
    of cmdShortOption:
      case key
      of "h": usage()
      else:
        echo "Unknown option: -", key
        usage()
    of cmdArgument:
      targets.add(key)
    of cmdEnd:
      discard

  if targets.len == 0:
    for k in ImageNames.keys:
      targets.add(k)

  echo "docker_build"
  echo "  registry:  ", registry
  echo "  tag:       ", tag
  echo "  platforms: ", platforms
  echo "  push:      ", push
  echo "  targets:   ", targets.join(", ")

  ensureBuildx()
  if push or "," in platforms:
    ensureBuilder()

  for target in targets:
    buildImage(target, registry, tag, platforms, push)

  echo ""
  echo "All builds complete."

main()

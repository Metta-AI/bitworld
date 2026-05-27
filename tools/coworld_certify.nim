import
  std/[os, parseopt, strutils],
  ../games_server/cogame_validator

const
  CoworldManifestName = "coworld_manifest.json"

type
  CoworldCertifyError = object of CatchableError

  CertifyArgs = object
    game: string
    config: ValidatorConfig

proc fail(message: string) =
  ## Raises one command-line certification error.
  raise newException(CoworldCertifyError, message)

proc repoRoot(): string =
  ## Returns the BitWorld repository root containing this tool.
  parentDir(parentDir(currentSourcePath()))

proc usage(): string =
  ## Returns command-line usage text.
  """
Usage:
  coworld_certify [options] <game-or-manifest>

Options:
  --timeout:<seconds>     Docker and endpoint timeout. Default: 60.
  --workspace:<path>      Artifact workspace. Default: bitworld/tmp.
  --docker:<path>         Docker command. Default: docker or env override.
  --skip-images           Skip Docker image inspect checks.
  --no-run                Certify manifest and write config only.
  --help                  Show this help.

Examples:
  coworld_certify among_them --no-run
  coworld_certify crewrift --skip-images
  coworld_certify games_server/games/planet_wars/coworld_manifest.json
"""

proc cleanGameName(value: string): string =
  ## Returns a normalized game key.
  result = value.strip().replace("\\", "/")
  while result.startsWith("./"):
    result = result[2 .. ^1]
  while result.len > 0 and result[^1] == '/':
    result.setLen(result.len - 1)

proc pathFromArg(value: string): string =
  ## Returns an absolute path for one command-line path.
  if value.isAbsolute():
    value
  else:
    absolutePath(value)

proc addUnique(paths: var seq[string], path: string) =
  ## Adds a path candidate if it is not already present.
  if path.len > 0 and path notin paths:
    paths.add(path)

proc manifestCandidates(root, game: string): seq[string] =
  ## Returns possible Coworld manifest paths for one game argument.
  let
    cleanGame = game.cleanGameName()
    explicitPath = pathFromArg(cleanGame)

  result.addUnique(explicitPath)
  result.addUnique(explicitPath / CoworldManifestName)

  result.addUnique(root / "games_server" / "games" / cleanGame)
  result.addUnique(
    root / "games_server" / "games" / cleanGame / CoworldManifestName
  )
  result.addUnique(root / cleanGame)
  result.addUnique(root / cleanGame / CoworldManifestName)

proc resolveManifestPath(root, game: string): string =
  ## Resolves a game name, folder, or manifest path to a Coworld manifest.
  for path in manifestCandidates(root, game):
    if fileExists(path) and path.extractFilename() == CoworldManifestName:
      return path
    if dirExists(path) and fileExists(path / CoworldManifestName):
      return path / CoworldManifestName
  fail("Coworld manifest not found for: " & game)

proc parseFloatOption(value, option: string): float =
  ## Parses one floating-point command-line option.
  try:
    result = value.parseFloat()
  except ValueError:
    fail(option & " must be a number")

proc parseArgs(): CertifyArgs =
  ## Parses command-line arguments.
  result.config = defaultValidatorConfig()
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if result.game.len > 0:
        fail("only one game or manifest may be provided")
      result.game = key
    of cmdLongOption:
      if key.len == 0:
        continue
      case key
      of "timeout":
        result.config.timeoutSeconds = parseFloatOption(val, "--timeout")
      of "workspace":
        result.config.workspace = val
      of "docker":
        result.config.dockerBin = val
      of "skip-images":
        result.config.checkImages = false
      of "no-run":
        result.config.runContainers = false
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
    of cmdEnd:
      discard
  if result.game.len == 0:
    echo usage()
    quit(1)

proc statusText(status: CriterionStatus): string =
  ## Returns a display label for one criterion status.
  case status
  of CriterionPass:
    "PASS"
  of CriterionFail:
    "FAIL"
  of CriterionSkip:
    "SKIP"

proc printCriteria(criteria: openArray[ValidationCriterion]) =
  ## Prints certification criteria in a command-line friendly format.
  for criterion in criteria:
    var line = "[" & statusText(criterion.status) & "] " & criterion.id
    line.add(" - " & criterion.name)
    if criterion.message.len > 0:
      line.add(": " & criterion.message)
    echo line

proc run() =
  ## Runs the Coworld certifier command-line tool.
  try:
    let
      args = parseArgs()
      manifestPath = resolveManifestPath(repoRoot(), args.game)
      result = certifyManifest(manifestPath, args.config)

    echo "Certification criteria:"
    printCriteria(result.criteria)
    if result.coworld.manifestPath.len > 0:
      echo "Coworld: ", result.coworld.manifestPath
    if result.artifacts.workspace.len > 0:
      echo "Artifacts: ", result.artifacts.workspace
      echo "Results: ", result.artifacts.resultsPath
      echo "Replay: ", result.artifacts.replayPath
      echo "Logs: ", result.artifacts.logsDir
  except CoworldCertifyError as e:
    stderr.writeLine("coworld_certify failed: " & e.msg)
    quit(1)
  except CogameValidatorError as e:
    stderr.writeLine("coworld_certify failed: " & e.msg)
    quit(1)
  except CatchableError as e:
    stderr.writeLine("coworld_certify failed: " & e.msg)
    quit(1)

run()

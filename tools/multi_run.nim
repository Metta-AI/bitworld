import
  std/[os, parseopt, strutils, tables, times],
  bitworld/multiruns

const
  DefaultGames = 1
  DefaultMaxGames = 1
  PollIntervalMs = 1000

type
  MultiRunConfig = object
    manifestPath: string
    games: int
    maxGames: int
    useEcs: bool
    botGroups: seq[BotGroup]

  ActiveJob = object
    meta: GameMeta
    playersByName: Table[string, PlayerManifest]

var
  currentRunId = ""
  cleanupStarted = false

proc usage(): string =
  ## Returns command-line usage text.
  "Usage: multi_run <manifest> [--games:N] [--max-games:N] " &
    "--bots:BOT:N[:ROLE]\n" &
    "Examples:\n" &
    "  multi_run games_server/games/crewrift/coworld_manifest.json " &
    "--games:10 --max-games:2 --bots:notsus:8\n" &
    "  multi_run games_server/games/crewrift/coworld_manifest.json " &
    "--games:50 --max-games:5 --bots:notsus:6:crew " &
    "--bots:truecrew:2:imposter"

proc pathFromArg(value: string): string =
  ## Returns an absolute path from the current working directory.
  if value.isAbsolute():
    value
  else:
    absolutePath(getCurrentDir() / value)

proc parseArgs(): MultiRunConfig =
  ## Parses command-line options for the multi-run launcher.
  var positional: seq[string]
  result.games = DefaultGames
  result.maxGames = DefaultMaxGames
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      positional.add(key)
    of cmdLongOption:
      case key
      of "":
        discard
      of "games":
        if val.len == 0:
          raise newException(MultiRunError, "--games requires a value.")
        result.games = parsePositiveInt(val, "--games")
      of "max-games":
        if val.len == 0:
          raise newException(MultiRunError, "--max-games requires a value.")
        result.maxGames = parsePositiveInt(val, "--max-games")
      of "bots":
        if val.len == 0:
          raise newException(MultiRunError, "--bots requires a value.")
        result.botGroups.add(parseBotGroup(val))
      of "ecs":
        result.useEcs = true
      else:
        raise newException(MultiRunError, "unknown option: --" & key)
    of cmdShortOption:
      raise newException(MultiRunError, "unknown option: -" & key)
    of cmdEnd:
      discard
  if positional.len != 1:
    raise newException(MultiRunError, "expected one Coworld manifest path.")
  result.manifestPath = pathFromArg(positional[0])
  if not fileExists(result.manifestPath):
    raise newException(
      MultiRunError,
      "manifest not found: " & result.manifestPath
    )
  if result.botGroups.len == 0:
    raise newException(MultiRunError, "at least one --bots group is required.")
  if result.maxGames > result.games:
    result.maxGames = result.games

proc pullDockerImage(image: string) =
  ## Pulls one Docker image if the image name is not empty.
  if image.len > 0:
    echo "Pulling ", image, "..."
    discard requireDocker(@["pull", image])

proc pullImages(game: GameManifest, launches: openArray[BotLaunch]) =
  ## Pulls each unique Docker image needed by the run.
  var images: seq[string]
  if game.imageUri.len > 0:
    images.add(game.imageUri)
  for launch in launches:
    if launch.player.imageUri notin images:
      images.add(launch.player.imageUri)
  for image in images:
    pullDockerImage(image)

proc runningRunContainers(runId: string): seq[string] =
  ## Lists running Docker containers for one multi-run id.
  if runId.len == 0:
    return
  let res = dockerResult(@[
    "ps",
    "--filter",
    "label=" & OwnerLabelKey & "=" & OwnerLabelValue,
    "--filter",
    "label=" & RunLabel & "=" & runId,
    "--format",
    "{{.Names}}"
  ])
  if res.code != 0:
    echo "Could not list Docker containers: ", res.output.strip()
    return
  for line in res.output.splitLines():
    let name = line.strip()
    if name.len > 0:
      result.add(name)

proc killContainer(name: string) =
  ## Kills one Docker container and reports failures.
  let res = dockerResult(@["kill", name])
  if res.code == 0:
    echo "Killed ", name
  elif res.output.contains("is not running"):
    echo "Already stopped ", name
  else:
    echo "Could not kill ", name, ": ", res.output.strip()

proc cleanupCurrentRun() =
  ## Kills all running Docker containers for the current run.
  if cleanupStarted:
    return
  cleanupStarted = true
  if currentRunId.len == 0:
    return
  let names = runningRunContainers(currentRunId)
  if names.len == 0:
    echo "No running Docker containers for ", currentRunId, "."
    return
  echo "Killing ", names.len, " Docker containers for ", currentRunId, "..."
  for name in names:
    killContainer(name)

proc controlCHook() {.noconv.} =
  ## Cleans up the current run when the user presses Ctrl-C.
  echo ""
  echo "Ctrl-C received, cleaning up running multi-run containers..."
  cleanupCurrentRun()
  quit(130)

proc playersByName(launches: openArray[BotLaunch]): Table[string, PlayerManifest] =
  ## Builds a manifest lookup table by player name.
  for launch in launches:
    result[launch.player.name] = launch.player

proc newGameMeta(
  paths: RunPaths,
  game: GameManifest,
  runId: string,
  gameIndex,
  port: int,
  slots: seq[PlayerSlot]
): GameMeta =
  ## Builds initial metadata for one queued game.
  let
    replayName = gameFileName(gameIndex, ".bitreplay")
    resultsName = gameFileName(gameIndex, ".scores.json")
    configName = gameFileName(gameIndex, ".config.json")
  GameMeta(
    runId: runId,
    gameIndex: gameIndex,
    gameName: game.name,
    containerName: gameContainerName(runId, gameIndex),
    port: port,
    status: "planned",
    exitCode: -1,
    replay: paths.artifactRelativePath(replayName),
    results: paths.artifactRelativePath(resultsName),
    config: paths.artifactRelativePath(configName),
    created: getTime().toUnix(),
    slots: slots
  )

proc writeConfig(paths: RunPaths, game: GameManifest, meta: GameMeta) =
  ## Writes one per-game config JSON file into the run folder.
  let
    configName = meta.config.extractFilename()
    config = buildGameConfigJson(game.path, meta.slots)
  writeFile(paths.artifactHostPath(configName), config)

proc stopPlayerContainers(meta: GameMeta) =
  ## Stops running player containers for one completed game.
  for slot in meta.slots:
    try:
      let container = inspectContainer(slot.containerName)
      if container.isActiveContainer():
        discard dockerResult(@["stop", slot.containerName])
    except CatchableError:
      discard

proc startJob(
  paths: RunPaths,
  game: GameManifest,
  launches: openArray[BotLaunch],
  playerTable: Table[string, PlayerManifest],
  gameIndex: int
): ActiveJob =
  ## Starts one game container and its fixed roster of player containers.
  let
    port = findOpenPort()
    slots = buildSlots(paths.runId, gameIndex, launches)
  var meta = newGameMeta(paths, game, paths.runId, gameIndex, port, slots)
  paths.runDir.writeGameMeta(meta)
  writeConfig(paths, game, meta)
  echo "Starting game ", gameIndex, " on port ", port, "..."
  try:
    discard requireDocker(gameDockerArgs(paths, game, meta))
    if not waitForHealthy(port):
      raise newException(
        MultiRunError,
        "game " & $gameIndex & " did not become healthy in time."
      )
    for slot in meta.slots:
      let player = playerTable[slot.player]
      discard requireDocker(playerDockerArgs(player, meta, slot))
    meta.status = "running"
    paths.runDir.writeGameMeta(meta)
    result = ActiveJob(meta: meta, playersByName: playerTable)
  except CatchableError as e:
    meta.status = "failed"
    meta.exitCode = -1
    meta.finished = getTime().toUnix()
    paths.runDir.writeGameMeta(meta)
    stopPlayerContainers(meta)
    discard dockerResult(@["stop", meta.containerName])
    raise newException(
      MultiRunError,
      "could not start game " & $gameIndex & ": " & e.msg
    )

proc finishJob(paths: RunPaths, job: ActiveJob, container: ContainerInfo): GameMeta =
  ## Marks one active job as finished or failed.
  result = job.meta
  result.exitCode = container.exitCode
  result.finished = getTime().toUnix()
  if container.normalExit():
    result.status = "finished"
  else:
    result.status = "failed"
  stopPlayerContainers(result)
  paths.runDir.writeGameMeta(result)

proc activeNames(jobs: openArray[ActiveJob]): string =
  ## Returns a compact active game list for progress output.
  for job in jobs:
    if result.len > 0:
      result.add(", ")
    result.add("game_" & align($job.meta.gameIndex, 4, '0'))
  if result.len == 0:
    result = "-"

proc printProgress(
  total,
  started,
  finished,
  failed: int,
  active: openArray[ActiveJob]
) =
  ## Prints one queue progress line.
  let counts = queueCounts(total, started, active.len, finished, failed)
  echo "running ", counts.running, " / ", counts.total,
    ", finished ", counts.finished,
    ", failed ", counts.failed,
    ", queued ", counts.queued,
    ", active ", activeNames(active)

proc runMultiRun(config: MultiRunConfig): int =
  ## Runs the bounded local Docker multi-run queue.
  if config.useEcs:
    raise newException(MultiRunError, "--ecs is not implemented yet.")
  let
    game = readGameManifest(config.manifestPath)
    paths = allocateRunPaths()
  currentRunId = paths.runId
  validateRoles(game.path, config.botGroups)
  let launches = resolveBotLaunches(game, config.botGroups)
  if launches.botCount() <= 0:
    raise newException(MultiRunError, "bot count must be greater than zero.")
  paths.runDir.writeRunMeta(RunMeta(
    runId: paths.runId,
    manifest: game.key,
    gameName: game.name,
    totalGames: config.games,
    maxGames: config.maxGames,
    botCount: launches.botCount(),
    created: getTime().toUnix()
  ))
  echo "Run: ", paths.runId
  echo "Artifacts: ", paths.runDir
  echo "Game: ", game.name
  echo "Total games: ", config.games
  echo "Max active games: ", config.maxGames
  echo "Players per game: ", launches.botCount()
  pullImages(game, launches)

  let playerTable = launches.playersByName()
  var
    active: seq[ActiveJob]
    nextGame = 1
    finished = 0
    failed = 0
    started = 0
  while finished + failed < config.games:
    while active.len < config.maxGames and nextGame <= config.games:
      try:
        active.add(startJob(paths, game, launches, playerTable, nextGame))
      except MultiRunError as e:
        echo e.msg
        inc failed
      inc started
      inc nextGame
      printProgress(config.games, started, finished, failed, active)

    var stillActive: seq[ActiveJob]
    for job in active:
      try:
        let container = inspectContainer(job.meta.containerName)
        if container.isActiveContainer():
          stillActive.add(job)
        else:
          let meta = finishJob(paths, job, container)
          if meta.status == "finished":
            inc finished
          else:
            inc failed
      except CatchableError as e:
        var meta = job.meta
        meta.status = "failed"
        meta.exitCode = -1
        meta.finished = getTime().toUnix()
        paths.runDir.writeGameMeta(meta)
        stopPlayerContainers(meta)
        echo "lost game ", meta.gameIndex, ": ", e.msg
        inc failed
    active = stillActive
    printProgress(config.games, started, finished, failed, active)
    if finished + failed < config.games:
      sleep(PollIntervalMs)

  echo "Multi run complete: ", finished, " finished, ", failed, " failed."
  echo "Report artifacts: ", paths.runDir
  if failed > 0:
    return 1

when isMainModule:
  setControlCHook(controlCHook)
  try:
    quit(runMultiRun(parseArgs()))
  except MultiRunError as e:
    echo e.msg
    echo usage()
    quit(1)

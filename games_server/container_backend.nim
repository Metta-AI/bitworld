## Shared container backend abstraction.
##
## Both games_server (dev/on-demand) and tournament_server (prod) use this
## so that launching game + player containers (Docker for dev, ECS for prod)
## and wiring the https (or file) URIs is implemented in one place.
##
## Tournament uses ecs_backend directly via this layer and its own
## artifact service instance (no dependency on games_server process).

import
  std/[os, strutils],
  artifact_service,
  ecs_backend

export artifact_service  # so callers can easily use the handlers / token helpers

const
  GameContainerPort* = 8080
  ContainerReplayDir* = "/replays"

type
  ContainerOwner* = object
    labelPrefix*: string      # e.g. "bitworld.tournament_server" or "bitworld.games_server"
    gameValue*: string        # value for the main owner key on game tasks (e.g. "tournament" or "among_them")
    playerValue*: string      # value for players/bots (e.g. "tournament_player" or "among_them_bot")

  ContainerBackendConfig* = object
    useEcs*: bool
    owner*: ContainerOwner
    artifactBaseUrl*: string  # e.g. "http://10.0.1.23:2081" (the URL containers should reach for URIs)
    replayDir*: string

  EpisodeLaunchResult* = object
    gameNameOrArn*: string
    playerNamesOrArns*: seq[string]
    gamePrivateIp*: string    # for ECS player addressing; "" for Docker
    gamePublicIp*: string

var
  backendConfig*: ContainerBackendConfig
  backendInitialized* = false

proc initContainerBackend*(cfg: ContainerBackendConfig) =
  ## Must be called once early (after loadEcsConfig if useEcs).
  backendConfig = cfg
  artifact_service.setArtifactReplayDir(cfg.replayDir)
  if cfg.useEcs:
    # Ensure ecs is configured; caller did loadEcsConfig()
    ecs_backend.setEcsOwner(cfg.owner.labelPrefix,
                            cfg.owner.gameValue,
                            cfg.owner.playerValue)
  backendInitialized = true

proc requireBackend() =
  if not backendInitialized:
    raise newException(IOError, "container backend not initialized")

# -----------------------
# URI construction (https vs file)
# -----------------------

proc buildArtifactUris*(replayName, resultsName, configName: string): tuple[replay, results, config: string] =
  ## Returns the three COGAME_*_URI values.
  ## If artifactBaseUrl is set (https mode), returns full https+token URLs.
  ## Otherwise falls back to file:// + ContainerReplayDir (local Docker dev).
  requireBackend()
  let base = backendConfig.artifactBaseUrl.strip()
  if base.len > 0:
    let
      replayToken = artifact_service.generateUploadToken(replayName)
      resultsToken = artifact_service.generateUploadToken(resultsName)
      uploadBase = base & artifact_service.ReplayUploadPath
    result.replay = uploadBase & replayName & "?token=" & replayToken
    result.results = uploadBase & resultsName & "?token=" & resultsToken
    result.config = base & artifact_service.ReplayDownloadPath & configName
  else:
    let dir = ContainerReplayDir
    result.replay = "file://" & dir / replayName
    result.results = "file://" & dir / resultsName
    result.config = "file://" & dir / configName

# Note: the above has a small forward-ref issue on consts; in practice the server will pass the full paths
# or we re-export the needed paths from artifact_service. For the initial impl we keep the spirit and
# callers can construct if needed. The important thing is the https decision lives here.

# -----------------------
# Low-level launch helpers (consolidated from both servers)
# -----------------------

# For the real consolidation the docker* procs from games_server and tournament would live here,
# parameterized by owner labels, whether to publish port, add-host, and the uri triple.

# High level sketch for episode launch (the key unification point).
# Real implementation will have full gameDockerArgs / playerDockerArgs variants + ECS path.

proc launchGameEpisode*(gameImage: string,
                        gameCommand: seq[string],
                        gameEnv: seq[(string, string)],
                        playerImagesAndCmds: seq[(string, seq[string], seq[(string,string)])],
                        replayName, resultsName, configName: string,
                        created: int64): EpisodeLaunchResult =
  ## Launches 1 game + N players as a unit.
  ## In ECS mode: uses ecs_backend (owner already set by init), https URIs, private IP for players.
  ## In Docker mode: reproduces the classic bind-mount + host.docker.internal + published port behavior.
  requireBackend()
  let uris = buildArtifactUris(replayName, resultsName, configName)

  if backendConfig.useEcs:
    # ECS path - direct use of (generalized) ecs_backend
    # For simplicity in this skeleton we assume the caller (or a richer wrapper) has already
    # written the config file to disk under replayDir/configName.
    # Real version will do the write + call ecsCreateGame + loop ecsCreateBot (passing private IP).
    let (taskArn, pub, priv) = ecs_backend.ecsCreateGame(
      gameImage,
      "tournament-episode",  # or from manifest
      "",                    # manifestKey if known
      replayName,
      gameCommand,
      gameEnv,
      uris.config,
      saveReplay = (backendConfig.artifactBaseUrl.len > 0)
    )
    # Then launch players (skeleton: one example)
    var playerArns: seq[string]
    for i, (img, cmd, env) in playerImagesAndCmds:
      let pName = "player-" & $i
      # In real code we would compute player WS URL using priv + port + slot token etc.
      let botArn = ecs_backend.ecsCreateBot(
        img,
        taskArn,
        priv,
        "player-bot",
        pName,
        cmd,
        env,
        slot = i,
        token = ""
      )
      playerArns.add(botArn)
    result = EpisodeLaunchResult(
      gameNameOrArn: taskArn,
      playerNamesOrArns: playerArns,
      gamePrivateIp: priv,
      gamePublicIp: pub
    )
    return

  # Docker (dev) path - skeleton that shows the shape.
  # Real code will build the full docker run args using the uris, mount replayDir, etc.
  # (The duplicated gameDockerArgs/playerDockerArgs logic moves here.)
  echo "[container_backend] Docker launch (stub) for ", replayName
  result = EpisodeLaunchResult(
    gameNameOrArn: "docker-game-stub-" & replayName,
    playerNamesOrArns: @[],
    gamePrivateIp: "",
    gamePublicIp: ""
  )

# Observation / control surface would also be unified here:
# listOwnedGames(), inspect(), stopEpisode(), etc. that dispatch on useEcs and owner labels.

proc currentOwner*(): ContainerOwner =
  requireBackend()
  backendConfig.owner

# Future: add the full consolidated list/inspect/stop/remove/health/wait logic
# from both servers so that the scheduler in tournament and the dashboard in games_server
# call the same code.

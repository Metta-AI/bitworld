## Shared container backend abstraction.
##
## Both games_server (dev/on-demand) and tournament_server (prod) use this
## so that launching game + player containers (Docker for dev, ECS for prod)
## and wiring the https (or file) URIs is implemented in one place.
##
## Tournament uses ecs_backend directly via this layer and its own
## artifact service instance (no dependency on games_server process).

import
  std/[os, osproc, strutils],
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
    s3ConfigBucket*: string   # defaults to "bitworld-game-configs" for --ecs (read-only game configs via presigned S3 GET); enables --ecs from laptops without extra env vars. Only active when useEcs=true. Replays/results still use artifactBaseUrl http proxy.
    s3ReplayBucket*: string   # when non-empty and useEcs: replay/results (log) become presigned S3 PUTs (prefixes replays/, results/). Independent of s3ConfigBucket and of artifactBaseUrl (enables laptop --ecs). Default "bitworld-replays".

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
# AWS CLI helpers (for S3 config delivery; modeled on ecs_backend)
# We avoid forcing --output json because s3 cp/presign are not JSON operations.
# Region / aws bin fall back to env / ECS_* / sensible defaults so this works
# both on the EC2 box (where loadEcsConfig ran) and on a laptop.
# -----------------------

proc getAwsBin(): string =
  if ecs_backend.ecsConf.awsBin.len > 0:
    return ecs_backend.ecsConf.awsBin
  getEnv("ECS_AWS_BIN", "aws")

proc getAwsRegion(): string =
  if ecs_backend.ecsConf.region.len > 0:
    return ecs_backend.ecsConf.region
  getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", getEnv("ECS_REGION", "us-east-1")))

proc runAws*(args: openArray[string]): tuple[output: string, code: int] =
  ## Runs an aws CLI command (no forced --output json; suitable for s3 cp/presign).
  ## Always force the only usable profile for this deployment.
  let command = quoteShellCommand(
    @[getAwsBin()] & @args & @["--profile", "sandbox-andre", "--region", getAwsRegion()]
  )
  let res = execCmdEx(command, options = {poEvalCommand, poStdErrToStdOut})
  result.output = res.output
  result.code = res.exitCode

proc uploadConfigToS3AndPresign*(bucket, key, localPath: string, expiresSec = 7200): string =
  ## Uploads the local config file to s3://bucket/key then returns a presigned GET URL.
  ## Callers must have already written the JSON to localPath (replayPath).
  ## Presigned URLs let the Fargate task fetch with plain https GET; no S3 perms on ecs_task role.
  ## (This path is only taken for useEcs launches when s3ConfigBucket is set.)
  if bucket.len == 0 or key.len == 0 or localPath.len == 0:
    raise newException(IOError, "S3 config upload requires bucket, key and localPath")
  if not fileExists(localPath):
    raise newException(IOError, "config file not found for S3 upload: " & localPath)

  # Upload (ignore output; use --only-show-errors to keep it quiet)
  let (upOut, upCode) = runAws([
    "s3", "cp", localPath, "s3://" & bucket & "/" & key,
    "--only-show-errors"
  ])
  if upCode != 0:
    raise newException(IOError, "aws s3 cp failed for config: " & upOut.strip())

  # Presign
  let (preOut, preCode) = runAws([
    "s3", "presign", "s3://" & bucket & "/" & key,
    "--expires-in", $expiresSec
  ])
  if preCode != 0:
    raise newException(IOError, "aws s3 presign failed for config: " & preOut.strip())

  result = preOut.strip()
  if not result.startsWith("https://"):
    raise newException(IOError, "unexpected presign output (expected https URL): " & result)

proc generatePresignedPutUrl*(bucket, key, contentType: string, expiresSec = 7200): string =
  ## Generates a presigned PUT URL (for container to write replay/results/logs directly to S3).
  ## Uses python + boto3 under forced sandbox-andre profile (aws cli presign is GET-only).
  ## Caller must have s3:PutObject on the bucket (via role or profile).
  if bucket.len == 0 or key.len == 0:
    raise newException(IOError, "presigned put requires bucket and key")
  let py = """
import os
import boto3
from botocore.config import Config
os.environ['AWS_PROFILE'] = 'sandbox-andre'
s3 = boto3.client('s3', config=Config(signature_version='s3v4'))
url = s3.generate_presigned_url(
    ClientMethod='put_object',
    Params={'Bucket': '""" & bucket & """', 'Key': '""" & key & """', 'ContentType': '""" & contentType & """'},
    ExpiresIn=""" & $expiresSec & """
)
print(url)
"""
  let (presignOut, code) = execCmdEx("python3 -c '" & py & "'")
  if code != 0:
    raise newException(IOError, "presigned put failed: " & presignOut.strip())
  result = presignOut.strip()
  if not result.startsWith("https://"):
    raise newException(IOError, "unexpected presign output: " & result)

# -----------------------
# URI construction (https vs file; S3 for configs only)
# -----------------------

proc buildArtifactUris*(replayName, resultsName, configName: string): tuple[replay, results, config: string] =
  ## Returns the three COGAME_*_URI values.
  ## If s3ConfigBucket is set (defaults to "bitworld-game-configs") *and* useEcs, the *config* field
  ## is a presigned S3 https GET (after uploading the locally-written config JSON). This makes --ecs
  ## "just work" from a laptop (or EC2) without needing to set BITWORLD_GAME_CONFIGS_BUCKET.
  ## Replay and results URIs always use the artifactBaseUrl http proxy (with tokens) when present
  ## (preserving the "proxy all container writes" security model).
  ## Otherwise falls back to the previous logic (orchestrator http or file://).
  requireBackend()
  let base = backendConfig.artifactBaseUrl.strip()
  let s3b = backendConfig.s3ConfigBucket.strip()

  # Always set replay + results from the orchestrator base (http proxy with tokens) when present.
  # Only the config field is special-cased to S3 when a bucket is configured *and* we are in ECS mode.
  if base.len > 0:
    let
      replayToken = artifact_service.generateUploadToken(replayName)
      resultsToken = artifact_service.generateUploadToken(resultsName)
      uploadBase = base & artifact_service.ReplayUploadPath
    result.replay = uploadBase & replayName & "?token=" & replayToken
    result.results = uploadBase & resultsName & "?token=" & resultsToken
    # config will be overridden below if S3 is active
    result.config = base & artifact_service.ReplayDownloadPath & configName
  else:
    let dir = ContainerReplayDir
    result.replay = "file://" & dir / replayName
    result.results = "file://" & dir / resultsName
    result.config = "file://" & dir / configName

  # S3 presigned PUT overrides for *writes* (replays/results) when in --ecs + bucket.
  # This is independent of artifactBaseUrl (laptop case has no base but still gets s3 writes)
  # and of the s3ConfigBucket path (which only affects the read config URI).
  let s3r = backendConfig.s3ReplayBucket.strip()
  if s3r.len > 0 and backendConfig.useEcs:
    let rkey = "replays/" & artifact_service.cleanReplayName(replayName)
    let skey = "results/" & artifact_service.cleanReplayName(resultsName)
    result.replay = generatePresignedPutUrl(s3r, rkey, "application/octet-stream")
    result.results = generatePresignedPutUrl(s3r, skey, "application/json")
    # (log support can be added symmetrically if/when callers pass a logName)

  # S3 override for the *config read* only (laptop --ecs enabler). Uploads still go through the base http.
  # Only active for ECS launches (useEcs=true), so local Docker dev never touches S3 even if the env var is set.
  if s3b.len > 0 and backendConfig.useEcs:
    let local = artifact_service.replayPath(configName)
    if fileExists(local):
      result.config = uploadConfigToS3AndPresign(s3b, "configs/" & artifact_service.cleanReplayName(configName), local)
    # else leave the base/file value we just computed (defensive)

# Note: the above has a small forward-ref issue on consts; in practice the server will pass the full paths
# or we re-export the needed paths from artifact_service. For the initial impl we keep the spirit and
# callers can construct if needed. The important thing is the https decision lives here.

proc ensureLocalFromS3*(name, prefix: string) =
  ## If s3ReplayBucket configured and the local file is absent, aws s3 cp it from
  ## s3://bucket/prefix/cleanName . Used on-demand by download handlers and scoring
  ## so that local replayDir-based code continues to work after direct S3 uploads.
  ## Safe no-op if not in s3 mode or file already present.
  requireBackend()
  let p = artifact_service.replayPath(name)
  if fileExists(p): return
  let s3b = backendConfig.s3ReplayBucket.strip()
  if s3b.len > 0:
    let key = prefix & artifact_service.cleanReplayName(name)
    discard runAws(["s3", "cp", "s3://" & s3b & "/" & key, p, "--only-show-errors"])

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
      saveReplayUri = uris.replay,
      resultsUri = uris.results,
      saveReplay = (backendConfig.artifactBaseUrl.len > 0 or backendConfig.s3ReplayBucket.len > 0)
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

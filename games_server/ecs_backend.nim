## ECS Fargate backend for games_server.
##
## Provides the same container lifecycle operations as the Docker backend
## (create, list, inspect, stop, remove, logs) but orchestrates ECS tasks
## via the AWS CLI instead of local Docker.
##
## Activated by --ecs flag on games_server. Requires env vars for cluster,
## subnet, and security group configuration.

import
  std/[httpclient, json, os, osproc, strutils, tables, times]

const
  GameContainerPort* = 8080
  EcsStatusRunning = "RUNNING"
  EcsStatusStopped = "STOPPED"
  EcsStatusPending = "PENDING"
  EcsStatusProvisioning = "PROVISIONING"
  TaskPollIntervalMs = 2000
  TaskPollTimeoutSec = 90.0
  HealthPollTimeoutSec = 90.0
  HealthPollIntervalMs = 500
  EngineWsEnv = "COGAMES_ENGINE_WS_URL"
  ConfigUriEnv = "COGAME_CONFIG_URI"
  ResultsUriEnv = "COGAME_RESULTS_URI"
  SaveReplayUriEnv = "COGAME_SAVE_REPLAY_URI"
  HostEnv = "COGAME_HOST"
  PortEnv = "COGAME_PORT"
  PlayerWebSocketPath = "/player"

type
  EcsConfig* = object
    cluster*: string
    publicSubnet*: string
    privateSubnet*: string
    gameSg*: string
    botSg*: string
    executionRoleArn*: string
    taskRoleArn*: string
    logGroup*: string
    region*: string
    awsBin*: string

  EcsError* = object of CatchableError

  CommandResult = object
    output: string
    code: int

var ecsConf*: EcsConfig

proc loadEcsConfig*() =
  putEnv("AWS_PROFILE", "sandbox-andre")
  ecsConf = EcsConfig(
    cluster: getEnv("ECS_CLUSTER", "bitworld-cluster"),
    publicSubnet: getEnv("ECS_PUBLIC_SUBNET", "subnet-0bfdcc939a2a25148"),
    privateSubnet: getEnv("ECS_PRIVATE_SUBNET", "subnet-065e93457a83febbb"),
    gameSg: getEnv("ECS_GAME_SG", "sg-02c003356746211fa"),
    botSg: getEnv("ECS_BOT_SG", "sg-084e721230bec8d99"),
    executionRoleArn: getEnv("ECS_EXECUTION_ROLE_ARN"),
    taskRoleArn: getEnv("ECS_TASK_ROLE_ARN"),
    logGroup: getEnv("ECS_LOG_GROUP", "/ecs/bitworld"),
    region: getEnv("ECS_REGION", "us-east-1"),
    awsBin: getEnv("ECS_AWS_BIN", "aws"),
  )

# =============================================================================
# AWS CLI Wrapper
# =============================================================================

proc awsResult(args: openArray[string]): CommandResult =
  let command = quoteShellCommand(
    @[ecsConf.awsBin] & @args &
    @["--output", "json", "--region", ecsConf.region]
  )
  let res = execCmdEx(command, options = {poEvalCommand, poStdErrToStdOut})
  result.output = res.output
  result.code = res.exitCode

proc requireAws(args: openArray[string]): JsonNode =
  let res = awsResult(args)
  if res.code != 0:
    raise newException(
      EcsError,
      "aws " & args.join(" ") & " failed: " & res.output.strip()
    )
  try:
    result = parseJson(res.output)
  except JsonParsingError:
    raise newException(
      EcsError,
      "aws returned invalid JSON: " & res.output[0 .. min(200, res.output.len - 1)]
    )

# =============================================================================
# Task Definition Management
# =============================================================================

var
  gameTaskDefs: Table[string, string]
  botTaskDefs: Table[string, string]  # image -> task def ARN

proc registerTaskDef(family, image: string, cpu = "256", memory = "512", arch = "X86_64"): string =
  var containerDef = %*[{
    "name": "main",
    "image": image,
    "essential": true,
    "portMappings": [{"containerPort": GameContainerPort, "protocol": "tcp"}],
  }]
  if ecsConf.logGroup.len > 0 and ecsConf.executionRoleArn.len > 0:
    containerDef[0]["logConfiguration"] = %*{
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": ecsConf.logGroup,
        "awslogs-region": ecsConf.region,
        "awslogs-stream-prefix": "ecs"
      }
    }
  let runtimePlatform = %*{
    "cpuArchitecture": arch,
    "operatingSystemFamily": "LINUX"
  }
  var args = @[
    "ecs", "register-task-definition",
    "--family", family,
    "--requires-compatibilities", "FARGATE",
    "--network-mode", "awsvpc",
    "--cpu", cpu,
    "--memory", memory,
    "--runtime-platform", $runtimePlatform,
    "--container-definitions", $containerDef,
  ]
  if ecsConf.executionRoleArn.len > 0:
    args.add("--execution-role-arn")
    args.add(ecsConf.executionRoleArn)
  if ecsConf.taskRoleArn.len > 0:
    args.add("--task-role-arn")
    args.add(ecsConf.taskRoleArn)
  let resp = requireAws(args)
  result = resp["taskDefinition"]["taskDefinitionArn"].getStr()

proc ensureGameTaskDef*(image: string): string =
  if image in gameTaskDefs:
    return gameTaskDefs[image]
  let family = "bitworld-game-" & image.split("/")[^1].split(":")[0]
  echo "ECS: registering game task definition for ", image, "..."
  result = registerTaskDef(family, image, "2048", "4096")
  gameTaskDefs[image] = result
  echo "ECS: game task def = ", result

proc ensureBotTaskDef*(image: string, arch = "X86_64"): string =
  let cacheKey = image & ":" & arch
  if cacheKey in botTaskDefs:
    return botTaskDefs[cacheKey]
  let family = "bitworld-bot-" & image.split("/")[^1].split(":")[0]
  echo "ECS: registering bot task definition for ", image, " (", arch, ")..."
  result = registerTaskDef(family, image, "1024", "2048", arch)
  botTaskDefs[cacheKey] = result
  echo "ECS: bot task def = ", result

# =============================================================================
# Task IP Resolution
# =============================================================================

proc getTaskEniId(taskJson: JsonNode): string =
  for attachment in taskJson["attachments"]:
    if attachment["type"].getStr() == "ElasticNetworkInterface":
      for detail in attachment["details"]:
        if detail["name"].getStr() == "networkInterfaceId":
          return detail["value"].getStr()

proc getTaskPrivateIp(taskJson: JsonNode): string =
  for attachment in taskJson["attachments"]:
    if attachment["type"].getStr() == "ElasticNetworkInterface":
      for detail in attachment["details"]:
        if detail["name"].getStr() == "privateIPv4Address":
          return detail["value"].getStr()

proc getPublicIp(eniId: string): string =
  let resp = requireAws(@[
    "ec2", "describe-network-interfaces",
    "--network-interface-ids", eniId,
  ])
  let ifaces = resp["NetworkInterfaces"]
  if ifaces.len > 0:
    let assoc = ifaces[0].getOrDefault("Association")
    if assoc != nil and assoc.kind == JObject:
      result = assoc.getOrDefault("PublicIp").getStr()

# Cache: taskArn -> (publicIp, privateIp)
var ipCache: Table[string, tuple[public, private: string]]

proc resolveTaskIps*(taskArn: string, taskJson: JsonNode): tuple[public, private: string] =
  if taskArn in ipCache:
    return ipCache[taskArn]
  result.private = getTaskPrivateIp(taskJson)
  let eniId = getTaskEniId(taskJson)
  if eniId.len > 0:
    result.public = getPublicIp(eniId)
  if result.public.len > 0 or result.private.len > 0:
    ipCache[taskArn] = result

# =============================================================================
# Task Lifecycle
# =============================================================================

proc runTask*(
  taskDefArn: string,
  subnet: string,
  sg: string,
  assignPublicIp: bool,
  tags: seq[tuple[key, value: string]],
  envOverrides: seq[tuple[name, value: string]] = @[],
  cmdOverride: seq[string] = @[],
): JsonNode =
  var networkConfig = %*{
    "awsvpcConfiguration": {
      "subnets": [subnet],
      "securityGroups": [sg],
      "assignPublicIp": if assignPublicIp: "ENABLED" else: "DISABLED"
    }
  }
  var overrides = %*{"containerOverrides": [{"name": "main"}]}
  if envOverrides.len > 0:
    var envArr = newJArray()
    for item in envOverrides:
      envArr.add(%*{"name": item.name, "value": item.value})
    overrides["containerOverrides"][0]["environment"] = envArr
  if cmdOverride.len > 0:
    var cmdArr = newJArray()
    for c in cmdOverride:
      cmdArr.add(%c)
    overrides["containerOverrides"][0]["command"] = cmdArr

  var tagsJson = newJArray()
  for t in tags:
    tagsJson.add(%*{"key": t.key, "value": t.value})

  let resp = requireAws(@[
    "ecs", "run-task",
    "--cluster", ecsConf.cluster,
    "--launch-type", "FARGATE",
    "--task-definition", taskDefArn,
    "--network-configuration", $networkConfig,
    "--overrides", $overrides,
    "--tags", $tagsJson,
  ])
  let tasks = resp["tasks"]
  if tasks.len == 0:
    let failures = resp.getOrDefault("failures")
    var reason = "unknown"
    if failures != nil and failures.len > 0:
      reason = failures[0].getOrDefault("reason").getStr("unknown")
    raise newException(EcsError, "run-task returned no tasks: " & reason)
  result = tasks[0]

proc waitForTaskRunning*(taskArn: string): JsonNode =
  let deadline = epochTime() + TaskPollTimeoutSec
  while epochTime() < deadline:
    let resp = requireAws(@[
      "ecs", "describe-tasks",
      "--cluster", ecsConf.cluster,
      "--tasks", taskArn,
    ])
    if resp["tasks"].len == 0:
      raise newException(EcsError, "task disappeared: " & taskArn)
    let task = resp["tasks"][0]
    let status = task["lastStatus"].getStr()
    case status
    of EcsStatusRunning:
      return task
    of EcsStatusStopped:
      let reason = task.getOrDefault("stoppedReason").getStr("unknown")
      raise newException(EcsError, "task stopped before running: " & reason)
    else:
      discard
    sleep(TaskPollIntervalMs)
  raise newException(EcsError, "task did not reach RUNNING within timeout: " & taskArn)

proc stopTask*(taskArn: string) =
  discard awsResult(@[
    "ecs", "stop-task",
    "--cluster", ecsConf.cluster,
    "--task", taskArn,
    "--reason", "stopped by games_server",
  ])

# =============================================================================
# Game Operations
# =============================================================================

proc ecsCreateGame*(
  image: string,
  cogameName: string,
  manifestKey: string,
  replay: string,
  command: seq[string],
  gameEnv: seq[tuple[name, value: string]],
  configUri: string,
  saveReplay: bool,
): tuple[taskArn, publicIp, privateIp: string] =
  let taskDefArn = ensureGameTaskDef(image)
  let
    created = $getTime().toUnix()
    tags = @[
      (key: "bitworld.games_server", value: "among_them"),
      (key: "bitworld.games_server.port", value: $GameContainerPort),
      (key: "bitworld.games_server.created", value: created),
      (key: "bitworld.games_server.replay", value: replay),
      (key: "bitworld.games_server.kind", value: "game"),
      (key: "bitworld.games_server.game_name", value: cogameName),
      (key: "bitworld.games_server.manifest", value: manifestKey),
    ]
  var cmd = command
  var env: seq[tuple[name, value: string]]
  for item in gameEnv:
    env.add(item)
  env.add((name: HostEnv, value: "0.0.0.0"))
  env.add((name: PortEnv, value: $GameContainerPort))
  env.add((name: ConfigUriEnv, value: configUri))
  for envName in ["CLAUDE_KEY", "GEMINI_KEY", "OPENAI_KEY", "XAI_KEY"]:
    let val = getEnv(envName)
    if val.len > 0:
      env.add((name: envName, value: val))
  if saveReplay and replay.len > 0:
    env.add((name: SaveReplayUriEnv, value: "file:///tmp/" & replay))
    let scores = replay.replace(".bitreplay", ".scores.json")
    env.add((name: ResultsUriEnv, value: "file:///tmp/" & scores))

  echo "ECS: launching game task..."
  let taskResp = runTask(
    taskDefArn,
    ecsConf.publicSubnet,
    ecsConf.gameSg,
    assignPublicIp = true,
    tags = tags,
    envOverrides = env,
    cmdOverride = cmd,
  )
  let taskArn = taskResp["taskArn"].getStr()
  echo "ECS: game task = ", taskArn, " (waiting for RUNNING...)"

  let runningTask = waitForTaskRunning(taskArn)
  let ips = resolveTaskIps(taskArn, runningTask)
  echo "ECS: game running at public=", ips.public, " private=", ips.private
  result = (taskArn: taskArn, publicIp: ips.public, privateIp: ips.private)

proc encodeUrlComponent(value: string): string =
  ## Encodes a string for use as one URL query value.
  for ch in value:
    case ch
    of 'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_', '.', '~':
      result.add(ch)
    else:
      result.add('%')
      result.add(ord(ch).toHex(2))

proc playerWsUrl(
  host: string,
  port: int,
  playerName: string,
  slot: int,
  token: string
): string =
  ## Builds the sprite player WebSocket URL for one launched bot.
  var query = "name=" & encodeUrlComponent(playerName)
  if slot >= 0:
    query.add("&slot=" & encodeUrlComponent($slot))
  if token.len > 0:
    query.add("&token=" & encodeUrlComponent(token))
  "ws://" & host & ":" & $port & PlayerWebSocketPath & "?" & query

proc ecsCreateBot*(
  botImage: string,
  gameTaskArn: string,
  gamePrivateIp: string,
  botName: string,
  playerName: string,
  botCommand: seq[string],
  botEnv: seq[tuple[name, value: string]],
  slot = -1,
  token = "",
  arch = "X86_64",
): string =
  ## Launches one bot ECS task using the manifest's `run` command followed
  ## by the bitworld player CLI arguments.
  let taskDefArn = ensureBotTaskDef(botImage, arch)
  let
    created = $getTime().toUnix()
    endpoint = playerWsUrl(
      gamePrivateIp,
      GameContainerPort,
      playerName,
      slot,
      token
    )
    tags = @[
      (key: "bitworld.games_server", value: "among_them_bot"),
      (key: "bitworld.games_server.game", value: gameTaskArn),
      (key: "bitworld.games_server.bot", value: botName),
      (key: "bitworld.games_server.created", value: created),
    ]
  let cmd = botCommand
  var env: seq[tuple[name, value: string]]
  env.add((name: EngineWsEnv, value: endpoint))
  for item in botEnv:
    env.add(item)
  for envName in ["CLAUDE_KEY", "GEMINI_KEY", "OPENAI_KEY", "XAI_KEY"]:
    let val = getEnv(envName)
    if val.len > 0:
      env.add((name: envName, value: val))

  let subnet = if ecsConf.privateSubnet.len > 0: ecsConf.privateSubnet
               else: ecsConf.publicSubnet
  echo "ECS: launching bot ", botName, " -> ", gamePrivateIp, ":", GameContainerPort
  let taskResp = runTask(
    taskDefArn,
    subnet,
    ecsConf.botSg,
    assignPublicIp = false,
    tags = tags,
    envOverrides = env,
    cmdOverride = cmd,
  )
  result = taskResp["taskArn"].getStr()
  echo "ECS: bot task = ", result

proc ecsCreateReplayGame*(
  image: string,
  replay: string,
  command: seq[string],
  gameEnv: seq[tuple[name, value: string]],
  extraEnv: seq[tuple[name, value: string]],
): tuple[taskArn, publicIp, privateIp: string] =
  ## Launches an ECS task for replay playback (no save, no bots).
  let taskDefArn = ensureGameTaskDef(image)
  let
    created = $getTime().toUnix()
    tags = @[
      (key: "bitworld.games_server", value: "among_them"),
      (key: "bitworld.games_server.port", value: $GameContainerPort),
      (key: "bitworld.games_server.created", value: created),
      (key: "bitworld.games_server.replay", value: replay),
      (key: "bitworld.games_server.kind", value: "replay"),
    ]
  let cmd = command
  var env = gameEnv
  for item in extraEnv:
    env.add(item)
  env.add((name: HostEnv, value: "0.0.0.0"))
  env.add((name: PortEnv, value: $GameContainerPort))

  echo "ECS: launching replay task..."
  let taskResp = runTask(
    taskDefArn,
    ecsConf.publicSubnet,
    ecsConf.gameSg,
    assignPublicIp = true,
    tags = tags,
    envOverrides = env,
    cmdOverride = cmd,
  )
  let taskArn = taskResp["taskArn"].getStr()
  echo "ECS: replay task = ", taskArn, " (waiting for RUNNING...)"

  let runningTask = waitForTaskRunning(taskArn)
  let ips = resolveTaskIps(taskArn, runningTask)
  echo "ECS: replay running at public=", ips.public, " private=", ips.private
  result = (taskArn: taskArn, publicIp: ips.public, privateIp: ips.private)

# =============================================================================
# Discovery
# =============================================================================

proc ecsDescribeTasks(taskArns: seq[string]): seq[JsonNode] =
  if taskArns.len == 0:
    return @[]
  let resp = requireAws(@[
    "ecs", "describe-tasks",
    "--cluster", ecsConf.cluster,
    "--tasks"] & taskArns & @["--include", "TAGS"]
  )
  for task in resp["tasks"]:
    result.add(task)

proc ecsListTaskArns(desiredStatus = "RUNNING"): seq[string] =
  let resp = requireAws(@[
    "ecs", "list-tasks",
    "--cluster", ecsConf.cluster,
    "--desired-status", desiredStatus,
  ])
  for arn in resp["taskArns"]:
    result.add(arn.getStr())

proc getTag(task: JsonNode, key: string): string =
  let tags = task.getOrDefault("tags")
  if tags == nil:
    return ""
  for tag in tags:
    if tag["key"].getStr() == key:
      return tag["value"].getStr()

proc isGameTask(task: JsonNode): bool =
  getTag(task, "bitworld.games_server") == "among_them"

proc isBotTask(task: JsonNode): bool =
  getTag(task, "bitworld.games_server") == "among_them_bot"

type
  EcsGameInfo* = object
    taskArn*: string
    status*: string
    publicIp*: string
    privateIp*: string
    port*: int
    created*: int64
    replay*: string
    kind*: string
    cogameName*: string
    manifestKey*: string

  EcsBotInfo* = object
    taskArn*: string
    status*: string
    gameTaskArn*: string
    botName*: string
    created*: int64

proc parseInt64Safe(s: string): int64 =
  try:
    result = parseBiggestInt(s)
  except ValueError:
    result = 0

proc taskToGameInfo(task: JsonNode): EcsGameInfo =
  result.taskArn = task["taskArn"].getStr()
  result.status = task["lastStatus"].getStr().toLowerAscii()
  result.port = GameContainerPort
  result.created = parseInt64Safe(getTag(task, "bitworld.games_server.created"))
  result.replay = getTag(task, "bitworld.games_server.replay")
  result.kind = getTag(task, "bitworld.games_server.kind")
  result.cogameName = getTag(task, "bitworld.games_server.game_name")
  result.manifestKey = getTag(task, "bitworld.games_server.manifest")
  let ips = resolveTaskIps(result.taskArn, task)
  result.publicIp = ips.public
  result.privateIp = ips.private

proc taskToBotInfo(task: JsonNode): EcsBotInfo =
  result.taskArn = task["taskArn"].getStr()
  result.status = task["lastStatus"].getStr().toLowerAscii()
  result.gameTaskArn = getTag(task, "bitworld.games_server.game")
  result.botName = getTag(task, "bitworld.games_server.bot")
  result.created = parseInt64Safe(getTag(task, "bitworld.games_server.created"))

proc ecsListGames*(): seq[EcsGameInfo] =
  let arns = ecsListTaskArns()
  if arns.len == 0:
    return @[]
  let tasks = ecsDescribeTasks(arns)
  for task in tasks:
    if isGameTask(task):
      result.add(taskToGameInfo(task))

proc ecsListBots*(): seq[EcsBotInfo] =
  let arns = ecsListTaskArns()
  if arns.len == 0:
    return @[]
  let tasks = ecsDescribeTasks(arns)
  for task in tasks:
    if isBotTask(task):
      result.add(taskToBotInfo(task))

proc ecsInspectGame*(taskArn: string): EcsGameInfo =
  let tasks = ecsDescribeTasks(@[taskArn])
  if tasks.len == 0:
    raise newException(EcsError, "game task not found: " & taskArn)
  if not isGameTask(tasks[0]):
    raise newException(EcsError, "task is not a game: " & taskArn)
  result = taskToGameInfo(tasks[0])

proc ecsInspectBot*(taskArn: string): EcsBotInfo =
  let tasks = ecsDescribeTasks(@[taskArn])
  if tasks.len == 0:
    raise newException(EcsError, "bot task not found: " & taskArn)
  if not isBotTask(tasks[0]):
    raise newException(EcsError, "task is not a bot: " & taskArn)
  result = taskToBotInfo(tasks[0])

# =============================================================================
# Stop / Remove
# =============================================================================

proc ecsStopGame*(taskArn: string) =
  let bots = ecsListBots()
  for bot in bots:
    if bot.gameTaskArn == taskArn:
      stopTask(bot.taskArn)
  stopTask(taskArn)

proc ecsStopBot*(taskArn: string) =
  stopTask(taskArn)

proc ecsRemoveGame*(taskArn: string): seq[string] =
  ecsStopGame(taskArn)
  result.add(taskArn)

proc ecsRemoveBot*(taskArn: string): seq[string] =
  stopTask(taskArn)
  result.add(taskArn)

# =============================================================================
# Health & WebSocket
# =============================================================================

proc ecsGameHealthy*(publicIp: string): bool =
  if publicIp.len == 0:
    return false
  var client = newHttpClient(timeout = 2000)
  try:
    let url = "http://" & publicIp & ":" & $GameContainerPort & "/healthz"
    let response = client.get(url)
    result = response.status.startsWith("200")
  except CatchableError:
    result = false
  finally:
    client.close()

proc ecsWaitForHealth*(publicIp: string): bool =
  let deadline = epochTime() + HealthPollTimeoutSec
  while epochTime() < deadline:
    if ecsGameHealthy(publicIp):
      return true
    sleep(HealthPollIntervalMs)

proc ecsGameWebSocketUrl*(publicIp: string, path: string): string =
  "ws://" & publicIp & ":" & $GameContainerPort & path

# =============================================================================
# Logs (limited without CloudWatch — just shows task status)
# =============================================================================

proc ecsContainerLogs*(taskArn: string): string =
  let tasks = ecsDescribeTasks(@[taskArn])
  if tasks.len == 0:
    return "task not found: " & taskArn
  let task = tasks[0]
  result = "status=" & task["lastStatus"].getStr() & "\n"
  let stopped = task.getOrDefault("stoppedReason")
  if stopped != nil:
    result.add("stoppedReason=" & stopped.getStr() & "\n")
  let container = task["containers"][0]
  let exitCode = container.getOrDefault("exitCode")
  if exitCode != nil:
    result.add("exitCode=" & $exitCode.getInt() & "\n")
  let reason = container.getOrDefault("reason")
  if reason != nil:
    result.add("reason=" & reason.getStr() & "\n")
  if ecsConf.logGroup.len > 0 and ecsConf.executionRoleArn.len > 0:
    let taskId = taskArn.split("/")[^1]
    let logStream = "ecs/main/" & taskId
    let logsRes = awsResult(@[
      "logs", "get-log-events",
      "--log-group-name", ecsConf.logGroup,
      "--log-stream-name", logStream,
      "--limit", "100",
    ])
    if logsRes.code == 0:
      let logsJson = parseJson(logsRes.output)
      result.add("\n--- CloudWatch logs ---\n")
      for event in logsJson["events"]:
        result.add(event["message"].getStr() & "\n")
    else:
      result.add("\n--- CloudWatch logs unavailable ---\n")
  else:
    result.add("\n--- logs unavailable (no execution role configured) ---\n")

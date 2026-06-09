## Reads ECS Container Insights metrics without coupling servers to
## CloudWatch details.

import
  std/[json, math, os, osproc, strutils, tables, times]

const
  LogGroupEnv* = "ECS_CONTAINER_INSIGHTS_LOG_GROUP"
  WindowSecondsEnv* = "ECS_METRIC_WINDOW_SECONDS"
  StreamLimitEnv* = "ECS_METRIC_STREAM_LIMIT"
  DefaultWindowSeconds = 10 * 60
  DefaultStreamLimit = 32
  GetEventsLimit = 10000

type
  CloudWatchMetric* = object
    cpu*: string
    memory*: string
    memoryPercent*: string

  CommandResult = object
    output: string
    code: int

  TaskSample = object
    timestamp: int64
    cpuUtilized: float
    cpuReserved: float
    memoryUtilized: float
    memoryReserved: float

proc envInt(name: string, defaultValue: int): int =
  ## Reads one positive integer environment setting.
  let raw = getEnv(name).strip()
  if raw.len == 0:
    return defaultValue
  try:
    result = parseInt(raw)
  except ValueError:
    return defaultValue
  if result <= 0:
    result = defaultValue

proc awsResult(
  awsBin,
  region: string,
  args: openArray[string]
): CommandResult =
  ## Runs AWS CLI and captures JSON output.
  let command = quoteShellCommand(
    @[awsBin] & @args & @["--output", "json", "--region", region]
  )
  let res = execCmdEx(command, options = {poEvalCommand, poStdErrToStdOut})
  result.output = res.output
  result.code = res.exitCode

proc jsonStart(output: string): int =
  ## Finds the first likely JSON document start.
  let
    objectStart = output.find('{')
    arrayStart = output.find('[')
  if objectStart < 0:
    return arrayStart
  if arrayStart < 0:
    return objectStart
  min(objectStart, arrayStart)

proc parseAwsJson(output: string): JsonNode =
  ## Parses AWS JSON output while tolerating warning prefixes.
  try:
    return parseJson(output)
  except JsonParsingError:
    discard
  let start = jsonStart(output)
  if start < 0:
    return nil
  try:
    result = parseJson(output[start .. ^1])
  except JsonParsingError:
    result = nil

proc awsJson(
  awsBin,
  region: string,
  args: openArray[string]
): JsonNode =
  ## Runs AWS CLI and returns parsed JSON, or nil on failure.
  let res = awsResult(awsBin, region, args)
  if res.code != 0:
    return nil
  result = parseAwsJson(res.output)

proc metricLogGroup*(cluster: string): string =
  ## Returns the Container Insights performance log group name.
  result = getEnv(LogGroupEnv).strip()
  if result.len == 0:
    result = "/aws/ecs/containerinsights/" & cluster & "/performance"

proc taskId(taskArn: string): string =
  ## Extracts the ECS task id from a task ARN.
  let parts = taskArn.split("/")
  if parts.len == 0:
    return taskArn
  parts[^1]

proc readFloat(node: JsonNode, key: string): float =
  ## Reads one numeric JSON field as a float.
  let value = node.getOrDefault(key)
  if value == nil:
    return 0.0
  case value.kind
  of JFloat:
    result = value.getFloat()
  of JInt:
    result = float(value.getInt())
  of JString:
    try:
      result = parseFloat(value.getStr())
    except ValueError:
      result = 0.0
  else:
    result = 0.0

proc readTimestamp(node: JsonNode, fallback: int64): int64 =
  ## Reads the sample timestamp in milliseconds.
  let value = node.getOrDefault("Timestamp")
  if value == nil:
    return fallback
  case value.kind
  of JInt:
    result = int64(value.getInt())
  of JFloat:
    result = int64(value.getFloat())
  of JString:
    try:
      result = parseBiggestInt(value.getStr())
    except ValueError:
      result = fallback
  else:
    result = fallback

proc percentString(used, reserved: float): string =
  ## Formats a reserved-resource ratio as a percentage.
  if reserved <= 0.0:
    return "-"
  $int(round((used / reserved) * 100.0)) & "%"

proc memoryString(used, reserved: float): string =
  ## Formats Container Insights memory megabytes like Docker stats.
  if used <= 0.0 and reserved <= 0.0:
    return "-"
  $int(round(used)) & "MiB / " & $int(round(reserved)) & "MiB"

proc sampleMetric(sample: TaskSample): CloudWatchMetric =
  ## Converts one task sample into display strings.
  result.cpu = percentString(sample.cpuUtilized, sample.cpuReserved)
  result.memory = memoryString(sample.memoryUtilized, sample.memoryReserved)
  result.memoryPercent = percentString(
    sample.memoryUtilized,
    sample.memoryReserved
  )

proc readEventSamples(
  events: JsonNode,
  arnByTaskId: Table[string, string],
  samples: var Table[string, TaskSample]
) =
  ## Reads task samples from CloudWatch log events.
  for event in events:
    let message = event.getOrDefault("message").getStr()
    if message.len == 0:
      continue
    var node: JsonNode
    try:
      node = parseJson(message)
    except JsonParsingError:
      continue
    if node.getOrDefault("Type").getStr() != "Task":
      continue
    let
      id = node.getOrDefault("TaskId").getStr()
      arn = arnByTaskId.getOrDefault(id)
    if arn.len == 0:
      continue
    let timestamp = readTimestamp(
      node,
      int64(event.getOrDefault("timestamp").getInt())
    )
    if arn in samples and samples[arn].timestamp > timestamp:
      continue
    samples[arn] = TaskSample(
      timestamp: timestamp,
      cpuUtilized: readFloat(node, "CpuUtilized"),
      cpuReserved: readFloat(node, "CpuReserved"),
      memoryUtilized: readFloat(node, "MemoryUtilized"),
      memoryReserved: readFloat(node, "MemoryReserved"),
    )

proc readFilteredSamples(
  awsBin,
  region,
  logGroup: string,
  startMs: int64,
  arnByTaskId: Table[string, string],
  samples: var Table[string, TaskSample]
): bool =
  ## Reads recent task samples with one CloudWatch Logs filter call.
  let resp = awsJson(awsBin, region, @[
    "logs", "filter-log-events",
    "--log-group-name", logGroup,
    "--start-time", $startMs,
    "--filter-pattern", "{ $.Type = \"Task\" }",
    "--limit", $GetEventsLimit,
  ])
  if resp == nil:
    return false
  readEventSamples(resp["events"], arnByTaskId, samples)
  true

proc latestStreamNames(
  awsBin,
  region,
  logGroup: string,
  limit: int
): seq[string] =
  ## Returns recently updated Container Insights performance streams.
  let resp = awsJson(awsBin, region, @[
    "logs", "describe-log-streams",
    "--log-group-name", logGroup,
    "--order-by", "LastEventTime",
    "--descending",
    "--limit", $limit,
  ])
  if resp == nil:
    return @[]
  for stream in resp["logStreams"]:
    let name = stream.getOrDefault("logStreamName").getStr()
    if name.len > 0:
      result.add(name)

proc readStreamSamples(
  awsBin,
  region,
  logGroup,
  streamName: string,
  startMs: int64,
  arnByTaskId: Table[string, string],
  samples: var Table[string, TaskSample]
) =
  ## Reads task samples from one performance log stream.
  let resp = awsJson(awsBin, region, @[
    "logs", "get-log-events",
    "--log-group-name", logGroup,
    "--log-stream-name", streamName,
    "--start-time", $startMs,
    "--start-from-head",
    "--limit", $GetEventsLimit,
  ])
  if resp == nil:
    return
  readEventSamples(resp["events"], arnByTaskId, samples)

proc ecsTaskMetrics*(
  taskArns: openArray[string],
  cluster,
  region,
  awsBin: string
): Table[string, CloudWatchMetric] =
  ## Reads latest ECS task metrics keyed by task ARN.
  if taskArns.len == 0:
    return
  let
    logGroup = metricLogGroup(cluster)
    windowSeconds = envInt(WindowSecondsEnv, DefaultWindowSeconds)
    streamLimit = envInt(StreamLimitEnv, DefaultStreamLimit)
    startMs = int64((epochTime() - float(windowSeconds)) * 1000.0)
  var
    arnByTaskId: Table[string, string]
    samples: Table[string, TaskSample]
  for arn in taskArns:
    let id = taskId(arn)
    if id.len > 0:
      arnByTaskId[id] = arn
  if not readFilteredSamples(
    awsBin,
    region,
    logGroup,
    startMs,
    arnByTaskId,
    samples
  ):
    for stream in latestStreamNames(awsBin, region, logGroup, streamLimit):
      readStreamSamples(
        awsBin,
        region,
        logGroup,
        stream,
        startMs,
        arnByTaskId,
        samples
      )
  for arn, sample in samples.pairs:
    result[arn] = sampleMetric(sample)

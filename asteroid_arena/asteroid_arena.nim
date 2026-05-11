import
  std/[json, os, parseopt, strutils],
  protocol, server, sim

type
  RunConfig = object
    address: string
    port: int
    seed: int
    durationTicks: int
    resultsPath: string
    tokens: seq[string]

proc readConfigString(node: JsonNode, name: string, value: var string) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(ValueError, "Config field " & name & " must be a string.")
  value = item.getStr()

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(ValueError, "Config field " & name & " must be an integer.")
  value = item.getInt()

proc update(config: var RunConfig, jsonText: string) =
  if jsonText.len == 0:
    return
  let node = parseJson(jsonText)
  if node.kind != JObject:
    raise newException(ValueError, "Config must be a JSON object.")
  node.readConfigString("address", config.address)
  node.readConfigInt("port", config.port)
  node.readConfigInt("seed", config.seed)
  var durationSeconds = 0
  node.readConfigInt("duration", durationSeconds)
  if durationSeconds > 0:
    config.durationTicks = durationSeconds * TargetFps
  node.readConfigString("resultsPath", config.resultsPath)
  if node.hasKey("tokens") and node["tokens"].kind == JArray:
    for item in node["tokens"]:
      if item.kind == JString:
        config.tokens.add(item.getStr())

when isMainModule:
  var
    config = RunConfig(
      address: DefaultHost,
      port: DefaultPort,
      seed: 0xA57E2,
      durationTicks: 90 * TargetFps
    )
    configJson = ""
    configPath = getEnv("COGAME_CONFIG_PATH")
  config.resultsPath = getEnv("COGAME_SAVE_RESULTS_PATH")
  if config.resultsPath.len == 0:
    config.resultsPath = getEnv("COGAME_RESULTS_PATH")
  let
    saveReplayPath = getEnv("COGAME_SAVE_REPLAY_PATH")
    loadReplayPath = getEnv("COGAME_LOAD_REPLAY_PATH")
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": config.address = val
      of "port": config.port = parseInt(val)
      of "config": configJson = val
      of "config-file": configPath = val
      of "duration": config.durationTicks = parseInt(val) * TargetFps
      else: discard
    else: discard
  if configPath.len > 0:
    config.update(readFile(configPath))
  if configJson.len > 0:
    config.update(configJson)
  runServerLoop(config.address, config.port, seed = config.seed,
    durationTicks = config.durationTicks, resultsPath = config.resultsPath,
    tokens = config.tokens,
    saveReplayPath = saveReplayPath,
    loadReplayPath = loadReplayPath)

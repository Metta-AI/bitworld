import std/[json, os, parseopt, strutils]
import jsony
import protocol, server

type
  BigAdventureError = object of CatchableError

  RunConfig = object
    address: string
    port: int
    seed: int
    saveReplayPath: string
    loadReplayPath: string
    saveScoresPath: string

proc readConfigString(node: JsonNode, name: string, value: var string) =
  ## Reads one optional string config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(
      BigAdventureError,
      "Config field " & name & " must be a string."
    )
  value = item.getStr()

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  ## Reads one optional integer config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(
      BigAdventureError,
      "Config field " & name & " must be an integer."
    )
  value = item.getInt()

proc defaultReplayPath(): string =
  ## Returns the configured replay save path from the environment.
  getEnv("COGAME_SAVE_REPLAY_PATH")

proc defaultLoadReplayPath(): string =
  ## Returns the configured replay load path from the environment.
  getEnv("COGAME_LOAD_REPLAY_PATH")

proc defaultScoresPath(): string =
  ## Returns the configured score save path from the environment.
  result = getEnv("COGAME_SAVE_RESULTS_PATH")
  if result.len == 0:
    result = getEnv("COGAME_RESULTS_PATH")

proc isKnownConfigField(name: string): bool =
  ## Returns true when a JSON config field is supported.
  case name
  of "address",
      "port",
      "seed",
      "tokens",
      "saveReplay",
      "loadReplay",
      "saveScores",
      "saveReplayPath",
      "loadReplayPath",
      "saveScoresPath",
      "save-replay",
      "load-replay",
      "save-scores",
      "save-replay-path",
      "load-replay-path",
      "save-scores-path":
    true
  else:
    false

proc validateConfigFields(node: JsonNode) =
  ## Raises when JSON config contains an unknown field.
  for name, _ in node.pairs:
    if not name.isKnownConfigField():
      raise newException(
        BigAdventureError,
        "Unknown config field: " & name
      )

proc update(config: var RunConfig, jsonText: string) =
  ## Updates the CLI config from JSON.
  if jsonText.len == 0:
    return
  var node: JsonNode
  try:
    node = fromJson(jsonText)
  except jsony.JsonError as e:
    raise newException(
      BigAdventureError,
      "Could not parse config JSON: " & e.msg
    )
  if node.kind != JObject:
    raise newException(BigAdventureError, "Config must be a JSON object.")
  node.validateConfigFields()
  node.readConfigString("address", config.address)
  node.readConfigInt("port", config.port)
  node.readConfigString("saveReplay", config.saveReplayPath)
  node.readConfigString("loadReplay", config.loadReplayPath)
  node.readConfigString("saveScores", config.saveScoresPath)
  node.readConfigString("saveReplayPath", config.saveReplayPath)
  node.readConfigString("loadReplayPath", config.loadReplayPath)
  node.readConfigString("saveScoresPath", config.saveScoresPath)
  node.readConfigString("save-replay", config.saveReplayPath)
  node.readConfigString("load-replay", config.loadReplayPath)
  node.readConfigString("save-scores", config.saveScoresPath)
  node.readConfigString("save-replay-path", config.saveReplayPath)
  node.readConfigString("load-replay-path", config.loadReplayPath)
  node.readConfigString("save-scores-path", config.saveScoresPath)
  node.readConfigInt("seed", config.seed)

proc requireOptionValue(name, value: string) =
  ## Raises when a CLI option is missing its value.
  if value.len == 0:
    raise newException(
      BigAdventureError,
      "Option --" & name & " requires a value."
    )

proc parseOptionInt(name, value: string): int =
  ## Parses one integer CLI option.
  name.requireOptionValue(value)
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(
      BigAdventureError,
      "Option --" & name & " must be an integer."
    )

proc echoStartupPaths(config: RunConfig) =
  ## Prints configured replay and score output paths.
  if config.loadReplayPath.len > 0:
    echo "Loading replay file: " & config.loadReplayPath
  if config.saveReplayPath.len > 0:
    echo "Writing replay file: " & config.saveReplayPath
  else:
    echo "Not writing replay file."
  if config.saveScoresPath.len > 0:
    echo "Writing scores file: " & config.saveScoresPath
  else:
    echo "Not writing scores file."

when isMainModule:
  var
    config = RunConfig(
      address: DefaultHost,
      port: DefaultPort,
      seed: 0xB1770,
      saveReplayPath: defaultReplayPath(),
      loadReplayPath: defaultLoadReplayPath(),
      saveScoresPath: defaultScoresPath()
    )
    configPath = getEnv("COGAME_CONFIG_PATH")
    configJson = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        key.requireOptionValue(val)
        config.address = val
      of "port":
        config.port = key.parseOptionInt(val)
      of "seed":
        config.seed = key.parseOptionInt(val)
      of "save-replay", "save-replay-path", "saveReplayPath":
        key.requireOptionValue(val)
        config.saveReplayPath = val
      of "load-replay", "load-replay-path", "loadReplayPath":
        key.requireOptionValue(val)
        config.loadReplayPath = val
      of "save-scores", "save-scores-path", "saveScoresPath":
        key.requireOptionValue(val)
        config.saveScoresPath = val
      of "config":
        key.requireOptionValue(val)
        configJson = val
      of "config-file":
        key.requireOptionValue(val)
        configPath = val
      else:
        raise newException(BigAdventureError, "Unknown option: --" & key)
    of cmdShortOption:
      raise newException(BigAdventureError, "Unknown option: -" & key)
    of cmdArgument:
      raise newException(BigAdventureError, "Unexpected argument: " & key)
    of cmdEnd:
      discard
  if configPath.len > 0:
    config.update(readFile(configPath))
  if configJson.len > 0:
    config.update(configJson)
  config.echoStartupPaths()
  runServerLoop(
    config.address,
    config.port,
    config.seed,
    config.saveReplayPath,
    config.loadReplayPath,
    config.saveScoresPath
  )

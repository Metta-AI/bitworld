import
  std/[json, os, parseopt, strutils],
  jsony,
  protocol, server, sim

type
  RunConfig = object
    address: string
    port: int
    seed: int
    simConfig: SimConfig
    saveScoresPath: string

proc readConfigString(node: JsonNode, name: string, value: var string) =
  ## Reads one optional string config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(
      PlanetWarsError,
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
      PlanetWarsError,
      "Config field " & name & " must be an integer."
    )
  value = item.getInt()

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
      "planets",
      "planetCount",
      "planet_count",
      "tokens",
      "saveScores",
      "saveScoresPath",
      "save-scores",
      "save-scores-path":
    true
  else:
    false

proc validateConfigFields(node: JsonNode) =
  ## Raises when JSON config contains an unknown field.
  for name, _ in node.pairs:
    if not name.isKnownConfigField():
      raise newException(
        PlanetWarsError,
        "Unknown config field: " & name
      )

proc update(config: var RunConfig, jsonText: string) =
  ## Updates the run config from a JSON object.
  if jsonText.len == 0:
    return
  var node: JsonNode
  try:
    node = fromJson(jsonText)
  except jsony.JsonError as e:
    raise newException(
      PlanetWarsError,
      "Could not parse config JSON: " & e.msg
    )
  if node.kind != JObject:
    raise newException(PlanetWarsError, "Config must be a JSON object.")
  node.validateConfigFields()
  node.readConfigString("address", config.address)
  node.readConfigInt("port", config.port)
  node.readConfigInt("seed", config.seed)
  node.readConfigInt("planets", config.simConfig.planetCount)
  node.readConfigInt("planetCount", config.simConfig.planetCount)
  node.readConfigInt("planet_count", config.simConfig.planetCount)
  node.readConfigString("saveScores", config.saveScoresPath)
  node.readConfigString("saveScoresPath", config.saveScoresPath)
  node.readConfigString("save-scores", config.saveScoresPath)
  node.readConfigString("save-scores-path", config.saveScoresPath)

proc requireOptionValue(name, value: string) =
  ## Raises when a CLI option is missing its value.
  if value.len == 0:
    raise newException(
      PlanetWarsError,
      "Option --" & name & " requires a value."
    )

proc parseOptionInt(name, value: string): int =
  ## Parses one integer CLI option.
  name.requireOptionValue(value)
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(
      PlanetWarsError,
      "Option --" & name & " must be an integer."
    )

proc echoStartupPaths(config: RunConfig) =
  ## Prints configured score output paths.
  echo "Using planet count: " & $config.simConfig.planetCount
  if config.saveScoresPath.len > 0:
    echo "Writing scores file: " & config.saveScoresPath
  else:
    echo "Not writing scores file."

when isMainModule:
  var
    config = RunConfig(
      address: DefaultHost,
      port: DefaultPort,
      seed: 0x1A7E7,
      simConfig: defaultSimConfig(),
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
      of "planets", "planet-count", "planetCount":
        config.simConfig.planetCount = key.parseOptionInt(val)
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
        raise newException(PlanetWarsError, "Unknown option: --" & key)
    of cmdShortOption:
      raise newException(PlanetWarsError, "Unknown option: -" & key)
    of cmdArgument:
      raise newException(PlanetWarsError, "Unexpected argument: " & key)
    of cmdEnd:
      discard
  if configPath.len > 0:
    config.update(readFile(configPath))
  if configJson.len > 0:
    config.update(configJson)
  config.simConfig.planetCount =
    config.simConfig.planetCount.checkedPlanetCount()
  config.echoStartupPaths()
  runServerLoop(
    config.address,
    config.port,
    config.seed,
    config.simConfig,
    config.saveScoresPath
  )

import jsony, protocol, server, sim
import std/[json, parseopt, strutils]

type
  BigAdventureError = object of CatchableError

  RunConfig = object
    address: string
    port: int
    seed: int
    saveReplayPath: string
    loadReplayPath: string

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
  node.readConfigString("address", config.address)
  node.readConfigInt("port", config.port)
  node.readConfigString("saveReplay", config.saveReplayPath)
  node.readConfigString("loadReplay", config.loadReplayPath)
  node.readConfigString("saveReplayPath", config.saveReplayPath)
  node.readConfigString("loadReplayPath", config.loadReplayPath)
  node.readConfigInt("seed", config.seed)

when isMainModule:
  var
    config = RunConfig(address: DefaultHost, port: DefaultPort, seed: 0xB1770)
    configPath = ""
    configJson = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": config.address = val
      of "port": config.port = parseInt(val)
      of "save-replay": config.saveReplayPath = val
      of "load-replay": config.loadReplayPath = val
      of "config": configJson = val
      of "config-file": configPath = val
      else: discard
    else: discard
  if configPath.len > 0:
    config.update(readFile(configPath))
  if configJson.len > 0:
    config.update(configJson)
  runServerLoop(
    config.address,
    config.port,
    config.seed,
    config.saveReplayPath,
    config.loadReplayPath
  )

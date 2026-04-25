import protocol, sim, server
import std/[parseopt, strutils]

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    configJson = ""
    configPath = ""
    saveReplayPath = ""
    loadReplayPath = ""
    targetFps = -1
    seed = 0xA6019
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = val
      of "port":
        port = parseInt(val)
      of "config":
        configJson = val
      of "config-file":
        configPath = val
      of "fps":
        targetFps = parseInt(val) * FpsScale
      of "seed":
        seed = parseInt(val)
      of "save-replay":
        saveReplayPath = val
      of "load-replay":
        loadReplayPath = val
      else: discard
    else: discard
  var config = defaultGameConfig()
  if configPath.len > 0:
    config.update(readFile(configPath))
  if configJson.len > 0:
    config.update(configJson)
  if targetFps >= 0:
    config.targetFps = targetFps
  runServerLoop(address, port, config, seed, saveReplayPath, loadReplayPath)

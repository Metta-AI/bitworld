import protocol, sim, server
import std/[parseopt, strutils]

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    configJson = ""
    configPath = ""
    mapPath = ""
    saveReplayPath = ""
    loadReplayPath = ""
    messageCooldown = -1
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
      of "map":
        mapPath = val
      of "save-replay":
        saveReplayPath = val
      of "load-replay":
        loadReplayPath = val
      of "message-cooldown":
        messageCooldown = max(0, parseInt(val))
      else: discard
    else: discard
  var config = defaultGameConfig()
  if configPath.len > 0:
    config.update(readFile(configPath))
  if configJson.len > 0:
    config.update(configJson)
  if mapPath.len > 0:
    config.mapPath = mapPath
  if messageCooldown >= 0:
    config.messageCooldownTicks = messageCooldown
  runServerLoop(address, port, config, saveReplayPath, loadReplayPath)

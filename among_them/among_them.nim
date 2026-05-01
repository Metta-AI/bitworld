import
  std/[os, parseopt, strutils],
  protocol, sim, server

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    configJson = ""
    configPath = getEnv("COGAME_CONFIG_PATH")
    mapPath = ""
    saveReplayPath = getEnv("COGAME_SAVE_REPLAY_PATH")
    loadReplayPath = ""
    saveScoresPath = getEnv("COGAME_SAVE_RESULTS_PATH")
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
      of "save-scores":
        saveScoresPath = val
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
  echo "Using map file: " & config.mapPath
  if configPath.len > 0:
    echo "Using config file: " & configPath
  if loadReplayPath.len > 0:
    echo "Using replay load file: " & loadReplayPath
  if saveReplayPath.len > 0:
    echo "Using replay save file: " & saveReplayPath
  if saveScoresPath.len > 0:
    echo "Using results save file: " & saveScoresPath
  runServerLoop(
    address,
    port,
    config,
    saveReplayPath,
    loadReplayPath,
    saveScoresPath
  )

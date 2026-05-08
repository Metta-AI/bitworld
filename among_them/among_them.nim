import
  std/[os, parseopt, strutils],
  curly,
  protocol, sim, server

proc cogamePath(value, source: string): string =
  if value.len == 0:
    return ""
  const FilePrefix = "file://"
  if value.startsWith(FilePrefix):
    result = value[FilePrefix.len .. ^1]
    if result.len == 0:
      echo "ERROR: empty file URI from " & source
      quit(1)
    return
  if "://" in value:
    echo "ERROR: unsupported URI from " & source & ": " & value
    quit(1)
  result = value

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    configJson = ""
    configPath = cogamePath(getEnv("COGAME_CONFIG_URI"), "COGAME_CONFIG_URI")
    mapPath = ""
    saveReplayPath = cogamePath(getEnv("COGAME_SAVE_REPLAY_URI"), "COGAME_SAVE_REPLAY_URI")
    loadReplayPath = cogamePath(getEnv("COGAME_LOAD_REPLAY_URI"), "COGAME_LOAD_REPLAY_URI")
    saveScoresPath = cogamePath(getEnv("COGAME_RESULTS_URI"), "COGAME_RESULTS_URI")
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
  let replayDownloadUrl = getEnv("REPLAY_DOWNLOAD_URL")
  if replayDownloadUrl.len > 0 and loadReplayPath.len == 0:
    echo "Downloading replay from: ", replayDownloadUrl
    let pool = newCurlPool(1)
    let resp = pool.get(replayDownloadUrl)
    if resp.code != 200:
      echo "ERROR: replay download failed: ", resp.code
      quit(1)
    loadReplayPath = "/tmp/downloaded.bitreplay"
    writeFile(loadReplayPath, resp.body)
    echo "Replay downloaded: ", resp.body.len, " bytes"

  echo "starting among_them on ", address, ":", port
  runServerLoop(
    address,
    port,
    config,
    saveReplayPath,
    loadReplayPath,
    saveScoresPath
  )

import
  std/[os, parseopt, strutils],
  curly

const
  RuntimeDefaultHost = "0.0.0.0"
  RuntimeDefaultPort = 8080
  CogameConfigUriEnv* = "COGAME_CONFIG_URI"
  CogameResultsUriEnv* = "COGAME_RESULTS_URI"
  CogameSaveReplayUriEnv* = "COGAME_SAVE_REPLAY_URI"
  CogameLoadReplayUriEnv* = "COGAME_LOAD_REPLAY_URI"
  CogameLogUriEnv* = "COGAME_LOG_URI"
  CogameHostEnv* = "COGAME_HOST"
  CogamePortEnv* = "COGAME_PORT"

type
  CogameRuntimeError* = object of CatchableError

  RuntimeConfig* = object
    host*: string
    port*: int
    config*: string
    resultsUri*: string
    replayUri*: string
    replay*: string
    logUri*: string
    replayMode*: bool
    mismatchQuit*: bool

proc usageText(): string =
  ## Returns the runtime command-line help text.
  """
Coworld runtime options:
  --host:<host>              Bind host. Env: COGAME_HOST.
  --port:<port>              Bind port. Env: COGAME_PORT.
  --config:{json}            Inline JSON config text.
  --config-path:<path>       Read JSON config from a local path.
  --config-uri:<uri>         Read JSON config from file/http/https URI.
                             Env: COGAME_CONFIG_URI.
  --results:<path>           Write results to a local path.
  --results-uri:<uri>        Write results to file/http/https URI.
                             Env: COGAME_RESULTS_URI.
  --save-replay:<path>       Write replay to a local path.
  --save-replay-uri:<uri>    Write replay to file/http/https URI.
                             Env: COGAME_SAVE_REPLAY_URI.
  --load-replay:<path>       Read replay from a local path.
  --load-replay-uri:<uri>    Read replay from file/http/https URI.
                             Env: COGAME_LOAD_REPLAY_URI.
  --log:<path>               Write log to a local path.
  --log-uri:<uri>            Write log to file/http/https URI.
                             Env: COGAME_LOG_URI.
  --mismatch-quit            Raise on replay hash mismatch.
  --help, -h                 Show this help.
"""

proc requireValue(option, value: string) =
  ## Raises when a runtime command-line option has no value.
  if value.len == 0:
    raise newException(
      CogameRuntimeError,
      "Option --" & option & " requires a value."
    )

proc parseRuntimePort(value, source: string): int =
  ## Parses one runtime port value.
  try:
    result = value.parseInt()
  except ValueError:
    raise newException(
      CogameRuntimeError,
      source & " must be an integer."
    )
  if result <= 0 or result > 65535:
    raise newException(
      CogameRuntimeError,
      source & " must be between 1 and 65535."
    )

proc fileUriPath(value, source: string): string =
  ## Returns a local path for a file URI or an empty string.
  const FilePrefix = "file://"
  if value.startsWith(FilePrefix):
    result = value[FilePrefix.len .. ^1]
    if result.len == 0:
      raise newException(CogameRuntimeError, "empty file URI from " & source)
    return
  ""

proc filePathFromCogameUri(value, source: string): string =
  ## Returns the local path for a Coworld file URI.
  fileUriPath(value, source)

proc isHttpCogameUri*(value: string): bool =
  ## Returns true when a Coworld URI is an HTTP(S) URI.
  value.startsWith("http://") or value.startsWith("https://")

proc readCogameUri*(value, source: string): string =
  ## Reads data from a Coworld file URI or HTTP(S) signed URI.
  if value.len == 0:
    return ""

  let path = filePathFromCogameUri(value, source)
  if path.len > 0:
    return readFile(path)

  if value.isHttpCogameUri():
    let
      client = newCurlPool(1)
      response = client.get(value)
    if response.code < 200 or response.code >= 300:
      raise newException(
        IOError,
        source & " download failed: " & $response.code
      )
    return response.body

  if "://" in value:
    raise newException(
      CogameRuntimeError,
      "unsupported URI from " & source & ": " & value
    )

  raise newException(CogameRuntimeError, source & " must be a URI")

proc readCogameEnv*(name: string): string =
  ## Reads data from a Coworld URI environment variable.
  readCogameUri(getEnv(name), name)

proc pathFromCogameUri*(value, source: string): string =
  ## Converts a Coworld file/input URI into a local path.
  if value.len == 0:
    return ""

  let path = filePathFromCogameUri(value, source)
  if path.len > 0:
    return path

  if value.isHttpCogameUri():
    result = getTempDir() / ("cogame-" & source.toLowerAscii())
    writeFile(result, readCogameUri(value, source))
    return

  if "://" in value:
    raise newException(
      CogameRuntimeError,
      "unsupported URI from " & source & ": " & value
    )

  raise newException(CogameRuntimeError, source & " must be a URI")

proc pathFromCogameEnv*(name: string): string =
  ## Reads a Coworld URI env var and returns the local path it addresses.
  pathFromCogameUri(getEnv(name), name)

proc outputPathFromCogameUri*(value, source, fileName: string): string =
  ## Returns a local output path for a Coworld artifact URI.
  if value.len == 0:
    return ""

  let path = filePathFromCogameUri(value, source)
  if path.len > 0:
    return path

  if value.isHttpCogameUri():
    result = getTempDir() / ("cogame-" & source.toLowerAscii() & "-" & fileName)
    return

  if "://" in value:
    raise newException(
      CogameRuntimeError,
      "unsupported URI from " & source & ": " & value
    )

  raise newException(CogameRuntimeError, source & " must be a URI")

proc outputPathFromCogameEnv*(name, fileName: string): string =
  ## Reads a Coworld output URI env var and returns the local path it addresses.
  outputPathFromCogameUri(getEnv(name), name, fileName)

proc cogameHost*(): string =
  ## Returns the Coworld game bind host.
  result = getEnv(CogameHostEnv, RuntimeDefaultHost)
  if result.len == 0:
    result = RuntimeDefaultHost

proc cogamePort*(): int =
  ## Returns the Coworld game bind port.
  let raw = getEnv(CogamePortEnv)
  if raw.len == 0:
    return RuntimeDefaultPort
  parseRuntimePort(raw, CogamePortEnv)

proc writeCogameUri*(
  value, data, contentType, source: string
) =
  ## Writes one Coworld artifact to a file URI or HTTP(S) signed URI.
  if value.len == 0:
    return

  let path = filePathFromCogameUri(value, source)
  if path.len > 0:
    let dir = path.parentDir()
    if dir.len > 0:
      createDir(dir)
    writeFile(path, data)
    return

  if value.isHttpCogameUri():
    let
      client = newCurlPool(1)
      headers = @[("Content-Type", contentType)]
      response = client.put(value, headers, data)
    if response.code < 200 or response.code >= 300:
      raise newException(
        IOError,
        source & " upload failed: " & $response.code & " " & response.body
      )
    return

  if "://" in value:
    raise newException(
      CogameRuntimeError,
      "unsupported URI from " & source & ": " & value
    )

  raise newException(CogameRuntimeError, source & " must be a URI")

proc writeCogameFileToUri*(
  value, path, contentType, source: string
) =
  ## Writes a local artifact file to its Coworld destination URI.
  if value.len == 0 or path.len == 0:
    return
  writeCogameUri(value, readFile(path), contentType, source)

proc writeCogameEnv*(
  name, data, contentType: string
) =
  ## Writes data to a Coworld URI environment variable.
  let value = getEnv(name)
  if value.len == 0:
    return
  writeCogameUri(value, data, contentType, name)

proc writeCogameFileEnv*(
  name, path, contentType: string
) =
  ## Writes a local artifact file to a Coworld URI environment variable.
  let value = getEnv(name)
  if value.len == 0 or path.len == 0:
    return
  writeCogameUri(value, readFile(path), contentType, name)

proc hasUriScheme(value: string): bool =
  ## Returns true when a value names a URI scheme.
  "://" in value

proc writeLocalTarget(path, data: string) =
  ## Writes data to a local path, creating parent directories as needed.
  let dir = path.parentDir()
  if dir.len > 0:
    createDir(dir)
  writeFile(path, data)

proc writeRuntimeTarget(
  value,
  data,
  contentType,
  source: string
) =
  ## Writes runtime data to either a local path or a Coworld URI.
  if value.len == 0:
    return
  if value.isHttpCogameUri() or value.hasUriScheme():
    writeCogameUri(value, data, contentType, source)
    return
  value.writeLocalTarget(data)

proc readRuntimeConfig*(): RuntimeConfig =
  ## Reads the Coworld runtime config from CLI arguments and env vars.
  result = RuntimeConfig(host: RuntimeDefaultHost, port: RuntimeDefaultPort)
  var
    hostSet = false
    portSet = false
    configSet = false
    resultsSet = false
    saveReplaySet = false
    loadReplaySet = false
    logSet = false

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      if key.len == 0:
        continue
      case key
      of "host":
        key.requireValue(val)
        result.host = val
        hostSet = true
      of "port":
        key.requireValue(val)
        result.port = parseRuntimePort(val, "--" & key)
        portSet = true
      of "config":
        key.requireValue(val)
        result.config = val
        configSet = true
      of "config-path":
        key.requireValue(val)
        result.config = readFile(val)
        configSet = true
      of "config-uri":
        key.requireValue(val)
        result.config = readCogameUri(val, "--" & key)
        configSet = true
      of "results":
        key.requireValue(val)
        result.resultsUri = val
        resultsSet = true
      of "results-uri":
        key.requireValue(val)
        result.resultsUri = val
        resultsSet = true
      of "save-replay":
        key.requireValue(val)
        result.replayUri = val
        saveReplaySet = true
      of "save-replay-uri":
        key.requireValue(val)
        result.replayUri = val
        saveReplaySet = true
      of "load-replay":
        key.requireValue(val)
        result.replay = readFile(val)
        result.replayMode = true
        loadReplaySet = true
      of "load-replay-uri":
        key.requireValue(val)
        result.replay = readCogameUri(val, "--" & key)
        result.replayMode = true
        loadReplaySet = true
      of "log":
        key.requireValue(val)
        result.logUri = val
        logSet = true
      of "log-uri":
        key.requireValue(val)
        result.logUri = val
        logSet = true
      of "mismatch-quit":
        if val.len > 0:
          raise newException(
            CogameRuntimeError,
            "Option --" & key & " does not take a value."
          )
        result.mismatchQuit = true
      of "help":
        echo usageText()
        quit(0)
      else:
        raise newException(CogameRuntimeError, "Unknown option: --" & key)
    of cmdShortOption:
      case key
      of "h":
        echo usageText()
        quit(0)
      else:
        raise newException(CogameRuntimeError, "Unknown option: -" & key)
    of cmdArgument:
      raise newException(CogameRuntimeError, "Unexpected argument: " & key)
    of cmdEnd:
      discard

  if not hostSet:
    result.host = getEnv(CogameHostEnv, result.host)
    if result.host.len == 0:
      result.host = RuntimeDefaultHost
  if not portSet:
    let port = getEnv(CogamePortEnv)
    if port.len > 0:
      result.port = parseRuntimePort(port, CogamePortEnv)
  if not configSet:
    let configUri = getEnv(CogameConfigUriEnv)
    if configUri.len > 0:
      result.config = readCogameUri(configUri, CogameConfigUriEnv)
  if not resultsSet:
    result.resultsUri = getEnv(CogameResultsUriEnv)
  if not saveReplaySet:
    result.replayUri = getEnv(CogameSaveReplayUriEnv)
  if not loadReplaySet:
    let replayUri = getEnv(CogameLoadReplayUriEnv)
    if replayUri.len > 0:
      result.replay = readCogameUri(replayUri, CogameLoadReplayUriEnv)
      result.replayMode = true
  if not logSet:
    result.logUri = getEnv(CogameLogUriEnv)

proc writeResults*(config: RuntimeConfig, data: string) =
  ## Writes a Coworld results artifact if a target is configured.
  writeRuntimeTarget(
    config.resultsUri,
    data,
    "application/json",
    CogameResultsUriEnv
  )

proc writeReplay*(config: RuntimeConfig, data: string) =
  ## Writes a Coworld replay artifact if a target is configured.
  writeRuntimeTarget(
    config.replayUri,
    data,
    "application/octet-stream",
    CogameSaveReplayUriEnv
  )

proc writeLog*(config: RuntimeConfig, data: string) =
  ## Writes a Coworld log artifact if a target is configured.
  writeRuntimeTarget(
    config.logUri,
    data,
    "text/plain; charset=utf-8",
    CogameLogUriEnv
  )

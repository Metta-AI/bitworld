import
  std/[os, strutils],
  curly

const
  CogameConfigUriEnv* = "COGAME_CONFIG_URI"
  CogameResultsUriEnv* = "COGAME_RESULTS_URI"
  CogameSaveReplayUriEnv* = "COGAME_SAVE_REPLAY_URI"
  CogameLoadReplayUriEnv* = "COGAME_LOAD_REPLAY_URI"
  CogameLogUriEnv* = "COGAME_LOG_URI"
  CogameReplayServerEnv* = "COGAME_REPLAY_SERVER"
  CogameResultsMethodEnv* = "COGAME_RESULTS_METHOD"
  CogameSaveReplayMethodEnv* = "COGAME_SAVE_REPLAY_METHOD"
  CogameHostEnv* = "COGAME_HOST"
  CogamePortEnv* = "COGAME_PORT"

type
  CogameRuntimeError* = object of CatchableError

proc filePathFromCogameUri(value, source: string): string =
  ## Returns the local path for a Coworld file URI.
  const FilePrefix = "file://"
  if value.startsWith(FilePrefix):
    result = value[FilePrefix.len .. ^1]
    if result.len == 0:
      raise newException(CogameRuntimeError, "empty file URI from " & source)
    return
  ""

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

proc cogameHost*(defaultHost: string): string =
  ## Returns the Coworld game bind host.
  result = getEnv(CogameHostEnv, defaultHost)
  if result.len == 0:
    result = defaultHost

proc cogamePort*(defaultPort: int): int =
  ## Returns the Coworld game bind port.
  let raw = getEnv(CogamePortEnv)
  if raw.len == 0:
    return defaultPort
  parseInt(raw)

proc cogameHttpMethod*(envName: string): string =
  ## Returns the upload method for a Coworld artifact URI.
  result = getEnv(envName, "PUT").toUpperAscii()
  if result notin ["POST", "PUT"]:
    raise newException(CogameRuntimeError, envName & " must be POST or PUT")

proc cogameHttpMethodForUri*(value, envName: string): string =
  ## Returns the upload method only when a URI uses HTTP(S).
  if value.isHttpCogameUri() and envName.len > 0:
    cogameHttpMethod(envName)
  else:
    "PUT"

proc writeCogameUri*(
  value, data, contentType, source: string,
  httpMethod = "PUT"
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
      response =
        case httpMethod.toUpperAscii()
        of "POST":
          client.post(value, headers, data)
        of "PUT":
          client.put(value, headers, data)
        else:
          raise newException(
            CogameRuntimeError,
            source & " upload method must be POST or PUT"
          )
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
  value, path, contentType, source: string,
  httpMethod = "PUT"
) =
  ## Writes a local artifact file to its Coworld destination URI.
  if value.len == 0 or path.len == 0:
    return
  writeCogameUri(value, readFile(path), contentType, source, httpMethod)

proc writeCogameEnv*(
  name, data, contentType: string,
  methodEnv = ""
) =
  ## Writes data to a Coworld URI environment variable.
  let value = getEnv(name)
  if value.len == 0:
    return
  let httpMethod =
    if value.isHttpCogameUri() and methodEnv.len > 0:
      cogameHttpMethod(methodEnv)
    else:
      "PUT"
  writeCogameUri(value, data, contentType, name, httpMethod)

proc writeCogameFileEnv*(
  name, path, contentType: string,
  methodEnv = ""
) =
  ## Writes a local artifact file to a Coworld URI environment variable.
  let value = getEnv(name)
  if value.len == 0 or path.len == 0:
    return
  let httpMethod =
    if value.isHttpCogameUri() and methodEnv.len > 0:
      cogameHttpMethod(methodEnv)
    else:
      "PUT"
  writeCogameUri(value, readFile(path), contentType, name, httpMethod)

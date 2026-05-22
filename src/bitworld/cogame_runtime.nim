import std/[httpclient, os, strutils]

const
  CogameConfigUriEnv* = "COGAME_CONFIG_URI"
  CogameResultsUriEnv* = "COGAME_RESULTS_URI"
  CogameSaveReplayUriEnv* = "COGAME_SAVE_REPLAY_URI"
  CogameLoadReplayUriEnv* = "COGAME_LOAD_REPLAY_URI"
  CogameResultsMethodEnv* = "COGAME_RESULTS_METHOD"
  CogameSaveReplayMethodEnv* = "COGAME_SAVE_REPLAY_METHOD"
  CogameHostEnv* = "COGAME_HOST"
  CogamePortEnv* = "COGAME_PORT"

proc pathFromCogameUri*(value, source: string): string =
  ## Converts a Coworld file/input URI into a local path.
  if value.len == 0:
    return ""

  const FilePrefix = "file://"
  if value.startsWith(FilePrefix):
    result = value[FilePrefix.len .. ^1]
    if result.len == 0:
      raise newException(ValueError, "empty file URI from " & source)
    return

  if value.startsWith("http://") or value.startsWith("https://"):
    var client = newHttpClient(timeout = 30_000)
    try:
      let body = client.getContent(value)
      result = getTempDir() / ("cogame-" & source.toLowerAscii() & ".json")
      writeFile(result, body)
      return
    finally:
      client.close()

  if "://" in value:
    raise newException(ValueError, "unsupported URI from " & source & ": " & value)

  raise newException(ValueError, source & " must be a URI")

proc pathFromCogameEnv*(name: string): string =
  ## Reads a Coworld URI env var and returns the local path it addresses.
  pathFromCogameUri(getEnv(name), name)

proc outputPathFromCogameUri*(value, source, fileName: string): string =
  ## Returns a local output path for a Coworld artifact URI.
  if value.len == 0:
    return ""

  const FilePrefix = "file://"
  if value.startsWith(FilePrefix):
    result = value[FilePrefix.len .. ^1]
    if result.len == 0:
      raise newException(ValueError, "empty file URI from " & source)
    return

  if value.startsWith("http://") or value.startsWith("https://"):
    result = getTempDir() / ("cogame-" & source.toLowerAscii() & "-" & fileName)
    return

  if "://" in value:
    raise newException(ValueError, "unsupported URI from " & source & ": " & value)

  raise newException(ValueError, source & " must be a URI")

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
    raise newException(ValueError, envName & " must be POST or PUT")

proc writeCogameUri*(
  value, data, contentType, source: string,
  httpMethod = "PUT"
) =
  ## Writes one Coworld artifact to a file URI or HTTP(S) signed URI.
  if value.len == 0:
    return

  const FilePrefix = "file://"
  if value.startsWith(FilePrefix):
    let path = value[FilePrefix.len .. ^1]
    if path.len == 0:
      raise newException(ValueError, "empty file URI from " & source)
    createDir(path.parentDir())
    writeFile(path, data)
    return

  if value.startsWith("http://") or value.startsWith("https://"):
    var client = newHttpClient(timeout = 60_000)
    try:
      let
        headers = newHttpHeaders({"Content-Type": contentType})
        requestMethod =
          case httpMethod.toUpperAscii()
          of "POST": HttpPost
          of "PUT": HttpPut
          else:
            raise newException(ValueError, source & " upload method must be POST or PUT")
        response = client.request(value, httpMethod = requestMethod, body = data, headers = headers)
        code = response.code.int
      if code < 200 or code >= 300:
        raise newException(ValueError, source & " upload failed: " & response.status)
      return
    finally:
      client.close()

  if "://" in value:
    raise newException(ValueError, "unsupported URI from " & source & ": " & value)

  raise newException(ValueError, source & " must be a URI")

proc writeCogameFileToUri*(
  value, path, contentType, source: string,
  httpMethod = "PUT"
) =
  ## Writes a local artifact file to its Coworld destination URI.
  if value.len == 0 or path.len == 0:
    return
  writeCogameUri(value, readFile(path), contentType, source, httpMethod)

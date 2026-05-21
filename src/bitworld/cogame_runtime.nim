import std/[httpclient, os, strutils]

const
  CogameConfigUriEnv* = "COGAME_CONFIG_URI"
  CogameResultsUriEnv* = "COGAME_RESULTS_URI"
  CogameSaveReplayUriEnv* = "COGAME_SAVE_REPLAY_URI"
  CogameLoadReplayUriEnv* = "COGAME_LOAD_REPLAY_URI"

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

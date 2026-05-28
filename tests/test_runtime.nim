import
  std/[os, strutils],
  bitworld/runtime

let workspace = getTempDir() / ("bitworld-cogame-runtime-" & $getCurrentProcessId())
if dirExists(workspace):
  removeDir(workspace)
createDir(workspace)

let resultsPath = workspace / "nested" / "results.json"
let configPath = workspace / "config.json"
writeFile(configPath, """{"config":true}""")
doAssert readCogameUri(
  "file://" & configPath,
  CogameConfigUriEnv
) == """{"config":true}"""

writeCogameUri(
  "file://" & resultsPath,
  """{"ok":true}""",
  "application/json",
  CogameResultsUriEnv
)
doAssert readFile(resultsPath) == """{"ok":true}"""

let envResultsPath = workspace / "env-results.json"
putEnv(CogameResultsUriEnv, "file://" & envResultsPath)
writeCogameEnv(
  CogameResultsUriEnv,
  """{"env":true}""",
  "application/json"
)
doAssert readFile(envResultsPath) == """{"env":true}"""

let httpOutputPath = outputPathFromCogameUri(
  "https://upload.example/results",
  CogameResultsUriEnv,
  "scores.json"
)
doAssert httpOutputPath.endsWith("cogame-cogame_results_uri-scores.json")

putEnv(CogameHostEnv, "127.0.0.1")
putEnv(CogamePortEnv, "9001")
doAssert cogameHost() == "127.0.0.1"
doAssert cogamePort() == 9001

let
  replayPath = workspace / "replay.bitreplay"
  logPath = workspace / "logs" / "game.log"
putEnv(CogameConfigUriEnv, "file://" & configPath)
putEnv(CogameSaveReplayUriEnv, "file://" & replayPath)
putEnv(CogameLoadReplayUriEnv, "file://" & replayPath)
putEnv(CogameLogUriEnv, "file://" & logPath)
writeFile(replayPath, "replay-bytes")

let runtimeConfig = readRuntimeConfig()
doAssert runtimeConfig.host == "127.0.0.1"
doAssert runtimeConfig.port == 9001
doAssert runtimeConfig.config == """{"config":true}"""
doAssert runtimeConfig.resultsUri == "file://" & envResultsPath
doAssert runtimeConfig.replayUri == "file://" & replayPath
doAssert runtimeConfig.replay == "replay-bytes"
doAssert runtimeConfig.replayMode
doAssert runtimeConfig.logUri == "file://" & logPath

let
  directResultsPath = workspace / "direct-results.json"
  directReplayPath = workspace / "direct-replay.bitreplay"
  directLogPath = workspace / "direct.log"
  directConfig = RuntimeConfig(
    resultsUri: directResultsPath,
    replayUri: directReplayPath,
    logUri: directLogPath
  )
directConfig.writeResults("""{"direct":true}""")
directConfig.writeReplay("direct-replay")
directConfig.writeLog("direct-log")
doAssert readFile(directResultsPath) == """{"direct":true}"""
doAssert readFile(directReplayPath) == "direct-replay"
doAssert readFile(directLogPath) == "direct-log"

removeDir(workspace)
echo "All tests passed"

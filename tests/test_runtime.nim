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
  "application/json",
  CogameResultsMethodEnv
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
putEnv(CogameResultsMethodEnv, "post")
doAssert cogameHost("0.0.0.0") == "127.0.0.1"
doAssert cogamePort(8080) == 9001
doAssert cogameHttpMethod(CogameResultsMethodEnv) == "POST"

removeDir(workspace)
echo "All tests passed"

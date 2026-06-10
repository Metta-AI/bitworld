import
  std/[json, os],
  ../tools/quick_run

proc expectValueError(action: proc()) =
  ## Requires an action to raise ValueError.
  try:
    action()
  except ValueError:
    return
  doAssert false, "Expected ValueError."

proc testSeedParser() =
  ## Tests quick-run seed parsing.
  doAssert parseSeed("-1") == -1
  doAssert parseSeed("0") == 0
  doAssert parseSeed("123") == 123
  expectValueError(proc() = discard parseSeed("-2"))
  expectValueError(proc() = discard parseSeed("seed"))

proc testMergedConfigJson() =
  ## Tests quick-run config merging keeps seed explicit.
  let workspace = getTempDir() / "bitworld-quick-run-test"
  if dirExists(workspace):
    removeDir(workspace)
  createDir(workspace)
  let configPath = workspace / "config.json"
  writeFile(configPath, """{"maxGames":1,"seed":5}""")

  let merged = parseJson(mergedConfigJson(
    """{"tokens":["a"],"slots":[{"name":"bot"}]}""",
    """{"minPlayers":2,"seed":10}""",
    configPath,
    true,
    42
  ))

  doAssert merged["tokens"][0].getStr() == "a"
  doAssert merged["slots"][0]["name"].getStr() == "bot"
  doAssert merged["maxGames"].getInt() == 1
  doAssert merged["minPlayers"].getInt() == 2
  doAssert merged["seed"].getInt() == 42
  removeDir(workspace)

echo "Testing quick run"
testSeedParser()
testMergedConfigJson()
echo "ok"

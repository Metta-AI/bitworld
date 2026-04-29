import
  std/[json, os],
  ../common/protocol,
  ../among_them/sim

const RootDir = currentSourcePath.parentDir.parentDir

proc initAmongThemForTest(config: GameConfig): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "among_them")
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc testMaxTicksConfigJson() =
  ## Tests replay config serialization for max tick budgets.
  var config = defaultGameConfig()
  config.maxTicks = 123

  let serialized = parseJson(config.configJson())
  doAssert serialized["maxTicks"].getInt() == 123,
    "maxTicks should be serialized in replay config"

  var roundTrip = defaultGameConfig()
  roundTrip.update($serialized)
  doAssert roundTrip.maxTicks == 123,
    "maxTicks should round-trip through config JSON"

proc testMaxTicksStartsAtGameStart() =
  ## Tests that maxTicks starts after lobby and times out as a draw/truncation.
  var config = defaultGameConfig()
  config.minPlayers = 3
  config.imposterCount = 1
  config.maxTicks = 2
  config.tasksPerPlayer = 1

  var sim = initAmongThemForTest(config)
  discard sim.addPlayer("player1")
  discard sim.addPlayer("player2")
  discard sim.addPlayer("player3")

  var inputs = newSeq[InputState](sim.players.len)
  sim.step(inputs, inputs)
  doAssert sim.phase == RoleReveal,
    "game should enter role reveal once minPlayers join"
  doAssert sim.gameTicksElapsed() == 0,
    "max tick budget should not start during role reveal"

  for _ in 0 ..< sim.config.roleRevealTicks:
    sim.step(inputs, inputs)
  doAssert sim.phase == Playing, "game should enter play after role reveal"
  doAssert sim.gameTicksElapsed() == 0,
    "max tick budget should start when play starts, not in lobby or role reveal"

  sim.step(inputs, inputs)
  doAssert sim.phase == Playing, "game should still be active before maxTicks"
  doAssert sim.gameTicksElapsed() == 1

  sim.step(inputs, inputs)
  doAssert sim.phase == GameOver, "game should end once maxTicks is reached"
  doAssert sim.winner == Crewmate,
    "time budget should use the draw sentinel winner"
  doAssert sim.timeLimitReached, "time budget win should be marked as truncated"

  for player in sim.players:
    doAssert player.reward == 0,
      "time budget should not award win rewards"

testMaxTicksConfigJson()
testMaxTicksStartsAtGameStart()
echo "All tests passed"

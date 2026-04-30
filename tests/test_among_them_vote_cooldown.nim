import
  std/os,
  ../among_them/sim

const RootDir = currentSourcePath.parentDir.parentDir

proc initAmongThemForTest(config: GameConfig): SimServer =
  ## Initializes Among Them from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "among_them")
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc addPlayers(sim: var SimServer, count: int) =
  ## Adds test players to the simulation.
  for i in 0 ..< count:
    discard sim.addPlayer("player" & $(i + 1))

proc testVoteResultResetsImposterCooldown() =
  ## Tests that meetings reset living impostor kill cooldowns.
  var config = defaultGameConfig()
  config.minPlayers = 3
  config.imposterCount = 1
  config.killCooldownTicks = 1200
  config.tasksPerPlayer = 1

  var sim = initAmongThemForTest(config)
  sim.addPlayers(3)
  let imposter = 0
  sim.players[imposter].role = Imposter

  sim.players[imposter].killCooldown = 17
  sim.startVote()
  sim.voteState.ejectedPlayer = -1
  sim.applyVoteResult()

  doAssert sim.phase == Playing, "vote result should return to playing"
  doAssert sim.players[imposter].killCooldown == config.killCooldownTicks,
    "living impostor cooldown should reset after a vote"

testVoteResultResetsImposterCooldown()
echo "All tests passed"

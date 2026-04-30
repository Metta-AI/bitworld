import
  std/[os, sequtils, strutils],
  ../common/protocol,
  ../among_them/sim

# Mirror of among_them/server.nim:buildRewardPacket so the test can verify
# the wire format without exposing private server internals.
proc buildRewardPacketCopy(sim: SimServer): string =
  proc rewardAddress(address: string): string =
    let parts = address.splitWhitespace()
    if parts.len >= 2:
      return parts[0] & ":" & parts[1]
    address
  proc rewardAccountFor(sim: SimServer, address: string): int =
    for i in 0 ..< sim.rewardAccounts.len:
      if sim.rewardAccounts[i].address == address:
        return i
    -1
  proc addStatLine(packet: var string,
      name, identity: string, value: int) =
    packet.add(name)
    packet.add(' ')
    packet.add(identity)
    packet.add(' ')
    packet.add($value)
    packet.add('\n')
  for player in sim.players:
    let
      identity = player.address.rewardAddress()
      accountIndex = sim.rewardAccountFor(player.address)
    result.addStatLine("reward", identity, player.reward)
    if accountIndex >= 0:
      let account = sim.rewardAccounts[accountIndex]
      result.addStatLine("wins_imposter", identity, account.winsImposter)
      result.addStatLine("wins_crewmate", identity, account.winsCrewmate)
      result.addStatLine("games_imposter", identity, account.gamesImposter)
      result.addStatLine("games_crewmate", identity, account.gamesCrewmate)
      result.addStatLine("kills", identity, account.kills)
      result.addStatLine("tasks", identity, account.tasks)

const RootDir = currentSourcePath.parentDir.parentDir

proc initAmongThemForTest(config: GameConfig): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "among_them")
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc accountFor(sim: SimServer, address: string): RewardAccount =
  for account in sim.rewardAccounts:
    if account.address == address:
      return account
  raise newException(ValueError, "no account for " & address)

proc rolesByAddress(sim: SimServer): seq[(string, PlayerRole)] =
  for player in sim.players:
    result.add((player.address, player.role))

proc testCrewWinIncrementsCrewmateStats() =
  ## A crew win must increment winsCrewmate (and gamesCrewmate) for every
  ## player whose role is Crewmate at the end of the game, with no spillover
  ## into the impostor counters.
  var config = defaultGameConfig()
  config.minPlayers = 3
  config.imposterCount = 1
  config.tasksPerPlayer = 1
  config.roleRevealTicks = 0
  config.gameOverTicks = 1

  var sim = initAmongThemForTest(config)
  discard sim.addPlayer("p1")
  discard sim.addPlayer("p2")
  discard sim.addPlayer("p3")

  var inputs = newSeq[InputState](sim.players.len)
  sim.step(inputs, inputs)
  doAssert sim.phase == Playing,
    "game should start at minPlayers; phase is " & $sim.phase

  # Snapshot which addresses got which roles for this run; the test must
  # verify per-role expectations against the actual assignment.
  let assigned = sim.rolesByAddress()
  for (address, role) in assigned:
    let account = sim.accountFor(address)
    if role == Imposter:
      doAssert account.gamesImposter == 1,
        "imposter should have gamesImposter=1 after startGame; got " &
          $account.gamesImposter & " for " & address
      doAssert account.gamesCrewmate == 0,
        "imposter should have gamesCrewmate=0 after startGame; got " &
          $account.gamesCrewmate & " for " & address
    else:
      doAssert account.gamesCrewmate == 1,
        "crewmate should have gamesCrewmate=1 after startGame; got " &
          $account.gamesCrewmate & " for " & address
      doAssert account.gamesImposter == 0,
        "crewmate should have gamesImposter=0 after startGame; got " &
          $account.gamesImposter & " for " & address

  sim.finishGame(Crewmate)
  doAssert sim.phase == GameOver
  doAssert sim.winner == Crewmate

  for (address, role) in assigned:
    let account = sim.accountFor(address)
    if role == Imposter:
      doAssert account.winsImposter == 0,
        "imposter must not gain winsImposter on crew win; got " &
          $account.winsImposter & " for " & address
      doAssert account.winsCrewmate == 0,
        "imposter must not gain winsCrewmate on crew win; got " &
          $account.winsCrewmate & " for " & address
    else:
      doAssert account.winsCrewmate == 1,
        "crewmate must gain winsCrewmate=1 on crew win; got " &
          $account.winsCrewmate & " for " & address
      doAssert account.winsImposter == 0,
        "crewmate must not gain winsImposter on crew win; got " &
          $account.winsImposter & " for " & address

proc testCrewWinPersistsAcrossReset() =
  ## After resetToLobby the rewardAccounts must still hold the prior win.
  ## The only counters that should change between games are reward (zeroed
  ## on Player rebuild) and the per-game increments at the next startGame.
  var config = defaultGameConfig()
  config.minPlayers = 3
  config.imposterCount = 1
  config.tasksPerPlayer = 1
  config.roleRevealTicks = 0
  config.gameOverTicks = 1

  var sim = initAmongThemForTest(config)
  discard sim.addPlayer("p1")
  discard sim.addPlayer("p2")
  discard sim.addPlayer("p3")
  var inputs = newSeq[InputState](sim.players.len)
  sim.step(inputs, inputs)
  let assigned = sim.rolesByAddress()
  sim.finishGame(Crewmate)

  sim.resetToLobby()
  doAssert sim.players.len == 0
  for (address, _) in assigned:
    doAssert sim.accountFor(address).winsCrewmate ==
      (if assigned.anyIt(it[0] == address and it[1] == Crewmate): 1 else: 0),
      "winsCrewmate must survive resetToLobby"

proc testCrewWinViaVoteEjection() =
  ## The realistic crew-win path: vote ejects the impostor, then
  ## checkWinCondition fires finishGame(Crewmate). Mirrors what happens in a
  ## real game so this regression-tests the actual call chain.
  var config = defaultGameConfig()
  config.minPlayers = 3
  config.imposterCount = 1
  config.tasksPerPlayer = 1
  config.roleRevealTicks = 0
  config.gameOverTicks = 1
  config.voteResultTicks = 1

  var sim = initAmongThemForTest(config)
  discard sim.addPlayer("p1")
  discard sim.addPlayer("p2")
  discard sim.addPlayer("p3")

  var inputs = newSeq[InputState](sim.players.len)
  sim.step(inputs, inputs)
  doAssert sim.phase == Playing

  let assigned = sim.rolesByAddress()
  var impIndex = -1
  for i in 0 ..< sim.players.len:
    if sim.players[i].role == Imposter:
      impIndex = i
  doAssert impIndex >= 0

  # Force-tally the vote with everyone voting the impostor.
  sim.startVote()
  doAssert sim.phase == Voting
  sim.voteState.votes = newSeq[int](sim.players.len)
  for i in 0 ..< sim.players.len:
    sim.voteState.votes[i] = impIndex
  sim.tallyVotes()
  doAssert sim.phase == VoteResult
  doAssert sim.voteState.ejectedPlayer == impIndex,
    "test setup expects impostor to be ejected"

  # Step through VoteResult so applyVoteResult + checkWinCondition fire.
  sim.step(inputs, inputs)
  doAssert sim.phase == GameOver,
    "ejecting the only impostor should end the game; phase is " & $sim.phase
  doAssert sim.winner == Crewmate

  for (address, role) in assigned:
    let account = sim.accountFor(address)
    if role == Imposter:
      doAssert account.winsCrewmate == 0
      doAssert account.winsImposter == 0
    else:
      doAssert account.winsCrewmate == 1,
        "crewmate (" & address & ") should have winsCrewmate=1 after " &
          "vote-eject crew win; got " & $account.winsCrewmate

proc testUserConfigCrewWin() =
  ## Exercises the user-reported config (8 players, 2 imposters, 8 tasks
  ## per crewmate, 360-tick vote timer). Crew win comes from ejecting both
  ## imposters via vote. Verifies winsCrewmate=1 for every crewmate and
  ## winsImposter=0 for both imposters after the win.
  var config = defaultGameConfig()
  config.minPlayers = 8
  config.imposterCount = 2
  config.tasksPerPlayer = 8
  config.voteTimerTicks = 360
  config.roleRevealTicks = 0
  config.gameOverTicks = 1
  config.voteResultTicks = 1

  var sim = initAmongThemForTest(config)
  for i in 1 .. 8:
    discard sim.addPlayer("p" & $i)

  var inputs = newSeq[InputState](sim.players.len)
  sim.step(inputs, inputs)
  doAssert sim.phase == Playing,
    "game should start with 8 players; phase is " & $sim.phase

  let assigned = sim.rolesByAddress()
  var imposters: seq[int] = @[]
  for i in 0 ..< sim.players.len:
    if sim.players[i].role == Imposter:
      imposters.add(i)
  doAssert imposters.len == 2,
    "config asks for 2 imposters; got " & $imposters.len

  # Eject impostor #1.
  sim.startVote()
  sim.voteState.votes = newSeq[int](sim.players.len)
  for i in 0 ..< sim.players.len:
    sim.voteState.votes[i] = imposters[0]
  sim.tallyVotes()
  doAssert sim.voteState.ejectedPlayer == imposters[0]
  sim.step(inputs, inputs)
  doAssert sim.phase == Playing,
    "game should continue after first imposter ejected; phase is " &
      $sim.phase
  doAssert not sim.players[imposters[0]].alive,
    "first imposter should be dead after ejection"

  # Eject impostor #2.
  sim.startVote()
  sim.voteState.votes = newSeq[int](sim.players.len)
  for i in 0 ..< sim.players.len:
    if sim.players[i].alive:
      sim.voteState.votes[i] = imposters[1]
  sim.tallyVotes()
  doAssert sim.voteState.ejectedPlayer == imposters[1]
  sim.step(inputs, inputs)
  doAssert sim.phase == GameOver,
    "ejecting both imposters should end the game; phase is " & $sim.phase
  doAssert sim.winner == Crewmate

  for (address, role) in assigned:
    let account = sim.accountFor(address)
    if role == Imposter:
      doAssert account.winsImposter == 0
      doAssert account.winsCrewmate == 0
      doAssert account.gamesImposter == 1
      doAssert account.gamesCrewmate == 0
    else:
      doAssert account.winsCrewmate == 1,
        "crewmate (" & address & ") winsCrewmate should be 1; got " &
          $account.winsCrewmate
      doAssert account.winsImposter == 0
      doAssert account.gamesCrewmate == 1
      doAssert account.gamesImposter == 0

proc testRewardPacketReflectsCrewWin() =
  ## End-to-end check: drive a sim through a crew win and verify the wire
  ## format the rewards endpoint sends shows the win for crewmates.
  var config = defaultGameConfig()
  config.minPlayers = 3
  config.imposterCount = 1
  config.tasksPerPlayer = 1
  config.roleRevealTicks = 0
  config.gameOverTicks = 1
  config.voteResultTicks = 1

  var sim = initAmongThemForTest(config)
  discard sim.addPlayer("p1")
  discard sim.addPlayer("p2")
  discard sim.addPlayer("p3")
  var inputs = newSeq[InputState](sim.players.len)
  sim.step(inputs, inputs)

  let assigned = sim.rolesByAddress()
  var impIndex = -1
  for i in 0 ..< sim.players.len:
    if sim.players[i].role == Imposter:
      impIndex = i

  sim.startVote()
  sim.voteState.votes = newSeq[int](sim.players.len)
  for i in 0 ..< sim.players.len:
    sim.voteState.votes[i] = impIndex
  sim.tallyVotes()
  sim.step(inputs, inputs)
  doAssert sim.phase == GameOver
  doAssert sim.winner == Crewmate

  let packet = sim.buildRewardPacketCopy()
  for (address, role) in assigned:
    let expected =
      if role == Imposter: "wins_crewmate " & address & " 0"
      else: "wins_crewmate " & address & " 1"
    doAssert expected in packet,
      "rewards packet should contain '" & expected & "'\nfull packet:\n" &
        packet

testCrewWinIncrementsCrewmateStats()
testCrewWinPersistsAcrossReset()
testCrewWinViaVoteEjection()
testUserConfigCrewWin()
testRewardPacketReflectsCrewWin()
echo "All tests passed"

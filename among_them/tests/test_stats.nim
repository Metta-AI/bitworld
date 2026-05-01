import
  std/[os, sequtils, strutils, unittest],
  ../../common/protocol,
  ../sim

const GameDir = currentSourcePath.parentDir.parentDir

proc buildRewardPacketCopy(sim: SimServer): string =
  ## Mirrors the reward packet wire format from the server.
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
  proc addStatLine(packet: var string, name, identity: string, value: int) =
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

proc initAmongThemForTest(config: GameConfig): SimServer =
  ## Initializes Among Them from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc accountFor(sim: SimServer, address: string): RewardAccount =
  ## Returns the reward account for one player address.
  for account in sim.rewardAccounts:
    if account.address == address:
      return account
  raise newException(ValueError, "no account for " & address)

proc rolesByAddress(sim: SimServer): seq[(string, PlayerRole)] =
  ## Returns player roles keyed by address.
  for player in sim.players:
    result.add((player.address, player.role))

suite "stats":
  test "crew win increments crewmate stats":
    var config = defaultGameConfig()
    config.minPlayers = 3
    config.imposterCount = 1
    config.autoImposterCount = false
    config.tasksPerPlayer = 1
    config.roleRevealTicks = 0
    config.startWaitTicks = 0
    config.gameOverTicks = 1

    var sim = initAmongThemForTest(config)
    discard sim.addPlayer("p1")
    discard sim.addPlayer("p2")
    discard sim.addPlayer("p3")

    var inputs = newSeq[InputState](sim.players.len)
    sim.step(inputs, inputs)
    check sim.phase == Playing

    let assigned = sim.rolesByAddress()
    for (address, role) in assigned:
      checkpoint address
      let account = sim.accountFor(address)
      if role == Imposter:
        check account.gamesImposter == 1
        check account.gamesCrewmate == 0
      else:
        check account.gamesCrewmate == 1
        check account.gamesImposter == 0

    sim.finishGame(Crewmate)
    check sim.phase == GameOver
    check sim.winner == Crewmate

    for (address, role) in assigned:
      checkpoint address
      let account = sim.accountFor(address)
      if role == Imposter:
        check account.winsImposter == 0
        check account.winsCrewmate == 0
      else:
        check account.winsCrewmate == 1
        check account.winsImposter == 0

  test "crew win persists across reset":
    var config = defaultGameConfig()
    config.minPlayers = 3
    config.imposterCount = 1
    config.autoImposterCount = false
    config.tasksPerPlayer = 1
    config.roleRevealTicks = 0
    config.startWaitTicks = 0
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
    check sim.players.len == 0
    for (address, _) in assigned:
      checkpoint address
      let expected =
        if assigned.anyIt(it[0] == address and it[1] == Crewmate): 1 else: 0
      check sim.accountFor(address).winsCrewmate == expected

  test "crew win via vote ejection":
    var config = defaultGameConfig()
    config.minPlayers = 3
    config.imposterCount = 1
    config.autoImposterCount = false
    config.tasksPerPlayer = 1
    config.roleRevealTicks = 0
    config.startWaitTicks = 0
    config.gameOverTicks = 1
    config.voteResultTicks = 1

    var sim = initAmongThemForTest(config)
    discard sim.addPlayer("p1")
    discard sim.addPlayer("p2")
    discard sim.addPlayer("p3")

    var inputs = newSeq[InputState](sim.players.len)
    sim.step(inputs, inputs)
    check sim.phase == Playing

    let assigned = sim.rolesByAddress()
    var impIndex = -1
    for i in 0 ..< sim.players.len:
      if sim.players[i].role == Imposter:
        impIndex = i
    require impIndex >= 0

    sim.startVote()
    check sim.phase == Voting
    sim.voteState.votes = newSeq[int](sim.players.len)
    for i in 0 ..< sim.players.len:
      sim.voteState.votes[i] = impIndex
    sim.tallyVotes()
    check sim.phase == VoteResult
    check sim.voteState.ejectedPlayer == impIndex

    sim.step(inputs, inputs)
    check sim.phase == GameOver
    check sim.winner == Crewmate

    for (address, role) in assigned:
      checkpoint address
      let account = sim.accountFor(address)
      if role == Imposter:
        check account.winsCrewmate == 0
        check account.winsImposter == 0
      else:
        check account.winsCrewmate == 1

  test "user config crew win":
    var config = defaultGameConfig()
    config.minPlayers = 8
    config.imposterCount = 2
    config.autoImposterCount = false
    config.tasksPerPlayer = 8
    config.voteTimerTicks = 360
    config.roleRevealTicks = 0
    config.startWaitTicks = 0
    config.gameOverTicks = 1
    config.voteResultTicks = 1

    var sim = initAmongThemForTest(config)
    for i in 1 .. 8:
      discard sim.addPlayer("p" & $i)

    var inputs = newSeq[InputState](sim.players.len)
    sim.step(inputs, inputs)
    check sim.phase == Playing

    let assigned = sim.rolesByAddress()
    var imposters: seq[int] = @[]
    for i in 0 ..< sim.players.len:
      if sim.players[i].role == Imposter:
        imposters.add(i)
    require imposters.len == 2

    sim.startVote()
    sim.voteState.votes = newSeq[int](sim.players.len)
    for i in 0 ..< sim.players.len:
      sim.voteState.votes[i] = imposters[0]
    sim.tallyVotes()
    check sim.voteState.ejectedPlayer == imposters[0]
    sim.step(inputs, inputs)
    check sim.phase == Playing
    check not sim.players[imposters[0]].alive

    sim.startVote()
    sim.voteState.votes = newSeq[int](sim.players.len)
    for i in 0 ..< sim.players.len:
      if sim.players[i].alive:
        sim.voteState.votes[i] = imposters[1]
    sim.tallyVotes()
    check sim.voteState.ejectedPlayer == imposters[1]
    sim.step(inputs, inputs)
    check sim.phase == GameOver
    check sim.winner == Crewmate

    for (address, role) in assigned:
      checkpoint address
      let account = sim.accountFor(address)
      if role == Imposter:
        check account.winsImposter == 0
        check account.winsCrewmate == 0
        check account.gamesImposter == 1
        check account.gamesCrewmate == 0
      else:
        check account.winsCrewmate == 1
        check account.winsImposter == 0
        check account.gamesCrewmate == 1
        check account.gamesImposter == 0

  test "reward packet reflects crew win":
    var config = defaultGameConfig()
    config.minPlayers = 3
    config.imposterCount = 1
    config.autoImposterCount = false
    config.tasksPerPlayer = 1
    config.roleRevealTicks = 0
    config.startWaitTicks = 0
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
    require impIndex >= 0

    sim.startVote()
    sim.voteState.votes = newSeq[int](sim.players.len)
    for i in 0 ..< sim.players.len:
      sim.voteState.votes[i] = impIndex
    sim.tallyVotes()
    sim.step(inputs, inputs)
    check sim.phase == GameOver
    check sim.winner == Crewmate

    let packet = sim.buildRewardPacketCopy()
    for (address, role) in assigned:
      checkpoint address
      let expected =
        if role == Imposter: "wins_crewmate " & address & " 0"
        else: "wins_crewmate " & address & " 1"
      check expected in packet

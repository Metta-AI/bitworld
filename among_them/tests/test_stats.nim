import
  std/[json, os, sequtils, strutils, unittest],
  bitworld/protocol,
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
      result.addStatLine("vote_players", identity, account.votePlayers)
      result.addStatLine("vote_skip", identity, account.voteSkip)
      result.addStatLine("vote_timeout", identity, account.voteTimeout)

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

proc configuredSlots(count: int): seq[PlayerSlotConfig] =
  ## Returns named slot configs for result-shape tests.
  for i in 0 ..< count:
    result.add PlayerSlotConfig(name: "player" & $(i + 1))

proc roleSlot(name: string, role: PlayerRole): PlayerSlotConfig =
  ## Returns one named slot with a fixed role.
  PlayerSlotConfig(name: name, role: role, hasRole: true)

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

  test "active disconnect removes task burden and forfeits win":
    var config = defaultGameConfig()
    config.minPlayers = 4
    config.imposterCount = 1
    config.autoImposterCount = false
    config.roleRevealTicks = 0
    config.startWaitTicks = 0
    config.maxGames = 1
    config.tasksPerPlayer = 0
    config.slots = @[
      roleSlot("imp", Imposter),
      roleSlot("crew1", Crewmate),
      roleSlot("crew2", Crewmate),
      roleSlot("crew3", Crewmate)
    ]

    var sim = initAmongThemForTest(config)
    discard sim.addPlayer("imp", 0)
    let abandonedCrew = sim.addPlayer("crew1", 1)
    discard sim.addPlayer("crew2", 2)
    discard sim.addPlayer("crew3", 3)

    sim.startGame()
    check sim.players[abandonedCrew].role == Crewmate

    sim.players[abandonedCrew].assignedTasks = @[0]
    check sim.totalTasksRemaining() == 1

    sim.recordGameAbandon(abandonedCrew)
    sim.removePlayerAt(abandonedCrew)
    check sim.totalTasksRemaining() == 0

    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Crewmate

    let results = parseJson(sim.playerResultsJson())
    check not results["win"][1].getBool()
    check results["win"][2].getBool()
    check results["win"][3].getBool()

  test "finite roster loss aborts instead of waiting forever":
    var config = defaultGameConfig()
    config.minPlayers = 3
    config.imposterCount = 1
    config.autoImposterCount = false
    config.roleRevealTicks = 0
    config.startWaitTicks = 3
    config.maxGames = 1

    var lobbySim = initAmongThemForTest(config)
    discard lobbySim.addPlayer("p1")
    discard lobbySim.addPlayer("p2")
    discard lobbySim.addPlayer("p3")
    var inputs = newSeq[InputState](lobbySim.players.len)
    lobbySim.step(inputs, inputs)
    check lobbySim.phase == Lobby
    check lobbySim.startWaitTimer > 0
    lobbySim.removePlayerAt(2)
    check lobbySim.shouldAbortFiniteMatch()

    var activeSim = initAmongThemForTest(config)
    activeSim.config.startWaitTicks = 0
    discard activeSim.addPlayer("p1")
    discard activeSim.addPlayer("p2")
    discard activeSim.addPlayer("p3")
    activeSim.startGame()
    while activeSim.players.len > 0:
      activeSim.removePlayerAt(activeSim.players.high)
    check activeSim.shouldAbortFiniteMatch()

    activeSim.config.maxGames = 0
    check not activeSim.shouldAbortFiniteMatch()

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

  test "removing player keeps task completions aligned":
    var config = defaultGameConfig()
    config.minPlayers = 3
    config.imposterCount = 0
    config.autoImposterCount = false
    config.tasksPerPlayer = 1
    config.roleRevealTicks = 0
    config.startWaitTicks = 0

    var sim = initAmongThemForTest(config)
    discard sim.addPlayer("p1")
    discard sim.addPlayer("p2")
    discard sim.addPlayer("p3")

    var inputs = newSeq[InputState](sim.players.len)
    sim.step(inputs, inputs)
    check sim.phase == Playing

    let
      address = sim.players[2].address
      taskIndex = sim.players[2].assignedTasks[0]
    sim.completeTask(2, taskIndex)
    check sim.tasks[taskIndex].completed[2]
    check sim.accountFor(address).tasks == 1

    sim.removePlayerAt(1)
    check sim.players[1].address == address
    check sim.tasks[taskIndex].completed.len == sim.players.len
    check sim.tasks[taskIndex].completed[1]

    sim.completeTask(1, taskIndex)
    check sim.accountFor(address).tasks == 1

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

  test "player result json reflects rewards and wins":
    let config = defaultGameConfig()
    var sim = initAmongThemForTest(config)

    let crewIndex = sim.addPlayer("crew", 0)
    let imposterIndex = sim.addPlayer("imposter", 1)
    sim.players[imposterIndex].role = Imposter
    sim.players[crewIndex].role = Crewmate
    sim.addReward(imposterIndex, 5)
    sim.addReward(crewIndex, 3)
    sim.recordKill(imposterIndex)
    sim.recordTask(crewIndex)
    sim.recordTask(crewIndex)
    sim.finishGame(Imposter)

    let results = parseJson(sim.playerResultsJson())
    check results["names"].len == 2
    check results["names"][0].getStr() == "crew"
    check results["scores"][0].getInt() == 3
    check not results["win"][0].getBool()
    check results["tasks"][0].getInt() == 2
    check results["kills"][0].getInt() == 0
    check results["imposter"][0].getInt() == 0
    check results["crew"][0].getInt() == 1
    check results["names"][1].getStr() == "imposter"
    check results["scores"][1].getInt() == 5 + WinReward
    check results["win"][1].getBool()
    check results["tasks"][1].getInt() == 0
    check results["kills"][1].getInt() == 1
    check results["imposter"][1].getInt() == 1
    check results["crew"][1].getInt() == 0

  test "player result json keeps configured slots after disconnect":
    var config = defaultGameConfig()
    config.minPlayers = 2
    config.imposterCount = 1
    config.autoImposterCount = false
    config.tasksPerPlayer = 1
    config.roleRevealTicks = 0
    config.update("""{"tokens":["crew-token","imposter-token"],"slots":[
      {"name":"crew","token":"crew-token","role":"crew"},
      {"name":"imposter","token":"imposter-token","role":"imposter"}
    ]}""")
    var sim = initAmongThemForTest(config)

    let
      crewIndex = sim.addPlayer("crew", 0, "crew-token")
      imposterIndex = sim.addPlayer("imposter", 1, "imposter-token")
    sim.startGame()
    sim.addReward(crewIndex, 3)
    sim.addReward(imposterIndex, 5)
    sim.recordKill(imposterIndex)
    sim.removePlayerAt(crewIndex)
    sim.finishGame(Imposter)

    let results = parseJson(sim.playerResultsJson())
    check results["names"].len == 2
    check results["names"][0].getStr() == "crew"
    check results["scores"][0].getInt() == 3
    check not results["win"][0].getBool()
    check results["tasks"][0].getInt() == 0
    check results["kills"][0].getInt() == 0
    check results["imposter"][0].getInt() == 0
    check results["crew"][0].getInt() == 1
    check results["names"][1].getStr() == "imposter"
    check results["scores"][1].getInt() == 5 + WinReward
    check results["win"][1].getBool()
    check results["tasks"][1].getInt() == 0
    check results["kills"][1].getInt() == 1
    check results["imposter"][1].getInt() == 1
    check results["crew"][1].getInt() == 0

  test "player result json reflects vote counters":
    let config = defaultGameConfig()
    var sim = initAmongThemForTest(config)

    let
      playerVoteIndex = sim.addPlayer("player-vote", 0)
      skipIndex = sim.addPlayer("skip", 1)
      timeoutIndex = sim.addPlayer("timeout", 2)
    sim.players[playerVoteIndex].role = Crewmate
    sim.players[skipIndex].role = Crewmate
    sim.players[timeoutIndex].role = Imposter
    sim.startVote()
    sim.voteState.votes[playerVoteIndex] = timeoutIndex
    sim.voteState.votes[skipIndex] = -2
    sim.voteState.votes[timeoutIndex] = -1
    sim.tallyVotes()

    let results = parseJson(sim.playerResultsJson())
    check results["names"][0].getStr() == "player-vote"
    check results["vote_players"][0].getInt() == 1
    check results["vote_skip"][0].getInt() == 0
    check results["vote_timeout"][0].getInt() == 0
    check results["names"][1].getStr() == "skip"
    check results["vote_players"][1].getInt() == 0
    check results["vote_skip"][1].getInt() == 1
    check results["vote_timeout"][1].getInt() == 0
    check results["names"][2].getStr() == "timeout"
    check results["vote_players"][2].getInt() == 0
    check results["vote_skip"][2].getInt() == 0
    check results["vote_timeout"][2].getInt() == 1

  test "player result json reflects draw scores":
    let config = defaultGameConfig()
    var sim = initAmongThemForTest(config)

    let
      crewIndex = sim.addPlayer("crew", 0)
      imposterIndex = sim.addPlayer("imposter", 1)
    sim.players[imposterIndex].role = Imposter
    sim.players[crewIndex].role = Crewmate
    sim.addReward(imposterIndex, 5)
    sim.addReward(crewIndex, 3)
    sim.recordKill(imposterIndex)
    sim.recordTask(crewIndex)
    sim.finishGame(Crewmate, timeLimitReached = true)

    let results = parseJson(sim.playerResultsJson())
    check results["names"].len == 2
    check results["names"][0].getStr() == "crew"
    check results["scores"][0].getInt() == 3
    check not results["win"][0].getBool()
    check results["tasks"][0].getInt() == 1
    check results["kills"][0].getInt() == 0
    check results["imposter"][0].getInt() == 0
    check results["crew"][0].getInt() == 1
    check results["names"][1].getStr() == "imposter"
    check results["scores"][1].getInt() == 5
    check not results["win"][1].getBool()
    check results["tasks"][1].getInt() == 0
    check results["kills"][1].getInt() == 1
    check results["imposter"][1].getInt() == 1
    check results["crew"][1].getInt() == 0

  test "player result json keeps disconnected configured slots":
    var config = defaultGameConfig()
    config.minPlayers = 8
    config.imposterCount = 2
    config.autoImposterCount = false
    config.roleRevealTicks = 0
    config.startWaitTicks = 0
    config.slots = configuredSlots(8)

    var sim = initAmongThemForTest(config)
    for i in 0 ..< 8:
      discard sim.addPlayer("player" & $(i + 1), i)
    sim.startGame()
    sim.removePlayerAt(7)
    sim.removePlayerAt(6)
    sim.finishGame(Crewmate, timeLimitReached = true)

    let results = parseJson(sim.playerResultsJson())
    check results["names"].len == 8
    check results["scores"].len == 8
    check results["win"].len == 8
    check results["names"][0].getStr() == "player1"
    check results["names"][5].getStr() == "player6"
    check results["names"][6].getStr() == "player7"
    check results["names"][7].getStr() == "player8"
    check results["scores"][6].getInt() == 0
    check results["scores"][7].getInt() == 0
    check not results["win"][6].getBool()
    check not results["win"][7].getBool()

  test "player result json ignores accounts outside a closed configured roster":
    var config = defaultGameConfig()
    config.minPlayers = 8
    config.imposterCount = 2
    config.autoImposterCount = false
    config.roleRevealTicks = 0
    config.startWaitTicks = 0
    config.closedRoster = true
    config.slots = configuredSlots(8)

    var sim = initAmongThemForTest(config)
    for i in 0 ..< 8:
      discard sim.addPlayer("player" & $(i + 1), i)
    sim.rewardAccounts.add RewardAccount(address: "unknown", slotIndex: 8, reward: 0)
    sim.finishGame(Crewmate, timeLimitReached = true)

    let results = parseJson(sim.playerResultsJson())
    check results["names"].len == 8
    check results["scores"].len == 8
    for name in results["names"]:
      check name.getStr() != "unknown"

  test "player result json emits never connected configured slots":
    var config = defaultGameConfig()
    config.minPlayers = 6
    config.imposterCount = 1
    config.autoImposterCount = false
    config.roleRevealTicks = 0
    config.startWaitTicks = 0
    config.slots = configuredSlots(8)

    var sim = initAmongThemForTest(config)
    for i in 0 ..< 6:
      discard sim.addPlayer("player" & $(i + 1), i)
    sim.startGame()
    sim.finishGame(Crewmate, timeLimitReached = true)

    let results = parseJson(sim.playerResultsJson())
    check results["names"].len == 8
    check results["scores"].len == 8
    check results["names"][6].getStr() == "player7"
    check results["names"][7].getStr() == "player8"
    check results["scores"][6].getInt() == 0
    check results["scores"][7].getInt() == 0
    check results["imposter"][6].getInt() == 0
    check results["crew"][6].getInt() == 0
    check results["imposter"][7].getInt() == 0
    check results["crew"][7].getInt() == 0

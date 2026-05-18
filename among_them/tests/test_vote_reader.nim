import
  std/[os, unittest],
  ../sim,
  ../votereader

const
  GameDir = currentSourcePath.parentDir.parentDir

proc initAmongThemForTest(config: GameConfig): SimServer =
  ## Initializes Among Them from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc addPlayers(sim: var SimServer, count: int) =
  ## Adds test players to the simulation.
  for i in 0 ..< count:
    discard sim.addPlayer("player" & $(i + 1))

suite "vote reader":
  test "parses rendered vote screen":
    var config = defaultGameConfig()
    config.minPlayers = 16
    config.tasksPerPlayer = 1
    var sim = initAmongThemForTest(config)
    sim.addPlayers(16)
    sim.startVote()
    sim.players[4].alive = false
    for i in 0 ..< sim.voteState.votes.len:
      sim.voteState.votes[i] = VoteReaderUnknown
    sim.voteState.votes[0] = 1
    sim.voteState.votes[1] = VoteReaderSkip
    sim.voteState.votes[2] = 0
    sim.voteState.votes[5] = VoteReaderSkip
    sim.voteState.votes[15] = 0
    sim.voteState.cursor[3] = sim.players.len
    sim.addVotingChat(0, "red sus")
    sim.addVotingChat(1, "green is clean")
    sim.addVotingChat(15, "light blue fake")
    sim.addVotingChat(6, "vote red")

    discard sim.buildVoteFrame(3)
    let read = parseVoteFrame(
      sim.fb.indices,
      sim.asciiSprites,
      sim.playerSprite,
      sim.bodySprite
    )

    check read.found
    check read.playerCount == 16
    check read.cursor == 16
    check read.selfSlot == 3
    for i in 0 ..< read.playerCount:
      check read.slots[i].colorIndex == i
    check not read.slots[4].alive
    check read.choices[0] == 1
    check read.choices[1] == VoteReaderSkip
    check read.choices[2] == 0
    check read.choices[5] == VoteReaderSkip
    check read.choices[15] == 0
    check read.chat.len == 4
    check read.chat[0].colorIndex == 0
    check read.chat[0].text == "red sus"
    check read.chat[1].colorIndex == 1
    check read.chat[1].text == "green is clean"
    check read.chat[2].colorIndex == 15
    check read.chat[2].text == "light blue fake"
    check read.chat[3].colorIndex == 6
    check read.chat[3].text == "vote red"
    check read.chatSusColor == 0

  test "parses rendered vote screen with shuffled colors":
    var config = defaultGameConfig()
    config.minPlayers = 4
    config.tasksPerPlayer = 1
    var sim = initAmongThemForTest(config)
    sim.addPlayers(4)
    sim.players[0].color = PlayerColors[1]
    sim.players[1].color = PlayerColors[0]
    sim.players[2].color = PlayerColors[3]
    sim.players[3].color = PlayerColors[2]
    sim.startVote()

    discard sim.buildVoteFrame(2)
    let read = parseVoteFrame(
      sim.fb.indices,
      sim.asciiSprites,
      sim.playerSprite,
      sim.bodySprite
    )

    check read.found
    check read.playerCount == 4
    check read.selfSlot == 2
    check read.slots[0].colorIndex == 1
    check read.slots[1].colorIndex == 0
    check read.slots[2].colorIndex == 3
    check read.slots[3].colorIndex == 2

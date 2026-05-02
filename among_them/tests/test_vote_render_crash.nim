import ../sim, ../global
import protocol

echo "Testing vote render crash"

var config = defaultGameConfig()
config.minPlayers = 7
config.imposterCount = 0
config.autoImposterCount = false
config.tasksPerPlayer = 1
config.voteTimerTicks = 360
config.roleRevealTicks = 0
config.showPlayerLabels = true

var game = initSimServer(config)
for i in 0 ..< 7:
  discard game.addPlayer("debug" & $i)

game.startGame()
doAssert game.phase == Playing
game.startVote(VoteCalledButton, 0)
doAssert game.phase == Voting

var
  globalState = initGlobalViewerState()
  nextGlobalState: GlobalViewerState
  playerStates = newSeq[PlayerViewerState](game.players.len)
  nextPlayerState: PlayerViewerState
  inputs = newSeq[InputState](game.players.len)
  prevInputs = inputs

for tick in 0 ..< 160:
  if tick == 5:
    inputs[0].attack = true
  elif tick == 6:
    inputs[0].attack = false
  if tick == 8:
    game.addVotingChat(0, "red says vote blue")
  if tick == 20:
    inputs[1].right = true
  elif tick == 21:
    inputs[1].right = false
  elif tick == 22:
    inputs[1].attack = true
  elif tick == 23:
    inputs[1].attack = false
  for i in 0 ..< game.players.len:
    discard game.render(i)
    discard game.buildSpriteProtocolPlayerUpdates(
      i,
      playerStates[i],
      nextPlayerState
    )
    playerStates[i] = nextPlayerState
  discard game.buildSpriteProtocolUpdates(
    globalState,
    nextGlobalState,
    game.tickCount,
    false,
    1,
    config.maxTicks,
    false,
    false
  )
  globalState = nextGlobalState
  game.step(inputs, prevInputs)
  prevInputs = inputs

echo "ok"

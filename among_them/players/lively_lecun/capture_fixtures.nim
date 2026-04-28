## Captures reference frames for each among_them phase and writes them
## to ./testdata/phase_*.bin for use as Go test fixtures.
##
## Run from the repo root after `nim c` setup is in place:
##   nim c -r among_them/players/lively_lecun/capture_fixtures.nim
##
## Each phase is captured in isolation by setting up a sim, driving it to
## the target phase, and dumping `sim.render(playerIndex=0)` (8192 bytes).

import std/[os, strformat]
import ../../../common/protocol
import ../../sim

const
  ScriptDir = currentSourcePath.parentDir
  RootDir = ScriptDir.parentDir.parentDir.parentDir
  TestDataDir = ScriptDir / "testdata"

proc setupSim(numPlayers: int, minPlayers = 3): SimServer =
  let prev = getCurrentDir()
  setCurrentDir(RootDir / "among_them")
  try:
    var config = defaultGameConfig()
    config.minPlayers = minPlayers
    config.tasksPerPlayer = 1
    config.imposterCount = 1
    result = initSimServer(config)
    for i in 0 ..< numPlayers:
      discard result.addPlayer(&"player{i}")
  finally:
    setCurrentDir(prev)

proc writeFrame(name: string, frame: seq[uint8]) =
  createDir(TestDataDir)
  let path = TestDataDir / &"phase_{name}.bin"
  var s = newString(frame.len)
  for i in 0 ..< frame.len:
    s[i] = char(frame[i])
  writeFile(path, s)
  echo &"wrote {path} ({frame.len} bytes)"

proc advanceUntil(sim: var SimServer, target: GamePhase, maxSteps = 400) =
  var inputs = newSeq[InputState](sim.players.len)
  var prev = inputs
  for _ in 0 .. maxSteps:
    if sim.phase == target:
      return
    sim.step(inputs, prev)
    prev = inputs
  raise newException(ValueError,
    &"sim did not reach {target} within {maxSteps} steps; phase={sim.phase}")

proc capture() =
  # Lobby (waiting): 1 of 3 required players present.
  block:
    var sim = setupSim(numPlayers = 1, minPlayers = 3)
    doAssert sim.phase == Lobby
    writeFrame("lobby_waiting", sim.render(0))

  # Lobby (ready): minPlayers met, but no step yet.
  block:
    var sim = setupSim(numPlayers = 3, minPlayers = 3)
    doAssert sim.phase == Lobby
    writeFrame("lobby_ready", sim.render(0))

  # RoleReveal: first step triggers startGame. Capture before the timer expires.
  block:
    var sim = setupSim(numPlayers = 3, minPlayers = 3)
    var inputs = newSeq[InputState](sim.players.len)
    sim.step(inputs, inputs)
    if sim.phase == RoleReveal:
      writeFrame("role_reveal", sim.render(0))
    else:
      echo &"  skipped role_reveal capture (phase={sim.phase})"

  # Playing: advance past RoleReveal.
  block:
    var sim = setupSim(numPlayers = 3, minPlayers = 3)
    advanceUntil(sim, Playing)
    writeFrame("playing", sim.render(0))

  # Playing - on a task: teleport a crewmate onto one of their assigned
  # task stations so the task icon overlays the player's on-screen position.
  block:
    var sim = setupSim(numPlayers = 3, minPlayers = 3)
    advanceUntil(sim, Playing)
    var idx = -1
    for i in 0 ..< sim.players.len:
      if sim.players[i].role == Crewmate and sim.players[i].assignedTasks.len > 0:
        idx = i
        break
    if idx >= 0:
      let
        taskIdx = sim.players[idx].assignedTasks[0]
        task = sim.tasks[taskIdx]
      sim.players[idx].x = task.x + task.w div 2
      sim.players[idx].y = task.y + task.h div 2
      writeFrame("playing_on_task", sim.render(idx))
    else:
      echo &"  skipped playing_on_task (no crewmate has tasks)"

  # Voting.
  block:
    var sim = setupSim(numPlayers = 3, minPlayers = 3)
    advanceUntil(sim, Playing)
    sim.startVote()
    doAssert sim.phase == Voting
    writeFrame("voting", sim.render(0))

  # VoteResult: all skip, tally.
  block:
    var sim = setupSim(numPlayers = 3, minPlayers = 3)
    advanceUntil(sim, Playing)
    sim.startVote()
    for i in 0 ..< sim.players.len:
      sim.voteState.votes[i] = -2
    sim.tallyVotes()
    doAssert sim.phase == VoteResult
    writeFrame("vote_result", sim.render(0))

  # GameOver: force-finish.
  block:
    var sim = setupSim(numPlayers = 3, minPlayers = 3)
    advanceUntil(sim, Playing)
    sim.finishGame(Crewmate)
    doAssert sim.phase == GameOver
    writeFrame("game_over", sim.render(0))

capture()
echo "done"

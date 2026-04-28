## Captures reference frames for each among_them phase and writes them
## to ./testdata/phase_*.bin for use as Go test fixtures. Also dumps the
## skeld map as ./testdata/skeld_map.bin (508 968 unpacked palette indices)
## and a ./testdata/fixtures.tsv sidecar with ground-truth camera/player
## coordinates for the playing-phase fixtures so the M4 localizer has
## something to compare against.
##
## Run from the repo root after `nim c` setup is in place:
##   nim c -r among_them/players/lively_lecun/capture_fixtures.nim

import std/[os, strformat, strutils]
import ../../../common/protocol
import ../../sim

const
  ScriptDir = currentSourcePath.parentDir
  RootDir = ScriptDir.parentDir.parentDir.parentDir
  TestDataDir = ScriptDir / "testdata"

var fixtureMeta: seq[string] = @[]

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

proc recordPlayerMeta(name: string, sim: SimServer, playerIndex: int) =
  ## Records ground-truth camera/player coordinates for the M4 localizer.
  ## Only meaningful during the Playing phase; called after writeFrame.
  let view = sim.playerView(playerIndex)
  let p = sim.players[playerIndex]
  fixtureMeta.add(&"{name}\t{view.cameraX}\t{view.cameraY}\t{p.x}\t{p.y}")

proc writeMapAsset(sim: SimServer) =
  ## Dumps the rendered skeld map (palette indices, MapWidth*MapHeight bytes)
  ## for client-side template matching.
  createDir(TestDataDir)
  let path = TestDataDir / "skeld_map.bin"
  var s = newString(sim.mapPixels.len)
  for i in 0 ..< sim.mapPixels.len:
    s[i] = char(sim.mapPixels[i])
  writeFile(path, s)
  echo &"wrote {path} ({sim.mapPixels.len} bytes, {MapWidth}x{MapHeight})"

proc writeMeta() =
  let path = TestDataDir / "fixtures.tsv"
  let header = "name\tcameraX\tcameraY\tplayerX\tplayerY"
  writeFile(path, header & "\n" & fixtureMeta.join("\n") & "\n")
  echo &"wrote {path} ({fixtureMeta.len} entries)"

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

  # Map asset: write once from a freshly-initialised sim. mapPixels are
  # the same regardless of phase / player count.
  block:
    var sim = setupSim(numPlayers = 3, minPlayers = 3)
    writeMapAsset(sim)

  # Playing: advance past RoleReveal.
  block:
    var sim = setupSim(numPlayers = 3, minPlayers = 3)
    advanceUntil(sim, Playing)
    writeFrame("playing", sim.render(0))
    recordPlayerMeta("playing", sim, 0)

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
      recordPlayerMeta("playing_on_task", sim, idx)
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
writeMeta()
echo "done"

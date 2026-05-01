## parse_voting_screen_unit — Sprint 7.1 diagnostic test.
##
## Builds real voting frames via `sim.buildVoteFrame`, feeds them
## through mod_talks' `parseVotingScreen`, and reports exactly which
## parsing step fails. This is the "data before code" step from
## LLM_SPRINTS.md §7.1.
##
## Run:
##   nim r among_them/players/mod_talks/test/parse_voting_screen_unit.nim
##
## Exit 0 on full pass, 1 on any failure.

import std/[strformat, strutils]
import ../../../sim
import ../../../../common/server

import ../bot
import ../types
import ../voting
import ../evidence  # playerColorName

import protocol  # ScreenWidth, ScreenHeight

const
  LobbySize = 8

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc buildTestBot(): Bot =
  var bot = initBot(masterSeed = 1)
  for i in 0 ..< LobbySize:
    discard bot.sim.addPlayer("acct-" & $i)
  bot

proc feedFrame(bot: var Bot, frame: openArray[uint8]) =
  ## Copies unpacked framebuffer pixels into the bot's input buffer
  ## and advances one tick — exactly what stepUnpackedFrame does, but
  ## we avoid calling it so we can instrument the parse in isolation.
  let frameLen = ScreenWidth * ScreenHeight
  assert frame.len == frameLen
  if bot.io.unpacked.len != frameLen:
    bot.io.unpacked.setLen(frameLen)
  for i in 0 ..< frameLen:
    bot.io.unpacked[i] = frame[i] and 0x0f
  inc bot.frameTick

# ---------------------------------------------------------------------------
# Test 1 — basic voting screen parse (no cursor, playerIndex=-1)
# ---------------------------------------------------------------------------

proc testBasicParse(): int =
  var bot = buildTestBot()
  bot.sim.startVote()
  discard bot.sim.buildVoteFrame(-1)  # -1 = no cursor / self-marker
  var frame = newSeq[uint8](bot.sim.fb.indices.len)
  for i in 0 ..< frame.len:
    frame[i] = bot.sim.fb.indices[i]
  bot.feedFrame(frame)
  # Try parseVotingScreen directly.
  if not bot.parseVotingScreen():
    echo "[basic_parse] FAIL: parseVotingScreen returned false"
    # Diagnose: try each player count individually.
    for count in countdown(MaxPlayers, 1):
      let layout = voteGridLayout(count)
      let skipOk = bot.voteSkipTextMatches(layout.skipX, layout.skipY)
      if count == LobbySize:
        echo &"  count={count}: skipTextMatches={skipOk}"
        if skipOk:
          for i in 0 ..< count:
            let slot = bot.parseVoteSlot(count, i)
            echo &"    slot[{i}]: colorIndex={slot.colorIndex} " &
                 &"alive={slot.alive} expected={i}"
    return 1
  if bot.voting.playerCount != LobbySize:
    echo &"[basic_parse] FAIL: playerCount={bot.voting.playerCount} want={LobbySize}"
    return 1
  for i in 0 ..< bot.voting.playerCount:
    if bot.voting.slots[i].colorIndex != i:
      echo &"[basic_parse] FAIL: slot[{i}].colorIndex=" &
           &"{bot.voting.slots[i].colorIndex} want={i}"
      return 1
  echo "[basic_parse] OK"
  0

# ---------------------------------------------------------------------------
# Test 2 — voting screen with cursor at player 0 (first alive)
# ---------------------------------------------------------------------------

proc testWithCursor(): int =
  var bot = buildTestBot()
  bot.sim.startVote()
  # Cursor starts at firstAlive (player 0)
  discard bot.sim.buildVoteFrame(0)
  var frame = newSeq[uint8](bot.sim.fb.indices.len)
  for i in 0 ..< frame.len:
    frame[i] = bot.sim.fb.indices[i]
  bot.feedFrame(frame)
  if not bot.parseVotingScreen():
    echo "[with_cursor] FAIL: parseVotingScreen returned false"
    # Diagnose.
    let layout = voteGridLayout(LobbySize)
    let skipOk = bot.voteSkipTextMatches(layout.skipX, layout.skipY)
    echo &"  skipTextMatches={skipOk}"
    for i in 0 ..< LobbySize:
      let slot = bot.parseVoteSlot(LobbySize, i)
      echo &"    slot[{i}]: colorIndex={slot.colorIndex} alive={slot.alive}"
    return 1
  echo "[with_cursor] OK: playerCount={bot.voting.playerCount} " &
       &"cursor={bot.voting.cursor} selfSlot={bot.voting.selfSlot}"
  0

# ---------------------------------------------------------------------------
# Test 3 — second frame after cursor move (simulating the live bug)
# ---------------------------------------------------------------------------

proc testSecondFrame(): int =
  var bot = buildTestBot()
  bot.sim.startVote()
  # Frame 1: cursor at firstAlive (player 0), self=player 3
  discard bot.sim.buildVoteFrame(3)
  var frame1 = newSeq[uint8](bot.sim.fb.indices.len)
  for i in 0 ..< frame1.len:
    frame1[i] = bot.sim.fb.indices[i]
  bot.feedFrame(frame1)
  let parsed1 = bot.parseVotingScreen()
  if not parsed1:
    echo "[second_frame] FAIL: first parse failed"
    return 1
  echo &"[second_frame] frame 1: parsed={parsed1} " &
       &"playerCount={bot.voting.playerCount} cursor={bot.voting.cursor}"

  # Simulate cursor move: moveCursor(-1) wraps to skip
  bot.sim.moveCursor(3, -1)

  # Frame 2: re-render with moved cursor
  discard bot.sim.buildVoteFrame(3)
  var frame2 = newSeq[uint8](bot.sim.fb.indices.len)
  for i in 0 ..< frame2.len:
    frame2[i] = bot.sim.fb.indices[i]
  bot.feedFrame(frame2)
  let parsed2 = bot.parseVotingScreen()
  if not parsed2:
    echo "[second_frame] FAIL: second parse failed (THIS IS THE BUG)"
    # Diagnose.
    let layout = voteGridLayout(LobbySize)
    let skipOk = bot.voteSkipTextMatches(layout.skipX, layout.skipY)
    echo &"  skipTextMatches={skipOk}"
    for i in 0 ..< LobbySize:
      let slot = bot.parseVoteSlot(LobbySize, i)
      echo &"    slot[{i}]: colorIndex={slot.colorIndex} alive={slot.alive}"
    return 1
  echo &"[second_frame] frame 2: parsed={parsed2} " &
       &"playerCount={bot.voting.playerCount} cursor={bot.voting.cursor}"
  0

# ---------------------------------------------------------------------------
# Test 4 — with chat messages
# ---------------------------------------------------------------------------

proc testWithChat(): int =
  var bot = buildTestBot()
  bot.sim.startVote()
  bot.sim.addVotingChat(0, "red sus")
  bot.sim.addVotingChat(2, "body in nav")
  discard bot.sim.buildVoteFrame(3)
  var frame = newSeq[uint8](bot.sim.fb.indices.len)
  for i in 0 ..< frame.len:
    frame[i] = bot.sim.fb.indices[i]
  bot.feedFrame(frame)
  if not bot.parseVotingScreen():
    echo "[with_chat] FAIL: parseVotingScreen returned false"
    return 1
  echo &"[with_chat] OK: chatLines={bot.voting.chatLines.len}"
  0

# ---------------------------------------------------------------------------
# Test 5 — with vote dots (some votes cast)
# ---------------------------------------------------------------------------

proc testWithVotes(): int =
  var bot = buildTestBot()
  bot.sim.startVote()
  bot.sim.voteState.votes[0] = 1   # player 0 votes for player 1
  bot.sim.voteState.votes[1] = -2  # player 1 skips
  discard bot.sim.buildVoteFrame(3)
  var frame = newSeq[uint8](bot.sim.fb.indices.len)
  for i in 0 ..< frame.len:
    frame[i] = bot.sim.fb.indices[i]
  bot.feedFrame(frame)
  if not bot.parseVotingScreen():
    echo "[with_votes] FAIL: parseVotingScreen returned false"
    return 1
  echo "[with_votes] OK"
  0

# ---------------------------------------------------------------------------
# Test 6 — pack/unpack cycle (simulates the network path)
# ---------------------------------------------------------------------------

proc testPackUnpack(): int =
  var bot = buildTestBot()
  bot.sim.startVote()
  let packed = bot.sim.buildVoteFrame(3)  # returns packed bytes
  # Unpack through the bot's standard path.
  discard bot.stepPackedFrame(packed)
  if not bot.voting.active:
    echo "[pack_unpack] FAIL: bot.voting.active is false after stepPackedFrame"
    # Diagnose.
    let layout = voteGridLayout(LobbySize)
    let skipOk = bot.voteSkipTextMatches(layout.skipX, layout.skipY)
    echo &"  skipTextMatches={skipOk}"
    for i in 0 ..< LobbySize:
      let slot = bot.parseVoteSlot(LobbySize, i)
      echo &"    slot[{i}]: colorIndex={slot.colorIndex} alive={slot.alive}"
    return 1
  echo "[pack_unpack] OK"
  0

# ---------------------------------------------------------------------------
# Test 7 — multi-frame through full pipeline (simulates the live bug)
# ---------------------------------------------------------------------------

proc testMultiFramePipeline(): int =
  ## The live bug: frame 1 parses, frame 2 doesn't. This test goes
  ## through the FULL decideNextMask pipeline for two consecutive
  ## frames (like a real game) to see if the second frame fails.
  var bot = buildTestBot()
  bot.sim.startVote()
  # Frame 1: first voting frame, player 3's perspective.
  let packed1 = bot.sim.buildVoteFrame(3)
  let mask1 = bot.stepPackedFrame(packed1)
  let active1 = bot.voting.active
  let branch1 = bot.diag.branchId
  echo &"[multi_frame] frame 1: active={active1} branch={branch1} " &
       &"mask={mask1} cursor={bot.voting.cursor}"
  if not active1:
    echo "[multi_frame] FAIL: frame 1 did not activate voting"
    return 1

  # Simulate cursor movement on the server side.
  bot.sim.moveCursor(3, -1)

  # Frame 2: same voting screen, cursor moved.
  let packed2 = bot.sim.buildVoteFrame(3)
  let mask2 = bot.stepPackedFrame(packed2)
  let active2 = bot.voting.active
  let branch2 = bot.diag.branchId
  echo &"[multi_frame] frame 2: active={active2} branch={branch2} " &
       &"mask={mask2} cursor={bot.voting.cursor}"
  if not active2:
    echo "[multi_frame] FAIL: frame 2 lost voting state (THIS IS THE BUG)"
    # Diagnose the frame.
    let layout = voteGridLayout(LobbySize)
    echo &"  isInterstitial={bot.percep.interstitial}"
    echo &"  interstitialText='{bot.percep.interstitialText}'"
    let skipOk = bot.voteSkipTextMatches(layout.skipX, layout.skipY)
    echo &"  skipTextMatches={skipOk}"
    for i in 0 ..< LobbySize:
      let slot = bot.parseVoteSlot(LobbySize, i)
      echo &"    slot[{i}]: colorIndex={slot.colorIndex} alive={slot.alive}"
    return 1

  # Frame 3: third frame.
  let packed3 = bot.sim.buildVoteFrame(3)
  let mask3 = bot.stepPackedFrame(packed3)
  let active3 = bot.voting.active
  let branch3 = bot.diag.branchId
  echo &"[multi_frame] frame 3: active={active3} branch={branch3} " &
       &"mask={mask3} cursor={bot.voting.cursor}"
  if not active3:
    echo "[multi_frame] FAIL: frame 3 lost voting state"
    return 1

  echo "[multi_frame] OK"
  0

# ---------------------------------------------------------------------------
# Test 8 — transition from Playing to Voting (realistic game flow)
# ---------------------------------------------------------------------------

proc testPlayingToVoting(): int =
  ## Simulates a realistic game: several Playing-phase frames, then
  ## the server calls startVote and sends Voting-phase frames. Tests
  ## that the transition doesn't confuse parseVotingScreen.
  var bot = buildTestBot()
  # Start the game so we get Playing-phase frames.
  bot.sim.startGame()
  # Run a few Playing-phase frames.
  for frame in 0 ..< 10:
    let packed = bot.sim.render(3)
    discard bot.stepPackedFrame(packed)
    bot.sim.step(@[], @[])
  echo &"[playing_to_voting] after 10 playing frames: " &
       &"interstitial={bot.percep.interstitial} localized={bot.percep.localized}"

  # Now start the vote.
  bot.sim.startVote()

  # First voting frame.
  let packed1 = bot.sim.buildVoteFrame(3)
  let mask1 = bot.stepPackedFrame(packed1)
  let active1 = bot.voting.active
  let branch1 = bot.diag.branchId
  echo &"[playing_to_voting] vote frame 1: active={active1} branch={branch1}"
  if not active1:
    echo "[playing_to_voting] FAIL: first vote frame did not activate voting"
    return 1

  # Second voting frame (after cursor moves).
  bot.sim.moveCursor(3, -1)
  let packed2 = bot.sim.buildVoteFrame(3)
  let mask2 = bot.stepPackedFrame(packed2)
  let active2 = bot.voting.active
  let branch2 = bot.diag.branchId
  echo &"[playing_to_voting] vote frame 2: active={active2} branch={branch2}"
  if not active2:
    echo "[playing_to_voting] FAIL: second vote frame lost voting"
    return 1

  echo "[playing_to_voting] OK"
  0

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc main() =
  var fails = 0
  fails += testBasicParse()
  fails += testWithCursor()
  fails += testSecondFrame()
  fails += testWithChat()
  fails += testWithVotes()
  fails += testPackUnpack()
  fails += testMultiFramePipeline()
  fails += testPlayingToVoting()
  if fails == 0:
    echo "parse_voting_screen_unit: OK (8 tests passed)"
  else:
    echo &"parse_voting_screen_unit: FAIL ({fails} failures)"
    quit(1)

when isMainModule:
  main()

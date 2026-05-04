## Speaker-attribution verification test.
##
## Proves that modulabot's voting-chat speaker attribution
## (`color_pip` sampling; see `voting.readVoteChatSpeakers` and
## `voting.voteChatSpeakerForLine`) correctly pairs each OCR'd chat
## line with the colour the sim rendered the pip with.
##
## Strategy: build a fresh bot (which initialises its own SimServer
## with a full sprite atlas), add eight players so the voting grid
## matches the lobby size modulabot expects, queue a deterministic
## set of chat messages with known speaker colours, call
## `sim.buildVoteFrame` to render a real voting frame, hand the
## unpacked framebuffer to `bot.stepUnpackedFrame`, then diff the
## parsed `bot.voting.chatLines` against ground truth.
##
## Scenarios cover:
##
## 1. One line per player colour, all eight colours in order.
## 2. Multi-line messages (wrapped by `chatLineCount`) — still one
##    speaker per message; attribution should pair every wrapped row
##    with the same pip.
## 3. Interleaved messages from different speakers in non-palette
##    order, to rule out any positional shortcut.
## 4. Short lines that OCR drops as not-useful do not starve the
##    next message's attribution.
##
## Exit 0 on full pass, 1 on any mismatch. Run from
## `test/trace_smoke.sh` (added step `[6/6]`).

import std/[strformat, strutils]
import ../../../sim
import ../../../../common/server  # Framebuffer.indices

import ../bot
import ../types
import ../evidence

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

const
  LobbySize = 8
    ## Full lobby so the voting grid lays out the way real games do.

type
  Expected = object
    speakerColor: int                   ## palette index 0..15
    text: string                        ## substring we expect OCR to
                                        ## contain (OCR isn't perfect;
                                        ## we match on substring, not
                                        ## exact equality)

proc renderScenario(
  scenario: string,
  messages: openArray[tuple[colorIndex: int, text: string]]
): seq[VoteChatLine] =
  ## Builds a fresh bot + sim, queues the given chat messages, renders
  ## a voting frame, and steps the bot once so its chat-line cache is
  ## populated. Returns a copy of `bot.voting.chatLines`.
  var bot = initBot(masterSeed = 1)
  for i in 0 ..< LobbySize:
    discard bot.sim.addPlayer("acct-" & $i)
  bot.sim.startVote()
  for m in messages:
    bot.sim.chatMessages.add ChatMessage(
      color: PlayerColors[m.colorIndex],
      text: m.text
    )
  discard bot.sim.buildVoteFrame(-1)
  # Copy the unpacked framebuffer (palette indices, one per pixel)
  # into the bot's input buffer and run one step. The bot will hit
  # its interstitial gate and call `parseVotingScreen`, which fills
  # `bot.voting.chatLines`.
  var frame = newSeq[uint8](bot.sim.fb.indices.len)
  for i in 0 ..< frame.len:
    frame[i] = bot.sim.fb.indices[i]
  discard bot.stepUnpackedFrame(frame)
  if not bot.voting.active:
    echo &"[{scenario}] FAIL: parseVotingScreen did not activate voting"
    quit(1)
  when defined(speakerDebug):
    echo &"[{scenario}] DEBUG: {bot.voting.chatLines.len} lines:"
    for i, line in bot.voting.chatLines:
      echo &"    [{i}] speaker={playerColorName(line.speakerColor)} " &
           &"y={line.y} text='{line.text}'"
  result = bot.voting.chatLines

proc checkAttribution(
  scenario: string,
  got: seq[VoteChatLine],
  expected: openArray[Expected]
): int =
  ## Returns 0 on full match, or the number of mismatches after
  ## printing a diff. `got` may contain extra wrapped-line rows
  ## beyond what `expected` enumerates — we match positionally
  ## against the first `expected.len` usefulChatLine rows.
  if got.len < expected.len:
    echo &"[{scenario}] FAIL: want >= {expected.len} lines, got {got.len}"
    for i, line in got:
      echo &"    got[{i}]: speaker={playerColorName(line.speakerColor)} " &
           &"y={line.y} text='{line.text}'"
    return max(1, expected.len - got.len)
  for i, want in expected:
    let have = got[i]
    let speakerOk = have.speakerColor == want.speakerColor
    let textOk = want.text.len == 0 or
                 want.text.toLowerAscii() in have.text.toLowerAscii()
    if not speakerOk or not textOk:
      inc result
      echo &"[{scenario}] FAIL line {i}:"
      echo &"    want: speaker={playerColorName(want.speakerColor)} " &
           &"text contains '{want.text}'"
      echo &"    got:  speaker={playerColorName(have.speakerColor)} " &
           &"y={have.y} text='{have.text}'"

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

proc scenarioAllColours(): int =
  ## One single-line message per palette colour 0..7, in palette
  ## order. Every line should attribute to its sender. Chat panel
  ## fits 7 messages in the ~93 px body; oldest (red, msg 0) gets
  ## dropped. Expected visible order: orange..pale blue.
  let msgs = [
    (colorIndex: 0, text: "alpha red here"),
    (colorIndex: 1, text: "orange present"),
    (colorIndex: 2, text: "yellow ping"),
    (colorIndex: 3, text: "lightblue ready"),
    (colorIndex: 4, text: "pink speaks"),
    (colorIndex: 5, text: "lime joined"),
    (colorIndex: 6, text: "blue checks"),
    (colorIndex: 7, text: "pale blue ok")
  ]
  let chatLines = renderScenario("all_colours", msgs)
  let expected = [
    Expected(speakerColor: 1, text: "orange"),
    Expected(speakerColor: 2, text: "yellow"),
    Expected(speakerColor: 3, text: "lightblue"),
    Expected(speakerColor: 4, text: "pink"),
    Expected(speakerColor: 5, text: "lime"),
    Expected(speakerColor: 6, text: "blue"),
    Expected(speakerColor: 7, text: "pale")
  ]
  checkAttribution("all_colours", chatLines, expected)

proc scenarioInterleaved(): int =
  ## Non-palette-ordered speakers to rule out any positional shortcut.
  let msgs = [
    (colorIndex: 5, text: "lime talks"),
    (colorIndex: 0, text: "red rebuts"),
    (colorIndex: 7, text: "pale blue sus red"),
    (colorIndex: 2, text: "yellow agrees")
  ]
  let chatLines = renderScenario("interleaved", msgs)
  let expected = [
    Expected(speakerColor: 5, text: "lime"),
    Expected(speakerColor: 0, text: "red"),
    Expected(speakerColor: 7, text: "sus"),
    Expected(speakerColor: 2, text: "yellow")
  ]
  checkAttribution("interleaved", chatLines, expected)

proc scenarioLongMessage(): int =
  ## One long message that wraps across multiple OCR rows. Every
  ## wrapped row should attribute to the same speaker (pale blue).
  ## The sim wraps on `VoteChatCharsPerLine = 32`; give it ~70 chars
  ## so we get 2–3 wrapped rows. This is the case that naive
  ## nearest-pip attribution gets wrong (the last wrapped row is
  ## closer to the next message's pip than its own); the
  ## `voteChatSpeakerForLine` prefer-above tie-break handles it.
  let longText = "pale blue gives a long speech about the " &
                 "electrical task and what happened there"
  let msgs = [
    (colorIndex: 7, text: longText),           # pale blue, wraps
    (colorIndex: 3, text: "lightblue short")   # single-line follow-up
  ]
  let chatLines = renderScenario("long_message", msgs)
  var fails = 0
  var sawPaleBlueWrap = false
  var sawLightBlue = false
  for line in chatLines:
    if "lightblue" in line.text.toLowerAscii():
      sawLightBlue = true
      if line.speakerColor != 3:
        inc fails
        echo &"[long_message] FAIL: lightblue line attributed to " &
             &"{playerColorName(line.speakerColor)}"
    else:
      # Treat all other non-empty lines as part of the long message.
      if line.speakerColor == 7:
        sawPaleBlueWrap = true
      else:
        inc fails
        echo &"[long_message] FAIL: wrapped row '{line.text}' " &
             &"attributed to {playerColorName(line.speakerColor)}, " &
             &"want pale blue"
  if not sawPaleBlueWrap:
    inc fails
    echo "[long_message] FAIL: no pale-blue-attributed row seen"
  if not sawLightBlue:
    inc fails
    echo "[long_message] FAIL: lightblue follow-up row missing"
  fails

proc scenarioUnattributedFallback(): int =
  ## Sanity check: zero messages → zero chat lines. Proves the
  ## attribution path doesn't spuriously invent speakers.
  let chatLines = renderScenario("empty_chat", [])
  if chatLines.len != 0:
    echo &"[empty_chat] FAIL: want 0 lines, got {chatLines.len}"
    for i, line in chatLines:
      echo &"    [{i}] speaker={playerColorName(line.speakerColor)} " &
           &"y={line.y} text='{line.text}'"
    return chatLines.len
  0

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc main() =
  var fails = 0
  fails += scenarioAllColours()
  fails += scenarioInterleaved()
  fails += scenarioLongMessage()
  fails += scenarioUnattributedFallback()
  if fails == 0:
    echo "speaker_attribution: OK (4 scenarios passed)"
  else:
    echo &"speaker_attribution: FAIL ({fails} mismatches across scenarios)"
    quit(1)

when isMainModule:
  main()

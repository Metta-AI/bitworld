## Voting-screen perception and decision.
##
## Phase 1 port from v2:1781-2067 (parser) and v2:3072-3227 (cursor /
## decision). The clearing helper (`clearVotingState`) lives here too.
##
## The crewmate vs. imposter decision asymmetry is the policy core:
## crewmates ignore chat and only accuse on firsthand evidence;
## imposters bandwagon on chat-named sus colours to blend in. Both
## paths are visible inside `desiredVotingTarget`.

import std/strutils

import protocol
import ../../sim
import ../../../common/server

import types
import sprite_match
import actors  # BodyMaxMisses, BodyMinStablePixels, BodyMinTintPixels
import ascii
import diag
import evidence

const
  VoteCellW* = 16
  VoteCellH* = 17
  VoteStartY* = 2
  VoteSkipW* = 28
  VoteBlackMarker* = 12'u8
  VoteListenTicks* = 100
    ## Frames to wait after the cursor lands on the target before
    ## pressing A. Lets chat fully load and absorb late "sus X" calls.
  VoteChatTextX* = 21
  VoteChatChars* = 15

# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------

proc clearVotingState*(bot: var Bot) =
  ## Resets the voting sub-record to its sentinel-initialized form.
  bot.voting.active = false
  bot.voting.playerCount = 0
  bot.voting.cursor = VoteUnknown
  bot.voting.selfSlot = VoteUnknown
  bot.voting.target = VoteUnknown
  bot.voting.startTick = -1
  bot.voting.chatSusColor = VoteUnknown
  bot.voting.chatText = ""
  bot.voting.chatLines.setLen(0)
  for i in 0 ..< bot.voting.slots.len:
    bot.voting.slots[i].colorIndex = VoteUnknown
    bot.voting.slots[i].alive = false
  for i in 0 ..< bot.voting.choices.len:
    bot.voting.choices[i] = VoteUnknown

# ---------------------------------------------------------------------------
# Grid layout
# ---------------------------------------------------------------------------

proc voteGridLayout*(count: int): tuple[cols, rows, startX,
                                        skipX, skipY: int] =
  ## Fixed voting grid geometry for one player count. Verbatim from
  ## v2:1781-1790.
  result.cols = min(count, 8)
  result.rows = (count + result.cols - 1) div result.cols
  let totalW = result.cols * VoteCellW
  result.startX = (ScreenWidth - totalW) div 2
  result.skipX = (ScreenWidth - VoteSkipW) div 2
  result.skipY = VoteStartY + result.rows * VoteCellH + 1

proc voteCellOrigin*(count, index: int): tuple[x, y: int] =
  let layout = voteGridLayout(count)
  (
    layout.startX + (index mod layout.cols) * VoteCellW,
    VoteStartY + (index div layout.cols) * VoteCellH
  )

# ---------------------------------------------------------------------------
# Slot / cursor parsing
# ---------------------------------------------------------------------------

proc voteSkipTextMatches*(bot: Bot, skipX, skipY: int): bool =
  ## True when the SKIP label is visible at the expected position.
  for y in max(0, skipY - 1) .. min(ScreenHeight - 6, skipY + 1):
    let
      minX = max(0, skipX - 2)
      maxX = min(ScreenWidth - asciiTextWidth("SKIP"), skipX + 2)
    for x in minX .. maxX:
      if bot.asciiTextMatches("SKIP", x, y):
        return true
  false

proc parseVoteSlot*(bot: Bot, count, index: int): VoteSlot =
  ## Parses one voting grid slot — colour and alive/dead.
  result.colorIndex = VoteUnknown
  let
    cell = voteCellOrigin(count, index)
    spriteX = cell.x + (VoteCellW - bot.sprites.player.width) div 2
    spriteY = cell.y + 1
  if matchesCrewmate(bot.io.unpacked, bot.sprites.player,
                     spriteX, spriteY, false):
    result.colorIndex = crewmateColorIndex(bot.io.unpacked, bot.sprites.player,
                                           spriteX, spriteY, false)
    result.alive = true
  elif matchesActorSprite(bot.io.unpacked, bot.sprites.body,
                          spriteX, spriteY, false,
                          BodyMaxMisses, BodyMinStablePixels,
                          BodyMinTintPixels):
    result.colorIndex = actorColorIndex(bot.io.unpacked, bot.sprites.body,
                                        spriteX, spriteY, false)
    result.alive = false

proc voteCellSelected*(bot: Bot, count, index: int): bool =
  ## True when the cursor outline (palette index 2) brackets one
  ## player cell.
  let cell = voteCellOrigin(count, index)
  var hits = 0
  for bx in 0 ..< VoteCellW:
    if bot.io.unpacked[(cell.y - 1) * ScreenWidth + cell.x + bx] == 2'u8:
      inc hits
    if bot.io.unpacked[(cell.y + VoteCellH - 2) * ScreenWidth + cell.x + bx] ==
        2'u8:
      inc hits
  hits >= VoteCellW

proc voteSkipSelected*(bot: Bot, skipX, skipY: int): bool =
  ## True when the cursor outlines the SKIP option.
  var hits = 0
  for bx in 0 ..< VoteSkipW:
    if bot.io.unpacked[(skipY - 1) * ScreenWidth + skipX + bx] == 2'u8:
      inc hits
    if bot.io.unpacked[(skipY + 6) * ScreenWidth + skipX + bx] == 2'u8:
      inc hits
  hits >= VoteSkipW

proc voteSelfMarkerPresent*(bot: Bot, count, index: int,
                          colorIndex: int): bool =
  ## True when the local-player marker sits above one slot.
  if colorIndex < 0 or colorIndex >= PlayerColors.len:
    return false
  let
    cell = voteCellOrigin(count, index)
    markerX = cell.x + VoteCellW div 2 - 1
    markerY = cell.y - 2
    a = bot.io.unpacked[markerY * ScreenWidth + markerX]
    b = bot.io.unpacked[markerY * ScreenWidth + markerX + 1]
    color = PlayerColors[colorIndex]
  if color == SpaceColor:
    a == 2'u8 and b == VoteBlackMarker
  else:
    a == color and b == color

# ---------------------------------------------------------------------------
# Vote-dot row parsing (other players' votes)
# ---------------------------------------------------------------------------

proc voteDotColorIndex*(bot: Bot, x, y: int): int =
  if x < 0 or y < 0 or x >= ScreenWidth or y >= ScreenHeight:
    return VoteUnknown
  let color = bot.io.unpacked[y * ScreenWidth + x]
  if color == 2'u8 and x > 0 and
      bot.io.unpacked[y * ScreenWidth + x - 1] == VoteBlackMarker:
    return playerColorIndex(SpaceColor)
  if color == SpaceColor:
    return VoteUnknown
  playerColorIndex(color)

proc parseVoteDotsForTarget*(bot: var Bot, target,
                            dotX, dotY: int) =
  ## Parses the compact voter dots for one voting target into
  ## `bot.voting.choices`.
  for row in 0 ..< MaxPlayers:
    let colorIndex = bot.voteDotColorIndex(
      dotX + (row mod 8) * 2,
      dotY + (row div 8)
    )
    if colorIndex >= 0 and colorIndex < bot.voting.choices.len:
      bot.voting.choices[colorIndex] = target

# ---------------------------------------------------------------------------
# Chat text OCR
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Chat text OCR
# ---------------------------------------------------------------------------
#
# `readAsciiRun` now lives in `ascii.nim` and uses variable-width
# glyph advance (the server's PixelFont is not a fixed-7px sprite
# font — see ascii.nim header for context). The duplicate that used
# to live here was silently misaligned and read voting-screen chat as
# garbage like `".'',...........,.."`, which kept `chatSusColorIndex`
# empty and prevented the bot from ever recognising the SKIP label on
# the voting screen. Downstream of this fix, `parseVotingScreen` can
# actually parse meetings for the first time in the bitworld_runner /
# CLI paths.

proc usefulChatLine*(line: string): bool =
  ## True when a parsed line contains real letters (not just `?`s).
  var
    letters = 0
    unknown = 0
  for ch in line:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'}:
      inc letters
    elif ch == '?':
      inc unknown
  letters >= 2 and unknown * 2 <= max(1, line.len)

iterator visibleChatLines*(bot: Bot, count: int): string =
  ## Yields each chat line currently rendered on the voting screen, in
  ## row order, with sequential duplicates collapsed and useless lines
  ## (no letters, mostly `?` glyphs) skipped. The trace writer
  ## consumes this directly to detect newly-observed lines without a
  ## second OCR pass; `readVoteChatText` is now a thin wrapper that
  ## concatenates the same yields.
  let
    layout = voteGridLayout(count)
    chatY = layout.skipY + 10
  var previous = ""
  for y in chatY + 2 ..< ScreenHeight - 6:
    let line = bot.readAsciiRun(VoteChatTextX, y, VoteChatChars)
    if not line.usefulChatLine():
      continue
    if line == previous:
      continue
    yield line
    previous = line

proc readVoteChatText*(bot: Bot, count: int): string =
  ## Concatenated OCR of the voting chat region. Used by
  ## `chatSusColorIndex` for sus-target detection. Refactored in
  ## Phase 2 to share `visibleChatLines` with the trace writer.
  for line in bot.visibleChatLines(count):
    if result.len > 0:
      result.add(' ')
    result.add(line)

proc normalizeChatText*(text: string): string =
  ## Lowercase + collapse non-alphanumerics into single spaces.
  var hadSpace = true
  for ch in text:
    var outCh = ch
    if ch in {'A' .. 'Z'}:
      outCh = char(ord(ch) - ord('A') + ord('a'))
    if outCh in {'a' .. 'z'} or outCh in {'0' .. '9'}:
      result.add(outCh)
      hadSpace = false
    elif not hadSpace:
      result.add(' ')
      hadSpace = true
  result = result.strip()

proc spanGap*(aStart, aEnd, bStart, bEnd: int): int =
  if aEnd <= bStart:
    bStart - aEnd
  elif bEnd <= aStart:
    aStart - bEnd
  else:
    0

proc chatSusColorIndex*(text: string): int =
  ## Returns the player colour mentioned with "sus" in chat, or
  ## VoteUnknown.
  let
    padded = " " & text.normalizeChatText() & " "
    susNeedle = " sus "
  result = VoteUnknown
  var
    bestSus = -1
    bestGap = high(int)
    bestLen = -1
  for i, name in PlayerColorNames:
    let colorNeedle = " " & name.normalizeChatText() & " "
    var colorPos = padded.find(colorNeedle)
    while colorPos >= 0:
      let
        colorStart = colorPos + 1
        colorEnd = colorPos + colorNeedle.len - 1
        colorLen = colorEnd - colorStart
      var susPos = padded.find(susNeedle)
      while susPos >= 0:
        let
          susStart = susPos + 1
          susEnd = susPos + susNeedle.len - 1
          gap = spanGap(colorStart, colorEnd, susStart, susEnd)
        if gap <= VoteChatChars * 2 and (
            susStart > bestSus or
            (susStart == bestSus and gap < bestGap) or
            (susStart == bestSus and gap == bestGap and
              colorLen > bestLen)):
          bestSus = susStart
          bestGap = gap
          bestLen = colorLen
          result = i
        susPos = padded.find(susNeedle, susPos + 1)
      colorPos = padded.find(colorNeedle, colorPos + 1)

# ---------------------------------------------------------------------------
# Top-level parser
# ---------------------------------------------------------------------------

proc parseVotingCandidate*(bot: var Bot, count, startTick: int): bool =
  ## Tries to parse the voting screen for a specific player count.
  ## Returns false unless every slot resolves to a colour matching
  ## its index — that's the strict invariant that makes "no, this
  ## isn't the voting screen" the only failure mode.
  let layout = voteGridLayout(count)
  if not bot.voteSkipTextMatches(layout.skipX, layout.skipY):
    return false
  var slots: array[MaxPlayers, VoteSlot]
  for i in 0 ..< count:
    slots[i] = bot.parseVoteSlot(count, i)
    if slots[i].colorIndex == VoteUnknown:
      return false
    if slots[i].colorIndex != i:
      return false

  bot.clearVotingState()
  bot.voting.active = true
  bot.voting.playerCount = count
  bot.voting.startTick = startTick
  bot.voting.cursor = VoteUnknown
  bot.voting.selfSlot = VoteUnknown
  for i in 0 ..< count:
    bot.voting.slots[i] = slots[i]
    if slots[i].alive and bot.voteCellSelected(count, i):
      bot.voting.cursor = i
    if bot.voteSelfMarkerPresent(count, i, slots[i].colorIndex):
      bot.voting.selfSlot = i
      bot.identity.selfColor = slots[i].colorIndex
    let cell = voteCellOrigin(count, i)
    bot.parseVoteDotsForTarget(
      i,
      cell.x + 1,
      cell.y + bot.sprites.player.height + 2
    )
  if bot.voteSkipSelected(layout.skipX, layout.skipY):
    bot.voting.cursor = count
  bot.parseVoteDotsForTarget(
    VoteSkip,
    layout.skipX + VoteSkipW + 2,
    layout.skipY
  )
  # Cache per-line OCR for the trace writer (chat_observed events).
  bot.voting.chatLines.setLen(0)
  for line in bot.visibleChatLines(count):
    bot.voting.chatLines.add(line)
  # Rebuild the concatenated text used by chatSusColorIndex.
  bot.voting.chatText.setLen(0)
  for line in bot.voting.chatLines:
    if bot.voting.chatText.len > 0:
      bot.voting.chatText.add(' ')
    bot.voting.chatText.add(line)
  bot.voting.chatSusColor = chatSusColorIndex(bot.voting.chatText)
  true

proc parseVotingScreen*(bot: var Bot): bool =
  ## Parses the voting interstitial if it is currently visible.
  ## Walks player counts top-down to prefer the largest plausible
  ## interpretation when multiple counts validate.
  let startTick =
    if bot.voting.active and bot.voting.startTick >= 0:
      bot.voting.startTick
    else:
      bot.frameTick
  for count in countdown(MaxPlayers, 1):
    if bot.parseVotingCandidate(count, startTick):
      return true
  bot.clearVotingState()
  false

# ---------------------------------------------------------------------------
# Decision: target selection
# ---------------------------------------------------------------------------

proc voteSlotForColor*(bot: Bot, colorIndex: int): int =
  for i in 0 ..< bot.voting.playerCount:
    if bot.voting.slots[i].colorIndex == colorIndex:
      return i
  VoteUnknown

proc voteTargetName*(bot: Bot, target: int): string =
  if target == VoteSkip:
    return "skip"
  if target >= 0 and target < bot.voting.playerCount:
    return playerColorName(bot.voting.slots[target].colorIndex)
  "unknown"

proc voteSummary*(bot: Bot): string =
  for i, choice in bot.voting.choices:
    if choice == VoteUnknown:
      continue
    if result.len > 0:
      result.add(", ")
    result.add(playerColorName(i))
    result.add("->")
    result.add(bot.voteTargetName(choice))
  if result.len == 0:
    result = "none"

proc selfVoteChoice*(bot: Bot): int =
  ## Returns the parsed vote choice for the local player, or
  ## VoteUnknown if not yet voted.
  if bot.identity.selfColor >= 0 and
      bot.identity.selfColor < bot.voting.choices.len:
    return bot.voting.choices[bot.identity.selfColor]
  if bot.voting.selfSlot >= 0 and
      bot.voting.selfSlot < bot.voting.playerCount:
    let colorIndex = bot.voting.slots[bot.voting.selfSlot].colorIndex
    if colorIndex >= 0 and colorIndex < bot.voting.choices.len:
      return bot.voting.choices[colorIndex]
  VoteUnknown

# ---------------------------------------------------------------------------
# Cursor stepping
# ---------------------------------------------------------------------------

proc nextVoteSelectable*(bot: Bot, cursor, direction: int): int =
  let total = bot.voting.playerCount + 1
  if total <= 0:
    return VoteUnknown
  var cur = cursor
  for step in 1 .. total:
    cur = (cur + direction + total) mod total
    if cur == bot.voting.playerCount:
      return cur
    if cur >= 0 and cur < bot.voting.playerCount and
        bot.voting.slots[cur].alive:
      return cur
  VoteUnknown

proc voteStepsTo*(bot: Bot, target, direction: int): int =
  if bot.voting.cursor == VoteUnknown:
    return high(int)
  var cur = bot.voting.cursor
  for step in 0 .. bot.voting.playerCount + 1:
    if cur == target:
      return step
    cur = bot.nextVoteSelectable(cur, direction)
    if cur == VoteUnknown:
      return high(int)
  high(int)

proc voteMoveDirection*(bot: Bot, target: int): int =
  let
    leftSteps = bot.voteStepsTo(target, -1)
    rightSteps = bot.voteStepsTo(target, 1)
  if leftSteps < rightSteps:
    -1
  else:
    1

# ---------------------------------------------------------------------------
# Decision: target picking
# ---------------------------------------------------------------------------

proc desiredVotingTarget*(bot: Bot): int =
  ## Chooses the voting target. The crewmate-vs-imposter asymmetry
  ## that gives this bot family its name lives here.
  ##
  ## IMPOSTER — bandwagon onto chat-named sus first, then most-recent
  ## suspect, then skip. Blends in with herd voting.
  ##
  ## CREWMATE — ignore chat entirely. Vote only with firsthand
  ## evidence (`evidenceBasedSuspect`); skip otherwise. Immune to
  ## manipulation by chat-first imposters.
  ##
  ## LLM override (compile-time gated by `-d:modTalksLlm`): if the
  ## LLM state machine has decided on a target (`llmVoting.voteTarget
  ## >= 0`), that wins over both rule-based paths. This is how the
  ## crewmate uses full memory context and the imposter uses the
  ## Stage-1 strategy to pick a target. See `llm.nim` + LLM_VOTING.md.
  when defined(modTalksLlm):
    if bot.llmVoting.enabled and bot.llmVoting.voteTarget >= 0:
      let slot = bot.voteSlotForColor(bot.llmVoting.voteTarget)
      if slot >= 0 and slot != bot.voting.selfSlot and
          bot.voting.slots[slot].alive:
        return slot
  if bot.role == RoleImposter:
    if bot.voting.chatSusColor >= 0:
      let slot = bot.voteSlotForColor(bot.voting.chatSusColor)
      if slot >= 0 and slot != bot.voting.selfSlot and
          bot.voting.slots[slot].alive:
        return slot
    let suspect = bot.suspectedColor()
    if suspect.found:
      let slot = bot.voteSlotForColor(suspect.colorIndex)
      if slot >= 0 and slot != bot.voting.selfSlot and
          bot.voting.slots[slot].alive:
        return slot
    return bot.voting.playerCount

  # Crewmate: evidence-only.
  let suspect = bot.evidenceBasedSuspect()
  if suspect.found:
    let slot = bot.voteSlotForColor(suspect.colorIndex)
    if slot >= 0 and slot != bot.voting.selfSlot and
        bot.voting.slots[slot].alive:
      return slot
  bot.voting.playerCount

# ---------------------------------------------------------------------------
# Decision: per-frame mask
# ---------------------------------------------------------------------------

proc decideVotingMask*(bot: var Bot): uint8 =
  ## Chooses voting-screen input from parsed vote state.
  bot.goal.has = false
  bot.goal.hasPathStep = false
  bot.goal.path.setLen(0)
  bot.voting.target = bot.desiredVotingTarget()
  let ownVote = bot.selfVoteChoice()
  if ownVote != VoteUnknown:
    bot.motion.desiredMask = 0
    bot.motion.controllerMask = 0
    bot.fired("voting.idle.already_voted",
      "voted " & bot.voteTargetName(ownVote))
    bot.thought(bot.diag.intent)
    return 0
  if bot.voting.cursor != bot.voting.target:
    let direction = bot.voteMoveDirection(bot.voting.target)
    let mask =
      if direction < 0:
        ButtonLeft
      else:
        ButtonRight
    bot.motion.desiredMask =
      if bot.io.lastMask == mask:
        0
      else:
        mask
    bot.motion.controllerMask = bot.motion.desiredMask
    bot.fired("voting.cursor.move",
      "voting cursor to " & bot.voteTargetName(bot.voting.target))
    bot.thought(bot.diag.intent)
    return bot.motion.desiredMask
  let listenedTicks =
    if bot.voting.startTick >= 0:
      bot.frameTick - bot.voting.startTick
    else:
      0
  if listenedTicks < VoteListenTicks:
    bot.motion.desiredMask = 0
    bot.motion.controllerMask = 0
    bot.fired("voting.cursor.listen",
      "ready, listening in vote chat " &
        $listenedTicks & "/" & $VoteListenTicks)
    bot.thought(bot.diag.intent)
    return 0
  bot.motion.desiredMask =
    if bot.io.lastMask == ButtonA:
      0
    else:
      ButtonA
  bot.motion.controllerMask = bot.motion.desiredMask
  bot.fired("voting.press_a",
    "voting for " & bot.voteTargetName(bot.voting.target))
  bot.thought(bot.diag.intent)
  bot.motion.desiredMask

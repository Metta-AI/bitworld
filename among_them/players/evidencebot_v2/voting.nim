proc voteGridLayout(
  count: int
): tuple[cols: int, rows: int, startX: int, skipX: int, skipY: int] =
  ## Returns the fixed voting grid geometry for a player count.
  result.cols = min(count, 8)
  result.rows = (count + result.cols - 1) div result.cols
  let totalW = result.cols * VoteCellW
  result.startX = (ScreenWidth - totalW) div 2
  result.skipX = (ScreenWidth - VoteSkipW) div 2
  result.skipY = VoteStartY + result.rows * VoteCellH + 1

proc voteCellOrigin(
  count,
  index: int
): tuple[x: int, y: int] =
  ## Returns the top-left voting cell origin for a player slot.
  let layout = voteGridLayout(count)
  (
    layout.startX + (index mod layout.cols) * VoteCellW,
    VoteStartY + (index div layout.cols) * VoteCellH
  )

proc voteSkipTextMatches(bot: Bot, skipX, skipY: int): bool =
  ## Returns true when the voting skip label is visible.
  for y in max(0, skipY - 1) .. min(ScreenHeight - 6, skipY + 1):
    let
      minX = max(0, skipX - 2)
      maxX = min(ScreenWidth - asciiTextWidth("SKIP"), skipX + 2)
    for x in minX .. maxX:
      if bot.asciiTextMatches("SKIP", x, y):
        return true

proc parseVoteSlot(
  bot: Bot,
  count,
  index: int
): VoteSlot =
  ## Parses one voting grid slot.
  result.colorIndex = VoteUnknown
  let
    cell = voteCellOrigin(count, index)
    spriteX = cell.x + (VoteCellW - bot.playerSprite.width) div 2
    spriteY = cell.y + 1
  if bot.matchesCrewmate(spriteX, spriteY, false):
    result.colorIndex = bot.crewmateColorIndex(spriteX, spriteY, false)
    result.alive = true
  elif bot.matchesActorSprite(
    bot.bodySprite,
    spriteX,
    spriteY,
    false,
    BodyMaxMisses,
    BodyMinStablePixels,
    BodyMinTintPixels
  ):
    result.colorIndex = bot.actorColorIndex(
      bot.bodySprite,
      spriteX,
      spriteY,
      false
    )
    result.alive = false

proc voteCellSelected(bot: Bot, count, index: int): bool =
  ## Returns true when the local cursor outlines one player cell.
  let cell = voteCellOrigin(count, index)
  var hits = 0
  for bx in 0 ..< VoteCellW:
    if bot.unpacked[(cell.y - 1) * ScreenWidth + cell.x + bx] == 2'u8:
      inc hits
    if bot.unpacked[(cell.y + VoteCellH - 2) * ScreenWidth + cell.x + bx] ==
        2'u8:
      inc hits
  hits >= VoteCellW

proc voteSkipSelected(bot: Bot, skipX, skipY: int): bool =
  ## Returns true when the local cursor outlines the skip option.
  var hits = 0
  for bx in 0 ..< VoteSkipW:
    if bot.unpacked[(skipY - 1) * ScreenWidth + skipX + bx] == 2'u8:
      inc hits
    if bot.unpacked[(skipY + 6) * ScreenWidth + skipX + bx] == 2'u8:
      inc hits
  hits >= VoteSkipW

proc voteSelfMarkerPresent(
  bot: Bot,
  count,
  index: int,
  colorIndex: int
): bool =
  ## Returns true when a voting slot has the local-player marker.
  if colorIndex < 0 or colorIndex >= PlayerColors.len:
    return false
  let
    cell = voteCellOrigin(count, index)
    markerX = cell.x + VoteCellW div 2 - 1
    markerY = cell.y - 2
    a = bot.unpacked[markerY * ScreenWidth + markerX]
    b = bot.unpacked[markerY * ScreenWidth + markerX + 1]
    color = PlayerColors[colorIndex]
  if color == SpaceColor:
    a == 2'u8 and b == VoteBlackMarker
  else:
    a == color and b == color

proc voteDotColorIndex(bot: Bot, x, y: int): int =
  ## Returns the voter color index for one vote dot position.
  if x < 0 or y < 0 or x >= ScreenWidth or y >= ScreenHeight:
    return VoteUnknown
  let color = bot.unpacked[y * ScreenWidth + x]
  if color == 2'u8 and x > 0 and
      bot.unpacked[y * ScreenWidth + x - 1] == VoteBlackMarker:
    return playerColorIndex(SpaceColor)
  if color == SpaceColor:
    return VoteUnknown
  playerColorIndex(color)

proc parseVoteDotsForTarget(
  bot: var Bot,
  target,
  dotX,
  dotY: int
) =
  ## Parses the compact voter dots for one voting target.
  for row in 0 ..< MaxPlayers:
    let colorIndex = bot.voteDotColorIndex(
      dotX + (row mod 8) * 2,
      dotY + (row div 8)
    )
    if colorIndex >= 0 and colorIndex < bot.voteChoices.len:
      bot.voteChoices[colorIndex] = target

proc readAsciiRun(bot: Bot, x, y, count: int): string =
  ## Reads a fixed-width ASCII run from the current screen.
  for i in 0 ..< count:
    result.add(bot.bestAsciiGlyph(x + i * 7, y))
  result = result.strip()

proc usefulChatLine(line: string): bool =
  ## Returns true when a parsed chat line contains real letters.
  var
    letters = 0
    unknown = 0
  for ch in line:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'}:
      inc letters
    elif ch == '?':
      inc unknown
  letters >= 2 and unknown * 2 <= max(1, line.len)

proc readVoteChatText(bot: Bot, count: int): string =
  ## Reads visible voting chat text from the chat panel.
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
    if result.len > 0:
      result.add(' ')
    result.add(line)
    previous = line

proc normalizeChatText(text: string): string =
  ## Normalizes chat text for simple word matching.
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

proc spanGap(aStart, aEnd, bStart, bEnd: int): int =
  ## Returns the number of characters between two text spans.
  if aEnd <= bStart:
    bStart - aEnd
  elif bEnd <= aStart:
    aStart - bEnd
  else:
    0

proc chatSusColorIndex(text: string): int =
  ## Returns the player color that visible chat calls sus.
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

proc parseVotingCandidate(
  bot: var Bot,
  count,
  startTick: int
): bool =
  ## Parses the voting screen for one possible player count.
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
  bot.voting = true
  bot.votePlayerCount = count
  bot.voteStartTick = startTick
  bot.voteCursor = VoteUnknown
  bot.voteSelfSlot = VoteUnknown
  for i in 0 ..< count:
    bot.voteSlots[i] = slots[i]
    if slots[i].alive and bot.voteCellSelected(count, i):
      bot.voteCursor = i
    if bot.voteSelfMarkerPresent(count, i, slots[i].colorIndex):
      bot.voteSelfSlot = i
      bot.selfColorIndex = slots[i].colorIndex
    let cell = voteCellOrigin(count, i)
    bot.parseVoteDotsForTarget(
      i,
      cell.x + 1,
      cell.y + bot.playerSprite.height + 2
    )
  if bot.voteSkipSelected(layout.skipX, layout.skipY):
    bot.voteCursor = count
  bot.parseVoteDotsForTarget(
    VoteSkip,
    layout.skipX + VoteSkipW + 2,
    layout.skipY
  )
  bot.voteChatText = bot.readVoteChatText(count)
  bot.voteChatSusColor = chatSusColorIndex(bot.voteChatText)
  true

proc parseVotingScreen(bot: var Bot): bool =
  ## Parses the voting interstitial if it is currently visible.
  let startTick =
    if bot.voting and bot.voteStartTick >= 0:
      bot.voteStartTick
    else:
      bot.frameTick
  for count in countdown(MaxPlayers, 1):
    if bot.parseVotingCandidate(count, startTick):
      return true
  bot.clearVotingState()
  false


import
  std/strutils,
  protocol,
  sim,
  ../common/pixelfonts,
  ../common/server

const
  VoteReaderCellW* = 16
  VoteReaderCellH* = 17
  VoteReaderStartY* = 2
  VoteReaderSkipW* = 28
  VoteReaderUnknown* = -1
  VoteReaderSkip* = -2
  VoteReaderBlackMarker* = 12'u8
  VoteReaderColorCount* = PlayerColors.len
  BodyMaxMisses = 9
  BodyMinStablePixels = 6
  BodyMinTintPixels = 6
  CrewmateMaxMisses = 8
  CrewmateMinBodyPixels = 8
  CrewmateMinStablePixels = 8
  VoteReaderColorNames* = [
    "red",
    "orange",
    "yellow",
    "light blue",
    "pink",
    "lime",
    "blue",
    "pale blue",
    "gray",
    "white",
    "dark brown",
    "brown",
    "dark teal",
    "green",
    "dark navy",
    "black"
  ]

type
  VoteReaderSlot* = object
    colorIndex*: int
    alive*: bool

  VoteReaderChat* = object
    colorIndex*: int
    lines*: seq[string]
    text*: string

  VoteReaderFrame* = object
    found*: bool
    playerCount*: int
    cursor*: int
    selfSlot*: int
    slots*: array[MaxPlayers, VoteReaderSlot]
    choices*: array[VoteReaderColorCount, int]
    chat*: seq[VoteReaderChat]
    chatText*: string
    chatSusColor*: int

proc initVoteReaderFrame(): VoteReaderFrame =
  ## Returns a vote read initialized with unknown sentinel values.
  result.cursor = VoteReaderUnknown
  result.selfSlot = VoteReaderUnknown
  result.chatSusColor = VoteReaderUnknown
  for i in 0 ..< result.slots.len:
    result.slots[i].colorIndex = VoteReaderUnknown
    result.slots[i].alive = false
  for i in 0 ..< result.choices.len:
    result.choices[i] = VoteReaderUnknown

proc framePixel(frame: openArray[uint8], x, y: int): uint8 =
  ## Returns one framebuffer pixel or transparent outside the frame.
  if x < 0 or y < 0 or x >= ScreenWidth or y >= ScreenHeight:
    return TransparentColorIndex
  let index = y * ScreenWidth + x
  if index < 0 or index >= frame.len:
    return TransparentColorIndex
  frame[index]

proc stableCrewmateColor(color: uint8): bool =
  ## Returns true for crewmate pixels that do not use player tint.
  color != TransparentColorIndex and
    color != TintColor and
    color != ShadeTintColor

proc voteReaderPlayerColorIndex*(color: uint8): int =
  ## Returns the player color index for one palette color.
  for i, playerColor in PlayerColors:
    if color == playerColor:
      return i
  VoteReaderUnknown

proc playerBodyColor(color: uint8): bool =
  ## Returns true when a pixel can be part of a player body.
  for playerColor in PlayerColors:
    if color == playerColor:
      return true
    if color == ShadowMap[playerColor and 0x0f'u8]:
      return true
  false

proc crewmatePixelMatches(spriteColor, frameColor: uint8): bool =
  ## Returns true when one crewmate sprite pixel matches the frame.
  if spriteColor == TintColor or spriteColor == ShadeTintColor:
    return playerBodyColor(frameColor)
  frameColor == spriteColor

proc crewmateColorIndex(
  frame: openArray[uint8],
  sprite: Sprite,
  x,
  y: int,
  flipH: bool
): int =
  ## Returns the most likely color index for one crewmate sprite.
  var counts: array[VoteReaderColorCount, int]
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let srcX =
        if flipH:
          sprite.width - 1 - sx
        else:
          sx
      let color = sprite.pixels[sprite.spriteIndex(srcX, sy)]
      if color != TintColor:
        continue
      let index = voteReaderPlayerColorIndex(frame.framePixel(x + sx, y + sy))
      if index >= 0:
        inc counts[index]
  var bestCount = 0
  result = VoteReaderUnknown
  for i, count in counts:
    if count > bestCount:
      bestCount = count
      result = i

proc matchesCrewmate(
  frame: openArray[uint8],
  sprite: Sprite,
  x,
  y: int,
  flipH: bool
): bool =
  ## Returns true when a crewmate sprite matches at one screen point.
  var
    bodyMatched = 0
    bodyPixels = 0
    matchedStable = 0
    misses = 0
    stablePixels = 0
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let srcX =
        if flipH:
          sprite.width - 1 - sx
        else:
          sx
      let color = sprite.pixels[sprite.spriteIndex(srcX, sy)]
      if color == TransparentColorIndex:
        continue
      if color.stableCrewmateColor():
        inc stablePixels
      else:
        inc bodyPixels
      let frameColor = frame.framePixel(x + sx, y + sy)
      if frameColor != TransparentColorIndex and
          crewmatePixelMatches(color, frameColor):
        if color.stableCrewmateColor():
          inc matchedStable
        else:
          inc bodyMatched
      else:
        inc misses
      if misses > CrewmateMaxMisses:
        return false
  stablePixels >= CrewmateMinStablePixels and
    matchedStable >= CrewmateMinStablePixels and
    bodyPixels >= CrewmateMinBodyPixels and
    bodyMatched >= CrewmateMinBodyPixels

proc matchesActorSprite(
  frame: openArray[uint8],
  sprite: Sprite,
  x,
  y: int,
  flipH: bool,
  maxMisses,
  minStablePixels,
  minTintPixels: int
): bool =
  ## Returns true when a tinted body-like sprite matches the frame.
  var
    tintMatched = 0
    tintPixels = 0
    stableMatched = 0
    misses = 0
    stablePixels = 0
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let srcX =
        if flipH:
          sprite.width - 1 - sx
        else:
          sx
      let color = sprite.pixels[sprite.spriteIndex(srcX, sy)]
      if color == TransparentColorIndex:
        continue
      if color.stableCrewmateColor():
        inc stablePixels
      else:
        inc tintPixels
      let frameColor = frame.framePixel(x + sx, y + sy)
      if frameColor != TransparentColorIndex and
          crewmatePixelMatches(color, frameColor):
        if color.stableCrewmateColor():
          inc stableMatched
        else:
          inc tintMatched
      else:
        inc misses
      if misses > maxMisses:
        return false
  stablePixels >= minStablePixels and
    stableMatched >= minStablePixels and
    tintPixels >= minTintPixels and
    tintMatched >= minTintPixels

proc actorColorIndex(
  frame: openArray[uint8],
  sprite: Sprite,
  x,
  y: int,
  flipH: bool
): int =
  ## Returns the most likely color index for a tinted actor sprite.
  var counts: array[VoteReaderColorCount, int]
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let srcX =
        if flipH:
          sprite.width - 1 - sx
        else:
          sx
      let color = sprite.pixels[sprite.spriteIndex(srcX, sy)]
      if color != TintColor:
        continue
      let index = voteReaderPlayerColorIndex(frame.framePixel(x + sx, y + sy))
      if index >= 0:
        inc counts[index]
  var bestCount = 0
  result = VoteReaderUnknown
  for i, count in counts:
    if count > bestCount:
      bestCount = count
      result = i

proc voteReaderGridLayout*(
  count: int
): tuple[cols, rows, startX, skipX, skipY: int] =
  ## Returns the vote screen grid geometry for one player count.
  result.cols = min(count, 8)
  if result.cols <= 0:
    return
  result.rows = (count + result.cols - 1) div result.cols
  let totalW = result.cols * VoteReaderCellW
  result.startX = (ScreenWidth - totalW) div 2
  result.skipX = (ScreenWidth - VoteReaderSkipW) div 2
  result.skipY = VoteReaderStartY + result.rows * VoteReaderCellH + 1

proc voteReaderCellOrigin*(
  count,
  index: int
): tuple[x, y: int] =
  ## Returns the top-left voting cell origin for one player slot.
  let layout = voteReaderGridLayout(count)
  (
    layout.startX + (index mod layout.cols) * VoteReaderCellW,
    VoteReaderStartY + (index div layout.cols) * VoteReaderCellH
  )

proc skipTextMatches(
  frame: openArray[uint8],
  font: PixelFont,
  skipX,
  skipY: int
): bool =
  ## Returns true when the skip label is visible at the expected spot.
  let maxX = ScreenWidth - font.textWidth("SKIP")
  if maxX < 0:
    return false
  for y in max(0, skipY - 1) .. min(ScreenHeight - font.height, skipY + 1):
    for x in max(0, skipX - 2) .. min(maxX, skipX + 2):
      if frame.textMatches(font, "SKIP", x, y):
        return true

proc parseSlot(
  frame: openArray[uint8],
  playerSprite,
  bodySprite: Sprite,
  count,
  index: int
): VoteReaderSlot =
  ## Parses color and alive state for one voting grid slot.
  result.colorIndex = VoteReaderUnknown
  let
    cell = voteReaderCellOrigin(count, index)
    spriteX = cell.x + (VoteReaderCellW - playerSprite.width) div 2
    spriteY = cell.y + 1
  if frame.matchesCrewmate(playerSprite, spriteX, spriteY, false):
    result.colorIndex = frame.crewmateColorIndex(
      playerSprite,
      spriteX,
      spriteY,
      false
    )
    result.alive = true
  elif frame.matchesActorSprite(
    bodySprite,
    spriteX,
    spriteY,
    false,
    BodyMaxMisses,
    BodyMinStablePixels,
    BodyMinTintPixels
  ):
    result.colorIndex = frame.actorColorIndex(
      bodySprite,
      spriteX,
      spriteY,
      false
    )
    result.alive = false

proc cellSelected(frame: openArray[uint8], count, index: int): bool =
  ## Returns true when the local cursor outlines one player cell.
  let cell = voteReaderCellOrigin(count, index)
  var hits = 0
  for bx in 0 ..< VoteReaderCellW:
    if frame.framePixel(cell.x + bx, cell.y - 1) == WhiteTextIndex:
      inc hits
    if frame.framePixel(
      cell.x + bx,
      cell.y + VoteReaderCellH - 2
    ) == WhiteTextIndex:
      inc hits
  hits >= VoteReaderCellW

proc skipSelected(frame: openArray[uint8], skipX, skipY: int): bool =
  ## Returns true when the local cursor outlines the skip option.
  var hits = 0
  for bx in 0 ..< VoteReaderSkipW:
    if frame.framePixel(skipX + bx, skipY - 1) == WhiteTextIndex:
      inc hits
    if frame.framePixel(skipX + bx, skipY + 6) == WhiteTextIndex:
      inc hits
  hits >= VoteReaderSkipW

proc selfMarkerPresent(
  frame: openArray[uint8],
  count,
  index,
  colorIndex: int
): bool =
  ## Returns true when the local-player marker sits above one slot.
  if colorIndex < 0 or colorIndex >= PlayerColors.len:
    return false
  let
    cell = voteReaderCellOrigin(count, index)
    markerX = cell.x + VoteReaderCellW div 2 - 1
    markerY = cell.y - 2
    a = frame.framePixel(markerX, markerY)
    b = frame.framePixel(markerX + 1, markerY)
    color = PlayerColors[colorIndex]
  if color == SpaceColor:
    a == WhiteTextIndex and b == VoteReaderBlackMarker
  else:
    a == color and b == color

proc voteDotColorIndex(
  frame: openArray[uint8],
  x,
  y: int
): int =
  ## Returns the color index for one compact vote dot.
  let color = frame.framePixel(x, y)
  if color == WhiteTextIndex and
      frame.framePixel(x - 1, y) == VoteReaderBlackMarker:
    return voteReaderPlayerColorIndex(SpaceColor)
  if color == SpaceColor or color == TransparentColorIndex:
    return VoteReaderUnknown
  voteReaderPlayerColorIndex(color)

proc parseVoteDotsForTarget(
  frame: openArray[uint8],
  read: var VoteReaderFrame,
  target,
  dotX,
  dotY: int
) =
  ## Parses the compact voter dots for one voting target.
  for row in 0 ..< MaxPlayers:
    let colorIndex = frame.voteDotColorIndex(
      dotX + (row mod 8) * 2,
      dotY + (row div 8)
    )
    if colorIndex >= 0 and colorIndex < read.choices.len:
      read.choices[colorIndex] = target

proc rowHasWhiteText(
  frame: openArray[uint8],
  textX,
  y: int
): bool =
  ## Returns true when one row has white text pixels in the text area.
  if y < 0 or y >= ScreenHeight:
    return false
  for x in textX ..< ScreenWidth:
    if frame.framePixel(x, y).isWhiteTextIndex():
      return true

proc textLineStarts(
  frame: openArray[uint8],
  textX,
  startY,
  endY: int
): seq[int] =
  ## Returns likely top rows for visible chat text lines.
  var y = max(0, startY)
  let lastY = min(ScreenHeight - 1, endY)
  while y <= lastY:
    if frame.rowHasWhiteText(textX, y):
      result.add(y)
      y += TextLineHeight
    else:
      inc y

proc usefulChatLine(line: string): bool =
  ## Returns true when one OCR line contains useful text.
  var
    letters = 0
    unknown = 0
  for ch in line:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'}:
      inc letters
    elif ch == '?':
      inc unknown
  letters >= 2 and unknown * 2 <= max(1, line.len)

proc scanChatIcons(
  frame: openArray[uint8],
  playerSprite: Sprite,
  chatY: int
): seq[tuple[y: int, colorIndex: int]] =
  ## Finds speaker icons in the voting chat panel.
  var y = max(0, chatY)
  while y <= ScreenHeight - playerSprite.height:
    if frame.matchesCrewmate(playerSprite, VoteChatIconX, y, false):
      let colorIndex = frame.crewmateColorIndex(
        playerSprite,
        VoteChatIconX,
        y,
        false
      )
      if colorIndex >= 0:
        result.add((y, colorIndex))
        y += playerSprite.height
        continue
    inc y

proc nearestChatIcon(
  icons: openArray[tuple[y: int, colorIndex: int]],
  font: PixelFont,
  lineY: int
): int =
  ## Returns the nearest speaker icon for one chat text row.
  let lineCenter = lineY + font.height div 2
  var
    best = VoteReaderUnknown
    bestDistance = high(int)
  for i, icon in icons:
    let
      iconCenter = icon.y + SpriteSize div 2
      distance = abs(iconCenter - lineCenter)
    if distance < bestDistance:
      best = i
      bestDistance = distance
  if bestDistance <= 24:
    best
  else:
    VoteReaderUnknown

proc parseVoteChat(
  frame: openArray[uint8],
  font: PixelFont,
  playerSprite: Sprite,
  chatY: int
): seq[VoteReaderChat] =
  ## Parses voting chat speakers and message text.
  let icons = frame.scanChatIcons(playerSprite, chatY)
  if icons.len == 0:
    return
  var entries = newSeq[VoteReaderChat](icons.len)
  for i, icon in icons:
    entries[i].colorIndex = icon.colorIndex
  for lineY in frame.textLineStarts(
    VoteChatTextX,
    chatY,
    ScreenHeight - font.height
  ):
    let
      line = frame.readRun(font, VoteChatTextX, lineY, VoteChatCharsPerLine)
      iconIndex = nearestChatIcon(icons, font, lineY)
    if iconIndex < 0 or not line.usefulChatLine():
      continue
    if entries[iconIndex].lines.len == 0 or
        entries[iconIndex].lines[^1] != line:
      entries[iconIndex].lines.add(line)
  for entry in entries.mitems:
    if entry.lines.len == 0:
      continue
    entry.text = entry.lines.join(" ")
    result.add(entry)

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
  ## Returns the character gap between two spans.
  if aEnd <= bStart:
    bStart - aEnd
  elif bEnd <= aStart:
    aStart - bEnd
  else:
    0

proc voteReaderChatSusColorIndex*(text: string): int =
  ## Returns the player color that visible chat calls sus.
  let
    padded = " " & text.normalizeChatText() & " "
    susNeedle = " sus "
  result = VoteReaderUnknown
  var
    bestBefore = false
    bestSus = -1
    bestGap = high(int)
    bestLen = -1
  for i, name in VoteReaderColorNames:
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
          before = colorEnd <= susStart
        if gap <= VoteChatCharsPerLine * 2 and (
            susStart > bestSus or
            (susStart == bestSus and before and not bestBefore) or
            (susStart == bestSus and before == bestBefore and
              gap < bestGap) or
            (susStart == bestSus and before == bestBefore and
              gap == bestGap and
              colorLen > bestLen)):
          bestBefore = before
          bestSus = susStart
          bestGap = gap
          bestLen = colorLen
          result = i
        susPos = padded.find(susNeedle, susPos + 1)
      colorPos = padded.find(colorNeedle, colorPos + 1)

proc parseVoteCandidate(
  frame: openArray[uint8],
  font: PixelFont,
  playerSprite,
  bodySprite: Sprite,
  count: int
): VoteReaderFrame =
  ## Parses the vote screen for one possible player count.
  result = initVoteReaderFrame()
  if count <= 0 or count > MaxPlayers:
    return
  let layout = voteReaderGridLayout(count)
  if layout.cols <= 0 or not frame.skipTextMatches(
    font,
    layout.skipX,
    layout.skipY
  ):
    return
  for i in 0 ..< count:
    let slot = frame.parseSlot(playerSprite, bodySprite, count, i)
    if slot.colorIndex == VoteReaderUnknown or slot.colorIndex != i:
      return
    result.slots[i] = slot

  result.found = true
  result.playerCount = count
  for i in 0 ..< count:
    if result.slots[i].alive and frame.cellSelected(count, i):
      result.cursor = i
    if frame.selfMarkerPresent(count, i, result.slots[i].colorIndex):
      result.selfSlot = i
    let cell = voteReaderCellOrigin(count, i)
    frame.parseVoteDotsForTarget(
      result,
      i,
      cell.x + 1,
      cell.y + playerSprite.height + 2
    )
  if frame.skipSelected(layout.skipX, layout.skipY):
    result.cursor = count
  frame.parseVoteDotsForTarget(
    result,
    VoteReaderSkip,
    layout.skipX + VoteReaderSkipW + 2,
    layout.skipY
  )
  result.chat = frame.parseVoteChat(
    font,
    playerSprite,
    layout.skipY + 10
  )
  for entry in result.chat:
    if result.chatText.len > 0:
      result.chatText.add(' ')
    result.chatText.add(entry.text)
  result.chatSusColor = voteReaderChatSusColorIndex(result.chatText)

proc parseVoteFrame*(
  frame: openArray[uint8],
  font: PixelFont,
  playerSprite,
  bodySprite: Sprite,
  expectedCount = 0
): VoteReaderFrame =
  ## Parses the visible voting screen from a 128 by 128 framebuffer.
  if frame.len < ScreenWidth * ScreenHeight:
    return initVoteReaderFrame()
  if expectedCount > 0:
    return parseVoteCandidate(
      frame,
      font,
      playerSprite,
      bodySprite,
      expectedCount
    )
  for count in countdown(MaxPlayers, 1):
    result = parseVoteCandidate(frame, font, playerSprite, bodySprite, count)
    if result.found:
      return
  result = initVoteReaderFrame()

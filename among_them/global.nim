import std/os
import supersnappy
import protocol, sim
import ../common/server

const
  ReplayScrubberSpriteId = 4004
  ReplayScrubberObjectId = 4004
  ReplayScrubberWidth = 84
  ReplayScrubberHeight = 5
  ReplayScrubberTrackY = 2
  ReplayScrubberY = 8
  ReplayPanelHeight = 20
  ReplayCenterBottomLayerId = 8
  ReplayBottomLeftLayerId = 9
  ReplayCenterBottomLayerType = 8
  ReplayBottomLeftLayerType = 4
  ReplayTickSpriteId = 4002
  ReplayControlsSpriteId = 4003
  ReplayTickObjectId = 4002
  ReplayControlsObjectId = 4003
  InterstitialSpriteId = 4005
  InterstitialObjectId = 4005
  InterstitialLayerId = 2
  InterstitialLayerType = 2
  ImposterBarSpriteId = 701
  ImposterBarObjectBase = 5000
  ImposterBarWidth = 10
  ImposterBarHeight = 2
  ImposterBarYOffset = 4
  TrailDotSpriteBase = 720
  TrailDotObjectBase = 6000
  TrailDotSize = 3
  TrailDotSpacing = 10
  TrailMaxDots = 10
  TransportIconSize = 6
  TransportIconHeight = 6
  TransportIconCount = 5
  TransportButtonGap = 2
  TransportButtonStride = TransportIconSize + TransportButtonGap
  TransportSpeedX = 0
  TransportSpeedY = 8
  TransportWidth = 108
  TransportHeight = 18
  TransportSpeedGap = 16
  TransportX = 2
  TransportY = 1
  Player2KillSpriteId = 5000
  Player2KillShadowSpriteId = 5001
  Player2GhostIconSpriteId = 5002
  Player2RemainingSpriteId = 5003
  Player2ProgressSpriteId = 5004
  Player2ArrowSpriteId = 5005
  Player2InterstitialSpriteId = 5006
  Player2InterstitialObjectId = 5006
  Player2RemainingObjectId = 5007
  Player2ProgressObjectId = 5008
  Player2ShadowSpriteId = 5009
  Player2ShadowObjectId = 5009
  Player2ShadowZ = -32767
  Player2TaskArrowObjectBase = 7000
  ProtocolTextSpriteBase = 9000
  ProtocolTextObjectBase = 9000
  ProtocolTextZ = 30010
  ProtocolTextColor = 2'u8
  ProtocolChatIconObjectBase = 9200
  ProtocolChatIconZ = 30009
  ProtocolVoteIconObjectBase = 9300
  ProtocolVoteIconZ = 30008
  ProtocolLobbyIconObjectBase = 9400
  ProtocolRoleIconObjectBase = 9500
  ProtocolResultIconObjectBase = 9600
  ProtocolGameOverIconObjectBase = 9700
  PlayerColorNames = [
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
  TrailDot = object
    x, y: int
    colorIndex: int

  PlayerTrail = object
    joinOrder: int
    lastX, lastY: int
    dots: seq[TrailDot]

  SpriteDefinition = object
    spriteId: int
    width: int
    height: int
    label: string
    pixels: seq[uint8]

  GlobalViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    mouseX*: int
    mouseY*: int
    mouseLayer*: int
    mouseDown*: bool
    selectedJoinOrder*: int
    clickPending*: bool
    scrubbingReplay*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    trails: seq[PlayerTrail]
    spriteDefs: seq[SpriteDefinition]

  PlayerViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    spriteDefs: seq[SpriteDefinition]

  ProtocolTextItem = object
    spriteId: int
    objectId: int
    x, y, z: int
    color: uint8
    label: string
    lines: seq[string]

var TransportSheet: Sprite

proc initGlobalViewerState*(): GlobalViewerState =
  ## Returns the default state for one global protocol viewer.
  result.mouseLayer = MapLayerId
  result.selectedJoinOrder = -1
  result.replaySeekTick = -1
  result.replayCommands = @[]

proc initPlayerViewerState*(): PlayerViewerState =
  ## Returns the default state for one sprite player viewer.
  discard

proc putRgbaPixel(pixels: var seq[uint8], pixelIndex: int, color: uint8) =
  ## Writes one palette color as a global protocol RGBA pixel.
  let
    rgba = Palette[color and 0x0f]
    offset = pixelIndex * 4
  pixels[offset] = rgba.r
  pixels[offset + 1] = rgba.g
  pixels[offset + 2] = rgba.b
  pixels[offset + 3] = rgba.a

proc newRgbaPixels(width, height: int): seq[uint8] =
  ## Allocates a transparent RGBA sprite buffer.
  newSeq[uint8](width * height * 4)

proc transportSheet(): Sprite =
  ## Returns the cached transport icon sheet.
  if TransportSheet.width == 0:
    TransportSheet = readRequiredSprite(clientDataDir() / "transport.png")
  TransportSheet

proc playerColorIndex(color: uint8): int =
  ## Returns the player color slot for a palette color.
  for i in 0 ..< PlayerColors.len:
    if PlayerColors[i] == color:
      return i
  0

proc playerColorName(index: int): string =
  ## Returns the display name for one player color slot.
  if index >= 0 and index < PlayerColorNames.len:
    return PlayerColorNames[index]
  "unknown"

proc addU8(packet: var seq[uint8], value: uint8) =
  ## Appends one unsigned byte to a global protocol packet.
  packet.add(value)

proc addU16(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 16 bit value.
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addU32(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 32 bit value.
  let v = uint32(value)
  for shift in countup(0, 24, 8):
    packet.add(uint8((v shr shift) and 0xff'u32))

proc addI16(packet: var seq[uint8], value: int) =
  ## Appends one little endian signed 16 bit value.
  let v = cast[uint16](int16(value))
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addViewport(packet: var seq[uint8], layer, width, height: int) =
  ## Appends a global protocol viewport message.
  packet.addU8(0x05)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addLayer(packet: var seq[uint8], layer, layerType, flags: int) =
  ## Appends a global protocol layer definition message.
  packet.addU8(0x06)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(layerType))
  packet.addU8(uint8(flags))

proc addSprite(
  packet: var seq[uint8],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label: string = ""
) =
  ## Appends a global protocol sprite definition message.
  packet.addU8(0x01)
  packet.addU16(spriteId)
  packet.addU16(width)
  packet.addU16(height)
  var raw = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    raw[i] = pixels[i]
  let compressed = supersnappy.compress(raw)
  packet.addU32(compressed.len)
  for byte in compressed:
    packet.addU8(byte)
  packet.addU16(label.len)
  for ch in label:
    packet.addU8(uint8(ord(ch)))

proc spriteDefinitionIndex(
  defs: openArray[SpriteDefinition],
  spriteId: int
): int =
  ## Returns the cache index for one sprite definition.
  for i in 0 ..< defs.len:
    if defs[i].spriteId == spriteId:
      return i
  -1

proc pixelsMatch(a: openArray[uint8], b: openArray[uint8]): bool =
  ## Returns true when two RGBA pixel payloads are identical.
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc copyPixels(pixels: openArray[uint8]): seq[uint8] =
  ## Copies one sprite payload into cache storage.
  result = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    result[i] = pixels[i]

proc addSpriteChanged(
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label: string = ""
) =
  ## Appends a sprite definition only when it changed.
  let index = defs.spriteDefinitionIndex(spriteId)
  if index >= 0:
    if defs[index].width == width and
        defs[index].height == height and
        defs[index].label == label and
        defs[index].pixels.pixelsMatch(pixels):
      return
    defs[index].width = width
    defs[index].height = height
    defs[index].label = label
    defs[index].pixels = copyPixels(pixels)
  else:
    defs.add SpriteDefinition(
      spriteId: spriteId,
      width: width,
      height: height,
      label: label,
      pixels: copyPixels(pixels)
    )
  packet.addSprite(spriteId, width, height, pixels, label)

proc addObject(
  packet: var seq[uint8],
  objectId, x, y, z, layer, spriteId: int
) =
  ## Appends a global protocol object definition message.
  packet.addU8(0x02)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc addDeleteObject(packet: var seq[uint8], objectId: int) =
  ## Appends a global protocol object delete message.
  packet.addU8(0x03)
  packet.addU16(objectId)

proc readProtocolI16(blob: string, offset: int): int =
  ## Reads one little endian signed 16 bit value from a string.
  let value = uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc applyGlobalViewerMessage*(
  state: var GlobalViewerState,
  message: string
) =
  ## Applies one or more global protocol client messages.
  var offset = 0
  while offset < message.len:
    let messageType = message[offset].uint8
    inc offset
    case messageType
    of 0x82:
      if offset + 4 > message.len:
        return
      state.mouseX = readProtocolI16(message, offset)
      state.mouseY = readProtocolI16(message, offset + 2)
      offset += 4
      if offset < message.len and message[offset].uint8 notin
          {0x81'u8, 0x82'u8, 0x83'u8, 0x84'u8}:
        state.mouseLayer = int(message[offset].uint8)
        inc offset
      else:
        state.mouseLayer = MapLayerId
    of 0x83:
      if offset + 2 > message.len:
        return
      let
        code = message[offset].uint8
        down = message[offset + 1].uint8
      offset += 2
      if code == 0x01'u8:
        state.mouseDown = down == 1'u8
        if state.mouseDown:
          state.clickPending = true
        else:
          state.scrubbingReplay = false
    of 0x81:
      if offset + 2 > message.len:
        return
      let length = int(uint16(message[offset].uint8) or
        (uint16(message[offset + 1].uint8) shl 8))
      offset += 2
      if offset + length > message.len:
        return
      for i in 0 ..< length:
        state.replayCommands.add(message[offset + i])
      offset += length
    of 0x84:
      if offset + 1 > message.len:
        return
      inc offset
    else:
      return

proc applyPlayerViewerMessage*(
  state: var PlayerViewerState,
  message: string,
  inputMask: var uint8,
  chatText: var string
) =
  ## Applies sprite player protocol input messages.
  var offset = 0
  while offset < message.len:
    let messageType = message[offset].uint8
    inc offset
    case messageType
    of 0x81:
      if offset + 2 > message.len:
        return
      let length = int(uint16(message[offset].uint8) or
        (uint16(message[offset + 1].uint8) shl 8))
      offset += 2
      if offset + length > message.len:
        return
      for i in 0 ..< length:
        let value = message[offset + i].uint8
        if value >= 32'u8 and value < 127'u8:
          chatText.add(message[offset + i])
      offset += length
    of 0x82:
      if offset + 4 > message.len:
        return
      offset += 4
      if offset < message.len and message[offset].uint8 notin
          {0x81'u8, 0x82'u8, 0x83'u8, 0x84'u8}:
        inc offset
    of 0x83:
      if offset + 2 > message.len:
        return
      offset += 2
    of 0x84:
      if offset + 1 > message.len:
        return
      inputMask = message[offset].uint8 and 0x7f'u8
      inc offset
    else:
      return

proc isSolid(sprite: Sprite, x, y: int, flipH: bool): bool =
  let srcX = if flipH: sprite.width - 1 - x else: x
  if srcX < 0 or srcX >= sprite.width or y < 0 or y >= sprite.height:
    return false
  sprite.pixels[sprite.spriteIndex(srcX, y)] != TransparentColorIndex

proc buildSpriteProtocolActorSprite(
  sprite: Sprite,
  tint: uint8,
  flipH: bool,
  selected: bool = false
): seq[uint8] =
  ## Builds a tinted actor sprite for the global viewer.
  let
    outWidth = sprite.width + 2
    outHeight = sprite.height + 2
    outline = if selected: 8'u8 else: OutlineColor
  result = newRgbaPixels(outWidth, outHeight)

  proc outIndex(x, y: int): int =
    y * outWidth + x

  if selected:
    for y in -1 .. sprite.height:
      for x in -1 .. sprite.width:
        if sprite.isSolid(x, y, flipH):
          continue
        let adjacent =
          sprite.isSolid(x - 1, y, flipH) or
          sprite.isSolid(x + 1, y, flipH) or
          sprite.isSolid(x, y - 1, flipH) or
          sprite.isSolid(x, y + 1, flipH)
        if adjacent:
          result.putRgbaPixel(outIndex(x + 1, y + 1), outline)

  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let srcX = if flipH: sprite.width - 1 - x else: x
      let colorIndex = sprite.pixels[sprite.spriteIndex(srcX, y)]
      if colorIndex == TransparentColorIndex:
        continue
      result.putRgbaPixel(
        outIndex(x + 1, y + 1),
        actorColor(colorIndex, tint)
      )

proc buildSpriteProtocolBodySprite(
  bodySprite: Sprite,
  tint: uint8
): seq[uint8] =
  ## Builds a tinted dead body sprite for the global viewer.
  let
    outWidth = bodySprite.width + 2
    outHeight = bodySprite.height + 2
  result = newRgbaPixels(outWidth, outHeight)

  proc outIndex(x, y: int): int =
    y * outWidth + x

  for y in 0 ..< bodySprite.height:
    for x in 0 ..< bodySprite.width:
      let colorIndex = bodySprite.pixels[bodySprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        result.putRgbaPixel(
          outIndex(x + 1, y + 1),
          actorColor(colorIndex, tint)
        )

proc buildSpriteProtocolRawSprite(sprite: Sprite): seq[uint8] =
  ## Builds a raw global protocol sprite from a game sprite.
  result = newRgbaPixels(sprite.width, sprite.height)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        result.putRgbaPixel(sprite.spriteIndex(x, y), colorIndex)

proc buildSpriteProtocolShadowSprite(sprite: Sprite): seq[uint8] =
  ## Builds a shadowed global protocol sprite from a game sprite.
  result = newRgbaPixels(sprite.width, sprite.height)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        result.putRgbaPixel(
          sprite.spriteIndex(x, y),
          ShadowMap[colorIndex and 0x0f]
        )

proc buildSolidSprite(width, height: int, color: uint8): seq[uint8] =
  ## Builds a solid protocol sprite.
  result = newRgbaPixels(width, height)
  for i in 0 ..< width * height:
    result.putRgbaPixel(i, color)

proc buildImposterBarSprite(): seq[uint8] =
  ## Builds the global-only red impostor marker sprite.
  result = newRgbaPixels(ImposterBarWidth, ImposterBarHeight)
  for i in 0 ..< ImposterBarWidth * ImposterBarHeight:
    result.putRgbaPixel(i, TintColor)

proc buildTrailDotSprite(color: uint8): seq[uint8] =
  ## Builds one global-only player trail dot sprite.
  result = newRgbaPixels(TrailDotSize, TrailDotSize)
  for i in 0 ..< TrailDotSize * TrailDotSize:
    result.putRgbaPixel(i, color)

proc buildMapSpritePixels(sim: SimServer): seq[uint8] =
  ## Returns the true-color map pixels for a global protocol sprite.
  if sim.mapRgba.len == sim.gameMap.width * sim.gameMap.height * 4:
    return sim.mapRgba
  result = newRgbaPixels(sim.gameMap.width, sim.gameMap.height)
  for i in 0 ..< sim.mapPixels.len:
    result.putRgbaPixel(i, sim.mapPixels[i])

proc buildPlayerShadowSprite(
  sim: SimServer,
  cameraX, cameraY: int
): seq[uint8] =
  ## Builds one screen-sized transparent shadow overlay.
  result = newRgbaPixels(ScreenWidth, ScreenHeight)
  for sy in 0 ..< ScreenHeight:
    for sx in 0 ..< ScreenWidth:
      let
        screenIndex = sy * ScreenWidth + sx
        mx = cameraX + sx
        my = cameraY + sy
      if not sim.shadowBuf[screenIndex]:
        continue
      if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
        continue
      let mapPixel = mapIndex(mx, my)
      if sim.wallMask[mapPixel]:
        continue
      result.putRgbaPixel(
        screenIndex,
        ShadowMap[sim.mapPixels[mapPixel] and 0x0f]
      )

proc putTextSpritePixel(
  pixels: var seq[uint8],
  width, height, x, y: int,
  color: uint8
) =
  ## Puts one protocol pixel into a text sprite.
  if x < 0 or y < 0 or x >= width or y >= height:
    return
  pixels.putRgbaPixel(y * width + x, color)

proc blitGlyph(
  target: var seq[uint8],
  targetWidth, targetHeight: int,
  sprite: Sprite,
  baseX, baseY: int,
  color: uint8
) =
  ## Blits a single-color glyph into protocol pixels.
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      if sprite.pixels[sprite.spriteIndex(x, y)] ==
          TransparentColorIndex:
        continue
      target.putTextSpritePixel(
        targetWidth,
        targetHeight,
        baseX + x,
        baseY + y,
        color
      )

proc blitSmallText(
  game: SimServer,
  target: var seq[uint8],
  targetWidth, targetHeight: int,
  text: string,
  baseX, baseY: int,
  color: uint8
) =
  ## Blits small text into protocol pixels.
  var x = baseX
  for ch in text:
    let idx = sim.asciiIndex(ch)
    if idx >= 0 and idx < game.asciiSprites.len:
      target.blitGlyph(
        targetWidth,
        targetHeight,
        game.asciiSprites[idx],
        x,
        baseY,
        color
      )
    x += 7

proc buildSpriteProtocolTextSprite(
  game: SimServer,
  lines: openArray[string],
  color: uint8
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a transparent multi-line text sprite.
  result.width = 1
  for line in lines:
    result.width = max(result.width, line.len * 7)
  result.height = max(1, lines.len * 9)
  result.pixels = newRgbaPixels(result.width, result.height)
  for lineIndex, line in lines:
    let baseY = lineIndex * 9
    var baseX = 0
    for ch in line:
      let idx = sim.asciiIndex(ch)
      if idx >= 0 and idx < game.asciiSprites.len:
        let sprite = game.asciiSprites[idx]
        for y in 0 ..< sprite.height:
          for x in 0 ..< sprite.width:
            if sprite.pixels[sprite.spriteIndex(x, y)] !=
                TransparentColorIndex:
              result.pixels.putTextSpritePixel(
                result.width,
                result.height,
                baseX + x,
                baseY + y,
                color
              )
      baseX += 7

proc textLabel(lines: openArray[string]): string =
  ## Returns a debugger label for one rendered text sprite.
  for i, line in lines:
    if i > 0:
      result.add("\n")
    result.add(line)

proc addTextItem(
  items: var seq[ProtocolTextItem],
  x, y: int,
  lines: openArray[string],
  label = "",
  color = ProtocolTextColor
) =
  ## Adds one text sprite placement to an interstitial layout.
  let index = items.len
  var item = ProtocolTextItem(
    spriteId: ProtocolTextSpriteBase + index,
    objectId: ProtocolTextObjectBase + index,
    x: x,
    y: y,
    z: ProtocolTextZ,
    color: color
  )
  for line in lines:
    item.lines.add(line)
  item.label =
    if label.len > 0:
      label
    else:
      textLabel(lines)
  items.add(item)

proc addVisibleVoteChatText(
  sim: SimServer,
  items: var seq[ProtocolTextItem],
  chatY: int
) =
  ## Adds separate text sprites for visible voting chat messages.
  let
    chatH = ScreenHeight - chatY - 3
    textX = 21
  if chatH <= 0:
    return
  var
    visible: seq[int] = @[]
    usedH = 0
  for i in countdown(sim.chatMessages.high, 0):
    let messageH = sim.chatMessages[i].text.chatMessageHeight()
    if usedH + messageH > chatH - 4:
      break
    visible.add(i)
    usedH += messageH
  var rowY = chatY + 2
  for j in countdown(visible.high, 0):
    let
      message = sim.chatMessages[visible[j]]
      lineCount = message.text.chatLineCount()
      messageH = message.text.chatMessageHeight()
    var lines: seq[string] = @[]
    for lineIndex in 0 ..< lineCount:
      lines.add(message.text.sliceChatLine(lineIndex))
    items.addTextItem(textX, rowY, lines, message.text)
    rowY += messageH

proc addVisibleVoteChatIcons(
  sim: SimServer,
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer: int,
  chatY: int
) =
  ## Adds separate player sprites for visible voting chat speakers.
  let
    chatH = ScreenHeight - chatY - 3
    iconX = 4
  if chatH <= 0:
    return
  var
    visible: seq[int] = @[]
    usedH = 0
  for i in countdown(sim.chatMessages.high, 0):
    let messageH = sim.chatMessages[i].text.chatMessageHeight()
    if usedH + messageH > chatH - 4:
      break
    visible.add(i)
    usedH += messageH
  var rowY = chatY + 2
  for j in countdown(visible.high, 0):
    let
      message = sim.chatMessages[visible[j]]
      lineCount = message.text.chatLineCount()
      messageH = message.text.chatMessageHeight()
      iconY = rowY + max(0, (lineCount * 9 - SpriteSize) div 2)
      objectId = ProtocolChatIconObjectBase + j
      spriteId = PlayerSpriteBase + playerColorIndex(message.color) * 2
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      iconX - 1,
      iconY - 1,
      ProtocolChatIconZ,
      layer,
      spriteId
    )
    rowY += messageH

proc interstitialTextItems(
  sim: SimServer,
  playerIndex: int
): seq[ProtocolTextItem] =
  ## Returns separate text sprites for one interstitial player screen.
  case sim.phase
  of Lobby:
    let needed = max(0, sim.config.minPlayers - sim.players.len)
    result.addTextItem(11, 4, ["WAITING"])
    if needed > 0:
      result.addTextItem(2, 14, ["NEED MORE!"])
    else:
      result.addTextItem(14, 14, ["READY!"])
  of Playing:
    if playerIndex < 0 or playerIndex >= sim.players.len:
      result.addTextItem(11, 22, ["GAME IN"])
      result.addTextItem(8, 32, ["PROGRESS"])
  of RoleReveal:
    let viewerIsImp =
      playerIndex >= 0 and playerIndex < sim.players.len and
      sim.players[playerIndex].role == Imposter
    let title = if viewerIsImp: "IMPS" else: "CREWMATE"
    result.addTextItem((ScreenWidth - title.len * 7) div 2, 14, [title])
  of Voting:
    let n = sim.players.len
    if n > 0:
      let
        cellH = 17
        cols = min(n, 8)
        rows = (n + cols - 1) div cols
        startY = 2
        skipW = 28
        skipY = startY + rows * cellH + 1
        skipX = (ScreenWidth - skipW) div 2
      result.addTextItem(skipX, skipY, ["SKIP"])
      sim.addVisibleVoteChatText(result, skipY + 10)
  of VoteResult:
    let ej = sim.voteState.ejectedPlayer
    if ej < 0 or ej >= sim.players.len:
      result.addTextItem(46, 54, ["NO ONE"])
      result.addTextItem(52, 64, ["DIED"])
  of GameOver:
    let title =
      if sim.winner == Crewmate: "CREW WINS"
      else: "IMPS WIN"
    let
      titleW = title.len * 7
      titleX = (ScreenWidth - titleW) div 2
      rowH = 14
      rowsPerCol = 8
      colW = ScreenWidth div 2
      textOffsetX = 19
      startY = 16
    result.addTextItem(titleX, 2, [title])
    for i in 0 ..< sim.players.len:
      let
        p = sim.players[i]
        col = i div rowsPerCol
        row = i mod rowsPerCol
        baseX = min(col, 1) * colW
        textX = baseX + textOffsetX
        textY = startY + row * rowH + (rowH - 6) div 2
        roleText = if p.role == Imposter: "IMP" else: "CREW"
      result.addTextItem(textX, textY, [roleText])

proc addProtocolTextSprites(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer: int,
  playerIndex: int
) =
  ## Adds separate text sprites for current interstitial text.
  let items = sim.interstitialTextItems(playerIndex)
  for item in items:
    let text = sim.buildSpriteProtocolTextSprite(item.lines, item.color)
    currentIds.add(item.objectId)
    packet.addSpriteChanged(
      spriteDefs,
      item.spriteId,
      text.width,
      text.height,
      text.pixels,
      item.label
    )
    packet.addObject(
      item.objectId,
      item.x,
      item.y,
      item.z,
      layer,
      item.spriteId
    )

proc addProtocolChatSprites(
  sim: SimServer,
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer: int
) =
  ## Adds separate player sprites for protocol-rendered voting chat.
  if sim.phase != Voting:
    return
  let n = sim.players.len
  if n == 0:
    return
  let
    cellH = 17
    cols = min(n, 8)
    rows = (n + cols - 1) div cols
    startY = 2
    skipY = startY + rows * cellH + 1
  sim.addVisibleVoteChatIcons(currentIds, packet, layer, skipY + 10)

proc putProtocolVoteDot(fb: var Framebuffer, x, y: int, color: uint8) =
  ## Draws one vote marker into a sprite protocol voting background.
  if color == SpaceColor:
    fb.putPixel(x - 1, y, 12'u8)
    fb.putPixel(x, y, 2'u8)
  else:
    fb.putPixel(x, y, color)

proc putProtocolSelfMarker(fb: var Framebuffer, x, y: int, color: uint8) =
  ## Draws the local voter marker into a sprite protocol voting background.
  if color == SpaceColor:
    fb.putPixel(x, y, 2'u8)
    fb.putPixel(x + 1, y, 12'u8)
  else:
    fb.putPixel(x, y, color)
    fb.putPixel(x + 1, y, color)

proc buildSpriteProtocolBlankFrame(color = 0'u8): seq[uint8] =
  ## Builds a packed blank frame for sprite protocol interstitials.
  var fb = initFramebuffer()
  fb.clearFrame(color)
  fb.packFramebuffer()
  fb.packed

proc buildSpriteProtocolVoteFrame(
  sim: SimServer,
  playerIndex: int
): seq[uint8] =
  ## Builds a voting background without baked text or player icons.
  var fb = initFramebuffer()
  fb.clearFrame(0)
  let n = sim.players.len
  if n == 0:
    fb.packFramebuffer()
    return fb.packed
  let
    cellW = 16
    cellH = 17
    cols = min(n, 8)
    rows = (n + cols - 1) div cols
    totalW = cols * cellW
    startX = (ScreenWidth - totalW) div 2
    startY = 2

  for idx in 0 ..< n:
    let
      pi = idx
      col = idx mod cols
      row = idx div cols
      cx = startX + col * cellW
      cy = startY + row * cellH
    if pi == playerIndex:
      fb.putProtocolSelfMarker(
        cx + cellW div 2 - 1,
        cy - 2,
        sim.players[pi].color
      )
    if sim.players[pi].alive and
        playerIndex >= 0 and playerIndex < sim.voteState.cursor.len and
        sim.voteState.cursor[playerIndex] == pi:
      for bx in 0 ..< cellW:
        fb.putPixel(cx + bx, cy - 1, 2'u8)
        fb.putPixel(cx + bx, cy + cellH - 2, 2'u8)
      for by in 0 ..< cellH:
        fb.putPixel(cx, cy + by - 1, 2'u8)
        fb.putPixel(cx + cellW - 1, cy + by - 1, 2'u8)
    var voterRow = 0
    for vi in 0 ..< n:
      if sim.voteState.votes[vi] == pi:
        let
          dotX = cx + 1 + (voterRow mod 8) * 2
          dotY = cy + SpriteSize + 2 + (voterRow div 8)
        fb.putProtocolVoteDot(dotX, dotY, sim.players[vi].color)
        inc voterRow

  let
    skipY = startY + rows * cellH + 1
    skipW = 28
    skipX = (ScreenWidth - skipW) div 2
  if playerIndex >= 0 and playerIndex < sim.voteState.cursor.len and
      sim.voteState.cursor[playerIndex] == n:
    for bx in 0 ..< skipW:
      fb.putPixel(skipX + bx, skipY - 1, 2'u8)
      fb.putPixel(skipX + bx, skipY + 6, 2'u8)
    for by in 0 ..< 8:
      fb.putPixel(skipX - 1, skipY + by - 1, 2'u8)
      fb.putPixel(skipX + skipW, skipY + by - 1, 2'u8)
  var skipVoterRow = 0
  for vi in 0 ..< n:
    if sim.voteState.votes[vi] == -2:
      let
        dotX = skipX + skipW + 2 + (skipVoterRow mod 8) * 2
        dotY = skipY + (skipVoterRow div 8)
      fb.putProtocolVoteDot(dotX, dotY, sim.players[vi].color)
      inc skipVoterRow

  let
    chatX = 1
    chatY = skipY + 10
    chatW = ScreenWidth - 2
    chatH = ScreenHeight - chatY - 3
  if chatH > 0:
    fb.fillRect(chatX, chatY, chatW, chatH, 0)

  let
    barY = ScreenHeight - 2
    barW = ScreenWidth - 4
    filled = sim.voteState.voteTimer * barW div sim.config.voteTimerTicks
  for bx in 0 ..< barW:
    let c = if bx < filled: 10'u8 else: 1'u8
    fb.putPixel(2 + bx, barY, c)
    fb.putPixel(2 + bx, barY + 1, c)

  fb.packFramebuffer()
  fb.packed

proc addProtocolVoteActorSprites(
  sim: SimServer,
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer: int
) =
  ## Adds separate player and body sprites for the voting candidate grid.
  if sim.phase != Voting:
    return
  let n = sim.players.len
  if n == 0:
    return
  let
    cellW = 16
    cellH = 17
    cols = min(n, 8)
    totalW = cols * cellW
    startX = (ScreenWidth - totalW) div 2
    startY = 2
  for idx in 0 ..< n:
    let
      player = sim.players[idx]
      col = idx mod cols
      row = idx div cols
      cx = startX + col * cellW
      cy = startY + row * cellH
      spriteX = cx + (cellW - SpriteSize) div 2
      spriteY = cy + 1
      colorIndex = playerColorIndex(player.color)
      objectId = ProtocolVoteIconObjectBase + idx
      spriteId =
        if player.alive:
          PlayerSpriteBase + colorIndex * 2
        else:
          BodySpriteBase + colorIndex
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      spriteX - 1,
      spriteY - 1,
      ProtocolVoteIconZ,
      layer,
      spriteId
    )

proc playerIconSpriteId(player: Player): int =
  ## Returns the default right-facing player icon sprite id.
  PlayerSpriteBase + playerColorIndex(player.color) * 2

proc addProtocolLobbyActorSprites(
  sim: SimServer,
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer: int
) =
  ## Adds separate player sprites for the lobby interstitial.
  if sim.phase != Lobby:
    return
  let startY = 26
  for i in 0 ..< sim.players.len:
    let
      col = i mod 6
      row = i div 6
      sx = 5 + col * 9
      sy = startY + row * 9
      objectId = ProtocolLobbyIconObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      sx - 1,
      sy - 1,
      ProtocolVoteIconZ,
      layer,
      sim.players[i].playerIconSpriteId()
    )

proc addProtocolRoleRevealActorSprites(
  sim: SimServer,
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer, playerIndex: int
) =
  ## Adds separate player sprites for the role reveal interstitial.
  if sim.phase != RoleReveal:
    return
  let viewerIsImp =
    playerIndex >= 0 and playerIndex < sim.players.len and
    sim.players[playerIndex].role == Imposter
  var shown: seq[int] = @[]
  if viewerIsImp:
    for i in 0 ..< sim.players.len:
      if sim.players[i].role == Imposter:
        shown.add(i)
  else:
    for i in 0 ..< sim.players.len:
      shown.add(i)
  if shown.len == 0:
    return
  let
    cellW = 16
    cellH = 18
    cols = min(shown.len, 8)
    totalW = cols * cellW
    startX = (ScreenWidth - totalW) div 2
    startY = 42
  for slot in 0 ..< shown.len:
    let
      playerIdx = shown[slot]
      col = slot mod cols
      row = slot div cols
      spriteX = startX + col * cellW + (cellW - SpriteSize) div 2
      spriteY = startY + row * cellH
      objectId = ProtocolRoleIconObjectBase + slot
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      spriteX - 1,
      spriteY - 1,
      ProtocolVoteIconZ,
      layer,
      sim.players[playerIdx].playerIconSpriteId()
    )

proc addProtocolVoteResultActorSprites(
  sim: SimServer,
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer: int
) =
  ## Adds separate player sprites for vote result interstitials.
  if sim.phase != VoteResult:
    return
  let ejected = sim.voteState.ejectedPlayer
  if ejected < 0 or ejected >= sim.players.len:
    return
  let
    sx = ScreenWidth div 2 - SpriteSize div 2
    sy = ScreenHeight div 2 - SpriteSize div 2
  currentIds.add(ProtocolResultIconObjectBase)
  packet.addObject(
    ProtocolResultIconObjectBase,
    sx - 1,
    sy - 1,
    ProtocolVoteIconZ,
    layer,
    sim.players[ejected].playerIconSpriteId()
  )

proc addProtocolGameOverActorSprites(
  sim: SimServer,
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer: int
) =
  ## Adds separate player sprites for the game over interstitial.
  if sim.phase != GameOver:
    return
  let
    rowH = 14
    rowsPerCol = 8
    colW = ScreenWidth div 2
    iconOffsetX = 4
    startY = 16
  for i in 0 ..< sim.players.len:
    let
      player = sim.players[i]
      col = i div rowsPerCol
      row = i mod rowsPerCol
      baseX = min(col, 1) * colW
      y = startY + row * rowH
      iconX = baseX + iconOffsetX
      iconY = y + (rowH - SpriteSize) div 2
      objectId = ProtocolGameOverIconObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      iconX - 1,
      iconY - 1,
      ProtocolVoteIconZ,
      layer,
      player.playerIconSpriteId()
    )

proc addProtocolInterstitialActorSprites(
  sim: SimServer,
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer, playerIndex: int
) =
  ## Adds separate actor sprites for sprite protocol interstitials.
  case sim.phase
  of Lobby:
    sim.addProtocolLobbyActorSprites(currentIds, packet, layer)
  of RoleReveal:
    sim.addProtocolRoleRevealActorSprites(
      currentIds,
      packet,
      layer,
      playerIndex
    )
  of Voting:
    sim.addProtocolVoteActorSprites(currentIds, packet, layer)
    sim.addProtocolChatSprites(currentIds, packet, layer)
  of VoteResult:
    sim.addProtocolVoteResultActorSprites(currentIds, packet, layer)
  of GameOver:
    sim.addProtocolGameOverActorSprites(currentIds, packet, layer)
  else:
    discard

proc spritePixelsFromPackedFrame(packed: openArray[uint8]): seq[uint8] =
  ## Converts a packed Bitworld frame into protocol sprite pixels.
  result = newRgbaPixels(ScreenWidth, ScreenHeight)
  var j = 0
  for byte in packed:
    result.putRgbaPixel(j, byte and 0x0f)
    inc j
    result.putRgbaPixel(j, (byte shr 4) and 0x0f)
    inc j

proc hasInterstitialFrame(sim: SimServer): bool =
  ## Returns true when the global viewer should show a neutral game screen.
  sim.phase in {Lobby, Voting, VoteResult, GameOver}

proc buildInterstitialFrame(
  sim: var SimServer,
  includeText = true
): seq[uint8] =
  ## Builds a neutral global-view interstitial frame.
  case sim.phase
  of Lobby:
    if includeText:
      sim.buildLobbyFrame(-1)
    else:
      buildSpriteProtocolBlankFrame()
  of Voting:
    if includeText:
      sim.buildVoteFrame(-1)
    else:
      sim.buildSpriteProtocolVoteFrame(-1)
  of VoteResult:
    if includeText:
      sim.buildResultFrame(-1)
    else:
      buildSpriteProtocolBlankFrame()
  of GameOver:
    if includeText:
      sim.buildGameOverFrame(-1)
    else:
      buildSpriteProtocolBlankFrame()
  else:
    @[]

proc buildSpriteProtocolInit(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition]
): seq[uint8] =
  ## Builds the initial global viewer snapshot.
  result = @[]
  let mapPixels = sim.buildMapSpritePixels()
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, sim.gameMap.width, sim.gameMap.height)
  result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
  result.addViewport(TopLeftLayerId, 160, 24)
  result.addLayer(InterstitialLayerId, InterstitialLayerType, UiLayerFlag)
  result.addViewport(InterstitialLayerId, ScreenWidth, ScreenHeight)
  result.addLayer(BottomRightLayerId, BottomRightLayerType, UiLayerFlag)
  result.addViewport(BottomRightLayerId, ScreenWidth, ScreenHeight)
  result.addSpriteChanged(
    spriteDefs,
    MapSpriteId,
    sim.gameMap.width,
    sim.gameMap.height,
    mapPixels,
    "map"
  )
  result.addObject(MapObjectId, 0, 0, low(int16), MapLayerId, MapSpriteId)
  let taskPixels = buildSpriteProtocolRawSprite(sim.taskIconSprite)
  result.addSpriteChanged(
    spriteDefs,
    TaskSpriteId,
    sim.taskIconSprite.width,
    sim.taskIconSprite.height,
    taskPixels,
    "task bubble"
  )
  result.addSpriteChanged(
    spriteDefs,
    ImposterBarSpriteId,
    ImposterBarWidth,
    ImposterBarHeight,
    buildImposterBarSprite(),
    "imposter marker"
  )
  for i in 0 ..< PlayerColors.len:
    result.addSpriteChanged(
      spriteDefs,
      TrailDotSpriteBase + i,
      TrailDotSize,
      TrailDotSize,
      buildTrailDotSprite(PlayerColors[i]),
      "trail " & playerColorName(i)
    )
  for i in 0 ..< PlayerColors.len:
    let
      playerRight = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        false
      )
      playerLeft = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        true
      )
      ghostRight = buildSpriteProtocolActorSprite(
        sim.ghostSprite,
        PlayerColors[i],
        false
      )
      ghostLeft = buildSpriteProtocolActorSprite(
        sim.ghostSprite,
        PlayerColors[i],
        true
      )
      selectedPlayerRight = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        false,
        true
      )
      selectedPlayerLeft = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        true,
        true
      )
      selectedGhostRight = buildSpriteProtocolActorSprite(
        sim.ghostSprite,
        PlayerColors[i],
        false,
        true
      )
      selectedGhostLeft = buildSpriteProtocolActorSprite(
        sim.ghostSprite,
        PlayerColors[i],
        true,
        true
      )
      bodyPixels = buildSpriteProtocolBodySprite(
        sim.bodySprite,
        PlayerColors[i]
      )
    result.addSpriteChanged(
      spriteDefs,
      PlayerSpriteBase + i * 2,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      playerRight,
      "player " & playerColorName(i) & " right"
    )
    result.addSpriteChanged(
      spriteDefs,
      PlayerSpriteBase + i * 2 + 1,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      playerLeft,
      "player " & playerColorName(i) & " left"
    )
    result.addSpriteChanged(
      spriteDefs,
      GhostSpriteBase + i * 2,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      ghostRight,
      "ghost " & playerColorName(i) & " right"
    )
    result.addSpriteChanged(
      spriteDefs,
      GhostSpriteBase + i * 2 + 1,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      ghostLeft,
      "ghost " & playerColorName(i) & " left"
    )
    result.addSpriteChanged(
      spriteDefs,
      SelectedPlayerSpriteBase + i * 2,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      selectedPlayerRight,
      "selected player " & playerColorName(i) & " right"
    )
    result.addSpriteChanged(
      spriteDefs,
      SelectedPlayerSpriteBase + i * 2 + 1,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      selectedPlayerLeft,
      "selected player " & playerColorName(i) & " left"
    )
    result.addSpriteChanged(
      spriteDefs,
      SelectedGhostSpriteBase + i * 2,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      selectedGhostRight,
      "selected ghost " & playerColorName(i) & " right"
    )
    result.addSpriteChanged(
      spriteDefs,
      SelectedGhostSpriteBase + i * 2 + 1,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      selectedGhostLeft,
      "selected ghost " & playerColorName(i) & " left"
    )
    result.addSpriteChanged(
      spriteDefs,
      BodySpriteBase + i,
      sim.bodySprite.width + 2,
      sim.bodySprite.height + 2,
      bodyPixels,
      "body " & playerColorName(i)
    )

proc buildSpriteProtocolPlayerInit(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition]
): seq[uint8] =
  ## Builds the initial sprite player snapshot.
  result = @[]
  let mapPixels = sim.buildMapSpritePixels()
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, ScreenWidth, ScreenHeight)
  result.addSpriteChanged(
    spriteDefs,
    MapSpriteId,
    sim.gameMap.width,
    sim.gameMap.height,
    mapPixels,
    "map"
  )
  result.addSpriteChanged(
    spriteDefs,
    TaskSpriteId,
    sim.taskIconSprite.width,
    sim.taskIconSprite.height,
    buildSpriteProtocolRawSprite(sim.taskIconSprite),
    "task bubble"
  )
  result.addSpriteChanged(
    spriteDefs,
    Player2KillSpriteId,
    sim.killButtonSprite.width,
    sim.killButtonSprite.height,
    buildSpriteProtocolRawSprite(sim.killButtonSprite),
    "imposter icon"
  )
  result.addSpriteChanged(
    spriteDefs,
    Player2KillShadowSpriteId,
    sim.killButtonSprite.width,
    sim.killButtonSprite.height,
    buildSpriteProtocolShadowSprite(sim.killButtonSprite),
    "imposter icon cooldown"
  )
  result.addSpriteChanged(
    spriteDefs,
    Player2GhostIconSpriteId,
    sim.ghostIconSprite.width,
    sim.ghostIconSprite.height,
    buildSpriteProtocolRawSprite(sim.ghostIconSprite),
    "ghost icon"
  )
  result.addSpriteChanged(
    spriteDefs,
    Player2ArrowSpriteId,
    1,
    1,
    buildSolidSprite(1, 1, 8'u8),
    "task arrow"
  )
  for i in 0 ..< PlayerColors.len:
    let
      playerRight = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        false
      )
      playerLeft = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        true
      )
      ghostRight = buildSpriteProtocolActorSprite(
        sim.ghostSprite,
        PlayerColors[i],
        false
      )
      ghostLeft = buildSpriteProtocolActorSprite(
        sim.ghostSprite,
        PlayerColors[i],
        true
      )
      bodyPixels = buildSpriteProtocolBodySprite(
        sim.bodySprite,
        PlayerColors[i]
      )
    result.addSpriteChanged(
      spriteDefs,
      PlayerSpriteBase + i * 2,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      playerRight,
      "player " & playerColorName(i) & " right"
    )
    result.addSpriteChanged(
      spriteDefs,
      PlayerSpriteBase + i * 2 + 1,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      playerLeft,
      "player " & playerColorName(i) & " left"
    )
    result.addSpriteChanged(
      spriteDefs,
      GhostSpriteBase + i * 2,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      ghostRight,
      "ghost " & playerColorName(i) & " right"
    )
    result.addSpriteChanged(
      spriteDefs,
      GhostSpriteBase + i * 2 + 1,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      ghostLeft,
      "ghost " & playerColorName(i) & " left"
    )
    result.addSpriteChanged(
      spriteDefs,
      BodySpriteBase + i,
      sim.bodySprite.width + 2,
      sim.bodySprite.height + 2,
      bodyPixels,
      "body " & playerColorName(i)
    )

proc spriteObjectId(player: Player): int =
  ## Returns the stable global protocol object id for a player.
  PlayerObjectBase + player.joinOrder

proc spriteImposterBarObjectId(player: Player): int =
  ## Returns the stable global protocol object id for an impostor bar.
  ImposterBarObjectBase + player.joinOrder

proc spriteTrailDotObjectId(joinOrder, dotIndex: int): int =
  ## Returns the stable global protocol object id for a trail dot.
  TrailDotObjectBase + joinOrder * TrailMaxDots + dotIndex

proc spritePlayerX(player: Player): int =
  ## Returns the global viewer x position for a player sprite.
  player.x - SpriteDrawOffX - 1

proc spritePlayerY(player: Player): int =
  ## Returns the global viewer y position for a player sprite.
  player.y - SpriteDrawOffY - 1

proc trailCenter(player: Player): tuple[x, y: int] =
  ## Returns the map position used for a player's trail.
  (
    x: player.x + CollisionW div 2,
    y: player.y + CollisionH div 2
  )

proc spriteBodyObjectId(index: int): int =
  ## Returns the global protocol object id for a dead body.
  BodyObjectBase + index

proc spriteTaskObjectId(index: int): int =
  ## Returns the global protocol object id for a task bubble.
  TaskObjectBase + index

proc taskStillNeeded(sim: SimServer, taskIndex: int): bool =
  ## Returns true when any player still needs a task station.
  for i in 0 ..< sim.players.len:
    let player = sim.players[i]
    if not player.hasTask(taskIndex):
      continue
    if taskIndex >= sim.tasks.len:
      continue
    if i >= sim.tasks[taskIndex].completed.len:
      return true
    if not sim.tasks[taskIndex].completed[i]:
      return true
  false

proc trailIndex(state: GlobalViewerState, joinOrder: int): int =
  ## Returns the trail index for one player join order.
  for i in 0 ..< state.trails.len:
    if state.trails[i].joinOrder == joinOrder:
      return i
  -1

proc playerExists(sim: SimServer, joinOrder: int): bool =
  ## Returns true when a player join order is still present.
  for player in sim.players:
    if player.joinOrder == joinOrder:
      return true
  false

proc updateTrails(state: var GlobalViewerState, sim: SimServer) =
  ## Updates global-only player trails from current player positions.
  for i in countdown(state.trails.high, 0):
    if not sim.playerExists(state.trails[i].joinOrder):
      state.trails.delete(i)

  for player in sim.players:
    let
      center = player.trailCenter()
      colorIndex = playerColorIndex(player.color)
    var index = state.trailIndex(player.joinOrder)
    if index < 0:
      state.trails.add PlayerTrail(
        joinOrder: player.joinOrder,
        lastX: center.x,
        lastY: center.y,
        dots: @[TrailDot(
          x: center.x,
          y: center.y,
          colorIndex: colorIndex
        )]
      )
      continue
    if distSq(
      center.x,
      center.y,
      state.trails[index].lastX,
      state.trails[index].lastY
    ) >= TrailDotSpacing * TrailDotSpacing:
      state.trails[index].dots.add TrailDot(
        x: center.x,
        y: center.y,
        colorIndex: colorIndex
      )
      state.trails[index].lastX = center.x
      state.trails[index].lastY = center.y
      while state.trails[index].dots.len > TrailMaxDots:
        state.trails[index].dots.delete(0)

proc spriteActorSpriteId(player: Player, selectedJoinOrder: int): int =
  ## Returns the sprite id for a player in the global viewer.
  let
    colorIndex = player.joinOrder mod PlayerColors.len
    side = if player.flipH: 1 else: 0
    selected = player.joinOrder == selectedJoinOrder
  if player.alive and selected:
    SelectedPlayerSpriteBase + colorIndex * 2 + side
  elif player.alive:
    PlayerSpriteBase + colorIndex * 2 + side
  elif selected:
    SelectedGhostSpriteBase + colorIndex * 2 + side
  else:
    GhostSpriteBase + colorIndex * 2 + side

proc selectSpritePlayer(sim: SimServer, mouseX, mouseY: int): int =
  ## Returns the join order of the topmost player under the mouse.
  result = -1
  var bestY = low(int)
  for player in sim.players:
    let
      x = player.spritePlayerX()
      y = player.spritePlayerY()
      w = sim.playerSprite.width + 2
      h = sim.playerSprite.height + 2
    if mouseX >= x and mouseX < x + w and
        mouseY >= y and mouseY < y + h and
        player.y >= bestY:
      bestY = player.y
      result = player.joinOrder

proc selectedPlayerIndex(sim: SimServer, joinOrder: int): int =
  ## Returns the player index for a join order.
  for i in 0 ..< sim.players.len:
    if sim.players[i].joinOrder == joinOrder:
      return i
  -1

proc roleName(role: PlayerRole): string =
  ## Returns a display name for a player role.
  case role
  of Crewmate:
    return "CREWMATE"
  of Imposter:
    return "IMPOSTER"

proc buildTaskProgressSprite(progress, total: int): seq[uint8] =
  ## Builds the one-pixel high task progress bar sprite.
  result = newRgbaPixels(TaskBarWidth, 1)
  let filled =
    if total > 0:
      clamp(progress * TaskBarWidth div total, 0, TaskBarWidth)
    else:
      0
  for x in 0 ..< TaskBarWidth:
    let color = if x < filled: ProgressFilled else: ProgressEmpty
    result.putRgbaPixel(x, color)

proc addSpritePlayerTaskArrows(
  sim: SimServer,
  playerIndex: int,
  cameraX,
  cameraY: int,
  currentIds: var seq[int],
  packet: var seq[uint8]
) =
  ## Adds off-screen task arrow objects to a sprite player packet.
  if not sim.config.showTaskArrows:
    return
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let player = sim.players[playerIndex]
  if player.role != Crewmate:
    return
  let bob = [0, 0, -1, -1, -1, 0, 0, 1, 1, 1]
  for taskIndex in player.assignedTasks:
    if taskIndex < 0 or taskIndex >= sim.tasks.len:
      continue
    let task = sim.tasks[taskIndex]
    if playerIndex < task.completed.len and task.completed[playerIndex]:
      continue
    let
      bobY =
        if player.activeTask == taskIndex:
          0
        else:
          bob[(sim.tickCount div 3) mod bob.len]
      iconX = task.x + task.w div 2 - cameraX
      iconY = task.y - SpriteSize div 2 - 2 + bobY - cameraY
      iconSx = task.x + task.w div 2 - SpriteSize div 2 - cameraX
      iconSy = task.y - SpriteSize - 2 + bobY - cameraY
    if iconSx + SpriteSize > 0 and iconSy + SpriteSize > 0 and
        iconSx < ScreenWidth and iconSy < ScreenHeight:
      continue
    let
      px = float(player.x + CollisionW div 2 - cameraX)
      py = float(player.y + CollisionH div 2 - cameraY)
      dx = float(iconX) - px
      dy = float(iconY) - py
    if abs(dx) < 0.5 and abs(dy) < 0.5:
      continue
    var ex, ey: float
    let
      minX = 0.0
      maxX = float(ScreenWidth - 1)
      minY = 0.0
      maxY = float(ScreenHeight - 1)
    if abs(dx) > abs(dy):
      if dx > 0:
        ex = maxX
      else:
        ex = minX
      ey = py + dy * (ex - px) / dx
      ey = clamp(ey, minY, maxY)
    else:
      if dy > 0:
        ey = maxY
      else:
        ey = minY
      ex = px + dx * (ey - py) / dy
      ex = clamp(ex, minX, maxX)
    let objectId = Player2TaskArrowObjectBase + taskIndex
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      int(ex),
      int(ey),
      30000,
      MapLayerId,
      Player2ArrowSpriteId
    )

proc buildSpriteProtocolPlayerUpdates*(
  sim: var SimServer,
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState
): seq[uint8] =
  ## Builds sprite protocol updates for one playable player view.
  result = @[]
  nextState = state
  if not nextState.initialized:
    result = sim.buildSpriteProtocolPlayerInit(nextState.spriteDefs)
    nextState.initialized = true

  var currentIds: seq[int] = @[]
  if sim.phase != Playing or playerIndex < 0 or
      playerIndex >= sim.players.len:
    let packedFrame =
      if sim.phase == Playing and
          (playerIndex < 0 or playerIndex >= sim.players.len):
        buildSpriteProtocolBlankFrame()
      elif sim.phase in {Lobby, RoleReveal}:
        buildSpriteProtocolBlankFrame()
      elif sim.phase == Voting:
        sim.buildSpriteProtocolVoteFrame(playerIndex)
      elif sim.phase in {VoteResult, GameOver}:
        buildSpriteProtocolBlankFrame()
      else:
        sim.render(playerIndex)
    let interstitial = spritePixelsFromPackedFrame(packedFrame)
    currentIds.add(Player2InterstitialObjectId)
    result.addSpriteChanged(
      nextState.spriteDefs,
      Player2InterstitialSpriteId,
      ScreenWidth,
      ScreenHeight,
      interstitial,
      "player screen"
    )
    result.addObject(
      Player2InterstitialObjectId,
      0,
      0,
      0,
      MapLayerId,
      Player2InterstitialSpriteId
    )
    sim.addProtocolTextSprites(
      nextState.spriteDefs,
      currentIds,
      result,
      MapLayerId,
      playerIndex
    )
    sim.addProtocolInterstitialActorSprites(
      currentIds,
      result,
      MapLayerId,
      playerIndex
    )
  else:
    let
      player = sim.players[playerIndex]
      view = sim.playerView(playerIndex)
      cameraX = view.cameraX
      cameraY = view.cameraY
      viewerIsGhost = view.viewerIsGhost
    if not viewerIsGhost:
      sim.castShadows(view.originMx, view.originMy, cameraX, cameraY)
    currentIds.add(MapObjectId)
    result.addObject(
      MapObjectId,
      -cameraX,
      -cameraY,
      low(int16),
      MapLayerId,
      MapSpriteId
    )
    if not viewerIsGhost:
      let shadowPixels = sim.buildPlayerShadowSprite(cameraX, cameraY)
      currentIds.add(Player2ShadowObjectId)
      result.addSpriteChanged(
        nextState.spriteDefs,
        Player2ShadowSpriteId,
        ScreenWidth,
        ScreenHeight,
        shadowPixels,
        "shadow"
      )
      result.addObject(
        Player2ShadowObjectId,
        0,
        0,
        Player2ShadowZ,
        MapLayerId,
        Player2ShadowSpriteId
      )

    for i in 0 ..< sim.bodies.len:
      let body = sim.bodies[i]
      if not sim.screenPointVisible(
        view,
        body.x + CollisionW div 2,
        body.y + CollisionH div 2
      ):
        continue
      let objectId = spriteBodyObjectId(i)
      currentIds.add(objectId)
      result.addObject(
        objectId,
        body.x - SpriteDrawOffX - 1 - cameraX,
        body.y - SpriteDrawOffY - 1 - cameraY,
        body.y,
        MapLayerId,
        BodySpriteBase + playerColorIndex(body.color)
      )

    for other in sim.players:
      if not view.screenPointInFrame(
        other.x + CollisionW div 2,
        other.y + CollisionH div 2
      ):
        continue
      if other.alive:
        if other.joinOrder != player.joinOrder:
          if not sim.screenPointVisible(
            view,
            other.x + CollisionW div 2,
            other.y + CollisionH div 2
          ):
            continue
      elif not viewerIsGhost:
        continue
      let objectId = other.spriteObjectId()
      currentIds.add(objectId)
      result.addObject(
        objectId,
        other.x - SpriteDrawOffX - 1 - cameraX,
        other.y - SpriteDrawOffY - 1 - cameraY,
        other.y,
        MapLayerId,
        other.spriteActorSpriteId(-1)
      )

    if player.role == Crewmate:
      let bob = [0, 0, -1, -1, -1, 0, 0, 1, 1, 1]
      for taskIndex in player.assignedTasks:
        if taskIndex < 0 or taskIndex >= sim.tasks.len:
          continue
        let task = sim.tasks[taskIndex]
        if playerIndex < task.completed.len and
            task.completed[playerIndex]:
          continue
        let
          bobY =
            if player.activeTask == taskIndex:
              0
            else:
              bob[(sim.tickCount div 3) mod bob.len]
          iconSx =
            task.x + task.w div 2 - SpriteSize div 2 - cameraX
          iconSy = task.y - SpriteSize - 2 + bobY - cameraY
        if iconSx + SpriteSize <= 0 or iconSy + SpriteSize <= 0 or
            iconSx >= ScreenWidth or iconSy >= ScreenHeight:
          continue
        let objectId = spriteTaskObjectId(taskIndex)
        currentIds.add(objectId)
        result.addObject(
          objectId,
          iconSx,
          iconSy,
          30000,
          MapLayerId,
          TaskSpriteId
        )
        if player.activeTask == taskIndex and player.taskProgress > 0:
          let
            barX = iconSx + SpriteSize div 2 - TaskBarWidth div 2
            barY = iconSy + SpriteSize + TaskBarGap
            progressPercent =
              if sim.config.taskCompleteTicks > 0:
                clamp(
                  player.taskProgress * 100 div sim.config.taskCompleteTicks,
                  0,
                  100
                )
              else:
                0
          currentIds.add(Player2ProgressObjectId)
          result.addSpriteChanged(
            nextState.spriteDefs,
            Player2ProgressSpriteId,
            TaskBarWidth,
            1,
            buildTaskProgressSprite(
              player.taskProgress,
              sim.config.taskCompleteTicks
            ),
            "progress bar " & $progressPercent & "%"
          )
          result.addObject(
            Player2ProgressObjectId,
            barX,
            barY,
            30001,
            MapLayerId,
            Player2ProgressSpriteId
          )

    sim.addSpritePlayerTaskArrows(
      playerIndex,
      cameraX,
      cameraY,
      currentIds,
      result
    )

    if not player.alive:
      currentIds.add(Player2RemainingObjectId)
      result.addObject(
        Player2RemainingObjectId,
        1,
        ScreenHeight - SpriteSize - 1,
        30002,
        MapLayerId,
        Player2GhostIconSpriteId
      )
    elif player.role == Imposter:
      currentIds.add(Player2RemainingObjectId)
      result.addObject(
        Player2RemainingObjectId,
        1,
        ScreenHeight - SpriteSize - 1,
        30002,
        MapLayerId,
        if player.killCooldown > 0:
          Player2KillShadowSpriteId
        else:
          Player2KillSpriteId
      )

    let
      remainingText = $sim.totalTasksRemaining()
      remaining = sim.buildSpriteProtocolTextSprite([remainingText], 2'u8)
      textX = ScreenWidth - remaining.width
    currentIds.add(SelectedTextObjectId)
    result.addSpriteChanged(
      nextState.spriteDefs,
      Player2RemainingSpriteId,
      remaining.width,
      remaining.height,
      remaining.pixels,
      "task counter " & remainingText
    )
    result.addObject(
      SelectedTextObjectId,
      textX,
      0,
      30003,
      MapLayerId,
      Player2RemainingSpriteId
    )

  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

proc replayCommandAt(layer, x, y: int): char =
  ## Returns the replay transport command under a UI coordinate.
  if layer != ReplayBottomLeftLayerId:
    return '\0'
  let
    localX = x - TransportX
    localY = y - TransportY
  if localY >= 0 and localY < TransportIconHeight:
    let index = localX div TransportButtonStride
    if index < 0 or index >= TransportIconCount:
      return '\0'
    if localX - index * TransportButtonStride >= TransportIconSize:
      return '\0'
    case index
    of 0: return '<'
    of 1: return ' '
    of 2: return 'e'
    of 3: return 'r'
    of 4: return 'b'
    else: return '\0'
  if localY >= TransportSpeedY and localY < TransportSpeedY + 6:
    let speedX = localX - TransportSpeedX
    if speedX >= 0 and speedX < 12:
      return '1'
    if speedX >= 16 and speedX < 28:
      return '2'
    if speedX >= 32 and speedX < 44:
      return '3'
    if speedX >= 48 and speedX < 60:
      return '4'
    if speedX >= 64 and speedX < 76:
      return '8'
  '\0'

proc replayScrubTickAt(
  layer, x, y, maxTick: int,
  requireInside = true
): int =
  ## Returns the replay tick under the scrubber pointer.
  if layer != ReplayCenterBottomLayerId or maxTick < 0:
    return -1
  let
    scrubberX = max(0, (ScreenWidth - ReplayScrubberWidth) div 2)
    localX = x - scrubberX
    localY = y - ReplayScrubberY
  if requireInside and (
      localX < 0 or localX >= ReplayScrubberWidth or
      localY < 0 or localY >= ReplayScrubberHeight
    ):
    return -1
  if ReplayScrubberWidth <= 1:
    return 0
  let clampedX = clamp(localX, 0, ReplayScrubberWidth - 1)
  clamp((clampedX * maxTick) div (ReplayScrubberWidth - 1), 0, maxTick)

proc buildReplayScrubberSprite(
  tick, maxTick: int,
  enabled: bool
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a compact replay scrubber sprite.
  result.width = ReplayScrubberWidth
  result.height = ReplayScrubberHeight
  result.pixels = newRgbaPixels(ReplayScrubberWidth, ReplayScrubberHeight)
  let knobX =
    if maxTick > 0:
      clamp(
        (tick * (ReplayScrubberWidth - 1)) div maxTick,
        0,
        ReplayScrubberWidth - 1
      )
    else:
      0

  for x in 0 ..< ReplayScrubberWidth:
    result.pixels.putRgbaPixel(
      ReplayScrubberTrackY * ReplayScrubberWidth + x,
      1'u8
    )
  if enabled:
    for x in 0 .. knobX:
      result.pixels.putRgbaPixel(
        ReplayScrubberTrackY * ReplayScrubberWidth + x,
        10'u8
      )
  for y in 0 ..< ReplayScrubberHeight:
    result.pixels.putRgbaPixel(
      y * ReplayScrubberWidth + knobX,
      if enabled: 2'u8 else: 1'u8
    )
  if knobX > 0:
    result.pixels.putRgbaPixel(
      ReplayScrubberTrackY * ReplayScrubberWidth + knobX - 1,
      if enabled: 2'u8 else: 1'u8
    )
  if knobX < ReplayScrubberWidth - 1:
    result.pixels.putRgbaPixel(
      ReplayScrubberTrackY * ReplayScrubberWidth + knobX + 1,
      if enabled: 2'u8 else: 1'u8
    )

proc blitTransportIcon(
  target: var seq[uint8],
  sheet: Sprite,
  cell, baseX, baseY: int,
  tint: uint8
) =
  ## Blits one transport icon cell into protocol pixels.
  let sourceX = cell * TransportIconSize
  for y in 0 ..< TransportIconHeight:
    for x in 0 ..< TransportIconSize:
      let colorIndex = sheet.pixels[sheet.spriteIndex(sourceX + x, y)]
      if colorIndex == TransparentColorIndex:
        continue
      target.putRgbaPixel(
        (baseY + y) * TransportWidth + baseX + x,
        tint
      )

proc buildReplayControlsSprite(
  sim: SimServer,
  replayPlaying: bool,
  replaySpeed: int,
  replayLooping: bool,
  replayEnabled: bool
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds the replay transport controls sprite.
  result.width = TransportWidth
  result.height = TransportHeight
  result.pixels = newRgbaPixels(TransportWidth, TransportHeight)
  let
    sheet = transportSheet()
    iconCells = [
      0,
      if replayPlaying: 2 else: 1,
      3,
      4,
      5
    ]
  for i in 0 ..< iconCells.len:
    let tint =
      if not replayEnabled:
        1'u8
      elif i == 3:
        if replayLooping: 10'u8 else: 1'u8
      else:
        2'u8
    result.pixels.blitTransportIcon(
      sheet,
      iconCells[i],
      i * TransportButtonStride,
      0,
      tint
    )

  let speedTexts = ["1X", "2X", "3X", "4X", "8X"]
  var x = TransportSpeedX
  for i in 0 ..< speedTexts.len:
    let speed =
      case i
      of 0: 1
      of 1: 2
      of 2: 3
      of 3: 4
      else: 8
    let color = if speed == replaySpeed: 10'u8 else: 1'u8
    sim.blitSmallText(
      result.pixels,
      TransportWidth,
      TransportHeight,
      speedTexts[i],
      x,
      TransportSpeedY,
      color
    )
    x += TransportSpeedGap

proc buildSpriteProtocolUpdates*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  replayTick = -1,
  replayPlaying = false,
  replaySpeed = 1,
  replayMaxTick = -1,
  replayLooping = false,
  replayEnabled = false
): seq[uint8] =
  ## Builds global viewer object updates for the current tick.
  result = @[]
  nextState = state
  nextState.replayCommands.setLen(0)
  nextState.replaySeekTick = -1
  if nextState.clickPending:
    let seekTick = replayScrubTickAt(
      nextState.mouseLayer,
      nextState.mouseX,
      nextState.mouseY,
      replayMaxTick
    )
    if replayTick >= 0 and seekTick >= 0:
      nextState.scrubbingReplay = true
      nextState.replaySeekTick = seekTick
    elif replayTick >= 0:
      let command = replayCommandAt(
        nextState.mouseLayer,
        nextState.mouseX,
        nextState.mouseY
      )
      if command != '\0':
        nextState.replayCommands.add(command)
      elif nextState.mouseLayer == MapLayerId:
        nextState.selectedJoinOrder =
          sim.selectSpritePlayer(nextState.mouseX, nextState.mouseY)
    elif nextState.mouseLayer == MapLayerId:
      nextState.selectedJoinOrder =
        sim.selectSpritePlayer(nextState.mouseX, nextState.mouseY)
    nextState.clickPending = false
  if replayTick >= 0 and nextState.mouseDown and nextState.scrubbingReplay:
    let seekTick = replayScrubTickAt(
      nextState.mouseLayer,
      nextState.mouseX,
      nextState.mouseY,
      replayMaxTick
    )
    if seekTick >= 0:
      nextState.replaySeekTick = seekTick
  if not nextState.initialized:
    result = sim.buildSpriteProtocolInit(nextState.spriteDefs)
    result.addLayer(
      ReplayCenterBottomLayerId,
      ReplayCenterBottomLayerType,
      UiLayerFlag
    )
    result.addViewport(ReplayCenterBottomLayerId, ScreenWidth, ReplayPanelHeight)
    result.addLayer(
      ReplayBottomLeftLayerId,
      ReplayBottomLeftLayerType,
      UiLayerFlag
    )
    result.addViewport(ReplayBottomLeftLayerId, ScreenWidth, ReplayPanelHeight)
    nextState.initialized = true

  nextState.updateTrails(sim)
  var currentIds: seq[int] = @[]
  for trail in nextState.trails:
    for i in 0 ..< trail.dots.len:
      let
        dot = trail.dots[i]
        objectId = spriteTrailDotObjectId(trail.joinOrder, i)
      currentIds.add(objectId)
      result.addObject(
        objectId,
        dot.x - TrailDotSize div 2,
        dot.y - TrailDotSize div 2,
        dot.y - 100,
        MapLayerId,
        TrailDotSpriteBase + dot.colorIndex
      )

  for player in sim.players:
    let objectId = player.spriteObjectId()
    currentIds.add(objectId)
    result.addObject(
      objectId,
      player.spritePlayerX(),
      player.spritePlayerY(),
      player.y,
      MapLayerId,
      player.spriteActorSpriteId(nextState.selectedJoinOrder)
    )
    if player.role == Imposter:
      let
        barObjectId = player.spriteImposterBarObjectId()
        barX = player.spritePlayerX() +
          (sim.playerSprite.width + 2 - ImposterBarWidth) div 2
        barY = player.spritePlayerY() - ImposterBarYOffset
      currentIds.add(barObjectId)
      result.addObject(
        barObjectId,
        barX,
        barY,
        30001,
        MapLayerId,
        ImposterBarSpriteId
      )

  for i in 0 ..< sim.bodies.len:
    let
      body = sim.bodies[i]
      objectId = spriteBodyObjectId(i)
    currentIds.add(objectId)
    result.addObject(
      objectId,
      body.x - SpriteDrawOffX - 1,
      body.y - SpriteDrawOffY - 1,
      body.y,
      MapLayerId,
      BodySpriteBase + playerColorIndex(body.color)
    )

  if sim.config.showTaskBubbles:
    let bob = [0, 0, -1, -1, -1, 0, 0, 1, 1, 1]
    for i in 0 ..< sim.tasks.len:
      if not sim.taskStillNeeded(i):
        continue
      let
        task = sim.tasks[i]
        objectId = spriteTaskObjectId(i)
        bobY = bob[(sim.tickCount div 3) mod bob.len]
      currentIds.add(objectId)
      result.addObject(
        objectId,
        task.x + task.w div 2 - SpriteSize div 2,
        task.y - SpriteSize - 2 + bobY,
        30000,
        MapLayerId,
        TaskSpriteId
      )

  if sim.hasInterstitialFrame():
    let interstitial = spritePixelsFromPackedFrame(
      sim.buildInterstitialFrame(false)
    )
    currentIds.add(InterstitialObjectId)
    result.addSpriteChanged(
      nextState.spriteDefs,
      InterstitialSpriteId,
      ScreenWidth,
      ScreenHeight,
      interstitial,
      "interstitial screen"
    )
    result.addObject(
      InterstitialObjectId,
      0,
      0,
      0,
      InterstitialLayerId,
      InterstitialSpriteId
    )
    sim.addProtocolTextSprites(
      nextState.spriteDefs,
      currentIds,
      result,
      InterstitialLayerId,
      -1
    )
    sim.addProtocolInterstitialActorSprites(
      currentIds,
      result,
      InterstitialLayerId,
      -1
    )

  let playerIndex = sim.selectedPlayerIndex(nextState.selectedJoinOrder)
  if playerIndex >= 0:
    let
      player = sim.players[playerIndex]
      text = sim.buildSpriteProtocolTextSprite(
        [
          "ADDRESS " & player.address,
          "ROLE " & roleName(player.role)
        ],
        2'u8
      )
      viewport = spritePixelsFromPackedFrame(
        sim.render(playerIndex)
      )
    currentIds.add(SelectedTextObjectId)
    currentIds.add(SelectedViewportObjectId)
    result.addSpriteChanged(
      nextState.spriteDefs,
      SelectedTextSpriteId,
      text.width,
      text.height,
      text.pixels,
      "selected player info"
    )
    result.addObject(
      SelectedTextObjectId,
      2,
      2,
      0,
      TopLeftLayerId,
      SelectedTextSpriteId
    )
    result.addSpriteChanged(
      nextState.spriteDefs,
      SelectedViewportSpriteId,
      ScreenWidth,
      ScreenHeight,
      viewport,
      "selected player viewport"
    )
    result.addObject(
      SelectedViewportObjectId,
      0,
      0,
      0,
      BottomRightLayerId,
      SelectedViewportSpriteId
    )

  let
    controlTick = max(0, replayTick)
    controlMaxTick = max(controlTick, replayMaxTick)
    tickText = sim.buildSpriteProtocolTextSprite(
      ["TICK " & $controlTick],
      if replayEnabled: 2'u8 else: 1'u8
    )
    scrubber = buildReplayScrubberSprite(
      controlTick,
      controlMaxTick,
      replayEnabled
    )
    controls = sim.buildReplayControlsSprite(
      replayPlaying,
      replaySpeed,
      replayLooping,
      replayEnabled
    )
  currentIds.add(ReplayTickObjectId)
  currentIds.add(ReplayControlsObjectId)
  currentIds.add(ReplayScrubberObjectId)
  result.addSpriteChanged(
    nextState.spriteDefs,
    ReplayTickSpriteId,
    tickText.width,
    tickText.height,
    tickText.pixels,
    "replay tick " & $controlTick
  )
  result.addObject(
    ReplayTickObjectId,
    max(0, (ScreenWidth - tickText.width) div 2),
    0,
    0,
    ReplayCenterBottomLayerId,
    ReplayTickSpriteId
  )
  result.addSpriteChanged(
    nextState.spriteDefs,
    ReplayScrubberSpriteId,
    scrubber.width,
    scrubber.height,
    scrubber.pixels,
    "replay scrubber"
  )
  result.addObject(
    ReplayScrubberObjectId,
    max(0, (ScreenWidth - ReplayScrubberWidth) div 2),
    ReplayScrubberY,
    0,
    ReplayCenterBottomLayerId,
    ReplayScrubberSpriteId
  )
  result.addSpriteChanged(
    nextState.spriteDefs,
    ReplayControlsSpriteId,
    controls.width,
    controls.height,
    controls.pixels,
    "replay controls"
  )
  result.addObject(
    ReplayControlsObjectId,
    TransportX,
    TransportY,
    0,
    ReplayBottomLeftLayerId,
    ReplayControlsSpriteId
  )

  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

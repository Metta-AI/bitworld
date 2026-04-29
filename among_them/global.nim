import std/os
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

type
  TrailDot = object
    x, y: int
    colorIndex: int

  PlayerTrail = object
    joinOrder: int
    lastX, lastY: int
    dots: seq[TrailDot]

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

  PlayerViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    shadowPixels*: seq[uint8]

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

proc addU8(packet: var seq[uint8], value: uint8) =
  ## Appends one unsigned byte to a global protocol packet.
  packet.add(value)

proc addU16(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 16 bit value.
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

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
  pixels: openArray[uint8]
) =
  ## Appends a global protocol sprite definition message.
  packet.addU8(0x01)
  packet.addU16(spriteId)
  packet.addU16(width)
  packet.addU16(height)
  for pixel in pixels:
    packet.addU8(pixel)

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

proc buildInterstitialFrame(sim: var SimServer): seq[uint8] =
  ## Builds a neutral global-view interstitial frame.
  case sim.phase
  of Lobby:
    sim.buildLobbyFrame(-1)
  of Voting:
    sim.buildVoteFrame(-1)
  of VoteResult:
    sim.buildResultFrame(-1)
  of GameOver:
    sim.buildGameOverFrame(-1)
  else:
    @[]

proc buildSpriteProtocolInit(sim: SimServer): seq[uint8] =
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
  result.addSprite(MapSpriteId, sim.gameMap.width, sim.gameMap.height, mapPixels)
  result.addObject(MapObjectId, 0, 0, low(int16), MapLayerId, MapSpriteId)
  let taskPixels = buildSpriteProtocolRawSprite(sim.taskIconSprite)
  result.addSprite(
    TaskSpriteId,
    sim.taskIconSprite.width,
    sim.taskIconSprite.height,
    taskPixels
  )
  result.addSprite(
    ImposterBarSpriteId,
    ImposterBarWidth,
    ImposterBarHeight,
    buildImposterBarSprite()
  )
  for i in 0 ..< PlayerColors.len:
    result.addSprite(
      TrailDotSpriteBase + i,
      TrailDotSize,
      TrailDotSize,
      buildTrailDotSprite(PlayerColors[i])
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
    result.addSprite(
      PlayerSpriteBase + i * 2,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      playerRight
    )
    result.addSprite(
      PlayerSpriteBase + i * 2 + 1,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      playerLeft
    )
    result.addSprite(
      GhostSpriteBase + i * 2,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      ghostRight
    )
    result.addSprite(
      GhostSpriteBase + i * 2 + 1,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      ghostLeft
    )
    result.addSprite(
      SelectedPlayerSpriteBase + i * 2,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      selectedPlayerRight
    )
    result.addSprite(
      SelectedPlayerSpriteBase + i * 2 + 1,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      selectedPlayerLeft
    )
    result.addSprite(
      SelectedGhostSpriteBase + i * 2,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      selectedGhostRight
    )
    result.addSprite(
      SelectedGhostSpriteBase + i * 2 + 1,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      selectedGhostLeft
    )
    result.addSprite(
      BodySpriteBase + i,
      sim.bodySprite.width + 2,
      sim.bodySprite.height + 2,
      bodyPixels
    )

proc buildSpriteProtocolPlayerInit(sim: SimServer): seq[uint8] =
  ## Builds the initial sprite player snapshot.
  result = @[]
  let mapPixels = sim.buildMapSpritePixels()
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, ScreenWidth, ScreenHeight)
  result.addSprite(MapSpriteId, sim.gameMap.width, sim.gameMap.height, mapPixels)
  result.addSprite(
    TaskSpriteId,
    sim.taskIconSprite.width,
    sim.taskIconSprite.height,
    buildSpriteProtocolRawSprite(sim.taskIconSprite)
  )
  result.addSprite(
    Player2KillSpriteId,
    sim.killButtonSprite.width,
    sim.killButtonSprite.height,
    buildSpriteProtocolRawSprite(sim.killButtonSprite)
  )
  result.addSprite(
    Player2KillShadowSpriteId,
    sim.killButtonSprite.width,
    sim.killButtonSprite.height,
    buildSpriteProtocolShadowSprite(sim.killButtonSprite)
  )
  result.addSprite(
    Player2GhostIconSpriteId,
    sim.ghostIconSprite.width,
    sim.ghostIconSprite.height,
    buildSpriteProtocolRawSprite(sim.ghostIconSprite)
  )
  result.addSprite(
    Player2ArrowSpriteId,
    1,
    1,
    buildSolidSprite(1, 1, 8'u8)
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
    result.addSprite(
      PlayerSpriteBase + i * 2,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      playerRight
    )
    result.addSprite(
      PlayerSpriteBase + i * 2 + 1,
      sim.playerSprite.width + 2,
      sim.playerSprite.height + 2,
      playerLeft
    )
    result.addSprite(
      GhostSpriteBase + i * 2,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      ghostRight
    )
    result.addSprite(
      GhostSpriteBase + i * 2 + 1,
      sim.ghostSprite.width + 2,
      sim.ghostSprite.height + 2,
      ghostLeft
    )
    result.addSprite(
      BodySpriteBase + i,
      sim.bodySprite.width + 2,
      sim.bodySprite.height + 2,
      bodyPixels
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
    result = sim.buildSpriteProtocolPlayerInit()
    nextState.initialized = true

  var currentIds: seq[int] = @[]
  if sim.phase != Playing or playerIndex < 0 or
      playerIndex >= sim.players.len:
    let interstitial = spritePixelsFromPackedFrame(sim.render(playerIndex))
    currentIds.add(Player2InterstitialObjectId)
    result.addSprite(
      Player2InterstitialSpriteId,
      ScreenWidth,
      ScreenHeight,
      interstitial
    )
    result.addObject(
      Player2InterstitialObjectId,
      0,
      0,
      0,
      MapLayerId,
      Player2InterstitialSpriteId
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
      if shadowPixels != state.shadowPixels:
        result.addSprite(
          Player2ShadowSpriteId,
          ScreenWidth,
          ScreenHeight,
          shadowPixels
        )
        nextState.shadowPixels = shadowPixels
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
          currentIds.add(Player2ProgressObjectId)
          result.addSprite(
            Player2ProgressSpriteId,
            TaskBarWidth,
            1,
            buildTaskProgressSprite(
              player.taskProgress,
              sim.config.taskCompleteTicks
            )
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
    result.addSprite(
      Player2RemainingSpriteId,
      remaining.width,
      remaining.height,
      remaining.pixels
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
    result = sim.buildSpriteProtocolInit()
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
      sim.buildInterstitialFrame()
    )
    currentIds.add(InterstitialObjectId)
    result.addSprite(
      InterstitialSpriteId,
      ScreenWidth,
      ScreenHeight,
      interstitial
    )
    result.addObject(
      InterstitialObjectId,
      0,
      0,
      0,
      InterstitialLayerId,
      InterstitialSpriteId
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
    result.addSprite(
      SelectedTextSpriteId,
      text.width,
      text.height,
      text.pixels
    )
    result.addObject(
      SelectedTextObjectId,
      2,
      2,
      0,
      TopLeftLayerId,
      SelectedTextSpriteId
    )
    result.addSprite(
      SelectedViewportSpriteId,
      ScreenWidth,
      ScreenHeight,
      viewport
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
  result.addSprite(
    ReplayTickSpriteId,
    tickText.width,
    tickText.height,
    tickText.pixels
  )
  result.addObject(
    ReplayTickObjectId,
    max(0, (ScreenWidth - tickText.width) div 2),
    0,
    0,
    ReplayCenterBottomLayerId,
    ReplayTickSpriteId
  )
  result.addSprite(
    ReplayScrubberSpriteId,
    scrubber.width,
    scrubber.height,
    scrubber.pixels
  )
  result.addObject(
    ReplayScrubberObjectId,
    max(0, (ScreenWidth - ReplayScrubberWidth) div 2),
    ReplayScrubberY,
    0,
    ReplayCenterBottomLayerId,
    ReplayScrubberSpriteId
  )
  result.addSprite(
    ReplayControlsSpriteId,
    controls.width,
    controls.height,
    controls.pixels
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

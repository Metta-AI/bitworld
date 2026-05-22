import std/[algorithm, os, strutils]
import supersnappy
import protocol, sim
import ../common/pixelfonts
import ../common/server

const
  ReplayScrubberSpriteId = 404
  ReplayScrubberObjectId = 4004
  ReplayScrubberWidth = 84
  ReplayScrubberHeight = 5
  ReplayScrubberTrackY = 2
  ReplayScrubberY = 8
  PlayerSelectPadding = 4
  TransportIconSize = 6
  TransportIconHeight = 6
  TransportIconCount = 5
  TransportButtonGap = 2
  TransportButtonStride = TransportIconSize + TransportButtonGap
  TransportSpeedX = 0
  TransportSpeedY = 8
  TransportWidth = 108
  TransportHeight = 14
  TransportX = 2
  TransportY = 1
  BubbleFillColor = 1'u8
  BubbleBorderColor = 7'u8
  BubbleTextColor = 7'u8
  BubblePad = 2
  BubblePointerHeight = 3
  MobLeftSpriteId = 313
  TrollLeftSpriteId = 314
  BossLeftSpriteId = 315
  CoinsHudSpriteId = PlayerHudSpriteId
  LivesHudSpriteId = PlayerHudSpriteId + 1
  StatusHudSpriteId = PlayerHudSpriteId + 2
  RoleLabelSpriteBase = PlayerHudSpriteId + 40
  StatusBadgeSpriteBase = 840
  LandmarkPromptSpriteBase = 860
  LandmarkShelterPromptSpriteId =
    LandmarkPromptSpriteBase + ord(high(LandmarkKind)) + 1
  LandmarkFortPromptSpriteId = LandmarkShelterPromptSpriteId + 1
  LandmarkMealPromptSpriteId = LandmarkFortPromptSpriteId + 1
  LandmarkFortMealPromptSpriteId = LandmarkMealPromptSpriteId + 1
  LandmarkWaystationPromptSpriteBase = LandmarkFortMealPromptSpriteId + 1
  WeatherOverlaySpriteBase = 900
  CoinsHudObjectId = PlayerHudObjectId
  LivesHudObjectId = PlayerHudObjectId + 1
  StatusHudObjectId = PlayerHudObjectId + 2
  RoleLabelObjectBase = PlayerHudObjectId + 100
  HudGap = 1
  HealthSprite5Base = 700
  HealthSprite10Base = 710
  PlayerHealthObjectBase = 10000
  MobHealthObjectBase = 11000
  CarryObjectBase = 12000
  StatusBadgeObjectBase = 13000
  LandmarkPromptObjectBase = 14000
  MobThreatBadgeObjectBase = 15000
  WeatherOverlayObjectBase = 16000
  StatusBadgeSlots = 7
  WeatherOverlaySlots = 56
  HealthBarWidth = 18
  HealthBarHeight = 5
  HealthBarPad = 1
  HealthBarGap = 3
  UiColors = [
    (r: 0'u8, g: 0'u8, b: 0'u8, a: 255'u8),
    (r: 20'u8, g: 24'u8, b: 30'u8, a: 235'u8),
    (r: 246'u8, g: 248'u8, b: 252'u8, a: 255'u8),
    (r: 224'u8, g: 64'u8, b: 79'u8, a: 255'u8),
    (r: 84'u8, g: 141'u8, b: 255'u8, a: 255'u8),
    (r: 150'u8, g: 109'u8, b: 255'u8, a: 255'u8),
    (r: 158'u8, g: 119'u8, b: 82'u8, a: 255'u8),
    (r: 255'u8, g: 255'u8, b: 255'u8, a: 255'u8),
    (r: 255'u8, g: 222'u8, b: 74'u8, a: 255'u8),
    (r: 255'u8, g: 167'u8, b: 62'u8, a: 255'u8),
    (r: 86'u8, g: 210'u8, b: 122'u8, a: 255'u8),
    (r: 68'u8, g: 205'u8, b: 214'u8, a: 255'u8),
    (r: 91'u8, g: 101'u8, b: 114'u8, a: 255'u8),
    (r: 235'u8, g: 104'u8, b: 180'u8, a: 255'u8),
    (r: 188'u8, g: 231'u8, b: 132'u8, a: 255'u8),
    (r: 246'u8, g: 248'u8, b: 252'u8, a: 255'u8)
  ]
  ActorOutlineColor = (r: 0'u8, g: 0'u8, b: 0'u8, a: 255'u8)
  SelectedOutlineColor = (r: 255'u8, g: 222'u8, b: 74'u8, a: 255'u8)
  HealthFrameColor = (r: 0'u8, g: 0'u8, b: 0'u8, a: 255'u8)
  HealthBackColor = (r: 32'u8, g: 36'u8, b: 42'u8, a: 235'u8)
  HealthGreenColor = (r: 86'u8, g: 210'u8, b: 122'u8, a: 255'u8)
  HealthYellowColor = (r: 255'u8, g: 222'u8, b: 74'u8, a: 255'u8)
  HealthRedColor = (r: 224'u8, g: 64'u8, b: 79'u8, a: 255'u8)
  PlayerTintColors = [
    (r: 229'u8, g: 64'u8, b: 88'u8, a: 255'u8),
    (r: 252'u8, g: 175'u8, b: 62'u8, a: 255'u8),
    (r: 255'u8, g: 220'u8, b: 90'u8, a: 255'u8),
    (r: 70'u8, g: 199'u8, b: 111'u8, a: 255'u8),
    (r: 67'u8, g: 169'u8, b: 225'u8, a: 255'u8),
    (r: 155'u8, g: 118'u8, b: 255'u8, a: 255'u8),
    (r: 235'u8, g: 98'u8, b: 178'u8, a: 255'u8),
    (r: 241'u8, g: 244'u8, b: 248'u8, a: 255'u8)
  ]
  PlayerTintNames = [
    "red",
    "orange",
    "yellow",
    "green",
    "blue",
    "purple",
    "pink",
    "white"
  ]

var TransportSheet: Sprite

type
  StatusBadgeKind = enum
    StatusPoison
    StatusSlow
    StatusChill
    StatusAlone
    StatusHelp
    StatusDown
    StatusPingRegroup
    StatusPingHelp
    StatusPingObjective
    StatusPingCamp
    StatusPingFood
    StatusPingRescue
    StatusPingLair

  GlobalViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    mouseX*: int
    mouseY*: int
    mouseLayer*: int
    mouseDown*: bool
    selectedPlayerId*: int
    clickPending*: bool
    scrubbingReplay*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]

  PlayerViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    hudCoins*: int
    hudLives*: int
    hudStatus*: string

  WorldSpriteObject = object
    id, x, y, spriteId, sortY: int

proc initGlobalViewerState*(): GlobalViewerState =
  ## Returns the default state for one global protocol viewer.
  result.mouseLayer = MapLayerId
  result.selectedPlayerId = -1
  result.replaySeekTick = -1
  result.replayCommands = @[]

proc initPlayerViewerState*(): PlayerViewerState =
  ## Returns the default state for one sprite player viewer.
  result.hudCoins = -1
  result.hudLives = -1
  result.hudStatus = ""

proc putRgbaPixel(pixels: var seq[uint8], pixelIndex: int, color: uint8) =
  ## Writes one generated UI color as a global protocol RGBA pixel.
  let
    rgba = UiColors[color and 0x0f]
    offset = pixelIndex * 4
  pixels[offset] = rgba.r
  pixels[offset + 1] = rgba.g
  pixels[offset + 2] = rgba.b
  pixels[offset + 3] = rgba.a

proc putRgbaPixel(
  pixels: var seq[uint8],
  pixelIndex: int,
  color: tuple[r, g, b, a: uint8]
) =
  ## Writes one true-color global protocol RGBA pixel.
  let offset = pixelIndex * 4
  pixels[offset] = color.r
  pixels[offset + 1] = color.g
  pixels[offset + 2] = color.b
  pixels[offset + 3] = color.a

proc newRgbaPixels(width, height: int): seq[uint8] =
  ## Allocates a transparent RGBA sprite buffer.
  newSeq[uint8](width * height * 4)

proc copyRgbaPixel(
  target: var seq[uint8],
  targetPixelIndex: int,
  source: openArray[uint8],
  sourceByteIndex: int
) =
  ## Copies one true-color pixel into a protocol sprite.
  let targetByteIndex = targetPixelIndex * 4
  target[targetByteIndex] = source[sourceByteIndex]
  target[targetByteIndex + 1] = source[sourceByteIndex + 1]
  target[targetByteIndex + 2] = source[sourceByteIndex + 2]
  target[targetByteIndex + 3] = source[sourceByteIndex + 3]

proc blendRgbaPixel(
  target: var seq[uint8],
  targetPixelIndex: int,
  source: openArray[uint8],
  sourceByteIndex: int
) =
  ## Blends one straight RGBA pixel into a protocol sprite.
  let
    targetByteIndex = targetPixelIndex * 4
    sourceAlpha = int(source[sourceByteIndex + 3])
  if sourceAlpha == 0:
    return
  if sourceAlpha == 255 or target[targetByteIndex + 3] == 0'u8:
    target.copyRgbaPixel(targetPixelIndex, source, sourceByteIndex)
    return
  let
    targetAlpha = int(target[targetByteIndex + 3])
    outAlpha = sourceAlpha + targetAlpha * (255 - sourceAlpha) div 255
  if outAlpha == 0:
    return
  for channel in 0 ..< 3:
    let value = (
      int(source[sourceByteIndex + channel]) * sourceAlpha +
      int(target[targetByteIndex + channel]) * targetAlpha *
        (255 - sourceAlpha) div 255
    ) div outAlpha
    target[targetByteIndex + channel] = value.uint8
  target[targetByteIndex + 3] = outAlpha.uint8

proc playerTintColor(
  playerIndex: int
): tuple[r, g, b, a: uint8] =
  ## Returns the true-color tint for one player slot.
  PlayerTintColors[playerIndex mod PlayerTintColors.len]

proc playerTintName(playerIndex: int): string =
  ## Returns the label color name for one player slot.
  PlayerTintNames[playerIndex mod PlayerTintNames.len]

proc transportSheet(): Sprite =
  ## Returns the cached transport icon sheet.
  if TransportSheet.width == 0:
    TransportSheet = readRequiredSprite(clientDataDir() / "transport.png")
  TransportSheet

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

proc objectVisible(
  x,
  y,
  width,
  height,
  viewportWidth,
  viewportHeight: int
): bool =
  ## Returns true when an object intersects the current viewport.
  if width <= 0 or height <= 0:
    return false
  x < viewportWidth and
    y < viewportHeight and
    x + width > 0 and
    y + height > 0

proc addWorldSpriteObject(
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  objectId,
  x,
  y,
  spriteId,
  spriteWidth,
  spriteHeight,
  viewportWidth,
  viewportHeight: int,
  sortYOverride = high(int)
) =
  ## Queues one world sprite object for game-side depth sorting.
  if not objectVisible(
    x,
    y,
    spriteWidth,
    spriteHeight,
    viewportWidth,
    viewportHeight
  ):
    return
  let objectSortY =
    if sortYOverride == high(int):
      y + spriteHeight
    else:
      sortYOverride
  currentIds.add(objectId)
  objects.add(WorldSpriteObject(
    id: objectId,
    x: x,
    y: y,
    spriteId: spriteId,
    sortY: objectSortY
  ))

proc flushWorldSpriteObjects(
  packet: var seq[uint8],
  objects: var seq[WorldSpriteObject]
) =
  ## Sends queued world objects with z ranks in draw order.
  objects.sort(
    proc(a, b: WorldSpriteObject): int =
      result = cmp(a.sortY, b.sortY)
      if result == 0:
        result = cmp(b.x, a.x)
      if result == 0:
        result = cmp(a.id, b.id)
  )
  for i, item in objects:
    packet.addObject(
      item.id,
      item.x,
      item.y,
      i,
      MapLayerId,
      item.spriteId
    )

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
  ## Applies sprite player input messages.
  discard state
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

proc isSolid(sprite: RgbaSprite, x, y: int): bool =
  ## Returns true when a true-color sprite coordinate is opaque.
  if x < 0 or x >= sprite.width or y < 0 or y >= sprite.height:
    return false
  sprite.pixels[sprite.rgbaSpriteIndex(x, y) + 3] != 0'u8

proc buildSpriteProtocolActorSprite(
  sprite: RgbaSprite,
  mask: Sprite,
  tint: tuple[r, g, b, a: uint8],
  selected = false,
  flipX = false
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds an outlined actor sprite with masked recoloring.
  let outline =
    if selected:
      SelectedOutlineColor
    else:
      ActorOutlineColor
  result.width = sprite.width + 2
  result.height = sprite.height + 2
  result.pixels = newRgbaPixels(result.width, result.height)
  let outWidth = result.width

  proc outIndex(x, y: int): int =
    y * outWidth + x

  proc sourceColumn(x: int): int =
    if flipX:
      sprite.width - 1 - x
    else:
      x

  proc drawnSolid(x, y: int): bool =
    if x < 0 or x >= sprite.width or y < 0 or y >= sprite.height:
      return false
    sprite.isSolid(sourceColumn(x), y)

  for y in -1 .. sprite.height:
    for x in -1 .. sprite.width:
      if drawnSolid(x, y):
        continue
      let adjacent =
        drawnSolid(x - 1, y) or
        drawnSolid(x + 1, y) or
        drawnSolid(x, y - 1) or
        drawnSolid(x, y + 1)
      if adjacent:
        result.pixels.putRgbaPixel(outIndex(x + 1, y + 1), outline)

  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let srcX = sourceColumn(x)
      let sourceIndex = sprite.rgbaSpriteIndex(srcX, y)
      if sprite.pixels[sourceIndex + 3] == 0'u8:
        continue
      if srcX < mask.width and y < mask.height and
          mask.pixels[mask.spriteIndex(srcX, y)] != TransparentColorIndex:
        let alpha = min(
          int(tint.a),
          int(sprite.pixels[sourceIndex + 3])
        ).uint8
        result.pixels.putRgbaPixel(
          outIndex(x + 1, y + 1),
          (r: tint.r, g: tint.g, b: tint.b, a: alpha)
        )
      else:
        result.pixels.copyRgbaPixel(
          outIndex(x + 1, y + 1),
          sprite.pixels,
          sourceIndex
        )

proc buildSpriteProtocolRawSprite(
  sprite: RgbaSprite,
  flipX = false
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a raw global protocol sprite from a true-color sprite.
  result.width = sprite.width
  result.height = sprite.height
  result.pixels = newSeq[uint8](sprite.pixels.len)
  if not flipX:
    for i in 0 ..< sprite.pixels.len:
      result.pixels[i] = sprite.pixels[i]
    return
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let
        sourceX = sprite.width - 1 - x
        sourceIndex = sprite.rgbaSpriteIndex(sourceX, y)
      result.pixels.copyRgbaPixel(
        y * result.width + x,
        sprite.pixels,
        sourceIndex
      )

proc tintSpritePixels(
  pixels: openArray[uint8],
  tint: tuple[r, g, b, a: uint8],
  strength = 88
): seq[uint8] =
  result = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    result[i] = pixels[i]
  for i in countup(0, result.len - 1, 4):
    if result[i + 3] == 0'u8:
      continue
    result[i] =
      ((int(result[i]) * (100 - strength) + int(tint.r) * strength) div 100).uint8
    result[i + 1] =
      ((int(result[i + 1]) * (100 - strength) + int(tint.g) * strength) div 100).uint8
    result[i + 2] =
      ((int(result[i + 2]) * (100 - strength) + int(tint.b) * strength) div 100).uint8

proc facedSize(sprite: RgbaSprite, facing: Facing): tuple[width, height: int] =
  ## Returns the rendered size for a facing rotation.
  case facing
  of FaceUp, FaceDown:
    (sprite.width, sprite.height)
  of FaceLeft, FaceRight:
    (sprite.height, sprite.width)

proc sourceForFacing(
  sprite: RgbaSprite,
  x, y: int,
  facing: Facing
): tuple[x, y: int] =
  ## Converts a rotated sprite coordinate to a source coordinate.
  case facing
  of FaceDown:
    (x, y)
  of FaceUp:
    (sprite.width - 1 - x, sprite.height - 1 - y)
  of FaceLeft:
    (sprite.width - 1 - y, x)
  of FaceRight:
    (y, sprite.height - 1 - x)

proc buildSpriteProtocolFacedRawSprite(
  sprite: RgbaSprite,
  facing: Facing
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a true-color sprite rotated for one facing.
  let size = sprite.facedSize(facing)
  result.width = size.width
  result.height = size.height
  result.pixels = newRgbaPixels(result.width, result.height)
  for y in 0 ..< size.height:
    for x in 0 ..< size.width:
      let
        source = sprite.sourceForFacing(x, y, facing)
        sourceIndex = sprite.rgbaSpriteIndex(source.x, source.y)
      if sprite.pixels[sourceIndex + 3] != 0'u8:
        result.pixels.copyRgbaPixel(
          y * result.width + x,
          sprite.pixels,
          sourceIndex
        )

proc blitMapSprite(
  pixels: var seq[uint8],
  sprite: RgbaSprite,
  baseX, baseY: int
) =
  ## Blits one sprite into the global map sprite.
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let
        px = baseX + x
        py = baseY + y
      if px < 0 or py < 0 or
          px >= WorldWidthPixels or py >= WorldHeightPixels:
        continue
      let sourceIndex = sprite.rgbaSpriteIndex(x, y)
      if sprite.pixels[sourceIndex + 3] != 0'u8:
        pixels.blendRgbaPixel(
          py * WorldWidthPixels + px,
          sprite.pixels,
          sourceIndex
        )

proc fillMapTile(
  pixels: var seq[uint8],
  baseX,
  baseY: int,
  color: tuple[r, g, b, a: uint8]
) =
  ## Fills the opaque biome backing under borrowed transparent ground art.
  for y in 0 ..< WorldTileSize:
    for x in 0 ..< WorldTileSize:
      let
        px = baseX + x
        py = baseY + y
      if px < 0 or py < 0 or
          px >= WorldWidthPixels or py >= WorldHeightPixels:
        continue
      pixels.putRgbaPixel(py * WorldWidthPixels + px, color)

proc shadeForElevation(
  color: tuple[r, g, b, a: uint8],
  elevation: int
): tuple[r, g, b, a: uint8] =
  ## Makes deterministic elevation visible under transparent terrain art.
  let shade = clamp(elevation, 0, 5) * 12
  (
    r: clamp(int(color.r) + shade, 0, 255).uint8,
    g: clamp(int(color.g) + shade, 0, 255).uint8,
    b: clamp(int(color.b) + shade, 0, 255).uint8,
    a: color.a
  )

proc buildSpriteProtocolMapSprite(sim: SimServer): seq[uint8] =
  ## Builds a full world map sprite from the described terrain cells.
  result = newRgbaPixels(WorldWidthPixels, WorldHeightPixels)
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      let
        baseX = tx * WorldTileSize
        baseY = ty * WorldTileSize
      result.fillMapTile(
        baseX,
        baseY,
        sim.tileBiomeKind(tx, ty).biomeBackgroundRgbaColor().shadeForElevation(
          sim.tileElevation(tx, ty)
        )
      )
      result.blitMapSprite(
        sim.groundRgbaSprite(sim.tileGroundKind(tx, ty)),
        baseX,
        baseY
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
  glyph: PixelGlyph,
  baseX, baseY: int,
  color: uint8
) =
  ## Blits a single-color glyph into protocol pixels.
  for y in 0 ..< glyph.height:
    for x in 0 ..< glyph.width:
      if not glyph.glyphPixel(x, y):
        continue
      target.putTextSpritePixel(
        targetWidth,
        targetHeight,
        baseX + x,
        baseY + y,
        color
      )

proc blitSmallText(
  sim: SimServer,
  target: var seq[uint8],
  targetWidth, targetHeight: int,
  text: string,
  baseX, baseY: int,
  color: uint8
) =
  ## Blits small text into protocol pixels.
  var x = baseX
  for ch in text:
    let glyph = sim.textFont.glyphAt(ch)
    target.blitGlyph(
      targetWidth,
      targetHeight,
      glyph,
      x,
      baseY,
      color
    )
    x += sim.textFont.glyphAdvance(ch)

proc buildSpriteProtocolTextSprite(
  sim: SimServer,
  lines: openArray[string],
  color: uint8
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a transparent multi-line text sprite.
  let lineHeight = sim.textFont.lineHeight()
  result.width = 1
  for line in lines:
    result.width = max(result.width, sim.textFont.textWidth(line))
  result.height = max(1, lines.len * lineHeight - sim.textFont.spacing)
  result.pixels = newRgbaPixels(result.width, result.height)
  for lineIndex, line in lines:
    let baseY = lineIndex * lineHeight
    var baseX = 0
    for ch in line:
      let glyph = sim.textFont.glyphAt(ch)
      result.pixels.blitGlyph(
        result.width,
        result.height,
        glyph,
        baseX,
        baseY,
        color
      )
      baseX += sim.textFont.glyphAdvance(ch)

proc lineCountForText(text: string): int =
  ## Returns the wrapped line count for one chat message.
  max(1, (text.len + MessageCharsPerLine - 1) div MessageCharsPerLine)

proc sliceMessageLine(text: string, lineIndex: int): string =
  ## Returns one fixed-width chat line.
  let startIndex = lineIndex * MessageCharsPerLine
  if startIndex >= text.len:
    return ""
  let endIndex = min(text.len, startIndex + MessageCharsPerLine)
  text[startIndex ..< endIndex]

proc fillRect(
  pixels: var seq[uint8],
  width, x, y, w, h: int,
  color: uint8
) =
  ## Fills a protocol pixel rectangle.
  for py in y ..< y + h:
    for px in x ..< x + w:
      pixels.putRgbaPixel(py * width + px, color)

proc strokeRect(
  pixels: var seq[uint8],
  width, x, y, w, h: int,
  color: uint8
) =
  ## Strokes a protocol pixel rectangle.
  for px in x ..< x + w:
    pixels.putRgbaPixel(y * width + px, color)
    pixels.putRgbaPixel((y + h - 1) * width + px, color)
  for py in y ..< y + h:
    pixels.putRgbaPixel(py * width + x, color)
    pixels.putRgbaPixel(py * width + x + w - 1, color)

proc fillRgbaRect(
  pixels: var seq[uint8],
  width, x, y, w, h: int,
  color: tuple[r, g, b, a: uint8]
) =
  ## Fills a true-color protocol pixel rectangle.
  for py in y ..< y + h:
    for px in x ..< x + w:
      pixels.putRgbaPixel(py * width + px, color)

proc strokeRgbaRect(
  pixels: var seq[uint8],
  width, x, y, w, h: int,
  color: tuple[r, g, b, a: uint8]
) =
  ## Strokes a true-color protocol pixel rectangle.
  for px in x ..< x + w:
    pixels.putRgbaPixel(y * width + px, color)
    pixels.putRgbaPixel((y + h - 1) * width + px, color)
  for py in y ..< y + h:
    pixels.putRgbaPixel(py * width + x, color)
    pixels.putRgbaPixel(py * width + x + w - 1, color)

proc healthSpriteMaximum(maximum: int): int =
  ## Returns the shared health sprite denominator for one actor.
  if maximum <= MaxPlayerLives:
    MaxPlayerLives
  else:
    BossHp

proc healthSpriteId(current, maximum: int): int =
  ## Returns the shared health sprite id for one health value.
  let spriteMaximum = maximum.healthSpriteMaximum()
  if spriteMaximum == MaxPlayerLives:
    HealthSprite5Base + clamp(current, 0, MaxPlayerLives)
  else:
    HealthSprite10Base + clamp(current, 0, BossHp)

proc healthSpriteLabel(current, maximum: int): string =
  ## Returns the label for one generated health sprite.
  "health " & $current & "/" & $maximum

proc healthFillColor(
  current, maximum: int
): tuple[r, g, b, a: uint8] =
  ## Returns the fill color for one health value.
  if maximum <= 0:
    return HealthRedColor
  let ratio = current * 100 div maximum
  if ratio > 50:
    HealthGreenColor
  elif ratio > 20:
    HealthYellowColor
  else:
    HealthRedColor

proc buildSpriteProtocolHealthSprite(
  current, maximum: int
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds one small true-color health bar sprite.
  let
    value = clamp(current, 0, maximum)
    innerWidth = HealthBarWidth - HealthBarPad * 2
    innerHeight = HealthBarHeight - HealthBarPad * 2
  result.width = HealthBarWidth
  result.height = HealthBarHeight
  result.pixels = newRgbaPixels(result.width, result.height)
  result.pixels.strokeRgbaRect(
    result.width,
    0,
    0,
    result.width,
    result.height,
    HealthFrameColor
  )
  result.pixels.fillRgbaRect(
    result.width,
    HealthBarPad,
    HealthBarPad,
    innerWidth,
    innerHeight,
    HealthBackColor
  )
  if maximum <= 0 or value <= 0:
    return
  let fillWidth = max(1, value * innerWidth div maximum)
  result.pixels.fillRgbaRect(
    result.width,
    HealthBarPad,
    HealthBarPad,
    fillWidth,
    innerHeight,
    healthFillColor(value, maximum)
  )

proc blitAsciiText(
  sim: SimServer,
  target: var seq[uint8],
  targetWidth, targetHeight: int,
  text: string,
  baseX, baseY: int,
  color: uint8
) =
  ## Blits Tiny5 ASCII text into protocol pixels.
  var offsetX = 0
  for ch in text:
    let glyph = sim.textFont.glyphAt(ch)
    target.blitGlyph(
      targetWidth,
      targetHeight,
      glyph,
      baseX + offsetX,
      baseY,
      color
    )
    offsetX += sim.textFont.glyphAdvance(ch)

proc buildSpriteProtocolBubbleSprite(
  sim: SimServer,
  text: string
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds one speech bubble sprite.
  let lineCount = text.lineCountForText()
  var longestLineWidth = sim.textFont.glyphAdvance('?')
  for lineIndex in 0 ..< lineCount:
    longestLineWidth = max(
      longestLineWidth,
      sim.textFont.textWidth(text.sliceMessageLine(lineIndex))
    )
  result.width = longestLineWidth + BubblePad * 2
  let lineHeight = sim.textFont.lineHeight()
  result.height =
    lineCount * lineHeight - sim.textFont.spacing +
    BubblePad * 2 + BubblePointerHeight
  result.pixels = newRgbaPixels(result.width, result.height)
  let bodyHeight = result.height - BubblePointerHeight
  result.pixels.fillRect(
    result.width,
    0,
    0,
    result.width,
    bodyHeight,
    BubbleFillColor
  )
  result.pixels.strokeRect(
    result.width,
    0,
    0,
    result.width,
    bodyHeight,
    BubbleBorderColor
  )
  let pointerX = result.width div 2
  for y in 0 ..< BubblePointerHeight:
    let span = BubblePointerHeight - y
    for x in pointerX - span .. pointerX + span:
      if x >= 0 and x < result.width:
        result.pixels.putRgbaPixel(
          (bodyHeight + y) * result.width + x,
          BubbleBorderColor
        )
  for lineIndex in 0 ..< lineCount:
    sim.blitAsciiText(
      result.pixels,
      result.width,
      result.height,
      text.sliceMessageLine(lineIndex),
      BubblePad,
      BubblePad + lineIndex * lineHeight,
      BubbleTextColor
    )

proc playerIdentity(player: Actor): string =
  ## Returns a sprite text friendly player identity.
  player.address.replace(":", " ")

proc buildReplayScrubberSprite(
  tick, maxTick: int
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
  for x in 0 .. knobX:
    result.pixels.putRgbaPixel(
      ReplayScrubberTrackY * ReplayScrubberWidth + x,
      10'u8
    )
  for y in 0 ..< ReplayScrubberHeight:
    result.pixels.putRgbaPixel(y * ReplayScrubberWidth + knobX, 2'u8)
  if knobX > 0:
    result.pixels.putRgbaPixel(
      ReplayScrubberTrackY * ReplayScrubberWidth + knobX - 1,
      2'u8
    )
  if knobX < ReplayScrubberWidth - 1:
    result.pixels.putRgbaPixel(
      ReplayScrubberTrackY * ReplayScrubberWidth + knobX + 1,
      2'u8
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
  replayLooping: bool
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
      if i == 3:
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

  let speedTexts = ["1X", "2X", "4X", "8X"]
  var x = TransportSpeedX
  for i in 0 ..< speedTexts.len:
    let color = if (1 shl i) == replaySpeed: 10'u8 else: 1'u8
    sim.blitSmallText(
      result.pixels,
      TransportWidth,
      TransportHeight,
      speedTexts[i],
      x,
      TransportSpeedY,
      color
    )
    x += 16

proc playerObjectId(player: Actor): int =
  ## Returns the stable global protocol object id for a player.
  PlayerObjectBase + player.id

proc playerSpriteId(
  playerIndex: int,
  form: PlayerForm,
  selected: bool,
  facing: Facing
): int =
  ## Returns the sprite id for one colored adventurer facing.
  let
    colorIndex = playerIndex mod PlayerTintColors.len
    base = if selected: SelectedPlayerSpriteBase else: PlayerSpriteBase
  base + colorIndex * 8 + ord(form) * 4 + ord(facing)

proc playerSpriteLabel(
  playerIndex: int,
  form: PlayerForm,
  selected: bool
): string =
  ## Returns the stable label for one colored adventurer sprite.
  result =
    if selected:
      "selected player "
    else:
      "player "
  result.add(playerIndex.playerTintName())
  result.add($(ord(form) + 1))

proc roleTintSlot(playerIndex: int, role: PlayerRole): int =
  ## Returns an obvious role color while keeping unarmed players identity-tinted.
  case role
  of RoleTank:
    4 # blue
  of RoleDps:
    0 # red
  of RoleHealer:
    3 # green
  of RoleUnarmed:
    playerIndex

proc roleGearLabel(kind: PickupKind): string =
  case kind
  of PickupTankGear:
    "TANK"
  of PickupDpsGear:
    "DPS"
  of PickupHealerGear:
    "HEAL"
  else:
    ""

proc roleGearSpriteId(kind: PickupKind): int =
  RoleLabelSpriteBase + ord(kind)

proc roleGearObjectId(pickupIndex: int): int =
  RoleLabelObjectBase + pickupIndex

proc statusBadgeSpriteId(kind: StatusBadgeKind): int =
  StatusBadgeSpriteBase + ord(kind)

proc statusBadgeObjectId(player: Actor, index: int): int =
  StatusBadgeObjectBase + player.id * StatusBadgeSlots + index

proc mobThreatBadgeObjectId(mobIndex, badgeIndex: int): int =
  MobThreatBadgeObjectBase + mobIndex * StatusBadgeSlots + badgeIndex

proc weatherOverlaySpriteId(weather: WeatherKind): int =
  WeatherOverlaySpriteBase + ord(weather)

proc weatherOverlayObjectId(index: int): int =
  WeatherOverlayObjectBase + index

proc weatherOverlayLabel(weather: WeatherKind): string =
  "weather " & weather.weatherLabel()

proc weatherOverlayColor(
  weather: WeatherKind
): tuple[r, g, b, a: uint8] =
  case weather
  of WeatherRain:
    (r: 130'u8, g: 183'u8, b: 235'u8, a: 190'u8)
  of WeatherSnow:
    (r: 245'u8, g: 250'u8, b: 255'u8, a: 220'u8)
  of WeatherDust:
    (r: 222'u8, g: 172'u8, b: 92'u8, a: 165'u8)
  of WeatherFog:
    (r: 186'u8, g: 196'u8, b: 205'u8, a: 112'u8)
  of WeatherClear:
    (r: 0'u8, g: 0'u8, b: 0'u8, a: 0'u8)

proc buildWeatherOverlaySprite(
  weather: WeatherKind
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a tiny translucent weather particle for sprite-protocol views.
  case weather
  of WeatherRain:
    result.width = 4
    result.height = 9
    result.pixels = newRgbaPixels(result.width, result.height)
    let color = weather.weatherOverlayColor()
    for y in 0 ..< result.height:
      let x = min(result.width - 1, y div 3)
      result.pixels.putRgbaPixel(y * result.width + x, color)
  of WeatherSnow:
    result.width = 5
    result.height = 5
    result.pixels = newRgbaPixels(result.width, result.height)
    let color = weather.weatherOverlayColor()
    for pos in [(2, 1), (1, 2), (2, 2), (3, 2), (2, 3)]:
      result.pixels.putRgbaPixel(pos[1] * result.width + pos[0], color)
  of WeatherDust:
    result.width = 7
    result.height = 4
    result.pixels = newRgbaPixels(result.width, result.height)
    let color = weather.weatherOverlayColor()
    for pos in [(1, 1), (2, 1), (4, 2), (5, 2), (3, 1)]:
      result.pixels.putRgbaPixel(pos[1] * result.width + pos[0], color)
  of WeatherFog:
    result.width = 32
    result.height = 8
    result.pixels = newRgbaPixels(result.width, result.height)
    let color = weather.weatherOverlayColor()
    for y in 2 .. 5:
      for x in 0 ..< result.width:
        if (x + y) mod 3 != 0:
          result.pixels.putRgbaPixel(y * result.width + x, color)
  of WeatherClear:
    result.width = 1
    result.height = 1
    result.pixels = newRgbaPixels(result.width, result.height)

proc weatherOverlaySize(weather: WeatherKind): tuple[width, height: int] =
  case weather
  of WeatherRain:
    (width: 4, height: 9)
  of WeatherSnow:
    (width: 5, height: 5)
  of WeatherDust:
    (width: 7, height: 4)
  of WeatherFog:
    (width: 32, height: 8)
  of WeatherClear:
    (width: 1, height: 1)

proc statusBadgeLabel(kind: StatusBadgeKind): string =
  case kind
  of StatusPoison: "POI"
  of StatusSlow: "SLW"
  of StatusChill: "CHL"
  of StatusAlone: "REG"
  of StatusHelp: "HELP"
  of StatusDown: "DOWN"
  of StatusPingRegroup: "PING REG"
  of StatusPingHelp: "PING HELP"
  of StatusPingObjective: "PING OBJ"
  of StatusPingCamp: "PING CAMP"
  of StatusPingFood: "PING FOOD"
  of StatusPingRescue: "PING RES"
  of StatusPingLair: "PING LAIR"

proc statusBadgeColor(kind: StatusBadgeKind): uint8 =
  case kind
  of StatusPoison: 13'u8
  of StatusSlow: 10'u8
  of StatusChill: 11'u8
  of StatusAlone: 8'u8
  of StatusHelp: 3'u8
  of StatusDown: 3'u8
  of StatusPingRegroup: 8'u8
  of StatusPingHelp: 3'u8
  of StatusPingObjective: 14'u8
  of StatusPingCamp: 10'u8
  of StatusPingFood: 6'u8
  of StatusPingRescue: 2'u8
  of StatusPingLair: 13'u8

proc statusBadgeSpriteLabel(kind: StatusBadgeKind): string =
  case kind
  of StatusPoison: "status poison"
  of StatusSlow: "status slow"
  of StatusChill: "status chill"
  of StatusAlone: "status alone"
  of StatusHelp: "status help"
  of StatusDown: "status down"
  of StatusPingRegroup: "status ping regroup"
  of StatusPingHelp: "status ping help"
  of StatusPingObjective: "status ping objective"
  of StatusPingCamp: "status ping camp"
  of StatusPingFood: "status ping food"
  of StatusPingRescue: "status ping rescue"
  of StatusPingLair: "status ping lair"

proc pingStatusBadge(kind: PlayerPingKind): StatusBadgeKind =
  case kind
  of PingRegroup: StatusPingRegroup
  of PingHelp: StatusPingHelp
  of PingObjective: StatusPingObjective
  of PingCamp: StatusPingCamp
  of PingFood: StatusPingFood
  of PingRescue: StatusPingRescue
  of PingLair: StatusPingLair
  of PingNone: StatusPingRegroup

proc threatBadges(species: MobSpecies): seq[StatusBadgeKind] =
  if species.speciesAppliesPoison():
    result.add(StatusPoison)
  if species.speciesAppliesSlow():
    result.add(StatusSlow)
  if species.speciesAppliesChill():
    result.add(StatusChill)
  if species.speciesPunishesIsolation():
    result.add(StatusAlone)

proc swooshSpriteId(form: PlayerForm, facing: Facing): int =
  ## Returns the sprite id for one adventurer attack swish facing.
  SwooshSpriteBase + ord(form) * 4 + ord(facing)

proc terrainSpriteId(kind: TerrainKind): int =
  ## Returns the sprite id for one terrain prop kind.
  TerrainSpriteBase + ord(kind)

proc landmarkSpriteId(kind: LandmarkKind): int =
  ## Returns the sprite id for one landmark kind.
  LandmarkSpriteBase + ord(kind)

proc mobSpeciesSpriteId(species: MobSpecies, flipLeft: bool): int =
  ## Returns the generated sprite id for one biome monster species.
  MobSpeciesSpriteBase + (ord(species) - 1) * 2 + (if flipLeft: 1 else: 0)

proc pickupSpriteId(kind: PickupKind): int =
  ## Returns the protocol sprite id for one pickup kind.
  case kind
  of PickupCoin, PickupTankGear, PickupDpsGear:
    CoinSpriteId
  of PickupHeart, PickupHealerGear:
    HeartSpriteId
  of PickupWood, PickupFood, PickupStone, PickupGold:
    kind.carryForPickup().landmarkForCarry().landmarkSpriteId()

proc carryObjectId(player: Actor): int =
  CarryObjectBase + player.id

proc terrainObjectId(index: int): int =
  ## Returns the object id for one terrain prop instance.
  TerrainObjectBase + index

proc landmarkObjectId(index: int): int =
  ## Returns the object id for one landmark instance.
  LandmarkObjectBase + index

proc landmarkPromptSpriteId(kind: LandmarkKind): int =
  LandmarkPromptSpriteBase + ord(kind)

proc landmarkPromptSpriteId(landmark: Landmark): int =
  if landmark.campIsFortified() and landmark.campIsProvisioned():
    LandmarkFortMealPromptSpriteId
  elif landmark.campIsFortified():
    LandmarkFortPromptSpriteId
  elif landmark.campIsProvisioned():
    LandmarkMealPromptSpriteId
  elif landmark.kind == LandmarkCamp and landmark.done:
    LandmarkShelterPromptSpriteId
  elif landmark.kind == LandmarkWaystation:
    LandmarkWaystationPromptSpriteBase + ord(biomeForTileX(landmark.tx))
  else:
    landmark.kind.landmarkPromptSpriteId()

proc landmarkPromptObjectId(index: int): int =
  LandmarkPromptObjectBase + index

proc landmarkPromptLabel(kind: LandmarkKind): string =
  case kind
  of LandmarkWood:
    "WOOD"
  of LandmarkFood:
    "FOOD"
  of LandmarkStone:
    "STONE"
  of LandmarkGold:
    "GOLD"
  of LandmarkCamp:
    "CAMP W" & $CampWoodCost & " S" & $CampStoneCost
  of LandmarkBeacon:
    "RELIC"
  of LandmarkFinalGate:
    "GATE C" & $FinalGateCampCost & " BOSS R" & $FinalGateRelicCost
  of LandmarkShrine:
    "SHRINE F" & $ShrineFoodBonus
  of LandmarkRescue:
    "RESCUE F" & $RescueFoodBonus
  of LandmarkLair:
    "LAIR"
  of LandmarkWaystation:
    "WAYPOINT"

proc landmarkPromptLabel(landmark: Landmark): string =
  if landmark.campIsFortified() and landmark.campIsProvisioned():
    "FORT MEAL"
  elif landmark.campIsFortified():
    "FORT"
  elif landmark.campIsProvisioned():
    "MEALS"
  elif landmark.kind == LandmarkCamp and landmark.done:
    "SHELTER"
  elif landmark.kind == LandmarkWaystation:
    biomeForTileX(landmark.tx).waystationPromptLabel()
  else:
    landmark.kind.landmarkPromptLabel()

proc mobSpriteId(mob: Mob): int =
  ## Returns the sprite id for one mob, including attack flips.
  let flipLeft = mob.attackPhase != MobIdle and mob.attackFacing == FaceLeft
  if mob.species != SpeciesNone:
    return mob.species.mobSpeciesSpriteId(flipLeft)
  case mob.kind
  of SnakeMob, WolfMob:
    if flipLeft: MobLeftSpriteId else: MobSpriteId
  of TrollMob, GoblinMob:
    if flipLeft: TrollLeftSpriteId else: TrollSpriteId
  of BossMob, BearMob:
    if flipLeft: BossLeftSpriteId else: BossSpriteId
  of ScorpionMob, BatMob:
    if flipLeft: MobLeftSpriteId else: MobSpriteId
  of SlimeMob, WraithMob:
    if flipLeft: TrollLeftSpriteId else: TrollSpriteId
  of YetiMob:
    if flipLeft: BossLeftSpriteId else: BossSpriteId

proc selectedPlayerIndex(sim: SimServer, playerId: int): int =
  ## Returns the player index for a selected player id.
  for i in 0 ..< sim.players.len:
    if sim.players[i].id == playerId:
      return i
  -1

proc selectSpritePlayer(sim: SimServer, mouseX, mouseY: int): int =
  ## Returns the id of the topmost player under the mouse.
  result = -1
  var bestY = low(int)
  for player in sim.players:
    let
      sprite = sim.playerSpriteFor(player)
      x = player.x - 1 - PlayerSelectPadding
      y = player.y - 1 - PlayerSelectPadding
      w = sprite.width + 2 + PlayerSelectPadding * 2
      h = sprite.height + 2 + PlayerSelectPadding * 2
    if mouseX >= x and mouseX < x + w and
        mouseY >= y and mouseY < y + h and
        player.y >= bestY:
      bestY = player.y
      result = player.id

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
      return '4'
    if speedX >= 48 and speedX < 60:
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

proc addCommonSpriteDefinitions(packet: var seq[uint8], sim: SimServer) =
  ## Adds sprite definitions shared by global and player views.
  for i in 0 ..< PlayerTintColors.len:
    for form in PlayerForm:
      let art = sim.playerArts[form]
      for facing in Facing:
        let pose = facing.playerPoseForFacing()
        let
          playerSprite = buildSpriteProtocolActorSprite(
            art.rgbaSprites[pose],
            art.masks[pose],
            playerTintColor(i),
            false,
            facing == FaceLeft
          )
          selectedPlayerSprite = buildSpriteProtocolActorSprite(
            art.rgbaSprites[pose],
            art.masks[pose],
            playerTintColor(i),
            true,
            facing == FaceLeft
          )
        packet.addSprite(
          playerSpriteId(i, form, false, facing),
          playerSprite.width,
          playerSprite.height,
          playerSprite.pixels,
          playerSpriteLabel(i, form, false)
        )
        packet.addSprite(
          playerSpriteId(i, form, true, facing),
          selectedPlayerSprite.width,
          selectedPlayerSprite.height,
          selectedPlayerSprite.pixels,
          playerSpriteLabel(i, form, true)
        )

  for form in PlayerForm:
    for facing in Facing:
      let swoosh = buildSpriteProtocolFacedRawSprite(
        sim.playerArts[form].rgbaSwoosh,
        facing
      )
      packet.addSprite(
        swooshSpriteId(form, facing),
        swoosh.width,
        swoosh.height,
        swoosh.pixels,
        "swoosh"
      )

  for kind in [PickupTankGear, PickupDpsGear, PickupHealerGear]:
    let
      label = kind.roleGearLabel()
      text = sim.buildSpriteProtocolTextSprite([label], 2'u8)
    packet.addSprite(
      kind.roleGearSpriteId(),
      text.width,
      text.height,
      text.pixels,
      "role " & label.toLowerAscii()
    )

  for kind in StatusBadgeKind:
    let
      label = kind.statusBadgeLabel()
      text = sim.buildSpriteProtocolTextSprite(
        [label],
        kind.statusBadgeColor()
      )
    packet.addSprite(
      kind.statusBadgeSpriteId(),
      text.width,
      text.height,
      text.pixels,
      kind.statusBadgeSpriteLabel()
    )

  let
    mob = buildSpriteProtocolRawSprite(sim.rgbaMobSprite)
    mobLeft = buildSpriteProtocolRawSprite(sim.rgbaMobSprite, true)
    troll = buildSpriteProtocolRawSprite(sim.rgbaTrollSprite)
    trollLeft = buildSpriteProtocolRawSprite(sim.rgbaTrollSprite, true)
    boss = buildSpriteProtocolRawSprite(sim.rgbaBossSprite)
    bossLeft = buildSpriteProtocolRawSprite(sim.rgbaBossSprite, true)
    coin = buildSpriteProtocolRawSprite(sim.rgbaCoinSprite)
    heart = buildSpriteProtocolRawSprite(sim.rgbaHeartSprite)
  packet.addSprite(MobSpriteId, mob.width, mob.height, mob.pixels, "wolf")
  packet.addSprite(
    MobLeftSpriteId,
    mobLeft.width,
    mobLeft.height,
    mobLeft.pixels,
    "wolf left"
  )
  packet.addSprite(
    TrollSpriteId,
    troll.width,
    troll.height,
    troll.pixels,
    "goblin"
  )
  packet.addSprite(
    TrollLeftSpriteId,
    trollLeft.width,
    trollLeft.height,
    trollLeft.pixels,
    "goblin left"
  )
  packet.addSprite(
    BossSpriteId,
    boss.width,
    boss.height,
    boss.pixels,
    "bear boss"
  )
  packet.addSprite(
    BossLeftSpriteId,
    bossLeft.width,
    bossLeft.height,
    bossLeft.pixels,
    "bear boss left"
  )
  for species in AllMobSpecies:
    let
      kind = species.speciesKind()
      label = species.speciesLabel()
      tint = species.speciesTint()
      base =
        case kind
        of SnakeMob, WolfMob, ScorpionMob, BatMob:
          mob
        of TrollMob, GoblinMob, SlimeMob, WraithMob:
          troll
        of BossMob, BearMob, YetiMob:
          boss
      left =
        case kind
        of SnakeMob, WolfMob, ScorpionMob, BatMob:
          mobLeft
        of TrollMob, GoblinMob, SlimeMob, WraithMob:
          trollLeft
        of BossMob, BearMob, YetiMob:
          bossLeft
      rightId = species.mobSpeciesSpriteId(false)
      leftId = species.mobSpeciesSpriteId(true)
      rightPixels = base.pixels.tintSpritePixels(tint)
      leftPixels = left.pixels.tintSpritePixels(tint)
    packet.addSprite(
      rightId,
      base.width,
      base.height,
      rightPixels,
      label
    )
    packet.addSprite(
      leftId,
      left.width,
      left.height,
      leftPixels,
      label & " left"
    )
  packet.addSprite(CoinSpriteId, coin.width, coin.height, coin.pixels, "coin")
  packet.addSprite(
    HeartSpriteId,
    heart.width,
    heart.height,
    heart.pixels,
    "heart"
  )
  for current in 0 .. MaxPlayerLives:
    let health = buildSpriteProtocolHealthSprite(current, MaxPlayerLives)
    packet.addSprite(
      healthSpriteId(current, MaxPlayerLives),
      health.width,
      health.height,
      health.pixels,
      healthSpriteLabel(current, MaxPlayerLives)
    )
  for current in 0 .. BossHp:
    let health = buildSpriteProtocolHealthSprite(current, BossHp)
    packet.addSprite(
      healthSpriteId(current, BossHp),
      health.width,
      health.height,
      health.pixels,
      healthSpriteLabel(current, BossHp)
    )
  for kind in TerrainKind:
    let prop = buildSpriteProtocolRawSprite(sim.terrainPropRgbaSprite(kind))
    packet.addSprite(
      terrainSpriteId(kind),
      prop.width,
      prop.height,
      prop.pixels,
      $kind
    )
  for kind in LandmarkKind:
    let landmark = buildSpriteProtocolRawSprite(sim.landmarkRgbaSprite(kind))
    packet.addSprite(
      landmarkSpriteId(kind),
      landmark.width,
      landmark.height,
      landmark.pixels,
      kind.landmarkLabel()
    )
    let
      prompt = kind.landmarkPromptLabel()
      promptSprite = sim.buildSpriteProtocolTextSprite([prompt], 2'u8)
    packet.addSprite(
      kind.landmarkPromptSpriteId(),
      promptSprite.width,
      promptSprite.height,
      promptSprite.pixels,
      "prompt " & prompt.toLowerAscii()
    )
  let
    shelterPrompt = "SHELTER"
    shelterPromptSprite = sim.buildSpriteProtocolTextSprite(
      [shelterPrompt],
      10'u8
    )
  packet.addSprite(
    LandmarkShelterPromptSpriteId,
    shelterPromptSprite.width,
    shelterPromptSprite.height,
    shelterPromptSprite.pixels,
    "prompt " & shelterPrompt.toLowerAscii()
  )
  let
    fortPrompt = "FORT"
    fortPromptSprite = sim.buildSpriteProtocolTextSprite(
      [fortPrompt],
      2'u8
    )
  packet.addSprite(
    LandmarkFortPromptSpriteId,
    fortPromptSprite.width,
    fortPromptSprite.height,
    fortPromptSprite.pixels,
    "prompt " & fortPrompt.toLowerAscii()
  )
  let
    mealPrompt = "MEALS"
    mealPromptSprite = sim.buildSpriteProtocolTextSprite(
      [mealPrompt],
      11'u8
    )
  packet.addSprite(
    LandmarkMealPromptSpriteId,
    mealPromptSprite.width,
    mealPromptSprite.height,
    mealPromptSprite.pixels,
    "prompt " & mealPrompt.toLowerAscii()
  )
  let
    fortMealPrompt = "FORT MEAL"
    fortMealPromptSprite = sim.buildSpriteProtocolTextSprite(
      [fortMealPrompt],
      11'u8
    )
  packet.addSprite(
    LandmarkFortMealPromptSpriteId,
    fortMealPromptSprite.width,
    fortMealPromptSprite.height,
    fortMealPromptSprite.pixels,
    "prompt " & fortMealPrompt.toLowerAscii()
  )
  for biome in BiomeKind:
    let
      prompt = biome.waystationPromptLabel()
      promptSprite = sim.buildSpriteProtocolTextSprite([prompt], 14'u8)
    packet.addSprite(
      LandmarkWaystationPromptSpriteBase + ord(biome),
      promptSprite.width,
      promptSprite.height,
      promptSprite.pixels,
      "prompt " & prompt.toLowerAscii()
    )
  for weather in WeatherKind:
    if weather == WeatherClear:
      continue
    let overlay = weather.buildWeatherOverlaySprite()
    packet.addSprite(
      weather.weatherOverlaySpriteId(),
      overlay.width,
      overlay.height,
      overlay.pixels,
      weather.weatherOverlayLabel()
    )

proc buildSpriteProtocolInit(sim: SimServer): seq[uint8] =
  ## Builds the initial global viewer snapshot.
  result = @[]
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, WorldWidthPixels, WorldHeightPixels)
  result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
  result.addViewport(TopLeftLayerId, ScreenWidth, 48)
  result.addLayer(
    ReplayCenterBottomLayerId,
    ReplayCenterBottomLayerType,
    UiLayerFlag
  )
  result.addViewport(ReplayCenterBottomLayerId, ScreenWidth, 16)
  result.addLayer(
    ReplayBottomLeftLayerId,
    ReplayBottomLeftLayerType,
    UiLayerFlag
  )
  result.addViewport(ReplayBottomLeftLayerId, ScreenWidth, 16)
  result.addSprite(
    MapSpriteId,
    WorldWidthPixels,
    WorldHeightPixels,
    sim.buildSpriteProtocolMapSprite()
  )
  result.addObject(MapObjectId, 0, 0, low(int16), MapLayerId, MapSpriteId)
  result.addCommonSpriteDefinitions(sim)

proc buildSpriteProtocolPlayerInit(sim: SimServer): seq[uint8] =
  ## Builds the initial sprite player snapshot.
  result = @[]
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, PlayerViewportWidth, PlayerViewportHeight)
  result.addSprite(
    MapSpriteId,
    WorldWidthPixels,
    WorldHeightPixels,
    sim.buildSpriteProtocolMapSprite(),
    "map"
  )
  result.addCommonSpriteDefinitions(sim)

proc chatSpriteId(player: Actor): int =
  ## Returns the sprite id for one player's chat bubble.
  ChatSpriteBase + player.id

proc chatObjectId(player: Actor): int =
  ## Returns the object id for one player's chat bubble.
  ChatObjectBase + player.id

proc attackObjectId(player: Actor): int =
  ## Returns the object id for one player's attack swoosh.
  AttackObjectBase + player.id

proc playerHealthObjectId(player: Actor): int =
  ## Returns the object id for one player's health bar.
  PlayerHealthObjectBase + player.id

proc mobHealthObjectId(index: int): int =
  ## Returns the object id for one mob health bar.
  MobHealthObjectBase + index

proc addHealthObject(
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  objectId,
  actorX,
  actorY,
  actorWidth,
  actorHeight,
  current,
  maximum,
  cameraX,
  cameraY,
  viewportWidth,
  viewportHeight: int
) =
  ## Adds one damaged actor health bar object.
  if maximum <= 0 or current >= maximum:
    return
  let
    x = actorX + actorWidth div 2 - HealthBarWidth div 2 - cameraX
    y = actorY - HealthBarHeight - HealthBarGap - cameraY
    sortY = actorY + actorHeight - cameraY + 1
  objects.addWorldSpriteObject(
    currentIds,
    objectId,
    x,
    y,
    healthSpriteId(current, maximum),
    HealthBarWidth,
    HealthBarHeight,
    viewportWidth,
    viewportHeight,
    sortY
  )

proc addSpeechBubbles(
  sim: SimServer,
  packet: var seq[uint8],
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  cameraX,
  cameraY,
  viewportWidth,
  viewportHeight: int
) =
  ## Adds speech bubble sprites above players.
  for player in sim.players:
    if player.lives <= 0 or player.message.len == 0:
      continue
    let
      bubble = sim.buildSpriteProtocolBubbleSprite(player.message)
      objectId = player.chatObjectId()
      spriteId = player.chatSpriteId()
      sprite = sim.playerSpriteFor(player)
      healthOffset =
        if player.lives < player.maxHp:
          HealthBarHeight + HealthBarGap
        else:
          0
      centerX = player.x + sprite.width div 2 - cameraX
      x = centerX - bubble.width div 2
      y = player.y - bubble.height - 4 - healthOffset - cameraY
    packet.addSprite(
      spriteId,
      bubble.width,
      bubble.height,
      bubble.pixels,
      player.message
    )
    objects.addWorldSpriteObject(
      currentIds,
      objectId,
      x,
      y,
      spriteId,
      bubble.width,
      bubble.height,
      viewportWidth,
      viewportHeight
    )

proc addAttackObjects(
  sim: SimServer,
  packet: var seq[uint8],
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  cameraX,
  cameraY,
  viewportWidth,
  viewportHeight: int
) =
  ## Adds active attack swoosh objects.
  for player in sim.players:
    if player.lives <= 0 or player.attackTicks <= 0:
      continue
    let
      hit = sim.attackRect(player)
      objectId = player.attackObjectId()
    objects.addWorldSpriteObject(
      currentIds,
      objectId,
      hit.x - cameraX,
      hit.y - cameraY,
      swooshSpriteId(player.form, player.facing),
      hit.w,
      hit.h,
      viewportWidth,
      viewportHeight
    )

proc addTerrainObjects(
  sim: SimServer,
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  cameraX,
  cameraY,
  viewportWidth,
  viewportHeight: int
) =
  ## Adds terrain prop objects so they share world sprite sorting.
  for i in 0 ..< sim.terrainProps.len:
    let
      prop = sim.terrainProps[i]
      objectId = terrainObjectId(i)
      sprite = sim.terrainPropRgbaSprite(prop.kind)
    objects.addWorldSpriteObject(
      currentIds,
      objectId,
      prop.tx * WorldTileSize - cameraX,
      prop.ty * WorldTileSize - cameraY,
      terrainSpriteId(prop.kind),
      sprite.width,
      sprite.height,
      viewportWidth,
      viewportHeight
    )

proc addLandmarkObjects(
  sim: SimServer,
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  cameraX,
  cameraY,
  viewportWidth,
  viewportHeight: int
) =
  ## Adds expedition resources, camps, beacons, and final gate objects.
  for i in 0 ..< sim.landmarks.len:
    let landmark = sim.landmarks[i]
    if landmark.done and landmark.kind in {
      LandmarkWood,
      LandmarkFood,
      LandmarkStone,
      LandmarkGold
    }:
      continue
    let
      sprite = sim.landmarkRgbaSprite(landmark.kind)
      objectId = landmarkObjectId(i)
    objects.addWorldSpriteObject(
      currentIds,
      objectId,
      landmark.landmarkWorldX() - cameraX,
      landmark.landmarkWorldY() - cameraY,
      landmarkSpriteId(landmark.kind),
      sprite.width,
      sprite.height,
      viewportWidth,
      viewportHeight
    )
    let
      prompt = landmark.landmarkPromptLabel()
      promptWidth = sim.textFont.textWidth(prompt)
      promptHeight = sim.textFont.height
    objects.addWorldSpriteObject(
      currentIds,
      i.landmarkPromptObjectId(),
      landmark.landmarkWorldX() - cameraX -
        max(0, (promptWidth - sprite.width) div 2),
      landmark.landmarkWorldY() - cameraY - promptHeight - 3,
      landmark.landmarkPromptSpriteId(),
      promptWidth,
      promptHeight,
      viewportWidth,
      viewportHeight,
      landmark.landmarkWorldY() - cameraY - 1
    )

proc addWeatherOverlayObjects(
  sim: SimServer,
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  cameraX,
  cameraY,
  viewportWidth,
  viewportHeight: int
) =
  ## Adds light deterministic weather particles to sprite-protocol map views.
  for i in 0 ..< WeatherOverlaySlots:
    let
      screenX = (i * 47 + sim.tickCount * 3) mod (viewportWidth + 48) - 24
      screenY = (i * 31 + sim.tickCount * 2) mod (viewportHeight + 32) - 16
      worldX = clamp(cameraX + screenX, 0, WorldWidthPixels - 1)
      weather = sim.weatherAtPixel(worldX)
    if weather == WeatherClear:
      continue
    let size = weather.weatherOverlaySize()
    objects.addWorldSpriteObject(
      currentIds,
      i.weatherOverlayObjectId(),
      screenX,
      screenY,
      weather.weatherOverlaySpriteId(),
      size.width,
      size.height,
      viewportWidth,
      viewportHeight,
      viewportHeight + i
    )

proc addWorldObjects(
  sim: SimServer,
  packet: var seq[uint8],
  currentIds: var seq[int],
  cameraX, cameraY: int,
  viewportWidth,
  viewportHeight: int,
  selectedPlayerId = -1
) =
  ## Adds pickups, mobs, players, attacks, and speech bubbles.
  var objects: seq[WorldSpriteObject] = @[]
  sim.addTerrainObjects(
    objects,
    currentIds,
    cameraX,
    cameraY,
    viewportWidth,
    viewportHeight
  )
  sim.addLandmarkObjects(
    objects,
    currentIds,
    cameraX,
    cameraY,
    viewportWidth,
    viewportHeight
  )

  for i in 0 ..< sim.pickups.len:
    let
      pickup = sim.pickups[i]
      objectId = PickupObjectBase + i
      spriteId = pickup.kind.pickupSpriteId()
      sprite = sim.pickupRgbaSprite(pickup.kind)
    objects.addWorldSpriteObject(
      currentIds,
      objectId,
      pickup.x - cameraX,
      pickup.y - cameraY,
      spriteId,
      sprite.width,
      sprite.height,
      viewportWidth,
      viewportHeight
    )
    if pickup.kind.isRoleGear():
      let
        label = pickup.kind.roleGearLabel()
        labelWidth = sim.textFont.textWidth(label)
        labelHeight = sim.textFont.height
      objects.addWorldSpriteObject(
        currentIds,
        i.roleGearObjectId(),
        pickup.x - cameraX - max(0, (labelWidth - sprite.width) div 2),
        pickup.y - cameraY - labelHeight - 3,
        pickup.kind.roleGearSpriteId(),
        labelWidth,
        labelHeight,
        viewportWidth,
        viewportHeight,
        pickup.y - cameraY - 1
      )

  for i in 0 ..< sim.mobs.len:
    let
      mob = sim.mobs[i]
      objectId = MobObjectBase + i
      spriteId = mob.mobSpriteId()
      drawY = mob.mobDrawY()
    objects.addWorldSpriteObject(
      currentIds,
      objectId,
      mob.x - cameraX,
      drawY - cameraY,
      spriteId,
      mob.sprite.width,
      mob.sprite.height,
      viewportWidth,
      viewportHeight
    )
    objects.addHealthObject(
      currentIds,
      mobHealthObjectId(i),
      mob.x,
      drawY,
      mob.sprite.width,
      mob.sprite.height,
      mob.hp,
      mob.mobMaxHp(),
      cameraX,
      cameraY,
      viewportWidth,
      viewportHeight
    )
    let badges = mob.species.threatBadges()
    for badgeIndex in 0 ..< badges.len:
      let
        badge = badges[badgeIndex]
        label = badge.statusBadgeLabel()
        badgeWidth = sim.textFont.textWidth(label)
        badgeHeight = sim.textFont.height
      objects.addWorldSpriteObject(
        currentIds,
        i.mobThreatBadgeObjectId(badgeIndex),
        mob.x + mob.sprite.width + 2 - cameraX,
        drawY - (badgeHeight + 2) * (badgeIndex + 1) - cameraY,
        badge.statusBadgeSpriteId(),
        badgeWidth,
        badgeHeight,
        viewportWidth,
        viewportHeight,
        drawY - cameraY + badgeIndex
      )

  for i in 0 ..< sim.players.len:
    let
      player = sim.players[i]
      selected = player.id == selectedPlayerId
      objectId = player.playerObjectId()
      playerSprite = sim.playerRgbaSpriteFor(player)
      downed = sim.playerDowned(i)
    if player.lives <= 0 and not downed:
      continue
    objects.addWorldSpriteObject(
      currentIds,
      objectId,
      player.x - 1 - cameraX,
      player.y - 1 - cameraY,
      playerSpriteId(
        i.roleTintSlot(player.role),
        player.form,
        selected,
        player.facing
      ),
      playerSprite.width + 2,
      playerSprite.height + 2,
      viewportWidth,
      viewportHeight
    )
    if player.carrying and not downed:
      let
        carriedLandmark = player.carriedItem.landmarkForCarry()
        carriedSprite = sim.landmarkRgbaSprite(carriedLandmark)
        carryX = player.x + playerSprite.width div 2 -
          carriedSprite.width div 2 - cameraX
        carryY = player.y - carriedSprite.height div 2 - 5 - cameraY
      objects.addWorldSpriteObject(
        currentIds,
        player.carryObjectId(),
        carryX,
        carryY,
        carriedLandmark.landmarkSpriteId(),
        carriedSprite.width,
        carriedSprite.height,
        viewportWidth,
        viewportHeight,
        player.y - cameraY
      )
    var badges: seq[StatusBadgeKind] = @[]
    if downed:
      badges.add(StatusDown)
    else:
      if player.poisonTicks > 0:
        badges.add(StatusPoison)
      if player.slowTicks > 0:
        badges.add(StatusSlow)
      if player.chillTicks > 0:
        badges.add(StatusChill)
      if sim.playerIsolationThreatened(i):
        badges.add(StatusAlone)
      if sim.playerNeedsHelp(i):
        badges.add(StatusHelp)
      if player.pingTicks > 0 and player.pingKind != PingNone:
        badges.add(player.pingKind.pingStatusBadge())
    for badgeIndex in 0 ..< badges.len:
      let
        badge = badges[badgeIndex]
        label = badge.statusBadgeLabel()
        badgeWidth = sim.textFont.textWidth(label)
        badgeHeight = sim.textFont.height
      objects.addWorldSpriteObject(
        currentIds,
        player.statusBadgeObjectId(badgeIndex),
        player.x + playerSprite.width + 2 - cameraX,
        player.y - (badgeHeight + 2) * (badgeIndex + 1) - cameraY,
        badge.statusBadgeSpriteId(),
        badgeWidth,
        badgeHeight,
        viewportWidth,
        viewportHeight,
        player.y - cameraY + badgeIndex
      )
    objects.addHealthObject(
      currentIds,
      player.playerHealthObjectId(),
      player.x - 1,
      player.y - 1,
      playerSprite.width + 2,
      playerSprite.height + 2,
      player.lives,
      player.maxHp,
      cameraX,
      cameraY,
      viewportWidth,
      viewportHeight
    )

  sim.addAttackObjects(
    packet,
    objects,
    currentIds,
    cameraX,
    cameraY,
    viewportWidth,
    viewportHeight
  )
  sim.addSpeechBubbles(
    packet,
    objects,
    currentIds,
    cameraX,
    cameraY,
    viewportWidth,
    viewportHeight
  )
  sim.addWeatherOverlayObjects(
    objects,
    currentIds,
    cameraX,
    cameraY,
    viewportWidth,
    viewportHeight
  )
  packet.flushWorldSpriteObjects(objects)

proc addPlayerHud(
  sim: SimServer,
  packet: var seq[uint8],
  currentIds: var seq[int],
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState
) =
  ## Adds the local player HUD to a sprite-player view.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let
    player = sim.players[playerIndex]
    frontier = sim.frontierTiles()
    lives = max(player.lives, 0)
    statusLine1 = player.role.roleLabel().toUpperAscii() & " " &
      sim.currentBiome().biomeLabel().toUpperAscii()
    statusLine2 = sim.currentWeather().weatherLabel().toUpperAscii() &
      " W" & $sim.wood & " F" & $sim.food & " S" & $sim.stone &
      " R" & $sim.relicShards
    ability = player.role.roleAbilityLabel().toUpperAscii()
    statusLine3 =
      if player.abilityCooldown > 0:
        "B " & ability & " CD" & $player.abilityCooldown
      else:
        "B " & ability
    playerElevation = sim.tileElevation(
      clamp(boundsCenterX(player.x, player.bounds) div WorldTileSize, 0, WorldWidthTiles - 1),
      clamp(boundsCenterY(player.y, player.bounds) div WorldTileSize, 0, WorldHeightTiles - 1)
    )
    statusLine4 =
      (if player.carrying:
        "CARRY " & player.carriedItem.carryLabel().toUpperAscii()
      else:
        "CARRY NONE") & " E" & $playerElevation & " " &
        player.statusLabel().toUpperAscii()
    statusLine5 = sim.expeditionObjectiveHint(playerIndex)
    status = statusLine1 & "|" & statusLine2 & "|" & statusLine3 & "|" &
      statusLine4 & "|" & statusLine5
  currentIds.add(CoinsHudObjectId)
  if state.hudCoins != frontier:
    let coinText = sim.buildSpriteProtocolTextSprite(
      ["FRONT " & $frontier],
      2'u8
    )
    packet.addSprite(
      CoinsHudSpriteId,
      coinText.width,
      coinText.height,
      coinText.pixels,
      "front " & $frontier
    )
  packet.addObject(
    CoinsHudObjectId,
    2,
    2,
    high(int16),
    MapLayerId,
    CoinsHudSpriteId
  )
  currentIds.add(LivesHudObjectId)
  if state.hudLives != lives:
    let livesText = sim.buildSpriteProtocolTextSprite(
      ["HP " & $lives & "/" & $player.maxHp],
      2'u8
    )
    packet.addSprite(
      LivesHudSpriteId,
      livesText.width,
      livesText.height,
      livesText.pixels,
      "hp " & $lives & "/" & $player.maxHp
    )
  packet.addObject(
    LivesHudObjectId,
    2,
    2 + sim.textFont.height + HudGap,
    high(int16),
    MapLayerId,
    LivesHudSpriteId
  )
  currentIds.add(StatusHudObjectId)
  if state.hudStatus != status:
    let statusText = sim.buildSpriteProtocolTextSprite(
      [statusLine1, statusLine2, statusLine3, statusLine4, statusLine5],
      2'u8
    )
    packet.addSprite(
      StatusHudSpriteId,
      statusText.width,
      statusText.height,
      statusText.pixels,
      status
    )
  packet.addObject(
    StatusHudObjectId,
    2,
    2 + (sim.textFont.height + HudGap) * 2,
    high(int16),
    MapLayerId,
    StatusHudSpriteId
  )
  nextState.hudCoins = frontier
  nextState.hudLives = lives
  nextState.hudStatus = status

proc addPlayerStatus(
  sim: SimServer,
  packet: var seq[uint8],
  currentIds: var seq[int],
  lines: openArray[string]
) =
  ## Adds centered status text to a sprite-player view.
  let
    text = sim.buildSpriteProtocolTextSprite(lines, 2'u8)
    x = max(0, (PlayerViewportWidth - text.width) div 2)
    y = max(0, (PlayerViewportHeight - text.height) div 2)
  currentIds.add(StatusHudObjectId)
  packet.addSprite(
    StatusHudSpriteId,
    text.width,
    text.height,
    text.pixels,
    "status"
  )
  packet.addObject(
    StatusHudObjectId,
    x,
    y,
    high(int16),
    MapLayerId,
    StatusHudSpriteId
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
  if playerIndex < 0 or playerIndex >= sim.players.len:
    sim.addPlayerStatus(result, currentIds, ["WAITING"])
  else:
    let player = sim.players[playerIndex]
    let
      cameraX = worldClampPixel(
        player.x + player.sprite.width div 2 - PlayerViewportWidth div 2,
        WorldWidthPixels - PlayerViewportWidth
      )
      cameraY = worldClampPixel(
        player.y + player.sprite.height div 2 - PlayerViewportHeight div 2,
        WorldHeightPixels - PlayerViewportHeight
      )
    currentIds.add(MapObjectId)
    result.addObject(
      MapObjectId,
      -cameraX,
      -cameraY,
      low(int16),
      MapLayerId,
      MapSpriteId
    )
    sim.addWorldObjects(
      result,
      currentIds,
      cameraX,
      cameraY,
      PlayerViewportWidth,
      PlayerViewportHeight
    )
    sim.addPlayerHud(result, currentIds, playerIndex, state, nextState)
    if sim.playerDowned(playerIndex):
      sim.addPlayerStatus(result, currentIds, ["DOWN", "WAIT FOR RESCUE"])
    elif player.lives <= 0:
      sim.addPlayerStatus(result, currentIds, ["GAME", "OVER"])

  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

proc buildSpriteProtocolUpdates*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  replayTick = -1,
  replayPlaying = false,
  replaySpeed = 1,
  replayMaxTick = -1,
  replayLooping = false
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
        nextState.selectedPlayerId =
          sim.selectSpritePlayer(nextState.mouseX, nextState.mouseY)
    elif nextState.mouseLayer == MapLayerId:
      nextState.selectedPlayerId =
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
    nextState.initialized = true

  var currentIds: seq[int] = @[]
  sim.addWorldObjects(
    result,
    currentIds,
    0,
    0,
    WorldWidthPixels,
    WorldHeightPixels,
    nextState.selectedPlayerId
  )

  let playerIndex = sim.selectedPlayerIndex(nextState.selectedPlayerId)
  var lines: seq[string] = @[
    "SCORE " & $sim.teamScore() & " FRONT " & $sim.frontierTiles(),
    sim.currentBiome().biomeLabel().toUpperAscii() & " " &
      sim.currentWeather().weatherLabel().toUpperAscii(),
    "W" & $sim.wood & " F" & $sim.food & " S" & $sim.stone &
      " R" & $sim.relicShards
  ]
  if playerIndex >= 0:
    let player = sim.players[playerIndex]
    lines.add("PLAYER " & player.playerIdentity())
    lines.add("ROLE " & player.role.roleLabel())
    lines.add("HP " & $player.lives & "/" & $player.maxHp)
    lines.add("FRONT " & $frontierTilesForX(player.personalFrontier))
    lines.add(sim.expeditionObjectiveHint(playerIndex))
  let text = sim.buildSpriteProtocolTextSprite(lines, 2'u8)
  currentIds.add(SelectedTextObjectId)
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

  if replayTick >= 0:
    let
      tickText = sim.buildSpriteProtocolTextSprite(
        ["TICK " & $replayTick],
        2'u8
      )
      scrubber = buildReplayScrubberSprite(replayTick, replayMaxTick)
      controls = sim.buildReplayControlsSprite(
        replayPlaying,
        replaySpeed,
        replayLooping
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

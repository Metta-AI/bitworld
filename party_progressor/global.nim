import std/[algorithm, os, sequtils, strutils]
import supersnappy
import bitworld/protocol, sim
import bitworld/pixelfonts
import bitworld/server

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
  MobTelegraphEffectSpriteId = 316
  MobLungeEffectSpriteId = 317
  MobAttackStyleEffectSpriteBase = 1320
  RoleAbilityEffectSpriteBase = 680
  DpsBeamHorizontalSpriteId = RoleAbilityEffectSpriteBase + 8
  DpsBeamVerticalSpriteId = RoleAbilityEffectSpriteBase + 9
  LivesHudSpriteId = PlayerHudSpriteId + 1
  StatusHudSpriteId = PlayerHudSpriteId + 2
  ManaHudSpriteId = PlayerHudSpriteId + 3
  HudFrontierIconSpriteId = PlayerHudSpriteId + 4
  HudWoodIconSpriteId = PlayerHudSpriteId + 5
  HudFoodIconSpriteId = PlayerHudSpriteId + 6
  HudStoneIconSpriteId = PlayerHudSpriteId + 7
  HudRelicIconSpriteId = PlayerHudSpriteId + 8
  HudCounterSpriteBase = PlayerHudSpriteId + 10
  VisibilityShadowSpriteId = 1500
  RoleLabelSpriteBase = PlayerHudSpriteId + 40
  RoleGearIconSpriteBase = RoleLabelSpriteBase + 16
  LandmarkShelterSpriteId = LandmarkSpriteBase + ord(high(LandmarkKind)) + 1
  StatusBadgeSpriteBase = 1600
  PlayerEffectAuraSpriteBase = 1660
  LandmarkPromptSpriteBase = 880
  LandmarkShelterPromptSpriteId =
    LandmarkPromptSpriteBase + ord(high(LandmarkKind)) + 1
  LandmarkFortPromptSpriteId = LandmarkShelterPromptSpriteId + 1
  LandmarkMealPromptSpriteId = LandmarkFortPromptSpriteId + 1
  LandmarkFortMealPromptSpriteId = LandmarkMealPromptSpriteId + 1
  LandmarkWardPromptSpriteId = LandmarkFortMealPromptSpriteId + 1
  LandmarkRallyPromptSpriteId = LandmarkWardPromptSpriteId + 1
  LandmarkAidPromptSpriteId = LandmarkRallyPromptSpriteId + 1
  LandmarkWaystationPromptSpriteBase = LandmarkAidPromptSpriteId + 1
  WeatherOverlaySpriteBase = 920
  LandmarkDynamicPromptSpriteBase = 940
  LivesHudObjectId = PlayerHudObjectId + 1
  StatusHudObjectId = PlayerHudObjectId + 2
  ManaHudObjectId = PlayerHudObjectId + 3
  HudCounterValueObjectBase = PlayerHudObjectId + 10
  HudCounterIconObjectBase = PlayerHudObjectId + 30
  HudArmorObjectBase = PlayerHudObjectId + 50
  HudEffectObjectBase = PlayerHudObjectId + 70
  RoleLabelObjectBase = PlayerHudObjectId + 100
  HealthSprite5Base = 700
  HealthSprite10Base = 710
  PlayerHealthObjectBase = 10000
  MobHealthObjectBase = 11000
  CarryObjectBase* = 12000
  CarryExtraObjectBase = CarryObjectBase + 100
  CarryCountObjectBase = CarryObjectBase + 500
  StatusBadgeObjectBase = 13000
  LandmarkPromptObjectBase = 14000
  MobThreatBadgeObjectBase = 15000
  WeatherOverlayObjectBase = 16000
  MobAttackEffectObjectBase = 17000
  RoleAbilityEffectObjectBase = 18000
  DpsBeamObjectBase = RoleAbilityEffectObjectBase + 100
  VisibilityShadowObjectId = 19000
  GuideObjectBase = 19200
  GuideBubbleObjectBase = 19300
  PlayerEffectAuraObjectBase = 19400
  CarryCountSpriteBase = 1400
  ArmorSpriteBase = 1460
  GuideSpriteId = 1479
  GuideBubbleSpriteBase = 1480
  CarryObjectStride = 8
  StatusBadgeSlots = 18
  PlayerEffectAuraSlots = 4
  WeatherOverlaySlots = 56
  MobAttackEffectSize = 28
  RoleAbilityEffectSize = 48
  PlayerEffectAuraSize = 42
  CarryHudSlotGap = 4
  HealthBarWidth = 18
  HealthBarHeight = 5
  HealthBarPad = 1
  HealthBarGap = 3
  HudMeterWidth = 42
  HudMeterHeight = 6
  HudMeterPad = 1
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
  ManaFillColor = (r: 84'u8, g: 141'u8, b: 255'u8, a: 255'u8)
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
    StatusRoleTank
    StatusRoleDps
    StatusRoleHealer
    StatusTrio
    StatusPartyFocus
    StatusHighGround
    StatusLowGround
    StatusForage
    StatusRally
    StatusShade
    StatusWarmth
    StatusLight
    StatusGuard
    StatusBlessing
    StatusRoute
    StatusSurvey
    StatusGuide
    StatusHunt
    StatusPoison
    StatusSlow
    StatusChill
    StatusExhaustion
    StatusMire
    StatusCold
    StatusHeat
    StatusFog
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
    StatusTriumph
    StatusRation
    StatusMorale
    StatusStagger

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
    hudArmor*: string

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
  result.hudArmor = ""

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
  width,
  height: int,
  tint: tuple[r, g, b, a: uint8],
  species: MobSpecies,
  strength = 48
): seq[uint8] =
  result = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    result[i] = pixels[i]
  for y in 0 ..< height:
    for x in 0 ..< width:
      let i = (y * width + x) * 4
      if i + 3 >= result.len or result[i + 3] == 0'u8:
        continue
      let
        originalR = int(result[i])
        originalG = int(result[i + 1])
        originalB = int(result[i + 2])
        luminance = (originalR * 3 + originalG * 5 + originalB * 2) div 10
      if luminance < 36:
        result[i] = max(0, originalR - 6).uint8
        result[i + 1] = max(0, originalG - 6).uint8
        result[i + 2] = max(0, originalB - 6).uint8
        continue
      var
        targetR = int(tint.r)
        targetG = int(tint.g)
        targetB = int(tint.b)
        localStrength = strength
      if luminance > 172:
        targetR = min(255, targetR + 42)
        targetG = min(255, targetG + 42)
        targetB = min(255, targetB + 42)
        localStrength = max(34, strength - 10)
      elif luminance < 86:
        targetR = max(0, targetR - 56)
        targetG = max(0, targetG - 56)
        targetB = max(0, targetB - 56)
        localStrength = min(62, strength + 8)
      if (x + y + ord(species)) mod 9 == 0 and luminance > 72:
        targetR = min(255, targetR + 34)
        targetG = min(255, targetG + 34)
        targetB = min(255, targetB + 34)
      elif (x * 2 + y + ord(species)) mod 11 == 0 and luminance > 64:
        targetR = max(0, targetR - 38)
        targetG = max(0, targetG - 38)
        targetB = max(0, targetB - 38)
      result[i] =
        ((originalR * (100 - localStrength) + targetR * localStrength) div 100).uint8
      result[i + 1] =
        ((originalG * (100 - localStrength) + targetG * localStrength) div 100).uint8
      result[i + 2] =
        ((originalB * (100 - localStrength) + targetB * localStrength) div 100).uint8

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
  baseX, baseY, targetWidth, targetHeight: int
) =
  ## Blits one sprite into a map sprite buffer.
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let
        px = baseX + x
        py = baseY + y
      if px < 0 or py < 0 or
          px >= targetWidth or py >= targetHeight:
        continue
      let sourceIndex = sprite.rgbaSpriteIndex(x, y)
      if sprite.pixels[sourceIndex + 3] != 0'u8:
        pixels.blendRgbaPixel(
          py * targetWidth + px,
          sprite.pixels,
          sourceIndex
        )

proc fillMapTile(
  pixels: var seq[uint8],
  baseX,
  baseY: int,
  targetWidth,
  targetHeight: int,
  color: tuple[r, g, b, a: uint8]
) =
  ## Fills the opaque biome backing under borrowed transparent ground art.
  for y in 0 ..< WorldTileSize:
    for x in 0 ..< WorldTileSize:
      let
        px = baseX + x
        py = baseY + y
      if px < 0 or py < 0 or
          px >= targetWidth or py >= targetHeight:
        continue
      pixels.putRgbaPixel(py * targetWidth + px, color)

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

proc mapChunkSpriteId(chunkIndex: int): int =
  MapChunkSpriteBase + chunkIndex

proc mapChunkObjectId(chunkIndex: int): int =
  MapChunkObjectBase + chunkIndex

proc buildMapAnchorSprite(): seq[uint8] =
  ## Keeps old MapObjectId camera semantics without drawing a full-world sprite.
  newRgbaPixels(1, 1)

proc buildSpriteProtocolMapChunkSprite(
  sim: SimServer,
  chunkIndex: int
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds one fixed-width world map chunk for clipped client rendering.
  let
    firstTx = chunkIndex * MapChunkTileWidth
    lastTx = min(WorldWidthTiles - 1, firstTx + MapChunkTileWidth - 1)
  if firstTx > lastTx:
    result.width = 1
    result.height = 1
    result.pixels = newRgbaPixels(1, 1)
    return
  result.width = (lastTx - firstTx + 1) * WorldTileSize
  result.height = WorldHeightPixels
  result.pixels = newRgbaPixels(result.width, result.height)
  for ty in 0 ..< WorldHeightTiles:
    for tx in firstTx .. lastTx:
      let
        baseX = (tx - firstTx) * WorldTileSize
        baseY = ty * WorldTileSize
      result.pixels.fillMapTile(
        baseX,
        baseY,
        result.width,
        result.height,
        sim.tileBiomeKind(tx, ty).biomeBackgroundRgbaColor().shadeForElevation(
          sim.tileElevation(tx, ty)
        )
      )
      result.pixels.blitMapSprite(
        sim.groundRgbaSprite(sim.tileGroundKind(tx, ty)),
        baseX,
        baseY,
        result.width,
        result.height
      )

proc addMapSpriteDefinitions(sim: SimServer, packet: var seq[uint8]) =
  ## Sends the map as clipped chunks plus a tiny camera-anchor sprite.
  packet.addSprite(MapSpriteId, 1, 1, buildMapAnchorSprite(), "map")
  for chunkIndex in 0 ..< MapChunkCount:
    let chunk = sim.buildSpriteProtocolMapChunkSprite(chunkIndex)
    packet.addSprite(
      chunkIndex.mapChunkSpriteId(),
      chunk.width,
      chunk.height,
      chunk.pixels,
      "map chunk " & $chunkIndex
    )

proc addMapAnchorObject(
  packet: var seq[uint8],
  currentIds: var seq[int],
  cameraX,
  cameraY: int
) =
  ## Preserves legacy bot camera tracking through MapObjectId.
  currentIds.add(MapObjectId)
  packet.addObject(
    MapObjectId,
    -cameraX,
    -cameraY,
    low(int16),
    MapLayerId,
    MapSpriteId
  )

proc addMapChunkObjects(
  packet: var seq[uint8],
  currentIds: var seq[int],
  cameraX,
  cameraY,
  viewportWidth: int
) =
  ## Places only map chunks that overlap the current camera viewport.
  let
    firstChunk = clamp(cameraX div MapChunkWidthPixels, 0, MapChunkCount - 1)
    lastChunk = clamp(
      (cameraX + viewportWidth - 1) div MapChunkWidthPixels,
      firstChunk,
      MapChunkCount - 1
    )
  for chunkIndex in firstChunk .. lastChunk:
    currentIds.add(chunkIndex.mapChunkObjectId())
    packet.addObject(
      chunkIndex.mapChunkObjectId(),
      chunkIndex * MapChunkWidthPixels - cameraX,
      -cameraY,
      low(int16).int + 1,
      MapLayerId,
      chunkIndex.mapChunkSpriteId()
    )

proc buildVisibilityShadowSprite(
  sim: SimServer,
  playerIndex,
  cameraX,
  cameraY: int
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a player-view shadow mask from terrain blockers and high elevation.
  result.width = PlayerViewportWidth
  result.height = PlayerViewportHeight
  result.pixels = newRgbaPixels(result.width, result.height)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let
    player = sim.players[playerIndex]
    fromTx = clamp(
      boundsCenterX(player.x, player.bounds) div WorldTileSize,
      0,
      WorldWidthTiles - 1
    )
    fromTy = clamp(
      boundsCenterY(player.y, player.bounds) div WorldTileSize,
      0,
      WorldHeightTiles - 1
    )
    startTx = max(0, cameraX div WorldTileSize)
    startTy = max(0, cameraY div WorldTileSize)
    endTx = min(
      WorldWidthTiles - 1,
      (cameraX + PlayerViewportWidth - 1) div WorldTileSize
    )
    endTy = min(
      WorldHeightTiles - 1,
      (cameraY + PlayerViewportHeight - 1) div WorldTileSize
    )
    hudTop = PlayerViewportHeight - WorldTileSize - CarryHudSlotGap
  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        visible = sim.tileVisibleFrom(fromTx, fromTy, tx, ty)
        blocker = sim.tileBlocksSight(tx, ty)
        alpha =
          if not visible:
            155'u8
          elif blocker and (tx != fromTx or ty != fromTy):
            58'u8
          else:
            0'u8
      if alpha == 0'u8:
        continue
      let
        tileScreenX = tx * WorldTileSize - cameraX
        tileScreenY = ty * WorldTileSize - cameraY
        sx0 = max(0, tileScreenX)
        sy0 = max(0, tileScreenY)
        sx1 = min(PlayerViewportWidth - 1, tileScreenX + WorldTileSize - 1)
        sy1 = min(PlayerViewportHeight - 1, tileScreenY + WorldTileSize - 1)
        color = (r: 0'u8, g: 0'u8, b: 0'u8, a: alpha)
      for sy in sy0 .. sy1:
        if sy >= hudTop:
          continue
        for sx in sx0 .. sx1:
          result.pixels.putRgbaPixel(sy * result.width + sx, color)

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

proc buildHudFrontierIconSprite(): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a tiny arrow/flag icon for the sprite-first player HUD.
  result.width = 13
  result.height = 11
  result.pixels = newRgbaPixels(result.width, result.height)
  result.pixels.fillRect(result.width, 1, 5, 9, 3, 10'u8)
  result.pixels.fillRect(result.width, 6, 2, 3, 9, 10'u8)
  result.pixels.putRgbaPixel(9 * result.width + 9, 10'u8)
  result.pixels.putRgbaPixel(8 * result.width + 10, 10'u8)
  result.pixels.putRgbaPixel(7 * result.width + 11, 10'u8)
  result.pixels.putRgbaPixel(6 * result.width + 12, 10'u8)
  result.pixels.putRgbaPixel(5 * result.width + 11, 10'u8)
  result.pixels.putRgbaPixel(4 * result.width + 10, 10'u8)
  result.pixels.putRgbaPixel(3 * result.width + 9, 10'u8)
  result.pixels.strokeRect(result.width, 0, 4, 10, 5, 2'u8)

proc buildHudWoodIconSprite(): tuple[width, height: int, pixels: seq[uint8]] =
  result.width = 13
  result.height = 11
  result.pixels = newRgbaPixels(result.width, result.height)
  result.pixels.fillRect(result.width, 2, 3, 9, 2, 6'u8)
  result.pixels.fillRect(result.width, 1, 6, 10, 2, 6'u8)
  result.pixels.strokeRect(result.width, 1, 2, 11, 7, 2'u8)

proc buildHudFoodIconSprite(): tuple[width, height: int, pixels: seq[uint8]] =
  result.width = 13
  result.height = 11
  result.pixels = newRgbaPixels(result.width, result.height)
  result.pixels.fillRect(result.width, 6, 2, 1, 8, 8'u8)
  for point in [
    (x: 4, y: 3),
    (x: 8, y: 3),
    (x: 3, y: 5),
    (x: 9, y: 5),
    (x: 4, y: 7),
    (x: 8, y: 7)
  ]:
    result.pixels.fillRect(result.width, point.x, point.y, 2, 2, 14'u8)

proc buildHudStoneIconSprite(): tuple[width, height: int, pixels: seq[uint8]] =
  result.width = 13
  result.height = 11
  result.pixels = newRgbaPixels(result.width, result.height)
  for y in 2 .. 8:
    let inset = abs(5 - y)
    result.pixels.fillRect(result.width, 3 + inset, y, 7 - inset * 2, 1, 12'u8)
  result.pixels.strokeRect(result.width, 3, 2, 7, 7, 2'u8)

proc buildHudRelicIconSprite(): tuple[width, height: int, pixels: seq[uint8]] =
  result.width = 13
  result.height = 11
  result.pixels = newRgbaPixels(result.width, result.height)
  for y in 1 .. 9:
    let inset = abs(5 - y)
    result.pixels.fillRect(result.width, 5 - inset div 2, y, 3 + inset, 1, 11'u8)
  result.pixels.strokeRect(result.width, 4, 1, 5, 9, 2'u8)

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

proc buildSpriteProtocolHudMeterSprite(
  current, maximum: int,
  fillColor: tuple[r, g, b, a: uint8]
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a wider true-color resource meter for the local player HUD.
  let
    value = clamp(current, 0, maximum)
    innerWidth = HudMeterWidth - HudMeterPad * 2
    innerHeight = HudMeterHeight - HudMeterPad * 2
  result.width = HudMeterWidth
  result.height = HudMeterHeight
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
    HudMeterPad,
    HudMeterPad,
    innerWidth,
    innerHeight,
    HealthBackColor
  )
  if maximum <= 0 or value <= 0:
    return
  let fillWidth = max(1, value * innerWidth div maximum)
  result.pixels.fillRgbaRect(
    result.width,
    HudMeterPad,
    HudMeterPad,
    fillWidth,
    innerHeight,
    fillColor
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
    "TANK GUARD"
  of PickupDpsGear:
    "DPS BEAM"
  of PickupHealerGear:
    "HEAL HOLD"
  else:
    ""

proc roleGearSpriteId(kind: PickupKind): int =
  RoleLabelSpriteBase + ord(kind)

proc roleGearIconSpriteId(kind: PickupKind): int =
  RoleGearIconSpriteBase + ord(kind)

proc roleGearIconLabel(kind: PickupKind): string =
  case kind
  of PickupTankGear:
    "role tank gear"
  of PickupDpsGear:
    "role dps gear"
  of PickupHealerGear:
    "role heal gear"
  else:
    ""

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

proc mobAttackEffectObjectId(mobIndex: int): int =
  MobAttackEffectObjectBase + mobIndex

proc roleAbilityEffectObjectId(player: Actor): int =
  RoleAbilityEffectObjectBase + player.id

proc dpsBeamObjectId(player: Actor): int =
  DpsBeamObjectBase + player.id

proc playerEffectAuraObjectId(player: Actor, index: int): int =
  PlayerEffectAuraObjectBase + player.id * PlayerEffectAuraSlots + index

proc roleAbilityEffectSpriteId(role: PlayerRole): int =
  RoleAbilityEffectSpriteBase + ord(role)

proc playerEffectAuraSpriteId(kind: PlayerEffectVisualKind): int =
  PlayerEffectAuraSpriteBase + ord(kind)

proc dpsBeamSpriteId(facing: Facing): int =
  if facing in {FaceLeft, FaceRight}:
    DpsBeamHorizontalSpriteId
  else:
    DpsBeamVerticalSpriteId

proc mobAttackEffectSpriteId(
  phase: MobAttackPhase,
  style = AttackLunge
): int =
  if style == AttackLunge and phase == MobTelegraph:
    MobTelegraphEffectSpriteId
  elif style == AttackLunge and phase == MobLunge:
    MobLungeEffectSpriteId
  elif phase == MobIdle:
    MobTelegraphEffectSpriteId
  else:
    MobAttackStyleEffectSpriteBase + ord(style) * 2 +
      (if phase == MobLunge: 1 else: 0)

proc mobAttackEffectLabel(
  phase: MobAttackPhase,
  style = AttackLunge
): string =
  if phase == MobIdle:
    return "mob idle"
  let styleLabel =
    case style
    of AttackLunge: "lunge"
    of AttackRanged: "dart"
    of AttackSlam: "slam"
    of AttackAura: "aura"
    of AttackCone: "cone"
    of AttackLine: "line"
    of AttackTrap: "trap"
    of AttackSupport: "support"
    of AttackSwarm: "swarm"
  if phase == MobTelegraph:
    if style == AttackLunge:
      "mob telegraph warning"
    else:
      "mob " & styleLabel & " warning"
  else:
    "mob " & styleLabel &
      (if style in {AttackAura, AttackSupport, AttackSwarm}: " pulse"
       else: " strike")

proc roleAbilityEffectLabel(role: PlayerRole): string =
  "ability " & role.roleLabel() & " effect"

proc playerEffectAuraLabel(kind: PlayerEffectVisualKind): string =
  case kind
  of EffectVisualPoison: "effect aura poison"
  of EffectVisualSlow: "effect aura slow"
  of EffectVisualChill: "effect aura chill"
  of EffectVisualExhaustion: "effect aura exhaustion"
  of EffectVisualMire: "effect aura mire"
  of EffectVisualCold: "effect aura cold"
  of EffectVisualHeat: "effect aura heat"
  of EffectVisualFog: "effect aura fog"
  of EffectVisualRoute: "effect aura route"
  of EffectVisualSurvey: "effect aura survey"
  of EffectVisualGuide: "effect aura guide"
  of EffectVisualHunt: "effect aura hunt"
  of EffectVisualTriumph: "effect aura triumph"
  of EffectVisualRation: "effect aura ration"
  of EffectVisualMorale: "effect aura morale"
  of EffectVisualMastery: "effect aura mastery"
  of EffectVisualGuard: "effect aura guard"
  of EffectVisualBlessing: "effect aura blessing"
  of EffectVisualForage: "effect aura forage"
  of EffectVisualRally: "effect aura rally"
  of EffectVisualShade: "effect aura shade"
  of EffectVisualWarmth: "effect aura warmth"
  of EffectVisualLight: "effect aura light"
  of EffectVisualTrio: "effect aura trio"

proc roleAbilityEffectColor(
  role: PlayerRole
): tuple[r, g, b, a: uint8] =
  case role
  of RoleTank:
    (r: 255'u8, g: 222'u8, b: 74'u8, a: 210'u8)
  of RoleDps:
    (r: 224'u8, g: 64'u8, b: 79'u8, a: 220'u8)
  of RoleHealer:
    (r: 86'u8, g: 210'u8, b: 122'u8, a: 220'u8)
  of RoleUnarmed:
    (r: 0'u8, g: 0'u8, b: 0'u8, a: 0'u8)

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

proc putEffectPixel(
  pixels: var seq[uint8],
  width,
  height,
  x,
  y: int,
  color: tuple[r, g, b, a: uint8]
) =
  if x < 0 or y < 0 or x >= width or y >= height:
    return
  pixels.putRgbaPixel(y * width + x, color)

proc buildMobAttackEffectSprite(
  phase: MobAttackPhase,
  style = AttackLunge
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a translucent attack-phase overlay for monster animations.
  result.width = MobAttackEffectSize
  result.height = MobAttackEffectSize
  result.pixels = newRgbaPixels(result.width, result.height)
  let
    center = MobAttackEffectSize div 2
    warning = (r: 255'u8, g: 222'u8, b: 74'u8, a: 190'u8)
    warningCore = (r: 255'u8, g: 248'u8, b: 180'u8, a: 225'u8)
    strike = (r: 255'u8, g: 64'u8, b: 79'u8, a: 210'u8)
    strikeCore = (r: 255'u8, g: 200'u8, b: 120'u8, a: 240'u8)
  if phase == MobTelegraph:
    for y in 0 ..< result.height:
      for x in 0 ..< result.width:
        let distance = abs(x - center) + abs(y - center)
        if distance in 10 .. 11:
          result.pixels.putEffectPixel(result.width, result.height, x, y, warning)
    case style
    of AttackRanged:
      for x in 5 .. 23:
        result.pixels.putEffectPixel(result.width, result.height, x, center, warningCore)
        if x mod 3 == 0:
          result.pixels.putEffectPixel(result.width, result.height, x, center - 2, warning)
          result.pixels.putEffectPixel(result.width, result.height, x, center + 2, warning)
    of AttackSlam:
      for i in 0 .. 13:
        for sx in [center - i, center + i]:
          result.pixels.putEffectPixel(result.width, result.height, sx, center + i div 2, warningCore)
    of AttackAura:
      for y in 0 ..< result.height:
        for x in 0 ..< result.width:
          let d = abs(x - center) + abs(y - center)
          if d in 5 .. 7 and (x + y) mod 2 == 0:
            result.pixels.putEffectPixel(result.width, result.height, x, y, warningCore)
    of AttackCone:
      for i in 0 .. 13:
        for spread in -i div 2 .. i div 2:
          result.pixels.putEffectPixel(result.width, result.height, center + spread, center - i, warningCore)
    of AttackLine:
      for y in 3 .. 25:
        result.pixels.putEffectPixel(result.width, result.height, center, y, warningCore)
        if y mod 4 == 0:
          result.pixels.putEffectPixel(result.width, result.height, center - 2, y, warning)
          result.pixels.putEffectPixel(result.width, result.height, center + 2, y, warning)
    of AttackTrap:
      for x in 7 .. 21:
        result.pixels.putEffectPixel(result.width, result.height, x, center - 7, warningCore)
        result.pixels.putEffectPixel(result.width, result.height, x, center + 7, warningCore)
      for y in center - 7 .. center + 7:
        result.pixels.putEffectPixel(result.width, result.height, 7, y, warning)
        result.pixels.putEffectPixel(result.width, result.height, 21, y, warning)
    of AttackSupport:
      for i in 0 .. 9:
        result.pixels.putEffectPixel(result.width, result.height, center - i, center, warningCore)
        result.pixels.putEffectPixel(result.width, result.height, center + i, center, warningCore)
        result.pixels.putEffectPixel(result.width, result.height, center, center - i, warningCore)
        result.pixels.putEffectPixel(result.width, result.height, center, center + i, warningCore)
    of AttackSwarm:
      for y in 5 .. 23:
        for x in 5 .. 23:
          if (x * 7 + y * 5) mod 17 == 0:
            result.pixels.putEffectPixel(result.width, result.height, x, y, warningCore)
    of AttackLunge:
      for y in 7 .. 16:
        result.pixels.putEffectPixel(result.width, result.height, center, y, warningCore)
        result.pixels.putEffectPixel(
          result.width,
          result.height,
          center + 1,
          y,
          warningCore
        )
      for y in 20 .. 21:
        for x in center .. center + 1:
          result.pixels.putEffectPixel(result.width, result.height, x, y, warningCore)
  elif phase == MobLunge:
    case style
    of AttackRanged:
      for x in 3 .. 25:
        result.pixels.putEffectPixel(result.width, result.height, x, center, strikeCore)
        result.pixels.putEffectPixel(result.width, result.height, x, center - 1, strike)
        result.pixels.putEffectPixel(result.width, result.height, x, center + 1, strike)
      for i in 0 .. 4:
        result.pixels.putEffectPixel(result.width, result.height, 25 - i, center - i, strike)
        result.pixels.putEffectPixel(result.width, result.height, 25 - i, center + i, strike)
    of AttackSlam:
      for y in 0 ..< result.height:
        for x in 0 ..< result.width:
          let d = abs(x - center) + abs(y - center)
          if d in 9 .. 12:
            result.pixels.putEffectPixel(result.width, result.height, x, y, strike)
      for x in center - 2 .. center + 2:
        for y in center - 2 .. center + 2:
          result.pixels.putEffectPixel(result.width, result.height, x, y, strikeCore)
    of AttackAura:
      for y in 0 ..< result.height:
        for x in 0 ..< result.width:
          let d = abs(x - center) + abs(y - center)
          if d in 4 .. 13 and (x + y) mod 3 != 0:
            result.pixels.putEffectPixel(result.width, result.height, x, y, strike)
    of AttackCone:
      for i in 0 .. 16:
        for spread in -i div 2 .. i div 2:
          result.pixels.putEffectPixel(result.width, result.height, center + spread, center - i, strike)
    of AttackLine:
      for y in 2 .. 26:
        for x in center - 1 .. center + 1:
          result.pixels.putEffectPixel(result.width, result.height, x, y, strikeCore)
    of AttackTrap:
      for x in 6 .. 22:
        for y in [6, 22]:
          result.pixels.putEffectPixel(result.width, result.height, x, y, strike)
      for y in 6 .. 22:
        for x in [6, 22]:
          result.pixels.putEffectPixel(result.width, result.height, x, y, strike)
    of AttackSupport:
      for y in 0 ..< result.height:
        for x in 0 ..< result.width:
          let d = abs(x - center) + abs(y - center)
          if d in 3 .. 11 and (x + y) mod 2 == 0:
            result.pixels.putEffectPixel(result.width, result.height, x, y, strikeCore)
    of AttackSwarm:
      for y in 4 .. 24:
        for x in 4 .. 24:
          if (x * 3 + y * 11) mod 13 in 0 .. 2:
            result.pixels.putEffectPixel(result.width, result.height, x, y, strike)
    of AttackLunge:
      for i in 0 .. 18:
        let
          x = 5 + i
          y = 21 - i
        result.pixels.putEffectPixel(result.width, result.height, x, y, strikeCore)
        result.pixels.putEffectPixel(result.width, result.height, x + 1, y, strike)
        result.pixels.putEffectPixel(result.width, result.height, x, y + 1, strike)
      for i in 0 .. 10:
        result.pixels.putEffectPixel(
          result.width,
          result.height,
          10 + i,
          18 - i div 2,
          strike
        )
        result.pixels.putEffectPixel(
          result.width,
          result.height,
          7 + i,
          10 + i div 3,
          strike
        )

proc buildRoleAbilityEffectSprite(
  role: PlayerRole
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds the red/yellow/green role-power pulse used by the sprite player.
  result.width = RoleAbilityEffectSize
  result.height = RoleAbilityEffectSize
  result.pixels = newRgbaPixels(result.width, result.height)
  let
    center = RoleAbilityEffectSize div 2
    color = role.roleAbilityEffectColor()
    core = (
      r: min(255, int(color.r) + 36).uint8,
      g: min(255, int(color.g) + 36).uint8,
      b: min(255, int(color.b) + 36).uint8,
      a: 238'u8
    )
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      let
        dx = x - center
        dy = y - center
        distance = dx * dx + dy * dy
      if distance in 400 .. 470:
        result.pixels.putEffectPixel(result.width, result.height, x, y, color)
      elif distance in 260 .. 286 and (x + y) mod 2 == 0:
        result.pixels.putEffectPixel(result.width, result.height, x, y, color)
  case role
  of RoleTank:
    for x in center - 14 .. center + 14:
      result.pixels.putEffectPixel(result.width, result.height, x, center - 15, core)
      result.pixels.putEffectPixel(result.width, result.height, x, center + 15, core)
    for y in center - 10 .. center + 10:
      result.pixels.putEffectPixel(result.width, result.height, center - 15, y, core)
      result.pixels.putEffectPixel(result.width, result.height, center + 15, y, core)
  of RoleDps:
    for offset in -17 .. 17:
      result.pixels.putEffectPixel(
        result.width,
        result.height,
        center + offset,
        center + offset,
        core
      )
      result.pixels.putEffectPixel(
        result.width,
        result.height,
        center + offset,
        center - offset,
        core
      )
  of RoleHealer:
    for offset in -18 .. 18:
      result.pixels.putEffectPixel(result.width, result.height, center + offset, center, core)
      result.pixels.putEffectPixel(result.width, result.height, center, center + offset, core)
    for y in center - 6 .. center + 6:
      for x in center - 6 .. center + 6:
        if abs(x - center) + abs(y - center) <= 6:
          result.pixels.putEffectPixel(result.width, result.height, x, y, color)
  of RoleUnarmed:
    discard

proc playerEffectAuraColors(
  kind: PlayerEffectVisualKind
): tuple[main, core, shade: tuple[r, g, b, a: uint8]] =
  case kind
  of EffectVisualPoison:
    (
      main: (r: 190'u8, g: 68'u8, b: 210'u8, a: 205'u8),
      core: (r: 114'u8, g: 238'u8, b: 130'u8, a: 235'u8),
      shade: (r: 70'u8, g: 42'u8, b: 96'u8, a: 145'u8)
    )
  of EffectVisualSlow, EffectVisualMire:
    (
      main: (r: 85'u8, g: 146'u8, b: 87'u8, a: 210'u8),
      core: (r: 188'u8, g: 231'u8, b: 132'u8, a: 235'u8),
      shade: (r: 70'u8, g: 52'u8, b: 34'u8, a: 150'u8)
    )
  of EffectVisualChill, EffectVisualCold, EffectVisualWarmth:
    (
      main: (r: 68'u8, g: 205'u8, b: 214'u8, a: 210'u8),
      core: (r: 230'u8, g: 252'u8, b: 255'u8, a: 238'u8),
      shade: (r: 67'u8, g: 118'u8, b: 174'u8, a: 150'u8)
    )
  of EffectVisualExhaustion, EffectVisualFog:
    (
      main: (r: 154'u8, g: 164'u8, b: 176'u8, a: 198'u8),
      core: (r: 246'u8, g: 248'u8, b: 252'u8, a: 226'u8),
      shade: (r: 62'u8, g: 68'u8, b: 80'u8, a: 132'u8)
    )
  of EffectVisualHeat, EffectVisualShade:
    (
      main: (r: 255'u8, g: 167'u8, b: 62'u8, a: 215'u8),
      core: (r: 255'u8, g: 235'u8, b: 124'u8, a: 238'u8),
      shade: (r: 184'u8, g: 58'u8, b: 42'u8, a: 150'u8)
    )
  of EffectVisualHunt:
    (
      main: (r: 224'u8, g: 64'u8, b: 79'u8, a: 220'u8),
      core: (r: 255'u8, g: 232'u8, b: 160'u8, a: 240'u8),
      shade: (r: 120'u8, g: 24'u8, b: 42'u8, a: 150'u8)
    )
  of EffectVisualGuard, EffectVisualLight, EffectVisualRoute, EffectVisualSurvey:
    (
      main: (r: 84'u8, g: 141'u8, b: 255'u8, a: 215'u8),
      core: (r: 218'u8, g: 236'u8, b: 255'u8, a: 238'u8),
      shade: (r: 38'u8, g: 54'u8, b: 112'u8, a: 145'u8)
    )
  of EffectVisualGuide, EffectVisualBlessing, EffectVisualForage:
    (
      main: (r: 86'u8, g: 210'u8, b: 122'u8, a: 215'u8),
      core: (r: 230'u8, g: 255'u8, b: 220'u8, a: 238'u8),
      shade: (r: 38'u8, g: 94'u8, b: 64'u8, a: 145'u8)
    )
  of EffectVisualTriumph, EffectVisualRation, EffectVisualMorale,
      EffectVisualMastery, EffectVisualRally, EffectVisualTrio:
    (
      main: (r: 255'u8, g: 222'u8, b: 74'u8, a: 220'u8),
      core: (r: 255'u8, g: 250'u8, b: 198'u8, a: 242'u8),
      shade: (r: 142'u8, g: 96'u8, b: 28'u8, a: 150'u8)
    )

proc buildPlayerEffectAuraSprite(
  kind: PlayerEffectVisualKind
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a translucent in-world marker for material buffs and debuffs.
  result.width = PlayerEffectAuraSize
  result.height = PlayerEffectAuraSize
  result.pixels = newRgbaPixels(result.width, result.height)
  let
    center = PlayerEffectAuraSize div 2
    colors = kind.playerEffectAuraColors()
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      let
        dx = x - center
        dy = y - center
        distanceSq = dx * dx + dy * dy
        manhattan = abs(dx) + abs(dy)
      case kind
      of EffectVisualSlow, EffectVisualMire:
        if y >= center + 7 and abs(dx) <= 15 and (x + y) mod 3 != 0:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.shade
          )
        elif distanceSq in 320 .. 380 and y >= center - 4:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.main
          )
      of EffectVisualPoison:
        if distanceSq in 250 .. 330 and (x * 5 + y * 7) mod 5 != 0:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.main
          )
        elif manhattan in 7 .. 9 and (x + y) mod 2 == 0:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.core
          )
      of EffectVisualChill, EffectVisualCold, EffectVisualWarmth:
        if distanceSq in 300 .. 360:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.main
          )
        if abs(dx) <= 1 or abs(dy) <= 1 or abs(abs(dx) - abs(dy)) <= 1:
          if manhattan in 8 .. 18 and (x + y) mod 3 != 0:
            result.pixels.putEffectPixel(
              result.width,
              result.height,
              x,
              y,
              colors.core
            )
      of EffectVisualHeat, EffectVisualShade:
        if distanceSq in 270 .. 350 and y <= center + 10:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.main
          )
        if y < center and abs(dx) <= (center - y) div 2 and (x + y) mod 2 == 0:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.core
          )
      of EffectVisualExhaustion, EffectVisualFog:
        if abs(dy) <= 6 and abs(dx) <= 17 and (x + y) mod 4 != 0:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.shade
          )
        if distanceSq in 310 .. 390 and (x * 3 + y) mod 3 != 0:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.main
          )
      of EffectVisualHunt:
        if distanceSq in 280 .. 340 or abs(dx) <= 1 or abs(dy) <= 1:
          if manhattan <= 19:
            result.pixels.putEffectPixel(
              result.width,
              result.height,
              x,
              y,
              if abs(dx) <= 1 or abs(dy) <= 1: colors.core else: colors.main
            )
      of EffectVisualGuard:
        if y >= center - 15 and y <= center + 13 and
            abs(dx) <= 15 - max(0, y - center) div 2 and
            (abs(dx) in 13 .. 15 or y in center - 15 .. center - 13 or
              y in center + 11 .. center + 13):
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.main
          )
      of EffectVisualBlessing, EffectVisualGuide, EffectVisualForage:
        if distanceSq in 300 .. 360:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.main
          )
        if (abs(dx) <= 2 and abs(dy) <= 13) or
            (abs(dy) <= 2 and abs(dx) <= 13):
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.core
          )
      of EffectVisualRoute, EffectVisualSurvey, EffectVisualLight:
        if distanceSq in 300 .. 360:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.main
          )
        if abs(dy) <= 2 and dx in -15 .. 12:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.core
          )
        if dx in 8 .. 15 and abs(dy) <= 15 - dx:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.core
          )
      of EffectVisualTriumph, EffectVisualRation, EffectVisualMorale,
          EffectVisualMastery, EffectVisualRally, EffectVisualTrio:
        if distanceSq in 300 .. 360:
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.main
          )
        if (abs(dx) <= 2 and abs(dy) <= 15) or
            (abs(dy) <= 2 and abs(dx) <= 15) or
            (abs(abs(dx) - abs(dy)) <= 1 and manhattan <= 18):
          result.pixels.putEffectPixel(
            result.width,
            result.height,
            x,
            y,
            colors.core
          )

proc buildDpsBeamSprite(
  horizontal: bool
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds the straight-line DPS beam used by the sprite player.
  let length = DpsBeamTiles * WorldTileSize
  if horizontal:
    result.width = length
    result.height = DpsBeamWidth
  else:
    result.width = DpsBeamWidth
    result.height = length
  result.pixels = newRgbaPixels(result.width, result.height)
  let
    red = (r: 224'u8, g: 64'u8, b: 79'u8, a: 215'u8)
    gold = (r: 255'u8, g: 222'u8, b: 74'u8, a: 235'u8)
    core = (r: 255'u8, g: 248'u8, b: 210'u8, a: 248'u8)
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      let
        longAxis = if horizontal: x else: y
        crossAxis = if horizontal: y else: x
        center = (if horizontal: result.height else: result.width) div 2
        distance = abs(crossAxis - center)
      if distance <= 1:
        result.pixels.putEffectPixel(result.width, result.height, x, y, core)
      elif distance <= 3:
        result.pixels.putEffectPixel(result.width, result.height, x, y, gold)
      elif distance <= 6 and (longAxis + crossAxis) mod 3 != 0:
        result.pixels.putEffectPixel(result.width, result.height, x, y, red)
      if longAxis mod 23 in 0 .. 2 and distance <= 7:
        result.pixels.putEffectPixel(result.width, result.height, x, y, gold)

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
  of StatusRoleTank: "TANK"
  of StatusRoleDps: "DPS"
  of StatusRoleHealer: "HEAL"
  of StatusTrio: "TRIO"
  of StatusPartyFocus: "FOCUS"
  of StatusHighGround: "HIGH"
  of StatusLowGround: "LOW"
  of StatusForage: "FORAGE"
  of StatusRally: "RALLY"
  of StatusShade: "SHADE"
  of StatusWarmth: "WARM"
  of StatusLight: "LIGHT"
  of StatusGuard: "GUARD"
  of StatusBlessing: "BLESS"
  of StatusRoute: "ROUTE"
  of StatusSurvey: "SCOUT"
  of StatusGuide: "GUIDE"
  of StatusHunt: "HUNT"
  of StatusTriumph: "WIN"
  of StatusRation: "MEAL"
  of StatusMorale: "MORALE"
  of StatusStagger: "STAGGER"
  of StatusPoison: "POISON"
  of StatusSlow: "SLOW"
  of StatusChill: "CHILL"
  of StatusExhaustion: "TIRED"
  of StatusMire: "MIRE"
  of StatusCold: "COLD"
  of StatusHeat: "HEAT"
  of StatusFog: "FOG"
  of StatusAlone: "ALONE"
  of StatusHelp: "HELP"
  of StatusDown: "DOWN"
  of StatusPingRegroup: "PING GO"
  of StatusPingHelp: "PING HELP"
  of StatusPingObjective: "PING OBJ"
  of StatusPingCamp: "PING CAMP"
  of StatusPingFood: "PING FOOD"
  of StatusPingRescue: "PING RES"
  of StatusPingLair: "PING LAIR"

proc statusBadgeColor(kind: StatusBadgeKind): uint8 =
  case kind
  of StatusRoleTank: 4'u8
  of StatusRoleDps: 3'u8
  of StatusRoleHealer: 10'u8
  of StatusTrio: 14'u8
  of StatusPartyFocus: 14'u8
  of StatusHighGround: 8'u8
  of StatusLowGround: 10'u8
  of StatusForage: 10'u8
  of StatusRally: 14'u8
  of StatusShade: 6'u8
  of StatusWarmth: 11'u8
  of StatusLight: 14'u8
  of StatusGuard: 4'u8
  of StatusBlessing: 14'u8
  of StatusRoute: 14'u8
  of StatusSurvey: 12'u8
  of StatusGuide: 2'u8
  of StatusHunt: 9'u8
  of StatusTriumph: 14'u8
  of StatusRation: 6'u8
  of StatusMorale: 14'u8
  of StatusStagger: 11'u8
  of StatusPoison: 13'u8
  of StatusSlow: 10'u8
  of StatusChill: 11'u8
  of StatusExhaustion: 7'u8
  of StatusMire: 10'u8
  of StatusCold: 11'u8
  of StatusHeat: 9'u8
  of StatusFog: 12'u8
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
  of StatusRoleTank: "status role tank"
  of StatusRoleDps: "status role dps"
  of StatusRoleHealer: "status role healer"
  of StatusTrio: "status trio"
  of StatusPartyFocus: "status party focus"
  of StatusHighGround: "status high ground"
  of StatusLowGround: "status low ground"
  of StatusForage: "status forage"
  of StatusRally: "status rally"
  of StatusShade: "status shade"
  of StatusWarmth: "status warmth"
  of StatusLight: "status light"
  of StatusGuard: "status guard"
  of StatusBlessing: "status blessing"
  of StatusRoute: "status route"
  of StatusSurvey: "status survey"
  of StatusGuide: "status guide"
  of StatusHunt: "status hunt"
  of StatusTriumph: "status triumph"
  of StatusRation: "status ration"
  of StatusMorale: "status morale"
  of StatusStagger: "status stagger"
  of StatusPoison: "status poison"
  of StatusSlow: "status slow"
  of StatusChill: "status chill"
  of StatusExhaustion: "status exhaust"
  of StatusMire: "status mire"
  of StatusCold: "status cold"
  of StatusHeat: "status heat"
  of StatusFog: "status fog"
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

proc roleStatusBadge(role: PlayerRole): tuple[found: bool, badge: StatusBadgeKind] =
  case role
  of RoleTank:
    (true, StatusRoleTank)
  of RoleDps:
    (true, StatusRoleDps)
  of RoleHealer:
    (true, StatusRoleHealer)
  of RoleUnarmed:
    (false, StatusRoleTank)

proc elevationStatusBadge(delta: int): tuple[found: bool, badge: StatusBadgeKind] =
  if delta >= ElevationCombatThreshold:
    (true, StatusHighGround)
  elif delta <= -ElevationCombatThreshold:
    (true, StatusLowGround)
  else:
    (false, StatusHighGround)

proc compactWorldEffects(
  effects: seq[PlayerEffectInfo]
): seq[PlayerEffectInfo] =
  ## Keeps in-world effect art to one readable player signal; the full list
  ## stays in the top-right HUD.
  for effect in effects:
    if effect.harmful:
      result.add(effect)
      return
  for effect in effects:
    case effect.key
    of "guard", "blessing", "route", "guide", "hunt", "triumph":
      result.add(effect)
      return
    else:
      discard

proc effectStatusBadge(
  effect: PlayerEffectInfo
): tuple[found: bool, badge: StatusBadgeKind] =
  case effect.key
  of "poison":
    (true, StatusPoison)
  of "slow":
    (true, StatusSlow)
  of "chill":
    (true, StatusChill)
  of "exhaustion":
    (true, StatusExhaustion)
  of "mire":
    (true, StatusMire)
  of "cold":
    (true, StatusCold)
  of "heat":
    (true, StatusHeat)
  of "fog":
    (true, StatusFog)
  of "guard":
    (true, StatusGuard)
  of "blessing":
    (true, StatusBlessing)
  of "route":
    (true, StatusRoute)
  of "guide":
    (true, StatusGuide)
  of "hunt":
    (true, StatusHunt)
  of "triumph":
    (true, StatusTriumph)
  else:
    (false, StatusForage)

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

proc landmarkSpriteId(landmark: Landmark): int =
  ## Returns the sprite id for one landmark instance.
  if landmark.kind == LandmarkCamp and landmark.done:
    LandmarkShelterSpriteId
  else:
    landmark.kind.landmarkSpriteId()

proc mobSpeciesSpriteId(species: MobSpecies, flipLeft: bool): int =
  ## Returns the generated sprite id for one biome monster species.
  MobSpeciesSpriteBase + (ord(species) - 1) * 2 + (if flipLeft: 1 else: 0)

proc armorSpriteId(kind: ArmorKind): int =
  ArmorSpriteBase + ord(kind)

proc pickupSpriteId(kind: PickupKind): int =
  ## Returns the protocol sprite id for one pickup kind.
  case kind
  of PickupCoin:
    CoinSpriteId
  of PickupHeart:
    HeartSpriteId
  of PickupTankGear, PickupDpsGear, PickupHealerGear:
    kind.roleGearIconSpriteId()
  of PickupWood, PickupFood, PickupStone, PickupGold:
    kind.carryForPickup().landmarkForCarry().landmarkSpriteId()
  of PickupArmor:
    ArmorScoutHood.armorSpriteId()

proc carryObjectId(player: Actor): int =
  CarryObjectBase + player.id

proc carryObjectId(player: Actor, item: CarryKind): int =
  let active = player.activeCarryItem()
  if item == active:
    player.carryObjectId()
  else:
    CarryExtraObjectBase + player.id * CarryObjectStride + ord(item)

proc carryCountObjectId(player: Actor, item: CarryKind): int =
  CarryCountObjectBase + player.id * CarryObjectStride + ord(item)

proc carryCountSpriteId(player: Actor, item: CarryKind): int =
  CarryCountSpriteBase + player.id * CarryObjectStride + ord(item)

proc hudCounterSpriteId(slot: int): int =
  HudCounterSpriteBase + slot

proc hudCounterValueObjectId(slot: int): int =
  HudCounterValueObjectBase + slot

proc hudCounterIconObjectId(slot: int): int =
  HudCounterIconObjectBase + slot

proc hudArmorObjectId(slot: ArmorSlot): int =
  HudArmorObjectBase + ord(slot)

proc hudEffectObjectId(slot: int): int =
  HudEffectObjectBase + slot

proc terrainObjectId(index: int): int =
  ## Returns the object id for one terrain prop instance.
  TerrainObjectBase + index

proc landmarkObjectId(index: int): int =
  ## Returns the object id for one landmark instance.
  LandmarkObjectBase + index

proc landmarkPromptSpriteId(kind: LandmarkKind): int =
  LandmarkPromptSpriteBase + ord(kind)

proc landmarkDynamicPromptSpriteId(index: int): int =
  LandmarkDynamicPromptSpriteBase + index

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
    "GATE HOLD"
  of LandmarkShrine:
    "SHRINE F" & $ShrineFoodBonus
  of LandmarkRescue:
    "RESCUE F" & $RescueFoodBonus
  of LandmarkLair:
    "LAIR"
  of LandmarkWaystation:
    "WAYPOINT"

proc landmarkPromptLabel(landmark: Landmark): string =
  if landmark.campIsAid():
    "AID"
  elif landmark.campIsRally():
    "RALLY"
  elif landmark.campIsWarded():
    "WARD"
  elif landmark.campIsFortified() and landmark.campIsProvisioned():
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

proc progressPercent(progress, total: int): int =
  clamp((max(0, progress) * 100) div max(1, total), 0, 100)

proc landmarkPromptLabel(sim: SimServer, landmark: Landmark): string =
  case landmark.kind
  of LandmarkFinalGate:
    if sim.bossDefeated and sim.relicShards >= FinalGateRelicCost and
        sim.campsActivated >= FinalGateCampCost:
      "GATE " & $landmark.progress.finalGateProgressPercent() & "%"
    elif sim.relicShards >= FinalGateRelicCost and
        sim.campsActivated >= FinalGateCampCost:
      "GATE BOSS"
    else:
      "GATE C" & $min(sim.campsActivated, FinalGateCampCost) & "/" &
        $FinalGateCampCost & " R" & $min(sim.relicShards, FinalGateRelicCost) &
        "/" & $FinalGateRelicCost
  of LandmarkRescue:
    if landmark.progress > 0:
      "RESCUE " & $progressPercent(landmark.progress, RescueEventTicks) & "%"
    else:
      landmark.landmarkPromptLabel()
  of LandmarkBeacon:
    if landmark.progress > 0:
      "RELIC " & $progressPercent(landmark.progress, BeaconAttunementTicks) & "%"
    else:
      landmark.landmarkPromptLabel()
  of LandmarkLair:
    if landmark.hp < LairHp:
      "LAIR " & $progressPercent(LairHp - max(0, landmark.hp), LairHp) & "%"
    else:
      landmark.landmarkPromptLabel()
  of LandmarkWaystation:
    let label = sim.tileBiomeKind(landmark.tx, landmark.ty).waystationPromptLabel()
    if landmark.progress > 0:
      label & " " & $progressPercent(
        landmark.progress,
        BiomeWaystationTicks
      ) & "%"
    else:
      label
  else:
    landmark.landmarkPromptLabel()

proc landmarkPromptColor(landmark: Landmark, prompt: string): uint8 =
  if prompt.contains("%"):
    14'u8
  elif landmark.campIsAid() or landmark.campIsRally() or
      landmark.campIsWarded() or landmark.campIsProvisioned():
    11'u8
  elif landmark.kind == LandmarkCamp and landmark.done:
    10'u8
  elif landmark.kind == LandmarkWaystation:
    14'u8
  else:
    2'u8

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
      icon = sim.pickupRgbaSprite(kind)
    packet.addSprite(
      kind.roleGearIconSpriteId(),
      icon.width,
      icon.height,
      icon.pixels,
      kind.roleGearIconLabel()
    )
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

  for kind in ArmorKind:
    if kind == ArmorNone:
      continue
    let armor = buildSpriteProtocolRawSprite(sim.armorRgbaSprites[kind])
    packet.addSprite(
      kind.armorSpriteId(),
      armor.width,
      armor.height,
      armor.pixels,
      "armor " & kind.armorLabel()
    )

  let guide = buildSpriteProtocolRawSprite(sim.rgbaLandmarkSprites[LandmarkRescue])
  packet.addSprite(
    GuideSpriteId,
    guide.width,
    guide.height,
    guide.pixels,
    "guide"
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

  for kind in PlayerEffectVisualKind:
    let effect = kind.buildPlayerEffectAuraSprite()
    packet.addSprite(
      kind.playerEffectAuraSpriteId(),
      effect.width,
      effect.height,
      effect.pixels,
      kind.playerEffectAuraLabel()
    )

  for style in MobAttackStyle:
    for phase in [MobTelegraph, MobLunge]:
      let effect = phase.buildMobAttackEffectSprite(style)
      packet.addSprite(
        phase.mobAttackEffectSpriteId(style),
        effect.width,
        effect.height,
        effect.pixels,
        phase.mobAttackEffectLabel(style)
      )

  for role in [RoleTank, RoleDps, RoleHealer]:
    let effect = role.buildRoleAbilityEffectSprite()
    packet.addSprite(
      role.roleAbilityEffectSpriteId(),
      effect.width,
      effect.height,
      effect.pixels,
      role.roleAbilityEffectLabel()
    )
  let
    dpsBeamHorizontal = buildDpsBeamSprite(true)
    dpsBeamVertical = buildDpsBeamSprite(false)
  packet.addSprite(
    DpsBeamHorizontalSpriteId,
    dpsBeamHorizontal.width,
    dpsBeamHorizontal.height,
    dpsBeamHorizontal.pixels,
    "ability dps beam horizontal"
  )
  packet.addSprite(
    DpsBeamVerticalSpriteId,
    dpsBeamVertical.width,
    dpsBeamVertical.height,
    dpsBeamVertical.pixels,
    "ability dps beam vertical"
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
      label = species.speciesLabel()
      tint = species.speciesTint()
      base = buildSpriteProtocolRawSprite(sim.mobSpeciesRgbaSprite(species))
      left = buildSpriteProtocolRawSprite(
        sim.mobSpeciesRgbaSprite(species),
        true
      )
      rightId = species.mobSpeciesSpriteId(false)
      leftId = species.mobSpeciesSpriteId(true)
      rightPixels =
        if sim.mobSpeciesHasGeneratedSprite(species):
          base.pixels
        else:
          base.pixels.tintSpritePixels(
            base.width,
            base.height,
            tint,
            species
          )
      leftPixels =
        if sim.mobSpeciesHasGeneratedSprite(species):
          left.pixels
        else:
          left.pixels.tintSpritePixels(
            left.width,
            left.height,
            tint,
            species
          )
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
  let shelter = buildSpriteProtocolRawSprite(
    sim.landmarkRgbaSprite(LandmarkCamp)
  )
  packet.addSprite(
    LandmarkShelterSpriteId,
    shelter.width,
    shelter.height,
    shelter.pixels,
    "shelter"
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
  for prompt in ["WARD", "RALLY", "AID"]:
    let
      promptSprite = sim.buildSpriteProtocolTextSprite([prompt], 11'u8)
      spriteId =
        if prompt == "WARD":
          LandmarkWardPromptSpriteId
        elif prompt == "RALLY":
          LandmarkRallyPromptSpriteId
        else:
          LandmarkAidPromptSpriteId
    packet.addSprite(
      spriteId,
      promptSprite.width,
      promptSprite.height,
      promptSprite.pixels,
      "prompt " & prompt.toLowerAscii()
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
  result.addViewport(MapLayerId, GlobalViewportWidth, GlobalViewportHeight)
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
  sim.addMapSpriteDefinitions(result)
  result.addCommonSpriteDefinitions(sim)

proc globalCameraX(sim: SimServer): int =
  ## Centers the bird's-eye global view on the party's rightward progress.
  if GlobalViewportWidth >= WorldWidthPixels:
    return 0
  var
    count = 0
    sumX = 0
    maxX = 0
  for player in sim.players:
    let centerX = boundsCenterX(player.x, player.bounds)
    sumX += centerX
    maxX = max(maxX, centerX)
    inc count
  if count == 0:
    return 0
  let focusX = max((sumX div count + maxX) div 2, SafeZoneRightPixels)
  worldClampPixel(
    focusX - GlobalViewportWidth div 3,
    WorldWidthPixels - GlobalViewportWidth
  )

proc buildSpriteProtocolPlayerInit(sim: SimServer): seq[uint8] =
  ## Builds the initial sprite player snapshot.
  result = @[]
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, PlayerViewportWidth, PlayerViewportHeight)
  result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
  result.addViewport(TopLeftLayerId, PlayerViewportWidth, 72)
  result.addLayer(TopRightLayerId, TopRightLayerType, UiLayerFlag)
  result.addViewport(TopRightLayerId, 172, 96)
  sim.addMapSpriteDefinitions(result)
  result.addCommonSpriteDefinitions(sim)
  let frontierIcon = buildHudFrontierIconSprite()
  result.addSprite(
    HudFrontierIconSpriteId,
    frontierIcon.width,
    frontierIcon.height,
    frontierIcon.pixels,
    "hud frontier icon"
  )
  let woodIcon = buildHudWoodIconSprite()
  result.addSprite(
    HudWoodIconSpriteId,
    woodIcon.width,
    woodIcon.height,
    woodIcon.pixels,
    "hud wood icon"
  )
  let foodIcon = buildHudFoodIconSprite()
  result.addSprite(
    HudFoodIconSpriteId,
    foodIcon.width,
    foodIcon.height,
    foodIcon.pixels,
    "hud food icon"
  )
  let stoneIcon = buildHudStoneIconSprite()
  result.addSprite(
    HudStoneIconSpriteId,
    stoneIcon.width,
    stoneIcon.height,
    stoneIcon.pixels,
    "hud stone icon"
  )
  let relicIcon = buildHudRelicIconSprite()
  result.addSprite(
    HudRelicIconSpriteId,
    relicIcon.width,
    relicIcon.height,
    relicIcon.pixels,
    "hud relic icon"
  )

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

proc addRoleAbilityEffectObjects(
  sim: SimServer,
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  cameraX,
  cameraY,
  viewportWidth,
  viewportHeight: int
) =
  ## Adds active player special-power pulses.
  for player in sim.players:
    if player.lives <= 0 or player.abilityTicks <= 0 or player.role == RoleUnarmed:
      continue
    let
      centerX = boundsCenterX(player.x, player.bounds)
      centerY = boundsCenterY(player.y, player.bounds)
      effectX = centerX - RoleAbilityEffectSize div 2 - cameraX
      effectY = centerY - RoleAbilityEffectSize div 2 - cameraY
    objects.addWorldSpriteObject(
      currentIds,
      player.roleAbilityEffectObjectId(),
      effectX,
      effectY,
      player.role.roleAbilityEffectSpriteId(),
      RoleAbilityEffectSize,
      RoleAbilityEffectSize,
      viewportWidth,
      viewportHeight,
      centerY - cameraY + RoleAbilityEffectSize
    )
    if player.role == RoleDps:
      let beam = player.dpsBeamRect()
      objects.addWorldSpriteObject(
        currentIds,
        player.dpsBeamObjectId(),
        beam.x - cameraX,
        beam.y - cameraY,
        player.facing.dpsBeamSpriteId(),
        beam.w,
        beam.h,
        viewportWidth,
        viewportHeight,
        centerY - cameraY + RoleAbilityEffectSize + 1
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
  packet: var seq[uint8],
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
    if landmark.done and landmark.kind != LandmarkCamp:
      continue
    let
      sprite = sim.landmarkRgbaSprite(landmark.kind)
      objectId = landmarkObjectId(i)
    objects.addWorldSpriteObject(
      currentIds,
      objectId,
      landmark.landmarkWorldX() - cameraX,
      landmark.landmarkWorldY() - cameraY,
      landmark.landmarkSpriteId(),
      sprite.width,
      sprite.height,
      viewportWidth,
      viewportHeight
    )
    let
      prompt = sim.landmarkPromptLabel(landmark)
      promptSprite = sim.buildSpriteProtocolTextSprite(
        [prompt],
        landmark.landmarkPromptColor(prompt)
      )
      promptSpriteId = i.landmarkDynamicPromptSpriteId()
      promptWidth = sim.textFont.textWidth(prompt)
      promptHeight = sim.textFont.height
    packet.addSprite(
      promptSpriteId,
      promptSprite.width,
      promptSprite.height,
      promptSprite.pixels,
      "prompt " & prompt.toLowerAscii()
    )
    objects.addWorldSpriteObject(
      currentIds,
      i.landmarkPromptObjectId(),
      landmark.landmarkWorldX() - cameraX -
        max(0, (promptWidth - sprite.width) div 2),
      landmark.landmarkWorldY() - cameraY - promptHeight - 3,
      promptSpriteId,
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
    packet,
    objects,
    currentIds,
    cameraX,
    cameraY,
    viewportWidth,
    viewportHeight
  )
  for i in 0 ..< sim.guides.len:
    let
      guide = sim.guides[i]
      sprite = sim.landmarkRgbaSprite(LandmarkRescue)
    objects.addWorldSpriteObject(
      currentIds,
      GuideObjectBase + i,
      guide.x - cameraX,
      guide.y - cameraY,
      GuideSpriteId,
      sprite.width,
      sprite.height,
      viewportWidth,
      viewportHeight
    )
    if guide.thanksTicks > 0:
      let bubble = sim.buildSpriteProtocolBubbleSprite("thank you")
      packet.addSprite(
        GuideBubbleSpriteBase + i,
        bubble.width,
        bubble.height,
        bubble.pixels,
        "guide thank you"
      )
      objects.addWorldSpriteObject(
        currentIds,
        GuideBubbleObjectBase + i,
        guide.x + sprite.width div 2 - bubble.width div 2 - cameraX,
        guide.y - bubble.height - 4 - cameraY,
        GuideBubbleSpriteBase + i,
        bubble.width,
        bubble.height,
        viewportWidth,
        viewportHeight,
        guide.y - cameraY - 1
      )
  let selectedPlayerIndex = sim.selectedPlayerIndex(selectedPlayerId)

  for i in 0 ..< sim.pickups.len:
    let
      pickup = sim.pickups[i]
      objectId = PickupObjectBase + i
      armorKind =
        if pickup.kind == PickupArmor:
          pickup.value.armorFromPickupValue()
        else:
          ArmorNone
      spriteId =
        if pickup.kind == PickupArmor:
          armorKind.armorSpriteId()
        else:
          pickup.kind.pickupSpriteId()
      sprite =
        if pickup.kind == PickupArmor:
          sim.armorRgbaSprites[armorKind]
        else:
          sim.pickupRgbaSprite(pickup.kind)
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
    elif pickup.kind == PickupArmor:
      let
        label = armorKind.armorLabel().toUpperAscii() & " " &
          armorKind.armorBonusLabel().toUpperAscii()
        labelSprite = sim.buildSpriteProtocolTextSprite([label], 8'u8)
        labelSpriteId = i.roleGearObjectId()
        labelWidth = sim.textFont.textWidth(label)
        labelHeight = sim.textFont.height
      packet.addSprite(
        labelSpriteId,
        labelSprite.width,
        labelSprite.height,
        labelSprite.pixels,
        "armor " & label.toLowerAscii()
      )
      objects.addWorldSpriteObject(
        currentIds,
        i.roleGearObjectId(),
        pickup.x - cameraX - max(0, (labelWidth - sprite.width) div 2),
        pickup.y - cameraY - labelHeight - 3,
        labelSpriteId,
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
    if mob.attackPhase in {MobTelegraph, MobLunge}:
      let
        effectForward =
          case mob.attackFacing
          of FaceLeft: -MobAttackEffectSize div 3
          of FaceRight: MobAttackEffectSize div 3
          of FaceUp, FaceDown: 0
        effectLift =
          case mob.attackPhase
          of MobTelegraph:
            if (mob.attackTicks div 8) mod 2 == 0: -2 else: 1
          of MobLunge:
            case mob.attackFacing
            of FaceUp: -MobAttackEffectSize div 3
            of FaceDown: MobAttackEffectSize div 3
            else: 0
          of MobIdle:
            0
        effectX = mob.x + mob.sprite.width div 2 -
          MobAttackEffectSize div 2 + effectForward
        effectY = drawY + mob.sprite.height div 2 -
          MobAttackEffectSize div 2 + effectLift
      objects.addWorldSpriteObject(
        currentIds,
        i.mobAttackEffectObjectId(),
        effectX - cameraX,
        effectY - cameraY,
        mob.attackPhase.mobAttackEffectSpriteId(mob.species.attackStyle()),
        MobAttackEffectSize,
        MobAttackEffectSize,
        viewportWidth,
        viewportHeight,
        drawY - cameraY + mob.sprite.height + 1
      )
    var badges: seq[StatusBadgeKind] = @[]
    if mob.partyFocusDamageBonus(sim.players, sim.tickCount) > 0:
      badges.add(StatusPartyFocus)
    if mob.bossStaggered():
      badges.add(StatusStagger)
    if selectedPlayerIndex >= 0:
      let elevationBadge = elevationStatusBadge(
        sim.mobTileElevation(mob) -
          sim.actorTileElevation(sim.players[selectedPlayerIndex])
      )
      if elevationBadge.found:
        badges.add(elevationBadge.badge)
    for badge in mob.species.threatBadges():
      badges.add(badge)
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

  let useCarryHud =
    viewportWidth == PlayerViewportWidth and viewportHeight == PlayerViewportHeight
  var carryHudSlot = 0
  for i in 0 ..< sim.players.len:
    let
      player = sim.players[i]
      selected = player.id == selectedPlayerId
      objectId = player.playerObjectId()
      playerSprite = sim.playerRgbaSpriteFor(player)
      downed = sim.playerDowned(i)
      worldEffects =
        if downed:
          newSeq[PlayerEffectInfo]()
        else:
          sim.activePlayerEffects(i).compactWorldEffects()
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
    if not downed:
      for effectIndex in 0 ..< min(worldEffects.len, PlayerEffectAuraSlots):
        let
          effect = worldEffects[effectIndex]
          centerX = boundsCenterX(player.x, player.bounds)
          centerY = boundsCenterY(player.y, player.bounds)
          offsetX =
            case effectIndex
            of 1: -5
            of 2: 5
            else: 0
          offsetY =
            case effectIndex
            of 0: 0
            of 1, 2: 3
            else: -5
          effectX = centerX - PlayerEffectAuraSize div 2 + offsetX - cameraX
          effectY = centerY - PlayerEffectAuraSize div 2 + offsetY - cameraY
        objects.addWorldSpriteObject(
          currentIds,
          player.playerEffectAuraObjectId(effectIndex),
          effectX,
          effectY,
          effect.visual.playerEffectAuraSpriteId(),
          PlayerEffectAuraSize,
          PlayerEffectAuraSize,
          viewportWidth,
          viewportHeight,
          player.y - cameraY + playerSprite.height + 1 + effectIndex
        )
    if player.activeCarryItem() != CarryNone and not downed:
      let carryUsesHud = useCarryHud and selected
      for item in CarryInventoryKinds:
        let count = player.carryCount(item)
        if count <= 0:
          continue
        if not carryUsesHud and item != player.activeCarryItem():
          continue
        let
          carriedLandmark = item.landmarkForCarry()
          carriedSprite = sim.landmarkRgbaSprite(carriedLandmark)
          carryX =
            if carryUsesHud:
              CarryHudSlotGap + carryHudSlot * (WorldTileSize + CarryHudSlotGap)
            else:
              player.x + playerSprite.width div 2 -
                carriedSprite.width div 2 - cameraX
          carryY =
            if carryUsesHud:
              viewportHeight - carriedSprite.height - CarryHudSlotGap
            else:
              player.y - carriedSprite.height div 2 - 5 - cameraY
          carrySortY =
            if carryUsesHud:
              viewportHeight + carryHudSlot
            else:
              player.y - cameraY
        objects.addWorldSpriteObject(
          currentIds,
          player.carryObjectId(item),
          carryX,
          carryY,
          carriedLandmark.landmarkSpriteId(),
          carriedSprite.width,
          carriedSprite.height,
          viewportWidth,
          viewportHeight,
          carrySortY
        )
        if carryUsesHud and count > 1:
          let
            countText = $count
            countSprite = sim.buildSpriteProtocolTextSprite([countText], 8'u8)
            countSpriteId = player.carryCountSpriteId(item)
            countObjectId = player.carryCountObjectId(item)
            countWidth = sim.textFont.textWidth(countText)
            countHeight = sim.textFont.height
          packet.addSprite(
            countSpriteId,
            countSprite.width,
            countSprite.height,
            countSprite.pixels,
            "carry " & item.carryLabel() & " x" & $count
          )
          objects.addWorldSpriteObject(
            currentIds,
            countObjectId,
            carryX + carriedSprite.width - countWidth,
            carryY + carriedSprite.height - countHeight,
            countSpriteId,
            countWidth,
            countHeight,
            viewportWidth,
            viewportHeight,
            carrySortY + 1
          )
        if carryUsesHud:
          inc carryHudSlot
    var badges: seq[StatusBadgeKind] = @[]
    if downed:
      badges.add(StatusDown)
    else:
      let roleBadge = player.role.roleStatusBadge()
      if roleBadge.found:
        badges.add(roleBadge.badge)
      if sim.playerInTrioFormation(i):
        badges.add(StatusTrio)
      if sim.playerNeedsHelp(i):
        badges.add(StatusHelp)
      elif sim.playerIsolationThreatened(i):
        badges.add(StatusAlone)
      if worldEffects.len > 0:
        let effectBadge = worldEffects[0].effectStatusBadge()
        if effectBadge.found:
          badges.add(effectBadge.badge)
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

  sim.addRoleAbilityEffectObjects(
    objects,
    currentIds,
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
    mana = clamp(player.mana, 0, MaxPlayerMana)
    counters = [
      (
        slot: 0,
        iconSpriteId: HudFrontierIconSpriteId,
        value: $frontier,
        x: 2,
        y: 2,
        label: "frontier"
      ),
      (
        slot: 1,
        iconSpriteId: HudWoodIconSpriteId,
        value: $sim.wood,
        x: 2,
        y: 26,
        label: "wood"
      ),
      (
        slot: 2,
        iconSpriteId: HudFoodIconSpriteId,
        value: $sim.food,
        x: 44,
        y: 26,
        label: "food"
      ),
      (
        slot: 3,
        iconSpriteId: HudStoneIconSpriteId,
        value: $sim.stone,
        x: 86,
        y: 26,
        label: "stone"
      ),
      (
        slot: 4,
        iconSpriteId: HudRelicIconSpriteId,
        value: $sim.relicShards,
        x: 128,
        y: 26,
        label: "relic"
      )
    ]
    effects = sim.activePlayerEffects(playerIndex)
    hudKey =
      counters.mapIt(it.label & ":" & it.value).join("|") &
        "|hp:" & $lives & "/" & $player.maxHp &
        "|mana:" & $mana & "/" & $MaxPlayerMana
    armorKey =
      block:
        var pieces: seq[string] = @[]
        for slot in ArmorSlot:
          pieces.add($ord(player.armor[slot]))
        for effect in effects:
          pieces.add(effect.key)
        pieces.join("|")

  if state.hudStatus != hudKey:
    let health = buildSpriteProtocolHudMeterSprite(
      lives,
      player.maxHp,
      healthFillColor(lives, player.maxHp)
    )
    packet.addSprite(
      LivesHudSpriteId,
      health.width,
      health.height,
      health.pixels,
      "hud hp " & $lives & "/" & $player.maxHp
    )
    let manaMeter = buildSpriteProtocolHudMeterSprite(
      mana,
      MaxPlayerMana,
      ManaFillColor
    )
    packet.addSprite(
      ManaHudSpriteId,
      manaMeter.width,
      manaMeter.height,
      manaMeter.pixels,
      "hud mana " & $mana & "/" & $MaxPlayerMana
    )
    for counter in counters:
      let counterText = sim.buildSpriteProtocolTextSprite(
        [counter.value],
        2'u8
      )
      packet.addSprite(
        counter.slot.hudCounterSpriteId(),
        counterText.width,
        counterText.height,
        counterText.pixels,
        "hud " & counter.label & " " & counter.value
      )

  for counter in counters:
    currentIds.add(counter.slot.hudCounterIconObjectId())
    packet.addObject(
      counter.slot.hudCounterIconObjectId(),
      counter.x,
      counter.y,
      high(int16),
      TopLeftLayerId,
      counter.iconSpriteId
    )
    currentIds.add(counter.slot.hudCounterValueObjectId())
    packet.addObject(
      counter.slot.hudCounterValueObjectId(),
      counter.x + 15,
      counter.y + 3,
      high(int16),
      TopLeftLayerId,
      counter.slot.hudCounterSpriteId()
    )

  currentIds.add(LivesHudObjectId)
  packet.addObject(
    LivesHudObjectId,
    50,
    4,
    high(int16),
    TopLeftLayerId,
    LivesHudSpriteId
  )

  currentIds.add(ManaHudObjectId)
  packet.addObject(
    ManaHudObjectId,
    50,
    12,
    high(int16),
    TopLeftLayerId,
    ManaHudSpriteId
  )

  var armorX = 2
  for slot in ArmorSlot:
    let armor = player.armor[slot]
    if armor == ArmorNone:
      continue
    currentIds.add(slot.hudArmorObjectId())
    packet.addObject(
      slot.hudArmorObjectId(),
      armorX,
      2,
      high(int16),
      TopRightLayerId,
      armor.armorSpriteId()
    )
    armorX += 20

  for effectIndex in 0 ..< min(effects.len, 4):
    let effect = effects[effectIndex]
    currentIds.add(effectIndex.hudEffectObjectId())
    packet.addObject(
      effectIndex.hudEffectObjectId(),
      2 + effectIndex * 42,
      28,
      high(int16),
      TopRightLayerId,
      effect.visual.playerEffectAuraSpriteId()
    )

  nextState.hudCoins = frontier
  nextState.hudLives = lives
  nextState.hudStatus = hudKey
  nextState.hudArmor = armorKey

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
    result.addMapAnchorObject(currentIds, cameraX, cameraY)
    result.addMapChunkObjects(currentIds, cameraX, cameraY, PlayerViewportWidth)
    sim.addWorldObjects(
      result,
      currentIds,
      cameraX,
      cameraY,
      PlayerViewportWidth,
      PlayerViewportHeight,
      player.id
    )
    let shadow = sim.buildVisibilityShadowSprite(playerIndex, cameraX, cameraY)
    currentIds.add(VisibilityShadowObjectId)
    result.addSprite(
      VisibilityShadowSpriteId,
      shadow.width,
      shadow.height,
      shadow.pixels,
      "visibility shadow"
    )
    result.addObject(
      VisibilityShadowObjectId,
      0,
      0,
      high(int16) - 200,
      MapLayerId,
      VisibilityShadowSpriteId
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
  let
    cameraX = sim.globalCameraX()
    cameraY = 0
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
          sim.selectSpritePlayer(
            nextState.mouseX + cameraX,
            nextState.mouseY + cameraY
          )
    elif nextState.mouseLayer == MapLayerId:
      nextState.selectedPlayerId =
        sim.selectSpritePlayer(
          nextState.mouseX + cameraX,
          nextState.mouseY + cameraY
        )
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
  result.addMapAnchorObject(currentIds, cameraX, cameraY)
  result.addMapChunkObjects(currentIds, cameraX, cameraY, GlobalViewportWidth)
  sim.addWorldObjects(
    result,
    currentIds,
    cameraX,
    cameraY,
    GlobalViewportWidth,
    GlobalViewportHeight,
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

import std/[os, strutils]
import supersnappy
import protocol, sim
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

var TransportSheet: Sprite

type
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

proc initGlobalViewerState*(): GlobalViewerState =
  ## Returns the default state for one global protocol viewer.
  result.mouseLayer = MapLayerId
  result.selectedPlayerId = -1
  result.replaySeekTick = -1
  result.replayCommands = @[]

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
          {0x81'u8, 0x82'u8, 0x83'u8}:
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
    else:
      return
proc isSolid(sprite: Sprite, x, y: int): bool =
  ## Returns true when a sprite source coordinate is opaque.
  if x < 0 or x >= sprite.width or y < 0 or y >= sprite.height:
    return false
  sprite.pixels[sprite.spriteIndex(x, y)] != TransparentColorIndex

proc facedSize(sprite: Sprite, facing: Facing): tuple[width, height: int] =
  ## Returns the rendered size for a facing rotation.
  case facing
  of FaceUp, FaceDown:
    (sprite.width, sprite.height)
  of FaceLeft, FaceRight:
    (sprite.height, sprite.width)

proc sourceForFacing(
  sprite: Sprite,
  x, y: int,
  facing: Facing
): tuple[x, y: int] =
  ## Converts a faced sprite coordinate to a source coordinate.
  case facing
  of FaceDown:
    (x, y)
  of FaceUp:
    (sprite.width - 1 - x, sprite.height - 1 - y)
  of FaceLeft:
    (sprite.width - 1 - y, x)
  of FaceRight:
    (y, sprite.height - 1 - x)

proc buildSpriteProtocolActorSprite(
  sprite: Sprite,
  tint: uint8,
  facing: Facing,
  selected = false
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds an outlined, tinted actor sprite for the global viewer.
  let
    size = sprite.facedSize(facing)
    outline = if selected: 8'u8 else: 0'u8
  result.width = size.width + 2
  result.height = size.height + 2
  result.pixels = newRgbaPixels(result.width, result.height)
  let outWidth = result.width

  proc outIndex(x, y: int): int =
    y * outWidth + x

  proc facedSolid(x, y: int): bool =
    if x < 0 or x >= size.width or y < 0 or y >= size.height:
      return false
    let src = sprite.sourceForFacing(x, y, facing)
    sprite.isSolid(src.x, src.y)

  for y in -1 .. size.height:
    for x in -1 .. size.width:
      if facedSolid(x, y):
        continue
      let adjacent =
        facedSolid(x - 1, y) or
        facedSolid(x + 1, y) or
        facedSolid(x, y - 1) or
        facedSolid(x, y + 1)
      if adjacent:
        result.pixels.putRgbaPixel(outIndex(x + 1, y + 1), outline)

  for y in 0 ..< size.height:
    for x in 0 ..< size.width:
      let src = sprite.sourceForFacing(x, y, facing)
      let colorIndex = sprite.pixels[sprite.spriteIndex(src.x, src.y)]
      if colorIndex != TransparentColorIndex:
        result.pixels.putRgbaPixel(outIndex(x + 1, y + 1), tint)

proc buildSpriteProtocolRawSprite(
  sprite: Sprite
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a raw global protocol sprite from a game sprite.
  result.width = sprite.width
  result.height = sprite.height
  result.pixels = newRgbaPixels(sprite.width, sprite.height)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        result.pixels.putRgbaPixel(sprite.spriteIndex(x, y), colorIndex)

proc buildSpriteProtocolMapSprite(sim: SimServer): seq[uint8] =
  ## Builds a full world map sprite using the same wall tiles as the game.
  result = newRgbaPixels(WorldWidthPixels, WorldHeightPixels)
  for i in 0 ..< WorldWidthPixels * WorldHeightPixels:
    result.putRgbaPixel(i, BackgroundColor)
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      if not sim.tiles[tileIndex(tx, ty)]:
        continue
      let
        baseX = tx * TileSize
        baseY = ty * TileSize
      for y in 0 ..< sim.terrainSprite.height:
        for x in 0 ..< sim.terrainSprite.width:
          let colorIndex =
            sim.terrainSprite.pixels[sim.terrainSprite.spriteIndex(x, y)]
          if colorIndex != TransparentColorIndex:
            result.putRgbaPixel(
              (baseY + y) * WorldWidthPixels + baseX + x,
              colorIndex
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
    if ch == ' ':
      x += 6
      continue
    if ch >= '0' and ch <= '9':
      target.blitGlyph(
        targetWidth,
        targetHeight,
        sim.digitSprites[ord(ch) - ord('0')],
        x,
        baseY,
        color
      )
    else:
      let letter = letterIndex(ch)
      if letter >= 0 and letter < sim.letterSprites.len:
        target.blitGlyph(
          targetWidth,
          targetHeight,
          sim.letterSprites[letter],
          x,
          baseY,
          color
        )
    x += 6

proc buildSpriteProtocolTextSprite(
  sim: SimServer,
  lines: openArray[string],
  color: uint8
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a transparent multi-line text sprite.
  result.width = 1
  for line in lines:
    result.width = max(result.width, line.len * 6)
  result.height = max(1, lines.len * 8 - 1)
  result.pixels = newRgbaPixels(result.width, result.height)
  for lineIndex, line in lines:
    let baseY = lineIndex * 8
    var baseX = 0
    for ch in line:
      if ch == ' ':
        baseX += 6
        continue
      if ch >= '0' and ch <= '9':
        let sprite = sim.digitSprites[ord(ch) - ord('0')]
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
      else:
        let letter = letterIndex(ch)
        if letter >= 0 and letter < sim.letterSprites.len:
          let sprite = sim.letterSprites[letter]
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
      baseX += 6

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

proc spritePixelsFromPackedFrame(packed: openArray[uint8]): seq[uint8] =
  ## Converts a packed Bitworld frame into protocol sprite pixels.
  result = newRgbaPixels(ScreenWidth, ScreenHeight)
  var j = 0
  for byte in packed:
    result.putRgbaPixel(j, byte and 0x0f)
    inc j
    result.putRgbaPixel(j, (byte shr 4) and 0x0f)
    inc j

proc playerObjectId(player: Actor): int =
  ## Returns the stable global protocol object id for a player.
  PlayerObjectBase + player.id

proc playerSpriteId(playerIndex: int, selected: bool): int =
  ## Returns the upright sprite id for a player color.
  let
    colorIndex = playerIndex mod PlayerColors.len
    base = if selected: SelectedPlayerSpriteBase else: PlayerSpriteBase
  base + colorIndex

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
      size = player.sprite.facedSize(FaceDown)
      x = player.x - 1 - PlayerSelectPadding
      y = player.y - 1 - PlayerSelectPadding
      w = size.width + 2 + PlayerSelectPadding * 2
      h = size.height + 2 + PlayerSelectPadding * 2
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

proc buildSpriteProtocolInit(sim: SimServer): seq[uint8] =
  ## Builds the initial global viewer snapshot.
  result = @[]
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, WorldWidthPixels, WorldHeightPixels)
  result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
  result.addViewport(TopLeftLayerId, ScreenWidth, 24)
  result.addLayer(BottomRightLayerId, BottomRightLayerType, UiLayerFlag)
  result.addViewport(BottomRightLayerId, ScreenWidth, ScreenHeight)
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

  for i in 0 ..< PlayerColors.len:
    let
      playerSprite = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        FaceDown
      )
      selectedPlayerSprite = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        FaceDown,
        true
      )
    result.addSprite(
      PlayerSpriteBase + i,
      playerSprite.width,
      playerSprite.height,
      playerSprite.pixels
    )
    result.addSprite(
      SelectedPlayerSpriteBase + i,
      selectedPlayerSprite.width,
      selectedPlayerSprite.height,
      selectedPlayerSprite.pixels
    )

  let
    mob = buildSpriteProtocolRawSprite(sim.mobSprite)
    boss = buildSpriteProtocolRawSprite(sim.bossSprite)
    coin = buildSpriteProtocolRawSprite(sim.coinSprite)
    heart = buildSpriteProtocolRawSprite(sim.heartSprite)
  result.addSprite(MobSpriteId, mob.width, mob.height, mob.pixels)
  result.addSprite(BossSpriteId, boss.width, boss.height, boss.pixels)
  result.addSprite(CoinSpriteId, coin.width, coin.height, coin.pixels)
  result.addSprite(HeartSpriteId, heart.width, heart.height, heart.pixels)

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
  for i in 0 ..< sim.players.len:
    let
      player = sim.players[i]
      selected = player.id == nextState.selectedPlayerId
      objectId = player.playerObjectId()
    currentIds.add(objectId)
    result.addObject(
      objectId,
      player.x - 1,
      player.y - 1,
      player.y,
      MapLayerId,
      playerSpriteId(i, selected)
    )

  for i in 0 ..< sim.mobs.len:
    let
      mob = sim.mobs[i]
      objectId = MobObjectBase + i
      spriteId = if mob.kind == BossMob: BossSpriteId else: MobSpriteId
    currentIds.add(objectId)
    result.addObject(
      objectId,
      mob.x,
      mob.y,
      mob.y,
      MapLayerId,
      spriteId
    )

  for i in 0 ..< sim.pickups.len:
    let
      pickup = sim.pickups[i]
      objectId = PickupObjectBase + i
      spriteId =
        if pickup.kind == PickupCoin: CoinSpriteId else: HeartSpriteId
    currentIds.add(objectId)
    result.addObject(
      objectId,
      pickup.x,
      pickup.y,
      pickup.y,
      MapLayerId,
      spriteId
    )

  let playerIndex = sim.selectedPlayerIndex(nextState.selectedPlayerId)
  if playerIndex >= 0:
    var lines: seq[string] = @[]
    let player = sim.players[playerIndex]
    lines.add("PLAYER " & player.playerIdentity())
    lines.add("COINS " & $player.coins)
    lines.add("LIVES " & $player.lives)
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

  if playerIndex >= 0:
    let viewport = spritePixelsFromPackedFrame(
      sim.render(playerIndex)
    )
    currentIds.add(SelectedViewportObjectId)
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

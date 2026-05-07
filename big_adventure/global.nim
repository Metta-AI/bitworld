import std/[algorithm, os, strutils]
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
  BubbleFillColor = 1'u8
  BubbleBorderColor = 7'u8
  BubbleTextColor = 7'u8
  BubblePad = 2
  BubblePointerHeight = 3
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

  PlayerViewerState* = object
    initialized*: bool
    objectIds*: seq[int]

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
  discard

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

proc addWorldSpriteObject(
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  objectId, x, y, spriteId, spriteHeight: int
) =
  ## Queues one world sprite object for game-side depth sorting.
  currentIds.add(objectId)
  objects.add(WorldSpriteObject(
    id: objectId,
    x: x,
    y: y,
    spriteId: spriteId,
    sortY: y + spriteHeight
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
  sprite: RgbaSprite
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a raw global protocol sprite from a true-color sprite.
  result.width = sprite.width
  result.height = sprite.height
  result.pixels = newSeq[uint8](sprite.pixels.len)
  for i in 0 ..< sprite.pixels.len:
    result.pixels[i] = sprite.pixels[i]

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

proc buildSpriteProtocolMapSprite(sim: SimServer): seq[uint8] =
  ## Builds a full world map sprite from the described terrain cells.
  result = newRgbaPixels(WorldWidthPixels, WorldHeightPixels)
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      result.blitMapSprite(
        sim.rgbaTerrainSprite,
        tx * WorldTileSize,
        ty * WorldTileSize
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

proc asciiIndex(ch: char): int =
  ## Returns the shared ASCII glyph index.
  ord(ch) - ord(' ')

proc asciiTextWidth(text: string): int =
  ## Returns the width of one fixed-width ASCII line.
  text.len * AsciiGlyphW

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

proc blitAsciiText(
  sim: SimServer,
  target: var seq[uint8],
  targetWidth, targetHeight: int,
  text: string,
  baseX, baseY: int,
  color: uint8
) =
  ## Blits fixed-width ASCII text into protocol pixels.
  var offsetX = 0
  for ch in text:
    let index = ch.asciiIndex()
    if index >= 0 and index < sim.asciiSprites.len:
      target.blitGlyph(
        targetWidth,
        targetHeight,
        sim.asciiSprites[index],
        baseX + offsetX,
        baseY,
        color
      )
    offsetX += AsciiGlyphW

proc buildSpriteProtocolBubbleSprite(
  sim: SimServer,
  text: string
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds one speech bubble sprite.
  let lineCount = text.lineCountForText()
  var longestLineWidth = AsciiGlyphW
  for lineIndex in 0 ..< lineCount:
    longestLineWidth = max(
      longestLineWidth,
      text.sliceMessageLine(lineIndex).asciiTextWidth()
    )
  result.width = longestLineWidth + BubblePad * 2
  result.height =
    lineCount * AsciiGlyphH + BubblePad * 2 + BubblePointerHeight
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
      BubblePad + lineIndex * AsciiGlyphH,
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

proc swooshSpriteId(form: PlayerForm, facing: Facing): int =
  ## Returns the sprite id for one adventurer attack swish facing.
  SwooshSpriteBase + ord(form) * 4 + ord(facing)

proc terrainSpriteId(kind: TerrainKind): int =
  ## Returns the sprite id for one terrain prop kind.
  TerrainSpriteBase + ord(kind)

proc terrainObjectId(index: int): int =
  ## Returns the object id for one terrain prop instance.
  TerrainObjectBase + index

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
          playerSprite.pixels
        )
        packet.addSprite(
          playerSpriteId(i, form, true, facing),
          selectedPlayerSprite.width,
          selectedPlayerSprite.height,
          selectedPlayerSprite.pixels
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

  let
    mob = buildSpriteProtocolRawSprite(sim.rgbaMobSprite)
    troll = buildSpriteProtocolRawSprite(sim.rgbaTrollSprite)
    boss = buildSpriteProtocolRawSprite(sim.rgbaBossSprite)
    coin = buildSpriteProtocolRawSprite(sim.rgbaCoinSprite)
    heart = buildSpriteProtocolRawSprite(sim.rgbaHeartSprite)
  packet.addSprite(MobSpriteId, mob.width, mob.height, mob.pixels, "ghost")
  packet.addSprite(
    TrollSpriteId,
    troll.width,
    troll.height,
    troll.pixels,
    "troll"
  )
  packet.addSprite(
    BossSpriteId,
    boss.width,
    boss.height,
    boss.pixels,
    "pigman"
  )
  packet.addSprite(CoinSpriteId, coin.width, coin.height, coin.pixels, "coin")
  packet.addSprite(
    HeartSpriteId,
    heart.width,
    heart.height,
    heart.pixels,
    "heart"
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

proc buildSpriteProtocolInit(sim: SimServer): seq[uint8] =
  ## Builds the initial global viewer snapshot.
  result = @[]
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, WorldWidthPixels, WorldHeightPixels)
  result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
  result.addViewport(TopLeftLayerId, ScreenWidth, 24)
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
  result.addViewport(MapLayerId, ScreenWidth, ScreenHeight)
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

proc addSpeechBubbles(
  sim: SimServer,
  packet: var seq[uint8],
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  cameraX, cameraY: int
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
      centerX = player.x + sprite.width div 2 - cameraX
      x = centerX - bubble.width div 2
      y = player.y - bubble.height - 4 - cameraY
    currentIds.add(objectId)
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
      bubble.height
    )

proc addAttackObjects(
  sim: SimServer,
  packet: var seq[uint8],
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  cameraX, cameraY: int
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
      hit.h
    )

proc addTerrainObjects(
  sim: SimServer,
  objects: var seq[WorldSpriteObject],
  currentIds: var seq[int],
  cameraX, cameraY: int
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
      sprite.height
    )

proc addWorldObjects(
  sim: SimServer,
  packet: var seq[uint8],
  currentIds: var seq[int],
  cameraX, cameraY: int,
  selectedPlayerId = -1
) =
  ## Adds pickups, mobs, players, attacks, and speech bubbles.
  var objects: seq[WorldSpriteObject] = @[]
  sim.addTerrainObjects(objects, currentIds, cameraX, cameraY)

  for i in 0 ..< sim.pickups.len:
    let
      pickup = sim.pickups[i]
      objectId = PickupObjectBase + i
      spriteId =
        if pickup.kind == PickupCoin: CoinSpriteId else: HeartSpriteId
      sprite = sim.pickupRgbaSprite(pickup.kind)
    objects.addWorldSpriteObject(
      currentIds,
      objectId,
      pickup.x - cameraX,
      pickup.y - cameraY,
      spriteId,
      sprite.height
    )

  for i in 0 ..< sim.mobs.len:
    let
      mob = sim.mobs[i]
      objectId = MobObjectBase + i
      spriteId =
        case mob.kind
        of SnakeMob:
          MobSpriteId
        of TrollMob:
          TrollSpriteId
        of BossMob:
          BossSpriteId
    objects.addWorldSpriteObject(
      currentIds,
      objectId,
      mob.x - cameraX,
      mob.y - cameraY,
      spriteId,
      mob.sprite.height
    )

  for i in 0 ..< sim.players.len:
    let
      player = sim.players[i]
      selected = player.id == selectedPlayerId
      objectId = player.playerObjectId()
    if player.lives <= 0:
      continue
    objects.addWorldSpriteObject(
      currentIds,
      objectId,
      player.x - 1 - cameraX,
      player.y - 1 - cameraY,
      playerSpriteId(
        i,
        player.form,
        selected,
        player.facing
      ),
      sim.playerRgbaSpriteFor(player).height + 2
    )

  sim.addAttackObjects(packet, objects, currentIds, cameraX, cameraY)
  sim.addSpeechBubbles(packet, objects, currentIds, cameraX, cameraY)
  packet.flushWorldSpriteObjects(objects)

proc addPlayerHud(
  sim: SimServer,
  packet: var seq[uint8],
  currentIds: var seq[int],
  playerIndex: int
) =
  ## Adds the local player HUD to a sprite-player view.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let
    player = sim.players[playerIndex]
    lines = [
      "COINS " & $min(player.coins, 99),
      "LIVES " & $max(player.lives, 0)
    ]
    text = sim.buildSpriteProtocolTextSprite(lines, 2'u8)
  currentIds.add(PlayerHudObjectId)
  packet.addSprite(
    PlayerHudSpriteId,
    text.width,
    text.height,
    text.pixels,
    "hud"
  )
  packet.addObject(
    PlayerHudObjectId,
    2,
    2,
    high(int16),
    MapLayerId,
    PlayerHudSpriteId
  )

proc addPlayerStatus(
  sim: SimServer,
  packet: var seq[uint8],
  currentIds: var seq[int],
  lines: openArray[string]
) =
  ## Adds centered status text to a sprite-player view.
  let
    text = sim.buildSpriteProtocolTextSprite(lines, 2'u8)
    x = max(0, (ScreenWidth - text.width) div 2)
    y = max(0, (ScreenHeight - text.height) div 2)
  currentIds.add(PlayerHudObjectId)
  packet.addSprite(
    PlayerHudSpriteId,
    text.width,
    text.height,
    text.pixels,
    "status"
  )
  packet.addObject(
    PlayerHudObjectId,
    x,
    y,
    high(int16),
    MapLayerId,
    PlayerHudSpriteId
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
        player.x + player.sprite.width div 2 - ScreenWidth div 2,
        WorldWidthPixels - ScreenWidth
      )
      cameraY = worldClampPixel(
        player.y + player.sprite.height div 2 - ScreenHeight div 2,
        WorldHeightPixels - ScreenHeight
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
      cameraY
    )
    sim.addPlayerHud(result, currentIds, playerIndex)
    if player.lives <= 0:
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
    nextState.selectedPlayerId
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

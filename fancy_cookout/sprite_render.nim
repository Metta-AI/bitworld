import
  supersnappy,
  pixie

const
  SpriteScreenWidth* = 128
  SpriteScreenHeight* = 128
  FancyTileSize* = 12

type
  RgbaSprite* = object
    width*, height*: int
    pixels*: seq[uint8]

  SpriteCacheEntry* = object
    spriteId*: int
    width*, height*: int
    pixels*: seq[uint8]

  SpriteViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    spriteCache*: seq[SpriteCacheEntry]

proc initSpriteViewerState*(): SpriteViewerState =
  discard

proc newRgbaSprite*(width, height: int): RgbaSprite =
  result.width = width
  result.height = height
  result.pixels = newSeq[uint8](width * height * 4)

proc putPixel*(sprite: var RgbaSprite, x, y: int, r, g, b, a: uint8) =
  if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height:
    return
  let offset = (y * sprite.width + x) * 4
  sprite.pixels[offset] = r
  sprite.pixels[offset + 1] = g
  sprite.pixels[offset + 2] = b
  sprite.pixels[offset + 3] = a

proc paletteToRgba*(palette: array[16, ColorRGBA], indexed: seq[uint8], width, height: int): RgbaSprite =
  result = newRgbaSprite(width, height)
  for i in 0 ..< width * height:
    let idx = indexed[i]
    if idx == 255 or idx >= 16:
      # transparent
      discard
    else:
      let c = palette[idx]
      let offset = i * 4
      result.pixels[offset] = c.r
      result.pixels[offset + 1] = c.g
      result.pixels[offset + 2] = c.b
      result.pixels[offset + 3] = 255

# Packet building
proc addU8*(packet: var seq[uint8], value: uint8) =
  packet.add(value)

proc addU16*(packet: var seq[uint8], value: int) =
  let v = uint16(value)
  packet.add(uint8(v and 0xff))
  packet.add(uint8(v shr 8))

proc addU32*(packet: var seq[uint8], value: int) =
  let v = uint32(value)
  for shift in countup(0, 24, 8):
    packet.add(uint8((v shr shift) and 0xff))

proc addI16*(packet: var seq[uint8], value: int) =
  let v = cast[uint16](int16(value))
  packet.add(uint8(v and 0xff))
  packet.add(uint8(v shr 8))

proc addViewport*(packet: var seq[uint8], layer, width, height: int) =
  packet.addU8(0x05)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addLayer*(packet: var seq[uint8], layer, layerType, flags: int) =
  packet.addU8(0x06)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(layerType))
  packet.addU8(uint8(flags))

proc addSprite*(
  packet: var seq[uint8],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label = ""
) =
  packet.addU8(0x01)
  packet.addU16(spriteId)
  packet.addU16(width)
  packet.addU16(height)
  var raw = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    raw[i] = pixels[i]
  let compressed = supersnappy.compress(raw)
  packet.addU32(compressed.len)
  for b in compressed:
    packet.addU8(b)
  packet.addU16(label.len)
  for ch in label:
    packet.addU8(uint8(ord(ch)))

proc addSpriteCached*(
  packet: var seq[uint8],
  cache: var seq[SpriteCacheEntry],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label = ""
) =
  for item in cache.mitems:
    if item.spriteId != spriteId:
      continue
    if item.width == width and item.height == height and
        item.pixels.len == pixels.len:
      var unchanged = true
      for i in 0 ..< pixels.len:
        if item.pixels[i] != pixels[i]:
          unchanged = false
          break
      if unchanged:
        return
    packet.addSprite(spriteId, width, height, pixels, label)
    item.width = width
    item.height = height
    item.pixels.setLen(pixels.len)
    for i in 0 ..< pixels.len:
      item.pixels[i] = pixels[i]
    return
  packet.addSprite(spriteId, width, height, pixels, label)
  var entry = SpriteCacheEntry(spriteId: spriteId, width: width, height: height)
  entry.pixels = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    entry.pixels[i] = pixels[i]
  cache.add(entry)

proc addObject*(
  packet: var seq[uint8],
  objectId, x, y, z, layer, spriteId: int
) =
  packet.addU8(0x02)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc addDeleteObject*(packet: var seq[uint8], objectId: int) =
  packet.addU8(0x03)
  packet.addU16(objectId)

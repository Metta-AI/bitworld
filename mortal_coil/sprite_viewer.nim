import supersnappy
import protocol, pixelfonts, render_utils

const
  SpritePlayerWebSocketPath* = "/sprite_player"
  MapLayerId* = 0
  MapLayerType = 0
  ZoomableLayerFlag = 1
  SpritePlayerInputMsg* = 0x84'u8

type
  SpriteViewerState* = object
    initialized*: bool
    prevLabel*: string

  TextSprite* = object
    id*: int
    x*, y*: int
    text*: string
    label*: string
    color*: uint8

proc addU8(packet: var seq[uint8], value: uint8) =
  packet.add(value)

proc addU16(packet: var seq[uint8], value: int) =
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addU32(packet: var seq[uint8], value: int) =
  let v = uint32(value)
  for shift in countup(0, 24, 8):
    packet.add(uint8((v shr shift) and 0xff'u32))

proc addI16(packet: var seq[uint8], value: int) =
  let v = cast[uint16](int16(value))
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addLayer*(packet: var seq[uint8], layer, layerType, flags: int) =
  packet.addU8(0x06)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(layerType))
  packet.addU8(uint8(flags))

proc addViewport*(packet: var seq[uint8], layer, width, height: int) =
  packet.addU8(0x05)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addClearObjects*(packet: var seq[uint8]) =
  packet.addU8(0x04)

proc addSprite*(packet: var seq[uint8], spriteId, width, height: int,
    pixels: openArray[uint8], label: string) =
  packet.addU8(0x01)
  packet.addU16(spriteId)
  packet.addU16(width)
  packet.addU16(height)
  var raw = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    raw[i] = pixels[i]
  let compressed = compress(raw)
  packet.addU32(compressed.len)
  for b in compressed:
    packet.addU8(uint8(b))
  packet.addU16(label.len)
  for ch in label:
    packet.addU8(uint8(ord(ch)))

proc addObject*(packet: var seq[uint8], objectId, x, y, z, layer, spriteId: int) =
  packet.addU8(0x02)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc wrapText(text: string, maxWidth: int): seq[string] =
  ## Word-wrap text to fit within maxWidth pixels.
  if maxWidth <= 0 or text.len == 0:
    return @[text]
  var pos = 0
  while pos < text.len:
    if result.len > 0:
      while pos < text.len and text[pos] == ' ':
        inc pos
      if pos >= text.len:
        break
    var lineWidth = 0
    var lineEnd = pos
    while lineEnd < text.len:
      var wordEnd = lineEnd
      while wordEnd < text.len and text[wordEnd] == ' ':
        inc wordEnd
      while wordEnd < text.len and text[wordEnd] != ' ':
        inc wordEnd
      var wordWidth = 0
      for i in lineEnd ..< wordEnd:
        wordWidth += font.glyphAdvance(text[i])
      if lineWidth == 0:
        lineEnd = wordEnd
        lineWidth = wordWidth
      elif lineWidth + wordWidth > maxWidth:
        break
      else:
        lineEnd = wordEnd
        lineWidth += wordWidth
    result.add(text[pos ..< lineEnd])
    pos = lineEnd
  if result.len == 0:
    result.add("")

proc textHeight*(text: string, maxWidth: int): int =
  ## Returns the pixel height of wrapped text.
  let lineHeight = font.height + 1
  let lines = wrapText(text, maxWidth)
  max(1, lines.len * lineHeight - 1)

proc renderTextPixels*(text: string, color: uint8, maxWidth: int): tuple[w, h: int, pixels: seq[uint8]] =
  let lineHeight = font.height + 1
  let lines = wrapText(text, maxWidth)
  var w = 1
  for line in lines:
    w = max(w, font.textWidth(line))
  w = max(1, min(w, maxWidth))
  let h = max(1, lines.len * lineHeight - 1)
  var pixels = newSeq[uint8](w * h * 4)
  let swatch = Palette[color.int]
  for lineIdx, line in lines:
    var penX = 0
    let baseY = lineIdx * lineHeight
    for ch in line:
      let glyph = font.glyphAt(ch)
      for gy in 0 ..< glyph.height:
        for gx in 0 ..< glyph.width:
          if glyph.glyphPixel(gx, gy):
            let px = penX + gx
            let py = baseY + gy
            if px < w and py < h:
              let idx = (py * w + px) * 4
              pixels[idx + 0] = swatch.r
              pixels[idx + 1] = swatch.g
              pixels[idx + 2] = swatch.b
              pixels[idx + 3] = 255
      penX += font.glyphAdvance(ch)
  (w, h, pixels)

proc buildSpritePacket*(sprites: openArray[TextSprite],
    state: var SpriteViewerState): seq[uint8] =
  var label = ""
  for s in sprites:
    if label.len > 0: label.add("\n")
    label.add(s.label)
  if label == state.prevLabel:
    return @[]
  state.prevLabel = label

  if not state.initialized:
    state.initialized = true
    result.addClearObjects()
    result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
    result.addViewport(MapLayerId, ScreenWidth, ScreenHeight)
  else:
    result.addClearObjects()

  for s in sprites:
    let maxW = max(1, ScreenWidth - s.x)
    if s.text.len == 0:
      let pixels = @[0'u8, 0, 0, 0]
      result.addSprite(s.id, 1, 1, pixels, s.label)
      result.addObject(s.id, s.x, s.y, s.id, MapLayerId, s.id)
    else:
      let (w, h, pixels) = renderTextPixels(s.text, s.color, maxW)
      result.addSprite(s.id, w, h, pixels, s.label)
      result.addObject(s.id, s.x, s.y, s.id, MapLayerId, s.id)

proc isSpritePlayerInput*(data: string): bool =
  data.len == 2 and data[0].uint8 == SpritePlayerInputMsg

proc spritePlayerInputMask*(data: string): uint8 =
  if data.len >= 2:
    data[1].uint8
  else:
    0

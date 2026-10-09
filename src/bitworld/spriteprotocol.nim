import
  std/tables,
  pixie,
  supersnappy,
  zippy,
  flatty/binny

const
  ScreenWidth* = 128
  ScreenHeight* = 128
  TileSize* = 6
  ProtocolBytes* = (ScreenWidth * ScreenHeight) div 2
  PacketInput* = 0'u8
  PacketChat* = 1'u8
  InputPacketBytes* = 2
  DefaultHost* = "localhost"
  DefaultPort* = 8080
  DefaultBaseAddress* = "ws://localhost:8080"
  DefaultPlayerAddress* = DefaultBaseAddress & "/player"
  DefaultGlobalAddress* = DefaultBaseAddress & "/global"
  DefaultRewardAddress* = DefaultBaseAddress & "/reward"
  ButtonUp* = 1'u8 shl 0
  ButtonDown* = 1'u8 shl 1
  ButtonLeft* = 1'u8 shl 2
  ButtonRight* = 1'u8 shl 3
  ButtonSelect* = 1'u8 shl 4
  ButtonA* = 1'u8 shl 5
  ButtonB* = 1'u8 shl 6
  SpriteMessageSprite* = 0x01'u8
  SpriteMessageObject* = 0x02'u8
  SpriteMessageDeleteObject* = 0x03'u8
  SpriteMessageClearObjects* = 0x04'u8
  SpriteMessageViewport* = 0x05'u8
  SpriteMessageLayer* = 0x06'u8
  SpriteMessageEncodedSprite* = 0x08'u8
    ## Define Encoded Sprite: like Define Sprite, plus one encoding byte
    ## that says how the pixel payload is packed. 0x07 is skipped
    ## because the stag_hunt game already uses it for identity packets.
  SpriteEncodingRgbaSnappy* = 0x00'u8
    ## Snappy stream of raw RGBA. The legacy Define Sprite payload.
  SpriteEncodingRgbaDeflate* = 0x01'u8
    ## Zlib stream of raw RGBA.
  SpriteEncodingIndexed* = 0x02'u8
    ## u8 palette count minus one, RGBA palette entries, then a zlib
    ## stream of one palette index byte per pixel.
  SpriteEncodingPaletteSwap* = 0x03'u8
    ## u16 source sprite id, u8 palette count minus one, RGBA palette
    ## entries. Reuses the index plane of an indexed sprite the client
    ## already holds; only the palette is new.
  SpriteEncodingAuto* = 0xff'u8
    ## Encoder-only: indexed when the sprite has at most 256 colors,
    ## otherwise RGBA deflate. Never written to the wire.
  SpriteMaxPaletteColors* = 256
  SpriteClientChat* = 0x81'u8
  SpriteClientMouseMove* = 0x82'u8
  SpriteClientMouseButton* = 0x83'u8
  SpriteClientInput* = 0x84'u8
  SpriteClientReady* = 0x85'u8
  SpriteClientDebugSprite* = 0x86'u8
  SpriteClientSpritesOff* = 0x87'u8
  SpriteLayerMap* = 0x00
  SpriteLayerTopLeft* = 0x01
  SpriteLayerTopRight* = 0x02
  SpriteLayerBottomRight* = 0x03
  SpriteLayerBottomLeft* = 0x04
  SpriteLayerCenterTop* = 0x05
  SpriteLayerCenterRight* = 0x06
  SpriteLayerCenterLeft* = 0x07
  SpriteLayerCenterBottom* = 0x08
  SpriteLayerFullScreen* = 0x09
  SpriteLayerZoomableFlag* = 0x01
  SpriteLayerUiFlag* = 0x02
  EmbeddedPalettePng = staticRead("../../client/data/pallete.png")

type
  SpriteProtocolError* = object of ValueError
    ## Raised when a sprite protocol packet cannot be decoded.

  InputState* = object
    up*, down*, left*, right*, select*, attack*, b*: bool

  SpritePacketKind* = enum
    spkSprite
    spkObject
    spkDeleteObject
    spkClearObjects
    spkViewport
    spkLayer

  SpritePacketSpriteDef* = object
    id*, width*, height*: int
    encoding*: uint8
      ## One of the SpriteEncoding values. A legacy Define Sprite
      ## message parses as SpriteEncodingRgbaSnappy.
    compressedPixels*: seq[uint8]
      ## The encoded pixel payload as it appeared on the wire. Empty for
      ## a pixel-free definition.
    label*: string

  DecodedSprite* = object
    ## One sprite definition decoded to straight RGBA. Indexed and
    ## palette-swap sprites also keep their index plane and palette so
    ## a later palette swap can reuse them.
    width*, height*: int
    pixels*: seq[uint8]
    indices*: seq[uint8]
    palette*: seq[uint8]

  SpritePacketObject* = object
    id*, x*, y*, z*, layer*, spriteId*: int

  SpritePacketViewport* = object
    layer*, width*, height*: int

  SpritePacketLayer* = object
    layer*, kind*, flags*: int

  SpritePacketMessage* = object
    kind*: SpritePacketKind
    sprite*: SpritePacketSpriteDef
    objectDef*: SpritePacketObject
    objectId*: int
    viewport*: SpritePacketViewport
    layer*: SpritePacketLayer

  SpriteClientKind* = enum
    SpriteClientChatMessage
    SpriteClientMouseMoveMessage
    SpriteClientMouseButtonMessage
    SpriteClientInputMessage
    SpriteClientReadyMessage
    SpriteClientDebugSpriteMessage
    SpriteClientSpritesOffMessage

  SpriteClientMessage* = object
    kind*: SpriteClientKind
    text*: string
    debugSprites*: seq[uint8]
    x*, y*, layer*: int
    hasLayer*: bool
    button*: uint8
    down*: bool
    mask*: uint8

var Palette*: array[16, ColorRGBA]

proc applyPalette(image: Image, source: string) =
  ## Copies the first 16 pixels from a palette image.
  if image.width < Palette.len or image.height < 1:
    raise newException(
      IOError,
      "Palette asset must be at least 16x1: " & source
    )

  for x in 0 ..< Palette.len:
    Palette[x] = image[x, 0]

proc loadPalette*(path = "") =
  ## Loads the embedded palette and ignores runtime palette paths.
  decodeImage(EmbeddedPalettePng).applyPalette("embedded " & path)

proc encodeInputMask*(input: InputState): uint8 =
  ## Encodes button state into the shared seven bit input mask.
  if input.up:
    result = result or ButtonUp
  if input.down:
    result = result or ButtonDown
  if input.left:
    result = result or ButtonLeft
  if input.right:
    result = result or ButtonRight
  if input.select:
    result = result or ButtonSelect
  if input.attack:
    result = result or ButtonA
  if input.b:
    result = result or ButtonB

proc decodeInputMask*(mask: uint8): InputState =
  ## Decodes the shared seven bit input mask into button state.
  result.up = (mask and ButtonUp) != 0
  result.down = (mask and ButtonDown) != 0
  result.left = (mask and ButtonLeft) != 0
  result.right = (mask and ButtonRight) != 0
  result.select = (mask and ButtonSelect) != 0
  result.attack = (mask and ButtonA) != 0
  result.b = (mask and ButtonB) != 0

proc blobFromBytes*(bytes: openArray[uint8]): string =
  ## Converts packet bytes to a websocket binary string.
  result = newString(bytes.len)
  for i, value in bytes:
    result[i] = char(value)

proc blobToBytes*(blob: string, bytes: var seq[uint8]) =
  ## Copies one websocket binary string into packet bytes.
  if bytes.len != blob.len:
    bytes.setLen(blob.len)
  for i in 0 ..< blob.len:
    bytes[i] = blob[i].uint8

proc blobFromMask*(mask: uint8): string =
  ## Builds a legacy button packet from an input mask.
  result = newString(InputPacketBytes)
  result[0] = char(PacketInput)
  result[1] = char(mask)

proc isInputPacket*(blob: string): bool =
  ## Returns true when a blob is a legacy button packet.
  blob.len == InputPacketBytes and blob[0].uint8 == PacketInput

proc isChatPacket*(blob: string): bool =
  ## Returns true when a blob is a legacy chat packet.
  blob.len >= 1 and blob[0].uint8 == PacketChat

proc blobToMask*(blob: string): uint8 =
  ## Reads the input mask from a legacy button packet.
  if not blob.isInputPacket():
    return 0
  blob[1].uint8

proc blobFromChat*(text: string): string =
  ## Builds a legacy chat packet from ASCII text.
  result = newString(text.len + 1)
  result[0] = char(PacketChat)
  for i, ch in text:
    result[i + 1] = ch

proc blobToChat*(blob: string): string =
  ## Reads printable ASCII text from a legacy chat packet.
  if not blob.isChatPacket():
    return ""
  for i in 1 ..< blob.len:
    let value = blob[i].uint8
    if value >= 32'u8 and value < 127'u8:
      result.add(blob[i])

proc addU8*(packet: var seq[uint8], value: uint8) =
  ## Appends one flatty encoded unsigned byte.
  packet.add(value)

proc addU16*(packet: var seq[uint8], value: int) =
  ## Appends one flatty encoded unsigned 16 bit value.
  let start = packet.len
  var encoded = uint16(value)
  packet.setLen(start + 2)
  copyMem(packet[start].addr, encoded.addr, 2)

proc addU32*(packet: var seq[uint8], value: int) =
  ## Appends one flatty encoded unsigned 32 bit value.
  let start = packet.len
  var encoded = uint32(value)
  packet.setLen(start + 4)
  copyMem(packet[start].addr, encoded.addr, 4)

proc addI16*(packet: var seq[uint8], value: int) =
  ## Appends one flatty encoded signed 16 bit value.
  let start = packet.len
  var encoded = int16(value)
  packet.setLen(start + 2)
  copyMem(packet[start].addr, encoded.addr, 2)

proc toPacketString(packet: openArray[uint8]): string =
  ## Copies packet bytes into a flatty-readable string.
  result = newString(packet.len)
  for i, value in packet:
    result[i] = char(value)

proc checkRead(packet: string, offset, count: int) =
  ## Raises when a flatty read would move beyond the packet.
  if offset < 0 or count < 0 or offset + count > packet.len:
    raise newException(SpriteProtocolError, "truncated sprite protocol packet")

proc readU8*(packet: string, offset: int): uint8 =
  ## Reads one flatty encoded unsigned byte.
  packet.checkRead(offset, 1)
  packet.readUint8(offset)

proc readU16*(packet: string, offset: int): int =
  ## Reads one flatty encoded unsigned 16 bit value.
  packet.checkRead(offset, 2)
  int(packet.readUint16(offset))

proc readU32*(packet: string, offset: int): int =
  ## Reads one flatty encoded unsigned 32 bit value.
  packet.checkRead(offset, 4)
  int(packet.readUint32(offset))

proc readI16*(packet: string, offset: int): int =
  ## Reads one flatty encoded signed 16 bit value.
  packet.checkRead(offset, 2)
  int(packet.readInt16(offset))

proc readU8*(packet: openArray[uint8], offset: int): uint8 =
  ## Reads one flatty encoded unsigned byte from packet bytes.
  toPacketString(packet).readU8(offset)

proc readU16*(packet: openArray[uint8], offset: int): int =
  ## Reads one flatty encoded unsigned 16 bit value from packet bytes.
  toPacketString(packet).readU16(offset)

proc readU32*(packet: openArray[uint8], offset: int): int =
  ## Reads one flatty encoded unsigned 32 bit value from packet bytes.
  toPacketString(packet).readU32(offset)

proc readI16*(packet: openArray[uint8], offset: int): int =
  ## Reads one flatty encoded signed 16 bit value from packet bytes.
  toPacketString(packet).readI16(offset)

proc addViewport*(packet: var seq[uint8], layer, width, height: int) =
  ## Appends one sprite protocol viewport message.
  packet.addU8(SpriteMessageViewport)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addLayer*(packet: var seq[uint8], layer, layerKind, flags: int) =
  ## Appends one sprite protocol layer definition message.
  packet.addU8(SpriteMessageLayer)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(layerKind))
  packet.addU8(uint8(flags))

proc addPixelFreeSprite*(
  packet: var seq[uint8],
  spriteId, width, height: int,
  label = ""
) =
  ## Appends one pixel-free sprite definition message: full dimensions and
  ## label with a zero-length pixel payload, for clients that sent
  ## Sprites Off.
  packet.addU8(SpriteMessageSprite)
  packet.addU16(spriteId)
  packet.addU16(width)
  packet.addU16(height)
  packet.addU32(0)
  packet.addU16(label.len)
  for ch in label:
    packet.addU8(uint8(ord(ch)))

proc addSprite*(
  packet: var seq[uint8],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label = ""
) =
  ## Appends one sprite protocol sprite definition message.
  packet.addU8(SpriteMessageSprite)
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

proc packedColor(pixels: openArray[uint8], offset: int): uint32 =
  ## Packs one RGBA pixel into a table key.
  uint32(pixels[offset]) or
    (uint32(pixels[offset + 1]) shl 8) or
    (uint32(pixels[offset + 2]) shl 16) or
    (uint32(pixels[offset + 3]) shl 24)

proc indexPixels*(
  pixels: openArray[uint8],
  palette: var seq[uint8],
  indices: var seq[uint8]
): bool =
  ## Splits straight RGBA pixels into a palette and an index plane. The
  ## palette lists colors in first-seen scanline order, so two sprites
  ## with the same layout share the same index plane. Returns false
  ## when the sprite has more than 256 colors.
  palette.setLen(0)
  indices.setLen(pixels.len div 4)
  var lookup = initTable[uint32, uint8]()
  var offset = 0
  for i in 0 ..< indices.len:
    let key = pixels.packedColor(offset)
    var index: uint8
    if lookup.hasKey(key):
      index = lookup[key]
    else:
      if lookup.len >= SpriteMaxPaletteColors:
        return false
      index = uint8(lookup.len)
      lookup[key] = index
      for channel in 0 .. 3:
        palette.add(pixels[offset + channel])
    indices[i] = index
    offset += 4
  true

proc encodeIndexedPayload*(pixels: openArray[uint8]): seq[uint8] =
  ## Builds an indexed sprite payload, or an empty seq when the sprite
  ## has more than 256 colors.
  var palette, indices: seq[uint8]
  if pixels.len == 0 or not pixels.indexPixels(palette, indices):
    return
  result.add(uint8(palette.len div 4 - 1))
  result.add(palette)
  result.add(zippy.compress(indices, dataFormat = dfZlib))

proc encodeRgbaDeflatePayload*(pixels: openArray[uint8]): seq[uint8] =
  ## Builds a zlib stream of raw RGBA pixels.
  var raw = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    raw[i] = pixels[i]
  zippy.compress(raw, dataFormat = dfZlib)

proc encodeRgbaSnappyPayload*(pixels: openArray[uint8]): seq[uint8] =
  ## Builds a Snappy stream of raw RGBA pixels, the legacy payload.
  var raw = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    raw[i] = pixels[i]
  supersnappy.compress(raw)

proc encodePaletteSwapPayload*(
  sourceSpriteId: int,
  sourcePixels, pixels: openArray[uint8]
): seq[uint8] =
  ## Builds a palette-swap payload when `pixels` recolors `sourcePixels`
  ## one color at a time: every pixel that has color A in the source has
  ## the same color B here. Returns an empty seq when the sizes differ,
  ## the source has more than 256 colors, or the recoloring is not
  ## consistent. The source must have been sent as an indexed sprite.
  if sourcePixels.len == 0 or sourcePixels.len != pixels.len:
    return
  var sourcePalette, sourceIndices: seq[uint8]
  if not sourcePixels.indexPixels(sourcePalette, sourceIndices):
    return
  let count = sourcePalette.len div 4
  var
    palette = newSeq[uint8](count * 4)
    seen = newSeq[bool](count)
  for i, index in sourceIndices:
    let
      slot = int(index) * 4
      offset = i * 4
    if seen[index]:
      for channel in 0 .. 3:
        if palette[slot + channel] != pixels[offset + channel]:
          return @[]
    else:
      seen[index] = true
      for channel in 0 .. 3:
        palette[slot + channel] = pixels[offset + channel]
  result.addU16(sourceSpriteId)
  result.add(uint8(count - 1))
  result.add(palette)

proc addEncodedSpritePayload*(
  packet: var seq[uint8],
  spriteId, width, height: int,
  encoding: uint8,
  payload: openArray[uint8],
  label = ""
) =
  ## Appends one Define Encoded Sprite message with a prebuilt payload.
  ## An empty payload is a pixel-free definition.
  packet.addU8(SpriteMessageEncodedSprite)
  packet.addU16(spriteId)
  packet.addU16(width)
  packet.addU16(height)
  packet.addU8(encoding)
  packet.addU32(payload.len)
  for byte in payload:
    packet.addU8(byte)
  packet.addU16(label.len)
  for ch in label:
    packet.addU8(uint8(ord(ch)))

proc addEncodedSprite*(
  packet: var seq[uint8],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label = "",
  encoding = SpriteEncodingAuto
): uint8 {.discardable.} =
  ## Appends one Define Encoded Sprite message for straight RGBA pixels
  ## and returns the encoding used. Auto picks indexed for sprites with
  ## at most 256 colors and RGBA deflate for everything else.
  var payload: seq[uint8]
  result = encoding
  case encoding
  of SpriteEncodingAuto:
    payload = pixels.encodeIndexedPayload()
    result = SpriteEncodingIndexed
    if payload.len == 0:
      payload = pixels.encodeRgbaDeflatePayload()
      result = SpriteEncodingRgbaDeflate
  of SpriteEncodingIndexed:
    payload = pixels.encodeIndexedPayload()
    if payload.len == 0:
      raise newException(
        SpriteProtocolError,
        "indexed sprite needs 1 .. 256 colors"
      )
  of SpriteEncodingRgbaDeflate:
    payload = pixels.encodeRgbaDeflatePayload()
  of SpriteEncodingRgbaSnappy:
    payload = pixels.encodeRgbaSnappyPayload()
  else:
    raise newException(
      SpriteProtocolError,
      "unknown sprite encoding " & $encoding
    )
  packet.addEncodedSpritePayload(spriteId, width, height, result, payload, label)

proc addPaletteSwapSprite*(
  packet: var seq[uint8],
  spriteId, sourceSpriteId, width, height: int,
  sourcePixels, pixels: openArray[uint8],
  label = ""
): bool {.discardable.} =
  ## Appends sprite `spriteId` as a palette swap of the indexed sprite
  ## `sourceSpriteId` when `pixels` is a per-color recoloring of
  ## `sourcePixels`, and as an ordinary auto-encoded sprite otherwise.
  ## Returns true when the swap was used. The source sprite must already
  ## have been defined with the indexed encoding in the same packet
  ## stream, or the client has no index plane to reuse.
  let payload = encodePaletteSwapPayload(sourceSpriteId, sourcePixels, pixels)
  if payload.len == 0:
    packet.addEncodedSprite(spriteId, width, height, pixels, label)
    return false
  packet.addEncodedSpritePayload(
    spriteId, width, height, SpriteEncodingPaletteSwap, payload, label
  )
  true

proc paletteSwapSourceId*(def: SpritePacketSpriteDef): int =
  ## Returns the source sprite id a palette-swap definition reuses, or
  ## -1 for every other definition.
  if def.encoding != SpriteEncodingPaletteSwap or
      def.compressedPixels.len < 3:
    return -1
  def.compressedPixels.readU16(0)

proc expandIndices(
  indices, palette: openArray[uint8],
  width, height: int
): seq[uint8] =
  ## Expands one index plane through a palette into straight RGBA.
  if indices.len != width * height:
    raise newException(
      SpriteProtocolError,
      "sprite index plane does not match width * height"
    )
  let count = palette.len div 4
  result = newSeq[uint8](indices.len * 4)
  for i, index in indices:
    if int(index) >= count:
      raise newException(SpriteProtocolError, "sprite palette index out of range")
    let
      slot = int(index) * 4
      offset = i * 4
    result[offset] = palette[slot]
    result[offset + 1] = palette[slot + 1]
    result[offset + 2] = palette[slot + 2]
    result[offset + 3] = palette[slot + 3]

proc decodeSprite*(
  def: SpritePacketSpriteDef,
  source = DecodedSprite()
): DecodedSprite =
  ## Decodes one sprite definition to straight RGBA. `source` is the
  ## already decoded sprite named by paletteSwapSourceId for a
  ## palette-swap definition and is ignored by the other encodings. A
  ## pixel-free definition decodes with empty pixels. Raises
  ## SpriteProtocolError for payloads that do not decode to exactly
  ## width * height * 4 bytes.
  result.width = def.width
  result.height = def.height
  let payload = def.compressedPixels
  if payload.len == 0:
    return
  case def.encoding
  of SpriteEncodingRgbaSnappy:
    try:
      result.pixels = supersnappy.uncompress(payload)
    except SnappyError as e:
      raise newException(SpriteProtocolError, "bad snappy sprite: " & e.msg)
  of SpriteEncodingRgbaDeflate:
    try:
      result.pixels = zippy.uncompress(payload, dfZlib)
    except ZippyError as e:
      raise newException(SpriteProtocolError, "bad deflate sprite: " & e.msg)
  of SpriteEncodingIndexed:
    let count = int(payload[0]) + 1
    if payload.len < 1 + count * 4:
      raise newException(SpriteProtocolError, "truncated sprite palette")
    result.palette = payload[1 ..< 1 + count * 4]
    try:
      result.indices = zippy.uncompress(payload[1 + count * 4 .. ^1], dfZlib)
    except ZippyError as e:
      raise newException(SpriteProtocolError, "bad indexed sprite: " & e.msg)
    result.pixels = expandIndices(
      result.indices, result.palette, def.width, def.height
    )
  of SpriteEncodingPaletteSwap:
    if payload.len < 3:
      raise newException(SpriteProtocolError, "truncated palette swap")
    let count = int(payload[2]) + 1
    if payload.len < 3 + count * 4:
      raise newException(SpriteProtocolError, "truncated sprite palette")
    if source.indices.len != def.width * def.height:
      raise newException(
        SpriteProtocolError,
        "palette swap source " & $def.paletteSwapSourceId() &
          " is not an indexed sprite of the same size"
      )
    result.palette = payload[3 ..< 3 + count * 4]
    result.indices = source.indices
    result.pixels = expandIndices(
      result.indices, result.palette, def.width, def.height
    )
  else:
    raise newException(
      SpriteProtocolError,
      "unknown sprite encoding " & $def.encoding
    )
  if result.pixels.len != def.width * def.height * 4:
    raise newException(
      SpriteProtocolError,
      "sprite pixels do not match width * height * 4"
    )

proc addObject*(
  packet: var seq[uint8],
  objectId, x, y, z, layer, spriteId: int
) =
  ## Appends one sprite protocol object definition message.
  packet.addU8(SpriteMessageObject)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc addDeleteObject*(packet: var seq[uint8], objectId: int) =
  ## Appends one sprite protocol object delete message.
  packet.addU8(SpriteMessageDeleteObject)
  packet.addU16(objectId)

proc addClearObjects*(packet: var seq[uint8]) =
  ## Appends one sprite protocol clear-objects message.
  packet.addU8(SpriteMessageClearObjects)

proc parseSpritePacket*(packet: openArray[uint8]): seq[SpritePacketMessage] =
  ## Decodes all server-to-client sprite protocol messages.
  let bytes = packet.toPacketString()
  var offset = 0
  while offset < bytes.len:
    let messageType = bytes.readU8(offset)
    inc offset
    case messageType
    of SpriteMessageSprite:
      bytes.checkRead(offset, 10)
      var message = SpritePacketMessage(kind: spkSprite)
      message.sprite.id = bytes.readU16(offset)
      message.sprite.width = bytes.readU16(offset + 2)
      message.sprite.height = bytes.readU16(offset + 4)
      let compressedLen = bytes.readU32(offset + 6)
      offset += 10
      bytes.checkRead(offset, compressedLen)
      message.sprite.compressedPixels =
        newSeq[uint8](compressedLen)
      for i in 0 ..< compressedLen:
        message.sprite.compressedPixels[i] = bytes[offset + i].uint8
      offset += compressedLen
      let labelLen = bytes.readU16(offset)
      offset += 2
      bytes.checkRead(offset, labelLen)
      message.sprite.label = bytes.readStr(offset, labelLen)
      offset += labelLen
      result.add(message)
    of SpriteMessageEncodedSprite:
      bytes.checkRead(offset, 11)
      var message = SpritePacketMessage(kind: spkSprite)
      message.sprite.id = bytes.readU16(offset)
      message.sprite.width = bytes.readU16(offset + 2)
      message.sprite.height = bytes.readU16(offset + 4)
      message.sprite.encoding = bytes.readU8(offset + 6)
      let payloadLen = bytes.readU32(offset + 7)
      offset += 11
      if message.sprite.encoding > SpriteEncodingPaletteSwap:
        raise newException(
          SpriteProtocolError,
          "unknown sprite encoding " & $message.sprite.encoding
        )
      bytes.checkRead(offset, payloadLen)
      message.sprite.compressedPixels = newSeq[uint8](payloadLen)
      for i in 0 ..< payloadLen:
        message.sprite.compressedPixels[i] = bytes[offset + i].uint8
      offset += payloadLen
      let labelLen = bytes.readU16(offset)
      offset += 2
      bytes.checkRead(offset, labelLen)
      message.sprite.label = bytes.readStr(offset, labelLen)
      offset += labelLen
      result.add(message)
    of SpriteMessageObject:
      bytes.checkRead(offset, 11)
      var message = SpritePacketMessage(kind: spkObject)
      message.objectDef.id = bytes.readU16(offset)
      message.objectDef.x = bytes.readI16(offset + 2)
      message.objectDef.y = bytes.readI16(offset + 4)
      message.objectDef.z = bytes.readI16(offset + 6)
      message.objectDef.layer = int(bytes.readU8(offset + 8))
      message.objectDef.spriteId = bytes.readU16(offset + 9)
      offset += 11
      result.add(message)
    of SpriteMessageDeleteObject:
      bytes.checkRead(offset, 2)
      result.add(SpritePacketMessage(
        kind: spkDeleteObject,
        objectId: bytes.readU16(offset)
      ))
      offset += 2
    of SpriteMessageClearObjects:
      result.add(SpritePacketMessage(kind: spkClearObjects))
    of SpriteMessageViewport:
      bytes.checkRead(offset, 5)
      var message = SpritePacketMessage(kind: spkViewport)
      message.viewport.layer = int(bytes.readU8(offset))
      message.viewport.width = bytes.readU16(offset + 1)
      message.viewport.height = bytes.readU16(offset + 3)
      offset += 5
      result.add(message)
    of SpriteMessageLayer:
      bytes.checkRead(offset, 3)
      var message = SpritePacketMessage(kind: spkLayer)
      message.layer.layer = int(bytes.readU8(offset))
      message.layer.kind = int(bytes.readU8(offset + 1))
      message.layer.flags = int(bytes.readU8(offset + 2))
      offset += 3
      result.add(message)
    else:
      raise newException(
        SpriteProtocolError,
        "unknown sprite protocol message " & $messageType
      )

proc spritePacketSpriteIds*(packet: openArray[uint8]): seq[int] =
  ## Returns all sprite ids defined in one sprite protocol packet.
  for message in packet.parseSpritePacket():
    if message.kind == spkSprite:
      result.add(message.sprite.id)

proc spritePacketObjects*(packet: openArray[uint8]): seq[SpritePacketObject] =
  ## Returns all objects defined in one sprite protocol packet.
  for message in packet.parseSpritePacket():
    if message.kind == spkObject:
      result.add(message.objectDef)

proc spritePacketObjectIds*(packet: openArray[uint8]): seq[int] =
  ## Returns all object ids defined in one sprite protocol packet.
  for item in packet.spritePacketObjects():
    result.add(item.id)

proc spritePacketViewports*(
  packet: openArray[uint8]
): seq[SpritePacketViewport] =
  ## Returns all viewports defined in one sprite protocol packet.
  for message in packet.parseSpritePacket():
    if message.kind == spkViewport:
      result.add(message.viewport)

proc spriteMessageBytes*(packet: openArray[uint8], offset: int): int =
  ## Returns the byte size of one sprite protocol message.
  if offset >= packet.len:
    return 0
  case packet[offset]
  of SpriteMessageSprite:
    if offset + 11 > packet.len:
      return packet.len - offset
    let
      compressedLen = packet.readU32(offset + 7)
      labelOffset = offset + 11 + compressedLen
    if labelOffset + 2 > packet.len:
      return packet.len - offset
    let labelLen = packet.readU16(labelOffset)
    min(packet.len - offset, 13 + compressedLen + labelLen)
  of SpriteMessageEncodedSprite:
    if offset + 12 > packet.len:
      return packet.len - offset
    let
      payloadLen = packet.readU32(offset + 8)
      labelOffset = offset + 12 + payloadLen
    if labelOffset + 2 > packet.len:
      return packet.len - offset
    let labelLen = packet.readU16(labelOffset)
    min(packet.len - offset, 14 + payloadLen + labelLen)
  of SpriteMessageObject:
    min(packet.len - offset, 12)
  of SpriteMessageDeleteObject:
    min(packet.len - offset, 3)
  of SpriteMessageClearObjects:
    1
  of SpriteMessageViewport:
    min(packet.len - offset, 6)
  of SpriteMessageLayer:
    min(packet.len - offset, 4)
  else:
    packet.len - offset

proc isSpriteInputPacket*(blob: string): bool =
  ## Returns true when a blob is a sprite button packet.
  blob.len == InputPacketBytes and blob[0].uint8 == SpriteClientInput

proc isSpritePlayerInputPacket*(blob: string): bool =
  ## Returns true when a blob is a sprite player button packet.
  blob.isSpriteInputPacket()

proc blobFromSpriteMask*(mask: uint8): string =
  ## Builds a sprite button packet from an input mask.
  result = newString(InputPacketBytes)
  result[0] = char(SpriteClientInput)
  result[1] = char(mask and 0x7f'u8)

proc blobFromSpriteReady*(): string =
  ## Builds a sprite client-ready packet.
  result = newString(1)
  result[0] = char(SpriteClientReady)

proc blobFromSpritesOff*(): string =
  ## Builds a sprite sprites-off capability packet: the client wants
  ## gameplay state without sprite pixel data.
  result = newString(1)
  result[0] = char(SpriteClientSpritesOff)

proc isSpritesOffPacket*(blob: string): bool =
  ## Returns true when a blob is a standalone sprites-off packet.
  blob.len == 1 and blob[0].uint8 == SpriteClientSpritesOff

proc blobFromSpriteChat*(text: string): string =
  ## Builds a sprite chat packet from ASCII text.
  var packet: seq[uint8]
  packet.addU8(SpriteClientChat)
  packet.addU16(text.len)
  for ch in text:
    packet.addU8(uint8(ord(ch)))
  blobFromBytes(packet)

proc blobFromSpriteDebugSprites*(debugSprites: openArray[uint8]): string =
  ## Builds a sprite debug packet from server-style sprite messages.
  var packet: seq[uint8]
  packet.addU8(SpriteClientDebugSprite)
  packet.addU32(debugSprites.len)
  for byte in debugSprites:
    packet.addU8(byte)
  blobFromBytes(packet)

proc isSpriteClientType(value: uint8): bool =
  ## Returns true when one byte starts a sprite client message.
  value == SpriteClientChat or
    value == SpriteClientMouseMove or
    value == SpriteClientMouseButton or
    value == SpriteClientInput or
    value == SpriteClientReady or
    value == SpriteClientDebugSprite or
    value == SpriteClientSpritesOff

proc parseSpriteClientMessages*(
  message: string
): seq[SpriteClientMessage] =
  ## Decodes all client-to-server sprite protocol messages.
  var offset = 0
  while offset < message.len:
    let messageType = message.readU8(offset)
    inc offset
    case messageType
    of SpriteClientChat:
      if offset + 2 > message.len:
        return
      let length = message.readU16(offset)
      offset += 2
      if offset + length > message.len:
        return
      var item = SpriteClientMessage(kind: SpriteClientChatMessage)
      for i in 0 ..< length:
        let value = message[offset + i].uint8
        if value >= 32'u8 and value < 127'u8:
          item.text.add(message[offset + i])
      offset += length
      result.add(item)
    of SpriteClientMouseMove:
      if offset + 4 > message.len:
        return
      var item = SpriteClientMessage(kind: SpriteClientMouseMoveMessage)
      item.x = message.readI16(offset)
      item.y = message.readI16(offset + 2)
      offset += 4
      if offset < message.len and
          not isSpriteClientType(message[offset].uint8):
        item.hasLayer = true
        item.layer = int(message[offset].uint8)
        inc offset
      result.add(item)
    of SpriteClientMouseButton:
      if offset + 2 > message.len:
        return
      result.add(SpriteClientMessage(
        kind: SpriteClientMouseButtonMessage,
        button: message[offset].uint8,
        down: message[offset + 1].uint8 != 0
      ))
      offset += 2
    of SpriteClientInput:
      if offset + 1 > message.len:
        return
      result.add(SpriteClientMessage(
        kind: SpriteClientInputMessage,
        mask: message[offset].uint8 and 0x7f'u8
      ))
      inc offset
    of SpriteClientReady:
      result.add(SpriteClientMessage(kind: SpriteClientReadyMessage))
    of SpriteClientSpritesOff:
      result.add(SpriteClientMessage(kind: SpriteClientSpritesOffMessage))
    of SpriteClientDebugSprite:
      if offset + 4 > message.len:
        return
      let length = message.readU32(offset)
      offset += 4
      if offset + length > message.len:
        return
      var item = SpriteClientMessage(kind: SpriteClientDebugSpriteMessage)
      item.debugSprites = newSeq[uint8](length)
      for i in 0 ..< length:
        item.debugSprites[i] = message[offset + i].uint8
      offset += length
      result.add(item)
    else:
      return

proc readSpriteInputText*(message: string): string =
  ## Reads printable chat text from sprite client messages.
  for item in message.parseSpriteClientMessages():
    if item.kind == SpriteClientChatMessage:
      result.add(item.text)

proc spriteInputMask*(message: string): uint8 =
  ## Reads the last input mask from sprite client messages.
  for item in message.parseSpriteClientMessages():
    if item.kind == SpriteClientInputMessage:
      result = item.mask

import
  pixie,
  supersnappy,
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
  SpriteClientChat* = 0x81'u8
  SpriteClientMouseMove* = 0x82'u8
  SpriteClientMouseButton* = 0x83'u8
  SpriteClientInput* = 0x84'u8
  SpriteClientReady* = 0x85'u8
  SpriteClientDebugSprite* = 0x86'u8
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
    compressedPixels*: seq[uint8]
    label*: string

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
    value == SpriteClientDebugSprite

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
        # Printable ASCII plus the Enter and Escape control codes.
        if (value >= 32'u8 and value < 127'u8) or
            value == 0x0a'u8 or value == 0x1b'u8:
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

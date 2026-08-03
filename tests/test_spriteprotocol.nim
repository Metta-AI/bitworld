import
  supersnappy,
  bitworld/spriteprotocol

proc expectSpriteError(packet: openArray[uint8]) =
  ## Checks that malformed server packets raise protocol errors.
  var raised = false
  try:
    discard packet.parseSpritePacket()
  except SpriteProtocolError:
    raised = true
  doAssert raised

proc expectReadError(packet: openArray[uint8], offset: int) =
  ## Checks that out-of-range primitive reads raise protocol errors.
  var raised = false
  try:
    discard packet.readU16(offset)
  except SpriteProtocolError:
    raised = true
  doAssert raised

proc mouseMoveBlob(x, y: int, layer = -1): string =
  ## Builds one mouse move blob for client parser tests.
  var packet: seq[uint8]
  packet.addU8(SpriteClientMouseMove)
  packet.addI16(x)
  packet.addI16(y)
  if layer >= 0:
    packet.addU8(uint8(layer))
  blobFromBytes(packet)

proc mouseButtonBlob(button: uint8, down: bool): string =
  ## Builds one mouse button blob for client parser tests.
  var packet: seq[uint8]
  let downValue =
    if down:
      1'u8
    else:
      0'u8
  packet.addU8(SpriteClientMouseButton)
  packet.addU8(button)
  packet.addU8(downValue)
  blobFromBytes(packet)

proc testInputMasks() =
  ## Tests sprite protocol input mask encoding and decoding.
  echo "Testing sprite input masks"
  let input = InputState(
    up: true,
    down: true,
    left: true,
    right: true,
    select: true,
    attack: true,
    b: true
  )
  let
    mask = input.encodeInputMask()
    decoded = mask.decodeInputMask()
  doAssert mask == 0x7f'u8

  doAssert decoded.up
  doAssert decoded.down
  doAssert decoded.left
  doAssert decoded.right
  doAssert decoded.select
  doAssert decoded.attack
  doAssert decoded.b

  let none = decodeInputMask(0)
  doAssert not none.up
  doAssert not none.down
  doAssert not none.left
  doAssert not none.right
  doAssert not none.select
  doAssert not none.attack
  doAssert not none.b

proc testLayerConstants() =
  ## Tests sprite layer type constants used by clients and games.
  echo "Testing sprite layer constants"
  doAssert SpriteLayerMap == 0x00
  doAssert SpriteLayerCenterBottom == 0x08
  doAssert SpriteLayerFullScreen == 0x09
  doAssert SpriteLayerZoomableFlag == 0x01
  doAssert SpriteLayerUiFlag == 0x02

proc testByteHelpers() =
  ## Tests byte blobs and primitive little-endian readers.
  echo "Testing sprite byte helpers"
  let
    source = @[0'u8, 1, 2, 127, 128, 255]
    blob = blobFromBytes(source)
  var bytes: seq[uint8]
  blob.blobToBytes(bytes)
  doAssert bytes == source

  var packet: seq[uint8]
  packet.addU8(0xab'u8)
  packet.addU16(0x1234)
  packet.addI16(-321)
  packet.addU32(0x12345678)
  doAssert packet.readU8(0) == 0xab'u8
  doAssert packet.readU16(1) == 0x1234
  doAssert packet.readI16(3) == -321
  doAssert packet.readU32(5) == 0x12345678

  let packetBlob = blobFromBytes(packet)
  doAssert packetBlob.readU8(0) == 0xab'u8
  doAssert packetBlob.readU16(1) == 0x1234
  doAssert packetBlob.readI16(3) == -321
  doAssert packetBlob.readU32(5) == 0x12345678
  packet.expectReadError(8)
  packet.expectReadError(-1)

proc testServerPacketBuilders() =
  ## Tests server packet builders and full packet parsing.
  echo "Testing sprite packet builders"
  var packet: seq[uint8]
  let pixels = @[1'u8, 2, 3, 4, 5, 6]
  packet.addClearObjects()
  packet.addViewport(2, 320, 240)
  packet.addLayer(2, 1, 3)
  packet.addSprite(7, 3, 2, pixels, "ship")
  packet.addObject(9, -4, 12, -2, 2, 7)
  packet.addDeleteObject(4)

  let
    messages = packet.parseSpritePacket()
    sprites = packet.spritePacketSpriteIds()
    objects = packet.spritePacketObjects()
    objectIds = packet.spritePacketObjectIds()
    viewports = packet.spritePacketViewports()

  doAssert messages.len == 6
  doAssert messages[0].kind == spkClearObjects
  doAssert messages[1].kind == spkViewport
  doAssert messages[2].kind == spkLayer
  doAssert messages[3].kind == spkSprite
  doAssert messages[4].kind == spkObject
  doAssert messages[5].kind == spkDeleteObject

  doAssert messages[1].viewport.layer == 2
  doAssert messages[1].viewport.width == 320
  doAssert messages[1].viewport.height == 240
  doAssert messages[2].layer.layer == 2
  doAssert messages[2].layer.kind == 1
  doAssert messages[2].layer.flags == 3
  doAssert messages[3].sprite.id == 7
  doAssert messages[3].sprite.width == 3
  doAssert messages[3].sprite.height == 2
  doAssert messages[3].sprite.label == "ship"
  doAssert uncompress(messages[3].sprite.compressedPixels) == pixels
  doAssert messages[5].objectId == 4

  # A pixel-free definition keeps dimensions and label with no pixel bytes.
  var pixelFree: seq[uint8]
  pixelFree.addPixelFreeSprite(8, 3, 2, "ghost")
  let pixelFreeMessages = pixelFree.parseSpritePacket()
  doAssert pixelFreeMessages.len == 1
  doAssert pixelFreeMessages[0].kind == spkSprite
  doAssert pixelFreeMessages[0].sprite.id == 8
  doAssert pixelFreeMessages[0].sprite.width == 3
  doAssert pixelFreeMessages[0].sprite.height == 2
  doAssert pixelFreeMessages[0].sprite.label == "ghost"
  doAssert pixelFreeMessages[0].sprite.compressedPixels.len == 0
  doAssert spriteMessageBytes(pixelFree, 0) == pixelFree.len

  doAssert sprites == @[7]
  doAssert objects.len == 1
  doAssert objects[0].id == 9
  doAssert objects[0].x == -4
  doAssert objects[0].y == 12
  doAssert objects[0].z == -2
  doAssert objects[0].layer == 2
  doAssert objects[0].spriteId == 7
  doAssert objectIds == @[9]
  doAssert viewports.len == 1
  doAssert viewports[0].layer == 2
  doAssert viewports[0].width == 320
  doAssert viewports[0].height == 240

proc testMultipleServerDefinitions() =
  ## Tests helper extractors with repeated sprites, objects, and viewports.
  echo "Testing sprite packet helper extractors"
  var packet: seq[uint8]
  packet.addSprite(1, 1, 1, [9'u8], "a")
  packet.addSprite(2, 2, 1, [1'u8, 2], "")
  packet.addObject(10, 0, 0, 0, 0, 1)
  packet.addObject(11, 5, -6, 7, 3, 2)
  packet.addViewport(0, 128, 128)
  packet.addViewport(3, 640, 480)

  let
    messages = packet.parseSpritePacket()
    objects = packet.spritePacketObjects()
    viewports = packet.spritePacketViewports()

  doAssert messages.len == 6
  doAssert packet.spritePacketSpriteIds() == @[1, 2]
  doAssert packet.spritePacketObjectIds() == @[10, 11]
  doAssert objects[0].spriteId == 1
  doAssert objects[1].x == 5
  doAssert objects[1].y == -6
  doAssert objects[1].z == 7
  doAssert objects[1].layer == 3
  doAssert objects[1].spriteId == 2
  doAssert viewports[0].width == 128
  doAssert viewports[0].height == 128
  doAssert viewports[1].layer == 3
  doAssert viewports[1].width == 640
  doAssert viewports[1].height == 480

proc testSpriteMessageBytes() =
  ## Tests byte sizes for complete and partial server messages.
  echo "Testing sprite message byte sizes"
  var packet: seq[uint8]
  packet.addClearObjects()
  packet.addLayer(1, 2, 3)
  packet.addViewport(4, 320, 200)
  packet.addObject(5, -1, -2, -3, 4, 6)
  packet.addDeleteObject(7)

  var offset = 0
  doAssert packet.spriteMessageBytes(offset) == 1
  offset += packet.spriteMessageBytes(offset)
  doAssert packet.spriteMessageBytes(offset) == 4
  offset += packet.spriteMessageBytes(offset)
  doAssert packet.spriteMessageBytes(offset) == 6
  offset += packet.spriteMessageBytes(offset)
  doAssert packet.spriteMessageBytes(offset) == 12
  offset += packet.spriteMessageBytes(offset)
  doAssert packet.spriteMessageBytes(offset) == 3
  offset += packet.spriteMessageBytes(offset)
  doAssert offset == packet.len
  doAssert packet.spriteMessageBytes(packet.len) == 0
  doAssert packet.spriteMessageBytes(packet.len + 3) == 0

  var spritePacket: seq[uint8]
  spritePacket.addSprite(12, 2, 2, [1'u8, 2, 3, 4], "unit")
  doAssert spritePacket.spriteMessageBytes(0) == spritePacket.len
  doAssert spritePacket.spriteMessageBytes(1) == spritePacket.len - 1
  doAssert @[SpriteMessageObject, 1'u8].spriteMessageBytes(0) == 2
  doAssert @[0xff'u8, 1, 2, 3].spriteMessageBytes(0) == 4

proc testMalformedServerPackets() =
  ## Tests server packet parser failures for malformed packets.
  echo "Testing malformed sprite packets"
  doAssert parseSpritePacket(@[]).len == 0
  expectSpriteError(@[0xff'u8])
  expectSpriteError(@[SpriteMessageObject, 1'u8])
  expectSpriteError(@[SpriteMessageDeleteObject, 1'u8])
  expectSpriteError(@[SpriteMessageViewport, 1'u8, 2])
  expectSpriteError(@[SpriteMessageLayer, 1'u8, 2])
  expectSpriteError(@[SpriteMessageSprite, 1'u8])

  var compressedTruncated: seq[uint8]
  compressedTruncated.addU8(SpriteMessageSprite)
  compressedTruncated.addU16(1)
  compressedTruncated.addU16(1)
  compressedTruncated.addU16(1)
  compressedTruncated.addU32(4)
  compressedTruncated.addU8(10)
  compressedTruncated.addU8(11)
  expectSpriteError(compressedTruncated)

  var labelLengthMissing: seq[uint8]
  labelLengthMissing.addU8(SpriteMessageSprite)
  labelLengthMissing.addU16(1)
  labelLengthMissing.addU16(1)
  labelLengthMissing.addU16(1)
  labelLengthMissing.addU32(0)
  expectSpriteError(labelLengthMissing)

  var labelTruncated: seq[uint8]
  labelTruncated.addU8(SpriteMessageSprite)
  labelTruncated.addU16(1)
  labelTruncated.addU16(1)
  labelTruncated.addU16(1)
  labelTruncated.addU32(0)
  labelTruncated.addU16(3)
  labelTruncated.addU8(uint8(ord('a')))
  labelTruncated.addU8(uint8(ord('b')))
  expectSpriteError(labelTruncated)

proc testSpriteClientParser() =
  ## Tests client parser chat and input messages.
  echo "Testing sprite client parser"
  var debugPacket: seq[uint8]
  debugPacket.addObject(11, 1, 2, 3, SpriteLayerMap, 7)
  let
    clientBlob =
      blobFromSpriteChat("hi!") &
      blobFromSpriteDebugSprites(debugPacket) &
      blobFromSpriteMask(ButtonA or ButtonRight) &
      blobFromSpriteReady() &
      blobFromSpritesOff()
    clientMessages = clientBlob.parseSpriteClientMessages()
  doAssert clientMessages.len == 5
  doAssert clientMessages[0].kind == SpriteClientChatMessage
  doAssert clientMessages[0].text == "hi!"
  doAssert clientMessages[1].kind == SpriteClientDebugSpriteMessage
  doAssert clientMessages[1].debugSprites == debugPacket
  doAssert clientMessages[2].kind == SpriteClientInputMessage
  doAssert clientMessages[2].mask == (ButtonA or ButtonRight)
  doAssert clientMessages[3].kind == SpriteClientReadyMessage
  doAssert clientMessages[4].kind == SpriteClientSpritesOffMessage
  doAssert clientBlob.readSpriteInputText() == "hi!"
  doAssert clientBlob.spriteInputMask() == (ButtonA or ButtonRight)
  doAssert blobFromSpritesOff().isSpritesOffPacket()
  doAssert not blobFromSpriteReady().isSpritesOffPacket()

  let
    cleanChat = blobFromSpriteChat(
      "ok" & char(10) & "~" & char(127) & "!"
    )
    cleanMessages = cleanChat.parseSpriteClientMessages()
  doAssert cleanMessages.len == 1
  doAssert cleanMessages[0].text == "ok~!"

  let
    emptyChat = blobFromSpriteChat("")
    emptyMessages = emptyChat.parseSpriteClientMessages()
  doAssert emptyMessages.len == 1
  doAssert emptyMessages[0].text == ""

  let multiChat =
    blobFromSpriteChat("one") &
    blobFromSpriteChat("two")
  doAssert multiChat.readSpriteInputText() == "onetwo"
  doAssert blobFromSpriteMask(0xff).spriteInputMask() == 0x7f'u8
  doAssert blobFromSpriteMask(ButtonLeft).isSpriteInputPacket()
  doAssert blobFromSpriteMask(ButtonLeft).isSpritePlayerInputPacket()
  doAssert not blobFromSpriteChat("x").isSpriteInputPacket()
  doAssert blobFromSpriteChat("x").spriteInputMask() == 0'u8

proc testSpriteClientMouseParser() =
  ## Tests client parser mouse messages and optional layers.
  echo "Testing sprite client mouse parser"
  let
    withLayer =
      mouseMoveBlob(-12, 34, 5) &
      mouseButtonBlob(1, true)
    withLayerMessages = withLayer.parseSpriteClientMessages()
  doAssert withLayerMessages.len == 2
  doAssert withLayerMessages[0].kind == SpriteClientMouseMoveMessage
  doAssert withLayerMessages[0].x == -12
  doAssert withLayerMessages[0].y == 34
  doAssert withLayerMessages[0].hasLayer
  doAssert withLayerMessages[0].layer == 5
  doAssert withLayerMessages[1].kind == SpriteClientMouseButtonMessage
  doAssert withLayerMessages[1].button == 1'u8
  doAssert withLayerMessages[1].down

  let
    withoutLayer =
      mouseMoveBlob(99, -100) &
      blobFromSpriteMask(ButtonDown)
    withoutLayerMessages = withoutLayer.parseSpriteClientMessages()
  doAssert withoutLayerMessages.len == 2
  doAssert withoutLayerMessages[0].kind == SpriteClientMouseMoveMessage
  doAssert withoutLayerMessages[0].x == 99
  doAssert withoutLayerMessages[0].y == -100
  doAssert not withoutLayerMessages[0].hasLayer
  doAssert withoutLayerMessages[1].kind == SpriteClientInputMessage
  doAssert withoutLayerMessages[1].mask == ButtonDown

  let upMessages = mouseButtonBlob(2, false).parseSpriteClientMessages()
  doAssert upMessages.len == 1
  doAssert upMessages[0].kind == SpriteClientMouseButtonMessage
  doAssert upMessages[0].button == 2'u8
  doAssert not upMessages[0].down

proc testSpriteClientMalformedMessages() =
  ## Tests client parser graceful stops on malformed messages.
  echo "Testing malformed sprite client messages"
  doAssert parseSpriteClientMessages("").len == 0
  doAssert parseSpriteClientMessages(blobFromBytes(@[0xff'u8])).len == 0
  doAssert parseSpriteClientMessages(
    blobFromBytes(@[SpriteClientChat])
  ).len == 0
  doAssert parseSpriteClientMessages(
    blobFromBytes(@[SpriteClientChat, 4'u8, 0, uint8(ord('a'))])
  ).len == 0
  doAssert parseSpriteClientMessages(
    blobFromBytes(@[SpriteClientMouseMove, 1'u8, 0, 2])
  ).len == 0
  doAssert parseSpriteClientMessages(
    blobFromBytes(@[SpriteClientMouseButton, 1'u8])
  ).len == 0
  doAssert parseSpriteClientMessages(
    blobFromBytes(@[SpriteClientInput])
  ).len == 0
  doAssert parseSpriteClientMessages(
    blobFromBytes(@[SpriteClientDebugSprite, 4'u8, 0, 0, 0, 1])
  ).len == 0

  let
    partial =
      blobFromSpriteChat("ok") &
      blobFromBytes(@[SpriteClientInput])
    messages = partial.parseSpriteClientMessages()
  doAssert messages.len == 1
  doAssert messages[0].kind == SpriteClientChatMessage
  doAssert messages[0].text == "ok"

testInputMasks()
testLayerConstants()
testByteHelpers()
testServerPacketBuilders()
testMultipleServerDefinitions()
testSpriteMessageBytes()
testMalformedServerPackets()
testSpriteClientParser()
testSpriteClientMouseParser()
testSpriteClientMalformedMessages()
echo "All tests passed"

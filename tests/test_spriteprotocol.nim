import bitworld/spriteprotocol

echo "Testing sprite packet builders"
var packet: seq[uint8]
packet.addClearObjects()
packet.addViewport(2, 320, 240)
packet.addLayer(2, 1, 3)
packet.addSprite(7, 2, 2, [1'u8, 2, 3, 4], "ship")
packet.addObject(9, -4, 12, 2, 2, 7)
packet.addDeleteObject(4)

let
  messages = packet.parseSpritePacket()
  sprites = packet.spritePacketSpriteIds()
  objects = packet.spritePacketObjects()
  viewports = packet.spritePacketViewports()

doAssert messages.len == 6
doAssert sprites == @[7]
doAssert objects.len == 1
doAssert objects[0].id == 9
doAssert objects[0].x == -4
doAssert objects[0].y == 12
doAssert objects[0].z == 2
doAssert objects[0].layer == 2
doAssert objects[0].spriteId == 7
doAssert viewports.len == 1
doAssert viewports[0].layer == 2
doAssert viewports[0].width == 320
doAssert viewports[0].height == 240

echo "Testing sprite client parser"
let clientBlob =
  blobFromSpriteChat("hi!") &
  blobFromSpriteMask(ButtonA or ButtonRight)
let clientMessages = clientBlob.parseSpriteClientMessages()
doAssert clientMessages.len == 2
doAssert clientMessages[0].text == "hi!"
doAssert clientMessages[1].mask == (ButtonA or ButtonRight)
doAssert clientBlob.readSpriteInputText() == "hi!"
doAssert clientBlob.spriteInputMask() == (ButtonA or ButtonRight)

echo "Testing legacy input helpers"
let legacyBlob = blobFromMask(ButtonB)
doAssert legacyBlob.isInputPacket()
doAssert legacyBlob.blobToMask() == ButtonB
doAssert blobFromChat("ok").blobToChat() == "ok"

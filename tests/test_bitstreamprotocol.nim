import
  bitworld/bitstreamprotocol,
  bitworld/server

echo "Testing bitstream constants"
doAssert ScreenWidth == 128
doAssert ScreenHeight == 128
doAssert TileSize == 6
doAssert ProtocolBytes == (ScreenWidth * ScreenHeight) div 2

echo "Testing bitstream input masks"
let input = InputState(
  up: true,
  right: true,
  attack: true,
  b: true
)
let mask = input.encodeInputMask()
doAssert mask == (ButtonUp or ButtonRight or ButtonA or ButtonB)

let decoded = mask.decodeInputMask()
doAssert decoded.up
doAssert not decoded.down
doAssert not decoded.left
doAssert decoded.right
doAssert not decoded.select
doAssert decoded.attack
doAssert decoded.b

echo "Testing bitstream legacy packets"
let inputBlob = blobFromMask(mask)
doAssert inputBlob.isInputPacket()
doAssert not inputBlob.isChatPacket()
doAssert inputBlob.blobToMask() == mask

var bytes: seq[uint8]
inputBlob.blobToBytes(bytes)
doAssert bytes == @[PacketInput, mask]
doAssert blobFromBytes(bytes) == inputBlob

let chatBlob = blobFromChat("ok" & char(10) & "!")
doAssert chatBlob.isChatPacket()
doAssert chatBlob.blobToChat() == "ok!"

echo "Testing bitstream framebuffer packing"
var framebuffer = initFramebuffer()
doAssert framebuffer.indices.len == ScreenWidth * ScreenHeight
doAssert framebuffer.packed.len == ProtocolBytes
framebuffer.indices[0] = 1
framebuffer.indices[1] = 2
framebuffer.packFramebuffer()
doAssert framebuffer.packed[0] == 0x21'u8

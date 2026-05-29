import
  bitworld/server,
  bitworld/spriteprotocol

echo "Testing framebuffer lifecycle"
var framebuffer = initFramebuffer()
doAssert framebuffer.indices.len == ScreenWidth * ScreenHeight
doAssert framebuffer.packed.len == ProtocolBytes

framebuffer.clearFrame(3)
doAssert framebuffer.indices[0] == 3
doAssert framebuffer.indices[^1] == 3

framebuffer.putPixel(1, 0, 5)
framebuffer.putPixel(-1, 0, 7)
framebuffer.putPixel(ScreenWidth, 0, 7)
doAssert framebuffer.indices[1] == 5

framebuffer.packFramebuffer()
doAssert framebuffer.packed[0] == 0x53'u8

echo "Testing sprite helpers"
let sprite = Sprite(width: 2, height: 2, pixels: @[1'u8, 2, 3, 4])
doAssert sprite.spriteIndex(1, 1) == 3

echo "All tests passed"

## Round-trip tests for Define Encoded Sprite (0x08): every encoding
## must decode to the exact RGBA bytes that went in, the legacy Define
## Sprite message must keep working next to it, and malformed encoded
## messages must raise.

import
  std/[random, tables],
  bitworld/spriteprotocol,
  supersnappy

proc expectSpriteError(body: proc()) =
  ## Asserts that a body raises SpriteProtocolError.
  var raised = false
  try:
    body()
  except SpriteProtocolError:
    raised = true
  doAssert raised, "expected a sprite protocol error"

proc checkerPixels(width, height, colors: int, seed = 1): seq[uint8] =
  ## Builds a deterministic sprite with the given number of distinct
  ## RGBA values, including transparent and translucent pixels.
  var rng = initRand(seed)
  result = newSeq[uint8](width * height * 4)
  for i in 0 ..< width * height:
    let
      color = rng.rand(colors - 1)
      offset = i * 4
    result[offset] = uint8(color * 7 mod 256)
    result[offset + 1] = uint8(color * 13 mod 256)
    result[offset + 2] = uint8(color * 29 mod 256)
    result[offset + 3] = uint8(if color == 0: 0 elif color mod 3 == 0: 128 else: 255)

proc allColorsPixels(): seq[uint8] =
  ## A 16x16 sprite that uses exactly 256 distinct RGBA values.
  result = newSeq[uint8](256 * 4)
  for i in 0 ..< 256:
    result[i * 4] = uint8(i)
    result[i * 4 + 1] = uint8(255 - i)
    result[i * 4 + 2] = uint8(i * 3 mod 256)
    result[i * 4 + 3] = uint8(if i == 0: 0 else: 255)

proc noisePixels(width, height: int, seed = 2): seq[uint8] =
  ## Builds an incompressible RGBA sprite with far more than 256 colors.
  var rng = initRand(seed)
  result = newSeq[uint8](width * height * 4)
  for i in 0 ..< result.len:
    result[i] = uint8(rng.rand(255))

proc recolor(pixels: seq[uint8]): seq[uint8] =
  ## Recolors pixels one color at a time, the way a tint does.
  result = pixels
  for i in 0 ..< pixels.len div 4:
    let offset = i * 4
    result[offset] = 255'u8 - pixels[offset]
    result[offset + 1] = pixels[offset + 1] div 2
    result[offset + 2] = pixels[offset + 2] xor 0x55

proc decodeAll(packet: seq[uint8]): OrderedTable[int, DecodedSprite] =
  ## Decodes every sprite definition in a packet in order, resolving
  ## palette swaps against earlier definitions.
  result = initOrderedTable[int, DecodedSprite]()
  for message in packet.parseSpritePacket():
    if message.kind != spkSprite:
      continue
    var source: DecodedSprite
    let sourceId = message.sprite.paletteSwapSourceId()
    if sourceId >= 0 and result.hasKey(sourceId):
      source = result[sourceId]
    result[message.sprite.id] = message.sprite.decodeSprite(source)

proc testEncodings() =
  echo "Testing encoded sprite round trips"
  let
    indexed = checkerPixels(37, 23, 16)
    full = allColorsPixels()
    noise = noisePixels(64, 48)
    tinted = recolor(indexed)
  var packet: seq[uint8]
  doAssert packet.addEncodedSprite(1, 37, 23, indexed, "indexed") ==
    SpriteEncodingIndexed
  doAssert packet.addEncodedSprite(2, 16, 16, full, "full palette") ==
    SpriteEncodingIndexed
  doAssert packet.addEncodedSprite(3, 64, 48, noise, "noise") ==
    SpriteEncodingRgbaDeflate
  doAssert packet.addEncodedSprite(
    4, 64, 48, noise, "noise snappy", SpriteEncodingRgbaSnappy
  ) == SpriteEncodingRgbaSnappy
  doAssert packet.addEncodedSprite(
    5, 37, 23, indexed, "indexed deflate", SpriteEncodingRgbaDeflate
  ) == SpriteEncodingRgbaDeflate
  doAssert packet.addPaletteSwapSprite(6, 1, 37, 23, indexed, tinted, "tint")
  packet.addSprite(7, 37, 23, indexed, "legacy")
  packet.addEncodedSpritePayload(8, 37, 23, SpriteEncodingIndexed, [], "ghost")

  let decoded = packet.decodeAll()
  doAssert decoded.len == 8
  doAssert decoded[1].pixels == indexed
  doAssert decoded[1].indices.len == 37 * 23
  doAssert decoded[1].palette.len == 16 * 4
  doAssert decoded[2].pixels == full
  doAssert decoded[2].palette.len == 256 * 4
  doAssert decoded[3].pixels == noise
  doAssert decoded[3].indices.len == 0
  doAssert decoded[4].pixels == noise
  doAssert decoded[5].pixels == indexed
  doAssert decoded[6].pixels == tinted
  doAssert decoded[6].indices == decoded[1].indices
  doAssert decoded[7].pixels == indexed
  doAssert decoded[8].pixels.len == 0
  doAssert decoded[8].width == 37

  # A palette swap of a palette swap keeps working.
  var chained: seq[uint8]
  chained.addEncodedSprite(1, 37, 23, indexed)
  doAssert chained.addPaletteSwapSprite(2, 1, 37, 23, indexed, tinted)
  doAssert chained.addPaletteSwapSprite(3, 2, 37, 23, tinted, indexed)
  let chainDecoded = chained.decodeAll()
  doAssert chainDecoded[3].pixels == indexed

  # The messages parse with the encoding and payload preserved.
  let messages = packet.parseSpritePacket()
  doAssert messages[0].sprite.encoding == SpriteEncodingIndexed
  doAssert messages[2].sprite.encoding == SpriteEncodingRgbaDeflate
  doAssert messages[3].sprite.encoding == SpriteEncodingRgbaSnappy
  doAssert uncompress(messages[3].sprite.compressedPixels) == noise
  doAssert messages[5].sprite.encoding == SpriteEncodingPaletteSwap
  doAssert messages[5].sprite.paletteSwapSourceId() == 1
  doAssert messages[6].sprite.encoding == SpriteEncodingRgbaSnappy
  doAssert messages[6].sprite.paletteSwapSourceId() == -1
  doAssert messages[7].sprite.label == "ghost"
  doAssert packet.spritePacketSpriteIds() == @[1, 2, 3, 4, 5, 6, 7, 8]

  # Sizes: indexed beats snappy RGBA by a wide margin on flat art, and a
  # palette swap is header plus palette.
  var flat = newSeq[uint8](64 * 64 * 4)
  for i in 0 ..< 64 * 64:
    let color = (i mod 64 div 8 + i div 64 div 16) mod 6
    flat[i * 4] = uint8(color * 40)
    flat[i * 4 + 1] = uint8(200 - color * 30)
    flat[i * 4 + 2] = uint8(color * 90 mod 256)
    flat[i * 4 + 3] = 255
  var legacy, encoded, swap: seq[uint8]
  legacy.addSprite(1, 64, 64, flat)
  encoded.addEncodedSprite(1, 64, 64, flat)
  swap.addPaletteSwapSprite(2, 1, 64, 64, flat, recolor(flat))
  doAssert encoded.len * 4 < legacy.len
  doAssert swap.len == 14 + 2 + 1 + 6 * 4

proc testPaletteSwapFallback() =
  echo "Testing palette swap fallback"
  let
    base = checkerPixels(20, 20, 8)
    noise = noisePixels(20, 20) # 400 pixels, more than 256 colors
  var inconsistent = base
  # One pixel changes color while the other pixels of that source color
  # keep theirs, so the recoloring is not a palette swap.
  inconsistent[0] = 1
  inconsistent[1] = 2
  inconsistent[2] = 3
  inconsistent[3] = 4
  var packet: seq[uint8]
  packet.addEncodedSprite(1, 20, 20, base)
  doAssert not packet.addPaletteSwapSprite(2, 1, 20, 20, base, inconsistent)
  doAssert not packet.addPaletteSwapSprite(3, 1, 20, 20, noise, base)
  let decoded = packet.decodeAll()
  doAssert decoded[2].pixels == inconsistent
  doAssert decoded[2].indices.len == 400
  doAssert decoded[3].pixels == base
  doAssert encodePaletteSwapPayload(1, base, base).len == 3 + 8 * 4
  doAssert encodePaletteSwapPayload(1, noise, noise).len == 0
  doAssert encodePaletteSwapPayload(1, base, base[0 ..< 8]).len == 0
  doAssert encodePaletteSwapPayload(1, base, inconsistent).len == 0

proc testEncodedMessageBytes() =
  echo "Testing encoded sprite message byte sizes"
  var packet: seq[uint8]
  packet.addEncodedSprite(3, 4, 4, checkerPixels(4, 4, 3), "abc")
  packet.addPaletteSwapSprite(4, 3, 4, 4, checkerPixels(4, 4, 3),
    recolor(checkerPixels(4, 4, 3)), "")
  packet.addObject(1, 0, 0, 0, 0, 3)
  var offset = 0
  let first = packet.spriteMessageBytes(0)
  doAssert packet[0] == SpriteMessageEncodedSprite
  doAssert first > 14 + 3
  offset += first
  doAssert packet[offset] == SpriteMessageEncodedSprite
  doAssert packet.spriteMessageBytes(offset) == 14 + 3 + 3 * 4
  offset += packet.spriteMessageBytes(offset)
  doAssert packet.spriteMessageBytes(offset) == 12
  offset += 12
  doAssert offset == packet.len
  doAssert @[SpriteMessageEncodedSprite, 1'u8, 2].spriteMessageBytes(0) == 3

proc testMalformedEncodedMessages() =
  echo "Testing malformed encoded sprites"
  proc header(encoding: uint8, payloadLen: int): seq[uint8] =
    result.addU8(SpriteMessageEncodedSprite)
    result.addU16(1)
    result.addU16(2)
    result.addU16(2)
    result.addU8(encoding)
    result.addU32(payloadLen)

  expectSpriteError(proc() = discard parseSpritePacket(@[SpriteMessageEncodedSprite, 1'u8]))
  expectSpriteError(proc() = discard parseSpritePacket(header(0x04, 0) & @[0'u8, 0]))
  expectSpriteError(proc() = discard parseSpritePacket(header(SpriteEncodingIndexed, 5) & @[1'u8]))
  expectSpriteError(proc() = discard parseSpritePacket(header(SpriteEncodingIndexed, 0)))

  # Decoding failures: bad deflate stream, index out of range, palette
  # swap without a source, pixel count mismatch.
  var badDeflate = header(SpriteEncodingRgbaDeflate, 3) & @[1'u8, 2, 3, 0, 0]
  expectSpriteError(proc() = discard badDeflate.parseSpritePacket()[0].sprite.decodeSprite())

  var payload: seq[uint8]
  payload.add(0'u8) # one palette entry
  payload.add([9'u8, 9, 9, 255])
  payload.add(encodeRgbaDeflatePayload([0'u8, 1, 0, 0])) # index 1 is out of range
  var outOfRange = header(SpriteEncodingIndexed, payload.len) & payload & @[0'u8, 0]
  expectSpriteError(proc() = discard outOfRange.parseSpritePacket()[0].sprite.decodeSprite())

  var swap: seq[uint8]
  swap.addU16(7)
  swap.add(0'u8)
  swap.add([1'u8, 2, 3, 4])
  var noSource = header(SpriteEncodingPaletteSwap, swap.len) & swap & @[0'u8, 0]
  expectSpriteError(proc() = discard noSource.parseSpritePacket()[0].sprite.decodeSprite())

  var wrongSize: seq[uint8]
  wrongSize.addEncodedSprite(1, 2, 2, checkerPixels(3, 3, 2))
  expectSpriteError(proc() = discard wrongSize.parseSpritePacket()[0].sprite.decodeSprite())

  expectSpriteError(proc() =
    var packet: seq[uint8]
    packet.addEncodedSprite(1, 64, 48, noisePixels(64, 48), "", SpriteEncodingIndexed)
  )

testEncodings()
testPaletteSwapFallback()
testEncodedMessageBytes()
testMalformedEncodedMessages()
echo "All tests passed"

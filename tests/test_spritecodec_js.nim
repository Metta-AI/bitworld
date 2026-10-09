## Cross-checks the browser decoder (client/spritecodec.js) against the
## Nim encoder: builds a packet that exercises every encoding, writes
## the source RGBA next to it, and has node decode the packet with the
## same JavaScript the HTML clients load. Skips when node is missing.

import
  std/[os, osproc, random, strutils],
  bitworld/spriteprotocol

proc pixels(width, height, colors: int, seed: int): seq[uint8] =
  ## Deterministic sprite with the given number of RGBA values.
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

proc bands(width, height, colors: int): seq[uint8] =
  ## Long horizontal runs of few colors: highly compressible, so the
  ## deflate stream has long matches.
  result = newSeq[uint8](width * height * 4)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let
        color = (x div 16 + y div 8) mod colors
        offset = (y * width + x) * 4
      result[offset] = uint8(color * 40)
      result[offset + 1] = uint8(255 - color * 30)
      result[offset + 2] = uint8(color * 90)
      result[offset + 3] = 255

proc noise(width, height: int, seed: int): seq[uint8] =
  ## Incompressible RGBA, which makes deflate fall back to stored blocks.
  var rng = initRand(seed)
  result = newSeq[uint8](width * height * 4)
  for i in 0 ..< result.len:
    result[i] = uint8(rng.rand(255))

proc recolor(source: seq[uint8]): seq[uint8] =
  result = source
  for i in 0 ..< source.len div 4:
    let offset = i * 4
    result[offset] = source[offset] xor 0xa5
    result[offset + 1] = source[offset + 1] div 3
    result[offset + 2] = 255'u8 - source[offset + 2]

proc main() =
  echo "Testing browser sprite codec against the Nim encoder"
  let node = findExe("node")
  if node.len == 0:
    echo "node not found, skipping browser codec check"
    return

  var packet, expected: seq[uint8]
  proc expect(id: int, rgba: seq[uint8]) =
    expected.addU16(id)
    expected.addU32(rgba.len)
    expected.add(rgba)

  let
    small = pixels(37, 23, 16, 1)
    full = pixels(40, 30, 256, 2)
    flat = bands(300, 200, 6)
    random = noise(64, 48, 3)
    tinted = recolor(small)
    tintedFlat = recolor(flat)
    tiny = pixels(1, 1, 2, 4)

  packet.addEncodedSprite(1, 37, 23, small, "indexed")
  expect(1, small)
  packet.addEncodedSprite(2, 40, 30, full, "full palette")
  expect(2, full)
  packet.addEncodedSprite(3, 300, 200, flat, "bands")
  expect(3, flat)
  packet.addEncodedSprite(4, 64, 48, random, "noise deflate")
  expect(4, random)
  packet.addEncodedSprite(5, 64, 48, random, "noise snappy", SpriteEncodingRgbaSnappy)
  expect(5, random)
  packet.addEncodedSprite(6, 300, 200, flat, "bands deflate", SpriteEncodingRgbaDeflate)
  expect(6, flat)
  doAssert packet.addPaletteSwapSprite(7, 1, 37, 23, small, tinted, "tint")
  expect(7, tinted)
  doAssert packet.addPaletteSwapSprite(8, 3, 300, 200, flat, tintedFlat, "bands tint")
  expect(8, tintedFlat)
  doAssert packet.addPaletteSwapSprite(9, 8, 300, 200, tintedFlat, flat, "bands back")
  expect(9, flat)
  packet.addSprite(10, 37, 23, small, "legacy")
  expect(10, small)
  packet.addEncodedSprite(11, 1, 1, tiny, "tiny")
  expect(11, tiny)

  let dir = getTempDir() / "bitworld_spritecodec_check"
  createDir(dir)
  let
    packetPath = dir / "packet.bin"
    expectedPath = dir / "expected.bin"
  writeFile(packetPath, cast[string](packet))
  writeFile(expectedPath, cast[string](expected))

  let script = currentSourcePath().parentDir() / "spritecodec_check.js"
  let (output, code) = execCmdEx(
    quoteShellCommand([node, script, packetPath, expectedPath])
  )
  echo output.strip()
  doAssert code == 0, "browser codec check failed"
  doAssert "11 sprites checked, 0 failed" in output
  echo "All tests passed"

main()

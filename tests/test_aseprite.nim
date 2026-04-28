import
  std/os,
  pixie,
  bitworld/aseprite, protocol

const
  RootDir = currentSourcePath.parentDir.parentDir
  DataDir = RootDir / "clients" / "data"

proc countPixelDiff(a, b: Image): int =
  ## Counts pixel differences between two same-sized images.
  doAssert a.width == b.width, "image widths should match"
  doAssert a.height == b.height, "image heights should match"
  for y in 0 ..< a.height:
    for x in 0 ..< a.width:
      if a[x, y] != b[x, y]:
        inc result

proc testasepriteMetadata() =
  ## Tests parsed aseprite metadata from existing client assets.
  echo "Testing aseprite metadata"
  let aseprite = readAseprite(DataDir / "logo.aseprite")
  doAssert aseprite.header.width == 64, "logo width should be decoded"
  doAssert aseprite.header.height == 64, "logo height should be decoded"
  doAssert aseprite.frames.len == 1, "logo should contain one frame"
  doAssert aseprite.layers.len == 1, "logo should contain one layer"
  doAssert aseprite.header.colorDepth == DepthIndexed, "logo should be indexed"

proc testasepriteRendering() =
  ## Tests rendering aseprite frames to Pixie images.
  echo "Testing aseprite rendering"
  for name in ["ascii", "transport"]:
    let
      rendered = readAsepriteImage(DataDir / (name & ".aseprite"))
      expected = readImage(DataDir / (name & ".png"))
    doAssert rendered.width == expected.width, name & " width should match"
    doAssert rendered.height == expected.height, name & " height should match"
    doAssert countPixelDiff(rendered, expected) == 0,
      name & " rendered pixels should match exported PNG"

proc testasepriteSpriteConversion() =
  ## Tests conversion from rendered aseprite frames to game sprites.
  echo "Testing aseprite sprite conversion"
  loadPalette(DataDir / "pallete.png")
  let sprite = readAsepriteSprite(DataDir / "transport.aseprite")
  doAssert sprite.width == 48, "transport sprite width should be decoded"
  doAssert sprite.height == 6, "transport sprite height should be decoded"
  doAssert sprite.pixels.len == sprite.width * sprite.height,
    "transport sprite pixel count should match dimensions"

testasepriteMetadata()
testasepriteRendering()
testasepriteSpriteConversion()
echo "All tests passed"

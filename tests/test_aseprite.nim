import
  std/os,
  pixie,
  ../client/aseprite, protocol

const
  RootDir = currentSourcePath.parentDir.parentDir
  DataDir = RootDir / "client" / "data"

proc countPixelDiff(a, b: Image): int =
  ## Counts pixel differences between two same-sized images.
  doAssert a.width == b.width, "image widths should match"
  doAssert a.height == b.height, "image heights should match"
  for y in 0 ..< a.height:
    for x in 0 ..< a.width:
      if a[x, y] != b[x, y]:
        inc result

proc testAsepriteMetadata() =
  ## Tests parsed Aseprite metadata from existing client assets.
  echo "Testing Aseprite metadata"
  let logo = readAseprite(DataDir / "logo.aseprite")
  doAssert logo.header.width == 64, "logo width should be decoded"
  doAssert logo.header.height == 64, "logo height should be decoded"
  doAssert logo.frames.len == 1, "logo should contain one frame"
  doAssert logo.layers.len == 1, "logo should contain one layer"
  doAssert logo.header.colorDepth == DepthIndexed, "logo should be indexed"

proc testAsepriteRendering() =
  ## Tests rendering Aseprite frames to Pixie images.
  echo "Testing Aseprite rendering"
  for name in ["ascii", "transport"]:
    let
      rendered = readAsepriteImage(DataDir / (name & ".aseprite"))
      expected = readImage(DataDir / (name & ".png"))
    doAssert rendered.width == expected.width, name & " width should match"
    doAssert rendered.height == expected.height, name & " height should match"
    doAssert countPixelDiff(rendered, expected) == 0,
      name & " rendered pixels should match exported PNG"

proc testAsepriteSpriteConversion() =
  ## Tests conversion from rendered Aseprite frames to game sprites.
  echo "Testing Aseprite sprite conversion"
  loadPalette(DataDir / "pallete.png")
  let sprite = readAsepriteSprite(DataDir / "transport.aseprite")
  doAssert sprite.width == 48, "transport sprite width should be decoded"
  doAssert sprite.height == 6, "transport sprite height should be decoded"
  doAssert sprite.pixels.len == sprite.width * sprite.height,
    "transport sprite pixel count should match dimensions"

testAsepriteMetadata()
testAsepriteRendering()
testAsepriteSpriteConversion()
echo "All tests passed"

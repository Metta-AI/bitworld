import
  std/os,
  pixie,
  ../common/server,
  ../common/pixelfonts

const
  RootDir = currentSourcePath.parentDir.parentDir
  FontPath = RootDir / "among_them" / "tiny5.aseprite"
  PreviewPath = RootDir / "out" / "tiny5_preview.png"
  PreviewText =
    "the quick brown fox jumps over the lazy dog. " &
    "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG. " &
    "0123456789 red sus green clean vote skip tasks done! "

proc foregroundPixels(image: Image, background: ColorRGBA): int =
  ## Counts pixels that differ from the preview background.
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      if image[x, y] != background:
        inc result

proc repeatedPreviewText(): string =
  ## Builds enough pangram text to fill the preview image.
  while result.len < 1200:
    result.add(PreviewText)

proc testTiny5Decode(font: PixelFont) =
  ## Tests the tiny5 font dimensions and printable ASCII glyphs.
  echo "Testing tiny5 font decode"
  doAssert font.height == 6, "tiny5 should be six pixels high"
  doAssert font.glyphs.len == PrintableAsciiCount,
    "tiny5 should contain printable ASCII glyphs"
  doAssert font.glyphs[0].ch == ' ', "tiny5 should start with space"
  doAssert font.glyphs[ord('A') - FirstPrintableAscii].width > 0,
    "tiny5 should contain A"
  doAssert font.glyphs[ord('?') - FirstPrintableAscii].width > 0,
    "tiny5 should contain fallback question mark"

proc testTiny5Preview(font: PixelFont) =
  ## Draws and saves a dense 128 by 128 tiny5 preview image.
  echo "Testing tiny5 preview rendering"
  let background = font.background
  var image = newImage(128, 128)
  image.fill(background)
  let box = image.drawTextBox(
    font,
    repeatedPreviewText(),
    0,
    0,
    image.width,
    image.height,
    rgba(255, 255, 255, 255),
    1
  )
  doAssert box.lines > 8, "tiny5 preview should fill many lines"
  doAssert image.foregroundPixels(background) > 800,
    "tiny5 preview should draw visible text"
  createDir(PreviewPath.splitFile.dir)
  image.writeFile(PreviewPath)
  echo "Wrote " & PreviewPath

proc testTiny5ImageOcr(font: PixelFont) =
  ## Tests exact OCR against text rendered into a Pixie image.
  echo "Testing tiny5 image OCR"
  let
    background = font.background
    text = "red sus"
  var image = newImage(128, 128)
  image.fill(background)
  image.drawText(font, text, 13, 19, rgba(255, 255, 255, 255))
  let
    score = image.textScore(font, text, 13, 19)
    mismatch = image.textScore(font, "red sad", 13, 19)
    found = image.findText(font, text)
    read = image.readRun(font, 13, 19, text.len)
  doAssert score.glyphError() == 0, "image OCR should match exactly"
  doAssert mismatch.glyphError() > 0, "image OCR should reject bad text"
  doAssert image.textMatches(font, text, 13, 19),
    "image OCR should match known text"
  doAssert found.found, "image OCR should find known text"
  doAssert found.x == 13, "image OCR should find the expected x"
  doAssert found.y == 19, "image OCR should find the expected y"
  doAssert read == text, "image OCR should read the rendered text"

proc testTiny5FramebufferOcr(font: PixelFont) =
  ## Tests exact OCR against text rendered into a 128 by 128 framebuffer.
  echo "Testing tiny5 framebuffer OCR"
  let text = "vote skip"
  var fb = initFramebuffer()
  fb.clearFrame(0)
  fb.drawText(font, text, 5, 87, 1'u8)
  let
    score = fb.indices.textScore(font, text, 5, 87)
    mismatch = fb.indices.textScore(font, "vote red", 5, 87)
    found = fb.indices.findText(font, text)
    read = fb.indices.readRun(font, 5, 87, text.len)
  doAssert score.glyphError() == 0, "frame OCR should match exactly"
  doAssert mismatch.glyphError() > 0, "frame OCR should reject bad text"
  doAssert fb.indices.textMatches(font, text, 5, 87),
    "frame OCR should match known text"
  doAssert found.found, "frame OCR should find known text"
  doAssert found.x == 5, "frame OCR should find the expected x"
  doAssert found.y == 87, "frame OCR should find the expected y"
  doAssert read == text, "frame OCR should read the rendered text"

let font = readPixelFont(FontPath)
testTiny5Decode(font)
testTiny5Preview(font)
testTiny5ImageOcr(font)
testTiny5FramebufferOcr(font)
echo "All tests passed"

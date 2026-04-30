import
  std/os,
  pixie,
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

let font = readPixelFont(FontPath)
testTiny5Decode(font)
testTiny5Preview(font)
echo "All tests passed"

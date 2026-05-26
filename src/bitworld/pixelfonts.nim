import
  std/[os, strutils],
  pixie,
  bitworld/aseprite,
  protocol,
  server

const
  FirstPrintableAscii* = 32
  LastPrintableAscii* = 126
  PrintableAsciiCount* = LastPrintableAscii - FirstPrintableAscii + 1
  DefaultGlyphSpacing* = 1
  WhiteTextIndex* = 2'u8
  WhiteTextThreshold = 180'u8

type
  PixelFontError* = object of ValueError
    ## Raised when a pixel font cannot be decoded.

  PixelGlyph* = object
    ch*: char
    width*, height*: int
    pixels*: seq[bool]

  PixelTextBox* = object
    lines*: int
    clipped*: bool

  PixelGlyphScore* = object
    misses*: int
    extras*: int
    opaque*: int
    foreground*: int

  PixelTextMatch* = object
    found*: bool
    x*, y*: int

  PixelFont* = object
    height*: int
    spacing*: int
    background*: ColorRGBA
    glyphs*: seq[PixelGlyph]

proc fail(message: string) {.raises: [PixelFontError].} =
  ## Raises a formatted pixel font decoder error.
  raise newException(PixelFontError, message)

proc isMarker(pixel: ColorRGBA): bool {.raises: [].} =
  ## Returns true when a pixel looks like a yellow width marker.
  pixel.a > 20'u8 and
    pixel.r > 180'u8 and
    pixel.g > 160'u8 and
    pixel.b < 120'u8

proc isWhiteTextPixel*(pixel: ColorRGBA): bool {.raises: [].} =
  ## Returns true when one RGBA pixel is white text ink.
  pixel.a > 20'u8 and
    pixel.r >= WhiteTextThreshold and
    pixel.g >= WhiteTextThreshold and
    pixel.b >= WhiteTextThreshold

proc isWhiteTextIndex*(index: uint8): bool {.raises: [].} =
  ## Returns true when one palette index is white text ink.
  if index == WhiteTextIndex:
    return true
  let pixel = Palette[int(index and 0x0f'u8)]
  pixel.isWhiteTextPixel()

proc glyphIndex*(font: PixelFont, ch: char): int {.raises: [].} =
  ## Returns the glyph index for a printable ASCII character.
  result = ord(ch) - FirstPrintableAscii
  if result < 0 or result >= font.glyphs.len:
    result = ord('?') - FirstPrintableAscii
  if result < 0 or result >= font.glyphs.len:
    result = -1

proc glyphAt*(font: PixelFont, ch: char): PixelGlyph {.raises: [].} =
  ## Returns a glyph for a character or an empty glyph.
  let index = font.glyphIndex(ch)
  if index < 0:
    return PixelGlyph()
  font.glyphs[index]

proc glyphPixel*(glyph: PixelGlyph, x, y: int): bool {.raises: [].} =
  ## Returns true when one glyph pixel is foreground.
  if x < 0 or y < 0 or x >= glyph.width or y >= glyph.height:
    return false
  glyph.pixels[y * glyph.width + x]

proc readFontImage(path: string): Image
    {.raises: [AsepriteError, IOError, PixieError].} =
  ## Reads one font source image from PNG or Aseprite.
  if not fileExists(path):
    raise newException(IOError, "Missing pixel font asset: " & path)
  let ext = path.splitFile.ext.toLowerAscii()
  if ext == ".aseprite":
    readAsepriteImage(path)
  else:
    readImage(path)

proc decodePixelFont*(
  image: Image,
  spacing = DefaultGlyphSpacing
): PixelFont {.raises: [PixelFontError].} =
  ## Decodes a horizontal ASCII font with a yellow width marker row.
  if image == nil:
    fail("Pixel font image cannot be nil.")
  if image.width <= 0 or image.height < 2:
    fail("Pixel font image must be at least one pixel wide and two high.")

  result.height = image.height - 1
  result.spacing = spacing
  result.background = image[0, 0]

  let markerY = image.height - 1
  var
    x = 0
    code = FirstPrintableAscii
  while x < image.width and code <= LastPrintableAscii:
    while x < image.width and not image[x, markerY].isMarker():
      inc x
    if x >= image.width:
      break
    var width = 0
    while x + width < image.width and image[x + width, markerY].isMarker():
      inc width

    var glyph = PixelGlyph(
      ch: char(code),
      width: width,
      height: result.height
    )
    glyph.pixels = newSeq[bool](width * result.height)
    for gy in 0 ..< result.height:
      for gx in 0 ..< width:
        let pixel = image[x + gx, gy]
        glyph.pixels[gy * width + gx] = pixel.isWhiteTextPixel()
    result.glyphs.add(glyph)
    x += width + spacing
    inc code

  if result.glyphs.len == 0:
    fail("Pixel font has no glyphs.")

proc readPixelFont*(
  path: string,
  spacing = DefaultGlyphSpacing
): PixelFont {.raises: [AsepriteError, IOError, PixieError, PixelFontError].} =
  ## Reads and decodes a pixel font from PNG or Aseprite.
  decodePixelFont(readFontImage(path), spacing)

proc textWidth*(font: PixelFont, text: string): int {.raises: [].} =
  ## Returns the width of the widest line in a text run.
  var lineWidth = 0
  for ch in text:
    if ch == '\n':
      result = max(result, lineWidth)
      lineWidth = 0
      continue
    let glyph = font.glyphAt(ch)
    if glyph.width <= 0:
      continue
    if lineWidth > 0:
      lineWidth += font.spacing
    lineWidth += glyph.width
  max(result, lineWidth)

proc glyphAdvance*(font: PixelFont, ch: char): int {.raises: [].} =
  ## Returns the horizontal advance for one character.
  let glyph = font.glyphAt(ch)
  if glyph.width <= 0:
    return 0
  glyph.width + font.spacing

proc lineHeight*(font: PixelFont, lineGap = DefaultGlyphSpacing): int
    {.raises: [].} =
  ## Returns the vertical advance for one text line.
  font.height + lineGap

proc glyphPreference(ch: char): int {.raises: [].} =
  ## Returns a deterministic tie-break preference for OCR glyphs.
  if ch in {'a' .. 'z'}:
    return 4
  if ch in {'0' .. '9'}:
    return 3
  if ch in {'A' .. 'Z'}:
    return 2
  if ch == ' ':
    return 1
  0

proc glyphError*(score: PixelGlyphScore): int {.raises: [].} =
  ## Returns the total OCR error count for one glyph or text score.
  score.misses + score.extras

proc scorePixel(
  score: var PixelGlyphScore,
  expected,
  actual: bool
) {.raises: [].} =
  ## Adds one expected and actual pixel comparison to an OCR score.
  if actual:
    inc score.foreground
  if expected:
    inc score.opaque
    if not actual:
      inc score.misses
  elif actual:
    inc score.extras

proc imagePixelOn(
  image: Image,
  x,
  y: int,
  background: ColorRGBA
): bool {.raises: [].} =
  ## Returns true when one image pixel is white text ink.
  discard background
  if image == nil or x < 0 or y < 0 or
      x >= image.width or y >= image.height:
    return false
  image[x, y].isWhiteTextPixel()

proc framePixelOn(
  frame: openArray[uint8],
  x,
  y: int,
  background: uint8
): bool {.raises: [].} =
  ## Returns true when one framebuffer pixel is white text ink.
  discard background
  if x < 0 or y < 0 or x >= ScreenWidth or y >= ScreenHeight:
    return false
  let index = y * ScreenWidth + x
  if index < 0 or index >= frame.len:
    return false
  frame[index].isWhiteTextIndex()

proc glyphScore*(
  image: Image,
  font: PixelFont,
  ch: char,
  x,
  y: int,
  background: ColorRGBA
): PixelGlyphScore {.raises: [].} =
  ## Scores one glyph against image pixels at the given position.
  let glyph = font.glyphAt(ch)
  let scanWidth = glyph.width + font.spacing
  for gy in 0 ..< glyph.height:
    for gx in 0 ..< scanWidth:
      let
        expected = gx < glyph.width and glyph.glyphPixel(gx, gy)
        actual = image.imagePixelOn(x + gx, y + gy, background)
      result.scorePixel(expected, actual)

proc glyphScore*(
  image: Image,
  font: PixelFont,
  ch: char,
  x,
  y: int
): PixelGlyphScore {.raises: [].} =
  ## Scores one glyph against image pixels using the font background.
  image.glyphScore(font, ch, x, y, font.background)

proc glyphScore*(
  frame: openArray[uint8],
  font: PixelFont,
  ch: char,
  x,
  y: int,
  background: uint8
): PixelGlyphScore {.raises: [].} =
  ## Scores one glyph against framebuffer pixels at the given position.
  let glyph = font.glyphAt(ch)
  let scanWidth = glyph.width + font.spacing
  for gy in 0 ..< glyph.height:
    for gx in 0 ..< scanWidth:
      let
        expected = gx < glyph.width and glyph.glyphPixel(gx, gy)
        actual = frame.framePixelOn(x + gx, y + gy, background)
      result.scorePixel(expected, actual)

proc glyphScore*(
  frame: openArray[uint8],
  font: PixelFont,
  ch: char,
  x,
  y: int
): PixelGlyphScore {.raises: [].} =
  ## Scores one glyph against framebuffer pixels using black background.
  frame.glyphScore(font, ch, x, y, 0'u8)

proc textScore*(
  image: Image,
  font: PixelFont,
  text: string,
  x,
  y: int,
  background: ColorRGBA
): PixelGlyphScore {.raises: [].} =
  ## Scores one expected text run against image pixels.
  var
    penX = x
    penY = y
  for ch in text:
    if ch == '\n':
      penX = x
      penY += font.height + font.spacing
      continue
    let score = image.glyphScore(font, ch, penX, penY, background)
    result.misses += score.misses
    result.extras += score.extras
    result.opaque += score.opaque
    result.foreground += score.foreground
    penX += font.glyphAdvance(ch)

proc textScore*(
  image: Image,
  font: PixelFont,
  text: string,
  x,
  y: int
): PixelGlyphScore {.raises: [].} =
  ## Scores one expected text run using the font background.
  image.textScore(font, text, x, y, font.background)

proc textScore*(
  frame: openArray[uint8],
  font: PixelFont,
  text: string,
  x,
  y: int,
  background: uint8
): PixelGlyphScore {.raises: [].} =
  ## Scores one expected text run against framebuffer pixels.
  var
    penX = x
    penY = y
  for ch in text:
    if ch == '\n':
      penX = x
      penY += font.height + font.spacing
      continue
    let score = frame.glyphScore(font, ch, penX, penY, background)
    result.misses += score.misses
    result.extras += score.extras
    result.opaque += score.opaque
    result.foreground += score.foreground
    penX += font.glyphAdvance(ch)

proc textScore*(
  frame: openArray[uint8],
  font: PixelFont,
  text: string,
  x,
  y: int
): PixelGlyphScore {.raises: [].} =
  ## Scores one expected text run using black background.
  frame.textScore(font, text, x, y, 0'u8)

proc textMatches*(
  image: Image,
  font: PixelFont,
  text: string,
  x,
  y: int,
  background: ColorRGBA,
  maxErrors = 0
): bool {.raises: [].} =
  ## Returns true when an expected text run matches image pixels.
  let score = image.textScore(font, text, x, y, background)
  score.opaque > 0 and score.glyphError() <= maxErrors

proc textMatches*(
  image: Image,
  font: PixelFont,
  text: string,
  x,
  y: int,
  maxErrors = 0
): bool {.raises: [].} =
  ## Returns true when expected text matches using the font background.
  image.textMatches(font, text, x, y, font.background, maxErrors)

proc textMatches*(
  frame: openArray[uint8],
  font: PixelFont,
  text: string,
  x,
  y: int,
  background: uint8,
  maxErrors = 0
): bool {.raises: [].} =
  ## Returns true when expected text matches framebuffer pixels.
  let score = frame.textScore(font, text, x, y, background)
  score.opaque > 0 and score.glyphError() <= maxErrors

proc textMatches*(
  frame: openArray[uint8],
  font: PixelFont,
  text: string,
  x,
  y: int,
  maxErrors = 0
): bool {.raises: [].} =
  ## Returns true when expected text matches a black framebuffer.
  frame.textMatches(font, text, x, y, 0'u8, maxErrors)

proc findText*(
  image: Image,
  font: PixelFont,
  text: string,
  background: ColorRGBA,
  maxErrors = 0
): PixelTextMatch {.raises: [].} =
  ## Finds an expected text run anywhere in image pixels.
  if image == nil or text.len == 0:
    return
  let maxX = image.width - font.textWidth(text)
  if maxX < 0 or image.height < font.height:
    return
  for sy in 0 .. image.height - font.height:
    for sx in 0 .. maxX:
      if image.textMatches(font, text, sx, sy, background, maxErrors):
        return PixelTextMatch(found: true, x: sx, y: sy)

proc findText*(
  image: Image,
  font: PixelFont,
  text: string,
  maxErrors = 0
): PixelTextMatch {.raises: [].} =
  ## Finds an expected text run using the font background.
  image.findText(font, text, font.background, maxErrors)

proc findText*(
  frame: openArray[uint8],
  font: PixelFont,
  text: string,
  background: uint8,
  maxErrors = 0
): PixelTextMatch {.raises: [].} =
  ## Finds an expected text run anywhere in framebuffer pixels.
  if text.len == 0:
    return
  let maxX = ScreenWidth - font.textWidth(text)
  if maxX < 0 or ScreenHeight < font.height:
    return
  for sy in 0 .. ScreenHeight - font.height:
    for sx in 0 .. maxX:
      if frame.textMatches(font, text, sx, sy, background, maxErrors):
        return PixelTextMatch(found: true, x: sx, y: sy)

proc findText*(
  frame: openArray[uint8],
  font: PixelFont,
  text: string,
  maxErrors = 0
): PixelTextMatch {.raises: [].} =
  ## Finds an expected text run in a black framebuffer.
  frame.findText(font, text, 0'u8, maxErrors)

proc bestGlyph*(
  image: Image,
  font: PixelFont,
  x,
  y: int,
  background: ColorRGBA,
  maxErrors = 0
): char {.raises: [].} =
  ## Reads the best glyph at one image position.
  var
    bestChar = '?'
    bestErrors = high(int)
    bestOpaque = -1
    bestPreference = -1
  for glyph in font.glyphs:
    let score = image.glyphScore(font, glyph.ch, x, y, background)
    let errors = score.glyphError()
    let preference = glyphPreference(glyph.ch)
    if errors < bestErrors or
        (errors == bestErrors and score.opaque > bestOpaque) or
        (
          errors == bestErrors and
          score.opaque == bestOpaque and
          preference > bestPreference
        ):
      bestChar = glyph.ch
      bestErrors = errors
      bestOpaque = score.opaque
      bestPreference = preference
  if bestErrors <= maxErrors:
    bestChar
  else:
    '?'

proc bestGlyph*(
  frame: openArray[uint8],
  font: PixelFont,
  x,
  y: int,
  background: uint8,
  maxErrors = 0
): char {.raises: [].} =
  ## Reads the best glyph at one framebuffer position.
  var
    bestChar = '?'
    bestErrors = high(int)
    bestOpaque = -1
    bestPreference = -1
  for glyph in font.glyphs:
    let score = frame.glyphScore(font, glyph.ch, x, y, background)
    let errors = score.glyphError()
    let preference = glyphPreference(glyph.ch)
    if errors < bestErrors or
        (errors == bestErrors and score.opaque > bestOpaque) or
        (
          errors == bestErrors and
          score.opaque == bestOpaque and
          preference > bestPreference
        ):
      bestChar = glyph.ch
      bestErrors = errors
      bestOpaque = score.opaque
      bestPreference = preference
  if bestErrors <= maxErrors:
    bestChar
  else:
    '?'

proc bestGlyph*(
  image: Image,
  font: PixelFont,
  x,
  y: int,
  maxErrors = 0
): char {.raises: [].} =
  ## Reads the best glyph using the font background.
  image.bestGlyph(font, x, y, font.background, maxErrors)

proc bestGlyph*(
  frame: openArray[uint8],
  font: PixelFont,
  x,
  y: int,
  maxErrors = 0
): char {.raises: [].} =
  ## Reads the best glyph from a black framebuffer.
  frame.bestGlyph(font, x, y, 0'u8, maxErrors)

proc readRun*(
  image: Image,
  font: PixelFont,
  x,
  y,
  count: int,
  background: ColorRGBA,
  maxErrors = 0,
  stripResult = true
): string {.raises: [].} =
  ## Reads a fixed number of variable-width glyphs from an image.
  var penX = x
  for i in 0 ..< count:
    let ch = image.bestGlyph(font, penX, y, background, maxErrors)
    result.add(ch)
    penX += font.glyphAdvance(ch)
  if stripResult:
    result = result.strip()

proc readRun*(
  image: Image,
  font: PixelFont,
  x,
  y,
  count: int,
  maxErrors = 0,
  stripResult = true
): string {.raises: [].} =
  ## Reads a fixed number of glyphs using the font background.
  image.readRun(
    font,
    x,
    y,
    count,
    font.background,
    maxErrors,
    stripResult
  )

proc readRun*(
  frame: openArray[uint8],
  font: PixelFont,
  x,
  y,
  count: int,
  background: uint8,
  maxErrors = 0,
  stripResult = true
): string {.raises: [].} =
  ## Reads a fixed number of variable-width glyphs from a framebuffer.
  var penX = x
  for i in 0 ..< count:
    let ch = frame.bestGlyph(font, penX, y, background, maxErrors)
    result.add(ch)
    penX += font.glyphAdvance(ch)
  if stripResult:
    result = result.strip()

proc readRun*(
  frame: openArray[uint8],
  font: PixelFont,
  x,
  y,
  count: int,
  maxErrors = 0,
  stripResult = true
): string {.raises: [].} =
  ## Reads a fixed number of glyphs from a black framebuffer.
  frame.readRun(font, x, y, count, 0'u8, maxErrors, stripResult)

proc drawGlyph*(
  image: Image,
  font: PixelFont,
  ch: char,
  x,
  y: int,
  color = rgba(255, 255, 255, 255)
) {.raises: [].} =
  ## Draws one glyph onto a Pixie image.
  if image == nil:
    return
  let glyph = font.glyphAt(ch)
  for gy in 0 ..< glyph.height:
    let py = y + gy
    if py < 0 or py >= image.height:
      continue
    for gx in 0 ..< glyph.width:
      let px = x + gx
      if px < 0 or px >= image.width:
        continue
      if glyph.glyphPixel(gx, gy):
        image[px, py] = color

proc drawText*(
  image: Image,
  font: PixelFont,
  text: string,
  x,
  y: int,
  color = rgba(255, 255, 255, 255)
) {.raises: [].} =
  ## Draws one or more explicit text lines onto a Pixie image.
  var
    penX = x
    penY = y
  for ch in text:
    if ch == '\n':
      penX = x
      penY += font.height + font.spacing
      continue
    image.drawGlyph(font, ch, penX, penY, color)
    penX += font.glyphAdvance(ch)

proc drawTextBox*(
  image: Image,
  font: PixelFont,
  text: string,
  x,
  y,
  width,
  height: int,
  color = rgba(255, 255, 255, 255),
  lineGap = 1
): PixelTextBox {.raises: [].} =
  ## Draws text into a clipped box with simple character wrapping.
  if image == nil or width <= 0 or height <= 0:
    return
  var
    penX = x
    penY = y
  for ch in text:
    if ch == '\n':
      penX = x
      penY += font.height + lineGap
      inc result.lines
      if penY + font.height > y + height:
        result.clipped = true
        return
      continue

    let advance = font.glyphAdvance(ch)
    if penX > x and penX + advance > x + width:
      penX = x
      penY += font.height + lineGap
      inc result.lines
    if penY + font.height > y + height:
      result.clipped = true
      return
    if ch != ' ' or penX != x:
      image.drawGlyph(font, ch, penX, penY, color)
      penX += advance
  if penX != x:
    inc result.lines

proc drawGlyph*(
  fb: var Framebuffer,
  font: PixelFont,
  ch: char,
  x,
  y: int,
  color: uint8
) {.raises: [].} =
  ## Draws one glyph onto a framebuffer.
  let glyph = font.glyphAt(ch)
  for gy in 0 ..< glyph.height:
    for gx in 0 ..< glyph.width:
      if glyph.glyphPixel(gx, gy):
        fb.putPixel(x + gx, y + gy, color)

proc drawText*(
  fb: var Framebuffer,
  font: PixelFont,
  text: string,
  x,
  y: int,
  color: uint8
) {.raises: [].} =
  ## Draws one or more explicit text lines onto a framebuffer.
  var
    penX = x
    penY = y
  for ch in text:
    if ch == '\n':
      penX = x
      penY += font.height + font.spacing
      continue
    fb.drawGlyph(font, ch, penX, penY, color)
    penX += font.glyphAdvance(ch)

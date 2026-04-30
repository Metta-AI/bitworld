import
  std/[os, strutils],
  pixie,
  bitworld/aseprite,
  server

const
  FirstPrintableAscii* = 32
  LastPrintableAscii* = 126
  PrintableAsciiCount* = LastPrintableAscii - FirstPrintableAscii + 1
  DefaultGlyphSpacing* = 1

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

proc isSameColor(a, b: ColorRGBA): bool {.raises: [].} =
  ## Returns true when two RGBA pixels are exactly equal.
  a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a

proc glyphIndex*(font: PixelFont, ch: char): int {.raises: [].} =
  ## Returns the glyph index for a printable ASCII character.
  result = ord(ch) - FirstPrintableAscii
  if result < 0 or result >= font.glyphs.len:
    result = ord('?') - FirstPrintableAscii
  if result < 0 or result >= font.glyphs.len:
    result = -1

proc glyphAt(font: PixelFont, ch: char): PixelGlyph {.raises: [].} =
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
        glyph.pixels[gy * width + gx] =
          pixel.a > 20'u8 and
          not pixel.isSameColor(result.background) and
          not pixel.isMarker()
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

proc glyphAdvance(font: PixelFont, ch: char): int {.raises: [].} =
  ## Returns the horizontal advance for one character.
  let glyph = font.glyphAt(ch)
  if glyph.width <= 0:
    return 0
  glyph.width + font.spacing

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

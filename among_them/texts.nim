import
  std/strutils,
  ../common/pixelfonts,
  ../common/protocol

const
  TextBackground = 0'u8

type
  AsciiGlyphScore* = PixelGlyphScore
  AsciiTextMatch* = PixelTextMatch

proc asciiChar*(index: int): char =
  ## Returns the character represented by one printable ASCII index.
  char(index + FirstPrintableAscii)

proc asciiTextWidth*(font: PixelFont, text: string): int =
  ## Returns the variable-width tiny font text width.
  font.textWidth(text)

proc asciiGlyphScore*(
  frame: openArray[uint8],
  font: PixelFont,
  ch: char,
  screenX,
  screenY: int
): AsciiGlyphScore =
  ## Scores one rendered tiny glyph against a black-backed frame.
  frame.glyphScore(font, ch, screenX, screenY, TextBackground)

proc asciiTextScore*(
  frame: openArray[uint8],
  font: PixelFont,
  text: string,
  screenX,
  screenY: int
): AsciiGlyphScore =
  ## Scores one rendered tiny text run against a black-backed frame.
  frame.textScore(font, text, screenX, screenY, TextBackground)

proc asciiTextMatches*(
  frame: openArray[uint8],
  font: PixelFont,
  text: string,
  x,
  y: int,
  maxErrors = 0
): bool =
  ## Returns true when tiny text is visible at the given screen position.
  frame.textMatches(font, text, x, y, TextBackground, maxErrors)

proc findAsciiText*(
  frame: openArray[uint8],
  font: PixelFont,
  text: string,
  maxErrors = 0
): AsciiTextMatch =
  ## Finds a rendered tiny phrase anywhere on the screen.
  frame.findText(font, text, TextBackground, maxErrors)

proc readAsciiRun*(
  frame: openArray[uint8],
  font: PixelFont,
  x,
  y,
  count: int,
  maxErrors = 0
): string =
  ## Reads a fixed number of variable-width tiny glyphs.
  frame.readRun(font, x, y, count, TextBackground, maxErrors)

proc rowHasText(
  frame: openArray[uint8],
  x,
  y: int
): bool =
  ## Returns true when one screen pixel is white text ink.
  if x < 0 or y < 0 or x >= ScreenWidth or y >= ScreenHeight:
    return false
  frame[y * ScreenWidth + x].isWhiteTextIndex()

proc readAsciiLine*(
  frame: openArray[uint8],
  font: PixelFont,
  y: int
): string =
  ## Reads a loose tiny text line from one black-screen text row.
  var firstX = -1
  for x in 0 ..< ScreenWidth:
    if frame.rowHasText(x, y):
      firstX = x
      break
  if firstX < 0:
    return ""
  result = frame.readAsciiRun(font, firstX, y, 32)
  result = result.strip()

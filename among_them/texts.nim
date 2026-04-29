import
  std/strutils,
  ../common/protocol,
  ../common/server,
  sim

const
  GlyphWidth = 7
  GlyphHeight = 9

type
  AsciiGlyphScore* = object
    misses*: int
    extras*: int
    opaque*: int
    foreground*: int

  AsciiTextMatch* = object
    found*: bool
    x*: int
    y*: int

proc asciiChar*(index: int): char =
  ## Returns the character represented by one ASCII sprite index.
  char(index + ord(' '))

proc asciiTextWidth*(text: string): int =
  ## Returns the fixed-width ASCII text width.
  text.len * GlyphWidth

proc screenColor(
  frame: openArray[uint8],
  x,
  y: int
): uint8 =
  ## Returns one screen color or black outside the framebuffer.
  if x < 0 or y < 0 or x >= ScreenWidth or y >= ScreenHeight:
    SpaceColor
  elif y * ScreenWidth + x >= frame.len:
    SpaceColor
  else:
    frame[y * ScreenWidth + x]

proc asciiGlyphScore*(
  frame: openArray[uint8],
  glyph: Sprite,
  screenX,
  screenY: int
): AsciiGlyphScore =
  ## Scores one rendered ASCII glyph against a black-backed frame.
  for y in 0 ..< glyph.height:
    for x in 0 ..< glyph.width:
      let
        color = glyph.pixels[glyph.spriteIndex(x, y)]
        sx = screenX + x
        sy = screenY + y
        frameColor = frame.screenColor(sx, sy)
      if frameColor != SpaceColor:
        inc result.foreground
      if color == TransparentColorIndex:
        if frameColor != SpaceColor:
          inc result.extras
        continue
      inc result.opaque
      if sx < 0 or sx >= ScreenWidth or sy < 0 or sy >= ScreenHeight:
        inc result.misses
      elif frameColor != color:
        inc result.misses

proc glyphError(score: AsciiGlyphScore): int =
  ## Returns the combined error for one glyph score.
  score.misses + score.extras

proc blankAsciiCell*(
  frame: openArray[uint8],
  screenX,
  screenY: int
): bool =
  ## Returns true when one seven by nine text cell is blank.
  for y in 0 ..< GlyphHeight:
    for x in 0 ..< GlyphWidth:
      if frame.screenColor(screenX + x, screenY + y) != SpaceColor:
        return false
  true

proc bestAsciiGlyph*(
  frame: openArray[uint8],
  asciiSprites: openArray[Sprite],
  x,
  y: int
): char =
  ## Reads the best single ASCII glyph at a fixed character cell.
  if frame.blankAsciiCell(x, y):
    return ' '
  var
    bestChar = ' '
    bestErrors = high(int)
    bestMisses = high(int)
    bestOpaque = 0
  for i, glyph in asciiSprites:
    let score = frame.asciiGlyphScore(glyph, x, y)
    if score.opaque == 0:
      continue
    let errors = score.glyphError()
    if errors < bestErrors or
        (errors == bestErrors and score.misses < bestMisses):
      bestErrors = errors
      bestMisses = score.misses
      bestOpaque = score.opaque
      bestChar = asciiChar(i)
  if bestOpaque == 0:
    return ' '
  if bestErrors <= max(2, bestOpaque div 6):
    return bestChar
  '?'

proc asciiTextScore*(
  frame: openArray[uint8],
  asciiSprites: openArray[Sprite],
  text: string,
  screenX,
  screenY: int
): AsciiGlyphScore =
  ## Scores one rendered ASCII text run against a black-backed frame.
  var offsetX = 0
  for ch in text:
    let idx = sim.asciiIndex(ch)
    if idx >= 0 and idx < asciiSprites.len:
      let score = frame.asciiGlyphScore(
        asciiSprites[idx],
        screenX + offsetX,
        screenY
      )
      result.misses += score.misses
      result.extras += score.extras
      result.opaque += score.opaque
      result.foreground += score.foreground
    offsetX += GlyphWidth

proc asciiTextMatches*(
  frame: openArray[uint8],
  asciiSprites: openArray[Sprite],
  text: string,
  x,
  y: int
): bool =
  ## Returns true when text is visible at the given screen position.
  let score = frame.asciiTextScore(asciiSprites, text, x, y)
  if score.opaque == 0:
    return false
  score.glyphError() <= max(2, score.opaque div 8)

proc findAsciiText*(
  frame: openArray[uint8],
  asciiSprites: openArray[Sprite],
  text: string
): AsciiTextMatch =
  ## Finds a rendered ASCII phrase anywhere on the screen.
  let maxX = ScreenWidth - text.asciiTextWidth()
  if maxX < 0:
    return
  for y in 0 .. ScreenHeight - GlyphHeight:
    for x in 0 .. maxX:
      if frame.asciiTextMatches(asciiSprites, text, x, y):
        return AsciiTextMatch(found: true, x: x, y: y)

proc readAsciiRun*(
  frame: openArray[uint8],
  asciiSprites: openArray[Sprite],
  x,
  y,
  count: int
): string =
  ## Reads a fixed-width ASCII run from the current screen.
  for i in 0 ..< count:
    result.add(frame.bestAsciiGlyph(asciiSprites, x + i * GlyphWidth, y))
  result = result.strip()

proc readAsciiLine*(
  frame: openArray[uint8],
  asciiSprites: openArray[Sprite],
  y: int
): string =
  ## Reads a loose ASCII line from one black-screen text row.
  for x in countup(0, ScreenWidth - GlyphWidth, GlyphWidth):
    result.add(frame.bestAsciiGlyph(asciiSprites, x, y))
  result = result.strip()

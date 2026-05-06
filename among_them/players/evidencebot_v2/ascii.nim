proc asciiChar(index: int): char =
  ## Returns the character represented by one ASCII sprite index.
  char(index + ord(' '))

proc asciiGlyphScore(
  bot: Bot,
  glyph: Sprite,
  screenX,
  screenY: int
): tuple[misses: int, opaque: int] =
  ## Scores one rendered ASCII glyph against the current screen.
  for y in 0 ..< glyph.height:
    for x in 0 ..< glyph.width:
      let color = glyph.pixels[glyph.spriteIndex(x, y)]
      if color == TransparentColorIndex:
        continue
      inc result.opaque
      let
        sx = screenX + x
        sy = screenY + y
      if sx < 0 or sx >= ScreenWidth or sy < 0 or sy >= ScreenHeight:
        inc result.misses
        continue
      if bot.unpacked[sy * ScreenWidth + sx] != color:
        inc result.misses

proc asciiTextScore(
  bot: Bot,
  text: string,
  screenX,
  screenY: int
): tuple[misses: int, opaque: int] =
  ## Scores one rendered ASCII text run against the current screen.
  var offsetX = 0
  for ch in text:
    let idx = sim.asciiIndex(ch)
    if idx >= 0 and idx < bot.sim.asciiSprites.len:
      let score = bot.asciiGlyphScore(
        bot.sim.asciiSprites[idx],
        screenX + offsetX,
        screenY
      )
      result.misses += score.misses
      result.opaque += score.opaque
    offsetX += 7

proc asciiTextWidth(text: string): int =
  ## Returns the fixed-width ASCII text width.
  text.len * 7

proc asciiTextMatches(bot: Bot, text: string, x, y: int): bool =
  ## Returns true when text is visible at the given screen position.
  let score = bot.asciiTextScore(text, x, y)
  if score.opaque == 0:
    return false
  score.misses <= max(2, score.opaque div 16)

proc findAsciiText(bot: Bot, text: string): bool =
  ## Finds a rendered ASCII phrase in the top black-screen title area.
  let maxX = ScreenWidth - asciiTextWidth(text)
  if maxX < 0:
    return false
  for y in 0 .. 20:
    for x in 0 .. maxX:
      if bot.asciiTextMatches(text, x, y):
        return true

proc bestAsciiGlyph(bot: Bot, x, y: int): char =
  ## Reads the best single ASCII glyph at a fixed character cell.
  var
    bestChar = ' '
    bestMisses = high(int)
    bestOpaque = 0
  for i, glyph in bot.sim.asciiSprites:
    let score = bot.asciiGlyphScore(glyph, x, y)
    if score.opaque == 0:
      continue
    if score.misses < bestMisses:
      bestMisses = score.misses
      bestOpaque = score.opaque
      bestChar = asciiChar(i)
  if bestOpaque == 0:
    return ' '
  if bestMisses <= max(2, bestOpaque div 8):
    return bestChar
  '?'

proc readAsciiLine(bot: Bot, y: int): string =
  ## Reads a loose ASCII line from one black-screen text row.
  for x in countup(0, ScreenWidth - 7, 7):
    result.add(bot.bestAsciiGlyph(x, y))
  result = result.strip()

proc detectInterstitialText(bot: Bot): string =
  ## Reads known interstitial ASCII text from a black screen.
  if bot.findAsciiText("CREW WINS"):
    return "CREW WINS"
  if bot.findAsciiText("IMPS WIN"):
    return "IMPS WIN"
  if bot.findAsciiText("IMPS"):
    return "IMPS"
  if bot.findAsciiText("CREWMATE"):
    return "CREWMATE"
  for y in 0 .. 20:
    let line = bot.readAsciiLine(y)
    if line.len > 0 and line != "??????????????????":
      return line
  ""

proc isGameOverText(text: string): bool =
  ## Returns true when interstitial text means the round has ended.
  text == "CREW WINS" or text == "IMPS WIN"

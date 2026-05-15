import std/os
import protocol, server, pixelfonts

const
  TextMargin* = 4
  WhiteColor* = 2'u8

var font*: PixelFont

proc loadFont*() =
  let path = currentSourcePath().parentDir() / "tiny5.aseprite"
  font = readPixelFont(path)

proc textW*(text: string): int =
  font.textWidth(text)

proc spaceWidth*(): int =
  font.glyphAdvance(' ')

proc fillRect*(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  for py in y ..< y + h:
    for px in x ..< x + w:
      fb.putPixel(px, py, color)

proc wrapLineCount*(text: string, maxWidth: int): int =
  if maxWidth <= 0 or text.len == 0:
    return 1
  result = 0
  var pos = 0
  while pos < text.len:
    if result > 0:
      while pos < text.len and text[pos] == ' ':
        inc pos
      if pos >= text.len:
        break
    var lineWidth = 0
    var lineEnd = pos
    while lineEnd < text.len:
      var wordEnd = lineEnd
      while wordEnd < text.len and text[wordEnd] == ' ':
        inc wordEnd
      while wordEnd < text.len and text[wordEnd] != ' ':
        inc wordEnd
      var wordWidth = 0
      for i in lineEnd ..< wordEnd:
        wordWidth += font.glyphAdvance(text[i])
      if lineWidth == 0:
        lineEnd = wordEnd
        lineWidth = wordWidth
      elif lineWidth + wordWidth > maxWidth:
        break
      else:
        lineEnd = wordEnd
        lineWidth += wordWidth
    pos = lineEnd
    inc result
  if result == 0:
    result = 1

proc fitChars*(text: string, maxWidth: int): int =
  var width = 0
  var lastBreak = 0
  for i, ch in text:
    let advance = font.glyphAdvance(ch)
    if width + advance > maxWidth:
      if lastBreak > 0:
        return lastBreak
      return max(i, 1)
    width += advance
    if ch == ' ':
      lastBreak = i + 1
  text.len

proc drawText*(fb: var Framebuffer, text: string, x, y: int, color: uint8 = WhiteColor) =
  fb.drawText(font, text, x, y, color)

proc drawTextWrapped*(fb: var Framebuffer, text: string, x, y: int,
    lineHeight: int, color: uint8 = WhiteColor): int =
  let maxWidth = ScreenWidth - x
  if maxWidth <= 0:
    return 0
  var row = 0
  var pos = 0
  while pos < text.len:
    if row > 0:
      while pos < text.len and text[pos] == ' ':
        inc pos
      if pos >= text.len:
        break
    var lineWidth = 0
    var lineEnd = pos
    while lineEnd < text.len:
      var wordEnd = lineEnd
      while wordEnd < text.len and text[wordEnd] == ' ':
        inc wordEnd
      while wordEnd < text.len and text[wordEnd] != ' ':
        inc wordEnd
      var wordWidth = 0
      for i in lineEnd ..< wordEnd:
        wordWidth += font.glyphAdvance(text[i])
      if lineWidth == 0:
        lineEnd = wordEnd
        lineWidth = wordWidth
      elif lineWidth + wordWidth > maxWidth:
        break
      else:
        lineEnd = wordEnd
        lineWidth += wordWidth
    let line = text[pos ..< lineEnd]
    fb.drawText(font, line, x, y + row * lineHeight, color)
    pos = lineEnd
    inc row
    if y + row * lineHeight + font.height > ScreenHeight:
      break
  row

proc released*(current, prev: InputState): InputState =
  result.up = not current.up and prev.up
  result.down = not current.down and prev.down
  result.left = not current.left and prev.left
  result.right = not current.right and prev.right
  result.attack = not current.attack and prev.attack
  result.b = not current.b and prev.b
  result.select = not current.select and prev.select

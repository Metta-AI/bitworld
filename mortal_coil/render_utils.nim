import protocol, server, data

const
  CharWidth* = 6
  CharHeight* = 6
  TextMargin* = 4

proc charsFromX*(x: int): int =
  (ScreenWidth - x) div CharWidth

proc fillRect*(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  for py in y ..< y + h:
    for px in x ..< x + w:
      fb.putPixel(px, py, color)

proc blitTextWrappedTinted*(fb: var Framebuffer, letterSprites: seq[Sprite],
    digitSprites: array[10, Sprite], text: string, x, y: int, lineHeight: int, tint: uint8): int =
  let maxChars = charsFromX(x)
  var row = 0
  var pos = 0
  while pos < text.len:
    let remaining = text.len - pos
    let lineLen = min(remaining, maxChars)
    let line = text[pos ..< pos + lineLen]
    fb.blitTextTinted(letterSprites, digitSprites, line, x, y + row * lineHeight, tint)
    pos += lineLen
    inc row
    if y + row * lineHeight + CharHeight > ScreenHeight:
      break
  row

proc blitTextWrapped*(fb: var Framebuffer, letterSprites: seq[Sprite],
    digitSprites: array[10, Sprite], text: string, x, y: int, lineHeight: int): int =
  let maxChars = charsFromX(x)
  var row = 0
  var pos = 0
  while pos < text.len:
    let remaining = text.len - pos
    let lineLen = min(remaining, maxChars)
    let line = text[pos ..< pos + lineLen]
    fb.blitText(letterSprites, digitSprites, line, x, y + row * lineHeight)
    pos += lineLen
    inc row
    if y + row * lineHeight + CharHeight > ScreenHeight:
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

proc chatLogStrings*(chatLog: seq[ChatEntry]): seq[string] =
  for entry in chatLog:
    result.add(entry.name & ": " & entry.text)

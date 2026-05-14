import protocol, server, soul, data, output

const
  WorldTitleTicks* = 24 * 3
  WorldDescTicks* = 24 * 10
  CharWidth = 6
  CharHeight = 6
  TextMargin = 4

proc charsFromX(x: int): int =
  (ScreenWidth - x) div CharWidth

proc blitTextWrappedTinted(fb: var Framebuffer, letterSprites: seq[Sprite],
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

proc renderWorld*(fb: var Framebuffer, letterSprites: seq[Sprite],
    digitSprites: array[10, Sprite], world: World, worldStep: WorldStep) =
  fb.clearFrame(0)
  case worldStep
  of WorldGazing:
    let line1 = "the world"
    let x1 = (ScreenWidth - line1.len * CharWidth) div 2
    let y1 = (ScreenHeight - CharHeight) div 2
    fb.blitTextTinted(letterSprites, line1, x1, y1, 2)
  of WorldTitle:
    let line1 = "the world"
    let line2 = world.title
    let x1 = (ScreenWidth - line1.len * CharWidth) div 2
    let x2 = (ScreenWidth - line2.len * CharWidth) div 2
    let y1 = (ScreenHeight - CharHeight * 2 - 2) div 2
    let y2 = y1 + CharHeight + 2
    fb.blitTextTinted(letterSprites, line1, x1, y1, 2)
    fb.blitTextTinted(letterSprites, digitSprites, line2, x2, y2, 2)
  of WorldDescription:
    let maxChars = charsFromX(TextMargin)
    let lineCount = max(1, (world.description.len + maxChars - 1) div maxChars)
    let totalH = lineCount * 8
    let startY = max(TextMargin, (ScreenHeight - totalH) div 2)
    discard fb.blitTextWrappedTinted(letterSprites, digitSprites, world.description, TextMargin, startY, 8, 2)

type
  WorldStepResult* = enum
    WorldContinue
    WorldDone

proc stepWorld*(worldStep: var WorldStep, worldTimer: var int, world: var World,
    players: seq[Player]): WorldStepResult =
  dec worldTimer
  if worldStep == WorldGazing and worldTimer <= 0:
    world = players[0].soul.generateWorld()
    worldStep = WorldTitle
    worldTimer = WorldTitleTicks
  elif worldStep == WorldTitle and worldTimer <= 0:
    worldStep = WorldDescription
    worldTimer = WorldDescTicks
    logWorld(world.title, world.description)
  elif worldStep == WorldDescription and worldTimer <= 0:
    return WorldDone
  WorldContinue

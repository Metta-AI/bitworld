import protocol, server, soul, data, output, render_utils

const
  WorldTitleTicks* = 24 * 3
  WorldDescTicks* = 24 * 10

proc renderWorld*(fb: var Framebuffer, world: World, worldStep: WorldStep) =
  fb.clearFrame(0)
  case worldStep
  of WorldGazing:
    let line1 = "The World"
    let x1 = (ScreenWidth - textW(line1)) div 2
    let y1 = (ScreenHeight - font.height) div 2
    fb.drawText(line1, x1, y1, 2)
  of WorldTitle:
    let line1 = "The World"
    let line2 = world.title
    let x1 = (ScreenWidth - textW(line1)) div 2
    let x2 = (ScreenWidth - textW(line2)) div 2
    let y1 = (ScreenHeight - font.height * 2 - 2) div 2
    let y2 = y1 + font.height + 2
    fb.drawText(line1, x1, y1, 2)
    fb.drawText(line2, x2, y2, 2)
  of WorldDescription:
    let maxWidth = ScreenWidth - TextMargin * 2
    let lineCount = wrapLineCount(world.description, maxWidth)
    let totalH = lineCount * 8
    let startY = max(TextMargin, (ScreenHeight - totalH) div 2)
    discard fb.drawTextWrapped(world.description, TextMargin, startY, 8, 2)

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

import paddy, pixie, silky, windy
import server
import std/[math, monotimes, os, times]

const
  AtlasPath = "dist/atlas.png"
  ShellPath = "data/atlas/shell.png"

  ShellWidth* = 293
  ShellHeight* = 453

  ScreenX = 45
  ScreenY = 42
  ScreenW = 200
  ScreenH = 200

  DpadBaseX = 28
  DpadBaseY = 290
  AButtonBaseX = 210
  AButtonBaseY = 298
  BButtonBaseX = 171
  BButtonBaseY = 321
  PauseBaseX = 103
  PauseBaseY = 386
  SelectBaseX = 148
  SelectBaseY = 386

type
  ShellVisualState = object
    dpadOffsetX: float32
    dpadOffsetY: float32
    aPressed: bool
    bPressed: bool
    selectPressed: bool

  ClientApp* = ref object
    window*: Window
    silky*: Silky
    unpacked*: seq[uint8]
    shell*: ShellVisualState

proc pointInRect(x, y, rx, ry, rw, rh: int): bool =
  x >= rx and y >= ry and x < rx + rw and y < ry + rh

proc detectShellSize(): IVec2 =
  if fileExists(ShellPath):
    try:
      let image = readImage(ShellPath)
      return ivec2(image.width.int32, image.height.int32)
    except PixieError:
      discard
  ivec2(ShellWidth, ShellHeight)

proc unpack4bpp*(packed: openArray[uint8], unpacked: var seq[uint8]) =
  let targetLen = packed.len * 2
  if unpacked.len != targetLen:
    unpacked.setLen(targetLen)

  for i, byte in packed:
    unpacked[i * 2] = byte and 0x0F
    unpacked[i * 2 + 1] = (byte shr 4) and 0x0F

proc initClient*(): ClientApp =
  if not dirExists("dist"):
    createDir("dist")
  let builder = newAtlasBuilder(1024, 2)
  builder.addDir("data/atlas/", "data/atlas/")
  builder.addDir("data/", "data/")
  if fileExists("data/atlas/nes-pixel.ttf"):
    builder.addFont("data/atlas/nes-pixel.ttf", "Default", 16.0)
  builder.write(AtlasPath)

  let shellSize = detectShellSize()

  result = ClientApp()
  result.window = newWindow(
    title = "Bit World",
    size = shellSize,
    visible = true
  )
  makeContextCurrent(result.window)
  when not defined(useDirectX):
    loadExtensions()
  initGamepads()
  result.silky = newSilky(result.window, AtlasPath)
  result.unpacked = @[]

proc sampleColor(index: uint8): ColorRGBX =
  let swatch = Palette[index.int]
  rgbx(swatch.r, swatch.g, swatch.b, swatch.a)

proc captureInput*(client: ClientApp): InputState =
  let down = client.window.buttonDown
  let pressed = client.window.buttonPressed
  let mouse = client.window.mousePos
  let mouseDown = down[MouseLeft]
  let mousePressed = pressed[MouseLeft]
  result.up = down[KeyUp] or down[KeyW]
  result.down = down[KeyDown] or down[KeyS]
  result.left = down[KeyLeft] or down[KeyA]
  result.right = down[KeyRight] or down[KeyD]
  result.select = down[KeySpace] or down[KeyEnter] or down[KeyX] or down[KeyK]
  result.attack = pressed[KeyZ] or pressed[KeyJ]
  client.shell = ShellVisualState()

  if mouseDown:
    if pointInRect(mouse.x.int, mouse.y.int, DpadBaseX, DpadBaseY, 78, 78):
      let
        localX = mouse.x.int - DpadBaseX
        localY = mouse.y.int - DpadBaseY
        dx = localX - 39
        dy = localY - 39
      if abs(dx) > abs(dy):
        if dx < -6:
          result.left = true
        elif dx > 6:
          result.right = true
      else:
        if dy < -6:
          result.up = true
        elif dy > 6:
          result.down = true

    if pointInRect(mouse.x.int, mouse.y.int, SelectBaseX, SelectBaseY, 39, 20):
      result.select = true
    if pointInRect(mouse.x.int, mouse.y.int, BButtonBaseX, BButtonBaseY, 41, 40):
      result.select = true

  if mousePressed and pointInRect(mouse.x.int, mouse.y.int, AButtonBaseX, AButtonBaseY, 41, 40):
    result.attack = true

  if result.left: client.shell.dpadOffsetX = -1
  if result.right: client.shell.dpadOffsetX = 1
  if result.up: client.shell.dpadOffsetY = -1
  if result.down: client.shell.dpadOffsetY = 1
  client.shell.aPressed = down[KeyZ] or down[KeyJ] or (mouseDown and pointInRect(mouse.x.int, mouse.y.int, AButtonBaseX, AButtonBaseY, 41, 40))
  client.shell.bPressed = down[KeyX] or down[KeyK] or (mouseDown and pointInRect(mouse.x.int, mouse.y.int, BButtonBaseX, BButtonBaseY, 41, 40))
  client.shell.selectPressed = result.select

  let gamepads = pollGamepads()
  if gamepads.len > 0:
    let pad = gamepads[0]
    let
      lx = pad.axis(GamepadLStickX)
      ly = pad.axis(GamepadLStickY)
      deadZone = 0.35'f
    result.left = result.left or pad.button(GamepadLeft) or lx <= -deadZone
    result.right = result.right or pad.button(GamepadRight) or lx >= deadZone
    result.up = result.up or pad.button(GamepadUp) or ly >= deadZone
    result.down = result.down or pad.button(GamepadDown) or ly <= -deadZone
    result.attack = result.attack or pad.buttonPressed(GamepadA)
    result.select = result.select or pad.button(GamepadB) or pad.button(GamepadStart) or pad.button(GamepadSelect)
    if pad.button(GamepadLeft) or lx <= -deadZone: client.shell.dpadOffsetX = -1
    if pad.button(GamepadRight) or lx >= deadZone: client.shell.dpadOffsetX = 1
    if pad.button(GamepadUp) or ly >= deadZone: client.shell.dpadOffsetY = -1
    if pad.button(GamepadDown) or ly <= -deadZone: client.shell.dpadOffsetY = 1
    client.shell.aPressed = client.shell.aPressed or pad.button(GamepadA)
    client.shell.bPressed = client.shell.bPressed or pad.button(GamepadB)
    client.shell.selectPressed = client.shell.selectPressed or pad.button(GamepadSelect)

proc drawShellUi(client: ClientApp) =
  client.silky.drawImage("shell", vec2(0, 0))
  client.silky.drawImage(
    "dpad",
    vec2(DpadBaseX.float32 + client.shell.dpadOffsetX, DpadBaseY.float32 + client.shell.dpadOffsetY)
  )
  client.silky.drawImage(
    "abutton",
    vec2(AButtonBaseX.float32, AButtonBaseY.float32 + (if client.shell.aPressed: 1'f else: 0'f))
  )
  client.silky.drawImage(
    "bbutton",
    vec2(BButtonBaseX.float32, BButtonBaseY.float32 + (if client.shell.bPressed: 1'f else: 0'f))
  )
  client.silky.drawImage("button", vec2(PauseBaseX.float32, PauseBaseY.float32))
  client.silky.drawImage(
    "button",
    vec2(SelectBaseX.float32, SelectBaseY.float32 + (if client.shell.selectPressed: 1'f else: 0'f))
  )

proc drawFramebuffer*(client: ClientApp, packed: openArray[uint8]) =
  unpack4bpp(packed, client.unpacked)

  let
    frameSize = client.window.size
    pixelScale = min(ScreenW div ScreenWidth, ScreenH div ScreenHeight)
    viewportWidth = ScreenWidth * pixelScale
    viewportHeight = ScreenHeight * pixelScale
    originX = ScreenX + (ScreenW - viewportWidth) div 2
    originY = ScreenY + (ScreenH - viewportHeight) div 2

  client.silky.beginUi(client.window, frameSize)
  client.silky.clearScreen(rgbx(0, 0, 0, 0))
  client.drawShellUi()
  client.silky.drawRect(
    vec2(ScreenX.float32, ScreenY.float32),
    vec2(ScreenW.float32, ScreenH.float32),
    rgbx(41, 42, 44, 255)
  )

  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      let index = client.unpacked[y * ScreenWidth + x]
      if index == 0:
        continue
      let px = originX + x * pixelScale
      let py = originY + y * pixelScale
      client.silky.drawRect(
        vec2(px.float32, py.float32),
        vec2(pixelScale.float32, pixelScale.float32),
        sampleColor(index)
      )

  client.silky.endUi()
  client.window.swapBuffers()

proc windowOpen*(client: ClientApp): bool =
  not client.window.closeRequested

proc runFrameLimiter*(targetFps: float, previousTick: var MonoTime) =
  let frameDuration = initDuration(milliseconds = int(round(1000.0 / targetFps)))
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

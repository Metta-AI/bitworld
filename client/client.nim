import paddy, pixie, protocol, silky, whisky, windy
import std/[math, monotimes, options, os, parseopt, strutils, times, locks]

const
  AtlasPath = "dist/atlas.png"
  ShellPath = "data/atlas/shell.png"
  WebSocketPath = "/ws"

  ShellWidth* = 293
  ShellHeight* = 478

  ScreenX = 45
  ScreenY = 67
  ScreenW = 200
  ScreenH = 200

  TopButtonY = 17
  TopButtonXs = [52, 102, 152, 202]

  DpadBaseX = 28
  DpadBaseY = 315
  AButtonBaseX = 210
  AButtonBaseY = 323
  BButtonBaseX = 171
  BButtonBaseY = 346
  PauseBaseX = 103
  PauseBaseY = 411
  SelectBaseX = 148
  SelectBaseY = 411
  TargetFps = 24.0

type
  ShellVisualState = object
    dpadOffsetX: float32
    dpadOffsetY: float32
    aPressed: bool
    bPressed: bool
    selectPressed: bool
    topPressed: array[4, bool]

  NetworkShared = object
    lock: Lock
    desiredMask: uint8
    latestFrame: seq[uint8]
    connected: bool
    stop: bool
    errorMessage: string

  NetworkThreadArgs = object
    shared: ptr NetworkShared
    url: string

  ClientApp* = ref object
    window*: Window
    silky*: Silky
    unpacked*: seq[uint8]
    shell*: ShellVisualState
    selectedGamepadIndex: int
    network: NetworkShared
    networkThread: Thread[NetworkThreadArgs]

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

proc sampleColor(index: uint8): ColorRGBX =
  let swatch = Palette[index.int]
  rgbx(swatch.r, swatch.g, swatch.b, swatch.a)

proc networkThreadProc(args: NetworkThreadArgs) {.thread.} =
  while true:
    {.gcsafe.}:
      withLock args.shared[].lock:
        if args.shared[].stop:
          return

    try:
      let ws = newWebSocket(args.url)
      var lastSentMask = 0xFF'u8
      {.gcsafe.}:
        withLock args.shared[].lock:
          args.shared[].connected = true
          args.shared[].errorMessage = ""

      while true:
        var
          desiredMask: uint8
          shouldStop: bool
        {.gcsafe.}:
          withLock args.shared[].lock:
            desiredMask = args.shared[].desiredMask
            shouldStop = args.shared[].stop
        if shouldStop:
          ws.close()
          return

        if desiredMask != lastSentMask:
          ws.send(blobFromMask(desiredMask), BinaryMessage)
          lastSentMask = desiredMask

        let message = ws.receiveMessage(10)
        if message.isSome:
          case message.get.kind
          of BinaryMessage:
            if message.get.data.len == ProtocolBytes:
              {.gcsafe.}:
                withLock args.shared[].lock:
                  blobToBytes(message.get.data, args.shared[].latestFrame)
          of Ping:
            ws.send(message.get.data, Pong)
          of TextMessage, Pong:
            discard
    except Exception as e:
      {.gcsafe.}:
        withLock args.shared[].lock:
          args.shared[].connected = false
          args.shared[].errorMessage = e.msg
          if args.shared[].stop:
            return
      sleep(250)

proc initClient*(host = DefaultHost, port = DefaultPort): ClientApp =
  if not dirExists("dist"):
    createDir("dist")
  let builder = newAtlasBuilder(1024, 2)
  builder.addDir("data/atlas/", "data/atlas/")
  builder.addDir("data/", "data/")
  if fileExists("data/atlas/nes-pixel.ttf"):
    builder.addFont("data/atlas/nes-pixel.ttf", "Default", 16.0)
  builder.write(AtlasPath)

  loadPalette("data/pallete.png")

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
  if result.window.contentScale > 1.0:
    result.silky.uiScale = 2.0
    result.window.size = shellSize * 2
  result.unpacked = @[]
  result.selectedGamepadIndex = 0

  initLock(result.network.lock)
  result.network.latestFrame = newSeq[uint8](ProtocolBytes)
  let url = "ws://" & host & ":" & $port & WebSocketPath
  createThread(result.networkThread, networkThreadProc, NetworkThreadArgs(shared: result.network.addr, url: url))

proc shutdownClient(client: ClientApp) =
  {.gcsafe.}:
    withLock client.network.lock:
      client.network.stop = true
  joinThread(client.networkThread)
  deinitLock(client.network.lock)

proc captureInputMask*(client: ClientApp): uint8 =
  let down = client.window.buttonDown
  let pressed = client.window.buttonPressed
  let mouse = client.silky.mousePos
  let mouseDown = down[MouseLeft]
  let mousePressed = pressed[MouseLeft]
  var input: InputState
  client.shell = ShellVisualState()

  input.up = down[KeyUp] or down[KeyW]
  input.down = down[KeyDown] or down[KeyS]
  input.left = down[KeyLeft] or down[KeyA]
  input.right = down[KeyRight] or down[KeyD]
  input.select = down[KeySpace] or down[KeyEnter] or down[KeyX] or down[KeyK]
  input.attack = down[KeyZ] or down[KeyJ]

  if mouseDown:
    for i, buttonX in TopButtonXs:
      if pointInRect(mouse.x.int, mouse.y.int, buttonX, TopButtonY, 39, 20):
        client.shell.topPressed[i] = true
        if mousePressed:
          client.selectedGamepadIndex = i

    if pointInRect(mouse.x.int, mouse.y.int, DpadBaseX, DpadBaseY, 78, 78):
      let
        localX = mouse.x.int - DpadBaseX
        localY = mouse.y.int - DpadBaseY
        dx = localX - 39
        dy = localY - 39
      if abs(dx) > abs(dy):
        if dx < -6:
          input.left = true
        elif dx > 6:
          input.right = true
      else:
        if dy < -6:
          input.up = true
        elif dy > 6:
          input.down = true

    if pointInRect(mouse.x.int, mouse.y.int, AButtonBaseX, AButtonBaseY, 41, 40):
      input.attack = true
    if pointInRect(mouse.x.int, mouse.y.int, BButtonBaseX, BButtonBaseY, 41, 40):
      input.select = true
    if pointInRect(mouse.x.int, mouse.y.int, SelectBaseX, SelectBaseY, 39, 20):
      input.select = true

  let
    bMouseHeld = mouseDown and pointInRect(mouse.x.int, mouse.y.int, BButtonBaseX, BButtonBaseY, 41, 40)
    selectMouseHeld = mouseDown and pointInRect(mouse.x.int, mouse.y.int, SelectBaseX, SelectBaseY, 39, 20)

  let gamepads = pollGamepads()
  if client.selectedGamepadIndex >= 0 and client.selectedGamepadIndex < gamepads.len:
    let pad = gamepads[client.selectedGamepadIndex]
    let
      lx = pad.axis(GamepadLStickX)
      ly = pad.axis(GamepadLStickY)
      deadZone = 0.35'f
    input.left = input.left or pad.button(GamepadLeft) or lx <= -deadZone
    input.right = input.right or pad.button(GamepadRight) or lx >= deadZone
    input.up = input.up or pad.button(GamepadUp) or ly >= deadZone
    input.down = input.down or pad.button(GamepadDown) or ly <= -deadZone
    input.attack = input.attack or pad.button(GamepadA)
    input.select = input.select or pad.button(GamepadB) or pad.button(GamepadStart)

  if input.left:
    client.shell.dpadOffsetX = -1
  if input.right:
    client.shell.dpadOffsetX = 1
  if input.up:
    client.shell.dpadOffsetY = -1
  if input.down:
    client.shell.dpadOffsetY = 1

  client.shell.aPressed = input.attack
  client.shell.bPressed = bMouseHeld or down[KeyX] or down[KeyK] or (client.selectedGamepadIndex >= 0 and client.selectedGamepadIndex < gamepads.len and gamepads[client.selectedGamepadIndex].button(GamepadB))
  client.shell.selectPressed = selectMouseHeld or down[KeySpace] or down[KeyEnter] or (client.selectedGamepadIndex >= 0 and client.selectedGamepadIndex < gamepads.len and gamepads[client.selectedGamepadIndex].button(GamepadStart))
  for i in 0 ..< client.shell.topPressed.len:
    client.shell.topPressed[i] = client.shell.topPressed[i] or i == client.selectedGamepadIndex
  result = encodeInputMask(input)

proc drawShellUi(client: ClientApp) =
  client.silky.drawImage("shell", vec2(0, 0))
  for i, buttonX in TopButtonXs:
    client.silky.drawImage(
      "button",
      vec2(buttonX.float32, TopButtonY.float32 + (if client.shell.topPressed[i]: 1'f else: 0'f))
    )
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

proc tickNetwork(client: ClientApp, inputMask: uint8) =
  {.gcsafe.}:
    withLock client.network.lock:
      client.network.desiredMask = inputMask

proc drawFramebuffer*(client: ClientApp) =
  var packed = newSeq[uint8](ProtocolBytes)
  {.gcsafe.}:
    withLock client.network.lock:
      if client.network.latestFrame.len == ProtocolBytes:
        packed = client.network.latestFrame
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

proc runFrameLimiter(previousTick: var MonoTime) =
  let frameDuration = initDuration(milliseconds = int(round(1000.0 / TargetFps)))
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runClientLoop*(host = DefaultHost, port = DefaultPort) =
  var
    client = initClient(host, port)
    lastTick = getMonoTime()

  while client.windowOpen:
    pollEvents()
    if client.window.buttonPressed[KeyEscape]:
      client.window.closeRequested = true

    let inputMask = client.captureInputMask()
    client.tickNetwork(inputMask)
    client.drawFramebuffer()
    runFrameLimiter(lastTick)

  client.shutdownClient()

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = val
      of "port": port = parseInt(val)
      else: discard
    else: discard
  runClientLoop(address, port)

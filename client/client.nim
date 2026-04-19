import paddy, pixie, protocol, server, silky, whisky, windy
import std/[math, monotimes, options, os, parseopt, strutils, times, locks]

const
  AtlasPath = "dist/atlas.png"
  LogoPath = "data/logo.png"
  ShellPath = "data/atlas/shell.png"
  WebSocketPath = "/ws"
  MinimumSplashMilliseconds = 1500'i64
  LayoutScale = 2
  PressOffset = LayoutScale.float32

  TopButtonW = 39 * LayoutScale
  TopButtonH = 20 * LayoutScale
  DpadSize = 78 * LayoutScale
  DpadCenter = DpadSize div 2
  DpadDeadZone = 6 * LayoutScale
  FaceButtonW = 41 * LayoutScale
  FaceButtonH = 40 * LayoutScale
  StartSelectButtonW = 39 * LayoutScale
  StartSelectButtonH = 20 * LayoutScale

  ShellWidth* = 293 * LayoutScale
  ShellHeight* = 478 * LayoutScale

  ScreenX = 45 * LayoutScale
  ScreenY = 67 * LayoutScale
  ScreenW = 200 * LayoutScale
  ScreenH = 200 * LayoutScale

  TopButtonY = 17 * LayoutScale
  TopButtonXs = [
    52 * LayoutScale,
    102 * LayoutScale,
    152 * LayoutScale,
    202 * LayoutScale
  ]

  DpadBaseX = 28 * LayoutScale
  DpadBaseY = 315 * LayoutScale
  AButtonBaseX = 210 * LayoutScale
  AButtonBaseY = 323 * LayoutScale
  BButtonBaseX = 171 * LayoutScale
  BButtonBaseY = 346 * LayoutScale
  PauseBaseX = 103 * LayoutScale
  PauseBaseY = 411 * LayoutScale
  SelectBaseX = 148 * LayoutScale
  SelectBaseY = 411 * LayoutScale
  TargetFps = 24.0
  ChatKeyboardChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ .?!"
  ChatKeyboardCols = 6

type
  ShellVisualState = object
    dpadOffsetX: float32
    dpadOffsetY: float32
    aPressed: bool
    bPressed: bool
    startPressed: bool
    selectPressed: bool
    topPressed: array[4, bool]

  TextAssistPhase = enum
    TextAssistOff
    TextAssistAwaitOpenFrame
    TextAssistOpening
    TextAssistReady
    TextAssistAwaitCloseFrame
    TextAssistClosing

  TextAssistState = object
    phase: TextAssistPhase
    pendingText: string
    pendingDeletes: int
    actionMasks: seq[uint8]
    lastSeenFrameSerial: uint64
    currentMask: uint8
    currentKeyIndex: int
    knownMessage: string
    editingMessage: string
    knownMessageValid: bool

  NetworkShared = object
    lock: Lock
    desiredMask: uint8
    latestFrame: seq[uint8]
    frameSerial: uint64
    connected: bool
    hasFrame: bool
    stop: bool
    reconnectRequested: bool
    errorMessage: string

  NetworkThreadArgs = object
    shared: ptr NetworkShared
    url: string

  ClientApp* = ref object
    window*: Window
    silky*: Silky
    unpacked*: seq[uint8]
    splashPixels: seq[uint8]
    shell*: ShellVisualState
    splashStartedAt: MonoTime
    selectedGamepadIndex: int
    network: NetworkShared
    networkThread: Thread[NetworkThreadArgs]
    textAssist: TextAssistState

proc pointInRect(x, y, rx, ry, rw, rh: int): bool =
  x >= rx and y >= ry and x < rx + rw and y < ry + rh

proc textAssistActive(client: ClientApp): bool =
  client.textAssist.phase != TextAssistOff

proc normalizeTextAssistRune(rune: Rune): char =
  let text = $rune
  if text.len != 1:
    return '\0'

  var ch = text[0]
  if ch >= 'a' and ch <= 'z':
    ch = ch.toUpperAscii()

  case ch
  of 'A' .. 'Z', ' ', '.', '?', '!':
    ch
  else:
    '\0'

proc chatKeyboardIndex(ch: char): int =
  for i in 0 ..< ChatKeyboardChars.len:
    if ChatKeyboardChars[i] == ch:
      return i
  0

proc currentKeyIndexForMessage(message: string): int =
  if message.len == 0:
    return chatKeyboardIndex('A')
  chatKeyboardIndex(message[^1])

proc enqueueTextAssistPress(client: ClientApp, mask: uint8) =
  client.textAssist.actionMasks.add(mask)
  client.textAssist.actionMasks.add(0)

proc enqueueTextAssistChar(client: ClientApp, ch: char) =
  let targetIndex = chatKeyboardIndex(ch)
  var
    currentCol = client.textAssist.currentKeyIndex mod ChatKeyboardCols
    currentRow = client.textAssist.currentKeyIndex div ChatKeyboardCols
    targetCol = targetIndex mod ChatKeyboardCols
    targetRow = targetIndex div ChatKeyboardCols

  while currentRow > targetRow:
    client.enqueueTextAssistPress(ButtonUp)
    dec currentRow
  while currentRow < targetRow:
    client.enqueueTextAssistPress(ButtonDown)
    inc currentRow
  while currentCol > targetCol:
    client.enqueueTextAssistPress(ButtonLeft)
    dec currentCol
  while currentCol < targetCol:
    client.enqueueTextAssistPress(ButtonRight)
    inc currentCol

  client.enqueueTextAssistPress(ButtonA)

proc queueTextAssistRune(client: ClientApp, rune: Rune) =
  if not client.textAssistActive():
    return
  let ch = normalizeTextAssistRune(rune)
  if ch == '\0':
    return
  client.textAssist.pendingText.add(ch)

proc requestTextAssistDelete(client: ClientApp) =
  if not client.textAssistActive():
    return
  if client.textAssist.pendingText.len > 0:
    client.textAssist.pendingText.setLen(client.textAssist.pendingText.len - 1)
  elif client.textAssist.phase in {TextAssistAwaitOpenFrame, TextAssistOpening, TextAssistReady}:
    inc client.textAssist.pendingDeletes

proc toggleTextAssist(client: ClientApp, currentFrameSerial: uint64) =
  case client.textAssist.phase
  of TextAssistOff:
    client.textAssist.phase = TextAssistAwaitOpenFrame
    client.textAssist.pendingText.setLen(0)
    client.textAssist.pendingDeletes = 0
    client.textAssist.actionMasks.setLen(0)
    client.textAssist.currentMask = 0
    client.textAssist.editingMessage.setLen(0)
    client.textAssist.knownMessage.setLen(0)
    client.textAssist.knownMessageValid = false
    client.textAssist.currentKeyIndex = chatKeyboardIndex('A')
    client.textAssist.lastSeenFrameSerial = currentFrameSerial
  of TextAssistAwaitOpenFrame:
    client.textAssist.phase = TextAssistOff
    client.textAssist.pendingText.setLen(0)
    client.textAssist.pendingDeletes = 0
    client.textAssist.actionMasks.setLen(0)
    client.textAssist.currentMask = 0
    client.textAssist.editingMessage.setLen(0)
    client.textAssist.currentKeyIndex = chatKeyboardIndex('A')
  of TextAssistOpening:
    client.textAssist.pendingText.setLen(0)
    client.textAssist.pendingDeletes = 0
    if client.textAssist.actionMasks.len >= 2:
      client.textAssist.phase = TextAssistOff
      client.textAssist.actionMasks.setLen(0)
      client.textAssist.currentMask = 0
      client.textAssist.editingMessage.setLen(0)
      client.textAssist.currentKeyIndex = chatKeyboardIndex('A')
    else:
      client.textAssist.phase = TextAssistAwaitCloseFrame
      client.textAssist.actionMasks.setLen(0)
      client.textAssist.currentMask = 0
      client.textAssist.lastSeenFrameSerial = currentFrameSerial
  of TextAssistReady:
    client.textAssist.phase = TextAssistAwaitCloseFrame
    client.textAssist.pendingText.setLen(0)
    client.textAssist.pendingDeletes = 0
    client.textAssist.actionMasks.setLen(0)
    client.textAssist.currentMask = 0
    client.textAssist.lastSeenFrameSerial = currentFrameSerial
  of TextAssistAwaitCloseFrame, TextAssistClosing:
    discard

proc applyTextAssistMaskEffect(client: ClientApp, mask: uint8) =
  case mask
  of ButtonUp:
    client.textAssist.currentKeyIndex =
      max(0, client.textAssist.currentKeyIndex - ChatKeyboardCols)
  of ButtonDown:
    client.textAssist.currentKeyIndex =
      min(ChatKeyboardChars.high, client.textAssist.currentKeyIndex + ChatKeyboardCols)
  of ButtonLeft:
    if client.textAssist.currentKeyIndex mod ChatKeyboardCols > 0:
      dec client.textAssist.currentKeyIndex
  of ButtonRight:
    if client.textAssist.currentKeyIndex mod ChatKeyboardCols < ChatKeyboardCols - 1 and
        client.textAssist.currentKeyIndex < ChatKeyboardChars.high:
      inc client.textAssist.currentKeyIndex
  of ButtonA:
    if client.textAssist.editingMessage.len < 16:
      client.textAssist.editingMessage.add(ChatKeyboardChars[client.textAssist.currentKeyIndex])
  of ButtonB:
    if client.textAssist.editingMessage.len > 0:
      client.textAssist.editingMessage.setLen(client.textAssist.editingMessage.len - 1)
  of ButtonSelect:
    if client.textAssist.phase == TextAssistClosing:
      client.textAssist.knownMessage = client.textAssist.editingMessage.strip(chars = {' '})
      client.textAssist.knownMessageValid = true
      client.textAssist.currentKeyIndex = chatKeyboardIndex('A')
  else:
    discard

proc popTextAssistMask(client: ClientApp): uint8 =
  if client.textAssist.actionMasks.len == 0:
    return 0
  result = client.textAssist.actionMasks[0]
  client.textAssist.actionMasks.delete(0)
  client.applyTextAssistMaskEffect(result)

proc popPendingTextChar(client: ClientApp): char =
  result = client.textAssist.pendingText[0]
  client.textAssist.pendingText.delete(0 .. 0)

proc advanceTextAssist(client: ClientApp, currentFrameSerial: uint64): uint8 =
  if not client.textAssistActive():
    return 0

  if currentFrameSerial == 0 or currentFrameSerial == client.textAssist.lastSeenFrameSerial:
    return client.textAssist.currentMask

  client.textAssist.lastSeenFrameSerial = currentFrameSerial

  while client.textAssist.actionMasks.len == 0:
    case client.textAssist.phase
    of TextAssistOff:
      client.textAssist.currentMask = 0
      return 0
    of TextAssistAwaitOpenFrame:
      client.textAssist.editingMessage = ""
      client.textAssist.currentKeyIndex = chatKeyboardIndex('A')
      client.enqueueTextAssistPress(ButtonSelect)
      client.textAssist.phase = TextAssistOpening
    of TextAssistOpening:
      client.textAssist.phase = TextAssistReady
    of TextAssistReady:
      if client.textAssist.pendingDeletes > 0:
        dec client.textAssist.pendingDeletes
        client.enqueueTextAssistPress(ButtonB)
      elif client.textAssist.pendingText.len > 0:
        let ch = client.popPendingTextChar()
        client.enqueueTextAssistChar(ch)
      else:
        client.textAssist.currentMask = 0
        return 0
    of TextAssistAwaitCloseFrame:
      client.enqueueTextAssistPress(ButtonSelect)
      client.textAssist.phase = TextAssistClosing
    of TextAssistClosing:
      client.textAssist.phase = TextAssistOff
      client.textAssist.currentMask = 0
      return 0

  client.textAssist.currentMask = client.popTextAssistMask()
  client.textAssist.currentMask

proc detectShellSize(): IVec2 =
  if fileExists(ShellPath):
    try:
      let image = readImage(ShellPath)
      return ivec2(image.width.int32, image.height.int32)
    except PixieError:
      discard
  ivec2(ShellWidth, ShellHeight)

proc loadSplashPixels(): seq[uint8] =
  result = newSeq[uint8](ScreenWidth * ScreenHeight)
  if not fileExists(LogoPath):
    return

  try:
    let sprite = spriteFromImage(readImage(LogoPath))
    if sprite.width == ScreenWidth and sprite.height == ScreenHeight:
      result = sprite.pixels
    else:
      echo "[Warning] Splash asset must be 64x64: " & LogoPath
  except CatchableError as e:
    echo "[Warning] Failed to load splash asset: " & e.msg

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
          args.shared[].hasFrame = false
          args.shared[].errorMessage = ""

      while true:
        var
          desiredMask: uint8
          shouldStop: bool
          shouldReconnect: bool
        {.gcsafe.}:
          withLock args.shared[].lock:
            desiredMask = args.shared[].desiredMask
            shouldStop = args.shared[].stop
            shouldReconnect = args.shared[].reconnectRequested
            if shouldReconnect:
              args.shared[].reconnectRequested = false
        if shouldStop:
          ws.close()
          return
        if shouldReconnect:
          {.gcsafe.}:
            withLock args.shared[].lock:
              args.shared[].connected = false
              args.shared[].hasFrame = false
          ws.close()
          break

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
                  args.shared[].hasFrame = true
                  inc args.shared[].frameSerial
          of Ping:
            ws.send(message.get.data, Pong)
          of TextMessage, Pong:
            discard
    except Exception as e:
      {.gcsafe.}:
        withLock args.shared[].lock:
          args.shared[].connected = false
          args.shared[].hasFrame = false
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
    style = Decorated,
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
  result.splashPixels = loadSplashPixels()
  result.splashStartedAt = getMonoTime()
  result.selectedGamepadIndex = 0
  result.window.runeInputEnabled = true
  let clientRef = result
  result.window.onRune = proc(rune: Rune) =
    clientRef.queueTextAssistRune(rune)

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
  var currentFrameSerial: uint64
  {.gcsafe.}:
    withLock client.network.lock:
      currentFrameSerial = client.network.frameSerial
  var input: InputState
  client.shell = ShellVisualState()

  if pressed[KeyEnter]:
    client.toggleTextAssist(currentFrameSerial)
  if pressed[KeyBackspace]:
    client.requestTextAssistDelete()

  let textAssistMode = client.textAssistActive()
  let keyboardStartPressed = pressed[KeyTab] or (pressed[KeyP] and not textAssistMode)
  var reconnectPressed = keyboardStartPressed

  input.up = down[KeyUp] or down[KeyW]
  input.down = down[KeyDown] or down[KeyS]
  input.left = down[KeyLeft] or down[KeyA]
  input.right = down[KeyRight] or down[KeyD]
  input.select = down[KeySpace]
  input.b = down[KeyX] or down[KeyK]
  input.attack = down[KeyZ] or down[KeyJ]

  if mouseDown:
    for i, buttonX in TopButtonXs:
      if pointInRect(mouse.x.int, mouse.y.int, buttonX, TopButtonY, TopButtonW, TopButtonH):
        client.shell.topPressed[i] = true
        if mousePressed:
          client.selectedGamepadIndex = i

    if pointInRect(mouse.x.int, mouse.y.int, DpadBaseX, DpadBaseY, DpadSize, DpadSize):
      let
        localX = mouse.x.int - DpadBaseX
        localY = mouse.y.int - DpadBaseY
        dx = localX - DpadCenter
        dy = localY - DpadCenter
      if abs(dx) > abs(dy):
        if dx < -DpadDeadZone:
          input.left = true
        elif dx > DpadDeadZone:
          input.right = true
      else:
        if dy < -DpadDeadZone:
          input.up = true
        elif dy > DpadDeadZone:
          input.down = true

    if pointInRect(mouse.x.int, mouse.y.int, AButtonBaseX, AButtonBaseY, FaceButtonW, FaceButtonH):
      input.attack = true
    if pointInRect(mouse.x.int, mouse.y.int, BButtonBaseX, BButtonBaseY, FaceButtonW, FaceButtonH):
      input.b = true
    if pointInRect(
      mouse.x.int,
      mouse.y.int,
      PauseBaseX,
      PauseBaseY,
      StartSelectButtonW,
      StartSelectButtonH
    ) and mousePressed:
      reconnectPressed = true
    if pointInRect(
      mouse.x.int,
      mouse.y.int,
      SelectBaseX,
      SelectBaseY,
      StartSelectButtonW,
      StartSelectButtonH
    ):
      input.select = true

  let startMouseHeld =
    mouseDown and pointInRect(
      mouse.x.int,
      mouse.y.int,
      PauseBaseX,
      PauseBaseY,
      StartSelectButtonW,
      StartSelectButtonH
    )

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
    input.b = input.b or pad.button(GamepadB)
    input.attack = input.attack or pad.button(GamepadA)
    input.select = input.select or pad.button(GamepadStart)
    reconnectPressed = reconnectPressed or pad.buttonPressed(GamepadSelect)

  if input.left:
    client.shell.dpadOffsetX = -PressOffset
  if input.right:
    client.shell.dpadOffsetX = PressOffset
  if input.up:
    client.shell.dpadOffsetY = -PressOffset
  if input.down:
    client.shell.dpadOffsetY = PressOffset

  if client.textAssistActive():
    input = decodeInputMask(client.advanceTextAssist(currentFrameSerial))
    client.shell = ShellVisualState()
    for i in 0 ..< client.shell.topPressed.len:
      client.shell.topPressed[i] = i == client.selectedGamepadIndex
    if input.left:
      client.shell.dpadOffsetX = -PressOffset
    if input.right:
      client.shell.dpadOffsetX = PressOffset
    if input.up:
      client.shell.dpadOffsetY = -PressOffset
    if input.down:
      client.shell.dpadOffsetY = PressOffset

  client.shell.aPressed = input.attack
  client.shell.bPressed = input.b
  client.shell.startPressed =
    startMouseHeld or
    down[KeyTab] or
    (down[KeyP] and not textAssistMode) or
    (
      client.selectedGamepadIndex >= 0 and
      client.selectedGamepadIndex < gamepads.len and
      gamepads[client.selectedGamepadIndex].button(GamepadStart)
    )
  client.shell.selectPressed = input.select
  for i in 0 ..< client.shell.topPressed.len:
    client.shell.topPressed[i] = client.shell.topPressed[i] or i == client.selectedGamepadIndex
  if reconnectPressed:
    client.splashStartedAt = getMonoTime()
    {.gcsafe.}:
      withLock client.network.lock:
        client.network.hasFrame = false
        client.network.reconnectRequested = true
  result = encodeInputMask(input)

proc drawShellUi(client: ClientApp) =
  client.silky.drawImage("shell", vec2(0, 0))
  for i, buttonX in TopButtonXs:
    client.silky.drawImage(
      "button",
      vec2(buttonX.float32, TopButtonY.float32 + (if client.shell.topPressed[i]: PressOffset else: 0'f))
    )
  client.silky.drawImage(
    "dpad",
    vec2(DpadBaseX.float32 + client.shell.dpadOffsetX, DpadBaseY.float32 + client.shell.dpadOffsetY)
  )
  client.silky.drawImage(
    "abutton",
    vec2(AButtonBaseX.float32, AButtonBaseY.float32 + (if client.shell.aPressed: PressOffset else: 0'f))
  )
  client.silky.drawImage(
    "bbutton",
    vec2(BButtonBaseX.float32, BButtonBaseY.float32 + (if client.shell.bPressed: PressOffset else: 0'f))
  )
  client.silky.drawImage(
    "button",
    vec2(PauseBaseX.float32, PauseBaseY.float32 + (if client.shell.startPressed: PressOffset else: 0'f))
  )
  client.silky.drawImage(
    "button",
    vec2(SelectBaseX.float32, SelectBaseY.float32 + (if client.shell.selectPressed: PressOffset else: 0'f))
  )

proc tickNetwork(client: ClientApp, inputMask: uint8) =
  {.gcsafe.}:
    withLock client.network.lock:
      client.network.desiredMask = inputMask

proc shouldShowSplash(client: ClientApp, connected, hasFrame: bool): bool =
  (getMonoTime() - client.splashStartedAt).inMilliseconds < MinimumSplashMilliseconds or
    not connected or
    not hasFrame

proc drawFramebuffer*(client: ClientApp) =
  var
    packed = newSeq[uint8](ProtocolBytes)
    connected: bool
    hasFrame: bool
  {.gcsafe.}:
    withLock client.network.lock:
      connected = client.network.connected
      hasFrame = client.network.hasFrame
      if client.network.latestFrame.len == ProtocolBytes:
        packed = client.network.latestFrame
  let showSplash = client.shouldShowSplash(connected, hasFrame)
  if not showSplash:
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

  let sourcePixels =
    if showSplash: client.splashPixels
    else: client.unpacked
  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      let index = sourcePixels[y * ScreenWidth + x]
      if index == TransparentColorIndex:
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

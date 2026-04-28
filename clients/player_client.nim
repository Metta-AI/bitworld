import paddy, pixie, protocol, server, silky, windy
import std/[math, monotimes, options, os, parseopt, strutils, times]

const
  AtlasPath = "dist/atlas.png"
  AsciiPath = "data/ascii.png"
  LogoPath = "data/logo.png"
  ShellPath = "data/atlas/shell.png"
  ScreenshotDirName = "screenshots"
  ScreenshotPrefix = "screenshot"
  ScreenshotScalePower = 2
  WebSocketPath = "/player"
  MinimumSplashMilliseconds = 1500'i64
  NetworkPollPasses = 8
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
  ScreenOnlyW = ScreenWidth * 3
  ScreenOnlyH = ScreenHeight * 3

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
  ChatMaxChars = 48
  ChatGlyphW = 7
  ChatGlyphH = 9
  ChatRowStride = 9
  ChatBoxMargin = 6
  ChatPad = 4

type
  ClientOptions = object
    title: string
    windowPos: Option[IVec2]
    screenOnly: bool
    selectedGamepadIndex: int
    reconnectDelayMilliseconds: int64

  ShellVisualState = object
    dpadOffsetX: float32
    dpadOffsetY: float32
    aPressed: bool
    bPressed: bool
    startPressed: bool
    selectPressed: bool
    topPressed: array[4, bool]

  ChatState = object
    active: bool
    draft: string
    sprites: seq[Sprite]

  NetworkState = object
    ws: WebSocketHandle
    url: string
    desiredMask: uint8
    lastSentMask: uint8
    latestFrame: seq[uint8]
    frameSerial: uint64
    connected: bool
    connecting: bool
    hasFrame: bool
    lastConnectAttemptAt: MonoTime
    reconnectDelayMilliseconds: int64
    errorMessage: string

  ClientApp* = ref object
    window*: Window
    silky*: Silky
    unpacked*: seq[uint8]
    splashPixels: seq[uint8]
    screenshotRequested: bool
    screenOnly: bool
    shell*: ShellVisualState
    splashStartedAt: MonoTime
    selectedGamepadIndex: int
    network: NetworkState
    chat: ChatState

proc pointInRect(x, y, rx, ry, rw, rh: int): bool =
  x >= rx and y >= ry and x < rx + rw and y < ry + rh

proc normalizeChatRune(rune: Rune): char =
  let text = $rune
  if text.len != 1:
    return '\0'
  let ch = text[0]
  if ch >= ' ' and ch <= '~':
    return ch
  '\0'

proc asciiIndex(ch: char): int =
  ord(ch) - ord(' ')

proc loadChatSprites(path: string): seq[Sprite] =
  if not fileExists(path):
    raise newException(IOError, "Missing ASCII sprite sheet: " & path)
  let
    image = readImage(path)
    cols = image.width div ChatGlyphW
    rows = image.height div ChatRowStride
    background = nearestPaletteIndex(image[0, 0])
  result = @[]
  for row in 0 ..< rows:
    for col in 0 ..< cols:
      var sprite = Sprite(width: ChatGlyphW, height: ChatGlyphH)
      sprite.pixels = newSeq[uint8](ChatGlyphW * ChatGlyphH)
      let
        baseX = col * ChatGlyphW
        baseY = row * ChatRowStride
      for y in 0 ..< ChatGlyphH:
        for x in 0 ..< ChatGlyphW:
          let colorIndex = nearestPaletteIndex(image[baseX + x, baseY + y])
          sprite.pixels[sprite.spriteIndex(x, y)] =
            if colorIndex == background:
              TransparentColorIndex
            else:
              colorIndex
      result.add(sprite)

proc chatActive(client: ClientApp): bool =
  client.chat.active

proc openChat(client: ClientApp) =
  client.chat.active = true
  client.chat.draft.setLen(0)
  client.window.runeInputEnabled = true

proc closeChat(client: ClientApp) =
  client.chat.active = false
  client.chat.draft.setLen(0)
  client.window.runeInputEnabled = false

proc submitChat(client: ClientApp) =
  if client.chat.draft.len > 0 and client.network.connected:
    client.network.ws.send(blobFromChat(client.chat.draft), BinaryMessage)
  client.closeChat()

proc queueChatRune(client: ClientApp, rune: Rune) =
  if not client.chatActive():
    return
  if client.chat.draft.len >= ChatMaxChars:
    return
  let ch = normalizeChatRune(rune)
  if ch != '\0':
    client.chat.draft.add(ch)

proc deleteChatChar(client: ClientApp) =
  if client.chat.active and client.chat.draft.len > 0:
    client.chat.draft.setLen(client.chat.draft.len - 1)

proc detectShellSize(): IVec2 =
  if fileExists(ShellPath):
    try:
      let image = readImage(ShellPath)
      return ivec2(image.width.int32, image.height.int32)
    except PixieError:
      discard
  ivec2(ShellWidth, ShellHeight)

proc detectWindowSize(screenOnly: bool): IVec2 =
  if screenOnly:
    return ivec2(ScreenOnlyW.int32, ScreenOnlyH.int32)
  detectShellSize()

proc parseSelectedGamepad(value: string): int =
  let parsed = parseInt(value)
  if parsed <= 0:
    return 0
  parsed - 1

proc parseReconnectDelay(value: string): int64 =
  let seconds = parseFloat(value)
  if not (seconds > 0):
    return 0
  int64(round(seconds * 1000.0))

proc screenshotDir(): string =
  getAppDir() / ScreenshotDirName

proc nextScreenshotPath(): string =
  let dir = screenshotDir()
  if not dirExists(dir):
    createDir(dir)

  var highestIndex = 0
  for kind, path in walkDir(dir):
    if kind != pcFile:
      continue
    let parts = splitFile(path)
    if parts.ext.toLowerAscii() != ".png":
      continue
    if not parts.name.startsWith(ScreenshotPrefix):
      continue
    if parts.name.len <= ScreenshotPrefix.len:
      continue

    let suffix = parts.name[ScreenshotPrefix.len .. ^1]
    if not suffix.allCharsInSet({'0'..'9'}):
      continue
    try:
      highestIndex = max(highestIndex, parseInt(suffix))
    except ValueError:
      discard

  dir / (ScreenshotPrefix & align($(highestIndex + 1), 3, '0') & ".png")

proc saveScreenshot(pixels: openArray[uint8]) =
  var image = newImage(ScreenWidth, ScreenHeight)
  image.fill(rgba(0, 0, 0, 0))

  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      let index = pixels[y * ScreenWidth + x]
      if index == TransparentColorIndex:
        continue
      let swatch = Palette[index.int]
      image[x, y] = rgbx(swatch.r, swatch.g, swatch.b, swatch.a)

  let path = nextScreenshotPath()
  image.magnifyBy2(ScreenshotScalePower).writeFile(path)
  echo "Saved screenshot: " & path

proc loadSplashPixels(): seq[uint8] =
  result = newSeq[uint8](ScreenWidth * ScreenHeight)
  if not fileExists(LogoPath):
    return

  try:
    let sprite = spriteFromImage(readImage(LogoPath))
    if sprite.width == ScreenWidth and sprite.height == ScreenHeight:
      result = sprite.pixels
    else:
      echo "[Warning] Splash asset must be " & $ScreenWidth & "x" &
        $ScreenHeight & ": " & LogoPath
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

proc drawChatSprite(
  client: ClientApp,
  sprite: Sprite,
  x, y, scale: int
) =
  for sy in 0 ..< sprite.height:
    for sx in 0 ..< sprite.width:
      let index = sprite.pixels[sprite.spriteIndex(sx, sy)]
      if index == TransparentColorIndex:
        continue
      client.silky.drawRect(
        vec2((x + sx * scale).float32, (y + sy * scale).float32),
        vec2(scale.float32, scale.float32),
        sampleColor(index)
      )

proc drawChatText(
  client: ClientApp,
  text: string,
  x, y, scale: int
) =
  var dx = x
  for ch in text:
    let idx = asciiIndex(ch)
    if idx >= 0 and idx < client.chat.sprites.len:
      client.drawChatSprite(client.chat.sprites[idx], dx, y, scale)
    dx += ChatGlyphW * scale

proc drawChatInput(
  client: ClientApp,
  originX, originY, viewportWidth, viewportHeight: int
) =
  if not client.chatActive():
    return

  let
    scale = 1
    boxW = min(
      viewportWidth - ChatBoxMargin * 2,
      ChatMaxChars * ChatGlyphW * scale + ChatPad * 2
    )
    boxH = ChatGlyphH * scale + ChatPad * 2
    boxX = originX + (viewportWidth - boxW) div 2
    boxY = originY + viewportHeight - boxH - ChatBoxMargin
    textCapacity = max(0, (boxW - ChatPad * 2) div (ChatGlyphW * scale))

  var text = client.chat.draft
  if text.len > textCapacity:
    text = text[text.len - textCapacity .. ^1]

  client.silky.drawRect(
    vec2(boxX.float32, boxY.float32),
    vec2(boxW.float32, boxH.float32),
    rgbx(0, 0, 0, 180)
  )
  client.silky.drawRect(
    vec2(boxX.float32, boxY.float32),
    vec2(boxW.float32, 1),
    sampleColor(2)
  )
  client.silky.drawRect(
    vec2(boxX.float32, (boxY + boxH - 1).float32),
    vec2(boxW.float32, 1),
    sampleColor(2)
  )
  client.silky.drawRect(
    vec2(boxX.float32, boxY.float32),
    vec2(1, boxH.float32),
    sampleColor(2)
  )
  client.silky.drawRect(
    vec2((boxX + boxW - 1).float32, boxY.float32),
    vec2(1, boxH.float32),
    sampleColor(2)
  )

  let
    textX = boxX + ChatPad
    textY = boxY + ChatPad
  client.drawChatText(text, textX, textY, scale)
  let caretX = textX + text.len * ChatGlyphW * scale
  if caretX < boxX + boxW - ChatPad:
    client.silky.drawRect(
      vec2(caretX.float32, textY.float32),
      vec2(1, (ChatGlyphH * scale).float32),
      sampleColor(2)
    )

proc connectNetwork(client: ClientApp) =
  client.network.connected = false
  client.network.connecting = true
  client.network.hasFrame = false
  client.network.errorMessage = ""
  client.network.lastSentMask = 0xFF'u8
  client.network.lastConnectAttemptAt = getMonoTime()

  let ws = openWebSocket(client.network.url, noDelay = true)
  client.network.ws = ws

  ws.onOpen = proc() =
    if client.network.ws != ws:
      return
    client.network.connected = true
    client.network.connecting = false
    client.network.hasFrame = false
    client.network.errorMessage = ""
    client.network.lastSentMask = 0xFF'u8

  ws.onMessage = proc(msg: string, kind: WebSocketMessageKind) =
    if client.network.ws != ws:
      return
    if kind == BinaryMessage and msg.len == ProtocolBytes:
      blobToBytes(msg, client.network.latestFrame)
      client.network.hasFrame = true
      inc client.network.frameSerial

  ws.onError = proc(msg: string) =
    if client.network.ws != ws:
      return
    client.network.connected = false
    client.network.connecting = false
    client.network.hasFrame = false
    client.network.lastConnectAttemptAt = getMonoTime()
    client.network.errorMessage = msg

  ws.onClose = proc() =
    if client.network.ws != ws:
      return
    client.network.connected = false
    client.network.connecting = false
    client.network.hasFrame = false
    client.network.lastConnectAttemptAt = getMonoTime()

proc reconnectNetwork(client: ClientApp) =
  client.network.ws.close()
  client.connectNetwork()

proc pollNetwork() =
  ## Pumps Windy network callbacks enough to avoid stale frame buildup.
  for i in 0 ..< NetworkPollPasses:
    pollHttp()

proc initClient*(
  host = DefaultHost,
  port = DefaultPort,
  clientOptions = ClientOptions()
): ClientApp =
  if not dirExists("dist"):
    createDir("dist")
  let builder = newAtlasBuilder(1024, 2)
  builder.addDir("data/atlas/", "data/atlas/")
  builder.addDir("data/", "data/")
  if fileExists("data/atlas/nes-pixel.ttf"):
    builder.addFont("data/atlas/nes-pixel.ttf", "Default", 16.0)
  builder.write(AtlasPath)

  loadPalette("data/pallete.png")
  let chatSprites = loadChatSprites(AsciiPath)

  let windowSize = detectWindowSize(clientOptions.screenOnly)

  result = ClientApp()
  result.window = newWindow(
    title = if clientOptions.title.len > 0: clientOptions.title else: "Bit World",
    size = windowSize,
    # Decorated locks the current size on X11, so apply HiDPI sizing first.
    style = DecoratedResizable,
    visible = true
  )
  makeContextCurrent(result.window)
  when not defined(useDirectX):
    loadExtensions()
  initGamepads()
  result.silky = newSilky(result.window, AtlasPath)
  if result.window.contentScale > 1.0:
    result.silky.uiScale = 2.0
    result.window.size = windowSize * 2
  result.window.style = Decorated
  result.unpacked = @[]
  result.splashPixels = loadSplashPixels()
  result.splashStartedAt = getMonoTime()
  result.screenOnly = clientOptions.screenOnly
  result.selectedGamepadIndex = max(0, clientOptions.selectedGamepadIndex)
  result.chat.sprites = chatSprites
  result.window.runeInputEnabled = false
  let clientRef = result
  result.window.onRune = proc(rune: Rune) =
    clientRef.queueChatRune(rune)
  if clientOptions.windowPos.isSome:
    result.window.pos = clientOptions.windowPos.get

  result.network.latestFrame = newSeq[uint8](ProtocolBytes)
  result.network.url = "ws://" & host & ":" & $port & WebSocketPath
  result.network.reconnectDelayMilliseconds =
    clientOptions.reconnectDelayMilliseconds
  result.connectNetwork()

proc shutdownClient(client: ClientApp) =
  client.network.ws.close()

proc captureInputMask*(client: ClientApp): uint8 =
  let down = client.window.buttonDown
  let pressed = client.window.buttonPressed
  let mouse = client.silky.mousePos
  let mouseDown = down[MouseLeft]
  let mousePressed = pressed[MouseLeft]
  var input: InputState
  client.shell = ShellVisualState()

  if pressed[KeyEnter]:
    if client.chatActive():
      client.submitChat()
    else:
      client.openChat()
  if pressed[KeyBackspace] and client.chatActive():
    client.deleteChatChar()
  if pressed[KeyF1]:
    client.screenshotRequested = true

  let chatMode = client.chatActive()
  let keyboardStartPressed =
    not chatMode and (pressed[KeyTab] or pressed[KeyP])
  var reconnectPressed = keyboardStartPressed

  input.up = down[KeyUp] or (not chatMode and down[KeyW])
  input.down = down[KeyDown] or (not chatMode and down[KeyS])
  input.left = down[KeyLeft] or (not chatMode and down[KeyA])
  input.right = down[KeyRight] or (not chatMode and down[KeyD])
  input.select = not chatMode and down[KeySpace]
  input.b = not chatMode and (down[KeyX] or down[KeyK])
  input.attack = not chatMode and (down[KeyZ] or down[KeyJ])

  if mouseDown and not client.screenOnly:
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
    mouseDown and not client.screenOnly and pointInRect(
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
    client.screenshotRequested = client.screenshotRequested or
      pad.buttonPressed(GamepadL1) or
      pad.buttonPressed(GamepadGripL) or
      pad.buttonPressed(GamepadGripL2) or
      pad.buttonPressed(GamepadMisc4)
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

  client.shell.aPressed = input.attack
  client.shell.bPressed = input.b
  client.shell.startPressed =
    startMouseHeld or
    (down[KeyTab] and not chatMode) or
    (down[KeyP] and not chatMode) or
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
    client.reconnectNetwork()
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
  client.network.desiredMask = inputMask
  if not client.network.connected:
    if client.network.reconnectDelayMilliseconds <= 0:
      return
    let elapsed =
      (getMonoTime() - client.network.lastConnectAttemptAt).inMilliseconds
    if not client.network.connecting and
      elapsed >= client.network.reconnectDelayMilliseconds:
        client.connectNetwork()
    return
  if inputMask == client.network.lastSentMask:
    return
  client.network.ws.send(blobFromMask(inputMask), BinaryMessage)
  client.network.lastSentMask = inputMask

proc shouldShowSplash(client: ClientApp, connected, hasFrame: bool): bool =
  (getMonoTime() - client.splashStartedAt).inMilliseconds < MinimumSplashMilliseconds or
    not connected or
    not hasFrame

proc drawFramebuffer*(client: ClientApp) =
  var
    packed = newSeq[uint8](ProtocolBytes)
    connected = client.network.connected
    hasFrame = client.network.hasFrame
  if client.network.latestFrame.len == ProtocolBytes:
    packed = client.network.latestFrame
  let showSplash = client.shouldShowSplash(connected, hasFrame)
  if not showSplash:
    unpack4bpp(packed, client.unpacked)

  let
    frameSize = client.window.size
    logicalWidth = int(round(frameSize.x.float32 / client.silky.uiScale))
    logicalHeight = int(round(frameSize.y.float32 / client.silky.uiScale))
    screenRectX = if client.screenOnly: 0 else: ScreenX
    screenRectY = if client.screenOnly: 0 else: ScreenY
    screenRectW = if client.screenOnly: logicalWidth else: ScreenW
    screenRectH = if client.screenOnly: logicalHeight else: ScreenH
    pixelScale = min(screenRectW div ScreenWidth, screenRectH div ScreenHeight)
    viewportWidth = ScreenWidth * pixelScale
    viewportHeight = ScreenHeight * pixelScale
    originX = screenRectX + (screenRectW - viewportWidth) div 2
    originY = screenRectY + (screenRectH - viewportHeight) div 2

  client.silky.beginUi(client.window, frameSize)
  client.silky.clearScreen(rgbx(0, 0, 0, 0))
  if not client.screenOnly:
    client.drawShellUi()
  client.silky.drawRect(
    vec2(screenRectX.float32, screenRectY.float32),
    vec2(screenRectW.float32, screenRectH.float32),
    rgbx(41, 42, 44, 255)
  )

  let sourcePixels =
    if showSplash: client.splashPixels
    else: client.unpacked
  if client.screenshotRequested:
    client.screenshotRequested = false
    try:
      saveScreenshot(sourcePixels)
    except CatchableError as e:
      echo "[Warning] Failed to save screenshot: " & e.msg
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

  client.drawChatInput(originX, originY, viewportWidth, viewportHeight)
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

proc runClientLoop*(
  host = DefaultHost,
  port = DefaultPort,
  clientOptions = ClientOptions()
) =
  var
    client = initClient(host, port, clientOptions)
    lastTick = getMonoTime()

  while client.windowOpen:
    pollEvents()
    pollNetwork()
    if client.window.buttonPressed[KeyEscape]:
      if client.chatActive():
        client.closeChat()
      else:
        client.window.closeRequested = true

    let inputMask = client.captureInputMask()
    client.tickNetwork(inputMask)
    pollNetwork()
    client.drawFramebuffer()
    runFrameLimiter(lastTick)

  client.shutdownClient()

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    clientOptions = ClientOptions()
    windowX = none(int)
    windowY = none(int)
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = val
      of "port": port = parseInt(val)
      of "x", "window-x":
        windowX = some(parseInt(val))
      of "y", "window-y":
        windowY = some(parseInt(val))
      of "screen-only":
        clientOptions.screenOnly = true
      of "title":
        clientOptions.title = val
      of "joystick", "gamepad", "controller":
        clientOptions.selectedGamepadIndex = parseSelectedGamepad(val)
      of "reconnect":
        clientOptions.reconnectDelayMilliseconds = parseReconnectDelay(val)
      else: discard
    else: discard
  if windowX.isSome or windowY.isSome:
    clientOptions.windowPos = some(ivec2(
      if windowX.isSome: windowX.get.int32 else: 0'i32,
      if windowY.isSome: windowY.get.int32 else: 0'i32
    ))
  runClientLoop(address, port, clientOptions)

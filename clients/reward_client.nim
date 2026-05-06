import
  std/[math, monotimes, os, parseopt, strutils, times],
  chroma, pixie, protocol, silky, windy

const
  AtlasPath = "dist/atlas.png"
  TargetFps = 24.0
  NetworkPollPasses = 8
  WindowWidth = 720
  WindowHeight = 420
  Padding = 18.0'f

type
  RewardOptions = object
    title: string
    reconnectDelayMilliseconds: int64

  NetworkState = object
    ws: WebSocketHandle
    url: string
    connected: bool
    connecting: bool
    lastConnectAttemptAt: MonoTime
    reconnectDelayMilliseconds: int64
    errorMessage: string
    latestText: string

  RewardApp = ref object
    window: Window
    silky: Silky
    network: NetworkState

proc pollNetwork() =
  ## Pumps Windy network callbacks.
  for i in 0 ..< NetworkPollPasses:
    pollHttp()

proc connectNetwork(app: RewardApp) =
  ## Opens the reward websocket connection.
  app.network.connected = false
  app.network.connecting = true
  app.network.errorMessage = ""
  app.network.latestText = ""
  app.network.lastConnectAttemptAt = getMonoTime()

  let ws = openWebSocket(app.network.url, noDelay = true)
  app.network.ws = ws

  ws.onOpen = proc() =
    if app.network.ws != ws:
      return
    app.network.connected = true
    app.network.connecting = false
    app.network.errorMessage = ""

  ws.onMessage = proc(msg: string, kind: WebSocketMessageKind) =
    if app.network.ws != ws:
      return
    case kind
    of Utf8Message, BinaryMessage:
      app.network.latestText = msg

  ws.onError = proc(msg: string) =
    if app.network.ws != ws:
      return
    app.network.connected = false
    app.network.connecting = false
    app.network.lastConnectAttemptAt = getMonoTime()
    app.network.errorMessage = msg

  ws.onClose = proc() =
    if app.network.ws != ws:
      return
    app.network.connected = false
    app.network.connecting = false
    app.network.lastConnectAttemptAt = getMonoTime()

proc reconnectNetwork(app: RewardApp) =
  ## Closes the current socket and starts a new connection.
  app.network.latestText = ""
  app.network.ws.close()
  app.connectNetwork()

proc tickNetwork(app: RewardApp) =
  ## Reconnects after disconnects when configured.
  if app.network.connected or app.network.connecting:
    return
  if app.network.reconnectDelayMilliseconds <= 0:
    return
  let elapsed =
    (getMonoTime() - app.network.lastConnectAttemptAt).inMilliseconds
  if elapsed >= app.network.reconnectDelayMilliseconds:
    app.connectNetwork()

proc statusText(app: RewardApp): string =
  ## Returns the connection status text.
  if app.network.connected:
    ""
  elif app.network.connecting:
    "connecting..."
  elif app.network.reconnectDelayMilliseconds > 0:
    "reconnecting..."
  elif app.network.errorMessage.len > 0:
    "disconnected..."
  else:
    "disconnected..."

proc draw(app: RewardApp) =
  ## Draws the reward screen.
  let
    frameSize = app.window.size
    logicalWidth = int(round(frameSize.x.float32 / app.silky.uiScale))
    logicalHeight = int(round(frameSize.y.float32 / app.silky.uiScale))
    width = logicalWidth.float32
    height = logicalHeight.float32

  app.silky.beginUi(app.window, frameSize)
  app.silky.clearScreen(rgbx(0, 0, 0, 255))
  app.silky.drawRect(
    vec2(0, 0),
    vec2(width, height),
    rgbx(0, 0, 0, 255)
  )
  if app.network.latestText.len > 0:
    discard app.silky.drawText(
      "Default",
      app.network.latestText,
      vec2(Padding, Padding),
      rgbx(232, 232, 232, 255),
      width - Padding * 2,
      height - Padding * 2,
      clip = true,
      wordWrap = false
    )
  else:
    discard app.silky.drawText(
      "Default",
      app.statusText(),
      vec2(0, 0),
      rgbx(232, 232, 232, 255),
      width,
      height,
      clip = false,
      hAlign = CenterAlign,
      vAlign = MiddleAlign
    )
  app.silky.endUi()
  app.window.swapBuffers()

proc windowOpen(app: RewardApp): bool =
  ## Returns true while the reward window should stay open.
  not app.window.closeRequested

proc runFrameLimiter(previousTick: var MonoTime) =
  ## Sleeps to keep the reward client near the target frame rate.
  let frameDuration = initDuration(milliseconds = int(round(1000.0 / TargetFps)))
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc initRewardApp(
  address = DefaultRewardAddress,
  options = RewardOptions()
): RewardApp =
  ## Creates the native reward client app.
  result = RewardApp()
  result.window = newWindow(
    title = if options.title.len > 0: options.title else: "Reward Viewer",
    size = ivec2(WindowWidth, WindowHeight),
    style = DecoratedResizable,
    visible = true
  )
  makeContextCurrent(result.window)
  when not defined(useDirectX):
    loadExtensions()
  result.silky = newSilky(result.window, AtlasPath)
  if result.window.contentScale > 1.0:
    result.silky.uiScale = 2.0
    result.window.size = ivec2(WindowWidth, WindowHeight) * 2
  result.network.url = address
  result.network.reconnectDelayMilliseconds =
    options.reconnectDelayMilliseconds
  result.connectNetwork()

proc shutdown(app: RewardApp) =
  ## Closes the reward websocket.
  app.network.ws.close()

proc parseReconnectDelay(value: string): int64 =
  ## Parses reconnect seconds as milliseconds.
  if value.len == 0:
    return 0
  max(0, int64(parseFloat(value) * 1000.0))

proc runRewardClient*(
  address = DefaultRewardAddress,
  options = RewardOptions()
) =
  ## Runs the native reward client.
  var
    app = initRewardApp(address, options)
    lastTick = getMonoTime()
  while app.windowOpen:
    pollEvents()
    pollNetwork()
    if app.window.buttonPressed[KeyEscape]:
      app.window.closeRequested = true
    if app.window.buttonPressed[KeyR]:
      app.reconnectNetwork()
    app.tickNetwork()
    app.draw()
    runFrameLimiter(lastTick)
  app.shutdown()

when isMainModule:
  var
    address = DefaultRewardAddress
    options = RewardOptions()
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = val
      of "title":
        options.title = val
      of "reconnect":
        options.reconnectDelayMilliseconds = parseReconnectDelay(val)
      else:
        discard
    else:
      discard
  runRewardClient(address, options)

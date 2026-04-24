import
  std/[locks, math, monotimes, os, parseopt, strutils, tables, times],
  mummy,
  protocol

const
  TargetFps = 24.0
  WebSocketPath = "/sprite"
  MapWidth = 512
  MapHeight = 512
  UiWidth = 128
  UiHeight = 128
  MapLayerId = 0
  LayerMapZoomable = 0
  UiLayerTypes = [1, 2, 3, 4, 5, 6, 7, 8]
  ZoomableLayerFlag = 1
  UiLayerFlag = 2
  MapSpriteId = 1
  MarkerSpriteId = 2
  LabelSpriteBase = 100
  MapObjectId = 1
  MarkerObjectId = 2
  LabelObjectBase = 100

type
  SpriteViewerState = object
    initialized: bool

  WebSocketAppState = object
    lock: Lock
    viewers: Table[WebSocket, SpriteViewerState]
    closedSockets: seq[WebSocket]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

var appState: WebSocketAppState

proc addU8(packet: var seq[uint8], value: uint8) =
  ## Appends one unsigned byte to a sprite protocol packet.
  packet.add(value)

proc addU16(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 16 bit value.
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addI16(packet: var seq[uint8], value: int) =
  ## Appends one little endian signed 16 bit value.
  let v = cast[uint16](int16(value))
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addLayer(packet: var seq[uint8], layer, layerType, flags: int) =
  ## Appends one sprite protocol layer definition.
  packet.addU8(0x06)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(layerType))
  packet.addU8(uint8(flags))

proc addViewport(packet: var seq[uint8], layer, width, height: int) =
  ## Appends one sprite protocol layer viewport.
  packet.addU8(0x05)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addSprite(
  packet: var seq[uint8],
  spriteId, width, height: int,
  pixels: openArray[uint8]
) =
  ## Appends one sprite protocol sprite definition.
  packet.addU8(0x01)
  packet.addU16(spriteId)
  packet.addU16(width)
  packet.addU16(height)
  for pixel in pixels:
    packet.addU8(pixel)

proc addObject(
  packet: var seq[uint8],
  objectId, x, y, z, layer, spriteId: int
) =
  ## Appends one sprite protocol object definition.
  packet.addU8(0x02)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc spriteColor(color: uint8): uint8 =
  ## Converts a game palette index to a sprite protocol pixel.
  color + 1'u8

proc glyphRows(ch: char): array[7, string] =
  ## Returns a tiny five by seven glyph.
  case ch
  of 'A': ["01110", "10001", "10001", "11111", "10001", "10001", "10001"]
  of 'B': ["11110", "10001", "10001", "11110", "10001", "10001", "11110"]
  of 'C': ["01111", "10000", "10000", "10000", "10000", "10000", "01111"]
  of 'E': ["11111", "10000", "10000", "11110", "10000", "10000", "11111"]
  of 'F': ["11111", "10000", "10000", "11110", "10000", "10000", "10000"]
  of 'G': ["01111", "10000", "10000", "10111", "10001", "10001", "01111"]
  of 'H': ["10001", "10001", "10001", "11111", "10001", "10001", "10001"]
  of 'I': ["11111", "00100", "00100", "00100", "00100", "00100", "11111"]
  of 'L': ["10000", "10000", "10000", "10000", "10000", "10000", "11111"]
  of 'M': ["10001", "11011", "10101", "10101", "10001", "10001", "10001"]
  of 'N': ["10001", "11001", "10101", "10011", "10001", "10001", "10001"]
  of 'O': ["01110", "10001", "10001", "10001", "10001", "10001", "01110"]
  of 'P': ["11110", "10001", "10001", "11110", "10000", "10000", "10000"]
  of 'R': ["11110", "10001", "10001", "11110", "10100", "10010", "10001"]
  of 'T': ["11111", "00100", "00100", "00100", "00100", "00100", "00100"]
  else: ["00000", "00000", "00000", "00000", "00000", "00000", "00000"]

proc textSprite(text: string, color: uint8): tuple[w, h: int, pixels: seq[uint8]] =
  ## Builds a transparent text sprite.
  result.w = max(1, text.len * 6 - 1)
  result.h = 7
  result.pixels = newSeq[uint8](result.w * result.h)
  for i, ch in text:
    if ch == ' ':
      continue
    let rows = glyphRows(ch)
    for y in 0 ..< result.h:
      for x in 0 ..< 5:
        if rows[y][x] == '1':
          result.pixels[y * result.w + i * 6 + x] = spriteColor(color)

proc mapPixels(): seq[uint8] =
  ## Builds a large checker and grid map sprite.
  result = newSeq[uint8](MapWidth * MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let
        grid = x mod 32 == 0 or y mod 32 == 0
        band = (x div 64 + y div 64) mod 2 == 0
        color =
          if grid:
            15'u8
          elif band:
            12'u8
          else:
            9'u8
      result[y * MapWidth + x] = spriteColor(color)

proc markerPixels(): seq[uint8] =
  ## Builds a small animated marker sprite.
  result = newSeq[uint8](9 * 9)
  for y in 0 ..< 9:
    for x in 0 ..< 9:
      let
        dx = x - 4
        dy = y - 4
      if abs(dx) + abs(dy) <= 4:
        result[y * 9 + x] = spriteColor(8)

proc labelNames(): array[8, string] =
  ## Returns label names in UI layer order.
  [
    "TOP LEFT",
    "TOP RIGHT",
    "BOTTOM RIGHT",
    "BOTTOM LEFT",
    "CENTER TOP",
    "CENTER RIGHT",
    "CENTER LEFT",
    "CENTER BOTTOM"
  ]

proc buildInitPacket(): seq[uint8] =
  ## Builds the initial layered sprite protocol snapshot.
  result = @[]
  result.addLayer(MapLayerId, LayerMapZoomable, ZoomableLayerFlag)
  result.addViewport(MapLayerId, MapWidth, MapHeight)
  result.addSprite(MapSpriteId, MapWidth, MapHeight, mapPixels())
  result.addSprite(MarkerSpriteId, 9, 9, markerPixels())
  result.addObject(
    MapObjectId,
    0,
    0,
    low(int16),
    MapLayerId,
    MapSpriteId
  )

  let names = labelNames()
  for i in 0 ..< names.len:
    let layer = UiLayerTypes[i]
    result.addLayer(layer, UiLayerTypes[i], UiLayerFlag)
    result.addViewport(layer, UiWidth, UiHeight)
    let label = textSprite(names[i], uint8(3 + i mod 12))
    result.addSprite(LabelSpriteBase + i, label.w, label.h, label.pixels)
    result.addObject(
      LabelObjectBase + i,
      4,
      4,
      0,
      layer,
      LabelSpriteBase + i
    )

proc buildUpdatePacket(tick: int): seq[uint8] =
  ## Builds the moving map marker update.
  let
    angle = float(tick) * 0.06
    x = MapWidth div 2 + int(cos(angle) * 120.0) - 4
    y = MapHeight div 2 + int(sin(angle) * 120.0) - 4
  result = @[]
  result.addObject(MarkerObjectId, x, y, 10, MapLayerId, MarkerSpriteId)

proc initAppState() =
  ## Initializes shared WebSocket state.
  initLock(appState.lock)
  appState.viewers = initTable[WebSocket, SpriteViewerState]()
  appState.closedSockets = @[]

proc httpHandler(request: Request) =
  ## Handles HTTP requests and upgrades sprite viewers.
  if request.uri == WebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.viewers[websocket] = SpriteViewerState()
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Global UI sprite server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  ## Tracks viewer closes.
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    discard message
  of ErrorEvent, CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  ## Runs the HTTP server.
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime) =
  ## Sleeps until the next target frame.
  let frameDuration = initDuration(milliseconds = int(1000.0 / TargetFps))
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runServerLoop*(host = DefaultHost, port = DefaultPort) =
  ## Runs the global UI sprite test server.
  initAppState()
  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4,
    tcpNoDelay = true
  )
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(
    serverThread,
    serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port)
  )
  httpServer.waitUntilReady()

  var
    lastTick = getMonoTime()
    tick = 0

  while true:
    var viewers: seq[tuple[websocket: WebSocket, state: SpriteViewerState]] = @[]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          if websocket in appState.viewers:
            appState.viewers.del(websocket)
        appState.closedSockets.setLen(0)
        for websocket, state in appState.viewers.pairs:
          viewers.add((websocket, state))

    for item in viewers:
      var packet =
        if item.state.initialized:
          buildUpdatePacket(tick)
        else:
          buildInitPacket() & buildUpdatePacket(tick)
      var nextState = item.state
      nextState.initialized = true
      try:
        item.websocket.send(blobFromBytes(packet), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if item.websocket in appState.viewers:
              appState.viewers[item.websocket] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            if item.websocket in appState.viewers:
              appState.viewers.del(item.websocket)

    inc tick
    runFrameLimiter(lastTick)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = val
      of "port":
        port = parseInt(val)
      else:
        discard
    else:
      discard
  runServerLoop(address, port)

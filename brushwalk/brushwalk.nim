import mummy
import protocol, server
import std/[locks, monotimes, os, parseopt, random, strutils, tables, times]

const
  WorldWidthPixels = 256
  WorldHeightPixels = 256
  MotionScale = 256
  Accel = 38
  FrictionNum = 200
  FrictionDen = 256
  MaxSpeed = 352
  StopThreshold = 8
  TargetFps = 24.0
  WebSocketPath = "/player"
  BackgroundColor = 12'u8
  OutlineColor = 0'u8
  MaxPaint = 200
  PaintRegenRate = 1
  PaintCostMove = 1
  BrushRadius = 3
  PlayerRadius = 3
  PlayerColors = [2'u8, 3, 7, 8, 10, 11, 13, 14]

type
  Player = object
    x, y: int
    velX, velY: int
    carryX, carryY: int
    paint: int
    color: uint8
    lastPaintX, lastPaintY: int
    painting: bool

  SimServer = object
    players: seq[Player]
    canvas: seq[uint8]
    fb: Framebuffer
    rng: Rand
    tickCount: int
    digitSprites: array[10, Sprite]
    letterSprites: seq[Sprite]

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    closedSockets: seq[WebSocket]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

proc clientDataDir(): string =
  getCurrentDir() / ".." / "clients" / "data"

proc loadClientPalette() =
  loadPalette(clientDataDir() / "pallete.png")

proc loadClientDigitSprites(): array[10, Sprite] =
  loadDigitSprites(clientDataDir() / "numbers.png")

proc loadClientLetterSprites(): seq[Sprite] =
  loadLetterSprites(clientDataDir() / "letters.png")

proc canvasIndex(x, y: int): int =
  y * WorldWidthPixels + x

proc inCanvasBounds(x, y: int): bool =
  x >= 0 and y >= 0 and x < WorldWidthPixels and y < WorldHeightPixels

proc paintPixel(sim: var SimServer, x, y: int, color: uint8) =
  if inCanvasBounds(x, y):
    sim.canvas[canvasIndex(x, y)] = color

proc paintHLine(sim: var SimServer, x0, x1, y: int, color: uint8) =
  for x in x0 .. x1:
    sim.paintPixel(x, y, color)

proc paintFilledCircle(sim: var SimServer, cx, cy, radius: int, color: uint8) =
  var
    x = radius
    y = 0
    d = 1 - radius
  sim.paintHLine(cx - x, cx + x, cy, color)
  while x > y:
    inc y
    if d <= 0:
      d += 2 * y + 1
    else:
      dec x
      d += 2 * (y - x) + 1
    sim.paintHLine(cx - x, cx + x, cy + y, color)
    sim.paintHLine(cx - x, cx + x, cy - y, color)
    sim.paintHLine(cx - y, cx + y, cy + x, color)
    sim.paintHLine(cx - y, cx + y, cy - x, color)

proc paintLine(sim: var SimServer, x0, y0, x1, y1: int, radius: int, color: uint8) =
  var
    dx = abs(x1 - x0)
    dy = abs(y1 - y0)
    sx = if x0 < x1: 1 else: -1
    sy = if y0 < y1: 1 else: -1
    err = dx - dy
    cx = x0
    cy = y0
  while true:
    sim.paintFilledCircle(cx, cy, radius, color)
    if cx == x1 and cy == y1:
      break
    let e2 = 2 * err
    if e2 > -dy:
      err -= dy
      cx += sx
    if e2 < dx:
      err += dx
      cy += sy

proc countPixels(sim: SimServer, color: uint8): int =
  for c in sim.canvas:
    if c == color:
      inc result

proc findPlayerSpawn(sim: SimServer): tuple[x, y: int] =
  let
    centerX = WorldWidthPixels div 2
    centerY = WorldHeightPixels div 2
    spacing = 20
  for radius in 0 .. 20:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        if abs(dx) != radius and abs(dy) != radius:
          continue
        let
          px = centerX + dx * spacing
          py = centerY + dy * spacing
        if px < PlayerRadius or py < PlayerRadius or
           px >= WorldWidthPixels - PlayerRadius or
           py >= WorldHeightPixels - PlayerRadius:
          continue
        var tooClose = false
        for p in sim.players:
          let
            ddx = px - p.x
            ddy = py - p.y
          if ddx * ddx + ddy * ddy < spacing * spacing:
            tooClose = true
            break
        if not tooClose:
          return (px, py)
  (centerX, centerY)

proc addPlayer(sim: var SimServer): int =
  let
    spawn = sim.findPlayerSpawn()
    colorIdx = sim.players.len mod PlayerColors.len
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    paint: MaxPaint,
    color: PlayerColors[colorIdx],
    lastPaintX: spawn.x,
    lastPaintY: spawn.y,
  )
  sim.players.high

proc initSimServer(): SimServer =
  result.rng = initRand(0xBB007)
  result.canvas = newSeq[uint8](WorldWidthPixels * WorldHeightPixels)
  for i in 0 ..< result.canvas.len:
    result.canvas[i] = BackgroundColor
  result.fb = initFramebuffer()
  loadClientPalette()
  result.digitSprites = loadClientDigitSprites()
  result.letterSprites = loadClientLetterSprites()

proc clampWorld(v, radius, maxVal: int): int =
  clamp(v, radius, maxVal - radius - 1)

proc applyInput(sim: var SimServer, playerIndex: int, input: InputState) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  template player: untyped = sim.players[playerIndex]

  var inputX, inputY = 0
  if input.left: dec inputX
  if input.right: inc inputX
  if input.up: dec inputY
  if input.down: inc inputY

  if inputX != 0:
    player.velX = clamp(player.velX + inputX * Accel, -MaxSpeed, MaxSpeed)
  else:
    player.velX = (player.velX * FrictionNum) div FrictionDen
    if abs(player.velX) < StopThreshold: player.velX = 0

  if inputY != 0:
    player.velY = clamp(player.velY + inputY * Accel, -MaxSpeed, MaxSpeed)
  else:
    player.velY = (player.velY * FrictionNum) div FrictionDen
    if abs(player.velY) < StopThreshold: player.velY = 0

  let oldX = player.x
  let oldY = player.y

  player.carryX += player.velX
  while abs(player.carryX) >= MotionScale:
    let step = if player.carryX < 0: -1 else: 1
    player.x = clampWorld(player.x + step, PlayerRadius, WorldWidthPixels)
    player.carryX -= step * MotionScale

  player.carryY += player.velY
  while abs(player.carryY) >= MotionScale:
    let step = if player.carryY < 0: -1 else: 1
    player.y = clampWorld(player.y + step, PlayerRadius, WorldHeightPixels)
    player.carryY -= step * MotionScale

  let moved = player.x != oldX or player.y != oldY
  if moved and input.attack and player.paint > 0:
    sim.paintLine(player.lastPaintX, player.lastPaintY, player.x, player.y, BrushRadius, player.color)
    player.paint = max(0, player.paint - PaintCostMove)
  if moved:
    player.lastPaintX = player.x
    player.lastPaintY = player.y

  if player.paint < MaxPaint:
    player.paint = min(MaxPaint, player.paint + PaintRegenRate)

proc renderCanvas(sim: var SimServer, cameraX, cameraY: int) =
  for sy in 0 ..< ScreenHeight:
    for sx in 0 ..< ScreenWidth:
      let
        wx = cameraX + sx
        wy = cameraY + sy
      if inCanvasBounds(wx, wy):
        sim.fb.indices[sy * ScreenWidth + sx] = sim.canvas[canvasIndex(wx, wy)]

proc fbHLine(fb: var Framebuffer, x0, x1, y: int, color: uint8) =
  for x in x0 .. x1:
    fb.putPixel(x, y, color)

proc drawFilledCircle(fb: var Framebuffer, cx, cy, radius: int, color: uint8) =
  var
    x = radius
    y = 0
    d = 1 - radius
  fb.fbHLine(cx - x, cx + x, cy, color)
  while x > y:
    inc y
    if d <= 0:
      d += 2 * y + 1
    else:
      dec x
      d += 2 * (y - x) + 1
    fb.fbHLine(cx - x, cx + x, cy + y, color)
    fb.fbHLine(cx - x, cx + x, cy - y, color)
    fb.fbHLine(cx - y, cx + y, cy + x, color)
    fb.fbHLine(cx - y, cx + y, cy - x, color)

proc drawCircleOutline(fb: var Framebuffer, cx, cy, radius: int, color: uint8) =
  var
    x = radius
    y = 0
    d = 1 - radius
  fb.putPixel(cx + x, cy, color)
  fb.putPixel(cx - x, cy, color)
  fb.putPixel(cx, cy + x, color)
  fb.putPixel(cx, cy - x, color)
  while x > y:
    inc y
    if d <= 0:
      d += 2 * y + 1
    else:
      dec x
      d += 2 * (y - x) + 1
    fb.putPixel(cx + x, cy + y, color)
    fb.putPixel(cx - x, cy + y, color)
    fb.putPixel(cx + x, cy - y, color)
    fb.putPixel(cx - x, cy - y, color)
    fb.putPixel(cx + y, cy + x, color)
    fb.putPixel(cx - y, cy + x, color)
    fb.putPixel(cx + y, cy - x, color)
    fb.putPixel(cx - y, cy - x, color)

proc renderPaintBar(fb: var Framebuffer, paint: int, color: uint8) =
  let
    barY = ScreenHeight - 3
    barX = 1
    barW = ScreenWidth - 2
    filled = max(0, min(barW, (paint * barW + MaxPaint - 1) div MaxPaint))
  for px in barX ..< barX + barW:
    fb.putPixel(px, barY, 1'u8)
    fb.putPixel(px, barY + 1, 1'u8)
  for px in barX ..< barX + filled:
    fb.putPixel(px, barY, color)
    fb.putPixel(px, barY + 1, color)

proc renderNumber(
  fb: var Framebuffer,
  digitSprites: array[10, Sprite],
  value, screenX, screenY: int
) =
  let text = $max(0, value)
  var x = screenX
  for ch in text:
    let digit = ord(ch) - ord('0')
    fb.blitSprite(digitSprites[digit], x, screenY, 0, 0)
    x += digitSprites[digit].width

proc buildFramePacket(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(BackgroundColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return sim.fb.packed

  let
    player = sim.players[playerIndex]
    cameraX = clamp(
      player.x - ScreenWidth div 2,
      0, WorldWidthPixels - ScreenWidth
    )
    cameraY = clamp(
      player.y - ScreenHeight div 2,
      0, WorldHeightPixels - ScreenHeight
    )

  sim.renderCanvas(cameraX, cameraY)

  for i in 0 ..< sim.players.len:
    let
      p = sim.players[i]
      sx = p.x - cameraX
      sy = p.y - cameraY
    sim.fb.drawFilledCircle(sx, sy, PlayerRadius, p.color)
    sim.fb.drawCircleOutline(sx, sy, PlayerRadius, OutlineColor)

  let score = sim.countPixels(player.color) div 64
  sim.fb.renderNumber(sim.digitSprites, score, 1, 1)
  sim.fb.renderPaintBar(player.paint, player.color)

  sim.fb.packFramebuffer()
  sim.fb.packed

proc step(sim: var SimServer, inputs: openArray[InputState]) =
  inc sim.tickCount
  for i in 0 ..< sim.players.len:
    let input =
      if i < inputs.len: inputs[i]
      else: InputState()
    sim.applyInput(i, input)

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.closedSockets = @[]

proc inputStateFromMasks(currentMask, previousMask: uint8): InputState =
  result = decodeInputMask(currentMask)

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket notin appState.playerIndices:
    return
  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc httpHandler(request: Request) =
  if request.path == WebSocketPath and request.httpMethod == "GET":
    discard request.upgradeToWebSocket()
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Brushwalk server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerIndices[websocket] = 0x7fffffff
        appState.inputMasks[websocket] = 0
        appState.lastAppliedMasks[websocket] = 0
  of MessageEvent:
    if message.kind == BinaryMessage and isInputPacket(message.data):
      {.gcsafe.}:
        withLock appState.lock:
          appState.inputMasks[websocket] = blobToMask(message.data)
  of ErrorEvent:
    discard
  of CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime) =
  let frameDuration = initDuration(milliseconds = int(1000.0 / TargetFps))
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runServerLoop(host = DefaultHost, port = DefaultPort) =
  initAppState()
  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4,
    tcpNoDelay = true
  )
  var serverThread: Thread[ServerThreadArgs]
  var serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc, ServerThreadArgs(
    server: serverPtr, address: host, port: port
  ))
  httpServer.waitUntilReady()

  var
    sim = initSimServer()
    lastTick = getMonoTime()

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[InputState]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] == 0x7fffffff:
            appState.playerIndices[websocket] = sim.addPlayer()

        inputs = newSeq[InputState](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
          let previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = inputStateFromMasks(currentMask, previousMask)
          appState.lastAppliedMasks[websocket] = currentMask
          sockets.add(websocket)
          playerIndices.add(playerIndex)

    sim.step(inputs)

    for i in 0 ..< sockets.len:
      let frameBlob = blobFromBytes(sim.buildFramePacket(playerIndices[i]))
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    runFrameLimiter(lastTick)

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
    of cmdArgument:
      if key.startsWith("--port"):
        discard
      else:
        try:
          port = parseInt(key)
        except ValueError:
          discard
    else: discard
  runServerLoop(address, port)

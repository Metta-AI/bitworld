import mummy, pixie
import protocol, server
import std/[locks, monotimes, os, parseopt, random, strutils, tables, times]

const
  SheetTileSize = TileSize
  LevelWidthTiles = 80
  LevelHeightTiles = 11
  LevelWidthPixels = LevelWidthTiles * TileSize
  LevelHeightPixels = LevelHeightTiles * TileSize
  MotionScale = 256
  AccelX = 32
  FrictionNum = 200
  FrictionDen = 256
  MaxSpeedX = 320
  StopThreshold = 8
  Gravity = 48
  JumpVel = -750
  BoostJumpVel = -350
  MaxFallSpeed = 1000
  TargetFps = 24.0
  WebSocketPath = "/player"
  BackgroundColor = 13'u8
  SkyColor = 14'u8
  PlayerColors = [3'u8, 7, 8, 14, 4, 11]
  GroundY = (LevelHeightTiles - 1) * TileSize
  DeathY = LevelHeightPixels + 12
  RespawnX = 2 * TileSize
  RespawnY = GroundY - TileSize
  GoalTileX = LevelWidthTiles - 3
  CollisionInset = 1
  CollisionWidth = TileSize - CollisionInset * 2
  CollisionHeight = TileSize

type
  Actor = object
    x, y: int
    velX, velY: int
    carryX, carryY: int
    onGround: bool
    score: int
    dead: bool
    respawnTimer: int
    facingRight: bool
    color: uint8

  TileKind = enum
    TileAir
    TileGround
    TileWall
    TileGoal

  SimServer = object
    players: seq[Actor]
    tiles: seq[TileKind]
    rabbitSprite: Sprite
    groundSprite: Sprite
    wallSprite: Sprite
    goalSprite: Sprite
    digitSprites: array[10, Sprite]
    letterSprites: seq[Sprite]
    fb: Framebuffer
    rng: Rand
    tickCount: int
    nextColorIndex: int

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

proc dataDir(): string =
  getCurrentDir() / "data"

proc repoDir(): string =
  getCurrentDir() / ".."

proc clientDataDir(): string =
  repoDir() / "client" / "data"

proc sheetPath(): string =
  dataDir() / "spritesheet.png"

proc loadClientPalette() =
  loadPalette(clientDataDir() / "pallete.png")

proc loadClientDigitSprites(): array[10, Sprite] =
  loadDigitSprites(clientDataDir() / "numbers.png")

proc loadClientLetterSprites(): seq[Sprite] =
  loadLetterSprites(clientDataDir() / "letters.png")

proc sheetSprite(sheet: Image, cellX, cellY: int): Sprite =
  spriteFromImage(
    sheet.subImage(cellX * SheetTileSize, cellY * SheetTileSize, SheetTileSize, SheetTileSize)
  )

proc tileIndex(tx, ty: int): int =
  ty * LevelWidthTiles + tx

proc inBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < LevelWidthTiles and ty < LevelHeightTiles

proc getTile(sim: SimServer, tx, ty: int): TileKind =
  if not inBounds(tx, ty):
    return TileAir
  sim.tiles[tileIndex(tx, ty)]

proc isSolid(kind: TileKind): bool =
  kind == TileGround or kind == TileWall

proc worldClampPixel(x, maxValue: int): int =
  x.clamp(0, maxValue)

proc rectsOverlap(ax, ay, aw, ah, bx, by, bw, bh: int): bool =
  ax < bx + bw and
  ax + aw > bx and
  ay < by + bh and
  ay + ah > by

proc collidesWithTiles(sim: SimServer, x, y, w, h: int): bool =
  let
    startTx = x div TileSize
    startTy = y div TileSize
    endTx = (x + w - 1) div TileSize
    endTy = (y + h - 1) div TileSize
  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      if sim.getTile(tx, ty).isSolid:
        return true
  false

proc buildLevel(sim: var SimServer) =
  sim.tiles = newSeq[TileKind](LevelWidthTiles * LevelHeightTiles)

  # Ground floor
  for tx in 0 ..< LevelWidthTiles:
    sim.tiles[tileIndex(tx, LevelHeightTiles - 1)] = TileGround

  # Gaps in the ground (pits) - need cooperation to cross
  let gaps = [
    (12, 4),
    (22, 5),
    (35, 4),
    (48, 10),
    (60, 5),
  ]
  for gap in gaps:
    let (start, width) = gap
    for dx in 0 ..< width:
      let tx = start + dx
      if inBounds(tx, LevelHeightTiles - 1):
        sim.tiles[tileIndex(tx, LevelHeightTiles - 1)] = TileAir

  # Platforms (stepping stones above gaps and walls)
  let platforms = [
    # (x, y, width) in tiles
    (14, 7, 2),
    (24, 6, 2),
    (26, 8, 2),
    (37, 7, 2),
    (50, 5, 2),
    (52, 7, 2),
    (62, 6, 2),
    (64, 8, 2),
  ]
  for plat in platforms:
    let (px, py, pw) = plat
    for dx in 0 ..< pw:
      if inBounds(px + dx, py):
        sim.tiles[tileIndex(px + dx, py)] = TileGround

  # Walls that are too tall to jump over alone
  let walls = [
    (18, 7, 3),  # (x, topY, height)
    (32, 4, 6),
    (44, 4, 6),
    (56, 6, 4),
    (70, 7, 3),
  ]
  for wall in walls:
    let (wx, topY, height) = wall
    for dy in 0 ..< height:
      let ty = topY + dy
      if inBounds(wx, ty):
        sim.tiles[tileIndex(wx, ty)] = TileWall

  # Goal flag at the end
  sim.tiles[tileIndex(GoalTileX, LevelHeightTiles - 2)] = TileGoal

proc playerColor(playerIndex: int): uint8 =
  PlayerColors[playerIndex mod PlayerColors.len]

proc findRandomSpawn(sim: var SimServer): tuple[x, y: int] =
  for _ in 0 ..< 200:
    let tx = sim.rng.rand(min(7, LevelWidthTiles - 2))
    let ty = sim.rng.rand(LevelHeightTiles - 2)
    let px = tx * TileSize
    let py = ty * TileSize
    if sim.getTile(tx, ty).isSolid:
      continue
    if not sim.getTile(tx, ty + 1).isSolid:
      continue
    if sim.collidesWithTiles(px + CollisionInset, py, CollisionWidth, CollisionHeight):
      continue
    return (px, py)
  (RespawnX, RespawnY)

proc resolveOverlaps(sim: var SimServer) =
  for i in 0 ..< sim.players.len:
    if sim.players[i].dead:
      continue
    for j in i + 1 ..< sim.players.len:
      if sim.players[j].dead:
        continue
      if rectsOverlap(
        sim.players[i].x + CollisionInset, sim.players[i].y, CollisionWidth, CollisionHeight,
        sim.players[j].x + CollisionInset, sim.players[j].y, CollisionWidth, CollisionHeight
      ):
        if sim.players[i].y <= sim.players[j].y:
          sim.players[i].y = sim.players[j].y - CollisionHeight
        else:
          sim.players[j].y = sim.players[i].y - CollisionHeight

proc addPlayer(sim: var SimServer): int =
  let spawn = sim.findRandomSpawn()
  let color = PlayerColors[sim.nextColorIndex mod PlayerColors.len]
  inc sim.nextColorIndex
  sim.players.add Actor(
    x: spawn.x,
    y: spawn.y,
    facingRight: true,
    color: color,
  )
  result = sim.players.high
  sim.resolveOverlaps()

proc respawnPlayer(sim: var SimServer, i: int) =
  let spawn = sim.findRandomSpawn()
  sim.players[i].x = spawn.x
  sim.players[i].y = spawn.y
  sim.players[i].velX = 0
  sim.players[i].velY = 0
  sim.players[i].carryX = 0
  sim.players[i].carryY = 0
  sim.players[i].onGround = false
  sim.players[i].dead = false
  sim.players[i].respawnTimer = 0
  sim.resolveOverlaps()

proc initSimServer(): SimServer =
  result.rng = initRand(0xB1770)
  result.fb = initFramebuffer()
  loadClientPalette()
  let sheet = readImage(sheetPath())
  result.groundSprite = sheet.sheetSprite(0, 0)
  result.rabbitSprite = sheet.sheetSprite(1, 0)
  result.wallSprite = sheet.sheetSprite(2, 0)
  result.goalSprite = sheet.sheetSprite(3, 0)
  result.digitSprites = loadClientDigitSprites()
  result.letterSprites = loadClientLetterSprites()
  result.players = @[]
  result.buildLevel()

proc applyInput(sim: var SimServer, playerIndex: int, input: InputState) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  template p: untyped = sim.players[playerIndex]

  if p.dead:
    return

  var inputX = 0
  if input.left:
    inputX -= 1
  if input.right:
    inputX += 1

  if inputX != 0:
    p.velX = clamp(p.velX + inputX * AccelX, -MaxSpeedX, MaxSpeedX)
    p.facingRight = inputX > 0
  else:
    p.velX = (p.velX * FrictionNum) div FrictionDen
    if abs(p.velX) < StopThreshold:
      p.velX = 0

  if input.attack and p.onGround:
    p.velY = JumpVel
    p.onGround = false

proc collidesWithPlayer(sim: SimServer, pi: int, x, y, w, h: int): int =
  for j in 0 ..< sim.players.len:
    if j == pi or sim.players[j].dead:
      continue
    let o = sim.players[j]
    if rectsOverlap(x, y, w, h, o.x + CollisionInset, o.y, CollisionWidth, CollisionHeight):
      return j
  -1

proc collidesAny(sim: SimServer, pi: int, x, y, w, h: int): bool =
  sim.collidesWithTiles(x, y, w, h) or sim.collidesWithPlayer(pi, x, y, w, h) >= 0

const PushRate = 4

proc tryPush(sim: var SimServer, other: int, step: int): bool =
  let nx = sim.players[other].x + step
  if nx + CollisionInset < 0 or nx + CollisionInset + CollisionWidth > LevelWidthPixels:
    return false
  if sim.collidesWithTiles(nx + CollisionInset, sim.players[other].y, CollisionWidth, CollisionHeight):
    return false
  if sim.collidesWithPlayer(other, nx + CollisionInset, sim.players[other].y, CollisionWidth, CollisionHeight) >= 0:
    return false
  sim.players[other].x = nx
  true

proc moveX(sim: var SimServer, p: var Actor, pi: int) =
  p.carryX += p.velX
  while abs(p.carryX) >= MotionScale:
    let step = (if p.carryX < 0: -1 else: 1)
    let nx = p.x + step
    let cx = nx + CollisionInset
    if cx < 0 or cx + CollisionWidth > LevelWidthPixels or sim.collidesWithTiles(cx, p.y, CollisionWidth, CollisionHeight):
      p.carryX = 0
      p.velX = 0
      break
    let hitPlayer = sim.collidesWithPlayer(pi, cx, p.y, CollisionWidth, CollisionHeight)
    if hitPlayer >= 0:
      if sim.tickCount mod PushRate == 0 and sim.tryPush(hitPlayer, step):
        p.x = nx
        p.carryX -= step * MotionScale
      else:
        p.carryX = 0
      break
    p.x = nx
    p.carryX -= step * MotionScale

proc moveY(sim: SimServer, p: var Actor, pi: int) =
  p.carryY += p.velY
  while abs(p.carryY) >= MotionScale:
    let step = (if p.carryY < 0: -1 else: 1)
    let ny = p.y + step
    if sim.collidesAny(pi, p.x + CollisionInset, ny, CollisionWidth, CollisionHeight):
      p.carryY = 0
      if p.velY > 0:
        p.onGround = true
      p.velY = 0
      break
    p.y = ny
    p.carryY -= step * MotionScale

proc applyPhysics(sim: var SimServer, p: var Actor, pi: int) =
  p.velY = min(p.velY + Gravity, MaxFallSpeed)
  sim.moveX(p, pi)
  sim.moveY(p, pi)

  if p.onGround:
    if not sim.collidesAny(pi, p.x + CollisionInset, p.y + 1, CollisionWidth, CollisionHeight):
      p.onGround = false

proc checkDeath(sim: var SimServer) =
  for i in 0 ..< sim.players.len:
    if sim.players[i].dead:
      continue
    if sim.players[i].y > DeathY:
      sim.players[i].dead = true
      sim.players[i].respawnTimer = 48

proc checkGoal(sim: var SimServer) =
  let goalX = GoalTileX * TileSize
  let goalY = (LevelHeightTiles - 2) * TileSize

  for i in 0 ..< sim.players.len:
    if sim.players[i].dead:
      continue
    if rectsOverlap(sim.players[i].x + CollisionInset, sim.players[i].y, CollisionWidth, CollisionHeight, goalX, goalY, TileSize, TileSize):
      inc sim.players[i].score
      sim.respawnPlayer(i)

proc updateRespawns(sim: var SimServer) =
  for i in 0 ..< sim.players.len:
    if not sim.players[i].dead:
      continue
    dec sim.players[i].respawnTimer
    if sim.players[i].respawnTimer <= 0:
      sim.respawnPlayer(i)

proc blitSpriteColored(fb: var Framebuffer, sprite: Sprite, screenX, screenY: int, color: uint8, flipX: bool) =
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        let dx = if flipX: sprite.width - 1 - x else: x
        for oy in -1 .. 1:
          for ox in -1 .. 1:
            if ox == 0 and oy == 0:
              continue
            fb.putPixel(screenX + dx + ox, screenY + y + oy, 0'u8)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        let dx = if flipX: sprite.width - 1 - x else: x
        fb.putPixel(screenX + dx, screenY + y, color)

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
  sim.fb.clearFrame(SkyColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let player = sim.players[playerIndex]

  var cameraX: int
  if player.dead:
    cameraX = worldClampPixel(player.x + sim.rabbitSprite.width div 2 - ScreenWidth div 2, LevelWidthPixels - ScreenWidth)
  else:
    cameraX = worldClampPixel(player.x + sim.rabbitSprite.width div 2 - ScreenWidth div 2, LevelWidthPixels - ScreenWidth)
  let cameraY = LevelHeightPixels - ScreenHeight

  # Render tiles
  let
    startTx = max(0, cameraX div TileSize)
    startTy = max(0, cameraY div TileSize)
    endTx = min(LevelWidthTiles - 1, (cameraX + ScreenWidth - 1) div TileSize)
    endTy = min(LevelHeightTiles - 1, (cameraY + ScreenHeight - 1) div TileSize)
  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let tile = sim.tiles[tileIndex(tx, ty)]
      case tile
      of TileGround:
        sim.fb.blitSprite(sim.groundSprite, tx * TileSize, ty * TileSize, cameraX, cameraY)
      of TileWall:
        sim.fb.blitSprite(sim.wallSprite, tx * TileSize, ty * TileSize, cameraX, cameraY)
      of TileGoal:
        sim.fb.blitSprite(sim.goalSprite, tx * TileSize, ty * TileSize, cameraX, cameraY)
      of TileAir:
        discard

  # Render players
  for i in 0 ..< sim.players.len:
    let p = sim.players[i]
    if p.dead:
      continue
    let
      sx = p.x - cameraX
      sy = p.y - cameraY
    sim.fb.blitSpriteColored(sim.rabbitSprite, sx, sy, p.color, not p.facingRight)

  # Render radar for off-screen players
  let
    pcx = player.x + sim.rabbitSprite.width div 2
    halfW = ScreenWidth div 2

  for i in 0 ..< sim.players.len:
    if i == playerIndex or sim.players[i].dead:
      continue
    let
      other = sim.players[i]
      ocx = other.x + sim.rabbitSprite.width div 2
      sx = ocx - cameraX
    if sx >= 0 and sx < ScreenWidth:
      continue
    let edgeX = if ocx < pcx: 0 else: ScreenWidth - 1
    let osy = clamp(other.y - cameraY, 0, ScreenHeight - 1)
    sim.fb.putPixel(edgeX, osy, other.color)

  # HUD
  sim.fb.renderNumber(sim.digitSprites, player.score, 0, 0)

  if player.dead:
    sim.fb.blitText(sim.letterSprites, "OOPS!", 17, 20)

  sim.fb.packFramebuffer()
  sim.fb.packed

proc step(sim: var SimServer, inputs: openArray[InputState]) =
  inc sim.tickCount
  for i in 0 ..< sim.players.len:
    let input =
      if i < inputs.len: inputs[i]
      else: InputState()
    sim.applyInput(i, input)
  for i in 0 ..< sim.players.len:
    if not sim.players[i].dead:
      sim.applyPhysics(sim.players[i], i)
  sim.checkDeath()
  sim.checkGoal()
  sim.updateRespawns()

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.closedSockets = @[]

proc inputStateFromMasks(currentMask, previousMask: uint8): InputState =
  result = decodeInputMask(currentMask)
  result.attack = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0

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
    request.respond(200, headers, "Jumper WebSocket server")

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

proc runServerLoop*(host = DefaultHost, port = DefaultPort) =
  initAppState()
  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4,
    tcpNoDelay = true
  )
  var serverThread: Thread[ServerThreadArgs]
  var serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc, ServerThreadArgs(server: serverPtr, address: host, port: port))
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
    positional = 0
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if positional == 0:
        address = key
      elif positional == 1:
        port = parseInt(key)
      inc positional
    of cmdLongOption:
      case key
      of "address": address = val
      of "port": port = parseInt(val)
      else: discard
    else: discard
  runServerLoop(address, port)

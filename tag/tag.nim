import mummy, pixie
import protocol, reward_protocol, server
import std/[locks, monotimes, os, parseopt, random, strutils, tables, times]

const
  SheetTileSize = TileSize
  WorldWidthTiles = 64
  WorldHeightTiles = 64
  WorldWidthPixels = WorldWidthTiles * TileSize
  WorldHeightPixels = WorldHeightTiles * TileSize
  MotionScale = 256
  Accel = 38
  FrictionNum = 200
  FrictionDen = 256
  MaxSpeed = 352
  StopThreshold = 8
  FpsScale = 1000
  TargetFps = 24 * FpsScale
  WebSocketPath = "/player"
  BackgroundColor = 12'u8
  PlayerColors = [3'u8, 7, 8, 14, 4, 11, 13, 15]
  FreezeTicks = 48
  ScoreInterval = 24
  BlinkRate = 6
  WhiteColor = 2'u8
  ItSpeedMul = 3
  ItSpeedDiv = 2

type
  Actor = object
    x, y: int
    sprite: Sprite
    facing: Facing
    velX, velY: int
    carryX, carryY: int
    score: int
    rlScore: int
    isIt: bool
    freezeTicks: int

  SimServer = object
    players: seq[Actor]
    tiles: seq[bool]
    playerSprite: Sprite
    terrainSprite: Sprite
    digitSprites: array[10, Sprite]
    letterSprites: seq[Sprite]
    fb: Framebuffer
    rng: Rand
    tickCount: int

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    closedSockets: seq[WebSocket]
    rewards: RewardState
    resetRequested: bool

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
  ty * WorldWidthTiles + tx

proc inTileBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles

proc worldClampPixel(x, maxValue: int): int =
  x.clamp(0, maxValue)

proc distanceSquared(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc rectsOverlap(ax, ay, aw, ah, bx, by, bw, bh: int): bool =
  ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by

proc collidesWithPlayer(sim: SimServer, pi: int, x, y, w, h: int): bool =
  for j in 0 ..< sim.players.len:
    if j == pi:
      continue
    let o = sim.players[j]
    if rectsOverlap(x, y, w, h, o.x, o.y, o.sprite.width, o.sprite.height):
      return true
  false

proc canOccupy(sim: SimServer, x, y, width, height: int): bool =
  if x < 0 or y < 0 or x + width > WorldWidthPixels or y + height > WorldHeightPixels:
    return false
  let
    startTx = x div TileSize
    startTy = y div TileSize
    endTx = (x + width - 1) div TileSize
    endTy = (y + height - 1) div TileSize
  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      if sim.tiles[tileIndex(tx, ty)]:
        return false
  true

proc clearSpawnArea(sim: var SimServer, centerTx, centerTy, radius: int) =
  for ty in centerTy - radius .. centerTy + radius:
    for tx in centerTx - radius .. centerTx + radius:
      if inTileBounds(tx, ty):
        sim.tiles[tileIndex(tx, ty)] = false

proc seedBrush(sim: var SimServer) =
  for _ in 0 ..< 120:
    let
      baseTx = sim.rng.rand(WorldWidthTiles - 1)
      baseTy = sim.rng.rand(WorldHeightTiles - 1)
      patchW = 1 + sim.rng.rand(3)
      patchH = 1 + sim.rng.rand(3)
    for dy in 0 ..< patchH:
      for dx in 0 ..< patchW:
        let tx = baseTx + dx
        let ty = baseTy + dy
        if inTileBounds(tx, ty) and sim.rng.rand(99) < 65:
          sim.tiles[tileIndex(tx, ty)] = true

proc findPlayerSpawn(sim: SimServer): tuple[x, y: int] =
  let
    centerTx = WorldWidthTiles div 2
    centerTy = WorldHeightTiles div 2
    minSpacingSq = 20 * 20
  for radius in 0 .. 12:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        let
          tx = centerTx + dx
          ty = centerTy + dy
        if not inTileBounds(tx, ty):
          continue
        let
          px = tx * TileSize
          py = ty * TileSize
        if not sim.canOccupy(px, py, sim.playerSprite.width, sim.playerSprite.height):
          continue
        var tooClose = false
        for player in sim.players:
          if distanceSquared(px, py, player.x, player.y) < minSpacingSq:
            tooClose = true
            break
        if not tooClose:
          return (px, py)
  (centerTx * TileSize, centerTy * TileSize)

proc addPlayer(sim: var SimServer): int =
  let spawn = sim.findPlayerSpawn()
  let isFirstPlayer = sim.players.len == 0
  sim.players.add Actor(
    x: spawn.x,
    y: spawn.y,
    sprite: sim.playerSprite,
    facing: FaceDown,
    isIt: isFirstPlayer,
    freezeTicks: 0,
  )
  sim.players.high

proc initSimServer(seed: int): SimServer =
  result.rng = initRand(seed)
  result.tiles = newSeq[bool](WorldWidthTiles * WorldHeightTiles)
  result.fb = initFramebuffer()
  loadClientPalette()
  let sheet = readImage(sheetPath())
  result.terrainSprite = sheet.sheetSprite(0, 0)
  result.playerSprite = sheet.sheetSprite(1, 0)
  result.digitSprites = loadClientDigitSprites()
  result.letterSprites = loadClientLetterSprites()
  result.seedBrush()
  let startTx = WorldWidthTiles div 2
  let startTy = WorldHeightTiles div 2
  result.clearSpawnArea(startTx, startTy, 5)
  result.players = @[]

proc placePlayerNear(sim: var SimServer, playerIndex, anchorIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if anchorIndex < 0 or anchorIndex >= sim.players.len:
    return
  let offsets = [
    (TileSize * 6, 0),
    (-TileSize * 6, 0),
    (0, TileSize * 6),
    (0, -TileSize * 6),
    (TileSize * 4, TileSize * 4),
    (-TileSize * 4, TileSize * 4),
    (TileSize * 4, -TileSize * 4),
    (-TileSize * 4, -TileSize * 4),
  ]
  for offset in offsets:
    let
      x = clamp(
        sim.players[anchorIndex].x + offset[0],
        0,
        WorldWidthPixels - sim.players[playerIndex].sprite.width,
      )
      y = clamp(
        sim.players[anchorIndex].y + offset[1],
        0,
        WorldHeightPixels - sim.players[playerIndex].sprite.height,
      )
    if sim.canOccupy(x, y, sim.players[playerIndex].sprite.width, sim.players[playerIndex].sprite.height):
      sim.players[playerIndex].x = x
      sim.players[playerIndex].y = y
      return

proc configureRlMatch(sim: var SimServer, controlledPlayers: int) =
  if controlledPlayers <= 0:
    return
  while sim.players.len < controlledPlayers + 1:
    discard sim.addPlayer()
  let botIndex = controlledPlayers
  sim.placePlayerNear(botIndex, 0)
  for player in sim.players.mitems:
    player.isIt = false
    player.freezeTicks = 0
  sim.players[0].isIt = true

proc applyMomentumAxis(
  sim: SimServer,
  actor: var Actor,
  pi: int,
  carry: var int,
  velocity: int,
  horizontal: bool
) =
  carry += velocity
  while abs(carry) >= MotionScale:
    let step = (if carry < 0: -1 else: 1)
    if horizontal:
      let nx = actor.x + step
      if sim.canOccupy(nx, actor.y, actor.sprite.width, actor.sprite.height) and
         not sim.collidesWithPlayer(pi, nx, actor.y, actor.sprite.width, actor.sprite.height):
        actor.x = nx
        carry -= step * MotionScale
      else:
        carry = 0
        break
    else:
      let ny = actor.y + step
      if sim.canOccupy(actor.x, ny, actor.sprite.width, actor.sprite.height) and
         not sim.collidesWithPlayer(pi, actor.x, ny, actor.sprite.width, actor.sprite.height):
        actor.y = ny
        carry -= step * MotionScale
      else:
        carry = 0
        break

proc applyInput(sim: var SimServer, playerIndex: int, input: InputState) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  template player: untyped = sim.players[playerIndex]

  if player.freezeTicks > 0:
    player.velX = 0
    player.velY = 0
    return

  var inputX = 0
  var inputY = 0
  if input.left:
    inputX -= 1
  if input.right:
    inputX += 1
  if input.up:
    inputY -= 1
  if input.down:
    inputY += 1

  let maxSpd = if player.isIt: MaxSpeed * ItSpeedMul div ItSpeedDiv else: MaxSpeed

  if inputX != 0:
    player.velX = clamp(player.velX + inputX * Accel, -maxSpd, maxSpd)
  else:
    player.velX = (player.velX * FrictionNum) div FrictionDen
    if abs(player.velX) < StopThreshold:
      player.velX = 0

  if inputY != 0:
    player.velY = clamp(player.velY + inputY * Accel, -maxSpd, maxSpd)
  else:
    player.velY = (player.velY * FrictionNum) div FrictionDen
    if abs(player.velY) < StopThreshold:
      player.velY = 0

  if abs(player.velX) > abs(player.velY):
    if player.velX < 0:
      player.facing = FaceLeft
    elif player.velX > 0:
      player.facing = FaceRight
  else:
    if player.velY < 0:
      player.facing = FaceUp
    elif player.velY > 0:
      player.facing = FaceDown

  if inputX < 0:
    player.facing = FaceLeft
  elif inputX > 0:
    player.facing = FaceRight
  elif inputY < 0:
    player.facing = FaceUp
  elif inputY > 0:
    player.facing = FaceDown

  sim.applyMomentumAxis(player, playerIndex, player.carryX, player.velX, true)
  sim.applyMomentumAxis(player, playerIndex, player.carryY, player.velY, false)

proc applyTag(sim: var SimServer) =
  if sim.players.len < 2:
    return

  var taggerIndex = -1
  for i in 0 ..< sim.players.len:
    if sim.players[i].isIt:
      taggerIndex = i
      break
  if taggerIndex < 0:
    return

  if sim.players[taggerIndex].freezeTicks > 0:
    return

  let t = sim.players[taggerIndex]
  for i in 0 ..< sim.players.len:
    if i == taggerIndex:
      continue
    if sim.players[i].freezeTicks > 0:
      continue
    let o = sim.players[i]
    if rectsOverlap(t.x - 1, t.y - 1, t.sprite.width + 2, t.sprite.height + 2,
                    o.x, o.y, o.sprite.width, o.sprite.height):
      sim.players[taggerIndex].rlScore += 50
      sim.players[taggerIndex].isIt = false
      sim.players[i].isIt = true
      sim.players[i].freezeTicks = FreezeTicks
      break

proc isOnScreen(viewer, target: Actor): bool =
  let
    camX = worldClampPixel(viewer.x + viewer.sprite.width div 2 - ScreenWidth div 2, WorldWidthPixels - ScreenWidth)
    camY = worldClampPixel(viewer.y + viewer.sprite.height div 2 - ScreenHeight div 2, WorldHeightPixels - ScreenHeight)
    sx = target.x - camX
    sy = target.y - camY
  sx + target.sprite.width > 0 and sx < ScreenWidth and
    sy + target.sprite.height > 0 and sy < ScreenHeight

proc awardProximityScore(sim: var SimServer) =
  if sim.players.len < 2:
    return
  if sim.tickCount mod ScoreInterval != 0:
    return

  var taggerIndex = -1
  for i in 0 ..< sim.players.len:
    if sim.players[i].isIt:
      taggerIndex = i
      break
  if taggerIndex < 0:
    return

  let tagger = sim.players[taggerIndex]
  for i in 0 ..< sim.players.len:
    if i == taggerIndex:
      continue
    if sim.players[i].isOnScreen(tagger):
      inc sim.players[i].score

proc awardRlShaping(sim: var SimServer) =
  if sim.players.len < 2:
    return

  var taggerIndex = -1
  for i in 0 ..< sim.players.len:
    if sim.players[i].isIt:
      taggerIndex = i
      break
  if taggerIndex < 0:
    return

  let tagger = sim.players[taggerIndex]
  for i in 0 ..< sim.players.len:
    if i == taggerIndex:
      continue
    let other = sim.players[i]
    let manhattan = abs(other.x - tagger.x) + abs(other.y - tagger.y)
    if manhattan <= TileSize * 10:
      inc sim.players[taggerIndex].rlScore

proc ensureTagger(sim: var SimServer) =
  if sim.players.len == 0:
    return
  var hasIt = false
  for p in sim.players:
    if p.isIt:
      hasIt = true
      break
  if not hasIt:
    sim.players[sim.rng.rand(sim.players.len - 1)].isIt = true
    sim.players[sim.players.len - 1].freezeTicks = 0

proc playerColor(playerIndex: int): uint8 =
  PlayerColors[playerIndex mod PlayerColors.len]

proc renderTerrain(sim: var SimServer, cameraX, cameraY: int) =
  let
    startTx = max(0, cameraX div TileSize)
    startTy = max(0, cameraY div TileSize)
    endTx = min(WorldWidthTiles - 1, (cameraX + ScreenWidth - 1) div TileSize)
    endTy = min(WorldHeightTiles - 1, (cameraY + ScreenHeight - 1) div TileSize)
  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      if sim.tiles[tileIndex(tx, ty)]:
        sim.fb.blitSprite(sim.terrainSprite, tx * TileSize, ty * TileSize, cameraX, cameraY)

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

proc blitSpriteColored(fb: var Framebuffer, sprite: Sprite, worldX, worldY, cameraX, cameraY: int, color: uint8) =
  let
    screenX = worldX - cameraX
    screenY = worldY - cameraY
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        fb.putPixel(screenX + x, screenY + y, color)

proc renderRadar(fb: var Framebuffer, sim: SimServer, playerIndex: int, cameraX, cameraY: int) =
  let
    player = sim.players[playerIndex]
    pcx = player.x + player.sprite.width div 2
    pcy = player.y + player.sprite.height div 2
    halfW = ScreenWidth div 2
    halfH = ScreenHeight div 2

  proc projectToEdge(dx, dy: int): tuple[x, y: int] =
    if dx == 0 and dy == 0:
      return (0, 0)
    let
      adx = abs(dx)
      ady = abs(dy)
    if adx * halfH > ady * halfW:
      let ex = if dx > 0: ScreenWidth - 1 else: 0
      let ey = halfH + dy * halfW div adx
      (ex, clamp(ey, 0, ScreenHeight - 1))
    else:
      let ey = if dy > 0: ScreenHeight - 1 else: 0
      let ex = halfW + dx * halfH div ady
      (clamp(ex, 0, ScreenWidth - 1), ey)

  for i in 0 ..< sim.players.len:
    if i == playerIndex:
      continue
    let
      other = sim.players[i]
      ocx = other.x + other.sprite.width div 2
      ocy = other.y + other.sprite.height div 2
      sx = ocx - cameraX
      sy = ocy - cameraY
    if sx >= 0 and sx < ScreenWidth and sy >= 0 and sy < ScreenHeight:
      continue
    let
      dx = ocx - pcx
      dy = ocy - pcy
      pos = projectToEdge(dx, dy)
      blinking = other.isIt and (sim.tickCount div BlinkRate) mod 2 == 0
      color = if blinking: WhiteColor else: playerColor(i)
    fb.putPixel(pos.x, pos.y, color)

proc renderHud(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let player = sim.players[playerIndex]
  sim.fb.renderNumber(sim.digitSprites, player.score, 0, 0)
  if player.isIt:
    sim.fb.blitText(sim.letterSprites, "IT", ScreenWidth - 12, 0)

proc render(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(BackgroundColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return sim.fb.packed

  let player = sim.players[playerIndex]
  let
    cameraX = worldClampPixel(player.x + player.sprite.width div 2 - ScreenWidth div 2, WorldWidthPixels - ScreenWidth)
    cameraY = worldClampPixel(player.y + player.sprite.height div 2 - ScreenHeight div 2, WorldHeightPixels - ScreenHeight)

  sim.renderTerrain(cameraX, cameraY)

  for i in 0 ..< sim.players.len:
    let p = sim.players[i]
    var color = playerColor(i)
    if p.isIt and (sim.tickCount div BlinkRate) mod 2 == 0:
      color = WhiteColor
    sim.fb.blitSpriteColored(p.sprite, p.x, p.y, cameraX, cameraY, color)
    if p.freezeTicks > 0:
      let barY = p.y - 2 - cameraY
      let barX = p.x - cameraX
      let barW = p.sprite.width
      let filled = (p.freezeTicks * barW + FreezeTicks - 1) div FreezeTicks
      for bx in 0 ..< barW:
        let c = if bx < filled: WhiteColor else: 0'u8
        sim.fb.putPixel(barX + bx, barY, c)

  sim.fb.renderRadar(sim, playerIndex, cameraX, cameraY)
  sim.renderHud(playerIndex)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc rewardMetric(sim: SimServer, playerIndex: int): RewardMetric =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return RewardMetric(score: 0, auxValue: 0)
  let player = sim.players[playerIndex]
  RewardMetric(score: player.rlScore, auxValue: if player.isIt: 1 else: 0)



proc botInput(sim: var SimServer, playerIndex: int): InputState =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  var
    targetIndex = -1
    bestDist = high(int)
  for i in 0 ..< sim.players.len:
    if i == playerIndex:
      continue
    let dist = distanceSquared(
      sim.players[playerIndex].x,
      sim.players[playerIndex].y,
      sim.players[i].x,
      sim.players[i].y,
    )
    if dist < bestDist:
      bestDist = dist
      targetIndex = i
  if targetIndex < 0:
    return

  let
    player = sim.players[playerIndex]
    target = sim.players[targetIndex]
    playerCenterX = player.x + player.sprite.width div 2
    playerCenterY = player.y + player.sprite.height div 2
    targetCenterX = target.x + target.sprite.width div 2
    targetCenterY = target.y + target.sprite.height div 2
    dx = targetCenterX - playerCenterX
    dy = targetCenterY - playerCenterY
    tagRange = player.sprite.width + 2
    tagRangeSq = tagRange * tagRange

  if player.isIt:
    if dx < -2:
      result.left = true
    elif dx > 2:
      result.right = true
    if dy < -2:
      result.up = true
    elif dy > 2:
      result.down = true
    if dx * dx + dy * dy <= tagRangeSq:
      result.attack = true
  else:
    if dx < -2:
      result.right = true
    elif dx > 2:
      result.left = true
    if dy < -2:
      result.down = true
    elif dy > 2:
      result.up = true
    if sim.rng.rand(0 .. 7) == 0:
      case sim.rng.rand(0 .. 3)
      of 0: result.left = true
      of 1: result.right = true
      of 2: result.up = true
      else: result.down = true

proc step(sim: var SimServer, inputs: openArray[InputState]) =
  inc sim.tickCount
  for i in 0 ..< sim.players.len:
    if sim.players[i].freezeTicks > 0:
      dec sim.players[i].freezeTicks
  for playerIndex in 0 ..< sim.players.len:
    let input =
      if playerIndex < inputs.len:
        inputs[playerIndex]
      else:
        sim.botInput(playerIndex)
    sim.applyInput(playerIndex, input)
  sim.applyTag()
  sim.awardRlShaping()
  sim.awardProximityScore()
  sim.ensureTagger()

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.closedSockets = @[]
  appState.rewards = initRewardState()
  appState.resetRequested = false

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
  appState.rewards.detachRewardClient(websocket)
  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc httpHandler(request: Request) =
  if request.path == WebSocketPath and request.httpMethod == "GET":
    {.gcsafe.}:
      withLock appState.lock:
        appState.rewards.captureRewardClient(request.remoteAddress)
    discard request.upgradeToWebSocket()
  elif request.path == RewardHttpPath and request.httpMethod == "GET":
    var snapshot: RewardSnapshot
    {.gcsafe.}:
      withLock appState.lock:
        snapshot = appState.rewards.lookupReward(request.remoteAddress)
    request.respondReward(snapshot)
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "BitWorld WebSocket server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerIndices[websocket] = PendingPlayerIndex
        appState.inputMasks[websocket] = 0
        appState.lastAppliedMasks[websocket] = 0
        appState.rewards.attachRewardClient(websocket)
  of MessageEvent:
    if message.kind == BinaryMessage and message.data.len == InputPacketBytes:
      {.gcsafe.}:
        withLock appState.lock:
          let mask = blobToMask(message.data)
          if mask == ResetInputMask:
            appState.resetRequested = true
            appState.inputMasks[websocket] = 0
            appState.lastAppliedMasks[websocket] = 0
          else:
            appState.inputMasks[websocket] = mask
  of ErrorEvent:
    discard
  of CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime, targetFps: int) =
  if targetFps <= 0:
    previousTick = getMonoTime()
    return
  let frameDuration = initDuration(microseconds = (1_000_000 * FpsScale) div targetFps)
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  targetFps = TargetFps,
  seed = 0xB1770
) =
  initAppState()
  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4,
    wsNoDelay = true
  )
  var serverThread: Thread[ServerThreadArgs]
  var serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc, ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()

  var
    currentSeed = seed
    sim = initSimServer(currentSeed)
    lastTick = getMonoTime()

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[InputState]
      shouldReset = false

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        if appState.resetRequested:
          shouldReset = true
          appState.resetRequested = false
          for _, value in appState.playerIndices.mpairs:
            value = PendingPlayerIndex
          for _, value in appState.inputMasks.mpairs:
            value = 0
          for _, value in appState.lastAppliedMasks.mpairs:
            value = 0
          appState.rewards.resetRewardEpisode()
        else:
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == PendingPlayerIndex:
              appState.playerIndices[websocket] = sim.addPlayer()
          if appState.playerIndices.len > 0:
            sim.configureRlMatch(appState.playerIndices.len)

          let controlledCount = appState.playerIndices.len
          inputs = newSeq[InputState](controlledCount)
          for websocket, playerIndex in appState.playerIndices.pairs:
            if playerIndex < 0 or playerIndex >= inputs.len:
              continue
            let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
            let previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
            inputs[playerIndex] = inputStateFromMasks(currentMask, previousMask)
            appState.lastAppliedMasks[websocket] = currentMask
            sockets.add(websocket)
            playerIndices.add(playerIndex)

    if shouldReset:
      inc currentSeed
      sim = initSimServer(currentSeed)
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == PendingPlayerIndex:
              appState.playerIndices[websocket] = sim.addPlayer()
            sockets.add(websocket)
            playerIndices.add(appState.playerIndices[websocket])
          if appState.playerIndices.len > 0:
            sim.configureRlMatch(appState.playerIndices.len)
      for i in 0 ..< sockets.len:
        {.gcsafe.}:
          withLock appState.lock:
            appState.rewards.recordReward(sockets[i], sim.rewardMetric(playerIndices[i]))
        let frameBlob = blobFromBytes(sim.render(playerIndices[i]))
        try:
          sockets[i].send(frameBlob, BinaryMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              sim.removePlayer(sockets[i])
      runFrameLimiter(lastTick, targetFps)
      continue


    sim.step(inputs)

    for i in 0 ..< sockets.len:
      {.gcsafe.}:
        withLock appState.lock:
          appState.rewards.recordReward(sockets[i], sim.rewardMetric(playerIndices[i]))
      let frameBlob = blobFromBytes(sim.render(playerIndices[i]))
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    runFrameLimiter(lastTick, targetFps)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    positional = 0
    targetFps = TargetFps
    seed = 0xB1770
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
      of "fps": targetFps = parseInt(val) * FpsScale
      of "seed": seed = parseInt(val)
      else: discard
    else: discard
  runServerLoop(address, port, targetFps = targetFps, seed = seed)

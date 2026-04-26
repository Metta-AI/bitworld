import mummy
import protocol, server
import std/[locks, math, monotimes, os, parseopt, random, strutils, tables, times]

const
  MotionScale = 256
  TargetFps = 24.0
  WebSocketPath = "/player"

  Accel = 28
  DashBoost = 280
  DashCooldownTicks = 24
  FrictionNum = 245
  FrictionDen = 256
  BrakeFrictionNum = 200
  BrakeFrictionDen = 256
  MaxSpeed = 400
  StopThreshold = 4
  PlayerRadius = 2
  KnockbackMul = 3

  PlatformStartSize = 48
  PlatformMinSize = 36
  ShrinkIntervalTicks = 24 * 10
  ShrinkAmount = 2

  SnowballSpeed = 180
  SnowballRadius = 1
  SnowballKnockback = 320
  SnowballSpawnInterval = 24 * 3
  SnowballMinInterval = 24
  PenguinWaveInterval = 24 * 15
  PenguinCount = 4
  PenguinSpeed = 140
  PenguinRadius = 2
  PenguinKnockback = 400

  RoundCount = 5
  RoundStartDelayTicks = 24 * 2
  RoundEndDelayTicks = 24 * 3
  MatchEndDelayTicks = 24 * 5
  FallAnimTicks = 6
  EdgeGraceTicks = 8

  WaterColor = 1'u8
  WaterHighlight = 12'u8
  IceTopColor = 11'u8
  IceMidColor = 15'u8
  IceEdgeColor = 5'u8
  IceSideColor = 1'u8
  ShadowColor = 1'u8
  SnowballColor = 2'u8
  PenguinBodyColor = 12'u8
  PenguinBellyColor = 2'u8
  HudBgColor = 1'u8
  PlayerColors = [3'u8, 7, 8, 14, 4, 6, 9, 10]
  MaxPlayers = 8

type
  ObstacleKind = enum
    Snowball
    Penguin

  Obstacle = object
    kind: ObstacleKind
    x, y: int
    velX, velY: int
    alive: bool

  Player = object
    x, y: int
    velX, velY: int
    alive: bool
    falling: bool
    fallTimer: int
    edgeTimer: int
    dashCooldown: int
    score: int
    elimOrder: int

  RoundPhase = enum
    PhaseRoundStart
    PhasePlaying
    PhaseRoundEnd
    PhaseMatchEnd

  SimServer = object
    players: seq[Player]
    obstacles: seq[Obstacle]
    fb: Framebuffer
    digitSprites: array[10, Sprite]
    letterSprites: seq[Sprite]
    rng: Rand
    tickCount: int
    platformSize: int
    platformX, platformY: int
    phase: RoundPhase
    phaseTimer: int
    currentRound: int
    elimCount: int
    snowballTimer: int
    penguinTimer: int
    lastShrinkTick: int

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

var appState: WebSocketAppState

proc repoDir(): string =
  getAppDir() / ".."

proc clientDataDir(): string =
  repoDir() / "client" / "data"

proc palettePath(): string =
  clientDataDir() / "pallete.png"

proc numbersPath(): string =
  clientDataDir() / "numbers.png"

proc lettersPath(): string =
  clientDataDir() / "letters.png"

proc platformLeft(sim: SimServer): int =
  sim.platformX

proc platformTop(sim: SimServer): int =
  sim.platformY

proc platformRight(sim: SimServer): int =
  sim.platformX + sim.platformSize - 1

proc platformBottom(sim: SimServer): int =
  sim.platformY + sim.platformSize - 1

proc isOnPlatform(sim: SimServer, px, py: int): bool =
  let margin = -1
  px >= sim.platformLeft + margin and px <= sim.platformRight - margin and
    py >= sim.platformTop + margin and py <= sim.platformBottom - margin

proc centerPlatform(sim: var SimServer) =
  sim.platformX = (ScreenWidth - sim.platformSize) div 2
  sim.platformY = (ScreenHeight - sim.platformSize) div 2 - 1

proc spawnPosition(sim: SimServer, index, total: int): tuple[x, y: int] =
  let cx = sim.platformX + sim.platformSize div 2
  let cy = sim.platformY + sim.platformSize div 2
  let radius = sim.platformSize div 3
  let angle = float(index) * 2.0 * PI / float(max(1, total))
  (cx + int(cos(angle) * float(radius)), cy + int(sin(angle) * float(radius)))

proc resetRound(sim: var SimServer) =
  sim.platformSize = PlatformStartSize
  sim.centerPlatform()
  sim.obstacles = @[]
  sim.elimCount = 0
  sim.snowballTimer = SnowballSpawnInterval
  sim.penguinTimer = PenguinWaveInterval
  sim.lastShrinkTick = sim.tickCount
  for i in 0 ..< sim.players.len:
    let pos = sim.spawnPosition(i, sim.players.len)
    sim.players[i].x = pos.x
    sim.players[i].y = pos.y
    sim.players[i].velX = 0
    sim.players[i].velY = 0
    sim.players[i].alive = true
    sim.players[i].falling = false
    sim.players[i].fallTimer = 0
    sim.players[i].edgeTimer = 0
    sim.players[i].dashCooldown = 0
    sim.players[i].elimOrder = 0

proc initSimServer(): SimServer =
  result.rng = initRand(0x1CE_B2A1)
  result.fb = initFramebuffer()
  loadPalette(palettePath())
  result.digitSprites = loadDigitSprites(numbersPath())
  result.letterSprites = loadLetterSprites(lettersPath())
  result.platformSize = PlatformStartSize
  result.centerPlatform()
  result.phase = PhaseRoundStart
  result.phaseTimer = RoundStartDelayTicks
  result.currentRound = 1

proc addPlayer(sim: var SimServer): int =
  let total = sim.players.len + 1
  let pos = sim.spawnPosition(sim.players.len, total)
  sim.players.add Player(
    x: pos.x,
    y: pos.y,
    alive: true,
  )
  sim.players.high

proc applyInput(sim: var SimServer, playerIndex: int, input: InputState, prevInput: InputState) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if not sim.players[playerIndex].alive or sim.players[playerIndex].falling:
    return

  template player: untyped = sim.players[playerIndex]

  var ix = 0
  var iy = 0
  if input.left: ix -= 1
  if input.right: ix += 1
  if input.up: iy -= 1
  if input.down: iy += 1

  if ix != 0:
    player.velX = clamp(player.velX + ix * Accel, -MaxSpeed, MaxSpeed)
  if iy != 0:
    player.velY = clamp(player.velY + iy * Accel, -MaxSpeed, MaxSpeed)

  let braking = input.b
  let frN = if braking: BrakeFrictionNum else: FrictionNum
  let frD = if braking: BrakeFrictionDen else: FrictionDen

  if ix == 0:
    player.velX = (player.velX * frN) div frD
    if abs(player.velX) < StopThreshold: player.velX = 0
  if iy == 0:
    player.velY = (player.velY * frN) div frD
    if abs(player.velY) < StopThreshold: player.velY = 0

  let dashPressed = input.attack and not prevInput.attack
  if dashPressed and player.dashCooldown <= 0:
    var dx = ix
    var dy = iy
    if dx == 0 and dy == 0:
      if abs(player.velX) > abs(player.velY):
        dx = if player.velX >= 0: 1 else: -1
      else:
        dy = if player.velY >= 0: 1 else: -1
    player.velX = clamp(player.velX + dx * DashBoost, -MaxSpeed * 2, MaxSpeed * 2)
    player.velY = clamp(player.velY + dy * DashBoost, -MaxSpeed * 2, MaxSpeed * 2)
    player.dashCooldown = DashCooldownTicks

  if player.dashCooldown > 0:
    dec player.dashCooldown

proc stepPlayerPositions(sim: var SimServer) =
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive: continue
    if sim.players[i].falling: continue
    sim.players[i].x += sim.players[i].velX div MotionScale
    sim.players[i].y += sim.players[i].velY div MotionScale

proc resolvePlayerCollisions(sim: var SimServer) =
  let collisionDist = PlayerRadius * 2 + 1
  let collisionDistSq = collisionDist * collisionDist
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive or sim.players[i].falling: continue
    for j in i + 1 ..< sim.players.len:
      if not sim.players[j].alive or sim.players[j].falling: continue
      let dx = sim.players[i].x - sim.players[j].x
      let dy = sim.players[i].y - sim.players[j].y
      let distSq = dx * dx + dy * dy
      if distSq < collisionDistSq and distSq > 0:
        let dist = max(1, int(sqrt(float(distSq))))
        let nx = (dx * 256) div dist
        let ny = (dy * 256) div dist
        let relVelX = sim.players[i].velX - sim.players[j].velX
        let relVelY = sim.players[i].velY - sim.players[j].velY
        let dot = (relVelX * nx + relVelY * ny) div 256
        if dot > 0:
          let impulse = dot * KnockbackMul
          sim.players[i].velX -= (impulse * nx) div 256
          sim.players[i].velY -= (impulse * ny) div 256
          sim.players[j].velX += (impulse * nx) div 256
          sim.players[j].velY += (impulse * ny) div 256
        let overlap = collisionDist - dist
        let pushX = (nx * overlap) div (2 * 256)
        let pushY = (ny * overlap) div (2 * 256)
        sim.players[i].x += pushX
        sim.players[i].y += pushY
        sim.players[j].x -= pushX
        sim.players[j].y -= pushY

proc spawnSnowball(sim: var SimServer) =
  let side = sim.rng.rand(3)
  var ox, oy, vx, vy: int
  let cx = sim.platformX + sim.platformSize div 2
  let cy = sim.platformY + sim.platformSize div 2
  let spread = sim.rng.rand(sim.platformSize div 2) - sim.platformSize div 4
  case side
  of 0:
    ox = sim.platformLeft - 4
    oy = cy + spread
    vx = SnowballSpeed
    vy = 0
  of 1:
    ox = sim.platformRight + 4
    oy = cy + spread
    vx = -SnowballSpeed
    vy = 0
  of 2:
    ox = cx + spread
    oy = sim.platformTop - 4
    vx = 0
    vy = SnowballSpeed
  else:
    ox = cx + spread
    oy = sim.platformBottom + 4
    vx = 0
    vy = -SnowballSpeed
  sim.obstacles.add Obstacle(kind: Snowball, x: ox, y: oy, velX: vx, velY: vy, alive: true)

proc spawnPenguinWave(sim: var SimServer) =
  let horizontal = sim.rng.rand(1) == 0
  let fromStart = sim.rng.rand(1) == 0
  for i in 0 ..< PenguinCount:
    var ox, oy, vx, vy: int
    let gap = sim.platformSize div (PenguinCount + 1)
    if horizontal:
      ox = if fromStart: sim.platformLeft - 6 else: sim.platformRight + 6
      oy = sim.platformTop + gap * (i + 1)
      vx = if fromStart: PenguinSpeed else: -PenguinSpeed
      vy = 0
    else:
      ox = sim.platformLeft + gap * (i + 1)
      oy = if fromStart: sim.platformTop - 6 else: sim.platformBottom + 6
      vx = 0
      vy = if fromStart: PenguinSpeed else: -PenguinSpeed
    sim.obstacles.add Obstacle(kind: Penguin, x: ox, y: oy, velX: vx, velY: vy, alive: true)

proc stepObstacles(sim: var SimServer) =
  for i in 0 ..< sim.obstacles.len:
    if not sim.obstacles[i].alive: continue
    sim.obstacles[i].x += sim.obstacles[i].velX div MotionScale
    sim.obstacles[i].y += sim.obstacles[i].velY div MotionScale
    let o = sim.obstacles[i]
    if o.x < -10 or o.x > ScreenWidth + 10 or o.y < -10 or o.y > ScreenHeight + 10:
      sim.obstacles[i].alive = false

  var active: seq[Obstacle] = @[]
  for o in sim.obstacles:
    if o.alive: active.add(o)
  sim.obstacles = move(active)

proc resolveObstacleCollisions(sim: var SimServer) =
  for oi in 0 ..< sim.obstacles.len:
    if not sim.obstacles[oi].alive: continue
    let o = sim.obstacles[oi]
    let oRadius = if o.kind == Snowball: SnowballRadius else: PenguinRadius
    let knockback = if o.kind == Snowball: SnowballKnockback else: PenguinKnockback
    for pi in 0 ..< sim.players.len:
      if not sim.players[pi].alive or sim.players[pi].falling: continue
      let dx = sim.players[pi].x - o.x
      let dy = sim.players[pi].y - o.y
      let hitDist = PlayerRadius + oRadius + 1
      let distSq = dx * dx + dy * dy
      if distSq < hitDist * hitDist:
        let dist = max(1, int(sqrt(float(distSq))))
        let nx = if dist > 0: (dx * 256) div dist else: 256
        let ny = if dist > 0: (dy * 256) div dist else: 0
        sim.players[pi].velX += (knockback * nx) div 256
        sim.players[pi].velY += (knockback * ny) div 256
        if o.kind == Snowball:
          sim.obstacles[oi].alive = false

proc checkEliminations(sim: var SimServer) =
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive: continue
    if sim.players[i].falling:
      dec sim.players[i].fallTimer
      if sim.players[i].fallTimer <= 0:
        sim.players[i].alive = false
        sim.players[i].falling = false
        inc sim.elimCount
        sim.players[i].elimOrder = sim.elimCount
      continue
    if not sim.isOnPlatform(sim.players[i].x, sim.players[i].y):
      if sim.players[i].edgeTimer < EdgeGraceTicks:
        inc sim.players[i].edgeTimer
      else:
        sim.players[i].falling = true
        sim.players[i].fallTimer = FallAnimTicks
        sim.players[i].velX = sim.players[i].velX div 2
        sim.players[i].velY = sim.players[i].velY div 2
    else:
      sim.players[i].edgeTimer = 0

proc aliveCount(sim: SimServer): int =
  for p in sim.players:
    if p.alive and not p.falling: inc result

proc shrinkPlatform(sim: var SimServer) =
  if sim.platformSize <= PlatformMinSize: return
  if sim.tickCount - sim.lastShrinkTick < ShrinkIntervalTicks: return
  sim.lastShrinkTick = sim.tickCount
  sim.platformSize = max(PlatformMinSize, sim.platformSize - ShrinkAmount)
  sim.centerPlatform()

proc checkRoundEnd(sim: var SimServer) =
  if sim.players.len < 2: return
  let alive = sim.aliveCount()
  if alive <= 1:
    for i in 0 ..< sim.players.len:
      if sim.players[i].alive and not sim.players[i].falling:
        sim.players[i].elimOrder = 0
        sim.players[i].score += 3
    let totalPlayers = sim.players.len
    for i in 0 ..< sim.players.len:
      if sim.players[i].elimOrder > 0:
        let points = totalPlayers - sim.players[i].elimOrder
        sim.players[i].score += max(0, points)
    sim.phase = if sim.currentRound >= RoundCount: PhaseMatchEnd else: PhaseRoundEnd
    sim.phaseTimer = if sim.phase == PhaseMatchEnd: MatchEndDelayTicks else: RoundEndDelayTicks

proc spawnObstacles(sim: var SimServer) =
  dec sim.snowballTimer
  if sim.snowballTimer <= 0:
    sim.spawnSnowball()
    let elapsed = sim.tickCount div (24 * 5)
    let interval = max(SnowballMinInterval, SnowballSpawnInterval - elapsed * 6)
    sim.snowballTimer = interval
  dec sim.penguinTimer
  if sim.penguinTimer <= 0:
    sim.spawnPenguinWave()
    sim.penguinTimer = PenguinWaveInterval

proc fillRect(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  for py in y ..< y + h:
    for px in x ..< x + w:
      fb.putPixel(px, py, color)

proc drawHLine(fb: var Framebuffer, x0, x1, y: int, color: uint8) =
  for x in min(x0, x1) .. max(x0, x1):
    fb.putPixel(x, y, color)

proc drawCircleFill(fb: var Framebuffer, cx, cy, radius: int, color: uint8) =
  if radius <= 0:
    fb.putPixel(cx, cy, color)
    return
  var x = radius
  var y = 0
  var d = 1 - radius
  while x >= y:
    fb.drawHLine(cx - x, cx + x, cy + y, color)
    fb.drawHLine(cx - x, cx + x, cy - y, color)
    fb.drawHLine(cx - y, cx + y, cy + x, color)
    fb.drawHLine(cx - y, cx + y, cy - x, color)
    inc y
    if d < 0:
      d += 2 * y + 1
    else:
      dec x
      d += 2 * (y - x) + 1

proc renderWater(sim: var SimServer) =
  sim.fb.clearFrame(WaterColor)
  let phase = (sim.tickCount div 6) mod 4
  for y in 0 ..< ScreenHeight:
    if (y + phase) mod 4 == 0:
      for x in 0 ..< ScreenWidth:
        let wx = (x + sim.tickCount div 3) mod 8
        if wx < 2:
          sim.fb.putPixel(x, y, WaterHighlight)

proc renderPlatform(sim: var SimServer) =
  let px = sim.platformX
  let py = sim.platformY
  let sz = sim.platformSize
  let sideHeight = 3

  sim.fb.fillRect(px + 1, py + sz, sz, sideHeight, IceSideColor)
  sim.fb.fillRect(px, py, sz, sz, IceTopColor)

  for x in px ..< px + sz:
    sim.fb.putPixel(x, py, IceMidColor)
    sim.fb.putPixel(x, py + sz - 1, IceEdgeColor)
  for y in py ..< py + sz:
    sim.fb.putPixel(px, y, IceMidColor)
    sim.fb.putPixel(px + sz - 1, y, IceEdgeColor)

  let shimmerPhase = (sim.tickCount div 8) mod sz
  for i in 0 ..< 3:
    let sx = px + (shimmerPhase + i * (sz div 3)) mod sz
    let sy = py + 2 + (i * 5) mod (sz - 4)
    if sx >= px and sx < px + sz and sy >= py and sy < py + sz:
      sim.fb.putPixel(sx, sy, 2'u8)

proc renderShadows(sim: var SimServer) =
  for i in 0 ..< sim.players.len:
    let p = sim.players[i]
    if not p.alive: continue
    if sim.isOnPlatform(p.x, p.y + 2):
      sim.fb.putPixel(p.x, p.y + 2, ShadowColor)
      sim.fb.putPixel(p.x - 1, p.y + 2, ShadowColor)
      sim.fb.putPixel(p.x + 1, p.y + 2, ShadowColor)

  for o in sim.obstacles:
    if not o.alive: continue
    sim.fb.putPixel(o.x, o.y + 1, ShadowColor)

proc renderObstacles(sim: var SimServer) =
  for o in sim.obstacles:
    if not o.alive: continue
    case o.kind
    of Snowball:
      sim.fb.drawCircleFill(o.x, o.y, SnowballRadius, SnowballColor)
    of Penguin:
      sim.fb.drawCircleFill(o.x, o.y, PenguinRadius, PenguinBodyColor)
      sim.fb.putPixel(o.x, o.y, PenguinBellyColor)

proc renderPlayers(sim: var SimServer) =
  for i in 0 ..< sim.players.len:
    let p = sim.players[i]
    if not p.alive and not p.falling: continue
    let color = PlayerColors[i mod PlayerColors.len]

    if p.falling:
      let shrink = FallAnimTicks - p.fallTimer
      if shrink < 2:
        sim.fb.drawCircleFill(p.x, p.y, PlayerRadius, color)
      elif shrink < 4:
        sim.fb.putPixel(p.x, p.y, color)
        sim.fb.putPixel(p.x + 1, p.y, color)
        sim.fb.putPixel(p.x, p.y + 1, color)
      else:
        sim.fb.putPixel(p.x, p.y, WaterHighlight)
    else:
      sim.fb.drawCircleFill(p.x, p.y, PlayerRadius, color)
      if p.dashCooldown > DashCooldownTicks - 3:
        sim.fb.drawCircleFill(p.x, p.y, PlayerRadius + 1, 2'u8)
        sim.fb.drawCircleFill(p.x, p.y, PlayerRadius, color)

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

proc renderHud(sim: var SimServer) =
  let hudSpacing = if sim.players.len <= 4: 16 else: ScreenWidth div sim.players.len
  for i in 0 ..< sim.players.len:
    let color = PlayerColors[i mod PlayerColors.len]
    let hudX = i * hudSpacing
    sim.fb.putPixel(hudX, 0, color)
    sim.fb.putPixel(hudX + 1, 0, color)
    sim.fb.renderNumber(sim.digitSprites, sim.players[i].score, hudX + 3, 0)

  case sim.phase
  of PhaseRoundStart:
    let textY = ScreenHeight div 2 - 3
    sim.fb.fillRect(10, textY - 1, 44, 8, HudBgColor)
    sim.fb.blitText(sim.letterSprites, "ROUND", 14, textY)
    sim.fb.renderNumber(sim.digitSprites, sim.currentRound, 46, textY)
  of PhaseRoundEnd:
    let textY = ScreenHeight div 2 - 3
    sim.fb.fillRect(12, textY - 1, 40, 8, HudBgColor)
    sim.fb.blitText(sim.letterSprites, "END", 22, textY)
  of PhaseMatchEnd:
    let rows = sim.players.len
    let rowH = if rows <= 4: 7 else: 6
    let boxH = 9 + rows * rowH
    let textY = max(2, ScreenHeight div 2 - boxH div 2)
    sim.fb.fillRect(6, textY - 1, 52, boxH, HudBgColor)
    sim.fb.blitText(sim.letterSprites, "FINAL", 18, textY)
    for i in 0 ..< sim.players.len:
      let color = PlayerColors[i mod PlayerColors.len]
      let rowY = textY + 8 + i * rowH
      sim.fb.putPixel(10, rowY + 2, color)
      sim.fb.putPixel(11, rowY + 2, color)
      sim.fb.renderNumber(sim.digitSprites, sim.players[i].score, 14, rowY)
  of PhasePlaying:
    discard

proc buildFramePacket(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.renderWater()
  sim.renderPlatform()
  sim.renderShadows()
  sim.renderObstacles()
  sim.renderPlayers()
  sim.renderHud()
  sim.fb.packFramebuffer()
  sim.fb.packed

proc step(sim: var SimServer, inputs, prevInputs: openArray[InputState]) =
  inc sim.tickCount

  case sim.phase
  of PhaseRoundStart:
    dec sim.phaseTimer
    if sim.phaseTimer <= 0:
      sim.phase = PhasePlaying
  of PhaseRoundEnd:
    dec sim.phaseTimer
    if sim.phaseTimer <= 0:
      inc sim.currentRound
      sim.phase = PhaseRoundStart
      sim.phaseTimer = RoundStartDelayTicks
      sim.resetRound()
  of PhaseMatchEnd:
    dec sim.phaseTimer
    if sim.phaseTimer <= 0:
      sim.currentRound = 1
      for i in 0 ..< sim.players.len:
        sim.players[i].score = 0
      sim.phase = PhaseRoundStart
      sim.phaseTimer = RoundStartDelayTicks
      sim.resetRound()
  of PhasePlaying:
    for i in 0 ..< sim.players.len:
      let input = if i < inputs.len: inputs[i] else: InputState()
      let prev = if i < prevInputs.len: prevInputs[i] else: InputState()
      sim.applyInput(i, input, prev)

    sim.stepPlayerPositions()
    sim.resolvePlayerCollisions()
    sim.spawnObstacles()
    sim.stepObstacles()
    sim.resolveObstacleCollisions()
    sim.checkEliminations()
    sim.shrinkPlatform()
    sim.checkRoundEnd()

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.closedSockets = @[]

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
  if request.uri == WebSocketPath and request.httpMethod == "GET":
    discard request.upgradeToWebSocket()
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Ice Brawl WebSocket server")

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
    if message.kind == BinaryMessage and message.data.len == InputPacketBytes:
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
      prevInputs: seq[InputState]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] == 0x7fffffff:
            if sim.players.len < MaxPlayers:
              appState.playerIndices[websocket] = sim.addPlayer()
              if sim.players.len == 1:
                sim.resetRound()

        inputs = newSeq[InputState](sim.players.len)
        prevInputs = newSeq[InputState](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
          let previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = decodeInputMask(currentMask)
          prevInputs[playerIndex] = decodeInputMask(previousMask)
          appState.lastAppliedMasks[websocket] = currentMask
          sockets.add(websocket)
          playerIndices.add(playerIndex)

    sim.step(inputs, prevInputs)

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
    else: discard
  runServerLoop(address, port)

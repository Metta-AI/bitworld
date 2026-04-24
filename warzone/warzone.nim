import mummy
import protocol, server
import std/[locks, math, monotimes, os, parseopt, random, strutils, tables, times]

const
  TargetFps = 24.0
  WebSocketPath = "/ws"
  BackgroundColor = 0'u8
  GroundColor = 9'u8
  SkyColor = 12'u8
  HorizonY = ScreenHeight div 2
  CrosshairColor = 2'u8

  ArenaSize = 800.0
  TankSpeed = 3.0
  TankTurnSpeed = 0.06
  TankRadius = 8.0
  TankHp = 5
  RespawnTicks = 72
  InvulnTicks = 48

  ProjectileSpeed = 8.0
  ProjectileLifetime = 60
  ProjectileRadius = 2.0
  ShootCooldown = 12

  ObstacleCount = 20
  ObstacleMinSize = 10.0
  ObstacleMaxSize = 25.0
  ObstacleMinHeight = 12.0
  ObstacleMaxHeight = 30.0

  CameraHeight = 6.0
  FovHalf = PI / 4.0
  NearClip = 1.0
  FarClip = 300.0

  PlayerColors = [10'u8, 3, 13, 8, 7, 14, 4, 11]

type
  Vec2 = object
    x, y: float

  Tank = object
    pos: Vec2
    angle: float
    hp: int
    kills: int
    color: uint8
    shootCooldown: int
    respawnTimer: int
    invulnTimer: int

  Projectile = object
    pos: Vec2
    vel: Vec2
    owner: int
    life: int

  Obstacle = object
    pos: Vec2
    halfW, halfH: float
    height: float

  SimServer = object
    tanks: seq[Tank]
    projectiles: seq[Projectile]
    obstacles: seq[Obstacle]
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
  getCurrentDir() / ".." / "client" / "data"

proc loadClientPalette() =
  loadPalette(clientDataDir() / "pallete.png")

proc loadClientDigitSprites(): array[10, Sprite] =
  loadDigitSprites(clientDataDir() / "numbers.png")

proc loadClientLetterSprites(): seq[Sprite] =
  loadLetterSprites(clientDataDir() / "letters.png")

proc vec2(x, y: float): Vec2 = Vec2(x: x, y: y)

proc dist(a, b: Vec2): float =
  let dx = a.x - b.x
  let dy = a.y - b.y
  sqrt(dx * dx + dy * dy)

proc drawLine(fb: var Framebuffer, x0, y0, x1, y1: int, color: uint8) =
  var
    dx = abs(x1 - x0)
    dy = abs(y1 - y0)
    sx = if x0 < x1: 1 else: -1
    sy = if y0 < y1: 1 else: -1
    err = dx - dy
    cx = x0
    cy = y0
  while true:
    fb.putPixel(cx, cy, color)
    if cx == x1 and cy == y1:
      break
    let e2 = 2 * err
    if e2 > -dy:
      err -= dy
      cx += sx
    if e2 < dx:
      err += dx
      cy += sy

proc worldToScreen(sim: SimServer, viewerPos: Vec2, viewerAngle: float, worldPos: Vec2, height: float): tuple[sx, sy: int, depth: float, vis: bool] =
  let
    dx = worldPos.x - viewerPos.x
    dy = worldPos.y - viewerPos.y
    cosA = cos(viewerAngle)
    sinA = sin(viewerAngle)
    localX = dx * cosA + dy * sinA
    localZ = -dx * sinA + dy * cosA

  if localZ < NearClip:
    return (0, 0, 0.0, false)
  if localZ > FarClip:
    return (0, 0, 0.0, false)

  let
    screenX = ScreenWidth div 2 + int(localX / localZ * (ScreenWidth.float / 2.0) / tan(FovHalf))
    screenY = HorizonY - int((height - CameraHeight) / localZ * (ScreenHeight.float / 2.0))

  (screenX, screenY, localZ, true)

proc projectCorner(sim: SimServer, viewerPos: Vec2, viewerAngle: float, wx, wy, h: float): tuple[sx, sy: int, depth: float, vis: bool] =
  sim.worldToScreen(viewerPos, viewerAngle, vec2(wx, wy), h)

proc renderGround(fb: var Framebuffer) =
  for y in 0 ..< HorizonY:
    for x in 0 ..< ScreenWidth:
      fb.putPixel(x, y, SkyColor)
  for y in HorizonY ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      fb.putPixel(x, y, GroundColor)

proc renderGridLines(fb: var Framebuffer, viewerPos: Vec2, viewerAngle: float) =
  let gridSpacing = 50.0
  let gridColor = 5'u8
  let cosA = cos(viewerAngle)
  let sinA = sin(viewerAngle)

  for i in -8 .. 8:
    let offset = i.float * gridSpacing
    let snappedX = round(viewerPos.x / gridSpacing) * gridSpacing + offset
    let snappedY = round(viewerPos.y / gridSpacing) * gridSpacing + offset

    # Lines parallel to Y axis (at snappedX)
    var prevSx, prevSy: int
    var prevVis = false
    for j in -4 .. 4:
      let wy = viewerPos.y + j.float * gridSpacing
      let dx = snappedX - viewerPos.x
      let dy = wy - viewerPos.y
      let localZ = -dx * sinA + dy * cosA
      let localX = dx * cosA + dy * sinA
      if localZ > NearClip and localZ < FarClip:
        let sx = ScreenWidth div 2 + int(localX / localZ * (ScreenWidth.float / 2.0) / tan(FovHalf))
        let sy = HorizonY + int(0.0 / localZ * (ScreenHeight.float / 2.0))
        if prevVis:
          fb.drawLine(prevSx, prevSy, sx, sy, gridColor)
        prevSx = sx
        prevSy = sy
        prevVis = true
      else:
        prevVis = false

    # Lines parallel to X axis (at snappedY)
    prevVis = false
    for j in -4 .. 4:
      let wx = viewerPos.x + j.float * gridSpacing
      let dx = wx - viewerPos.x
      let dy = snappedY - viewerPos.y
      let localZ = -dx * sinA + dy * cosA
      let localX = dx * cosA + dy * sinA
      if localZ > NearClip and localZ < FarClip:
        let sx = ScreenWidth div 2 + int(localX / localZ * (ScreenWidth.float / 2.0) / tan(FovHalf))
        let sy = HorizonY + int(0.0 / localZ * (ScreenHeight.float / 2.0))
        if prevVis:
          fb.drawLine(prevSx, prevSy, sx, sy, gridColor)
        prevSx = sx
        prevSy = sy
        prevVis = true
      else:
        prevVis = false

proc renderObstacle(fb: var Framebuffer, sim: SimServer, viewerPos: Vec2, viewerAngle: float, obs: Obstacle) =
  let
    ox = obs.pos.x
    oy = obs.pos.y
    hw = obs.halfW
    hh = obs.halfH
    h = obs.height
    obstColor = 1'u8

  var
    corners: array[4, tuple[x, y: float]]
    topPts: array[4, tuple[sx, sy: int, depth: float, vis: bool]]
    botPts: array[4, tuple[sx, sy: int, depth: float, vis: bool]]

  corners[0] = (ox - hw, oy - hh)
  corners[1] = (ox + hw, oy - hh)
  corners[2] = (ox + hw, oy + hh)
  corners[3] = (ox - hw, oy + hh)

  for i in 0 ..< 4:
    topPts[i] = sim.projectCorner(viewerPos, viewerAngle, corners[i].x, corners[i].y, h)
    botPts[i] = sim.projectCorner(viewerPos, viewerAngle, corners[i].x, corners[i].y, 0.0)

  for i in 0 ..< 4:
    let j = (i + 1) mod 4
    if topPts[i].vis and topPts[j].vis:
      fb.drawLine(topPts[i].sx, topPts[i].sy, topPts[j].sx, topPts[j].sy, obstColor)
    if botPts[i].vis and botPts[j].vis:
      fb.drawLine(botPts[i].sx, botPts[i].sy, botPts[j].sx, botPts[j].sy, obstColor)
    if topPts[i].vis and botPts[i].vis:
      fb.drawLine(topPts[i].sx, topPts[i].sy, botPts[i].sx, botPts[i].sy, obstColor)

proc renderTank(fb: var Framebuffer, sim: SimServer, viewerPos: Vec2, viewerAngle: float, tank: Tank) =
  if tank.respawnTimer > 0:
    return
  if tank.invulnTimer > 0 and (sim.tickCount mod 4) < 2:
    return

  let
    color = tank.color
    cosT = cos(tank.angle)
    sinT = sin(tank.angle)
    hw = 4.0
    hh = 5.0
    bodyH = 4.0
    turretH = 6.0
    barrelLen = 7.0
    barrelH = 5.5

  var corners: array[4, Vec2]
  corners[0] = vec2(tank.pos.x + (-hw) * cosT - (-hh) * sinT, tank.pos.y + (-hw) * sinT + (-hh) * cosT)
  corners[1] = vec2(tank.pos.x + ( hw) * cosT - (-hh) * sinT, tank.pos.y + ( hw) * sinT + (-hh) * cosT)
  corners[2] = vec2(tank.pos.x + ( hw) * cosT - ( hh) * sinT, tank.pos.y + ( hw) * sinT + ( hh) * cosT)
  corners[3] = vec2(tank.pos.x + (-hw) * cosT - ( hh) * sinT, tank.pos.y + (-hw) * sinT + ( hh) * cosT)

  var
    topPts: array[4, tuple[sx, sy: int, depth: float, vis: bool]]
    botPts: array[4, tuple[sx, sy: int, depth: float, vis: bool]]

  for i in 0 ..< 4:
    topPts[i] = sim.worldToScreen(viewerPos, viewerAngle, corners[i], bodyH)
    botPts[i] = sim.worldToScreen(viewerPos, viewerAngle, corners[i], 0.0)

  for i in 0 ..< 4:
    let j = (i + 1) mod 4
    if topPts[i].vis and topPts[j].vis:
      fb.drawLine(topPts[i].sx, topPts[i].sy, topPts[j].sx, topPts[j].sy, color)
    if botPts[i].vis and botPts[j].vis:
      fb.drawLine(botPts[i].sx, botPts[i].sy, botPts[j].sx, botPts[j].sy, color)
    if topPts[i].vis and botPts[i].vis:
      fb.drawLine(topPts[i].sx, topPts[i].sy, botPts[i].sx, botPts[i].sy, color)

  let
    turretTop = sim.worldToScreen(viewerPos, viewerAngle, tank.pos, turretH)
    turretBot = sim.worldToScreen(viewerPos, viewerAngle, tank.pos, bodyH)
  if turretTop.vis and turretBot.vis:
    fb.drawLine(turretTop.sx - 1, turretTop.sy, turretTop.sx + 1, turretTop.sy, color)
    fb.drawLine(turretBot.sx - 1, turretBot.sy, turretBot.sx + 1, turretBot.sy, color)
    fb.drawLine(turretTop.sx - 1, turretTop.sy, turretBot.sx - 1, turretBot.sy, color)
    fb.drawLine(turretTop.sx + 1, turretTop.sy, turretBot.sx + 1, turretBot.sy, color)

  let barrelEnd = vec2(
    tank.pos.x + barrelLen * cosT,
    tank.pos.y + barrelLen * sinT
  )
  let
    bEnd = sim.worldToScreen(viewerPos, viewerAngle, barrelEnd, barrelH)
    bStart = sim.worldToScreen(viewerPos, viewerAngle, tank.pos, barrelH)
  if bEnd.vis and bStart.vis:
    fb.drawLine(bStart.sx, bStart.sy, bEnd.sx, bEnd.sy, color)

proc renderProjectile(fb: var Framebuffer, sim: SimServer, viewerPos: Vec2, viewerAngle: float, proj: Projectile, color: uint8) =
  let pt = sim.worldToScreen(viewerPos, viewerAngle, proj.pos, 4.0)
  if pt.vis:
    let sz = max(1, int(3.0 / pt.depth * 20.0))
    for dy in -sz .. sz:
      for dx in -sz .. sz:
        if dx * dx + dy * dy <= sz * sz:
          fb.putPixel(pt.sx + dx, pt.sy + dy, color)

proc renderCrosshair(fb: var Framebuffer) =
  let cx = ScreenWidth div 2
  let cy = HorizonY
  fb.putPixel(cx, cy - 2, CrosshairColor)
  fb.putPixel(cx, cy + 2, CrosshairColor)
  fb.putPixel(cx - 2, cy, CrosshairColor)
  fb.putPixel(cx + 2, cy, CrosshairColor)

proc renderNumber(fb: var Framebuffer, digitSprites: array[10, Sprite], value, screenX, screenY: int) =
  let text = $max(0, value)
  var x = screenX
  for ch in text:
    let digit = ord(ch) - ord('0')
    fb.blitSprite(digitSprites[digit], x, screenY, 0, 0)
    x += digitSprites[digit].width

proc renderHud(fb: var Framebuffer, digitSprites: array[10, Sprite], letterSprites: seq[Sprite], tank: Tank) =
  for i in 0 ..< TankHp:
    let x = 1 + i * 3
    let color: uint8 = if i < tank.hp: 10 else: 1
    fb.putPixel(x, 1, color)
    fb.putPixel(x + 1, 1, color)
    fb.putPixel(x, 2, color)
    fb.putPixel(x + 1, 2, color)

  let killX = ScreenWidth - 1 - 6
  var text = $tank.kills
  var x = killX
  for ch in text:
    let digit = ord(ch) - ord('0')
    fb.blitSprite(digitSprites[digit], x, 1, 0, 0)
    x += digitSprites[digit].width

proc renderMinimap(fb: var Framebuffer, sim: SimServer, viewerIdx: int) =
  let
    mapSize = 16
    mapX = ScreenWidth - mapSize - 1
    mapY = ScreenHeight - mapSize - 1
    viewer = sim.tanks[viewerIdx]
    scale = mapSize.float / ArenaSize

  for y in mapY .. mapY + mapSize:
    fb.putPixel(mapX - 1, y, 1)
    fb.putPixel(mapX + mapSize, y, 1)
  for x in mapX .. mapX + mapSize:
    fb.putPixel(x, mapY - 1, 1)
    fb.putPixel(x, mapY + mapSize, 1)

  for obs in sim.obstacles:
    let
      ox = mapX + int(obs.pos.x * scale)
      oy = mapY + int(obs.pos.y * scale)
    fb.putPixel(ox, oy, 1)

  for i, tank in sim.tanks:
    if tank.respawnTimer > 0:
      continue
    let
      tx = mapX + int(tank.pos.x * scale)
      ty = mapY + int(tank.pos.y * scale)
    fb.putPixel(tx, ty, tank.color)

  let
    fx = int(-sin(viewer.angle) * 2.0)
    fy = int(cos(viewer.angle) * 2.0)
    vx = mapX + int(viewer.pos.x * scale)
    vy = mapY + int(viewer.pos.y * scale)
  fb.putPixel(vx + fx, vy + fy, 2)

proc findSpawn(sim: var SimServer): Vec2 =
  let margin = 30.0
  for _ in 0 ..< 200:
    let
      x = margin + sim.rng.rand(ArenaSize - 2 * margin)
      y = margin + sim.rng.rand(ArenaSize - 2 * margin)
      pos = vec2(x, y)
    var ok = true
    for obs in sim.obstacles:
      if dist(pos, obs.pos) < max(obs.halfW, obs.halfH) + TankRadius + 5.0:
        ok = false
        break
    if ok:
      for tank in sim.tanks:
        if tank.respawnTimer == 0 and dist(pos, tank.pos) < 60.0:
          ok = false
          break
    if ok:
      return pos
  vec2(ArenaSize / 2.0, ArenaSize / 2.0)

proc initSimServer(): SimServer =
  result.rng = initRand(0xDEAD)
  result.fb = initFramebuffer()
  loadClientPalette()
  result.digitSprites = loadClientDigitSprites()
  result.letterSprites = loadClientLetterSprites()

  let margin = 40.0
  for _ in 0 ..< ObstacleCount:
    for _ in 0 ..< 50:
      let
        x = margin + result.rng.rand(ArenaSize - 2 * margin)
        y = margin + result.rng.rand(ArenaSize - 2 * margin)
        hw = ObstacleMinSize / 2.0 + result.rng.rand(ObstacleMaxSize - ObstacleMinSize) / 2.0
        hh = ObstacleMinSize / 2.0 + result.rng.rand(ObstacleMaxSize - ObstacleMinSize) / 2.0
        h = ObstacleMinHeight + result.rng.rand(ObstacleMaxHeight - ObstacleMinHeight)
      var ok = true
      for obs in result.obstacles:
        if dist(vec2(x, y), obs.pos) < max(hw, hh) + max(obs.halfW, obs.halfH) + 10.0:
          ok = false
          break
      if ok:
        result.obstacles.add Obstacle(pos: vec2(x, y), halfW: hw, halfH: hh, height: h)
        break

proc addPlayer(sim: var SimServer): int =
  let
    spawn = sim.findSpawn()
    colorIdx = sim.tanks.len mod PlayerColors.len
  sim.tanks.add Tank(
    pos: spawn,
    angle: sim.rng.rand(2.0 * PI),
    hp: TankHp,
    color: PlayerColors[colorIdx],
  )
  sim.tanks.high

proc rectContains(obs: Obstacle, pos: Vec2, radius: float): bool =
  pos.x + radius > obs.pos.x - obs.halfW and
  pos.x - radius < obs.pos.x + obs.halfW and
  pos.y + radius > obs.pos.y - obs.halfH and
  pos.y - radius < obs.pos.y + obs.halfH

proc tryMove(sim: SimServer, pos: Vec2, newPos: Vec2, radius: float): Vec2 =
  result = newPos
  if result.x - radius < 0: result.x = radius
  if result.y - radius < 0: result.y = radius
  if result.x + radius > ArenaSize: result.x = ArenaSize - radius
  if result.y + radius > ArenaSize: result.y = ArenaSize - radius

  for obs in sim.obstacles:
    if obs.rectContains(result, radius):
      let tryX = vec2(result.x, pos.y)
      let tryY = vec2(pos.x, result.y)
      if not obs.rectContains(tryX, radius):
        result = tryX
      elif not obs.rectContains(tryY, radius):
        result = tryY
      else:
        result = pos

proc applyInput(sim: var SimServer, tankIdx: int, input: InputState) =
  if tankIdx < 0 or tankIdx >= sim.tanks.len:
    return
  template tank: untyped = sim.tanks[tankIdx]

  if tank.respawnTimer > 0:
    dec tank.respawnTimer
    if tank.respawnTimer == 0:
      tank.pos = sim.findSpawn()
      tank.angle = sim.rng.rand(2.0 * PI)
      tank.hp = TankHp
      tank.invulnTimer = InvulnTicks
    return

  if tank.invulnTimer > 0:
    dec tank.invulnTimer

  if tank.shootCooldown > 0:
    dec tank.shootCooldown

  if input.left:
    tank.angle += TankTurnSpeed
  if input.right:
    tank.angle -= TankTurnSpeed

  var speed = 0.0
  if input.up:
    speed = TankSpeed
  elif input.down:
    speed = -TankSpeed * 0.6

  if speed != 0.0:
    let newPos = vec2(
      tank.pos.x - sin(tank.angle) * speed,
      tank.pos.y + cos(tank.angle) * speed
    )
    tank.pos = sim.tryMove(tank.pos, newPos, TankRadius)

  if input.attack and tank.shootCooldown == 0:
    tank.shootCooldown = ShootCooldown
    let muzzleOffset = 8.0
    sim.projectiles.add Projectile(
      pos: vec2(
        tank.pos.x - sin(tank.angle) * muzzleOffset,
        tank.pos.y + cos(tank.angle) * muzzleOffset
      ),
      vel: vec2(
        -sin(tank.angle) * ProjectileSpeed,
        cos(tank.angle) * ProjectileSpeed
      ),
      owner: tankIdx,
      life: ProjectileLifetime
    )

proc updateProjectiles(sim: var SimServer) =
  var alive: seq[Projectile]
  for proj in sim.projectiles.mitems:
    proj.pos.x += proj.vel.x
    proj.pos.y += proj.vel.y
    dec proj.life

    if proj.life <= 0 or proj.pos.x < 0 or proj.pos.y < 0 or
       proj.pos.x > ArenaSize or proj.pos.y > ArenaSize:
      continue

    var hitObstacle = false
    for obs in sim.obstacles:
      if obs.rectContains(proj.pos, ProjectileRadius):
        hitObstacle = true
        break
    if hitObstacle:
      continue

    var hitTank = false
    for i in 0 ..< sim.tanks.len:
      if i == proj.owner:
        continue
      if sim.tanks[i].respawnTimer > 0 or sim.tanks[i].invulnTimer > 0:
        continue
      if dist(proj.pos, sim.tanks[i].pos) < TankRadius + ProjectileRadius:
        dec sim.tanks[i].hp
        if sim.tanks[i].hp <= 0:
          sim.tanks[i].respawnTimer = RespawnTicks
          if proj.owner >= 0 and proj.owner < sim.tanks.len:
            inc sim.tanks[proj.owner].kills
        hitTank = true
        break
    if hitTank:
      continue

    alive.add proj
  sim.projectiles = alive

proc buildFramePacket(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(BackgroundColor)
  if playerIndex < 0 or playerIndex >= sim.tanks.len:
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let tank = sim.tanks[playerIndex]

  if tank.respawnTimer > 0:
    sim.fb.renderGround()
    let secs = (tank.respawnTimer + TargetFps.int - 1) div TargetFps.int
    sim.fb.blitText(sim.letterSprites, "DESTROYED", 7, 24)
    sim.fb.renderNumber(sim.digitSprites, secs, 29, 34)
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let
    viewerPos = tank.pos
    viewerAngle = tank.angle

  sim.fb.renderGround()
  sim.fb.renderGridLines(viewerPos, viewerAngle)

  for obs in sim.obstacles:
    sim.fb.renderObstacle(sim, viewerPos, viewerAngle, obs)

  for i in 0 ..< sim.tanks.len:
    if i == playerIndex:
      continue
    sim.fb.renderTank(sim, viewerPos, viewerAngle, sim.tanks[i])

  for proj in sim.projectiles:
    let color = if proj.owner >= 0 and proj.owner < sim.tanks.len:
      sim.tanks[proj.owner].color
    else: 2'u8
    sim.fb.renderProjectile(sim, viewerPos, viewerAngle, proj, color)

  sim.fb.renderCrosshair()
  sim.fb.renderHud(sim.digitSprites, sim.letterSprites, tank)
  sim.fb.renderMinimap(sim, playerIndex)

  sim.fb.packFramebuffer()
  sim.fb.packed

proc step(sim: var SimServer, inputs: openArray[InputState]) =
  inc sim.tickCount
  for i in 0 ..< sim.tanks.len:
    let input =
      if i < inputs.len: inputs[i]
      else: InputState()
    sim.applyInput(i, input)
  sim.updateProjectiles()

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
  if removedIndex >= 0 and removedIndex < sim.tanks.len:
    sim.tanks.delete(removedIndex)
    # Fix projectile owner indices
    var aliveProjectiles: seq[Projectile]
    for proj in sim.projectiles:
      var p = proj
      if p.owner == removedIndex:
        continue
      if p.owner > removedIndex:
        dec p.owner
      aliveProjectiles.add p
    sim.projectiles = aliveProjectiles
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc httpHandler(request: Request) =
  if request.uri == WebSocketPath and request.httpMethod == "GET":
    discard request.upgradeToWebSocket()
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Warzone server")

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
    wsNoDelay = true
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

        inputs = newSeq[InputState](sim.tanks.len)
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
      try:
        port = parseInt(key)
      except ValueError:
        address = key
    else: discard
  runServerLoop(address, port)

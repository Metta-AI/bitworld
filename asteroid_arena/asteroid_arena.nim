import mummy
import int_math, protocol, reward_protocol, server
import std/[locks, monotimes, os, parseopt, random, strutils, tables, times]

const
  MotionScale = 256
  WorldWidthPixels = 256
  WorldHeightPixels = 256
  WorldWidthUnits = WorldWidthPixels * MotionScale
  WorldHeightUnits = WorldHeightPixels * MotionScale

  DirectionScale = 256
  DirectionCount = 16
  DirectionX: array[DirectionCount, int] = [
    0, 98, 181, 236, 256, 236, 181, 98,
    0, -98, -181, -236, -256, -236, -181, -98
  ]
  DirectionY: array[DirectionCount, int] = [
    -256, -236, -181, -98, 0, 98, 181, 236,
    256, 236, 181, 98, 0, -98, -181, -236
  ]

  ShipCollisionRadius = 2
  ShipNoseOffsetPixels = 3
  ShipTailOffsetPixels = 2
  ShipWingOffsetPixels = 2
  ShipThrust = 36
  ReverseThrust = 20
  PassiveDragNum = 252
  PassiveDragDen = 256
  BrakeDragNum = 208
  BrakeDragDen = 256
  StopThreshold = 6
  ShipMaxSpeed = 450
  FireCooldownTicks = 7
  BulletLifeTicks = 36
  BulletSpeed = 704
  BulletRadiusPixels = 1
  MaxBulletsPerPlayer = 6
  RespawnDelayTicks = 42
  SpawnInvulnTicks = 30
  ThrustVisualTicks = 2

  InitialLargeAsteroids = 6
  TargetAsteroidValue = 54
  AsteroidSpawnCooldownTicks = 18
  SpawnSafeDistancePixels = 40
  AsteroidSafeDistancePixels = 32
  ShipKillScore = 5

  FpsScale = 1000
  TargetFps = 24 * FpsScale
  WebSocketPath = "/player"

  BackgroundColor = 12'u8
  HudBackdropColor = 1'u8
  HudBorderColor = 15'u8
  AsteroidFillColor = 13'u8
  AsteroidOutlineColor = 15'u8
  ThrusterColor = 8'u8
  BulletFlashColor = 2'u8
  ShieldColor = 11'u8
  ExplosionCoreColor = 2'u8
  StarColors = [13'u8, 15'u8, 2'u8]
  PlayerColors = [3'u8, 4'u8, 6'u8, 7'u8, 8'u8, 9'u8, 10'u8, 11'u8, 13'u8, 14'u8, 15'u8]

type
  AsteroidSize = enum
    AsteroidSmall
    AsteroidMedium
    AsteroidLarge

  Asteroid = object
    id: int
    x: int
    y: int
    velX: int
    velY: int
    size: AsteroidSize
    rotation: int
    spin: int
    seed: uint32

  Bullet = object
    ownerId: int
    x: int
    y: int
    velX: int
    velY: int
    ttl: int
    color: uint8

  Explosion = object
    x: int
    y: int
    ttl: int
    maxTtl: int
    radius: int
    color: uint8

  Star = object
    x: int
    y: int
    color: uint8

  Player = object
    id: int
    color: uint8
    x: int
    y: int
    velX: int
    velY: int
    facing: int
    score: int
    fireCooldown: int
    respawnTicks: int
    invulnTicks: int
    thrustTicks: int
    alive: bool

  PlayerInput = object
    turnLeft: bool
    turnRight: bool
    thrust: bool
    reverse: bool
    fireHeld: bool
    brakeHeld: bool

  SimServer = object
    players: seq[Player]
    asteroids: seq[Asteroid]
    bullets: seq[Bullet]
    explosions: seq[Explosion]
    stars: seq[Star]
    digitSprites: array[10, Sprite]
    letterSprites: seq[Sprite]
    fb: Framebuffer
    rng: Rand
    nextPlayerId: int
    nextAsteroidId: int
    asteroidSpawnCooldown: int

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

var appState: WebSocketAppState

proc repoDir(): string =
  getCurrentDir() / ".."

proc clientDataDir(): string =
  repoDir() / "client" / "data"

proc palettePath(): string =
  clientDataDir() / "pallete.png"

proc numbersPath(): string =
  clientDataDir() / "numbers.png"

proc lettersPath(): string =
  clientDataDir() / "letters.png"

proc signOf(value: int): int =
  if value < 0:
    -1
  elif value > 0:
    1
  else:
    0

proc normalizedDirection(value: int): int =
  var wrapped = value mod DirectionCount
  if wrapped < 0:
    wrapped += DirectionCount
  wrapped

proc forwardX(direction: int): int =
  DirectionX[normalizedDirection(direction)]

proc forwardY(direction: int): int =
  DirectionY[normalizedDirection(direction)]

proc sideX(direction: int): int =
  DirectionX[normalizedDirection(direction + DirectionCount div 4)]

proc sideY(direction: int): int =
  DirectionY[normalizedDirection(direction + DirectionCount div 4)]

proc asteroidRadius(size: AsteroidSize): int =
  case size
  of AsteroidSmall: 2
  of AsteroidMedium: 4
  of AsteroidLarge: 6

proc asteroidValue(size: AsteroidSize): int =
  case size
  of AsteroidSmall: 1
  of AsteroidMedium: 3
  of AsteroidLarge: 9

proc asteroidScore(size: AsteroidSize): int =
  case size
  of AsteroidSmall: 1
  of AsteroidMedium: 2
  of AsteroidLarge: 4

proc fragmentCount(size: AsteroidSize): int =
  case size
  of AsteroidSmall: 0
  of AsteroidMedium: 2
  of AsteroidLarge: 3

proc fragmentSize(size: AsteroidSize): AsteroidSize =
  case size
  of AsteroidLarge: AsteroidMedium
  of AsteroidMedium: AsteroidSmall
  of AsteroidSmall: AsteroidSmall

proc fragmentKick(size: AsteroidSize): int =
  case size
  of AsteroidSmall: 88
  of AsteroidMedium: 60
  of AsteroidLarge: 44

proc asteroidSpeedRange(size: AsteroidSize): tuple[minSpeed, maxSpeed: int] =
  case size
  of AsteroidSmall:
    (68, 106)
  of AsteroidMedium:
    (46, 78)
  of AsteroidLarge:
    (30, 54)

proc fillRect(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  if w <= 0 or h <= 0:
    return
  for py in y ..< y + h:
    for px in x ..< x + w:
      fb.putPixel(px, py, color)

proc strokeRect(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  if w <= 0 or h <= 0:
    return
  for px in x ..< x + w:
    fb.putPixel(px, y, color)
    fb.putPixel(px, y + h - 1, color)
  for py in y ..< y + h:
    fb.putPixel(x, py, color)
    fb.putPixel(x + w - 1, py, color)

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

proc renderCenteredNumber(
  fb: var Framebuffer,
  digitSprites: array[10, Sprite],
  value, centerX, screenY: int
) =
  let text = $max(0, value)
  let width = text.len * digitSprites[0].width
  fb.renderNumber(digitSprites, value, centerX - width div 2, screenY)

proc renderCenteredText(sim: var SimServer, text: string, centerX, screenY: int) =
  let width = text.len * 6
  sim.fb.blitText(sim.letterSprites, text, centerX - width div 2, screenY)

proc drawLine(fb: var Framebuffer, x0, y0, x1, y1: int, color: uint8) =
  var
    currentX = x0
    currentY = y0
    dx = abs(x1 - x0)
    dy = -abs(y1 - y0)
    stepX = if x0 < x1: 1 else: -1
    stepY = if y0 < y1: 1 else: -1
    error = dx + dy

  while true:
    fb.putPixel(currentX, currentY, color)
    if currentX == x1 and currentY == y1:
      break
    let twiceError = error * 2
    if twiceError >= dy:
      error += dy
      currentX += stepX
    if twiceError <= dx:
      error += dx
      currentY += stepY

proc drawHSpan(fb: var Framebuffer, x0, x1, y: int, color: uint8) =
  let
    startX = min(x0, x1)
    endX = max(x0, x1)
  for x in startX .. endX:
    fb.putPixel(x, y, color)

proc plotCircleOctants(fb: var Framebuffer, cx, cy, x, y: int, color: uint8) =
  fb.putPixel(cx + x, cy + y, color)
  fb.putPixel(cx - x, cy + y, color)
  fb.putPixel(cx + x, cy - y, color)
  fb.putPixel(cx - x, cy - y, color)
  fb.putPixel(cx + y, cy + x, color)
  fb.putPixel(cx - y, cy + x, color)
  fb.putPixel(cx + y, cy - x, color)
  fb.putPixel(cx - y, cy - x, color)

proc drawCircleFill(fb: var Framebuffer, cx, cy, radius: int, color: uint8) =
  if radius <= 0:
    fb.putPixel(cx, cy, color)
    return

  var
    x = radius
    y = 0
    decision = 1 - radius
  while x >= y:
    fb.drawHSpan(cx - x, cx + x, cy + y, color)
    fb.drawHSpan(cx - x, cx + x, cy - y, color)
    fb.drawHSpan(cx - y, cx + y, cy + x, color)
    fb.drawHSpan(cx - y, cx + y, cy - x, color)
    inc y
    if decision < 0:
      decision += 2 * y + 1
    else:
      dec x
      decision += 2 * (y - x) + 1

proc drawCircleRing(fb: var Framebuffer, cx, cy, radius, thickness: int, color: uint8) =
  for ringRadius in countdown(radius, max(0, radius - thickness + 1)):
    var
      x = ringRadius
      y = 0
      decision = 1 - ringRadius
    while x >= y:
      fb.plotCircleOctants(cx, cy, x, y, color)
      inc y
      if decision < 0:
        decision += 2 * y + 1
      else:
        dec x
        decision += 2 * (y - x) + 1

proc applyDrag(value: var int, numerator, denominator: int) =
  value = (value * numerator) div denominator
  if abs(value) <= StopThreshold:
    value = 0

proc clampVelocity(velX, velY: var int, maxSpeed: int) =
  clampVectorLength(velX, velY, maxSpeed)

proc wrapAxis(value: var int, worldSize: int) =
  while value < 0:
    value += worldSize
  while value >= worldSize:
    value -= worldSize

proc wrapPosition(x, y: var int) =
  wrapAxis(x, WorldWidthUnits)
  wrapAxis(y, WorldHeightUnits)

proc wrappedDelta(value, center, worldSize: int): int =
  result = value - center
  let half = worldSize div 2
  if result > half:
    result -= worldSize
  elif result < -half:
    result += worldSize

proc wrappedDistanceSquared(ax, ay, bx, by: int): int =
  let
    dx = wrappedDelta(ax, bx, WorldWidthUnits)
    dy = wrappedDelta(ay, by, WorldHeightUnits)
  dx * dx + dy * dy

proc mixHash(value: uint32): uint32 =
  var x = value
  x = x xor (x shr 16)
  x *= 0x7feb352d'u32
  x = x xor (x shr 15)
  x *= 0x846ca68b'u32
  x xor (x shr 16)

proc randomPlayerColor(sim: var SimServer): uint8 =
  var available: seq[uint8] = @[]
  for color in PlayerColors:
    var used = false
    for player in sim.players:
      if player.color == color:
        used = true
        break
    if not used:
      available.add(color)

  if available.len == 0:
    return PlayerColors[sim.rng.rand(PlayerColors.high)]
  available[sim.rng.rand(available.high)]

proc addExplosion(
  sim: var SimServer,
  x, y, radius: int,
  color: uint8,
  ttl = 12
) =
  sim.explosions.add Explosion(
    x: x,
    y: y,
    ttl: ttl,
    maxTtl: ttl,
    radius: radius,
    color: color
  )

proc asteroidSpeed(sim: var SimServer, size: AsteroidSize): int =
  let range = asteroidSpeedRange(size)
  if range.maxSpeed <= range.minSpeed:
    return range.minSpeed
  range.minSpeed + sim.rng.rand(range.maxSpeed - range.minSpeed)

proc makeAsteroid(
  sim: var SimServer,
  size: AsteroidSize,
  x, y, velX, velY: int
): Asteroid =
  let spinRoll = sim.rng.rand(2)
  result = Asteroid(
    id: sim.nextAsteroidId,
    x: x,
    y: y,
    velX: velX,
    velY: velY,
    size: size,
    rotation: sim.rng.rand(7),
    spin:
      case spinRoll
      of 0: -1
      of 1: 0
      else: 1,
    seed: mixHash(uint32(sim.rng.rand(high(int))))
  )
  inc sim.nextAsteroidId
  wrapPosition(result.x, result.y)

proc totalAsteroidValue(sim: SimServer): int =
  for asteroid in sim.asteroids:
    result += asteroidValue(asteroid.size)

proc generateStars(sim: var SimServer) =
  for _ in 0 ..< 96:
    sim.stars.add Star(
      x: sim.rng.rand(WorldWidthPixels - 1),
      y: sim.rng.rand(WorldHeightPixels - 1),
      color: StarColors[sim.rng.rand(StarColors.high)]
    )

proc spawnRandomLargeAsteroid(sim: var SimServer): bool =
  let safeDistance = SpawnSafeDistancePixels * MotionScale
  for _ in 0 ..< 80:
    let
      x = sim.rng.rand(WorldWidthPixels - 1) * MotionScale
      y = sim.rng.rand(WorldHeightPixels - 1) * MotionScale
    var tooClose = false
    for player in sim.players:
      if not player.alive:
        continue
      if wrappedDistanceSquared(x, y, player.x, player.y) < safeDistance * safeDistance:
        tooClose = true
        break
    if tooClose:
      continue

    let
      direction = sim.rng.rand(DirectionCount - 1)
      speed = sim.asteroidSpeed(AsteroidLarge)
      velX = forwardX(direction) * speed div DirectionScale
      velY = forwardY(direction) * speed div DirectionScale
    sim.asteroids.add(sim.makeAsteroid(AsteroidLarge, x, y, velX, velY))
    return true
  false

proc playerIndexById(sim: SimServer, playerId: int): int =
  for i, player in sim.players:
    if player.id == playerId:
      return i
  -1

proc addScore(sim: var SimServer, playerId, points: int) =
  if playerId == 0 or points <= 0:
    return
  let playerIndex = sim.playerIndexById(playerId)
  if playerIndex >= 0:
    sim.players[playerIndex].score += points

proc spawnPointIsSafe(sim: SimServer, x, y: int): bool =
  let
    shipSafeDistance = SpawnSafeDistancePixels * MotionScale
    asteroidSafeDistance = AsteroidSafeDistancePixels * MotionScale
  for player in sim.players:
    if player.alive and wrappedDistanceSquared(x, y, player.x, player.y) < shipSafeDistance * shipSafeDistance:
      return false
  for asteroid in sim.asteroids:
    let radius = (asteroidRadius(asteroid.size) * MotionScale) + asteroidSafeDistance
    if wrappedDistanceSquared(x, y, asteroid.x, asteroid.y) < radius * radius:
      return false
  true

proc findSpawnPoint(sim: var SimServer): tuple[x, y: int, ok: bool] =
  for _ in 0 ..< 96:
    let
      x = sim.rng.rand(WorldWidthPixels - 1) * MotionScale
      y = sim.rng.rand(WorldHeightPixels - 1) * MotionScale
    if sim.spawnPointIsSafe(x, y):
      return (x, y, true)
  (0, 0, false)

proc respawnPlayer(sim: var SimServer, playerIndex: int): bool =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false

  let spawn = sim.findSpawnPoint()
  if not spawn.ok:
    return false

  sim.players[playerIndex].x = spawn.x
  sim.players[playerIndex].y = spawn.y
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0
  sim.players[playerIndex].alive = true
  sim.players[playerIndex].respawnTicks = 0
  sim.players[playerIndex].invulnTicks = SpawnInvulnTicks
  sim.players[playerIndex].fireCooldown = 0
  sim.players[playerIndex].thrustTicks = 0
  sim.players[playerIndex].facing = sim.rng.rand(DirectionCount - 1)
  true

proc addPlayer(sim: var SimServer): int =
  inc sim.nextPlayerId
  sim.players.add Player(
    id: sim.nextPlayerId,
    color: sim.randomPlayerColor(),
    facing: sim.rng.rand(DirectionCount - 1)
  )
  let playerIndex = sim.players.high
  if not sim.respawnPlayer(playerIndex):
    sim.players[playerIndex].respawnTicks = 1
  playerIndex

proc destroyShip(sim: var SimServer, playerIndex: int, killerId = 0) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if not sim.players[playerIndex].alive or sim.players[playerIndex].invulnTicks > 0:
    return

  let player = sim.players[playerIndex]
  sim.addExplosion(player.x, player.y, 7, player.color, ttl = 14)
  sim.players[playerIndex].alive = false
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0
  sim.players[playerIndex].respawnTicks = RespawnDelayTicks
  sim.players[playerIndex].invulnTicks = 0
  sim.players[playerIndex].fireCooldown = 0
  sim.players[playerIndex].thrustTicks = 0

  if killerId != 0 and killerId != player.id:
    sim.addScore(killerId, ShipKillScore)

proc bulletsForPlayer(sim: SimServer, playerId: int): int =
  for bullet in sim.bullets:
    if bullet.ownerId == playerId:
      inc result

proc tryFireBullet(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  let player = sim.players[playerIndex]
  if not player.alive or player.fireCooldown > 0:
    return
  if sim.bulletsForPlayer(player.id) >= MaxBulletsPerPlayer:
    return

  let
    noseDistance = (ShipNoseOffsetPixels + 1) * MotionScale
    muzzleX = player.x + forwardX(player.facing) * noseDistance div DirectionScale
    muzzleY = player.y + forwardY(player.facing) * noseDistance div DirectionScale
    bulletVelX = player.velX + forwardX(player.facing) * BulletSpeed div DirectionScale
    bulletVelY = player.velY + forwardY(player.facing) * BulletSpeed div DirectionScale
  sim.bullets.add Bullet(
    ownerId: player.id,
    x: muzzleX,
    y: muzzleY,
    velX: bulletVelX,
    velY: bulletVelY,
    ttl: BulletLifeTicks,
    color: player.color
  )
  sim.players[playerIndex].fireCooldown = FireCooldownTicks

proc initSimServer(seed: int): SimServer =
  result.rng = initRand(seed)
  result.fb = initFramebuffer()
  loadPalette(palettePath())
  result.digitSprites = loadDigitSprites(numbersPath())
  result.letterSprites = loadLetterSprites(lettersPath())
  result.generateStars()
  for _ in 0 ..< InitialLargeAsteroids:
    discard result.spawnRandomLargeAsteroid()

proc rockVertexRadius(asteroid: Asteroid, vertexIndex: int): int =
  let
    baseRadius = asteroidRadius(asteroid.size)
    wobble = max(1, baseRadius div 3)
    mixed = mixHash(asteroid.seed xor uint32(vertexIndex * 0x9E3779B9'u32.int))
    delta = int(mixed mod uint32(wobble * 2 + 1)) - wobble
  max(2, baseRadius + delta)

proc asteroidScreenPosition(
  asteroid: Asteroid,
  viewerX, viewerY: int
): tuple[x, y: int] =
  (
    ScreenWidth div 2 + wrappedDelta(asteroid.x, viewerX, WorldWidthUnits) div MotionScale,
    ScreenHeight div 2 + wrappedDelta(asteroid.y, viewerY, WorldHeightUnits) div MotionScale
  )

proc shipScreenPosition(
  player: Player,
  viewerX, viewerY: int
): tuple[x, y: int] =
  (
    ScreenWidth div 2 + wrappedDelta(player.x, viewerX, WorldWidthUnits) div MotionScale,
    ScreenHeight div 2 + wrappedDelta(player.y, viewerY, WorldHeightUnits) div MotionScale
  )

proc renderStars(sim: var SimServer, viewerX, viewerY: int) =
  let
    viewerPixelX = viewerX div MotionScale
    viewerPixelY = viewerY div MotionScale
  for star in sim.stars:
    let
      screenX = ScreenWidth div 2 + wrappedDelta(star.x, viewerPixelX, WorldWidthPixels)
      screenY = ScreenHeight div 2 + wrappedDelta(star.y, viewerPixelY, WorldHeightPixels)
    if screenX >= 0 and screenX < ScreenWidth and screenY >= 0 and screenY < ScreenHeight:
      sim.fb.putPixel(screenX, screenY, star.color)

proc renderAsteroid(sim: var SimServer, asteroid: Asteroid, viewerX, viewerY: int) =
  let
    radius = asteroidRadius(asteroid.size)
    center = asteroid.asteroidScreenPosition(viewerX, viewerY)
  if center.x < -radius - 2 or center.x >= ScreenWidth + radius + 2 or
      center.y < -radius - 2 or center.y >= ScreenHeight + radius + 2:
    return

  sim.fb.drawCircleFill(center.x, center.y, max(1, radius - 2), AsteroidFillColor)

  var
    firstX = 0
    firstY = 0
    previousX = 0
    previousY = 0
  for vertexIndex in 0 ..< 8:
    let
      direction = normalizedDirection((vertexIndex + asteroid.rotation) * 2)
      vertexRadius = asteroid.rockVertexRadius(vertexIndex)
      vertexX = center.x + forwardX(direction) * vertexRadius div DirectionScale
      vertexY = center.y + forwardY(direction) * vertexRadius div DirectionScale
    if vertexIndex == 0:
      firstX = vertexX
      firstY = vertexY
    else:
      sim.fb.drawLine(previousX, previousY, vertexX, vertexY, AsteroidOutlineColor)
    previousX = vertexX
    previousY = vertexY
  sim.fb.drawLine(previousX, previousY, firstX, firstY, AsteroidOutlineColor)

  let craterCount =
    case asteroid.size
    of AsteroidSmall: 1
    of AsteroidMedium: 2
    of AsteroidLarge: 3
  for craterIndex in 0 ..< craterCount:
    let
      mixed = mixHash(asteroid.seed xor uint32(craterIndex + 17))
      direction = normalizedDirection(int(mixed and 0xF))
      craterDistance = max(1, radius div 2)
      craterX = center.x + forwardX(direction) * craterDistance div DirectionScale
      craterY = center.y + forwardY(direction) * craterDistance div DirectionScale
    sim.fb.putPixel(craterX, craterY, BackgroundColor)

proc renderBullet(sim: var SimServer, bullet: Bullet, viewerX, viewerY: int) =
  let
    screenX = ScreenWidth div 2 + wrappedDelta(bullet.x, viewerX, WorldWidthUnits) div MotionScale
    screenY = ScreenHeight div 2 + wrappedDelta(bullet.y, viewerY, WorldHeightUnits) div MotionScale
  if screenX < 0 or screenX >= ScreenWidth or screenY < 0 or screenY >= ScreenHeight:
    return

  sim.fb.putPixel(screenX, screenY, bullet.color)
  if abs(bullet.velX) >= abs(bullet.velY):
    sim.fb.putPixel(screenX - signOf(bullet.velX), screenY, BulletFlashColor)
  else:
    sim.fb.putPixel(screenX, screenY - signOf(bullet.velY), BulletFlashColor)

proc renderShip(sim: var SimServer, player: Player, viewerX, viewerY: int) =
  if not player.alive:
    return
  if player.invulnTicks > 0 and ((player.invulnTicks div 2) mod 2 == 0):
    return

  let
    center = player.shipScreenPosition(viewerX, viewerY)
    fx = forwardX(player.facing)
    fy = forwardY(player.facing)
    sx = sideX(player.facing)
    sy = sideY(player.facing)
    noseX = center.x + fx * ShipNoseOffsetPixels div DirectionScale
    noseY = center.y + fy * ShipNoseOffsetPixels div DirectionScale
    tailX = center.x - fx * ShipTailOffsetPixels div DirectionScale
    tailY = center.y - fy * ShipTailOffsetPixels div DirectionScale
    leftX = tailX + sx * ShipWingOffsetPixels div DirectionScale
    leftY = tailY + sy * ShipWingOffsetPixels div DirectionScale
    rightX = tailX - sx * ShipWingOffsetPixels div DirectionScale
    rightY = tailY - sy * ShipWingOffsetPixels div DirectionScale

  if player.thrustTicks > 0:
    let
      flameX = center.x - fx * (ShipTailOffsetPixels + 2) div DirectionScale
      flameY = center.y - fy * (ShipTailOffsetPixels + 2) div DirectionScale
    sim.fb.drawLine(leftX, leftY, flameX, flameY, ThrusterColor)
    sim.fb.drawLine(rightX, rightY, flameX, flameY, ThrusterColor)

  sim.fb.drawLine(noseX, noseY, leftX, leftY, player.color)
  sim.fb.drawLine(leftX, leftY, rightX, rightY, player.color)
  sim.fb.drawLine(rightX, rightY, noseX, noseY, player.color)
  sim.fb.putPixel(center.x, center.y, BulletFlashColor)

  if player.invulnTicks > 0:
    sim.fb.drawCircleRing(center.x, center.y, ShipCollisionRadius + 2, 1, ShieldColor)

proc renderExplosion(sim: var SimServer, explosion: Explosion, viewerX, viewerY: int) =
  let
    centerX = ScreenWidth div 2 + wrappedDelta(explosion.x, viewerX, WorldWidthUnits) div MotionScale
    centerY = ScreenHeight div 2 + wrappedDelta(explosion.y, viewerY, WorldHeightUnits) div MotionScale
    elapsed = explosion.maxTtl - explosion.ttl
    ringRadius = max(1, 1 + (elapsed * explosion.radius) div max(1, explosion.maxTtl))
  if centerX < -ringRadius - 1 or centerX >= ScreenWidth + ringRadius + 1 or
      centerY < -ringRadius - 1 or centerY >= ScreenHeight + ringRadius + 1:
    return

  sim.fb.drawCircleRing(centerX, centerY, ringRadius, 1, explosion.color)
  if elapsed * 2 < explosion.maxTtl:
    sim.fb.putPixel(centerX, centerY, ExplosionCoreColor)

proc renderHud(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  let player = sim.players[playerIndex]
  sim.fb.fillRect(0, 0, 20, 8, HudBackdropColor)
  sim.fb.strokeRect(0, 0, 20, 8, HudBorderColor)
  sim.fb.renderNumber(sim.digitSprites, player.score, 2, 1)

  if not player.alive:
    let
      boxW = 52
      boxH = 18
      boxX = (ScreenWidth - boxW) div 2
      boxY = (ScreenHeight - boxH) div 2
      titleY = boxY + 3
      counterY = boxY + 10
    sim.fb.fillRect(boxX, boxY, boxW, boxH, HudBackdropColor)
    sim.fb.strokeRect(boxX, boxY, boxW, boxH, HudBorderColor)
    sim.renderCenteredText("RESPAWN", ScreenWidth div 2, titleY)
    if player.respawnTicks > 0:
      let seconds = 1 + (player.respawnTicks - 1) div 24
      sim.fb.renderCenteredNumber(
        sim.digitSprites,
        seconds,
        ScreenWidth div 2,
        counterY
      )
    else:
      sim.renderCenteredText("CLEAR", ScreenWidth div 2, counterY)
  elif player.invulnTicks > 0:
    sim.renderCenteredText("SAFE", ScreenWidth div 2, 1)

proc render(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(BackgroundColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let
    viewerX = sim.players[playerIndex].x
    viewerY = sim.players[playerIndex].y

  sim.renderStars(viewerX, viewerY)

  for asteroid in sim.asteroids:
    sim.renderAsteroid(asteroid, viewerX, viewerY)
  for explosion in sim.explosions:
    sim.renderExplosion(explosion, viewerX, viewerY)
  for bullet in sim.bullets:
    sim.renderBullet(bullet, viewerX, viewerY)
  for player in sim.players:
    sim.renderShip(player, viewerX, viewerY)

  sim.renderHud(playerIndex)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc rewardMetric(sim: SimServer, playerIndex: int): RewardMetric =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return RewardMetric(score: 0, auxValue: 0)
  let player = sim.players[playerIndex]
  let auxValue =
    if player.alive:
      1
    else:
      0
  RewardMetric(score: player.score, auxValue: auxValue)


proc buildAsteroidFragments(sim: var SimServer, asteroid: Asteroid): seq[Asteroid] =
  let
    count = fragmentCount(asteroid.size)
    childSize = fragmentSize(asteroid.size)
  if count <= 0:
    return @[]

  let
    parentRadius = asteroidRadius(asteroid.size)
    childRadius = asteroidRadius(childSize)
    offsetPixels = max(2, parentRadius - childRadius + 2)
    baseDirection = sim.rng.rand(DirectionCount - 1)
    kickBase = fragmentKick(childSize)

  for i in 0 ..< count:
    let
      direction = normalizedDirection(baseDirection + (i * DirectionCount) div count + sim.rng.rand(1))
      offsetUnits = offsetPixels * MotionScale
      offsetX = forwardX(direction) * offsetUnits div DirectionScale
      offsetY = forwardY(direction) * offsetUnits div DirectionScale
      kick = kickBase + sim.rng.rand(max(1, kickBase div 2))
      fragmentVelX = asteroid.velX + forwardX(direction) * kick div DirectionScale
      fragmentVelY = asteroid.velY + forwardY(direction) * kick div DirectionScale
    result.add(sim.makeAsteroid(
      childSize,
      asteroid.x + offsetX,
      asteroid.y + offsetY,
      fragmentVelX,
      fragmentVelY
    ))

proc stepPlayers(sim: var SimServer, inputs: openArray[PlayerInput]) =
  for playerIndex in 0 ..< sim.players.len:
    var player = sim.players[playerIndex]

    if player.fireCooldown > 0:
      dec player.fireCooldown
    if player.invulnTicks > 0:
      dec player.invulnTicks
    if player.thrustTicks > 0:
      dec player.thrustTicks

    let input =
      if playerIndex < inputs.len:
        inputs[playerIndex]
      else:
        PlayerInput()

    if not player.alive:
      if player.respawnTicks > 0:
        dec player.respawnTicks
      sim.players[playerIndex] = player
      continue

    if input.turnLeft and not input.turnRight:
      player.facing = normalizedDirection(player.facing - 1)
    elif input.turnRight and not input.turnLeft:
      player.facing = normalizedDirection(player.facing + 1)

    if input.thrust and not input.reverse:
      player.velX += forwardX(player.facing) * ShipThrust div DirectionScale
      player.velY += forwardY(player.facing) * ShipThrust div DirectionScale
      player.thrustTicks = ThrustVisualTicks
    elif input.reverse and not input.thrust:
      player.velX -= forwardX(player.facing) * ReverseThrust div DirectionScale
      player.velY -= forwardY(player.facing) * ReverseThrust div DirectionScale

    if input.brakeHeld:
      applyDrag(player.velX, BrakeDragNum, BrakeDragDen)
      applyDrag(player.velY, BrakeDragNum, BrakeDragDen)
    else:
      applyDrag(player.velX, PassiveDragNum, PassiveDragDen)
      applyDrag(player.velY, PassiveDragNum, PassiveDragDen)

    clampVelocity(player.velX, player.velY, ShipMaxSpeed)
    player.x += player.velX
    player.y += player.velY
    wrapPosition(player.x, player.y)

    sim.players[playerIndex] = player
    if input.fireHeld:
      sim.tryFireBullet(playerIndex)

proc stepAsteroids(sim: var SimServer) =
  for asteroid in sim.asteroids.mitems:
    asteroid.x += asteroid.velX
    asteroid.y += asteroid.velY
    wrapPosition(asteroid.x, asteroid.y)
    discard asteroid.spin

proc stepBullets(sim: var SimServer) =
  var activeBullets: seq[Bullet] = @[]
  for bullet in sim.bullets:
    var updated = bullet
    updated.x += updated.velX
    updated.y += updated.velY
    wrapPosition(updated.x, updated.y)
    dec updated.ttl
    if updated.ttl > 0:
      activeBullets.add(updated)
  sim.bullets = move(activeBullets)

proc resolveBulletCollisions(sim: var SimServer) =
  if sim.bullets.len == 0:
    return

  var
    bulletAlive = newSeq[bool](sim.bullets.len)
    asteroidAlive = newSeq[bool](sim.asteroids.len)
    fragments: seq[Asteroid] = @[]
  for i in 0 ..< bulletAlive.len:
    bulletAlive[i] = true
  for i in 0 ..< asteroidAlive.len:
    asteroidAlive[i] = true

  for bulletIndex, bullet in sim.bullets:
    if not bulletAlive[bulletIndex]:
      continue

    for asteroidIndex, asteroid in sim.asteroids:
      if not asteroidAlive[asteroidIndex]:
        continue
      let radius = (asteroidRadius(asteroid.size) + BulletRadiusPixels) * MotionScale
      if wrappedDistanceSquared(bullet.x, bullet.y, asteroid.x, asteroid.y) <= radius * radius:
        bulletAlive[bulletIndex] = false
        asteroidAlive[asteroidIndex] = false
        fragments.add(sim.buildAsteroidFragments(asteroid))
        sim.addExplosion(asteroid.x, asteroid.y, asteroidRadius(asteroid.size) + 5, AsteroidOutlineColor)
        sim.addScore(bullet.ownerId, asteroidScore(asteroid.size))
        break

    if not bulletAlive[bulletIndex]:
      continue

    for playerIndex, player in sim.players:
      if not player.alive or player.id == bullet.ownerId or player.invulnTicks > 0:
        continue
      let radius = (ShipCollisionRadius + BulletRadiusPixels + 1) * MotionScale
      if wrappedDistanceSquared(bullet.x, bullet.y, player.x, player.y) <= radius * radius:
        bulletAlive[bulletIndex] = false
        sim.destroyShip(playerIndex, bullet.ownerId)
        break

  var nextBullets: seq[Bullet] = @[]
  for i, bullet in sim.bullets:
    if bulletAlive[i]:
      nextBullets.add(bullet)
  sim.bullets = move(nextBullets)

  var nextAsteroids: seq[Asteroid] = @[]
  for i, asteroid in sim.asteroids:
    if asteroidAlive[i]:
      nextAsteroids.add(asteroid)
  for asteroid in fragments:
    nextAsteroids.add(asteroid)
  sim.asteroids = move(nextAsteroids)

proc resolveShipAsteroidCollisions(sim: var SimServer) =
  var crashed: seq[int] = @[]
  for playerIndex, player in sim.players:
    if not player.alive or player.invulnTicks > 0:
      continue
    for asteroid in sim.asteroids:
      let radius = (ShipCollisionRadius + asteroidRadius(asteroid.size)) * MotionScale
      if wrappedDistanceSquared(player.x, player.y, asteroid.x, asteroid.y) <= radius * radius:
        crashed.add(playerIndex)
        break
  for playerIndex in crashed:
    sim.destroyShip(playerIndex)

proc resolveShipShipCollisions(sim: var SimServer) =
  var crashFlags = newSeq[bool](sim.players.len)
  let crashRadius = (ShipCollisionRadius * 2) * MotionScale
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive or sim.players[i].invulnTicks > 0:
      continue
    for j in i + 1 ..< sim.players.len:
      if not sim.players[j].alive or sim.players[j].invulnTicks > 0:
        continue
      if wrappedDistanceSquared(sim.players[i].x, sim.players[i].y, sim.players[j].x, sim.players[j].y) <=
          crashRadius * crashRadius:
        crashFlags[i] = true
        crashFlags[j] = true
  for i in 0 ..< crashFlags.len:
    if crashFlags[i]:
      sim.destroyShip(i)

proc stepExplosions(sim: var SimServer) =
  var activeExplosions: seq[Explosion] = @[]
  for explosion in sim.explosions:
    var updated = explosion
    dec updated.ttl
    if updated.ttl > 0:
      activeExplosions.add(updated)
  sim.explosions = move(activeExplosions)

proc stepRespawns(sim: var SimServer) =
  for playerIndex in 0 ..< sim.players.len:
    if not sim.players[playerIndex].alive and sim.players[playerIndex].respawnTicks <= 0:
      discard sim.respawnPlayer(playerIndex)

proc ensureAsteroids(sim: var SimServer) =
  if sim.asteroidSpawnCooldown > 0:
    dec sim.asteroidSpawnCooldown
  if sim.totalAsteroidValue() >= TargetAsteroidValue or sim.asteroidSpawnCooldown > 0:
    return
  if sim.spawnRandomLargeAsteroid():
    sim.asteroidSpawnCooldown = AsteroidSpawnCooldownTicks

proc step(sim: var SimServer, inputs: openArray[PlayerInput]) =
  sim.stepPlayers(inputs)
  sim.stepAsteroids()
  sim.stepBullets()
  sim.resolveBulletCollisions()
  sim.resolveShipAsteroidCollisions()
  sim.resolveShipShipCollisions()
  sim.stepExplosions()
  sim.stepRespawns()
  sim.ensureAsteroids()

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.closedSockets = @[]
  appState.rewards = initRewardState()
  appState.resetRequested = false

proc playerInputFromMasks(currentMask, previousMask: uint8): PlayerInput =
  let decoded = decodeInputMask(currentMask)
  result.turnLeft = decoded.left
  result.turnRight = decoded.right
  result.thrust = decoded.up
  result.reverse = decoded.down
  result.fireHeld = decoded.attack
  result.brakeHeld = decoded.b

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket notin appState.playerIndices:
    return

  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  appState.rewards.detachRewardClient(websocket)

  if removedIndex >= 0 and removedIndex < sim.players.len:
    let removedPlayerId = sim.players[removedIndex].id
    sim.players.delete(removedIndex)

    var remainingBullets: seq[Bullet] = @[]
    for bullet in sim.bullets:
      if bullet.ownerId != removedPlayerId:
        remainingBullets.add(bullet)
    sim.bullets = move(remainingBullets)

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

proc runServerLoop(
  host = DefaultHost,
  port = DefaultPort,
  targetFps = TargetFps,
  seed = 0xA57E2
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
      inputs: seq[PlayerInput]
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

          inputs = newSeq[PlayerInput](sim.players.len)
          for websocket, playerIndex in appState.playerIndices.pairs:
            if playerIndex < 0 or playerIndex >= inputs.len:
              continue
            let
              currentMask = appState.inputMasks.getOrDefault(websocket, 0)
              previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
            inputs[playerIndex] = playerInputFromMasks(currentMask, previousMask)
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
    targetFps = TargetFps
    seed = 0xA57E2
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = val
      of "port":
        port = parseInt(val)
      of "fps":
        targetFps = parseInt(val) * FpsScale
      of "seed":
        seed = parseInt(val)
      else:
        discard
    else:
      discard
  runServerLoop(address, port, targetFps = targetFps, seed = seed)

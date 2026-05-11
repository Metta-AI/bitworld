import
  std/[random, strutils],
  ../common/protocol

type
  RgbaColor* = object
    r*: uint8
    g*: uint8
    b*: uint8
    a*: uint8

const
  MotionScale* = 256
  WorldWidthPixels* = 256
  WorldHeightPixels* = 256
  WorldWidthUnits* = WorldWidthPixels * MotionScale
  WorldHeightUnits* = WorldHeightPixels * MotionScale

  DirectionScale* = 256
  DirectionCount* = 16
  DirectionX*: array[DirectionCount, int] = [
    0, 98, 181, 236, 256, 236, 181, 98,
    0, -98, -181, -236, -256, -236, -181, -98
  ]
  DirectionY*: array[DirectionCount, int] = [
    -256, -236, -181, -98, 0, 98, 181, 236,
    256, 236, 181, 98, 0, -98, -181, -236
  ]

  ShipCollisionRadius* = 2
  ShipNoseOffsetPixels* = 3
  ShipTailOffsetPixels* = 2
  ShipWingOffsetPixels* = 2
  ShipThrust* = 36
  ReverseThrust* = 20
  PassiveDragNum* = 252
  PassiveDragDen* = 256
  BrakeDragNum* = 208
  BrakeDragDen* = 256
  StopThreshold* = 6
  ShipMaxSpeed* = 450
  FireCooldownTicks* = 7
  BulletLifeTicks* = 36
  BulletSpeed* = 704
  BulletRadiusPixels* = 1
  MaxBulletsPerPlayer* = 6
  RespawnDelayTicks* = 42
  SpawnInvulnTicks* = 30
  ThrustVisualTicks* = 2

  InitialLargeAsteroids* = 6
  TargetAsteroidValue* = 54
  AsteroidSpawnCooldownTicks* = 18
  SpawnSafeDistancePixels* = 40
  AsteroidSafeDistancePixels* = 32
  ShipKillScore* = 5

  TargetFps* = 24

  WebSocketPath* = "/player"
  SpritePlayerWebSocketPath* = "/sprite_player"
  GlobalWebSocketPath* = "/global"
  RewardWebSocketPath* = "/reward"

  BackgroundColor* = RgbaColor(r: 0x29, g: 0xAD, b: 0xFF, a: 255)
  AsteroidFillColor* = RgbaColor(r: 0x83, g: 0x76, b: 0x9C, a: 255)
  AsteroidOutlineColor* = RgbaColor(r: 0xFF, g: 0xCC, b: 0xAA, a: 255)
  ThrusterColor* = RgbaColor(r: 0xFF, g: 0x00, b: 0x4D, a: 255)
  BulletFlashColor* = RgbaColor(r: 0x7E, g: 0x25, b: 0x53, a: 255)
  ShieldColor* = RgbaColor(r: 0x00, g: 0xE4, b: 0x36, a: 255)
  ExplosionCoreColor* = RgbaColor(r: 0x7E, g: 0x25, b: 0x53, a: 255)
  HudBackdropColor* = RgbaColor(r: 0x1D, g: 0x2B, b: 0x53, a: 255)
  HudBorderColor* = RgbaColor(r: 0xFF, g: 0xCC, b: 0xAA, a: 255)
  StarColors* = [
    RgbaColor(r: 0x83, g: 0x76, b: 0x9C, a: 255),
    RgbaColor(r: 0xFF, g: 0xCC, b: 0xAA, a: 255),
    RgbaColor(r: 0x7E, g: 0x25, b: 0x53, a: 255)
  ]
  PlayerColors* = [
    RgbaColor(r: 0x00, g: 0x87, b: 0x51, a: 255),  # 3
    RgbaColor(r: 0xAB, g: 0x52, b: 0x36, a: 255),  # 4
    RgbaColor(r: 0xC2, g: 0xC3, b: 0xC7, a: 255),  # 6
    RgbaColor(r: 0xFF, g: 0xF1, b: 0xE8, a: 255),  # 7
    RgbaColor(r: 0xFF, g: 0x00, b: 0x4D, a: 255),  # 8
    RgbaColor(r: 0xFF, g: 0xA3, b: 0x00, a: 255),  # 9
    RgbaColor(r: 0xFF, g: 0xEC, b: 0x27, a: 255),  # 10
    RgbaColor(r: 0x00, g: 0xE4, b: 0x36, a: 255),  # 11
    RgbaColor(r: 0x83, g: 0x76, b: 0x9C, a: 255),  # 13
    RgbaColor(r: 0xFF, g: 0x77, b: 0xA8, a: 255),  # 14
    RgbaColor(r: 0xFF, g: 0xCC, b: 0xAA, a: 255)   # 15
  ]

  # Sprite protocol layer/object/sprite IDs
  MapLayerId* = 0
  MapLayerType* = 0
  TopLeftLayerId* = 1
  TopLeftLayerType* = 1
  ZoomableLayerFlag* = 1
  UiLayerFlag* = 2

type
  AsteroidSize* = enum
    AsteroidSmall
    AsteroidMedium
    AsteroidLarge

  Asteroid* = object
    id*: int
    x*: int
    y*: int
    velX*: int
    velY*: int
    size*: AsteroidSize
    rotation*: int
    spin*: int
    seed*: uint32

  Bullet* = object
    ownerId*: int
    x*: int
    y*: int
    velX*: int
    velY*: int
    ttl*: int
    color*: RgbaColor

  Explosion* = object
    x*: int
    y*: int
    ttl*: int
    maxTtl*: int
    radius*: int
    color*: RgbaColor

  Star* = object
    x*: int
    y*: int
    color*: RgbaColor

  Player* = object
    id*: int
    name*: string
    color*: RgbaColor
    x*: int
    y*: int
    velX*: int
    velY*: int
    facing*: int
    score*: int
    fireCooldown*: int
    respawnTicks*: int
    invulnTicks*: int
    thrustTicks*: int
    alive*: bool

  PlayerInput* = object
    turnLeft*: bool
    turnRight*: bool
    thrust*: bool
    reverse*: bool
    fireHeld*: bool
    brakeHeld*: bool

  SimServer* = object
    players*: seq[Player]
    asteroids*: seq[Asteroid]
    bullets*: seq[Bullet]
    explosions*: seq[Explosion]
    stars*: seq[Star]
    rng*: Rand
    nextPlayerId*: int
    nextAsteroidId*: int
    asteroidSpawnCooldown*: int
    tickCount*: int

proc roundDiv(numerator, denominator: int): int =
  if denominator <= 0:
    return 0
  if numerator >= 0:
    (numerator + denominator div 2) div denominator
  else:
    -((-numerator + denominator div 2) div denominator)

proc mulDivRound(a, b, denominator: int): int =
  roundDiv(a * b, denominator)

proc ceilSqrt(value: int): int =
  if value <= 0:
    return 0
  var
    x = value
    y = (x + 1) div 2
  while y < x:
    x = y
    y = (x + value div x) div 2
  result = x
  if result * result < value:
    inc result

proc clampVectorLength(x, y: var int, maxLength: int) =
  let lengthSq = x * x + y * y
  if lengthSq <= maxLength * maxLength:
    return
  let length = ceilSqrt(lengthSq)
  if length <= 0:
    return
  x = mulDivRound(x, maxLength, length)
  y = mulDivRound(y, maxLength, length)

proc signOf*(value: int): int =
  if value < 0:
    -1
  elif value > 0:
    1
  else:
    0

proc normalizedDirection*(value: int): int =
  var wrapped = value mod DirectionCount
  if wrapped < 0:
    wrapped += DirectionCount
  wrapped

proc forwardX*(direction: int): int =
  DirectionX[normalizedDirection(direction)]

proc forwardY*(direction: int): int =
  DirectionY[normalizedDirection(direction)]

proc sideX*(direction: int): int =
  DirectionX[normalizedDirection(direction + DirectionCount div 4)]

proc sideY*(direction: int): int =
  DirectionY[normalizedDirection(direction + DirectionCount div 4)]

proc asteroidRadius*(size: AsteroidSize): int =
  case size
  of AsteroidSmall: 2
  of AsteroidMedium: 4
  of AsteroidLarge: 6

proc asteroidValue*(size: AsteroidSize): int =
  case size
  of AsteroidSmall: 1
  of AsteroidMedium: 3
  of AsteroidLarge: 9

proc asteroidScore*(size: AsteroidSize): int =
  case size
  of AsteroidSmall: 1
  of AsteroidMedium: 2
  of AsteroidLarge: 4

proc fragmentCount*(size: AsteroidSize): int =
  case size
  of AsteroidSmall: 0
  of AsteroidMedium: 2
  of AsteroidLarge: 3

proc fragmentSize*(size: AsteroidSize): AsteroidSize =
  case size
  of AsteroidLarge: AsteroidMedium
  of AsteroidMedium: AsteroidSmall
  of AsteroidSmall: AsteroidSmall

proc fragmentKick*(size: AsteroidSize): int =
  case size
  of AsteroidSmall: 88
  of AsteroidMedium: 60
  of AsteroidLarge: 44

proc asteroidSpeedRange*(size: AsteroidSize): tuple[minSpeed, maxSpeed: int] =
  case size
  of AsteroidSmall:
    (68, 106)
  of AsteroidMedium:
    (46, 78)
  of AsteroidLarge:
    (30, 54)

proc applyDrag(value: var int, numerator, denominator: int) =
  value = (value * numerator) div denominator
  if abs(value) <= StopThreshold:
    value = 0

proc clampVelocity(velX, velY: var int, maxSpeed: int) =
  clampVectorLength(velX, velY, maxSpeed)

proc wrapAxis*(value: var int, worldSize: int) =
  while value < 0:
    value += worldSize
  while value >= worldSize:
    value -= worldSize

proc wrapPosition*(x, y: var int) =
  wrapAxis(x, WorldWidthUnits)
  wrapAxis(y, WorldHeightUnits)

proc wrappedDelta*(value, center, worldSize: int): int =
  result = value - center
  let half = worldSize div 2
  if result > half:
    result -= worldSize
  elif result < -half:
    result += worldSize

proc wrappedDistanceSquared*(ax, ay, bx, by: int): int =
  let
    dx = wrappedDelta(ax, bx, WorldWidthUnits)
    dy = wrappedDelta(ay, by, WorldHeightUnits)
  dx * dx + dy * dy

proc mixHash*(value: uint32): uint32 =
  var x = value
  x = x xor (x shr 16)
  x *= 0x7feb352d'u32
  x = x xor (x shr 15)
  x *= 0x846ca68b'u32
  x xor (x shr 16)

proc rockVertexRadius*(asteroid: Asteroid, vertexIndex: int): int =
  let
    baseRadius = asteroidRadius(asteroid.size)
    wobble = max(1, baseRadius div 3)
    mixed = mixHash(asteroid.seed xor uint32(vertexIndex * 0x9E3779B9'u32.int))
    delta = int(mixed mod uint32(wobble * 2 + 1)) - wobble
  max(2, baseRadius + delta)

proc randomPlayerColor(sim: var SimServer): RgbaColor =
  var available: seq[RgbaColor] = @[]
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

proc addExplosion*(
  sim: var SimServer,
  x, y, radius: int,
  color: RgbaColor,
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

proc totalAsteroidValue*(sim: SimServer): int =
  for asteroid in sim.asteroids:
    result += asteroidValue(asteroid.size)

proc generateStars(sim: var SimServer) =
  for _ in 0 ..< 96:
    sim.stars.add Star(
      x: sim.rng.rand(WorldWidthPixels - 1),
      y: sim.rng.rand(WorldHeightPixels - 1),
      color: StarColors[sim.rng.rand(StarColors.high)]
    )

proc spawnRandomLargeAsteroid*(sim: var SimServer): bool =
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

proc playerIndexById*(sim: SimServer, playerId: int): int =
  for i, player in sim.players:
    if player.id == playerId:
      return i
  -1

proc addScore*(sim: var SimServer, playerId, points: int) =
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

proc respawnPlayer*(sim: var SimServer, playerIndex: int): bool =
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

proc addPlayer*(sim: var SimServer, name: string): int =
  inc sim.nextPlayerId
  sim.players.add Player(
    id: sim.nextPlayerId,
    name: name,
    color: sim.randomPlayerColor(),
    facing: sim.rng.rand(DirectionCount - 1)
  )
  let playerIndex = sim.players.high
  if not sim.respawnPlayer(playerIndex):
    sim.players[playerIndex].respawnTicks = 1
  playerIndex

proc destroyShip*(sim: var SimServer, playerIndex: int, killerId = 0) =
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

proc bulletsForPlayer*(sim: SimServer, playerId: int): int =
  for bullet in sim.bullets:
    if bullet.ownerId == playerId:
      inc result

proc tryFireBullet*(sim: var SimServer, playerIndex: int) =
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

proc buildAsteroidFragments*(sim: var SimServer, asteroid: Asteroid): seq[Asteroid] =
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

proc buildRewardPacket*(sim: SimServer): string =
  for player in sim.players:
    result.add("reward ")
    result.add(player.name)
    result.add(" ")
    result.add($player.score)
    result.add("\n")

proc playerInputFromMasks*(currentMask, previousMask: uint8): PlayerInput =
  let decoded = decodeInputMask(currentMask)
  result.turnLeft = decoded.left
  result.turnRight = decoded.right
  result.thrust = decoded.up
  result.reverse = decoded.down
  result.fireHeld = decoded.attack
  result.brakeHeld = decoded.b

proc cleanPlayerName*(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc stepPlayers*(sim: var SimServer, inputs: openArray[PlayerInput]) =
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

proc stepAsteroids*(sim: var SimServer) =
  for asteroid in sim.asteroids.mitems:
    asteroid.x += asteroid.velX
    asteroid.y += asteroid.velY
    wrapPosition(asteroid.x, asteroid.y)
    discard asteroid.spin

proc stepBullets*(sim: var SimServer) =
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

proc resolveBulletCollisions*(sim: var SimServer) =
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

proc resolveShipAsteroidCollisions*(sim: var SimServer) =
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

proc resolveShipShipCollisions*(sim: var SimServer) =
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

proc stepExplosions*(sim: var SimServer) =
  var activeExplosions: seq[Explosion] = @[]
  for explosion in sim.explosions:
    var updated = explosion
    dec updated.ttl
    if updated.ttl > 0:
      activeExplosions.add(updated)
  sim.explosions = move(activeExplosions)

proc stepRespawns*(sim: var SimServer) =
  for playerIndex in 0 ..< sim.players.len:
    if not sim.players[playerIndex].alive and sim.players[playerIndex].respawnTicks <= 0:
      discard sim.respawnPlayer(playerIndex)

proc ensureAsteroids*(sim: var SimServer) =
  if sim.asteroidSpawnCooldown > 0:
    dec sim.asteroidSpawnCooldown
  if sim.totalAsteroidValue() >= TargetAsteroidValue or sim.asteroidSpawnCooldown > 0:
    return
  if sim.spawnRandomLargeAsteroid():
    sim.asteroidSpawnCooldown = AsteroidSpawnCooldownTicks

proc step*(sim: var SimServer, inputs: openArray[PlayerInput]) =
  sim.stepPlayers(inputs)
  sim.stepAsteroids()
  sim.stepBullets()
  sim.resolveBulletCollisions()
  sim.resolveShipAsteroidCollisions()
  sim.resolveShipShipCollisions()
  sim.stepExplosions()
  sim.stepRespawns()
  sim.ensureAsteroids()
  inc sim.tickCount

proc initSimServer*(seed: int): SimServer =
  result.rng = initRand(seed)
  result.generateStars()
  for _ in 0 ..< InitialLargeAsteroids:
    discard result.spawnRandomLargeAsteroid()

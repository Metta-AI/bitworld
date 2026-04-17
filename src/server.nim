import pixie
import std/[os, random]

const
  ScreenWidth* = 64
  ScreenHeight* = 64
  TileSize* = 6
  ProtocolBytes* = (ScreenWidth * ScreenHeight) div 2
  WorldWidthTiles = 96
  WorldHeightTiles = 96
  WorldWidthPixels = WorldWidthTiles * TileSize
  WorldHeightPixels = WorldHeightTiles * TileSize
  TargetMobCount = 48
  MinMobSpacing = 16
  MinPlayerSpawnSpacing = 40
  MotionScale = 256
  Accel = 76
  FrictionNum = 200
  FrictionDen = 256
  MaxSpeed = 704
  StopThreshold = 12
  MaxPlayerLives* = 5

type
  InputState* = object
    up*, down*, left*, right*, select*, attack*: bool

  Facing* = enum
    FaceUp
    FaceDown
    FaceLeft
    FaceRight

  Sprite* = object
    width*, height*: int
    pixels*: seq[uint8]

  Actor* = object
    x*, y*: int
    sprite*: Sprite
    attackTicks*: int
    attackResolved*: bool
    velX*: int
    velY*: int
    carryX*: int
    carryY*: int
    lives*: int
    invulnTicks*: int
    coins*: int

  PickupKind* = enum
    PickupCoin
    PickupHeart

  Pickup* = object
    x*, y*: int
    kind*: PickupKind

  Mob* = object
    x*, y*: int
    sprite*: Sprite
    wanderCooldown*: int
    hp*: int
    attackCooldown*: int
    attackPhase*: int
    attackFacing*: Facing

  SimServer* = object
    players*: seq[Actor]
    mobs*: seq[Mob]
    pickups*: seq[Pickup]
    tiles*: seq[bool]
    terrainSprite*: Sprite
    mobSprite*: Sprite
    swooshSprite*: Sprite
    heartSprite*: Sprite
    emptyHeartSprite*: Sprite
    coinSprite*: Sprite
    digitSprites*: array[10, Sprite]
    packedFrame*: seq[uint8]
    frameIndices*: seq[uint8]
    rng*: Rand
    tickCount*: int
    facing*: Facing
    mobSpawnCooldown*: int

var Palette*: array[16, ColorRGBA]

proc tileIndex(tx, ty: int): int =
  ty * WorldWidthTiles + tx

proc inTileBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles

proc spriteIndex(sprite: Sprite, x, y: int): int =
  y * sprite.width + x

proc makeSprite(lines: openArray[string], legend: openArray[(char, uint8)]): Sprite =
  result.height = lines.len
  result.width = (if lines.len == 0: 0 else: lines[0].len)
  result.pixels = newSeq[uint8](result.width * result.height)
  var lut: array[256, uint8]
  for pair in legend:
    lut[pair[0].ord] = pair[1]

  for y, line in lines:
    for x, ch in line:
      result.pixels[result.spriteIndex(x, y)] = lut[ch.ord]

proc fallbackPlayerSprite(): Sprite =
  makeSprite(
    [
      "..cc..",
      ".cddc.",
      ".ceec.",
      ".c44c.",
      ".7..7.",
      "7....7"
    ],
    [('.', 0'u8), ('c', 12'u8), ('d', 14'u8), ('e', 15'u8), ('4', 4'u8), ('7', 7'u8)]
  )

proc fallbackMobSprite(): Sprite =
  makeSprite(
    [
      ".33..",
      "3553.",
      "35553",
      ".355.",
      "..3.."
    ],
    [('.', 0'u8), ('3', 3'u8), ('5', 5'u8)]
  )

proc fallbackTerrainSprite(): Sprite =
  makeSprite(
    [
      "334433",
      "345543",
      "455554",
      "455554",
      "345543",
      "334433"
    ],
    [('3', 3'u8), ('4', 4'u8), ('5', 5'u8)]
  )

proc fallbackSwooshSprite(): Sprite =
  makeSprite(
    [
      "..6...",
      ".6....",
      ".6....",
      ".6....",
      ".6....",
      "..6..."
    ],
    [('.', 0'u8), ('6', 6'u8)]
  )

proc fallbackCoinSprite(): Sprite =
  makeSprite(
    [
      "..77..",
      ".7887.",
      "788887",
      "788887",
      ".7887.",
      "..77.."
    ],
    [('.', 0'u8), ('7', 7'u8), ('8', 8'u8)]
  )

proc loadPalette(path: string) =
  if not fileExists(path):
    raise newException(IOError, "Missing palette asset: " & path)

  let image = readImage(path)
  if image.width < Palette.len or image.height < 1:
    raise newException(IOError, "Palette asset must be at least 16x1: " & path)

  for x in 0 ..< Palette.len:
    Palette[x] = image[x, 0]

proc nearestPaletteIndex(pixel: ColorRGBA): uint8 =
  if pixel.a < 20'u8:
    return 0

  var best = 0
  var bestDistance = high(int)
  for index in 0 ..< Palette.len:
    let candidate = Palette[index]
    let dr = int(pixel.r) - int(candidate.r)
    let dg = int(pixel.g) - int(candidate.g)
    let db = int(pixel.b) - int(candidate.b)
    let da = int(pixel.a) - int(candidate.a)
    let distance = dr * dr + dg * dg + db * db + da * da
    if distance < bestDistance:
      bestDistance = distance
      best = index
  best.uint8

proc spriteFromImage(image: Image): Sprite =
  result.width = image.width
  result.height = image.height
  result.pixels = newSeq[uint8](result.width * result.height)
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      result.pixels[result.spriteIndex(x, y)] = nearestPaletteIndex(image[x, y])

proc sliceSpriteStrip(image: Image, spriteWidth, spriteHeight, count: int): seq[Sprite] =
  result = @[]
  for i in 0 ..< count:
    var sprite = Sprite(width: spriteWidth, height: spriteHeight)
    sprite.pixels = newSeq[uint8](spriteWidth * spriteHeight)
    let baseX = i * spriteWidth
    for y in 0 ..< spriteHeight:
      for x in 0 ..< spriteWidth:
        sprite.pixels[sprite.spriteIndex(x, y)] = nearestPaletteIndex(image[baseX + x, y])
    result.add(sprite)

proc loadDigitSprites(path: string): array[10, Sprite] =
  if not fileExists(path):
    raise newException(IOError, "Missing digit sprite strip: " & path)

  let image = readImage(path)
  let digits = sliceSpriteStrip(image, 6, 6, 10)
  if digits.len != 10:
    raise newException(IOError, "Digit sprite strip must contain 10 digits: " & path)

  for i in 0 ..< 10:
    result[i] = digits[i]

proc readRequiredSprite(path: string): Sprite =
  if not fileExists(path):
    raise newException(IOError, "Missing sprite asset: " & path)
  spriteFromImage(readImage(path))

proc maybeLoadSprite(candidates: openArray[string], fallback: Sprite): Sprite =
  for candidate in candidates:
    if fileExists(candidate):
      try:
        return spriteFromImage(readImage(candidate))
      except PixieError:
        discard
  fallback

proc worldClampPixel(x, maxValue: int): int =
  x.clamp(0, maxValue)

proc rectsOverlap(ax, ay, aw, ah, bx, by, bw, bh: int): bool =
  ax < bx + bw and
  ax + aw > bx and
  ay < by + bh and
  ay + ah > by

proc distanceSquared(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

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
  for _ in 0 ..< 180:
    let
      baseTx = sim.rng.rand(WorldWidthTiles - 1)
      baseTy = sim.rng.rand(WorldHeightTiles - 1)
      patchW = 1 + sim.rng.rand(4)
      patchH = 1 + sim.rng.rand(4)
    for dy in 0 ..< patchH:
      for dx in 0 ..< patchW:
        let tx = baseTx + dx
        let ty = baseTy + dy
        if inTileBounds(tx, ty) and sim.rng.rand(99) < 72:
          sim.tiles[tileIndex(tx, ty)] = true

proc canSpawnMobAt(sim: SimServer, px, py: int, sprite: Sprite): bool =
  if not sim.canOccupy(px, py, sprite.width, sprite.height):
    return false

  let mobSpacingSq = MinMobSpacing * MinMobSpacing
  for mob in sim.mobs:
    if distanceSquared(px, py, mob.x, mob.y) < mobSpacingSq:
      return false

  if sim.players.len > 0:
    let player = sim.players[0]
    if distanceSquared(px, py, player.x, player.y) < MinPlayerSpawnSpacing * MinPlayerSpawnSpacing:
      return false

  true

proc spawnOneMob(sim: var SimServer, sprite: Sprite): bool =
  for _ in 0 ..< 128:
    let
      tx = sim.rng.rand(WorldWidthTiles - 1)
      ty = sim.rng.rand(WorldHeightTiles - 1)
      px = tx * TileSize
      py = ty * TileSize
    if sim.canSpawnMobAt(px, py, sprite):
      sim.mobs.add Mob(
        x: px,
        y: py,
        sprite: sprite,
        wanderCooldown: 8 + sim.rng.rand(18),
        hp: 3,
        attackCooldown: 30 + sim.rng.rand(30)
      )
      return true
  false

proc spawnMobs(sim: var SimServer, count: int, sprite: Sprite) =
  var spawned = 0
  while spawned < count:
    if not sim.spawnOneMob(sprite):
      break
    inc spawned

proc initSimServer*(): SimServer =
  result.rng = initRand(0xB1770)
  result.tiles = newSeq[bool](WorldWidthTiles * WorldHeightTiles)
  result.frameIndices = newSeq[uint8](ScreenWidth * ScreenHeight)
  result.packedFrame = newSeq[uint8](ProtocolBytes)
  result.facing = FaceDown
  loadPalette("data/pallete.png")
  let terrainSprite = readRequiredSprite("data/wall.png")
  let playerSprite = readRequiredSprite("data/player.png")
  let mobSprite = readRequiredSprite("data/snake.png")
  let swooshSprite = readRequiredSprite("data/swoosh.png")
  let heartSprite = readRequiredSprite("data/heart.png")
  let emptyHeartSprite = readRequiredSprite("data/empty_heart.png")
  let coinSprite = readRequiredSprite("data/coin.png")
  let digitSprites = loadDigitSprites("data/numbers.png")
  result.terrainSprite = terrainSprite
  result.mobSprite = mobSprite
  result.swooshSprite = swooshSprite
  result.heartSprite = heartSprite
  result.emptyHeartSprite = emptyHeartSprite
  result.coinSprite = coinSprite
  result.digitSprites = digitSprites

  result.seedBrush()
  let startTx = WorldWidthTiles div 2
  let startTy = WorldHeightTiles div 2
  result.clearSpawnArea(startTx, startTy, 5)

  result.players = @[
    Actor(
      x: startTx * TileSize,
      y: startTy * TileSize,
      sprite: playerSprite,
      lives: MaxPlayerLives
    )
  ]
  result.spawnMobs(36, mobSprite)
  result.mobSpawnCooldown = 30

proc currentPlayerCoins*(sim: SimServer): int =
  if sim.players.len == 0: 0 else: sim.players[0].coins

proc moveActor(sim: SimServer, actor: var Actor, dx, dy: int) =
  if dx != 0:
    let stepX = (if dx < 0: -1 else: 1)
    for _ in 0 ..< abs(dx):
      let nx = actor.x + stepX
      if sim.canOccupy(nx, actor.y, actor.sprite.width, actor.sprite.height):
        actor.x = nx
      else:
        break

  if dy != 0:
    let stepY = (if dy < 0: -1 else: 1)
    for _ in 0 ..< abs(dy):
      let ny = actor.y + stepY
      if sim.canOccupy(actor.x, ny, actor.sprite.width, actor.sprite.height):
        actor.y = ny
      else:
        break

proc applyMomentumAxis(
  sim: SimServer,
  actor: var Actor,
  carry: var int,
  velocity: int,
  horizontal: bool
) =
  carry += velocity
  while abs(carry) >= MotionScale:
    let step = (if carry < 0: -1 else: 1)
    if horizontal:
      if sim.canOccupy(actor.x + step, actor.y, actor.sprite.width, actor.sprite.height):
        actor.x += step
        carry -= step * MotionScale
      else:
        carry = 0
        break
    else:
      if sim.canOccupy(actor.x, actor.y + step, actor.sprite.width, actor.sprite.height):
        actor.y += step
        carry -= step * MotionScale
      else:
        carry = 0
        break

proc applyInput*(sim: var SimServer, input: InputState) =
  if sim.players.len == 0:
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

  if inputX != 0:
    sim.players[0].velX = clamp(sim.players[0].velX + inputX * Accel, -MaxSpeed, MaxSpeed)
  else:
    sim.players[0].velX = (sim.players[0].velX * FrictionNum) div FrictionDen
    if abs(sim.players[0].velX) < StopThreshold:
      sim.players[0].velX = 0

  if inputY != 0:
    sim.players[0].velY = clamp(sim.players[0].velY + inputY * Accel, -MaxSpeed, MaxSpeed)
  else:
    sim.players[0].velY = (sim.players[0].velY * FrictionNum) div FrictionDen
    if abs(sim.players[0].velY) < StopThreshold:
      sim.players[0].velY = 0

  if abs(sim.players[0].velX) > abs(sim.players[0].velY):
    if sim.players[0].velX < 0:
      sim.facing = FaceLeft
    elif sim.players[0].velX > 0:
      sim.facing = FaceRight
  else:
    if sim.players[0].velY < 0:
      sim.facing = FaceUp
    elif sim.players[0].velY > 0:
      sim.facing = FaceDown

  if inputX < 0:
    sim.facing = FaceLeft
  elif inputX > 0:
    sim.facing = FaceRight
  elif inputY < 0:
    sim.facing = FaceUp
  elif inputY > 0:
    sim.facing = FaceDown

  sim.applyMomentumAxis(sim.players[0], sim.players[0].carryX, sim.players[0].velX, true)
  sim.applyMomentumAxis(sim.players[0], sim.players[0].carryY, sim.players[0].velY, false)
  if input.attack and sim.players[0].attackTicks == 0:
    sim.players[0].attackTicks = 5
    sim.players[0].attackResolved = false

proc attackRect(sim: SimServer, player: Actor): tuple[x, y, w, h: int] =
  let sprite = sim.swooshSprite
  case sim.facing
  of FaceUp:
    (player.x, player.y - sprite.height, sprite.width, sprite.height)
  of FaceDown:
    (player.x, player.y + player.sprite.height, sprite.width, sprite.height)
  of FaceLeft:
    (player.x - sprite.height, player.y, sprite.height, sprite.width)
  of FaceRight:
    (player.x + player.sprite.width, player.y, sprite.height, sprite.width)

proc lungeVector(facing: Facing, distance: int): tuple[dx, dy: int] =
  case facing
  of FaceUp: (0, -distance)
  of FaceDown: (0, distance)
  of FaceLeft: (-distance, 0)
  of FaceRight: (distance, 0)

proc chooseFacing(fromX, fromY, toX, toY: int): Facing =
  let
    dx = toX - fromX
    dy = toY - fromY
  if abs(dx) > abs(dy):
    if dx < 0: FaceLeft else: FaceRight
  else:
    if dy < 0: FaceUp else: FaceDown

proc applyAttack(sim: var SimServer) =
  if sim.players.len == 0 or sim.players[0].attackTicks <= 0 or sim.players[0].attackResolved:
    return

  let player = sim.players[0]
  let hit = sim.attackRect(player)
  var survivors: seq[Mob] = @[]
  for mob in sim.mobs.mitems:
    let wasHit = rectsOverlap(
      hit.x, hit.y, hit.w, hit.h,
      mob.x, mob.y, mob.sprite.width, mob.sprite.height
    )
    if rectsOverlap(
      hit.x, hit.y, hit.w, hit.h,
      mob.x, mob.y, mob.sprite.width, mob.sprite.height
    ):
      dec mob.hp
      var dx = 0
      var dy = 0
      case sim.facing
      of FaceUp: dy = -4
      of FaceDown: dy = 4
      of FaceLeft: dx = -4
      of FaceRight: dx = 4
      var actor = Actor(x: mob.x, y: mob.y, sprite: mob.sprite)
      sim.moveActor(actor, dx, dy)
      mob.x = actor.x
      mob.y = actor.y

    if mob.hp > 0:
      survivors.add(mob)
    elif wasHit:
      let roll = sim.rng.rand(99)
      if roll < 10:
        sim.pickups.add(Pickup(x: mob.x, y: mob.y, kind: PickupHeart))
      elif roll < 60:
        sim.pickups.add(Pickup(x: mob.x, y: mob.y, kind: PickupCoin))
  sim.mobs = survivors
  sim.players[0].attackResolved = true

proc collectPickups(sim: var SimServer) =
  if sim.players.len == 0:
    return

  let player = sim.players[0]
  var remaining: seq[Pickup] = @[]
  for pickup in sim.pickups:
    if rectsOverlap(
      pickup.x, pickup.y, TileSize, TileSize,
      player.x, player.y, player.sprite.width, player.sprite.height
    ):
      case pickup.kind
      of PickupCoin:
        inc sim.players[0].coins
      of PickupHeart:
        if sim.players[0].lives < MaxPlayerLives:
          inc sim.players[0].lives
      continue
    remaining.add(pickup)
  sim.pickups = remaining

proc updateMobs*(sim: var SimServer) =
  if sim.players.len == 0:
    return

  let player = sim.players[0]
  for mob in sim.mobs.mitems:
    dec mob.attackCooldown
    if mob.attackCooldown < 0:
      mob.attackCooldown = 0

    if mob.attackPhase == 0:
      let
        centerX = mob.x + mob.sprite.width div 2
        centerY = mob.y + mob.sprite.height div 2
        playerCenterX = player.x + player.sprite.width div 2
        playerCenterY = player.y + player.sprite.height div 2
      if mob.attackCooldown == 0 and distanceSquared(centerX, centerY, playerCenterX, playerCenterY) <= 18 * 18:
        mob.attackFacing = chooseFacing(centerX, centerY, playerCenterX, playerCenterY)
        let back = lungeVector(mob.attackFacing, -1)
        var actor = Actor(x: mob.x, y: mob.y, sprite: mob.sprite)
        sim.moveActor(actor, back.dx, back.dy)
        mob.x = actor.x
        mob.y = actor.y
        mob.attackPhase = 1
        continue

    elif mob.attackPhase == 1:
      let lunge = lungeVector(mob.attackFacing, 4)
      var actor = Actor(x: mob.x, y: mob.y, sprite: mob.sprite)
      sim.moveActor(actor, lunge.dx, lunge.dy)
      mob.x = actor.x
      mob.y = actor.y
      if player.invulnTicks == 0 and rectsOverlap(
        mob.x, mob.y, mob.sprite.width, mob.sprite.height,
        player.x, player.y, player.sprite.width, player.sprite.height
      ):
        if sim.players[0].lives > 0:
          dec sim.players[0].lives
        sim.players[0].invulnTicks = 30
      mob.attackPhase = 0
      mob.attackCooldown = 45 + sim.rng.rand(30)
      continue

    dec mob.wanderCooldown
    if mob.wanderCooldown > 0:
      continue

    mob.wanderCooldown = 8 + sim.rng.rand(20)
    let direction = sim.rng.rand(4)
    var dx = 0
    var dy = 0
    case direction
    of 0: dx = 1
    of 1: dx = -1
    of 2: dy = 1
    else: dy = -1

    var actor = Actor(x: mob.x, y: mob.y, sprite: mob.sprite)
    sim.moveActor(actor, dx, dy)
    mob.x = actor.x
    mob.y = actor.y

proc respawnMobs(sim: var SimServer) =
  if sim.mobs.len >= TargetMobCount:
    sim.mobSpawnCooldown = 24
    return

  dec sim.mobSpawnCooldown
  if sim.mobSpawnCooldown > 0:
    return

  discard sim.spawnOneMob(sim.mobSprite)
  sim.mobSpawnCooldown = 24 + sim.rng.rand(24)

proc clearFrame(sim: var SimServer) =
  for i in 0 ..< sim.frameIndices.len:
    sim.frameIndices[i] = 3

proc putPixel(sim: var SimServer, x, y: int, index: uint8) =
  if x < 0 or y < 0 or x >= ScreenWidth or y >= ScreenHeight or index == 0:
    return
  sim.frameIndices[y * ScreenWidth + x] = index

proc blitSprite(sim: var SimServer, sprite: Sprite, worldX, worldY, cameraX, cameraY: int, facing = FaceDown) =
  let
    screenX = worldX - cameraX
    screenY = worldY - cameraY
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != 0:
        var dx = 0
        var dy = 0
        case facing
        of FaceDown:
          dx = x
          dy = y
        of FaceUp:
          dx = sprite.width - 1 - x
          dy = sprite.height - 1 - y
        of FaceLeft:
          dx = y
          dy = sprite.width - 1 - x
        of FaceRight:
          dx = sprite.height - 1 - y
          dy = x
        sim.putPixel(screenX + dx, screenY + dy, colorIndex)

proc renderTerrain(sim: var SimServer, cameraX, cameraY: int) =
  let
    startTx = max(0, cameraX div TileSize)
    startTy = max(0, cameraY div TileSize)
    endTx = min(WorldWidthTiles - 1, (cameraX + ScreenWidth - 1) div TileSize)
    endTy = min(WorldHeightTiles - 1, (cameraY + ScreenHeight - 1) div TileSize)

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      if sim.tiles[tileIndex(tx, ty)]:
        sim.blitSprite(
          sim.terrainSprite,
          tx * TileSize,
          ty * TileSize,
          cameraX,
          cameraY
        )

proc renderHud(sim: var SimServer) =
  for i in 0 ..< MaxPlayerLives:
    let x = i * sim.heartSprite.width
    let y = 0
    if i < sim.players[0].lives:
      sim.blitSprite(sim.heartSprite, x, y, 0, 0)
    else:
      sim.blitSprite(sim.emptyHeartSprite, x, y, 0, 0)

  let
    coins = min(sim.players[0].coins, 99)
    hudWidth = sim.coinSprite.width * 3
    hudX = ScreenWidth - hudWidth
  sim.blitSprite(sim.coinSprite, hudX, 0, 0, 0)
  sim.blitSprite(sim.digitSprites[coins div 10], hudX + sim.coinSprite.width, 0, 0, 0)
  sim.blitSprite(sim.digitSprites[coins mod 10], hudX + sim.coinSprite.width * 2, 0, 0, 0)

proc packFramebuffer(sim: var SimServer) =
  for i in 0 ..< sim.packedFrame.len:
    let lo = sim.frameIndices[i * 2] and 0x0F
    let hi = sim.frameIndices[i * 2 + 1] and 0x0F
    sim.packedFrame[i] = lo or (hi shl 4)

proc buildFramePacket*(sim: var SimServer): seq[uint8] =
  sim.clearFrame()
  if sim.players.len == 0:
    return sim.packedFrame

  let player = sim.players[0]
  let
    cameraX = worldClampPixel(player.x + player.sprite.width div 2 - ScreenWidth div 2, WorldWidthPixels - ScreenWidth)
    cameraY = worldClampPixel(player.y + player.sprite.height div 2 - ScreenHeight div 2, WorldHeightPixels - ScreenHeight)

  sim.renderTerrain(cameraX, cameraY)
  for pickup in sim.pickups:
    case pickup.kind
    of PickupCoin:
      sim.blitSprite(sim.coinSprite, pickup.x, pickup.y, cameraX, cameraY)
    of PickupHeart:
      sim.blitSprite(sim.heartSprite, pickup.x, pickup.y, cameraX, cameraY)
  for mob in sim.mobs:
    sim.blitSprite(mob.sprite, mob.x, mob.y, cameraX, cameraY)
  sim.blitSprite(player.sprite, player.x, player.y, cameraX, cameraY)
  if sim.players[0].attackTicks > 0:
    let hit = sim.attackRect(player)
    sim.blitSprite(sim.swooshSprite, hit.x, hit.y, cameraX, cameraY, sim.facing)
  sim.renderHud()
  sim.packFramebuffer()
  sim.packedFrame

proc step*(sim: var SimServer, input: InputState) =
  inc sim.tickCount
  if sim.players.len > 0 and sim.players[0].invulnTicks > 0:
    dec sim.players[0].invulnTicks
  sim.applyInput(input)
  sim.collectPickups()
  sim.applyAttack()
  sim.updateMobs()
  sim.respawnMobs()
  if sim.players.len > 0 and sim.players[0].attackTicks > 0:
    dec sim.players[0].attackTicks
    if sim.players[0].attackTicks == 0:
      sim.players[0].attackResolved = false

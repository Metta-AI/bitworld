import pixie
import protocol
import ../common/server
import std/[os, random]

const
  SheetTileSize* = TileSize
  GameName* = "big_adventure"
  GameVersion* = "1"
  ReplayMagic* = "BITWORLD"
  ReplayFormatVersion* = 1'u16
  ReplayTickHashRecord* = 0x01'u8
  ReplayInputRecord* = 0x02'u8
  ReplayJoinRecord* = 0x03'u8
  ReplayLeaveRecord* = 0x04'u8
  ReplayFps* = 24
  WorldWidthTiles* = 96
  WorldHeightTiles* = 96
  WorldWidthPixels* = WorldWidthTiles * TileSize
  WorldHeightPixels* = WorldHeightTiles * TileSize
  TargetMobCount* = 48
  MinMobSpacing* = 16
  MinPlayerSpawnSpacing* = 40
  MotionScale* = 256
  Accel* = 38
  FrictionNum* = 200
  FrictionDen* = 256
  MaxSpeed* = 352
  StopThreshold* = 8
  MaxPlayerLives* = 5
  SnakeHp* = 3
  BossHp* = 10
  BossCoinValue* = 10
  TargetFps* = 24.0
  WebSocketPath* = "/ws"
  SpriteWebSocketPath* = "/sprite"
  BackgroundColor* = 12'u8
  HealthBarGray* = 1'u8
  HealthBarGreen* = 10'u8
  HealthBarYellow* = 8'u8
  HealthBarRed* = 3'u8
  BossHealInterval* = 50
  RadarRange* = 128
  RadarColorSnake* = 10'u8
  RadarColorBoss* = 3'u8
  PlayerColors* = [2'u8, 7, 8, 14, 4, 11, 13, 15]
  MapSpriteId* = 1
  MapObjectId* = 1
  MapLayerId* = 0
  MapLayerType* = 0
  TopLeftLayerId* = 1
  TopLeftLayerType* = 1
  BottomRightLayerId* = 3
  BottomRightLayerType* = 3
  ReplayCenterBottomLayerId* = 8
  ReplayBottomLeftLayerId* = 9
  ReplayCenterBottomLayerType* = 8
  ReplayBottomLeftLayerType* = 4
  ZoomableLayerFlag* = 1
  UiLayerFlag* = 2
  PlayerSpriteBase* = 100
  SelectedPlayerSpriteBase* = 200
  MobSpriteId* = 300
  BossSpriteId* = 301
  CoinSpriteId* = 302
  HeartSpriteId* = 303
  SelectedTextSpriteId* = 400
  SelectedViewportSpriteId* = 401
  ReplayTickSpriteId* = 402
  ReplayControlsSpriteId* = 403
  PlayerObjectBase* = 1000
  MobObjectBase* = 2000
  PickupObjectBase* = 3000
  SelectedTextObjectId* = 4000
  SelectedViewportObjectId* = 4001
  ReplayTickObjectId* = 4002
  ReplayControlsObjectId* = 4003

type
  Actor* = object
    id*: int
    address*: string
    x*, y*: int
    sprite*: Sprite
    facing*: Facing
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

  MobKind* = enum
    SnakeMob
    BossMob

  Pickup* = object
    x*, y*: int
    kind*: PickupKind
    value*: int

  Mob* = object
    kind*: MobKind
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
    playerSprite*: Sprite
    terrainSprite*: Sprite
    mobSprite*: Sprite
    bossSprite*: Sprite
    swooshSprite*: Sprite
    heartSprite*: Sprite
    emptyHeartSprite*: Sprite
    coinSprite*: Sprite
    digitSprites*: array[10, Sprite]
    letterSprites*: seq[Sprite]
    fb*: Framebuffer
    rng*: Rand
    tickCount*: int
    mobSpawnCooldown*: int
    nextPlayerId*: int

proc dataDir*(): string =
  getCurrentDir() / "data"

proc repoDir*(): string =
  getCurrentDir() / ".."

proc clientDataDir*(): string =
  repoDir() / "client" / "data"

proc sheetPath*(): string =
  dataDir() / "spritesheet.png"

proc loadClientPalette*() =
  loadPalette(clientDataDir() / "pallete.png")

proc loadClientDigitSprites*(): array[10, Sprite] =
  loadDigitSprites(clientDataDir() / "numbers.png")

proc loadClientLetterSprites*(): seq[Sprite] =
  loadLetterSprites(clientDataDir() / "letters.png")

proc sheetSprite(sheet: Image, cellX, cellY: int): Sprite =
  spriteFromImage(
    sheet.subImage(cellX * SheetTileSize, cellY * SheetTileSize, SheetTileSize, SheetTileSize)
  )

proc sheetRegionSprite(sheet: Image, x, y, width, height: int): Sprite =
  spriteFromImage(sheet.subImage(x, y, width, height))

proc tileIndex*(tx, ty: int): int =
  ty * WorldWidthTiles + tx

proc inTileBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles

proc worldClampPixel*(x, maxValue: int): int =
  x.clamp(0, maxValue)

proc rectsOverlap*(ax, ay, aw, ah, bx, by, bw, bh: int): bool =
  ax < bx + bw and
  ax + aw > bx and
  ay < by + bh and
  ay + ah > by

proc distanceSquared*(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc canOccupy*(sim: SimServer, x, y, width, height: int): bool =
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

proc clearSpawnArea*(sim: var SimServer, centerTx, centerTy, radius: int) =
  for ty in centerTy - radius .. centerTy + radius:
    for tx in centerTx - radius .. centerTx + radius:
      if inTileBounds(tx, ty):
        sim.tiles[tileIndex(tx, ty)] = false

proc seedBrush*(sim: var SimServer) =
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

proc canSpawnMobAt*(sim: SimServer, px, py: int, sprite: Sprite): bool =
  if not sim.canOccupy(px, py, sprite.width, sprite.height):
    return false

  let mobSpacingSq = MinMobSpacing * MinMobSpacing
  for mob in sim.mobs:
    if distanceSquared(px, py, mob.x, mob.y) < mobSpacingSq:
      return false

  if sim.players.len > 0:
    for player in sim.players:
      if distanceSquared(px, py, player.x, player.y) < MinPlayerSpawnSpacing * MinPlayerSpawnSpacing:
        return false

  true

proc spawnOneMob*(sim: var SimServer, kind: MobKind, sprite: Sprite, hp: int): bool =
  for _ in 0 ..< 128:
    let
      tx = sim.rng.rand(WorldWidthTiles - 1)
      ty = sim.rng.rand(WorldHeightTiles - 1)
      px = tx * TileSize
      py = ty * TileSize
    if sim.canSpawnMobAt(px, py, sprite):
      sim.mobs.add Mob(
        kind: kind,
        x: px,
        y: py,
        sprite: sprite,
        wanderCooldown: 8 + sim.rng.rand(18),
        hp: hp,
        attackCooldown: 30 + sim.rng.rand(30)
      )
      return true
  false

proc spawnMobs*(sim: var SimServer, count: int, kind: MobKind, sprite: Sprite, hp: int) =
  var spawned = 0
  while spawned < count:
    if not sim.spawnOneMob(kind, sprite, hp):
      break
    inc spawned

proc snakeCount*(sim: SimServer): int =
  for mob in sim.mobs:
    if mob.kind == SnakeMob:
      inc result

proc hasBoss*(sim: SimServer): bool =
  for mob in sim.mobs:
    if mob.kind == BossMob:
      return true

proc mobAttackRange*(mob: Mob): int =
  12 + max(mob.sprite.width, mob.sprite.height)

proc findPlayerSpawn*(sim: SimServer): tuple[x, y: int] =
  let
    centerTx = WorldWidthTiles div 2
    centerTy = WorldHeightTiles div 2
    minSpacingSq = MinPlayerSpawnSpacing * MinPlayerSpawnSpacing

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

proc addPlayer*(sim: var SimServer, address: string): int =
  inc sim.nextPlayerId
  let spawn = sim.findPlayerSpawn()
  sim.players.add Actor(
    id: sim.nextPlayerId,
    address: address,
    x: spawn.x,
    y: spawn.y,
    sprite: sim.playerSprite,
    facing: FaceDown,
    lives: MaxPlayerLives
  )
  sim.players.high

proc initSimServer*(): SimServer =
  result.rng = initRand(0xB1770)
  result.tiles = newSeq[bool](WorldWidthTiles * WorldHeightTiles)
  result.fb = initFramebuffer()
  loadClientPalette()
  let sheet = readImage(sheetPath())
  result.terrainSprite = sheet.sheetSprite(0, 0)
  result.playerSprite = sheet.sheetSprite(1, 0)
  result.mobSprite = sheet.sheetSprite(2, 0)
  result.bossSprite = sheet.sheetRegionSprite(0, 2 * SheetTileSize, 2 * SheetTileSize, 2 * SheetTileSize)
  result.swooshSprite = sheet.sheetSprite(3, 0)
  result.heartSprite = sheet.sheetSprite(0, 1)
  result.emptyHeartSprite = sheet.sheetSprite(1, 1)
  result.coinSprite = sheet.sheetSprite(2, 1)
  result.digitSprites = loadClientDigitSprites()
  result.letterSprites = loadClientLetterSprites()

  result.seedBrush()
  let startTx = WorldWidthTiles div 2
  let startTy = WorldHeightTiles div 2
  result.clearSpawnArea(startTx, startTy, 5)

  result.players = @[]
  result.spawnMobs(36, SnakeMob, result.mobSprite, SnakeHp)
  discard result.spawnOneMob(BossMob, result.bossSprite, BossHp)
  result.mobSpawnCooldown = 30

proc mixHash(hash: var uint64, value: uint64) =
  ## Mixes one integer into a deterministic FNV-1a hash.
  hash = hash xor value
  hash *= 1099511628211'u64

proc mixHashInt(hash: var uint64, value: int) =
  ## Mixes one signed integer into a deterministic hash.
  hash.mixHash(cast[uint64](int64(value)))

proc gameHash*(sim: SimServer): uint64 =
  ## Returns a deterministic hash of gameplay state.
  result = 14695981039346656037'u64
  result.mixHashInt(sim.tickCount)
  result.mixHashInt(sim.mobSpawnCooldown)
  result.mixHashInt(sim.nextPlayerId)
  result.mixHashInt(sim.players.len)
  for player in sim.players:
    result.mixHashInt(player.id)
    result.mixHashInt(player.x)
    result.mixHashInt(player.y)
    result.mixHashInt(ord(player.facing))
    result.mixHashInt(player.attackTicks)
    result.mixHashInt(ord(player.attackResolved))
    result.mixHashInt(player.velX)
    result.mixHashInt(player.velY)
    result.mixHashInt(player.carryX)
    result.mixHashInt(player.carryY)
    result.mixHashInt(player.lives)
    result.mixHashInt(player.invulnTicks)
    result.mixHashInt(player.coins)
  result.mixHashInt(sim.mobs.len)
  for mob in sim.mobs:
    result.mixHashInt(ord(mob.kind))
    result.mixHashInt(mob.x)
    result.mixHashInt(mob.y)
    result.mixHashInt(mob.wanderCooldown)
    result.mixHashInt(mob.hp)
    result.mixHashInt(mob.attackCooldown)
    result.mixHashInt(mob.attackPhase)
    result.mixHashInt(ord(mob.attackFacing))
  result.mixHashInt(sim.pickups.len)
  for pickup in sim.pickups:
    result.mixHashInt(pickup.x)
    result.mixHashInt(pickup.y)
    result.mixHashInt(ord(pickup.kind))
    result.mixHashInt(pickup.value)
  for tile in sim.tiles:
    result.mixHashInt(ord(tile))

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

proc applyInput*(sim: var SimServer, playerIndex: int, input: InputState) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  template player: untyped = sim.players[playerIndex]

  if player.lives <= 0:
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

  if inputX != 0:
    player.velX = clamp(player.velX + inputX * Accel, -MaxSpeed, MaxSpeed)
  else:
    player.velX = (player.velX * FrictionNum) div FrictionDen
    if abs(player.velX) < StopThreshold:
      player.velX = 0

  if inputY != 0:
    player.velY = clamp(player.velY + inputY * Accel, -MaxSpeed, MaxSpeed)
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

  sim.applyMomentumAxis(player, player.carryX, player.velX, true)
  sim.applyMomentumAxis(player, player.carryY, player.velY, false)
  if input.attack and player.attackTicks == 0:
    player.attackTicks = 5
    player.attackResolved = false

proc attackRect*(sim: SimServer, player: Actor): tuple[x, y, w, h: int] =
  let sprite = sim.swooshSprite
  case player.facing
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

proc handlePlayerDeath(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].lives > 0:
    return

  if sim.players[playerIndex].coins > 0:
    sim.pickups.add(Pickup(
      x: sim.players[playerIndex].x,
      y: sim.players[playerIndex].y,
      kind: PickupCoin,
      value: sim.players[playerIndex].coins
    ))
    sim.players[playerIndex].coins = 0

proc damagePlayer(sim: var SimServer, playerIndex: int, knockbackDx, knockbackDy: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].lives <= 0 or sim.players[playerIndex].invulnTicks > 0:
    return

  dec sim.players[playerIndex].lives
  sim.players[playerIndex].invulnTicks = 30

  var actor = Actor(
    x: sim.players[playerIndex].x,
    y: sim.players[playerIndex].y,
    sprite: sim.players[playerIndex].sprite
  )
  sim.moveActor(actor, knockbackDx, knockbackDy)
  sim.players[playerIndex].x = actor.x
  sim.players[playerIndex].y = actor.y
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0
  sim.players[playerIndex].carryX = 0
  sim.players[playerIndex].carryY = 0

  if sim.players[playerIndex].lives <= 0:
    sim.handlePlayerDeath(playerIndex)

proc applyAttack(sim: var SimServer) =
  if sim.players.len == 0:
    return

  var mobDamaged = newSeq[bool](sim.mobs.len)
  var bossHitCounts = newSeq[int](sim.mobs.len)
  var bossKnockbackXs = newSeq[int](sim.mobs.len)
  var bossKnockbackYs = newSeq[int](sim.mobs.len)
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].attackTicks <= 0 or sim.players[playerIndex].attackResolved:
      continue

    let player = sim.players[playerIndex]
    let hit = sim.attackRect(player)
    for mobIndex in 0 ..< sim.mobs.len:
      if sim.mobs[mobIndex].kind == SnakeMob and mobDamaged[mobIndex]:
        continue
      if rectsOverlap(
        hit.x, hit.y, hit.w, hit.h,
        sim.mobs[mobIndex].x, sim.mobs[mobIndex].y, sim.mobs[mobIndex].sprite.width, sim.mobs[mobIndex].sprite.height
      ):
        var dx = 0
        var dy = 0
        case player.facing
        of FaceUp: dy = -4
        of FaceDown: dy = 4
        of FaceLeft: dx = -4
        of FaceRight: dx = 4
        if sim.mobs[mobIndex].kind == BossMob:
          inc bossHitCounts[mobIndex]
          bossKnockbackXs[mobIndex] += dx
          bossKnockbackYs[mobIndex] += dy
        else:
          mobDamaged[mobIndex] = true
          dec sim.mobs[mobIndex].hp
          var actor = Actor(x: sim.mobs[mobIndex].x, y: sim.mobs[mobIndex].y, sprite: sim.mobs[mobIndex].sprite)
          sim.moveActor(actor, dx, dy)
          sim.mobs[mobIndex].x = actor.x
          sim.mobs[mobIndex].y = actor.y
        break

    for targetPlayerIndex in 0 ..< sim.players.len:
      if targetPlayerIndex == playerIndex:
        continue
      let targetPlayer = sim.players[targetPlayerIndex]
      if targetPlayer.lives <= 0:
        continue
      if rectsOverlap(
        hit.x, hit.y, hit.w, hit.h,
        targetPlayer.x, targetPlayer.y, targetPlayer.sprite.width, targetPlayer.sprite.height
      ):
        var dx = 0
        var dy = 0
        case player.facing
        of FaceUp: dy = -4
        of FaceDown: dy = 4
        of FaceLeft: dx = -4
        of FaceRight: dx = 4
        sim.damagePlayer(targetPlayerIndex, dx, dy)

    sim.players[playerIndex].attackResolved = true

  for mobIndex in 0 ..< sim.mobs.len:
    if sim.mobs[mobIndex].kind != BossMob or bossHitCounts[mobIndex] == 0:
      continue

    sim.mobs[mobIndex].hp -= bossHitCounts[mobIndex]

    let
      knockbackX = bossKnockbackXs[mobIndex].clamp(-4, 4)
      knockbackY = bossKnockbackYs[mobIndex].clamp(-4, 4)
    if knockbackX != 0 or knockbackY != 0:
      var actor = Actor(x: sim.mobs[mobIndex].x, y: sim.mobs[mobIndex].y, sprite: sim.mobs[mobIndex].sprite)
      sim.moveActor(actor, knockbackX, knockbackY)
      sim.mobs[mobIndex].x = actor.x
      sim.mobs[mobIndex].y = actor.y

  var survivors: seq[Mob] = @[]
  for mob in sim.mobs:
    if mob.hp > 0:
      survivors.add(mob)
    else:
      if mob.kind == BossMob:
        sim.pickups.add(Pickup(
          x: mob.x + mob.sprite.width div 2 - TileSize div 2,
          y: mob.y + mob.sprite.height div 2 - TileSize div 2,
          kind: PickupCoin,
          value: BossCoinValue
        ))
      else:
        let roll = sim.rng.rand(99)
        if roll < 10:
          sim.pickups.add(Pickup(x: mob.x, y: mob.y, kind: PickupHeart, value: 1))
        elif roll < 60:
          sim.pickups.add(Pickup(x: mob.x, y: mob.y, kind: PickupCoin, value: 1))
  sim.mobs = survivors

proc collectPickups(sim: var SimServer) =
  if sim.players.len == 0:
    return

  var remaining: seq[Pickup] = @[]
  for pickup in sim.pickups:
    var collected = false
    for playerIndex in 0 ..< sim.players.len:
      let player = sim.players[playerIndex]
      if player.lives <= 0:
        continue
      if rectsOverlap(
        pickup.x, pickup.y, TileSize, TileSize,
        player.x, player.y, player.sprite.width, player.sprite.height
      ):
        case pickup.kind
        of PickupCoin:
          sim.players[playerIndex].coins += max(1, pickup.value)
        of PickupHeart:
          if sim.players[playerIndex].lives < MaxPlayerLives:
            inc sim.players[playerIndex].lives
        collected = true
        break
    if collected:
      continue
    remaining.add(pickup)
  sim.pickups = remaining

proc updateMobs*(sim: var SimServer) =
  if sim.players.len == 0:
    return

  if sim.tickCount mod BossHealInterval == 0:
    for mob in sim.mobs.mitems:
      if mob.kind == BossMob:
        mob.hp = BossHp

  for mob in sim.mobs.mitems:
    dec mob.attackCooldown
    if mob.attackCooldown < 0:
      mob.attackCooldown = 0

    var
      targetPlayerIndex = 0
      bestDistance = high(int)
      hasTarget = false
    let
      centerX = mob.x + mob.sprite.width div 2
      centerY = mob.y + mob.sprite.height div 2
    for playerIndex in 0 ..< sim.players.len:
      let player = sim.players[playerIndex]
      if player.lives <= 0:
        continue
      let playerCenterX = player.x + player.sprite.width div 2
      let playerCenterY = player.y + player.sprite.height div 2
      let distance = distanceSquared(centerX, centerY, playerCenterX, playerCenterY)
      if distance < bestDistance:
        bestDistance = distance
        targetPlayerIndex = playerIndex
        hasTarget = true
    if not hasTarget:
      continue
    let player = sim.players[targetPlayerIndex]

    if mob.attackPhase == 0:
      let
        playerCenterX = player.x + player.sprite.width div 2
        playerCenterY = player.y + player.sprite.height div 2
      let attackRange = mob.mobAttackRange()
      if mob.attackCooldown == 0 and distanceSquared(centerX, centerY, playerCenterX, playerCenterY) <= attackRange * attackRange:
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
      for playerIndex in 0 ..< sim.players.len:
        let player = sim.players[playerIndex]
        if player.lives <= 0:
          continue
        if player.invulnTicks == 0 and rectsOverlap(
          mob.x, mob.y, mob.sprite.width, mob.sprite.height,
          player.x, player.y, player.sprite.width, player.sprite.height
        ):
          sim.damagePlayer(playerIndex, lunge.dx, lunge.dy)
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
  if not sim.hasBoss():
    discard sim.spawnOneMob(BossMob, sim.bossSprite, BossHp)

  if sim.snakeCount() >= TargetMobCount:
    sim.mobSpawnCooldown = 24
    return

  dec sim.mobSpawnCooldown
  if sim.mobSpawnCooldown > 0:
    return

  discard sim.spawnOneMob(SnakeMob, sim.mobSprite, SnakeHp)
  sim.mobSpawnCooldown = 24 + sim.rng.rand(24)

proc renderTerrain*(sim: var SimServer, cameraX, cameraY: int) =
  let
    startTx = max(0, cameraX div TileSize)
    startTy = max(0, cameraY div TileSize)
    endTx = min(WorldWidthTiles - 1, (cameraX + ScreenWidth - 1) div TileSize)
    endTy = min(WorldHeightTiles - 1, (cameraY + ScreenHeight - 1) div TileSize)

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      if sim.tiles[tileIndex(tx, ty)]:
        sim.fb.blitSprite(sim.terrainSprite, tx * TileSize, ty * TileSize, cameraX, cameraY)

proc renderNumber*(
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

proc renderHud*(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  let
    player = sim.players[playerIndex]
    coins = min(player.coins, 99)
    heartsStartX = ScreenWidth - MaxPlayerLives * sim.heartSprite.width

  sim.fb.renderNumber(sim.digitSprites, coins, 0, 0)

  for i in 0 ..< MaxPlayerLives:
    let x = heartsStartX + i * sim.heartSprite.width
    if i < player.lives:
      sim.fb.blitSprite(sim.heartSprite, x, 0, 0, 0)
    else:
      sim.fb.blitSprite(sim.emptyHeartSprite, x, 0, 0, 0)

proc renderHealthBar*(fb: var Framebuffer, screenX, screenY, width, current, maximum: int) =
  if maximum <= 0 or width <= 0:
    return
  let
    filled = max(0, min(width, (current * width + maximum - 1) div maximum))
    ratio = current * 100 div maximum
    barColor =
      if ratio > 50: HealthBarGreen
      elif ratio > 20: HealthBarYellow
      else: HealthBarRed
  for px in screenX ..< screenX + width:
    fb.putPixel(px, screenY, HealthBarGray)
  for px in screenX ..< screenX + filled:
    fb.putPixel(px, screenY, barColor)

proc playerColor*(playerIndex: int): uint8 =
  PlayerColors[playerIndex mod PlayerColors.len]

proc renderRadar*(fb: var Framebuffer, sim: SimServer, playerIndex: int, cameraX, cameraY: int) =
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

  for i, mob in sim.mobs:
    let
      mcx = mob.x + mob.sprite.width div 2
      mcy = mob.y + mob.sprite.height div 2
      dx = mcx - pcx
      dy = mcy - pcy
    if abs(dx) > RadarRange or abs(dy) > RadarRange:
      continue
    let sx = mcx - cameraX
    let sy = mcy - cameraY
    if sx >= 0 and sx < ScreenWidth and sy >= 0 and sy < ScreenHeight:
      continue
    let color = if mob.kind == BossMob: RadarColorBoss else: RadarColorSnake
    let pos = projectToEdge(dx, dy)
    fb.putPixel(pos.x, pos.y, color)

  for i in 0 ..< sim.players.len:
    if i == playerIndex or sim.players[i].lives <= 0:
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
    fb.putPixel(pos.x, pos.y, playerColor(i))

proc buildFramePacket*(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(BackgroundColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return sim.fb.packed

  let player = sim.players[playerIndex]

  if player.lives <= 0:
    sim.fb.blitText(sim.letterSprites, "GAME", 20, 26)
    sim.fb.blitText(sim.letterSprites, "OVER", 20, 34)
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let
    cameraX = worldClampPixel(player.x + player.sprite.width div 2 - ScreenWidth div 2, WorldWidthPixels - ScreenWidth)
    cameraY = worldClampPixel(player.y + player.sprite.height div 2 - ScreenHeight div 2, WorldHeightPixels - ScreenHeight)

  sim.renderTerrain(cameraX, cameraY)
  for pickup in sim.pickups:
    case pickup.kind
    of PickupCoin:
      sim.fb.blitSprite(sim.coinSprite, pickup.x, pickup.y, cameraX, cameraY)
    of PickupHeart:
      sim.fb.blitSprite(sim.heartSprite, pickup.x, pickup.y, cameraX, cameraY)
  for mob in sim.mobs:
    sim.fb.blitSprite(mob.sprite, mob.x, mob.y, cameraX, cameraY)
  for i in 0 ..< sim.players.len:
    let otherPlayer = sim.players[i]
    if otherPlayer.lives > 0:
      sim.fb.blitSpriteTinted(otherPlayer.sprite, otherPlayer.x, otherPlayer.y, cameraX, cameraY, playerColor(i))
  for otherPlayer in sim.players:
    if otherPlayer.lives > 0 and otherPlayer.attackTicks > 0:
      let hit = sim.attackRect(otherPlayer)
      sim.fb.blitSprite(sim.swooshSprite, hit.x, hit.y, cameraX, cameraY, otherPlayer.facing)
  for mob in sim.mobs:
    let
      maxHp = (if mob.kind == BossMob: BossHp else: SnakeHp)
      barW = mob.sprite.width
      barX = mob.x - cameraX
      barY = mob.y - cameraY - 2
    sim.fb.renderHealthBar(barX, barY, barW, mob.hp, maxHp)
  for i in 0 ..< sim.players.len:
    let p = sim.players[i]
    if p.lives > 0:
      let
        barW = p.sprite.width
        barX = p.x - cameraX
        barY = p.y - cameraY - 2
      sim.fb.renderHealthBar(barX, barY, barW, p.lives, MaxPlayerLives)
  sim.fb.renderRadar(sim, playerIndex, cameraX, cameraY)
  sim.renderHud(playerIndex)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc buildReplayFramePacket*(sim: var SimServer): seq[uint8] =
  ## Builds a simple player screen for replay mode.
  sim.fb.clearFrame(BackgroundColor)
  sim.fb.blitText(sim.letterSprites, "REPLAY", 20, 30)
  sim.fb.blitText(sim.letterSprites, "GLOBAL", 20, 38)
  sim.fb.blitText(sim.letterSprites, "VIEW", 20, 46)
  sim.fb.packFramebuffer()
  sim.fb.packed
proc step*(sim: var SimServer, inputs: openArray[InputState]) =
  inc sim.tickCount
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].invulnTicks > 0:
      dec sim.players[playerIndex].invulnTicks
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: InputState()
    sim.applyInput(playerIndex, input)
  sim.collectPickups()
  sim.applyAttack()
  sim.updateMobs()
  sim.respawnMobs()
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].attackTicks > 0:
      dec sim.players[playerIndex].attackTicks
      if sim.players[playerIndex].attackTicks == 0:
        sim.players[playerIndex].attackResolved = false

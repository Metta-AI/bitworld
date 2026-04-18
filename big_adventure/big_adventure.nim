import mummy, pixie
import protocol, server
import std/[locks, monotimes, os, parseopt, random, strutils, tables, times]

const
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
  TargetFps = 24.0
  WebSocketPath = "/ws"

type
  Actor* = object
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

  Pickup* = object
    x*, y*: int
    kind*: PickupKind
    value*: int

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
    playerSprite*: Sprite
    terrainSprite*: Sprite
    mobSprite*: Sprite
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
  getAppDir() / "data"

proc repoDir(): string =
  getAppDir() / ".."

proc clientDataDir(): string =
  repoDir() / "client" / "data"

proc tileIndex(tx, ty: int): int =
  ty * WorldWidthTiles + tx

proc inTileBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles

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
    for player in sim.players:
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

proc findPlayerSpawn(sim: SimServer): tuple[x, y: int] =
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

proc addPlayer(sim: var SimServer): int =
  let spawn = sim.findPlayerSpawn()
  sim.players.add Actor(
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
  loadPalette(clientDataDir() / "pallete.png")
  result.terrainSprite = readRequiredSprite(dataDir() / "wall.png")
  result.playerSprite = readRequiredSprite(dataDir() / "player.png")
  result.mobSprite = readRequiredSprite(dataDir() / "snake.png")
  result.swooshSprite = readRequiredSprite(dataDir() / "swoosh.png")
  result.heartSprite = readRequiredSprite(dataDir() / "heart.png")
  result.emptyHeartSprite = readRequiredSprite(dataDir() / "empty_heart.png")
  result.coinSprite = readRequiredSprite(dataDir() / "coin.png")
  result.digitSprites = loadDigitSprites(clientDataDir() / "numbers.png")
  result.letterSprites = loadLetterSprites(clientDataDir() / "letters.png")

  result.seedBrush()
  let startTx = WorldWidthTiles div 2
  let startTy = WorldHeightTiles div 2
  result.clearSpawnArea(startTx, startTy, 5)

  result.players = @[]
  result.spawnMobs(36, result.mobSprite)
  result.mobSpawnCooldown = 30

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

proc attackRect(sim: SimServer, player: Actor): tuple[x, y, w, h: int] =
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
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].attackTicks <= 0 or sim.players[playerIndex].attackResolved:
      continue

    let player = sim.players[playerIndex]
    let hit = sim.attackRect(player)
    for mobIndex in 0 ..< sim.mobs.len:
      if mobDamaged[mobIndex]:
        continue
      if rectsOverlap(
        hit.x, hit.y, hit.w, hit.h,
        sim.mobs[mobIndex].x, sim.mobs[mobIndex].y, sim.mobs[mobIndex].sprite.width, sim.mobs[mobIndex].sprite.height
      ):
        mobDamaged[mobIndex] = true
        dec sim.mobs[mobIndex].hp
        var dx = 0
        var dy = 0
        case player.facing
        of FaceUp: dy = -4
        of FaceDown: dy = 4
        of FaceLeft: dx = -4
        of FaceRight: dx = 4
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

  var survivors: seq[Mob] = @[]
  for mob in sim.mobs:
    if mob.hp > 0:
      survivors.add(mob)
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
  if sim.mobs.len >= TargetMobCount:
    sim.mobSpawnCooldown = 24
    return

  dec sim.mobSpawnCooldown
  if sim.mobSpawnCooldown > 0:
    return

  discard sim.spawnOneMob(sim.mobSprite)
  sim.mobSpawnCooldown = 24 + sim.rng.rand(24)

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

proc renderHud(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  let player = sim.players[playerIndex]
  for i in 0 ..< MaxPlayerLives:
    let x = i * sim.heartSprite.width
    if i < player.lives:
      sim.fb.blitSprite(sim.heartSprite, x, 0, 0, 0)
    else:
      sim.fb.blitSprite(sim.emptyHeartSprite, x, 0, 0, 0)

  let
    coins = min(player.coins, 99)
    hudWidth = sim.coinSprite.width * 3
    hudX = ScreenWidth - hudWidth
  sim.fb.blitSprite(sim.coinSprite, hudX, 0, 0, 0)
  sim.fb.blitSprite(sim.digitSprites[coins div 10], hudX + sim.coinSprite.width, 0, 0, 0)
  sim.fb.blitSprite(sim.digitSprites[coins mod 10], hudX + sim.coinSprite.width * 2, 0, 0, 0)

proc buildFramePacket*(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame()
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
  for otherPlayer in sim.players:
    if otherPlayer.lives > 0:
      sim.fb.blitSprite(otherPlayer.sprite, otherPlayer.x, otherPlayer.y, cameraX, cameraY)
  for otherPlayer in sim.players:
    if otherPlayer.lives > 0 and otherPlayer.attackTicks > 0:
      let hit = sim.attackRect(otherPlayer)
      sim.fb.blitSprite(sim.swooshSprite, hit.x, hit.y, cameraX, cameraY, otherPlayer.facing)
  sim.renderHud(playerIndex)
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

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.closedSockets = @[]

proc inputStateFromMasks(currentMask, previousMask: uint8): InputState =
  result = decodeInputMask(currentMask)
  result.attack = (currentMask and ButtonAttack) != 0 and (previousMask and ButtonAttack) == 0

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
    request.respond(200, headers, "Bit World WebSocket server")

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

proc runServerLoop*(host = DefaultHost, port = DefaultPort) =
  initAppState()

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4)

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
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = val
      of "port": port = parseInt(val)
      else: discard
    else: discard
  runServerLoop(address, port)

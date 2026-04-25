import mummy, pixie
import protocol, server
import std/[locks, monotimes, os, parseopt, random, strutils, tables, times]

const
  SheetTileSize = TileSize
  GameName = "big_adventure"
  GameVersion = "1"
  ReplayMagic = "BITWORLD"
  ReplayFormatVersion = 1'u16
  ReplayTickHashRecord = 0x01'u8
  ReplayInputRecord = 0x02'u8
  ReplayJoinRecord = 0x03'u8
  ReplayLeaveRecord = 0x04'u8
  ReplayFps = 24
  WorldWidthTiles = 96
  WorldHeightTiles = 96
  WorldWidthPixels = WorldWidthTiles * TileSize
  WorldHeightPixels = WorldHeightTiles * TileSize
  TargetMobCount = 48
  MinMobSpacing = 16
  MinPlayerSpawnSpacing = 40
  MotionScale = 256
  Accel = 38
  FrictionNum = 200
  FrictionDen = 256
  MaxSpeed = 352
  StopThreshold = 8
  MaxPlayerLives* = 5
  SnakeHp = 3
  BossHp = 10
  BossCoinValue = 10
  TargetFps = 24.0
  WebSocketPath = "/ws"
  SpriteWebSocketPath = "/sprite"
  BackgroundColor = 12'u8
  HealthBarGray = 1'u8
  HealthBarGreen = 10'u8
  HealthBarYellow = 8'u8
  HealthBarRed = 3'u8
  BossHealInterval = 50
  RadarRange = 128
  RadarColorSnake = 10'u8
  RadarColorBoss = 3'u8
  PlayerColors = [2'u8, 7, 8, 14, 4, 11, 13, 15]
  MapSpriteId = 1
  MapObjectId = 1
  MapLayerId = 0
  MapLayerType = 0
  TopLeftLayerId = 1
  TopLeftLayerType = 1
  BottomRightLayerId = 3
  BottomRightLayerType = 3
  ReplayCenterBottomLayerId = 8
  ReplayBottomRightLayerId = 9
  ReplayCenterBottomLayerType = 8
  ReplayBottomRightLayerType = 3
  ZoomableLayerFlag = 1
  UiLayerFlag = 2
  PlayerSpriteBase = 100
  SelectedPlayerSpriteBase = 200
  MobSpriteId = 300
  BossSpriteId = 301
  CoinSpriteId = 302
  HeartSpriteId = 303
  SelectedTextSpriteId = 400
  SelectedViewportSpriteId = 401
  ReplayTickSpriteId = 402
  ReplayControlsSpriteId = 403
  PlayerObjectBase = 1000
  MobObjectBase = 2000
  PickupObjectBase = 3000
  SelectedTextObjectId = 4000
  SelectedViewportObjectId = 4001
  ReplayTickObjectId = 4002
  ReplayControlsObjectId = 4003

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

  WebSocketAppState = object
    lock: Lock
    replayLoaded: bool
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    spriteViewers: Table[WebSocket, SpriteViewerState]
    closedSockets: seq[WebSocket]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

  SpriteViewerState = object
    initialized: bool
    objectIds: seq[int]
    mouseX: int
    mouseY: int
    mouseLayer: int
    selectedPlayerId: int
    clickPending: bool
    replayCommands: seq[char]

  ReplayError* = object of CatchableError

  ReplayInput = object
    time: uint32
    player: uint8
    keys: uint8

  ReplayHash = object
    tick: uint32
    hash: uint64

  ReplayJoin = object
    time: uint32
    player: uint8
    address: string

  ReplayLeave = object
    time: uint32
    player: uint8

  ReplayData = object
    gameName: string
    gameVersion: string
    joins: seq[ReplayJoin]
    leaves: seq[ReplayLeave]
    inputs: seq[ReplayInput]
    hashes: seq[ReplayHash]

  ReplayWriter = object
    enabled: bool
    file: File
    lastMasks: seq[uint8]

  ReplayPlayer = object
    data: ReplayData
    joinIndex: int
    leaveIndex: int
    inputIndex: int
    hashIndex: int
    masks: seq[uint8]
    lastAppliedMasks: seq[uint8]
    playing: bool
    speedIndex: int

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

proc initSpriteViewerState(): SpriteViewerState =
  ## Returns the default state for one sprite protocol viewer.
  result.mouseLayer = MapLayerId
  result.selectedPlayerId = -1
  result.replayCommands = @[]

proc tickTime(tick: int): uint32 =
  ## Converts a simulation tick to replay milliseconds.
  uint32((int64(tick) * 1000'i64) div int64(ReplayFps))

proc writeU8(file: File, value: uint8) =
  ## Writes one unsigned byte.
  file.write(char(value))

proc writeU16(file: File, value: uint16) =
  ## Writes one little endian unsigned 16 bit value.
  file.writeU8(uint8(value and 0xff'u16))
  file.writeU8(uint8(value shr 8))

proc writeU32(file: File, value: uint32) =
  ## Writes one little endian unsigned 32 bit value.
  for shift in countup(0, 24, 8):
    file.writeU8(uint8((value shr shift) and 0xff'u32))

proc writeU64(file: File, value: uint64) =
  ## Writes one little endian unsigned 64 bit value.
  for shift in countup(0, 56, 8):
    file.writeU8(uint8((value shr shift) and 0xff'u64))

proc writeReplayString(file: File, value: string) =
  ## Writes a replay UTF-8 string.
  if value.len > high(uint16).int:
    raise newException(ReplayError, "Replay string is too long")
  file.writeU16(uint16(value.len))
  file.write(value)

proc readU8(bytes: string, offset: var int): uint8 =
  ## Reads one unsigned byte from a replay buffer.
  if offset + 1 > bytes.len:
    raise newException(
      ReplayError,
      "Replay file is truncated at byte " & $offset
    )
  result = bytes[offset].uint8
  inc offset

proc readU16(bytes: string, offset: var int): uint16 =
  ## Reads one little endian unsigned 16 bit value.
  if offset + 2 > bytes.len:
    raise newException(
      ReplayError,
      "Replay file is truncated at byte " & $offset
    )
  result = uint16(bytes[offset].uint8) or
    (uint16(bytes[offset + 1].uint8) shl 8)
  offset += 2

proc readU32(bytes: string, offset: var int): uint32 =
  ## Reads one little endian unsigned 32 bit value.
  if offset + 4 > bytes.len:
    raise newException(
      ReplayError,
      "Replay file is truncated at byte " & $offset
    )
  for shift in countup(0, 24, 8):
    result = result or (uint32(bytes[offset].uint8) shl shift)
    inc offset

proc readU64(bytes: string, offset: var int): uint64 =
  ## Reads one little endian unsigned 64 bit value.
  if offset + 8 > bytes.len:
    raise newException(
      ReplayError,
      "Replay file is truncated at byte " & $offset
    )
  for shift in countup(0, 56, 8):
    result = result or (uint64(bytes[offset].uint8) shl shift)
    inc offset

proc readReplayString(bytes: string, offset: var int): string =
  ## Reads a replay UTF-8 string.
  let length = int(bytes.readU16(offset))
  if offset + length > bytes.len:
    raise newException(
      ReplayError,
      "Replay file is truncated at byte " & $offset
    )
  result = bytes[offset ..< offset + length]
  offset += length

proc openReplayWriter(path: string): ReplayWriter =
  ## Opens a replay file and writes the header.
  if path.len == 0:
    return
  if not open(result.file, path, fmWrite):
    raise newException(IOError, "Could not open replay file: " & path)
  result.enabled = true
  result.lastMasks = @[]
  result.file.write(ReplayMagic)
  result.file.writeU16(ReplayFormatVersion)
  result.file.writeReplayString(GameName)
  result.file.writeReplayString(GameVersion)
  result.file.writeU64(uint64(toUnix(getTime())) * 1000'u64)

proc closeReplayWriter(writer: var ReplayWriter) =
  ## Closes a replay writer if it is open.
  if writer.enabled:
    writer.file.flushFile()
    writer.file.close()
    writer.enabled = false

proc flushReplayWriter(writer: var ReplayWriter) =
  ## Flushes a replay writer if it is open.
  if writer.enabled:
    writer.file.flushFile()

proc writeJoin(
  writer: var ReplayWriter,
  time: uint32,
  player: int,
  address: string
) =
  ## Writes one player join replay record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayJoinRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))
  writer.file.writeReplayString(address)

proc writeLeave(writer: var ReplayWriter, time: uint32, player: int) =
  ## Writes one player leave replay record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayLeaveRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))

proc writeInput(writer: var ReplayWriter, input: ReplayInput) =
  ## Writes one player input replay record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayInputRecord)
  writer.file.writeU32(input.time)
  writer.file.writeU8(input.player)
  writer.file.writeU8(input.keys)

proc writeHash(writer: var ReplayWriter, tick: uint32, hash: uint64) =
  ## Writes one tick hash replay record.
  if not writer.enabled:
    return
  writer.file.writeU8(ReplayTickHashRecord)
  writer.file.writeU32(tick)
  writer.file.writeU64(hash)
  writer.flushReplayWriter()

proc loadReplay(path: string): ReplayData =
  ## Loads a replay file into memory.
  let bytes = readFile(path)
  var offset = 0
  if bytes.len < ReplayMagic.len:
    raise newException(ReplayError, "Replay file is truncated")
  if bytes[0 ..< ReplayMagic.len] != ReplayMagic:
    raise newException(ReplayError, "Replay magic is not BITWORLD")
  offset = ReplayMagic.len
  let formatVersion = bytes.readU16(offset)
  if formatVersion != ReplayFormatVersion:
    raise newException(ReplayError, "Unsupported replay format version")
  result.gameName = bytes.readReplayString(offset)
  result.gameVersion = bytes.readReplayString(offset)
  discard bytes.readU64(offset)
  if result.gameName != GameName:
    raise newException(ReplayError, "Replay game name does not match")
  if result.gameVersion != GameVersion:
    raise newException(ReplayError, "Replay game version does not match")

  var lastTick = -1
  var lastInputTime = 0'u32
  var lastJoinTime = 0'u32
  var lastLeaveTime = 0'u32
  while offset < bytes.len:
    let recordType = bytes.readU8(offset)
    case recordType
    of ReplayTickHashRecord:
      let
        tick = bytes.readU32(offset)
        hash = bytes.readU64(offset)
      if int(tick) <= lastTick:
        raise newException(ReplayError, "Replay tick hashes move backward")
      lastTick = int(tick)
      result.hashes.add(ReplayHash(tick: tick, hash: hash))
    of ReplayInputRecord:
      let input = ReplayInput(
        time: bytes.readU32(offset),
        player: bytes.readU8(offset),
        keys: bytes.readU8(offset)
      )
      if input.time < lastInputTime:
        raise newException(ReplayError, "Replay input timestamps move backward")
      lastInputTime = input.time
      result.inputs.add(input)
    of ReplayJoinRecord:
      let join = ReplayJoin(
        time: bytes.readU32(offset),
        player: bytes.readU8(offset),
        address: bytes.readReplayString(offset)
      )
      if join.time < lastJoinTime:
        raise newException(ReplayError, "Replay join timestamps move backward")
      lastJoinTime = join.time
      result.joins.add(join)
    of ReplayLeaveRecord:
      let leave = ReplayLeave(
        time: bytes.readU32(offset),
        player: bytes.readU8(offset)
      )
      if leave.time < lastLeaveTime:
        raise newException(ReplayError, "Replay leave timestamps move backward")
      lastLeaveTime = leave.time
      result.leaves.add(leave)
    else:
      raise newException(ReplayError, "Unknown replay record type")

proc sheetSprite(sheet: Image, cellX, cellY: int): Sprite =
  spriteFromImage(
    sheet.subImage(cellX * SheetTileSize, cellY * SheetTileSize, SheetTileSize, SheetTileSize)
  )

proc sheetRegionSprite(sheet: Image, x, y, width, height: int): Sprite =
  spriteFromImage(sheet.subImage(x, y, width, height))

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

proc spawnOneMob(sim: var SimServer, kind: MobKind, sprite: Sprite, hp: int): bool =
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

proc spawnMobs(sim: var SimServer, count: int, kind: MobKind, sprite: Sprite, hp: int) =
  var spawned = 0
  while spawned < count:
    if not sim.spawnOneMob(kind, sprite, hp):
      break
    inc spawned

proc snakeCount(sim: SimServer): int =
  for mob in sim.mobs:
    if mob.kind == SnakeMob:
      inc result

proc hasBoss(sim: SimServer): bool =
  for mob in sim.mobs:
    if mob.kind == BossMob:
      return true

proc mobAttackRange(mob: Mob): int =
  12 + max(mob.sprite.width, mob.sprite.height)

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

proc addPlayer(sim: var SimServer, address: string): int =
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

proc renderHud(sim: var SimServer, playerIndex: int) =
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

proc renderHealthBar(fb: var Framebuffer, screenX, screenY, width, current, maximum: int) =
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

proc playerColor(playerIndex: int): uint8 =
  PlayerColors[playerIndex mod PlayerColors.len]

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

proc spriteColor(color: uint8): uint8 =
  ## Converts a game palette index to a sprite protocol pixel.
  color + 1'u8

proc addU8(packet: var seq[uint8], value: uint8) =
  ## Appends one unsigned byte to a sprite protocol packet.
  packet.add(value)

proc addU16(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 16 bit value.
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addI16(packet: var seq[uint8], value: int) =
  ## Appends one little endian signed 16 bit value.
  let v = cast[uint16](int16(value))
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addViewport(packet: var seq[uint8], layer, width, height: int) =
  ## Appends a sprite protocol viewport message.
  packet.addU8(0x05)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addLayer(packet: var seq[uint8], layer, layerType, flags: int) =
  ## Appends a sprite protocol layer definition message.
  packet.addU8(0x06)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(layerType))
  packet.addU8(uint8(flags))

proc addSprite(
  packet: var seq[uint8],
  spriteId, width, height: int,
  pixels: openArray[uint8]
) =
  ## Appends a sprite protocol sprite definition message.
  packet.addU8(0x01)
  packet.addU16(spriteId)
  packet.addU16(width)
  packet.addU16(height)
  for pixel in pixels:
    packet.addU8(pixel)

proc addObject(
  packet: var seq[uint8],
  objectId, x, y, z, layer, spriteId: int
) =
  ## Appends a sprite protocol object definition message.
  packet.addU8(0x02)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc addDeleteObject(packet: var seq[uint8], objectId: int) =
  ## Appends a sprite protocol object delete message.
  packet.addU8(0x03)
  packet.addU16(objectId)

proc readProtocolI16(blob: string, offset: int): int =
  ## Reads one little endian signed 16 bit value from a string.
  let value = uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc applySpriteViewerMessage(
  state: var SpriteViewerState,
  message: string
) =
  ## Applies one or more sprite protocol client messages.
  var offset = 0
  while offset < message.len:
    let messageType = message[offset].uint8
    inc offset
    case messageType
    of 0x82:
      if offset + 4 > message.len:
        return
      state.mouseX = readProtocolI16(message, offset)
      state.mouseY = readProtocolI16(message, offset + 2)
      offset += 4
    of 0x83:
      if offset + 2 > message.len:
        return
      let
        code = message[offset].uint8
        down = message[offset + 1].uint8
      offset += 2
      if code == 0x01'u8 and down == 1'u8:
        state.clickPending = true
    of 0x81:
      if offset + 2 > message.len:
        return
      let length = int(uint16(message[offset].uint8) or
        (uint16(message[offset + 1].uint8) shl 8))
      offset += 2
      if offset + length > message.len:
        return
      for i in 0 ..< length:
        state.replayCommands.add(message[offset + i])
      offset += length
    else:
      return

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

proc isSolid(sprite: Sprite, x, y: int): bool =
  ## Returns true when a sprite source coordinate is opaque.
  if x < 0 or x >= sprite.width or y < 0 or y >= sprite.height:
    return false
  sprite.pixels[sprite.spriteIndex(x, y)] != TransparentColorIndex

proc facedSize(sprite: Sprite, facing: Facing): tuple[width, height: int] =
  ## Returns the rendered size for a facing rotation.
  case facing
  of FaceUp, FaceDown:
    (sprite.width, sprite.height)
  of FaceLeft, FaceRight:
    (sprite.height, sprite.width)

proc sourceForFacing(
  sprite: Sprite,
  x, y: int,
  facing: Facing
): tuple[x, y: int] =
  ## Converts a faced sprite coordinate to a source coordinate.
  case facing
  of FaceDown:
    (x, y)
  of FaceUp:
    (sprite.width - 1 - x, sprite.height - 1 - y)
  of FaceLeft:
    (sprite.width - 1 - y, x)
  of FaceRight:
    (y, sprite.height - 1 - x)

proc buildSpriteProtocolActorSprite(
  sprite: Sprite,
  tint: uint8,
  facing: Facing,
  selected = false
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds an outlined, tinted actor sprite for the global viewer.
  let
    size = sprite.facedSize(facing)
    outline = if selected: 8'u8 else: 0'u8
  result.width = size.width + 2
  result.height = size.height + 2
  result.pixels = newSeq[uint8](result.width * result.height)
  let outWidth = result.width

  proc outIndex(x, y: int): int =
    y * outWidth + x

  proc facedSolid(x, y: int): bool =
    if x < 0 or x >= size.width or y < 0 or y >= size.height:
      return false
    let src = sprite.sourceForFacing(x, y, facing)
    sprite.isSolid(src.x, src.y)

  for y in -1 .. size.height:
    for x in -1 .. size.width:
      if facedSolid(x, y):
        continue
      let adjacent =
        facedSolid(x - 1, y) or
        facedSolid(x + 1, y) or
        facedSolid(x, y - 1) or
        facedSolid(x, y + 1)
      if adjacent:
        result.pixels[outIndex(x + 1, y + 1)] = spriteColor(outline)

  for y in 0 ..< size.height:
    for x in 0 ..< size.width:
      let src = sprite.sourceForFacing(x, y, facing)
      let colorIndex = sprite.pixels[sprite.spriteIndex(src.x, src.y)]
      if colorIndex != TransparentColorIndex:
        result.pixels[outIndex(x + 1, y + 1)] = spriteColor(tint)

proc buildSpriteProtocolRawSprite(
  sprite: Sprite
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a raw sprite protocol sprite from a game sprite.
  result.width = sprite.width
  result.height = sprite.height
  result.pixels = newSeq[uint8](sprite.width * sprite.height)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        result.pixels[sprite.spriteIndex(x, y)] = spriteColor(colorIndex)

proc buildSpriteProtocolMapSprite(sim: SimServer): seq[uint8] =
  ## Builds a full world map sprite using the same wall tiles as the game.
  result = newSeq[uint8](WorldWidthPixels * WorldHeightPixels)
  for i in 0 ..< result.len:
    result[i] = spriteColor(BackgroundColor)
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      if not sim.tiles[tileIndex(tx, ty)]:
        continue
      let
        baseX = tx * TileSize
        baseY = ty * TileSize
      for y in 0 ..< sim.terrainSprite.height:
        for x in 0 ..< sim.terrainSprite.width:
          let colorIndex =
            sim.terrainSprite.pixels[sim.terrainSprite.spriteIndex(x, y)]
          if colorIndex != TransparentColorIndex:
            result[(baseY + y) * WorldWidthPixels + baseX + x] =
              spriteColor(colorIndex)

proc putTextSpritePixel(
  pixels: var seq[uint8],
  width, height, x, y: int,
  color: uint8
) =
  ## Puts one protocol pixel into a text sprite.
  if x < 0 or y < 0 or x >= width or y >= height:
    return
  pixels[y * width + x] = spriteColor(color)

proc buildSpriteProtocolTextSprite(
  sim: SimServer,
  lines: openArray[string],
  color: uint8
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Builds a transparent multi-line text sprite.
  result.width = 1
  for line in lines:
    result.width = max(result.width, line.len * 6)
  result.height = max(1, lines.len * 8 - 1)
  result.pixels = newSeq[uint8](result.width * result.height)
  for lineIndex, line in lines:
    let baseY = lineIndex * 8
    var baseX = 0
    for ch in line:
      if ch == ' ':
        baseX += 6
        continue
      if ch >= '0' and ch <= '9':
        let sprite = sim.digitSprites[ord(ch) - ord('0')]
        for y in 0 ..< sprite.height:
          for x in 0 ..< sprite.width:
            if sprite.pixels[sprite.spriteIndex(x, y)] !=
                TransparentColorIndex:
              result.pixels.putTextSpritePixel(
                result.width,
                result.height,
                baseX + x,
                baseY + y,
                color
              )
      else:
        let letter = letterIndex(ch)
        if letter >= 0 and letter < sim.letterSprites.len:
          let sprite = sim.letterSprites[letter]
          for y in 0 ..< sprite.height:
            for x in 0 ..< sprite.width:
              if sprite.pixels[sprite.spriteIndex(x, y)] !=
                  TransparentColorIndex:
                result.pixels.putTextSpritePixel(
                  result.width,
                  result.height,
                  baseX + x,
                  baseY + y,
                  color
                )
      baseX += 6

proc playerIdentity(player: Actor): string =
  ## Returns a sprite text friendly player identity.
  player.address.replace(":", " ")

proc spritePixelsFromPackedFrame(packed: openArray[uint8]): seq[uint8] =
  ## Converts a packed Bitworld frame into protocol sprite pixels.
  result = newSeq[uint8](ScreenWidth * ScreenHeight)
  var j = 0
  for byte in packed:
    result[j] = spriteColor(byte and 0x0f)
    inc j
    result[j] = spriteColor((byte shr 4) and 0x0f)
    inc j

proc playerObjectId(player: Actor): int =
  ## Returns the stable sprite protocol object id for a player.
  PlayerObjectBase + player.id

proc playerSpriteId(playerIndex: int, selected: bool): int =
  ## Returns the upright sprite id for a player color.
  let
    colorIndex = playerIndex mod PlayerColors.len
    base = if selected: SelectedPlayerSpriteBase else: PlayerSpriteBase
  base + colorIndex

proc selectedPlayerIndex(sim: SimServer, playerId: int): int =
  ## Returns the player index for a selected player id.
  for i in 0 ..< sim.players.len:
    if sim.players[i].id == playerId:
      return i
  -1

proc selectSpritePlayer(sim: SimServer, mouseX, mouseY: int): int =
  ## Returns the id of the topmost player under the mouse.
  result = -1
  var bestY = low(int)
  for player in sim.players:
    let
      size = player.sprite.facedSize(FaceDown)
      x = player.x - 1
      y = player.y - 1
      w = size.width + 2
      h = size.height + 2
    if mouseX >= x and mouseX < x + w and
        mouseY >= y and mouseY < y + h and
        player.y >= bestY:
      bestY = player.y
      result = player.id

proc buildSpriteProtocolInit(sim: SimServer): seq[uint8] =
  ## Builds the initial global viewer snapshot.
  result = @[]
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, WorldWidthPixels, WorldHeightPixels)
  result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
  result.addViewport(TopLeftLayerId, ScreenWidth, 24)
  result.addLayer(BottomRightLayerId, BottomRightLayerType, UiLayerFlag)
  result.addViewport(BottomRightLayerId, ScreenWidth, ScreenHeight)
  result.addLayer(
    ReplayCenterBottomLayerId,
    ReplayCenterBottomLayerType,
    UiLayerFlag
  )
  result.addViewport(ReplayCenterBottomLayerId, ScreenWidth, 8)
  result.addLayer(
    ReplayBottomRightLayerId,
    ReplayBottomRightLayerType,
    UiLayerFlag
  )
  result.addViewport(ReplayBottomRightLayerId, 96, 16)
  result.addSprite(
    MapSpriteId,
    WorldWidthPixels,
    WorldHeightPixels,
    sim.buildSpriteProtocolMapSprite()
  )
  result.addObject(MapObjectId, 0, 0, low(int16), MapLayerId, MapSpriteId)

  for i in 0 ..< PlayerColors.len:
    let
      playerSprite = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        FaceDown
      )
      selectedPlayerSprite = buildSpriteProtocolActorSprite(
        sim.playerSprite,
        PlayerColors[i],
        FaceDown,
        true
      )
    result.addSprite(
      PlayerSpriteBase + i,
      playerSprite.width,
      playerSprite.height,
      playerSprite.pixels
    )
    result.addSprite(
      SelectedPlayerSpriteBase + i,
      selectedPlayerSprite.width,
      selectedPlayerSprite.height,
      selectedPlayerSprite.pixels
    )

  let
    mob = buildSpriteProtocolRawSprite(sim.mobSprite)
    boss = buildSpriteProtocolRawSprite(sim.bossSprite)
    coin = buildSpriteProtocolRawSprite(sim.coinSprite)
    heart = buildSpriteProtocolRawSprite(sim.heartSprite)
  result.addSprite(MobSpriteId, mob.width, mob.height, mob.pixels)
  result.addSprite(BossSpriteId, boss.width, boss.height, boss.pixels)
  result.addSprite(CoinSpriteId, coin.width, coin.height, coin.pixels)
  result.addSprite(HeartSpriteId, heart.width, heart.height, heart.pixels)

proc buildSpriteProtocolUpdates(
  sim: var SimServer,
  state: SpriteViewerState,
  nextState: var SpriteViewerState,
  replayTick = -1,
  replayPlaying = false,
  replaySpeed = 1
): seq[uint8] =
  ## Builds global viewer object updates for the current tick.
  result = @[]
  nextState = state
  nextState.replayCommands.setLen(0)
  if nextState.clickPending:
    nextState.selectedPlayerId =
      sim.selectSpritePlayer(nextState.mouseX, nextState.mouseY)
    nextState.clickPending = false
  if not nextState.initialized:
    result = sim.buildSpriteProtocolInit()
    nextState.initialized = true

  var currentIds: seq[int] = @[]
  for i in 0 ..< sim.players.len:
    let
      player = sim.players[i]
      selected = player.id == nextState.selectedPlayerId
      objectId = player.playerObjectId()
    currentIds.add(objectId)
    result.addObject(
      objectId,
      player.x - 1,
      player.y - 1,
      player.y,
      MapLayerId,
      playerSpriteId(i, selected)
    )

  for i in 0 ..< sim.mobs.len:
    let
      mob = sim.mobs[i]
      objectId = MobObjectBase + i
      spriteId = if mob.kind == BossMob: BossSpriteId else: MobSpriteId
    currentIds.add(objectId)
    result.addObject(
      objectId,
      mob.x,
      mob.y,
      mob.y,
      MapLayerId,
      spriteId
    )

  for i in 0 ..< sim.pickups.len:
    let
      pickup = sim.pickups[i]
      objectId = PickupObjectBase + i
      spriteId =
        if pickup.kind == PickupCoin: CoinSpriteId else: HeartSpriteId
    currentIds.add(objectId)
    result.addObject(
      objectId,
      pickup.x,
      pickup.y,
      pickup.y,
      MapLayerId,
      spriteId
    )

  let playerIndex = sim.selectedPlayerIndex(nextState.selectedPlayerId)
  if playerIndex >= 0:
    var lines: seq[string] = @[]
    let player = sim.players[playerIndex]
    lines.add("PLAYER " & player.playerIdentity())
    lines.add("COINS " & $player.coins)
    lines.add("LIVES " & $player.lives)
    let text = sim.buildSpriteProtocolTextSprite(lines, 2'u8)
    currentIds.add(SelectedTextObjectId)
    result.addSprite(
      SelectedTextSpriteId,
      text.width,
      text.height,
      text.pixels
    )
    result.addObject(
      SelectedTextObjectId,
      2,
      2,
      0,
      TopLeftLayerId,
      SelectedTextSpriteId
    )

  if playerIndex >= 0 and replayTick < 0:
    let viewport = spritePixelsFromPackedFrame(
      sim.buildFramePacket(playerIndex)
    )
    currentIds.add(SelectedViewportObjectId)
    result.addSprite(
      SelectedViewportSpriteId,
      ScreenWidth,
      ScreenHeight,
      viewport
    )
    result.addObject(
      SelectedViewportObjectId,
      0,
      0,
      0,
      BottomRightLayerId,
      SelectedViewportSpriteId
    )

  if replayTick >= 0:
    let
      tickText = sim.buildSpriteProtocolTextSprite(
        ["TICK " & $replayTick],
        2'u8
      )
      controlText = sim.buildSpriteProtocolTextSprite(
        [
          if replayPlaying: "PAUSE " & $replaySpeed & "X" else: "PLAY",
          "STOP 1X 2X 4X 8X"
        ],
        2'u8
      )
    currentIds.add(ReplayTickObjectId)
    currentIds.add(ReplayControlsObjectId)
    result.addSprite(
      ReplayTickSpriteId,
      tickText.width,
      tickText.height,
      tickText.pixels
    )
    result.addObject(
      ReplayTickObjectId,
      max(0, (ScreenWidth - tickText.width) div 2),
      0,
      0,
      ReplayCenterBottomLayerId,
      ReplayTickSpriteId
    )
    result.addSprite(
      ReplayControlsSpriteId,
      controlText.width,
      controlText.height,
      controlText.pixels
    )
    result.addObject(
      ReplayControlsObjectId,
      2,
      1,
      0,
      ReplayBottomRightLayerId,
      ReplayControlsSpriteId
    )

  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

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
  appState.replayLoaded = false
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.spriteViewers = initTable[WebSocket, SpriteViewerState]()
  appState.closedSockets = @[]

proc inputStateFromMasks(currentMask, previousMask: uint8): InputState =
  result = decodeInputMask(currentMask)
  result.attack = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0

proc initReplayPlayer(data: ReplayData): ReplayPlayer =
  ## Builds replay playback state.
  result.data = data
  result.masks = @[]
  result.lastAppliedMasks = @[]
  result.playing = true
  result.speedIndex = 0

proc replaySpeed(replay: ReplayPlayer): int =
  ## Returns the current integer replay speed.
  case replay.speedIndex
  of 0: 1
  of 1: 2
  of 2: 4
  else: 8

proc resetReplay(replay: var ReplayPlayer) =
  ## Resets replay playback cursors.
  replay.joinIndex = 0
  replay.leaveIndex = 0
  replay.inputIndex = 0
  replay.hashIndex = 0
  replay.masks = @[]
  replay.lastAppliedMasks = @[]

proc ensureReplayPlayer(replay: var ReplayPlayer, player: int) =
  ## Expands replay input tables for one player.
  while replay.masks.len <= player:
    replay.masks.add(0)
    replay.lastAppliedMasks.add(0)

proc applyReplayEvents(replay: var ReplayPlayer, sim: var SimServer) =
  ## Applies replay joins and inputs for the current tick.
  let time = tickTime(sim.tickCount)
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    if int(leave.player) < 0 or int(leave.player) >= sim.players.len:
      raise newException(ReplayError, "Replay player leave is invalid")
    sim.players.delete(int(leave.player))
    if int(leave.player) < replay.masks.len:
      replay.masks.delete(int(leave.player))
    if int(leave.player) < replay.lastAppliedMasks.len:
      replay.lastAppliedMasks.delete(int(leave.player))
    inc replay.leaveIndex

  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    if int(join.player) != sim.players.len:
      raise newException(ReplayError, "Replay player join order is invalid")
    discard sim.addPlayer(join.address)
    replay.ensureReplayPlayer(int(join.player))
    inc replay.joinIndex

  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    replay.ensureReplayPlayer(int(input.player))
    replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex

proc replayInputs(replay: var ReplayPlayer, playerCount: int): seq[InputState] =
  ## Builds replay inputs for the current tick.
  result = newSeq[InputState](playerCount)
  for playerIndex in 0 ..< playerCount:
    replay.ensureReplayPlayer(playerIndex)
    result[playerIndex] = inputStateFromMasks(
      replay.masks[playerIndex],
      replay.lastAppliedMasks[playerIndex]
    )
    replay.lastAppliedMasks[playerIndex] = replay.masks[playerIndex]

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  ## Checks the recorded hash for the current tick.
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    raise newException(ReplayError, "Replay hash tick is missing")
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    raise newException(
      ReplayError,
      "Replay hash mismatch at tick " & $sim.tickCount
    )
  inc replay.hashIndex

proc stepReplay(replay: var ReplayPlayer, sim: var SimServer) =
  ## Advances replay by one simulation tick.
  replay.applyReplayEvents(sim)
  let inputs = replay.replayInputs(sim.players.len)
  sim.step(inputs)
  replay.checkReplayHash(sim)

proc seekReplay(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## Seeks replay playback to a target tick.
  sim = initSimServer()
  replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc applyReplayCommand(
  replay: var ReplayPlayer,
  sim: var SimServer,
  command: char
) =
  ## Applies one global viewer replay command.
  case command
  of ' ', 'p', 'P':
    replay.playing = not replay.playing
  of 's', 'S':
    replay.playing = false
    replay.seekReplay(sim, 0)
  of '+', '=':
    replay.speedIndex = min(replay.speedIndex + 1, 3)
  of '-', '_':
    replay.speedIndex = max(replay.speedIndex - 1, 0)
  of ',', '<':
    replay.playing = false
    replay.seekReplay(sim, max(0, sim.tickCount - ReplayFps * 5))
  of '.', '>':
    replay.playing = false
    replay.seekReplay(sim, sim.tickCount + ReplayFps * 5)
  else:
    discard

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket in appState.spriteViewers:
    appState.spriteViewers.del(websocket)
  if websocket notin appState.playerIndices:
    return

  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  appState.playerAddresses.del(websocket)

  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc httpHandler(request: Request) =
  if request.uri == WebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerAddresses[websocket] = request.remoteAddress
  elif request.uri == SpriteWebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.spriteViewers[websocket] = initSpriteViewerState()
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
        if websocket notin appState.spriteViewers:
          if appState.replayLoaded:
            appState.playerIndices[websocket] = -1
          else:
            appState.playerIndices[websocket] = 0x7fffffff
          appState.inputMasks[websocket] = 0
          appState.lastAppliedMasks[websocket] = 0
  of MessageEvent:
    if message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.spriteViewers:
            appState.spriteViewers[websocket].applySpriteViewerMessage(
              message.data
            )
          elif message.data.len == InputPacketBytes and
              not appState.replayLoaded:
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

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  saveReplayPath = "",
  loadReplayPath = ""
) =
  initAppState()
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  let replayLoaded = loadReplayPath.len > 0
  var
    replayWriter = openReplayWriter(saveReplayPath)
    replayPlayer =
      if replayLoaded:
        initReplayPlayer(loadReplay(loadReplayPath))
      else:
        ReplayPlayer()
  defer:
    replayWriter.closeReplayWriter()
  appState.replayLoaded = replayLoaded

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
      spriteViewers: seq[WebSocket] = @[]
      spriteStates: seq[SpriteViewerState] = @[]
      replayCommands: seq[char] = @[]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          if not replayLoaded and websocket in appState.playerIndices:
            let playerIndex = appState.playerIndices[websocket]
            if playerIndex >= 0 and playerIndex < sim.players.len:
              replayWriter.writeLeave(tickTime(sim.tickCount), playerIndex)
              if playerIndex < replayWriter.lastMasks.len:
                replayWriter.lastMasks.delete(playerIndex)
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        if not replayLoaded:
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] != 0x7fffffff:
              continue
            let address = appState.playerAddresses.getOrDefault(
              websocket,
              "unknown"
            )
            appState.playerIndices[websocket] = sim.addPlayer(address)
            replayWriter.writeJoin(
              tickTime(sim.tickCount),
              appState.playerIndices[websocket],
              address
            )
            while replayWriter.lastMasks.len < sim.players.len:
              replayWriter.lastMasks.add(0)

        for websocket, playerIndex in appState.playerIndices.pairs:
          sockets.add(websocket)
          playerIndices.add(playerIndex)
        if not replayLoaded:
          inputs = newSeq[InputState](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          if replayLoaded:
            continue
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
          let previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = inputStateFromMasks(currentMask, previousMask)
          if playerIndex < replayWriter.lastMasks.len and
              currentMask != replayWriter.lastMasks[playerIndex]:
            replayWriter.writeInput(ReplayInput(
              time: tickTime(sim.tickCount),
              player: uint8(playerIndex),
              keys: currentMask
            ))
            replayWriter.lastMasks[playerIndex] = currentMask
          appState.lastAppliedMasks[websocket] = currentMask
        for websocket, state in appState.spriteViewers.pairs:
          spriteViewers.add(websocket)
          spriteStates.add(state)
          for command in state.replayCommands:
            replayCommands.add(command)
          appState.spriteViewers[websocket].replayCommands.setLen(0)

    if replayLoaded:
      for command in replayCommands:
        replayPlayer.applyReplayCommand(sim, command)
      if replayPlayer.playing:
        for _ in 0 ..< replayPlayer.replaySpeed():
          if replayPlayer.playing:
            replayPlayer.stepReplay(sim)
    else:
      sim.step(inputs)
      replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())

    for i in 0 ..< sockets.len:
      let framePacket =
        if replayLoaded:
          sim.buildReplayFramePacket()
        else:
          sim.buildFramePacket(playerIndices[i])
      let frameBlob = blobFromBytes(framePacket)
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    for i in 0 ..< spriteViewers.len:
      var nextState: SpriteViewerState
      let packet = sim.buildSpriteProtocolUpdates(
        spriteStates[i],
        nextState,
        if replayLoaded: sim.tickCount else: -1,
        replayPlayer.playing,
        replayPlayer.replaySpeed()
      )
      if packet.len == 0:
        continue
      try:
        spriteViewers[i].send(blobFromBytes(packet), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if spriteViewers[i] in appState.spriteViewers:
              appState.spriteViewers[spriteViewers[i]] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(spriteViewers[i])

    runFrameLimiter(lastTick)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    saveReplayPath = ""
    loadReplayPath = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = val
      of "port": port = parseInt(val)
      of "save-replay": saveReplayPath = val
      of "load-replay": loadReplayPath = val
      else: discard
    else: discard
  runServerLoop(address, port, saveReplayPath, loadReplayPath)

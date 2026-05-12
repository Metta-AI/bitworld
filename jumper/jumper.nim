import
  std/[json, locks, monotimes, os, parseopt, random, strutils, tables, times],
  mummy, pixie, supersnappy,
  bitworld/clients, protocol, server

const
  DefaultSeed = 0xB1770
  DefaultMaxTicks = 0
  DefaultMaxGames = 0
  UnassignedPlayerIndex = 0x7fffffff
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
  MaxFallSpeed = 1000
  TargetFps = 24.0
  HealthzPath = "/healthz"
  WebSocketPath = "/player"
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
  MapLayerId = 0
  MapLayerKind = 0
  MapLayerFlags = 1
  SkySpriteId = 1
  GroundSpriteId = 2
  WallSpriteId = 3
  GoalSpriteId = 4
  DigitSpriteBase = 20
  LetterSpriteBase = 40
  PlayerSpriteBase = 100
  RadarSpriteBase = 200
  SkyObjectId = 1
  TileObjectBase = 1000
  PlayerObjectBase = 5000
  RadarObjectBase = 6000
  HudObjectBase = 7000
  TextObjectBase = 7100

type
  RgbaSprite = object
    width, height: int
    pixels: seq[uint8]

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
    rng: Rand
    tickCount: int
    nextColorIndex: int

  PlayerViewerState = object
    initialized: bool

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerViewers: Table[WebSocket, PlayerViewerState]
    closedSockets: seq[WebSocket]
    tokens: seq[string]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

  RunConfig = object
    address: string
    port: int
    seed: int
    maxTicks: int
    maxGames: int
    tokens: seq[string]

proc dataDir(): string =
  getCurrentDir() / "data"

proc repoDir(): string =
  getCurrentDir() / ".."

proc clientDataDir(): string =
  repoDir() / "clients" / "data"

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

proc newRgbaSprite(width, height: int): RgbaSprite =
  ## Allocates a transparent RGBA sprite.
  result.width = width
  result.height = height
  result.pixels = newSeq[uint8](width * height * 4)

proc rgbaColor(color: uint8): ColorRGBA =
  ## Converts one palette index to an RGBA color.
  if color == TransparentColorIndex:
    return ColorRGBA(r: 0, g: 0, b: 0, a: 0)
  Palette[int(color)]

proc putRgbaPixel(sprite: var RgbaSprite, x, y: int, color: ColorRGBA) =
  ## Writes one pixel into an RGBA sprite.
  if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height:
    return
  let offset = (y * sprite.width + x) * 4
  sprite.pixels[offset] = color.r
  sprite.pixels[offset + 1] = color.g
  sprite.pixels[offset + 2] = color.b
  sprite.pixels[offset + 3] = color.a

proc solidRgbaSprite(width, height: int, color: uint8): RgbaSprite =
  ## Builds one solid RGBA sprite from a palette index.
  result = newRgbaSprite(width, height)
  let rgba = rgbaColor(color)
  for y in 0 ..< height:
    for x in 0 ..< width:
      result.putRgbaPixel(x, y, rgba)

proc spriteToRgba(sprite: Sprite): RgbaSprite =
  ## Converts one indexed sprite to the sprite protocol RGBA format.
  result = newRgbaSprite(sprite.width, sprite.height)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let color = sprite.pixels[sprite.spriteIndex(x, y)]
      result.putRgbaPixel(x, y, rgbaColor(color))

proc coloredPlayerSprite(
  sprite: Sprite,
  color: uint8,
  flipX: bool
): RgbaSprite =
  ## Builds a tinted player sprite with a one pixel outline.
  result = newRgbaSprite(sprite.width + 2, sprite.height + 2)
  let black = rgbaColor(0'u8)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let source = sprite.pixels[sprite.spriteIndex(x, y)]
      if source == TransparentColorIndex:
        continue
      let dx =
        if flipX:
          sprite.width - 1 - x
        else:
          x
      for oy in -1 .. 1:
        for ox in -1 .. 1:
          if ox == 0 and oy == 0:
            continue
          result.putRgbaPixel(dx + 1 + ox, y + 1 + oy, black)

  let tint = rgbaColor(color)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let source = sprite.pixels[sprite.spriteIndex(x, y)]
      if source == TransparentColorIndex:
        continue
      let dx =
        if flipX:
          sprite.width - 1 - x
        else:
          x
      result.putRgbaPixel(dx + 1, y + 1, tint)

proc addU8(packet: var seq[uint8], value: uint8) =
  ## Appends one unsigned byte.
  packet.add(value)

proc addU16(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 16 bit value.
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addU32(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 32 bit value.
  let v = uint32(value)
  for shift in countup(0, 24, 8):
    packet.add(uint8((v shr shift) and 0xff'u32))

proc addI16(packet: var seq[uint8], value: int) =
  ## Appends one little endian signed 16 bit value.
  let v = cast[uint16](int16(value))
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc addViewport(packet: var seq[uint8], layer, width, height: int) =
  ## Appends one sprite protocol viewport message.
  packet.addU8(0x05'u8)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addLayer(packet: var seq[uint8], layer, layerKind, flags: int) =
  ## Appends one sprite protocol layer definition message.
  packet.addU8(0x06'u8)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(layerKind))
  packet.addU8(uint8(flags))

proc addSprite(
  packet: var seq[uint8],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label: string
) =
  ## Appends one sprite protocol sprite definition message.
  packet.addU8(0x01'u8)
  packet.addU16(spriteId)
  packet.addU16(width)
  packet.addU16(height)
  var raw = newSeq[uint8](pixels.len)
  for i in 0 ..< pixels.len:
    raw[i] = pixels[i]
  let compressed = supersnappy.compress(raw)
  packet.addU32(compressed.len)
  for byte in compressed:
    packet.addU8(byte)
  packet.addU16(label.len)
  for ch in label:
    packet.addU8(uint8(ord(ch)))

proc addRgbaSprite(
  packet: var seq[uint8],
  spriteId: int,
  sprite: RgbaSprite,
  label: string
) =
  ## Appends one RGBA sprite definition.
  packet.addSprite(spriteId, sprite.width, sprite.height, sprite.pixels, label)

proc addObject(
  packet: var seq[uint8],
  objectId, x, y, z, layer, spriteId: int
) =
  ## Appends one sprite protocol object definition message.
  packet.addU8(0x02'u8)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc addClearObjects(packet: var seq[uint8]) =
  ## Appends one sprite protocol clear objects message.
  packet.addU8(0x04'u8)

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

proc colorSlot(color: uint8): int =
  ## Returns the compact sprite slot for one player color.
  for i in 0 ..< PlayerColors.len:
    if PlayerColors[i] == color:
      return i
  0

proc playerSpriteId(color: uint8, facingRight: bool): int =
  ## Returns the sprite id for one colored player facing.
  PlayerSpriteBase + color.colorSlot() * 2 + (
    if facingRight:
      0
    else:
      1
  )

proc radarSpriteId(color: uint8): int =
  ## Returns the radar dot sprite id for one player color.
  RadarSpriteBase + color.colorSlot()

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

proc initSimServer(seed = DefaultSeed): SimServer =
  result.rng = initRand(seed)
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

proc addSpriteProtocolInit(packet: var seq[uint8], sim: SimServer) =
  ## Appends the static sprite protocol setup for one player viewer.
  packet.addLayer(MapLayerId, MapLayerKind, MapLayerFlags)
  packet.addViewport(MapLayerId, ScreenWidth, ScreenHeight)
  packet.addRgbaSprite(
    SkySpriteId,
    solidRgbaSprite(ScreenWidth, ScreenHeight, SkyColor),
    "sky"
  )
  packet.addRgbaSprite(
    GroundSpriteId,
    sim.groundSprite.spriteToRgba(),
    "ground"
  )
  packet.addRgbaSprite(WallSpriteId, sim.wallSprite.spriteToRgba(), "wall")
  packet.addRgbaSprite(GoalSpriteId, sim.goalSprite.spriteToRgba(), "goal")

  for i in 0 ..< sim.digitSprites.len:
    packet.addRgbaSprite(
      DigitSpriteBase + i,
      sim.digitSprites[i].spriteToRgba(),
      "digit " & $i
    )
  for i in 0 ..< sim.letterSprites.len:
    packet.addRgbaSprite(
      LetterSpriteBase + i,
      sim.letterSprites[i].spriteToRgba(),
      "letter " & $i
    )
  for i in 0 ..< PlayerColors.len:
    let color = PlayerColors[i]
    packet.addRgbaSprite(
      PlayerSpriteBase + i * 2,
      sim.rabbitSprite.coloredPlayerSprite(color, false),
      "player " & $i & " right"
    )
    packet.addRgbaSprite(
      PlayerSpriteBase + i * 2 + 1,
      sim.rabbitSprite.coloredPlayerSprite(color, true),
      "player " & $i & " left"
    )
    packet.addRgbaSprite(
      RadarSpriteBase + i,
      solidRgbaSprite(1, 1, color),
      "radar " & $i
    )

proc addNumberObjects(
  packet: var seq[uint8],
  sim: SimServer,
  value, screenX, screenY, objectBase: int
) =
  ## Appends digit objects for one non-negative number.
  let text = $max(0, value)
  var x = screenX
  for i, ch in text:
    let digit = ord(ch) - ord('0')
    packet.addObject(
      objectBase + i,
      x,
      screenY,
      int(high(int16)),
      MapLayerId,
      DigitSpriteBase + digit
    )
    x += sim.digitSprites[digit].width

proc addTextObjects(
  packet: var seq[uint8],
  sim: SimServer,
  text: string,
  screenX, screenY, objectBase: int
) =
  ## Appends letter objects for one short text string.
  var x = screenX
  for i, ch in text:
    if ch == ' ':
      x += 6
      continue
    let index = letterIndex(ch)
    if index >= 0 and index < sim.letterSprites.len:
      packet.addObject(
        objectBase + i,
        x,
        screenY,
        int(high(int16)) - 1,
        MapLayerId,
        LetterSpriteBase + index
      )
    x += 6

proc cameraXFor(sim: SimServer, player: Actor): int =
  ## Returns the player camera x coordinate.
  worldClampPixel(
    player.x + sim.rabbitSprite.width div 2 - ScreenWidth div 2,
    LevelWidthPixels - ScreenWidth
  )

proc buildSpriteProtocolPlayerUpdates(
  sim: SimServer,
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState
): seq[uint8] =
  ## Builds one sprite protocol update packet for a player viewer.
  nextState = state
  if not nextState.initialized:
    result.addSpriteProtocolInit(sim)
    nextState.initialized = true

  result.addClearObjects()
  result.addObject(
    SkyObjectId,
    0,
    0,
    int(low(int16)),
    MapLayerId,
    SkySpriteId
  )

  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  let
    player = sim.players[playerIndex]
    cameraX = sim.cameraXFor(player)
    cameraY = LevelHeightPixels - ScreenHeight
    startTx = max(0, cameraX div TileSize)
    startTy = max(0, cameraY div TileSize)
    endTx = min(LevelWidthTiles - 1, (cameraX + ScreenWidth - 1) div TileSize)
    endTy = min(
      LevelHeightTiles - 1,
      (cameraY + ScreenHeight - 1) div TileSize
    )

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        tile = sim.tiles[tileIndex(tx, ty)]
        spriteId =
          case tile
          of TileGround:
            GroundSpriteId
          of TileWall:
            WallSpriteId
          of TileGoal:
            GoalSpriteId
          of TileAir:
            0
      if spriteId == 0:
        continue
      result.addObject(
        TileObjectBase + tileIndex(tx, ty),
        tx * TileSize - cameraX,
        ty * TileSize - cameraY,
        0,
        MapLayerId,
        spriteId
      )

  for i in 0 ..< sim.players.len:
    let other = sim.players[i]
    if other.dead:
      continue
    let
      sx = other.x - cameraX - 1
      sy = other.y - cameraY - 1
    result.addObject(
      PlayerObjectBase + i,
      sx,
      sy,
      sy + 100,
      MapLayerId,
      other.color.playerSpriteId(other.facingRight)
    )

  let pcx = player.x + sim.rabbitSprite.width div 2
  for i in 0 ..< sim.players.len:
    if i == playerIndex or sim.players[i].dead:
      continue
    let
      other = sim.players[i]
      ocx = other.x + sim.rabbitSprite.width div 2
      sx = ocx - cameraX
    if sx >= 0 and sx < ScreenWidth:
      continue
    let
      edgeX =
        if ocx < pcx:
          0
        else:
          ScreenWidth - 1
      osy = clamp(other.y - cameraY, 0, ScreenHeight - 1)
    result.addObject(
      RadarObjectBase + i,
      edgeX,
      osy,
      int(high(int16)) - 2,
      MapLayerId,
      other.color.radarSpriteId()
    )

  result.addNumberObjects(sim, player.score, 0, 0, HudObjectBase)
  if player.dead:
    result.addTextObjects(sim, "OOPS!", 17, 20, TextObjectBase)

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
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.closedSockets = @[]
  appState.tokens = @[]

proc inputStateFromMasks(currentMask, previousMask: uint8): InputState =
  result = decodeInputMask(currentMask)
  result.attack = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket in appState.playerViewers:
    appState.playerViewers.del(websocket)
  if websocket notin appState.playerIndices:
    appState.inputMasks.del(websocket)
    appState.lastAppliedMasks.del(websocket)
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

proc resetConnectedPlayers() =
  ## Marks every connected player socket for a fresh simulation join.
  var sockets: seq[WebSocket] = @[]
  for websocket in appState.playerIndices.keys:
    sockets.add(websocket)
  for websocket in sockets:
    appState.playerIndices[websocket] = UnassignedPlayerIndex
    appState.playerViewers[websocket] = PlayerViewerState()
    appState.inputMasks[websocket] = 0
    appState.lastAppliedMasks[websocket] = 0

proc isWebSocketUpgrade(request: Request): bool =
  ## Returns true when the request is a WebSocket upgrade.
  request.headers["Sec-WebSocket-Key"].len > 0

proc respondPlain(request: Request, status: int, body: string) =
  ## Sends a no-cache plain text response.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(status, headers, body)

proc serveHealthz(request: Request): bool =
  ## Serves the container health check endpoint.
  if request.path != HealthzPath or request.httpMethod notin ["GET", "HEAD"]:
    return false
  request.respondPlain(200, "healthy")
  true

proc isPlayerStaticRoute(route: string): bool =
  ## Returns true for the player client static routes Jumper serves.
  case route
  of PlayerClientRoute, PlayerClientHtmlRoute, CoworldPlayerClientRoute,
      SnappyClientRoute, SnappyClientPath, CoworldSnappyClientRoute:
    true
  else:
    false

proc serveClientFile(request: Request, route: string): bool =
  ## Serves one sprite player client static file.
  if request.httpMethod != "GET":
    return false
  let filePath = clientStaticPath(route, GlobalClientRoute)
  if filePath.len == 0:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = clientStaticContentType(route, GlobalClientRoute)
  headers["Cache-Control"] = "no-cache"
  if not fileExists(filePath):
    request.respond(404, headers, "Missing static client: " & route)
    return true
  try:
    request.respond(200, headers, readFile(filePath))
  except IOError as e:
    request.respond(500, headers, "Could not read static client: " & e.msg)
  true

proc servePlayerStatic(request: Request): bool =
  ## Serves the shared sprite client for player-only Jumper routes.
  if not request.path.isPlayerStaticRoute():
    return false
  request.serveClientFile(request.path)

proc playerSlot(request: Request): int =
  ## Returns the requested zero-based slot or -1 for automatic assignment.
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return int.high
  if result < 0:
    return int.high

proc playerToken(request: Request): string =
  ## Returns the player join token.
  request.queryParams.getOrDefault("token", "").strip()

proc playerJoinAllowed(slot: int, token: string): bool =
  ## Returns true when the configured token list accepts the join request.
  if appState.tokens.len == 0:
    return true
  if slot >= 0 and slot < appState.tokens.len:
    return token == appState.tokens[slot]
  if slot == -1:
    return token in appState.tokens
  false

proc httpHandler(request: Request) =
  if request.serveHealthz():
    discard
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      not request.isWebSocketUpgrade():
    discard request.serveClientFile(GlobalClientRoute)
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.playerSlot()
      token = request.playerToken()
    var allowed = false
    {.gcsafe.}:
      withLock appState.lock:
        allowed = playerJoinAllowed(slot, token)
    if not allowed:
      request.respondPlain(403, "player token rejected\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerViewers[websocket] = PlayerViewerState()
        appState.playerIndices[websocket] = UnassignedPlayerIndex
        appState.inputMasks[websocket] = 0
        appState.lastAppliedMasks[websocket] = 0
  elif request.servePlayerStatic():
    discard
  else:
    request.respondPlain(200, "Jumper sprite protocol server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    if message.kind == BinaryMessage and message.data.len == 2 and (
        message.data[0].uint8 == PacketInput or
        message.data[0].uint8 == 0x84'u8
    ):
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.playerViewers:
            appState.inputMasks[websocket] = message.data[1].uint8 and 0x7f'u8
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
  seed = DefaultSeed,
  maxTicks = DefaultMaxTicks,
  maxGames = DefaultMaxGames,
  tokens: seq[string] = @[]
) =
  initAppState()
  appState.tokens = tokens
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
    sim = initSimServer(seed)
    lastTick = getMonoTime()
    runTicks = 0
    gamesFinished = 0

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      playerStates: seq[PlayerViewerState] = @[]
      inputs: seq[InputState]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] == UnassignedPlayerIndex:
            appState.playerIndices[websocket] = sim.addPlayer()

        inputs = newSeq[InputState](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          sockets.add(websocket)
          playerIndices.add(playerIndex)
          playerStates.add(
            appState.playerViewers.getOrDefault(
              websocket,
              PlayerViewerState()
            )
          )
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
          let previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = inputStateFromMasks(currentMask, previousMask)
          appState.lastAppliedMasks[websocket] = currentMask

    sim.step(inputs)
    inc runTicks

    for i in 0 ..< sockets.len:
      var nextState: PlayerViewerState
      let packet = sim.buildSpriteProtocolPlayerUpdates(
        playerIndices[i],
        playerStates[i],
        nextState
      )
      try:
        sockets[i].send(blobFromBytes(packet), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if sockets[i] in appState.playerViewers:
              appState.playerViewers[sockets[i]] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    if maxTicks > 0 and runTicks >= maxTicks:
      inc gamesFinished
      if maxGames > 0 and gamesFinished >= maxGames:
        quit(0)
      sim = initSimServer(seed + gamesFinished)
      runTicks = 0
      {.gcsafe.}:
        withLock appState.lock:
          resetConnectedPlayers()

    runFrameLimiter(lastTick)

proc readConfigString(node: JsonNode, name: string, value: var string) =
  ## Reads one optional string config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(ValueError, "Config field " & name & " must be a string.")
  value = item.getStr()

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  ## Reads one optional integer config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(
      ValueError,
      "Config field " & name & " must be an integer."
    )
  value = item.getInt()

proc readConfigStrings(node: JsonNode, name: string, value: var seq[string]) =
  ## Reads one optional string array config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JArray:
    raise newException(
      ValueError,
      "Config field " & name & " must be an array."
    )
  value.setLen(0)
  for child in item.items:
    if child.kind != JString:
      raise newException(
        ValueError,
        "Config field " & name & " items must be strings."
      )
    value.add(child.getStr())

proc update(config: var RunConfig, jsonText: string) =
  ## Updates the run config from a JSON object.
  if jsonText.len == 0:
    return
  let node = parseJson(jsonText)
  if node.kind != JObject:
    raise newException(ValueError, "Config must be a JSON object.")
  node.readConfigString("address", config.address)
  node.readConfigInt("port", config.port)
  node.readConfigInt("seed", config.seed)
  node.readConfigInt("maxTicks", config.maxTicks)
  node.readConfigInt("max-ticks", config.maxTicks)
  node.readConfigInt("maxGames", config.maxGames)
  node.readConfigInt("max-games", config.maxGames)
  node.readConfigStrings("tokens", config.tokens)

when isMainModule:
  var
    config = RunConfig(
      address: DefaultHost,
      port: DefaultPort,
      seed: DefaultSeed,
      maxTicks: DefaultMaxTicks,
      maxGames: DefaultMaxGames,
      tokens: @[]
    )
    configJson = ""
    configPath = getEnv("COGAME_CONFIG_PATH")
    positional = 0
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if positional == 0:
        config.address = key
      elif positional == 1:
        config.port = parseInt(key)
      inc positional
    of cmdLongOption:
      case key
      of "address": config.address = val
      of "port": config.port = parseInt(val)
      of "seed": config.seed = parseInt(val)
      of "maxTicks", "max-ticks": config.maxTicks = parseInt(val)
      of "maxGames", "max-games": config.maxGames = parseInt(val)
      of "token": config.tokens.add(val)
      of "config": configJson = val
      of "config-file": configPath = val
      else: discard
    else: discard
  if configPath.len > 0:
    config.update(readFile(configPath))
  if configJson.len > 0:
    config.update(configJson)
  runServerLoop(
    config.address,
    config.port,
    seed = config.seed,
    maxTicks = config.maxTicks,
    maxGames = config.maxGames,
    tokens = config.tokens
  )

import std/[os, random]
import bitworld/aseprite
import pixie, protocol
import ../common/server

const
  ArtCellSize* = 32
  WorldTileSize* = ArtCellSize
  SheetTileSize* = ArtCellSize
  GameName* = "big_adventure"
  GameVersion* = "1"
  ReplayMagic* = "BITWORLD"
  ReplayFormatVersion* = 2'u16
  ReplayTickHashRecord* = 0x01'u8
  ReplayInputRecord* = 0x02'u8
  ReplayJoinRecord* = 0x03'u8
  ReplayLeaveRecord* = 0x04'u8
  ReplayFps* = 24
  WorldWidthTiles* = 32
  WorldHeightTiles* = 32
  WorldWidthPixels* = WorldWidthTiles * WorldTileSize
  WorldHeightPixels* = WorldHeightTiles * WorldTileSize
  TargetMobCount* = 48
  TerrainPatchDivisor* = 52
  MinMobSpacing* = 24
  MinPlayerSpawnSpacing* = 24
  SwooshDistanceDivisor* = 3
  MotionScale* = 256
  Accel* = 38
  FrictionNum* = 200
  FrictionDen* = 256
  MaxSpeed* = 352
  StopThreshold* = 8
  MaxPlayerLives* = 5
  SnakeHp* = 3
  TrollHp* = 5
  BossHp* = 10
  BossCoinValue* = 10
  TargetFps* = 24
  SpritePlayerWebSocketPath* = "/sprite_player"
  GlobalWebSocketPath* = "/global"
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
  MessageCharsPerLine* = 16
  MessageLineCount* = 3
  MessageMaxChars* = MessageCharsPerLine * MessageLineCount
  AsciiGlyphW* = 7
  AsciiGlyphH* = 9
  AsciiRowStride* = 9
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
  SwooshSpriteBase* = 304
  TrollSpriteId* = 312
  TerrainSpriteBase* = 320
  SelectedTextSpriteId* = 400
  SelectedViewportSpriteId* = 401
  ReplayTickSpriteId* = 402
  ReplayControlsSpriteId* = 403
  ChatSpriteBase* = 500
  PlayerHudSpriteId* = 600
  PlayerObjectBase* = 1000
  MobObjectBase* = 2000
  PickupObjectBase* = 3000
  SelectedTextObjectId* = 4000
  SelectedViewportObjectId* = 4001
  ReplayTickObjectId* = 4002
  ReplayControlsObjectId* = 4003
  ChatObjectBase* = 5000
  AttackObjectBase* = 6000
  PlayerHudObjectId* = 7000
  TerrainObjectBase* = 8000

type
  PlayerForm* = enum
    MalePlayer
    FemalePlayer

  PlayerPose* = enum
    PlayerFront
    PlayerSide
    PlayerBack

  TerrainKind* = enum
    TerrainTree
    TerrainEvergreen
    TerrainRock
    TerrainLog
    TerrainStump

  RgbaSprite* = object
    width*, height*: int
    pixels*: seq[uint8]

  SpriteBounds* = object
    x*, y*, w*, h*: int

  PlayerArt* = object
    sprites*: array[PlayerPose, Sprite]
    rgbaSprites*: array[PlayerPose, RgbaSprite]
    masks*: array[PlayerPose, Sprite]
    bounds*: array[PlayerPose, SpriteBounds]
    swoosh*: Sprite
    rgbaSwoosh*: RgbaSprite
    swooshBounds*: SpriteBounds

  Actor* = object
    id*: int
    address*: string
    x*, y*: int
    form*: PlayerForm
    sprite*: Sprite
    bounds*: SpriteBounds
    facing*: Facing
    attackTicks*: int
    attackResolved*: bool
    message*: string
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
    TrollMob
    BossMob

  Pickup* = object
    x*, y*: int
    kind*: PickupKind
    value*: int

  Mob* = object
    kind*: MobKind
    x*, y*: int
    sprite*: Sprite
    bounds*: SpriteBounds
    wanderCooldown*: int
    hp*: int
    attackCooldown*: int
    attackPhase*: int
    attackFacing*: Facing

  TerrainProp* = object
    tx*, ty*: int
    kind*: TerrainKind

  SimServer* = object
    players*: seq[Actor]
    mobs*: seq[Mob]
    pickups*: seq[Pickup]
    tiles*: seq[bool]
    terrainKinds*: seq[TerrainKind]
    terrainProps*: seq[TerrainProp]
    playerArts*: array[PlayerForm, PlayerArt]
    playerSprite*: Sprite
    terrainSprite*: Sprite
    rgbaTerrainSprite*: RgbaSprite
    terrainSprites*: array[TerrainKind, Sprite]
    rgbaTerrainSprites*: array[TerrainKind, RgbaSprite]
    terrainBounds*: array[TerrainKind, SpriteBounds]
    mobSprite*: Sprite
    rgbaMobSprite*: RgbaSprite
    mobBounds*: SpriteBounds
    trollSprite*: Sprite
    rgbaTrollSprite*: RgbaSprite
    trollBounds*: SpriteBounds
    bossSprite*: Sprite
    rgbaBossSprite*: RgbaSprite
    bossBounds*: SpriteBounds
    heartSprite*: Sprite
    rgbaHeartSprite*: RgbaSprite
    heartBounds*: SpriteBounds
    coinSprite*: Sprite
    rgbaCoinSprite*: RgbaSprite
    coinBounds*: SpriteBounds
    digitSprites*: array[10, Sprite]
    letterSprites*: seq[Sprite]
    asciiSprites*: seq[Sprite]
    fb*: Framebuffer
    rng*: Rand
    seed*: int
    tickCount*: int
    mobSpawnCooldown*: int
    nextPlayerId*: int

proc dataDir*(): string =
  getCurrentDir() / "data"

proc repoDir*(): string =
  getCurrentDir() / ".."

proc clientDataDir*(): string =
  repoDir() / "clients" / "data"

proc sheetPath*(): string =
  ## Returns the new 32 by 32 Aseprite sheet path.
  let path = dataDir() / "spritesheat.aseprite"
  if fileExists(path):
    return path
  dataDir() / "spritesheet.aseprite"

proc loadClientPalette*() =
  loadPalette(clientDataDir() / "pallete.png")

proc loadClientDigitSprites*(): array[10, Sprite] =
  loadDigitSprites(clientDataDir() / "numbers.png")

proc loadClientLetterSprites*(): seq[Sprite] =
  loadLetterSprites(clientDataDir() / "letters.png")

proc loadClientAsciiSprites*(): seq[Sprite] =
  ## Loads the shared printable ASCII sprite sheet.
  let path = clientDataDir() / "ascii.png"
  if not fileExists(path):
    raise newException(IOError, "Missing ASCII sprite sheet: " & path)
  let
    image = readImage(path)
    cols = image.width div AsciiGlyphW
    rows = image.height div AsciiRowStride
    background = nearestPaletteIndex(image[0, 0])
  result = @[]
  for row in 0 ..< rows:
    for col in 0 ..< cols:
      var sprite = Sprite(width: AsciiGlyphW, height: AsciiGlyphH)
      sprite.pixels = newSeq[uint8](AsciiGlyphW * AsciiGlyphH)
      let
        baseX = col * AsciiGlyphW
        baseY = row * AsciiRowStride
      for y in 0 ..< AsciiGlyphH:
        for x in 0 ..< AsciiGlyphW:
          let colorIndex = nearestPaletteIndex(image[baseX + x, baseY + y])
          sprite.pixels[sprite.spriteIndex(x, y)] =
            if colorIndex == background:
              TransparentColorIndex
            else:
              colorIndex
      result.add(sprite)

proc rgbaSpriteIndex*(sprite: RgbaSprite, x, y: int): int =
  ## Returns the byte offset for one RGBA sprite pixel.
  (y * sprite.width + x) * 4

proc rgbaSpriteFromImage(image: Image): RgbaSprite =
  ## Copies a Pixie image into a straight RGBA sprite.
  result.width = image.width
  result.height = image.height
  result.pixels = newSeq[uint8](result.width * result.height * 4)
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      let
        pixel = image[x, y]
        index = result.rgbaSpriteIndex(x, y)
      result.pixels[index] = pixel.r
      result.pixels[index + 1] = pixel.g
      result.pixels[index + 2] = pixel.b
      result.pixels[index + 3] = pixel.a

proc sheetSprite(sheet: Image, cellX, cellY: int): Sprite =
  ## Slices one 32 by 32 cell as a palette-indexed sprite.
  spriteFromImage(
    sheet.subImage(
      cellX * ArtCellSize,
      cellY * ArtCellSize,
      ArtCellSize,
      ArtCellSize
    )
  )

proc sheetRgbaSprite(sheet: Image, cellX, cellY: int): RgbaSprite =
  ## Slices one 32 by 32 cell as a true-color sprite.
  rgbaSpriteFromImage(
    sheet.subImage(
      cellX * ArtCellSize,
      cellY * ArtCellSize,
      ArtCellSize,
      ArtCellSize
    )
  )

proc visibleBounds*(sprite: Sprite): SpriteBounds =
  ## Measures the exact visible bounds of a palette sprite.
  var
    minX = sprite.width
    minY = sprite.height
    maxX = -1
    maxY = -1
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      if sprite.pixels[sprite.spriteIndex(x, y)] == TransparentColorIndex:
        continue
      minX = min(minX, x)
      minY = min(minY, y)
      maxX = max(maxX, x)
      maxY = max(maxY, y)
  if maxX < minX or maxY < minY:
    return SpriteBounds()
  SpriteBounds(
    x: minX,
    y: minY,
    w: maxX - minX + 1,
    h: maxY - minY + 1
  )

proc visibleBounds*(sprite: RgbaSprite): SpriteBounds =
  ## Measures the exact visible bounds of a true-color sprite.
  var
    minX = sprite.width
    minY = sprite.height
    maxX = -1
    maxY = -1
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      if sprite.pixels[sprite.rgbaSpriteIndex(x, y) + 3] == 0'u8:
        continue
      minX = min(minX, x)
      minY = min(minY, y)
      maxX = max(maxX, x)
      maxY = max(maxY, y)
  if maxX < minX or maxY < minY:
    return SpriteBounds()
  SpriteBounds(
    x: minX,
    y: minY,
    w: maxX - minX + 1,
    h: maxY - minY + 1
  )

proc lowerCenterBounds(bounds: SpriteBounds): SpriteBounds =
  ## Returns a small trunk-like collision box from visible bounds.
  if bounds.w <= 0 or bounds.h <= 0:
    return bounds
  let
    width = max(6, bounds.w div 3)
    height = max(6, bounds.h div 4)
  SpriteBounds(
    x: bounds.x + (bounds.w - width) div 2,
    y: bounds.y + bounds.h - height,
    w: width,
    h: height
  )

proc terrainCollisionBounds*(
  sprite: RgbaSprite,
  kind: TerrainKind
): SpriteBounds =
  ## Measures collision bounds for one terrain prop sprite.
  let bounds = sprite.visibleBounds()
  case kind
  of TerrainTree, TerrainEvergreen:
    bounds.lowerCenterBounds()
  of TerrainRock, TerrainLog, TerrainStump:
    bounds

proc loadPlayerArt(sheet: Image, row: int): PlayerArt =
  ## Loads one adventurer row from the new art sheet.
  result.sprites[PlayerFront] = sheet.sheetSprite(0, row)
  result.sprites[PlayerSide] = sheet.sheetSprite(1, row)
  result.sprites[PlayerBack] = sheet.sheetSprite(2, row)
  result.rgbaSprites[PlayerFront] = sheet.sheetRgbaSprite(0, row)
  result.rgbaSprites[PlayerSide] = sheet.sheetRgbaSprite(1, row)
  result.rgbaSprites[PlayerBack] = sheet.sheetRgbaSprite(2, row)
  result.swoosh = sheet.sheetSprite(3, row)
  result.rgbaSwoosh = sheet.sheetRgbaSprite(3, row)
  result.masks[PlayerFront] = sheet.sheetSprite(4, row)
  result.masks[PlayerSide] = sheet.sheetSprite(5, row)
  result.masks[PlayerBack] = sheet.sheetSprite(6, row)
  result.bounds[PlayerFront] = result.rgbaSprites[PlayerFront].visibleBounds()
  result.bounds[PlayerSide] = result.rgbaSprites[PlayerSide].visibleBounds()
  result.bounds[PlayerBack] = result.rgbaSprites[PlayerBack].visibleBounds()
  result.swooshBounds = result.rgbaSwoosh.visibleBounds()

proc playerPoseForFacing*(facing: Facing): PlayerPose =
  ## Returns the drawn player pose for a movement facing.
  case facing
  of FaceUp:
    PlayerBack
  of FaceDown:
    PlayerFront
  of FaceLeft, FaceRight:
    PlayerSide

proc playerFormForId(playerId: int): PlayerForm =
  ## Splits players evenly between male and female adventurers.
  if playerId mod 2 == 0:
    FemalePlayer
  else:
    MalePlayer

proc terrainPropSprite*(sim: SimServer, kind: TerrainKind): Sprite =
  ## Returns the sprite for one terrain prop kind.
  sim.terrainSprites[kind]

proc terrainPropRgbaSprite*(sim: SimServer, kind: TerrainKind): RgbaSprite =
  ## Returns the true-color sprite for one terrain prop kind.
  sim.rgbaTerrainSprites[kind]

proc terrainPropBounds*(sim: SimServer, kind: TerrainKind): SpriteBounds =
  ## Returns the collision bounds for one terrain prop kind.
  sim.terrainBounds[kind]

proc pickupSprite*(sim: SimServer, kind: PickupKind): Sprite =
  ## Returns the sprite for one pickup kind.
  case kind
  of PickupCoin:
    sim.coinSprite
  of PickupHeart:
    sim.heartSprite

proc pickupRgbaSprite*(sim: SimServer, kind: PickupKind): RgbaSprite =
  ## Returns the true-color sprite for one pickup kind.
  case kind
  of PickupCoin:
    sim.rgbaCoinSprite
  of PickupHeart:
    sim.rgbaHeartSprite

proc pickupBounds*(sim: SimServer, kind: PickupKind): SpriteBounds =
  ## Returns the collision bounds for one pickup kind.
  case kind
  of PickupCoin:
    sim.coinBounds
  of PickupHeart:
    sim.heartBounds

proc playerSpriteFor*(sim: SimServer, player: Actor): Sprite =
  ## Returns the current drawn sprite for one player.
  sim.playerArts[player.form].sprites[player.facing.playerPoseForFacing()]

proc playerRgbaSpriteFor*(sim: SimServer, player: Actor): RgbaSprite =
  ## Returns the current true-color sprite for one player.
  sim.playerArts[player.form].rgbaSprites[player.facing.playerPoseForFacing()]

proc playerBoundsFor*(sim: SimServer, player: Actor): SpriteBounds =
  ## Returns the current collision bounds for one player.
  sim.playerArts[player.form].bounds[player.facing.playerPoseForFacing()]

proc playerMaskFor*(sim: SimServer, player: Actor): Sprite =
  ## Returns the current recolor mask for one player.
  sim.playerArts[player.form].masks[player.facing.playerPoseForFacing()]

proc playerSwooshFor*(sim: SimServer, player: Actor): Sprite =
  ## Returns the attack sprite for one player's form.
  sim.playerArts[player.form].swoosh

proc playerRgbaSwooshFor*(sim: SimServer, player: Actor): RgbaSprite =
  ## Returns the true-color attack sprite for one player's form.
  sim.playerArts[player.form].rgbaSwoosh

proc mobBoundsFor*(sim: SimServer, kind: MobKind): SpriteBounds =
  ## Returns the collision bounds for one mob kind.
  case kind
  of SnakeMob:
    sim.mobBounds
  of TrollMob:
    sim.trollBounds
  of BossMob:
    sim.bossBounds

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

proc boundsCenterX*(x: int, bounds: SpriteBounds): int =
  ## Returns the world x center for one collision bounds.
  x + bounds.x + bounds.w div 2

proc boundsCenterY*(y: int, bounds: SpriteBounds): int =
  ## Returns the world y center for one collision bounds.
  y + bounds.y + bounds.h div 2

proc boundsOverlap*(
  ax, ay: int,
  a: SpriteBounds,
  bx, by: int,
  b: SpriteBounds
): bool =
  ## Returns true when two sprite bounds overlap in world space.
  if a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0:
    return false
  rectsOverlap(
    ax + a.x,
    ay + a.y,
    a.w,
    a.h,
    bx + b.x,
    by + b.y,
    b.w,
    b.h
  )

proc rectOverlapsBounds*(
  x, y, w, h: int,
  bx, by: int,
  bounds: SpriteBounds
): bool =
  ## Returns true when a rectangle overlaps sprite bounds.
  if bounds.w <= 0 or bounds.h <= 0:
    return false
  rectsOverlap(
    x,
    y,
    w,
    h,
    bx + bounds.x,
    by + bounds.y,
    bounds.w,
    bounds.h
  )

proc distanceSquared*(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc canOccupy*(sim: SimServer, x, y: int, bounds: SpriteBounds): bool =
  let
    worldX = x + bounds.x
    worldY = y + bounds.y
  if bounds.w <= 0 or bounds.h <= 0:
    return true
  if worldX < 0 or worldY < 0 or
      worldX + bounds.w > WorldWidthPixels or
      worldY + bounds.h > WorldHeightPixels:
    return false

  let
    startTx = max(0, worldX div WorldTileSize)
    startTy = max(0, worldY div WorldTileSize)
    endTx = min(
      WorldWidthTiles - 1,
      (worldX + bounds.w - 1) div WorldTileSize
    )
    endTy = min(
      WorldHeightTiles - 1,
      (worldY + bounds.h - 1) div WorldTileSize
    )

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      if not sim.tiles[tileIndex(tx, ty)]:
        continue
      let
        kind = sim.terrainKinds[tileIndex(tx, ty)]
        terrainBounds = sim.terrainPropBounds(kind)
        terrainX = tx * WorldTileSize
        terrainY = ty * WorldTileSize
      if boundsOverlap(x, y, bounds, terrainX, terrainY, terrainBounds):
        return false
  true

proc clearSpawnArea*(sim: var SimServer, centerTx, centerTy, radius: int) =
  for ty in centerTy - radius .. centerTy + radius:
    for tx in centerTx - radius .. centerTx + radius:
      if inTileBounds(tx, ty):
        sim.tiles[tileIndex(tx, ty)] = false

proc seedBrush*(sim: var SimServer) =
  let patchCount = max(
    12,
    (WorldWidthTiles * WorldHeightTiles) div TerrainPatchDivisor
  )
  for _ in 0 ..< patchCount:
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

proc randomTerrainKind(rng: var Rand): TerrainKind =
  ## Chooses one terrain prop with more trees than small debris.
  let roll = rng.rand(99)
  if roll < 32:
    TerrainTree
  elif roll < 62:
    TerrainEvergreen
  elif roll < 76:
    TerrainRock
  elif roll < 89:
    TerrainLog
  else:
    TerrainStump

proc seedTerrainProps*(sim: var SimServer) =
  ## Creates visual terrain props for every solid terrain tile.
  sim.terrainProps.setLen(0)
  for ty in 0 ..< WorldHeightTiles:
    for tx in 0 ..< WorldWidthTiles:
      if sim.tiles[tileIndex(tx, ty)]:
        let kind = sim.rng.randomTerrainKind()
        sim.terrainKinds[tileIndex(tx, ty)] = kind
        sim.terrainProps.add(TerrainProp(
          tx: tx,
          ty: ty,
          kind: kind
        ))

proc nextMobAttackCooldown(rng: var Rand, kind: MobKind): int =
  ## Returns the cooldown before the next mob hit.
  case kind
  of SnakeMob:
    45 + rng.rand(30)
  of TrollMob:
    16 + rng.rand(14)
  of BossMob:
    35 + rng.rand(25)

proc canSpawnMobAt*(
  sim: SimServer,
  px, py: int,
  bounds: SpriteBounds
): bool =
  if not sim.canOccupy(px, py, bounds):
    return false

  let mobSpacingSq = MinMobSpacing * MinMobSpacing
  for mob in sim.mobs:
    let
      ax = boundsCenterX(px, bounds)
      ay = boundsCenterY(py, bounds)
      bx = boundsCenterX(mob.x, mob.bounds)
      by = boundsCenterY(mob.y, mob.bounds)
    if distanceSquared(ax, ay, bx, by) < mobSpacingSq:
      return false

  if sim.players.len > 0:
    for player in sim.players:
      let
        ax = boundsCenterX(px, bounds)
        ay = boundsCenterY(py, bounds)
        bx = boundsCenterX(player.x, player.bounds)
        by = boundsCenterY(player.y, player.bounds)
      if distanceSquared(ax, ay, bx, by) <
          MinPlayerSpawnSpacing * MinPlayerSpawnSpacing:
        return false

  true

proc spawnOneMob*(
  sim: var SimServer,
  kind: MobKind,
  sprite: Sprite,
  hp: int
): bool =
  let bounds = sim.mobBoundsFor(kind)
  for _ in 0 ..< 128:
    let
      tx = sim.rng.rand(WorldWidthTiles - 1)
      ty = sim.rng.rand(WorldHeightTiles - 1)
      px = tx * WorldTileSize
      py = ty * WorldTileSize
    if sim.canSpawnMobAt(px, py, bounds):
      sim.mobs.add Mob(
        kind: kind,
        x: px,
        y: py,
        sprite: sprite,
        bounds: bounds,
        wanderCooldown: 8 + sim.rng.rand(18),
        hp: hp,
        attackCooldown: sim.rng.nextMobAttackCooldown(kind)
      )
      return true
  false

proc spawnMobs*(
  sim: var SimServer,
  count: int,
  kind: MobKind,
  sprite: Sprite,
  hp: int
) =
  var spawned = 0
  while spawned < count:
    if not sim.spawnOneMob(kind, sprite, hp):
      break
    inc spawned

proc snakeCount*(sim: SimServer): int =
  for mob in sim.mobs:
    if mob.kind != BossMob:
      inc result

proc hasBoss*(sim: SimServer): bool =
  for mob in sim.mobs:
    if mob.kind == BossMob:
      return true

proc mobAttackRange*(mob: Mob): int =
  12 + max(mob.bounds.w, mob.bounds.h)

proc mobMaxHp*(mob: Mob): int =
  ## Returns the maximum hit points for one mob.
  case mob.kind
  of SnakeMob:
    SnakeHp
  of TrollMob:
    TrollHp
  of BossMob:
    BossHp

proc findPlayerSpawn*(
  sim: SimServer,
  bounds: SpriteBounds
): tuple[x, y: int] =
  let
    centerTx = WorldWidthTiles div 2
    centerTy = WorldHeightTiles div 2
    minSpacingSq = MinPlayerSpawnSpacing * MinPlayerSpawnSpacing

  for radius in 0 .. 8:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        let
          tx = centerTx + dx
          ty = centerTy + dy
        if not inTileBounds(tx, ty):
          continue
        let
          px = tx * WorldTileSize
          py = ty * WorldTileSize
        if not sim.canOccupy(px, py, bounds):
          continue
        var tooClose = false
        for player in sim.players:
          let
            ax = boundsCenterX(px, bounds)
            ay = boundsCenterY(py, bounds)
            bx = boundsCenterX(player.x, player.bounds)
            by = boundsCenterY(player.y, player.bounds)
          if distanceSquared(ax, ay, bx, by) < minSpacingSq:
            tooClose = true
            break
        if not tooClose:
          return (px, py)

  (centerTx * WorldTileSize, centerTy * WorldTileSize)

proc addPlayer*(sim: var SimServer, address: string): int =
  inc sim.nextPlayerId
  let form = sim.nextPlayerId.playerFormForId()
  let bounds = sim.playerArts[form].bounds[PlayerFront]
  let spawn = sim.findPlayerSpawn(bounds)
  sim.players.add Actor(
    id: sim.nextPlayerId,
    address: address,
    x: spawn.x,
    y: spawn.y,
    form: form,
    sprite: sim.playerArts[form].sprites[PlayerFront],
    bounds: bounds,
    facing: FaceDown,
    lives: MaxPlayerLives
  )
  sim.players.high

proc initSimServer*(seed = 0xB1770): SimServer =
  result.seed = seed
  result.rng = initRand(seed)
  result.tiles = newSeq[bool](WorldWidthTiles * WorldHeightTiles)
  result.terrainKinds = newSeq[TerrainKind](WorldWidthTiles * WorldHeightTiles)
  result.fb = initFramebuffer()
  loadClientPalette()
  let sheet = readAsepriteImage(sheetPath())
  result.playerArts[MalePlayer] = sheet.loadPlayerArt(0)
  result.playerArts[FemalePlayer] = sheet.loadPlayerArt(1)
  result.playerSprite = result.playerArts[MalePlayer].sprites[PlayerFront]
  result.mobSprite = sheet.sheetSprite(0, 2)
  result.rgbaMobSprite = sheet.sheetRgbaSprite(0, 2)
  result.mobBounds = result.rgbaMobSprite.visibleBounds()
  result.trollSprite = sheet.sheetSprite(1, 2)
  result.rgbaTrollSprite = sheet.sheetRgbaSprite(1, 2)
  result.trollBounds = result.rgbaTrollSprite.visibleBounds()
  result.bossSprite = sheet.sheetSprite(2, 2)
  result.rgbaBossSprite = sheet.sheetRgbaSprite(2, 2)
  result.bossBounds = result.rgbaBossSprite.visibleBounds()
  result.terrainSprite = sheet.sheetSprite(0, 3)
  result.rgbaTerrainSprite = sheet.sheetRgbaSprite(0, 3)
  result.terrainSprites[TerrainTree] = sheet.sheetSprite(1, 3)
  result.rgbaTerrainSprites[TerrainTree] = sheet.sheetRgbaSprite(1, 3)
  result.terrainBounds[TerrainTree] =
    result.rgbaTerrainSprites[TerrainTree].terrainCollisionBounds(TerrainTree)
  result.terrainSprites[TerrainEvergreen] = sheet.sheetSprite(2, 3)
  result.rgbaTerrainSprites[TerrainEvergreen] = sheet.sheetRgbaSprite(2, 3)
  result.terrainBounds[TerrainEvergreen] =
    result.rgbaTerrainSprites[TerrainEvergreen].terrainCollisionBounds(
      TerrainEvergreen
    )
  result.terrainSprites[TerrainRock] = sheet.sheetSprite(3, 3)
  result.rgbaTerrainSprites[TerrainRock] = sheet.sheetRgbaSprite(3, 3)
  result.terrainBounds[TerrainRock] =
    result.rgbaTerrainSprites[TerrainRock].terrainCollisionBounds(TerrainRock)
  result.terrainSprites[TerrainLog] = sheet.sheetSprite(4, 3)
  result.rgbaTerrainSprites[TerrainLog] = sheet.sheetRgbaSprite(4, 3)
  result.terrainBounds[TerrainLog] =
    result.rgbaTerrainSprites[TerrainLog].terrainCollisionBounds(TerrainLog)
  result.terrainSprites[TerrainStump] = sheet.sheetSprite(5, 3)
  result.rgbaTerrainSprites[TerrainStump] = sheet.sheetRgbaSprite(5, 3)
  result.terrainBounds[TerrainStump] =
    result.rgbaTerrainSprites[TerrainStump].terrainCollisionBounds(
      TerrainStump
    )
  result.coinSprite = sheet.sheetSprite(0, 4)
  result.rgbaCoinSprite = sheet.sheetRgbaSprite(0, 4)
  result.coinBounds = result.rgbaCoinSprite.visibleBounds()
  result.heartSprite = sheet.sheetSprite(1, 4)
  result.rgbaHeartSprite = sheet.sheetRgbaSprite(1, 4)
  result.heartBounds = result.rgbaHeartSprite.visibleBounds()
  result.digitSprites = loadClientDigitSprites()
  result.letterSprites = loadClientLetterSprites()
  result.asciiSprites = loadClientAsciiSprites()

  result.seedBrush()
  let startTx = WorldWidthTiles div 2
  let startTy = WorldHeightTiles div 2
  result.clearSpawnArea(startTx, startTy, 5)
  result.seedTerrainProps()

  result.players = @[]
  result.spawnMobs(28, SnakeMob, result.mobSprite, SnakeHp)
  result.spawnMobs(8, TrollMob, result.trollSprite, TrollHp)
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
      if sim.canOccupy(nx, actor.y, actor.bounds):
        actor.x = nx
      else:
        break

  if dy != 0:
    let stepY = (if dy < 0: -1 else: 1)
    for _ in 0 ..< abs(dy):
      let ny = actor.y + stepY
      if sim.canOccupy(actor.x, ny, actor.bounds):
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
      if sim.canOccupy(actor.x + step, actor.y, actor.bounds):
        actor.x += step
        carry -= step * MotionScale
      else:
        carry = 0
        break
    else:
      if sim.canOccupy(actor.x, actor.y + step, actor.bounds):
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
  player.bounds = sim.playerBoundsFor(player)

  sim.applyMomentumAxis(player, player.carryX, player.velX, true)
  sim.applyMomentumAxis(player, player.carryY, player.velY, false)
  if input.attack and player.attackTicks == 0:
    player.attackTicks = 5
    player.attackResolved = false

proc attackRect*(sim: SimServer, player: Actor): tuple[x, y, w, h: int] =
  let sprite = sim.playerSwooshFor(player)
  let
    width =
      if player.facing in {FaceUp, FaceDown}:
        sprite.width
      else:
        sprite.height
    height =
      if player.facing in {FaceUp, FaceDown}:
        sprite.height
      else:
        sprite.width
    closeX = max(1, width div SwooshDistanceDivisor)
    closeY = max(1, height div SwooshDistanceDivisor)
    playerCenterX = player.x + player.sprite.width div 2
    playerCenterY = player.y + player.sprite.height div 2
  case player.facing
  of FaceUp:
    (playerCenterX - width div 2, player.y - closeY, width, height)
  of FaceDown:
    (
      playerCenterX - width div 2,
      player.y + player.sprite.height - closeY,
      width,
      height
    )
  of FaceLeft:
    (player.x - closeX, playerCenterY - height div 2, width, height)
  of FaceRight:
    (
      player.x + player.sprite.width - closeX,
      playerCenterY - height div 2,
      width,
      height
    )

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
    sprite: sim.players[playerIndex].sprite,
    bounds: sim.players[playerIndex].bounds
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
      if sim.mobs[mobIndex].kind != BossMob and mobDamaged[mobIndex]:
        continue
      if rectOverlapsBounds(
        hit.x,
        hit.y,
        hit.w,
        hit.h,
        sim.mobs[mobIndex].x,
        sim.mobs[mobIndex].y,
        sim.mobs[mobIndex].bounds
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
          var actor = Actor(
            x: sim.mobs[mobIndex].x,
            y: sim.mobs[mobIndex].y,
            sprite: sim.mobs[mobIndex].sprite,
            bounds: sim.mobs[mobIndex].bounds
          )
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
      if rectOverlapsBounds(
        hit.x,
        hit.y,
        hit.w,
        hit.h,
        targetPlayer.x,
        targetPlayer.y,
        targetPlayer.bounds
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
      var actor = Actor(
        x: sim.mobs[mobIndex].x,
        y: sim.mobs[mobIndex].y,
        sprite: sim.mobs[mobIndex].sprite,
        bounds: sim.mobs[mobIndex].bounds
      )
      sim.moveActor(actor, knockbackX, knockbackY)
      sim.mobs[mobIndex].x = actor.x
      sim.mobs[mobIndex].y = actor.y

  var survivors: seq[Mob] = @[]
  for mob in sim.mobs:
    if mob.hp > 0:
      survivors.add(mob)
    else:
      if mob.kind == BossMob:
        let sprite = sim.pickupSprite(PickupCoin)
        sim.pickups.add(Pickup(
          x: mob.x + mob.sprite.width div 2 - sprite.width div 2,
          y: mob.y + mob.sprite.height div 2 - sprite.height div 2,
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
    let bounds = sim.pickupBounds(pickup.kind)
    var collected = false
    for playerIndex in 0 ..< sim.players.len:
      let player = sim.players[playerIndex]
      if player.lives <= 0:
        continue
      if boundsOverlap(
        pickup.x,
        pickup.y,
        bounds,
        player.x,
        player.y,
        player.bounds
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
      centerX = boundsCenterX(mob.x, mob.bounds)
      centerY = boundsCenterY(mob.y, mob.bounds)
    for playerIndex in 0 ..< sim.players.len:
      let player = sim.players[playerIndex]
      if player.lives <= 0:
        continue
      let
        playerCenterX = boundsCenterX(player.x, player.bounds)
        playerCenterY = boundsCenterY(player.y, player.bounds)
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
        playerCenterX = boundsCenterX(player.x, player.bounds)
        playerCenterY = boundsCenterY(player.y, player.bounds)
      let attackRange = mob.mobAttackRange()
      if mob.attackCooldown == 0 and distanceSquared(centerX, centerY, playerCenterX, playerCenterY) <= attackRange * attackRange:
        mob.attackFacing = chooseFacing(centerX, centerY, playerCenterX, playerCenterY)
        let back = lungeVector(mob.attackFacing, -1)
        var actor = Actor(
          x: mob.x,
          y: mob.y,
          sprite: mob.sprite,
          bounds: mob.bounds
        )
        sim.moveActor(actor, back.dx, back.dy)
        mob.x = actor.x
        mob.y = actor.y
        mob.attackPhase = 1
        continue

    elif mob.attackPhase == 1:
      let lunge = lungeVector(mob.attackFacing, 4)
      var actor = Actor(
        x: mob.x,
        y: mob.y,
        sprite: mob.sprite,
        bounds: mob.bounds
      )
      sim.moveActor(actor, lunge.dx, lunge.dy)
      mob.x = actor.x
      mob.y = actor.y
      for playerIndex in 0 ..< sim.players.len:
        let player = sim.players[playerIndex]
        if player.lives <= 0:
          continue
        if player.invulnTicks == 0 and boundsOverlap(
          mob.x,
          mob.y,
          mob.bounds,
          player.x,
          player.y,
          player.bounds
        ):
          sim.damagePlayer(playerIndex, lunge.dx, lunge.dy)
      mob.attackPhase = 0
      mob.attackCooldown = sim.rng.nextMobAttackCooldown(mob.kind)
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

    var actor = Actor(
      x: mob.x,
      y: mob.y,
      sprite: mob.sprite,
      bounds: mob.bounds
    )
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

  if sim.rng.rand(99) < 20:
    discard sim.spawnOneMob(TrollMob, sim.trollSprite, TrollHp)
  else:
    discard sim.spawnOneMob(SnakeMob, sim.mobSprite, SnakeHp)
  sim.mobSpawnCooldown = 24 + sim.rng.rand(24)

proc renderTerrain*(sim: var SimServer, cameraX, cameraY: int) =
  let
    startTx = max(0, cameraX div WorldTileSize)
    startTy = max(0, cameraY div WorldTileSize)
    endTx = min(
      WorldWidthTiles - 1,
      (cameraX + ScreenWidth - 1) div WorldTileSize
    )
    endTy = min(
      WorldHeightTiles - 1,
      (cameraY + ScreenHeight - 1) div WorldTileSize
    )

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        x = tx * WorldTileSize
        y = ty * WorldTileSize
      sim.fb.blitSprite(sim.terrainSprite, x, y, cameraX, cameraY)
      if sim.tiles[tileIndex(tx, ty)]:
        let sprite = sim.terrainSprites[sim.terrainKinds[tileIndex(tx, ty)]]
        sim.fb.blitSprite(sprite, x, y, cameraX, cameraY)

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

proc blitActorSprite(
  fb: var Framebuffer,
  sprite, mask: Sprite,
  worldX, worldY, cameraX, cameraY: int,
  tint: uint8,
  flipX = false
) =
  ## Draws one actor sprite while recoloring only its mask pixels.
  let
    screenX = worldX - cameraX
    screenY = worldY - cameraY
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let sourceX =
        if flipX:
          sprite.width - 1 - x
        else:
          x
      let colorIndex = sprite.pixels[sprite.spriteIndex(sourceX, y)]
      if colorIndex == TransparentColorIndex:
        continue
      let
        drawIndex =
          if sourceX < mask.width and y < mask.height and
              mask.pixels[mask.spriteIndex(sourceX, y)] !=
                  TransparentColorIndex:
            tint
          else:
            colorIndex
      fb.putPixel(screenX + x, screenY + y, drawIndex)

proc renderHud*(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  let
    player = sim.players[playerIndex]
    coins = min(player.coins, 99)

  sim.fb.renderNumber(sim.digitSprites, coins, 0, 0)
  sim.fb.blitText(sim.letterSprites, "LIVES", 34, 0)
  sim.fb.renderNumber(sim.digitSprites, player.lives, 70, 0)

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
    pcx = boundsCenterX(player.x, player.bounds)
    pcy = boundsCenterY(player.y, player.bounds)
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
      mcx = boundsCenterX(mob.x, mob.bounds)
      mcy = boundsCenterY(mob.y, mob.bounds)
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
      ocx = boundsCenterX(other.x, other.bounds)
      ocy = boundsCenterY(other.y, other.bounds)
      sx = ocx - cameraX
      sy = ocy - cameraY
    if sx >= 0 and sx < ScreenWidth and sy >= 0 and sy < ScreenHeight:
      continue
    let
      dx = ocx - pcx
      dy = ocy - pcy
      pos = projectToEdge(dx, dy)
    fb.putPixel(pos.x, pos.y, playerColor(i))

proc render*(sim: var SimServer, playerIndex: int): seq[uint8] =
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
      sim.fb.blitActorSprite(
        sim.playerSpriteFor(otherPlayer),
        sim.playerMaskFor(otherPlayer),
        otherPlayer.x,
        otherPlayer.y,
        cameraX,
        cameraY,
        playerColor(i),
        otherPlayer.facing == FaceLeft
      )
  for otherPlayer in sim.players:
    if otherPlayer.lives > 0 and otherPlayer.attackTicks > 0:
      let hit = sim.attackRect(otherPlayer)
      sim.fb.blitSprite(
        sim.playerSwooshFor(otherPlayer),
        hit.x,
        hit.y,
        cameraX,
        cameraY,
        otherPlayer.facing
      )
  for mob in sim.mobs:
    let
      maxHp = mob.mobMaxHp()
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

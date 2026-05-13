import
  std/[json, locks, monotimes, os, parseopt, random, strutils, tables, times],
  mummy, pixie, supersnappy,
  bitworld/aseprite, bitworld/clients, bitworld/tiled, protocol, server

const
  DefaultSeed = 0xB1770
  DefaultMaxTicks = 0
  DefaultMaxGames = 0
  UnassignedPlayerIndex = 0x7fffffff
  SheetTileSize = 32
  SheetColumns = 8
  WorldTileSize = 32
  PlayerSpriteSize = 32
  PlayerBoxWidth = 20
  PlayerBoxHeight = 23
  PlayerSpriteOffsetX = (PlayerSpriteSize - PlayerBoxWidth) div 2
  PlayerSpriteOffsetY = PlayerSpriteSize - PlayerBoxHeight
  PlayerFrameCount = 4
  PlayerDirectionCount = 2
  PlayerSpritesPerColor = PlayerFrameCount * PlayerDirectionCount
  LevelWidthTiles = 64
  LevelHeightTiles = 16
  LevelWidthPixels = LevelWidthTiles * WorldTileSize
  LevelHeightPixels = LevelHeightTiles * WorldTileSize
  ViewportWidth = 320
  ViewportHeight = 200
  MotionScale = 256
  AccelX = 171
  FrictionNum = 200
  FrictionDen = 256
  MaxSpeedX = 1707
  StopThreshold = 43
  Gravity = 256
  JumpVel = -3594
  MaxFallSpeed = 5333
  TargetFps = 24.0
  HealthzPath = "/healthz"
  WebSocketPath = "/player"
  GlobalWebSocketPath = "/global"
  SkyColor = 14'u8
  PlayerColors = [3'u8, 7, 8, 14, 4, 11]
  DeathY = LevelHeightPixels + WorldTileSize * 2
  SpawnWidthTiles = 9
  SpawnAirTiles = 4
  TiledLayerName = "Tile Layer 1"
  FlagGid = 15
  SignGid = 60
  MapLayerId = 0
  MapLayerKind = 0
  MapLayerFlags = 1
  SkySpriteId = 1
  DigitSpriteBase = 20
  LetterSpriteBase = 40
  PlayerSpriteBase = 100
  RadarSpriteBase = 200
  TiledSpriteBase = 300
  SkyObjectId = 1
  TileObjectBase = 1000
  PlayerObjectBase = 5000
  RadarObjectBase = 6000
  HudObjectBase = 7000
  TextObjectBase = 7100
  ChatSpriteBase = 9000
  ChatObjectBase = 9000
  DebugPlayerBoxSpriteId = 900
  DebugPlayerBoxObjectBase = 8000
  DebugPlayerBounds = false
  OverlapResolvePasses = 4
  ChatMaxChars = 24
  ChatPad = 3
  ChatPointerHeight = 3
  ChatGapY = 4

type
  HsvColor = object
    h, s, v: float

  RgbaSprite = object
    width, height: int
    pixels: seq[uint8]

  Rect = object
    x, y, w, h: int

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
    message: string

  TileKind = enum
    TileAir
    TileDecoration
    TileGround
    TileWall
    TileGoal

  PlayerFrame = enum
    PlayerStand
    PlayerWalkA
    PlayerWalkB
    PlayerJump

  SimServer = object
    players: seq[Actor]
    tiles: seq[TileKind]
    tileGids: seq[int]
    tileSprites: Table[int, RgbaSprite]
    playerFrames: array[PlayerFrame, RgbaSprite]
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
    globalViewers: Table[WebSocket, PlayerViewerState]
    chatMessages: Table[WebSocket, string]
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
  dataDir() / "spritesheet.aseprite"

proc tiledProjectPath(): string =
  dataDir() / "forest.tiled-project"

proc tiledSessionPath(): string =
  dataDir() / "forest.tiled-session"

proc tiledMapPath(): string =
  dataDir() / "forest.tmx"

proc loadClientPalette() =
  loadPalette(clientDataDir() / "pallete.png")

proc loadClientDigitSprites(): array[10, Sprite] =
  loadDigitSprites(clientDataDir() / "numbers.png")

proc loadClientLetterSprites(): seq[Sprite] =
  loadLetterSprites(clientDataDir() / "letters.png")

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

proc rgbaPixel(sprite: RgbaSprite, x, y: int): ColorRGBA =
  ## Reads one pixel from an RGBA sprite.
  if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height:
    return rgba(0, 0, 0, 0)
  let offset = (y * sprite.width + x) * 4
  rgba(
    sprite.pixels[offset],
    sprite.pixels[offset + 1],
    sprite.pixels[offset + 2],
    sprite.pixels[offset + 3]
  )

proc sheetRgbaSprite(sheet: Image, cellX, cellY: int): RgbaSprite =
  ## Slices one 32 pixel cell from the sprite sheet as RGBA.
  result = newRgbaSprite(SheetTileSize, SheetTileSize)
  let image = sheet.subImage(
    cellX * SheetTileSize,
    cellY * SheetTileSize,
    SheetTileSize,
    SheetTileSize
  )
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      result.putRgbaPixel(x, y, image[x, y])

proc sheetGidSprite(sheet: Image, gid: int): RgbaSprite =
  ## Slices one Tiled gid cell from the sprite sheet as RGBA.
  if gid <= 0:
    raise newException(TiledError, "Tiled gid must be positive: " & $gid)
  let
    index = gid - 1
    cellX = index mod SheetColumns
    cellY = index div SheetColumns
  if (cellX + 1) * SheetTileSize > sheet.width or
      (cellY + 1) * SheetTileSize > sheet.height:
    raise newException(
      TiledError,
      "Tiled gid " & $gid & " is outside the sprite sheet"
    )
  sheet.sheetRgbaSprite(cellX, cellY)

proc rgbToHsv(color: ColorRGBA): HsvColor =
  ## Converts one RGBA color to HSV while ignoring alpha.
  let
    r = color.r.float / 255.0
    g = color.g.float / 255.0
    b = color.b.float / 255.0
    maxValue = max(r, max(g, b))
    minValue = min(r, min(g, b))
    delta = maxValue - minValue
  result.v = maxValue
  if maxValue <= 0.0:
    result.s = 0.0
  else:
    result.s = delta / maxValue

  if delta <= 0.0:
    result.h = 0.0
  elif maxValue == r:
    result.h = (g - b) / delta
    if result.h < 0.0:
      result.h += 6.0
    result.h /= 6.0
  elif maxValue == g:
    result.h = ((b - r) / delta + 2.0) / 6.0
  else:
    result.h = ((r - g) / delta + 4.0) / 6.0

proc toColor(hsv: HsvColor, alpha: uint8): ColorRGBA =
  ## Converts HSV plus alpha to an RGBA color.
  if hsv.s <= 0.0:
    let gray = uint8(clamp(int(hsv.v * 255.0 + 0.5), 0, 255))
    return rgba(gray, gray, gray, alpha)

  var h = hsv.h
  while h < 0.0:
    h += 1.0
  while h >= 1.0:
    h -= 1.0
  let
    scaled = h * 6.0
    sector = min(5, int(scaled))
    f = scaled - sector.float
    p = hsv.v * (1.0 - hsv.s)
    q = hsv.v * (1.0 - hsv.s * f)
    t = hsv.v * (1.0 - hsv.s * (1.0 - f))

  proc channel(value: float): uint8 =
    uint8(clamp(int(value * 255.0 + 0.5), 0, 255))

  case sector
  of 0:
    rgba(channel(hsv.v), channel(t), channel(p), alpha)
  of 1:
    rgba(channel(q), channel(hsv.v), channel(p), alpha)
  of 2:
    rgba(channel(p), channel(hsv.v), channel(t), alpha)
  of 3:
    rgba(channel(p), channel(q), channel(hsv.v), alpha)
  of 4:
    rgba(channel(t), channel(p), channel(hsv.v), alpha)
  else:
    rgba(channel(hsv.v), channel(p), channel(q), alpha)

proc isProtectedPlayerPixel(color: ColorRGBA): bool =
  ## Returns true for player colors that must keep their source hue.
  color.r == 0xee'u8 and
    color.g == 0xb8'u8 and
    color.b == 0x85'u8

proc isPlayerTintPixel(color: ColorRGBA): bool =
  ## Returns true for red player pixels that should be hue shifted.
  if color.a == 0 or color.isProtectedPlayerPixel():
    return false

  let hsv = color.rgbToHsv()
  hsv.s >= 0.35 and
    hsv.v >= 0.25 and
    (hsv.h <= 0.04 or hsv.h >= 0.94)

proc tintPlayerPixel(color: ColorRGBA, targetHue: float): ColorRGBA =
  ## Hue shifts one saturated red player pixel.
  if not color.isPlayerTintPixel():
    return color
  var hsv = color.rgbToHsv()
  hsv.h = targetHue
  hsv.toColor(color.a)

proc tintPlayerSprite(
  sprite: RgbaSprite,
  color: uint8,
  flipX: bool
): RgbaSprite =
  ## HSV-tints and optionally flips one player frame.
  result = newRgbaSprite(sprite.width, sprite.height)
  let targetHue = rgbaColor(color).rgbToHsv().h
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let
        dx =
          if flipX:
            sprite.width - 1 - x
          else:
            x
        source = sprite.rgbaPixel(x, y)
      result.putRgbaPixel(dx, y, source.tintPlayerPixel(targetHue))

proc solidRgbaSprite(width, height: int, color: uint8): RgbaSprite =
  ## Builds one solid RGBA sprite from a palette index.
  result = newRgbaSprite(width, height)
  let rgba = rgbaColor(color)
  for y in 0 ..< height:
    for x in 0 ..< width:
      result.putRgbaPixel(x, y, rgba)

proc outlineRgbaSprite(width, height: int, color: ColorRGBA): RgbaSprite =
  ## Builds a transparent outline sprite.
  result = newRgbaSprite(width, height)
  if width <= 0 or height <= 0:
    return
  for x in 0 ..< width:
    result.putRgbaPixel(x, 0, color)
    result.putRgbaPixel(x, height - 1, color)
  for y in 0 ..< height:
    result.putRgbaPixel(0, y, color)
    result.putRgbaPixel(width - 1, y, color)

proc spriteToRgba(sprite: Sprite): RgbaSprite =
  ## Converts one indexed sprite to the sprite protocol RGBA format.
  result = newRgbaSprite(sprite.width, sprite.height)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let color = sprite.pixels[sprite.spriteIndex(x, y)]
      result.putRgbaPixel(x, y, rgbaColor(color))

proc chatCharSupported(ch: char): bool =
  ## Returns true when Jumper can draw one chat character.
  if ch == ' ' or (ch >= '0' and ch <= '9'):
    return true
  letterIndex(ch) >= 0

proc cleanChatMessage(message: string): string =
  ## Normalizes one submitted player chat message.
  for ch in message.strip():
    if result.len >= ChatMaxChars:
      return
    if ch.chatCharSupported():
      result.add(ch)

proc chatGlyphWidth(sim: SimServer, ch: char): int =
  ## Returns the sprite protocol width for one chat character.
  if ch == ' ':
    return 4
  if ch >= '0' and ch <= '9':
    return sim.digitSprites[ord(ch) - ord('0')].width
  let index = letterIndex(ch)
  if index >= 0 and index < sim.letterSprites.len:
    return sim.letterSprites[index].width
  0

proc chatTextWidth(sim: SimServer, text: string): int =
  ## Returns the rendered width of one chat line.
  for ch in text:
    result += sim.chatGlyphWidth(ch)

proc blitChatGlyph(
  target: var RgbaSprite,
  glyph: Sprite,
  x, y: int,
  color: ColorRGBA
) =
  ## Blits one indexed glyph into a chat bubble.
  for gy in 0 ..< glyph.height:
    for gx in 0 ..< glyph.width:
      let source = glyph.pixels[glyph.spriteIndex(gx, gy)]
      if source != TransparentColorIndex:
        target.putRgbaPixel(x + gx, y + gy, color)

proc blitChatText(
  sim: SimServer,
  target: var RgbaSprite,
  text: string,
  x, y: int
) =
  ## Blits one chat line into a chat bubble.
  var dx = x
  let color = rgba(0, 0, 0, 255)
  for ch in text:
    if ch == ' ':
      dx += sim.chatGlyphWidth(ch)
      continue
    if ch >= '0' and ch <= '9':
      let glyph = sim.digitSprites[ord(ch) - ord('0')]
      target.blitChatGlyph(glyph, dx, y, color)
      dx += glyph.width
      continue
    let index = letterIndex(ch)
    if index >= 0 and index < sim.letterSprites.len:
      let glyph = sim.letterSprites[index]
      target.blitChatGlyph(glyph, dx, y, color)
      dx += glyph.width

proc speechBubbleSprite(sim: SimServer, text: string): RgbaSprite =
  ## Builds one speech bubble sprite for a player message.
  let
    textWidth = max(6, sim.chatTextWidth(text))
    lineHeight = 6
    bodyWidth = textWidth + ChatPad * 2
    bodyHeight = lineHeight + ChatPad * 2
    fill = rgba(255, 255, 255, 235)
    border = rgba(0, 0, 0, 255)
  result = newRgbaSprite(bodyWidth, bodyHeight + ChatPointerHeight)
  for y in 0 ..< bodyHeight:
    for x in 0 ..< bodyWidth:
      result.putRgbaPixel(x, y, fill)
  for x in 0 ..< bodyWidth:
    result.putRgbaPixel(x, 0, border)
    result.putRgbaPixel(x, bodyHeight - 1, border)
  for y in 0 ..< bodyHeight:
    result.putRgbaPixel(0, y, border)
    result.putRgbaPixel(bodyWidth - 1, y, border)
  let pointerX = bodyWidth div 2
  for y in 0 ..< ChatPointerHeight:
    let span = ChatPointerHeight - y - 1
    for x in pointerX - span .. pointerX + span:
      result.putRgbaPixel(x, bodyHeight + y, border)
  sim.blitChatText(result, text, ChatPad, ChatPad)

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

proc isPassThroughGid(gid: int): bool =
  ## Returns true when a rendered tile should not collide.
  case gid
  of SignGid:
    true
  else:
    false

proc worldClampPixel(x, maxValue: int): int =
  x.clamp(0, maxValue)

proc rectsOverlap(ax, ay, aw, ah, bx, by, bw, bh: int): bool =
  ax < bx + bw and
  ax + aw > bx and
  ay < by + bh and
  ay + ah > by

proc collidesWithTiles(sim: SimServer, x, y, w, h: int): bool =
  let
    startTx = x div WorldTileSize
    startTy = y div WorldTileSize
    endTx = (x + w - 1) div WorldTileSize
    endTy = (y + h - 1) div WorldTileSize
  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      if sim.getTile(tx, ty).isSolid:
        return true
  false

proc tileKindForGid(gid: int): TileKind =
  ## Returns the Jumper tile kind for one Tiled gid.
  case gid
  of 0:
    TileAir
  of FlagGid:
    TileGoal
  else:
    if gid.isPassThroughGid():
      TileDecoration
    else:
      TileGround

proc buildLevel(sim: var SimServer) =
  ## Loads the Jumper level from the Tiled forest map.
  let
    workspace = loadTiledWorkspace(
      tiledProjectPath(),
      tiledSessionPath(),
      tiledMapPath()
    )
    map = workspace.map
    layer = map.layerByName(TiledLayerName)

  if map.width != LevelWidthTiles or map.height != LevelHeightTiles:
    raise newException(
      TiledError,
      "Forest map size must be " & $LevelWidthTiles & "x" &
        $LevelHeightTiles & ", got " & $map.width & "x" & $map.height
    )
  if map.tileWidth != WorldTileSize or map.tileHeight != WorldTileSize:
    raise newException(
      TiledError,
      "Forest map tile size must be " & $WorldTileSize & "x" &
        $WorldTileSize
    )

  sim.tiles = newSeq[TileKind](LevelWidthTiles * LevelHeightTiles)
  sim.tileGids = newSeq[int](sim.tiles.len)
  for ty in 0 ..< LevelHeightTiles:
    for tx in 0 ..< LevelWidthTiles:
      let
        index = tileIndex(tx, ty)
        gid = layer.gidAt(tx, ty)
      sim.tiles[index] = gid.tileKindForGid()
      sim.tileGids[index] = gid

proc loadTileSprites(sim: var SimServer, sheet: Image) =
  ## Loads each Tiled gid sprite used by the map.
  sim.tileSprites = initTable[int, RgbaSprite]()
  for gid in sim.tileGids:
    if gid == 0 or gid in sim.tileSprites:
      continue
    sim.tileSprites[gid] = sheet.sheetGidSprite(gid)

proc colorSlot(color: uint8): int =
  ## Returns the compact sprite slot for one player color.
  for i in 0 ..< PlayerColors.len:
    if PlayerColors[i] == color:
      return i
  0

proc playerSpriteId(
  color: uint8,
  facingRight: bool,
  frame: PlayerFrame
): int =
  ## Returns the sprite id for one colored player animation frame.
  let directionOffset =
    if facingRight:
      PlayerFrameCount
    else:
      0
  PlayerSpriteBase +
    color.colorSlot() * PlayerSpritesPerColor +
    directionOffset +
    ord(frame)

proc radarSpriteId(color: uint8): int =
  ## Returns the radar dot sprite id for one player color.
  RadarSpriteBase + color.colorSlot()

proc tileSpriteId(gid: int): int =
  ## Returns the sprite id for one Tiled gid.
  TiledSpriteBase + gid

proc playerCollisionBounds(sim: SimServer, player: Actor): Rect =
  ## Returns the fixed player collision box.
  Rect(x: 0, y: 0, w: PlayerBoxWidth, h: PlayerBoxHeight)

proc playerCollisionRectAt(
  sim: SimServer,
  player: Actor,
  x, y: int
): Rect =
  ## Returns the world collision rectangle for one player position.
  let bounds = sim.playerCollisionBounds(player)
  Rect(
    x: x + bounds.x,
    y: y + bounds.y,
    w: bounds.w,
    h: bounds.h
  )

proc playerCollisionRect(sim: SimServer, player: Actor): Rect =
  ## Returns the current world collision rectangle for one player.
  sim.playerCollisionRectAt(player, player.x, player.y)

proc playerCenterX(sim: SimServer, player: Actor): int =
  ## Returns the center x coordinate of the visible player body.
  let rect = sim.playerCollisionRect(player)
  rect.x + rect.w div 2

proc playerCenterY(sim: SimServer, player: Actor): int =
  ## Returns the center y coordinate of the visible player body.
  let rect = sim.playerCollisionRect(player)
  rect.y + rect.h div 2

proc playersOverlapAt(
  sim: SimServer,
  a: Actor,
  ax, ay: int,
  b: Actor,
  bx, by: int
): bool =
  ## Returns true when two player collision boxes overlap.
  let
    ar = sim.playerCollisionRectAt(a, ax, ay)
    br = sim.playerCollisionRectAt(b, bx, by)
  rectsOverlap(ar.x, ar.y, ar.w, ar.h, br.x, br.y, br.w, br.h)

proc randomSpawn(sim: var SimServer): tuple[x, y: int] =
  ## Returns a random spawn in the first tiles, above the ground.
  let
    widthPixels = SpawnWidthTiles * WorldTileSize
    maxBodyX = max(0, widthPixels - PlayerBoxWidth)
    bodyX = sim.rng.rand(maxBodyX)
    bodyY = SpawnAirTiles * WorldTileSize
  (bodyX, bodyY)

proc resolveOverlaps(sim: var SimServer) =
  for _ in 0 ..< OverlapResolvePasses:
    var moved = false
    for i in 0 ..< sim.players.len:
      if sim.players[i].dead:
        continue
      for j in i + 1 ..< sim.players.len:
        if sim.players[j].dead:
          continue
        if sim.playersOverlapAt(
          sim.players[i],
          sim.players[i].x,
          sim.players[i].y,
          sim.players[j],
          sim.players[j].x,
          sim.players[j].y
        ):
          let
            ri = sim.playerCollisionRect(sim.players[i])
            rj = sim.playerCollisionRect(sim.players[j])
          if ri.y <= rj.y:
            sim.players[i].y += rj.y - ri.y - ri.h
            sim.players[i].carryY = 0
            sim.players[i].velY = 0
          else:
            sim.players[j].y += ri.y - rj.y - rj.h
            sim.players[j].carryY = 0
            sim.players[j].velY = 0
          moved = true
    if not moved:
      break

proc addPlayer(sim: var SimServer): int =
  let spawn = sim.randomSpawn()
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
  let spawn = sim.randomSpawn()
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
  let sheet = readAsepriteImage(sheetPath())
  result.playerFrames[PlayerStand] = sheet.sheetRgbaSprite(0, 0)
  result.playerFrames[PlayerWalkA] = sheet.sheetRgbaSprite(1, 0)
  result.playerFrames[PlayerWalkB] = sheet.sheetRgbaSprite(2, 0)
  result.playerFrames[PlayerJump] = sheet.sheetRgbaSprite(3, 0)
  result.digitSprites = loadClientDigitSprites()
  result.letterSprites = loadClientLetterSprites()
  result.players = @[]
  result.buildLevel()
  result.loadTileSprites(sheet)

proc addSpriteProtocolInit(
  packet: var seq[uint8],
  sim: SimServer,
  viewportWidth = ViewportWidth,
  viewportHeight = ViewportHeight
) =
  ## Appends the static sprite protocol setup for one sprite viewer.
  packet.addLayer(MapLayerId, MapLayerKind, MapLayerFlags)
  packet.addViewport(MapLayerId, viewportWidth, viewportHeight)
  packet.addRgbaSprite(
    SkySpriteId,
    solidRgbaSprite(viewportWidth, viewportHeight, SkyColor),
    "sky"
  )
  when DebugPlayerBounds:
    packet.addRgbaSprite(
      DebugPlayerBoxSpriteId,
      outlineRgbaSprite(
        PlayerBoxWidth,
        PlayerBoxHeight,
        rgba(255, 255, 255, 255)
      ),
      "debug player box"
    )
  var emittedTileSprites = initTable[int, bool]()
  for gid in sim.tileGids:
    if gid == 0 or gid in emittedTileSprites:
      continue
    packet.addRgbaSprite(
      gid.tileSpriteId(),
      sim.tileSprites[gid],
      "tile " & $gid
    )
    emittedTileSprites[gid] = true

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
    for frame in PlayerFrame:
      packet.addRgbaSprite(
        playerSpriteId(color, false, frame),
        sim.playerFrames[frame].tintPlayerSprite(color, true),
        "player " & $i & " left " & $frame
      )
      packet.addRgbaSprite(
        playerSpriteId(color, true, frame),
        sim.playerFrames[frame].tintPlayerSprite(color, false),
        "player " & $i & " right " & $frame
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

proc addSpeechBubble(
  packet: var seq[uint8],
  sim: SimServer,
  player: Actor,
  playerIndex,
  screenX,
  screenY,
  z: int
) =
  ## Appends a speech bubble object above one player.
  if player.message.len == 0:
    return
  let
    bubble = sim.speechBubbleSprite(player.message)
    x = screenX + PlayerBoxWidth div 2 - bubble.width div 2
    y = screenY - bubble.height - ChatGapY
    spriteId = ChatSpriteBase + playerIndex
  packet.addRgbaSprite(spriteId, bubble, "chat " & player.message)
  packet.addObject(
    ChatObjectBase + playerIndex,
    x,
    y,
    z,
    MapLayerId,
    spriteId
  )

proc cameraXFor(sim: SimServer, player: Actor): int =
  ## Returns the player camera x coordinate.
  worldClampPixel(
    sim.playerCenterX(player) - ViewportWidth div 2,
    LevelWidthPixels - ViewportWidth
  )

proc cameraYFor(sim: SimServer, player: Actor): int =
  ## Returns the player camera y coordinate.
  worldClampPixel(
    sim.playerCenterY(player) - ViewportHeight div 2,
    LevelHeightPixels - ViewportHeight
  )

proc animationFrame(sim: SimServer, player: Actor): PlayerFrame =
  ## Returns the current animation frame for one player.
  if not player.onGround:
    return PlayerJump
  if abs(player.velX) >= StopThreshold:
    if (sim.tickCount div 6) mod 2 == 0:
      return PlayerWalkA
    return PlayerWalkB
  PlayerStand

proc hasTileSupport(sim: SimServer, player: Actor): bool =
  ## Returns true when solid tiles touch the player collision box.
  let
    rect = sim.playerCollisionRect(player)
    startTx = rect.x div WorldTileSize
    endTx = (rect.x + rect.w - 1) div WorldTileSize
    ty = (rect.y + rect.h) div WorldTileSize
  for tx in startTx .. endTx:
    if sim.getTile(tx, ty).isSolid:
      return true
  false

proc hasPlayerSupport(sim: SimServer, playerIndex: int): bool =
  ## Returns true when another player's box supports this player's box.
  let
    player = sim.players[playerIndex]
    rect = sim.playerCollisionRect(player)
    footY = rect.y + rect.h
  for i in 0 ..< sim.players.len:
    if i == playerIndex or sim.players[i].dead:
      continue
    let otherRect = sim.playerCollisionRect(sim.players[i])
    if footY >= otherRect.y and footY < otherRect.y + otherRect.h and
        rect.x < otherRect.x + otherRect.w and
        rect.x + rect.w > otherRect.x:
      return true
  false

proc hasGroundSupport(sim: SimServer, playerIndex: int): bool =
  ## Returns true when a player can still stand on current support.
  if sim.players[playerIndex].dead:
    return false
  sim.hasTileSupport(sim.players[playerIndex]) or
    sim.hasPlayerSupport(playerIndex)

proc validateGroundSupport(sim: var SimServer) =
  ## Clears grounded state when moving support no longer lines up.
  for i in 0 ..< sim.players.len:
    if sim.players[i].onGround and not sim.hasGroundSupport(i):
      sim.players[i].onGround = false

proc playerBlockedByTilesAt(
  sim: SimServer,
  player: Actor,
  x, y: int
): bool =
  ## Returns true when one player position overlaps world tiles.
  let rect = sim.playerCollisionRectAt(player, x, y)
  rect.x < 0 or
    rect.x + rect.w > LevelWidthPixels or
    sim.collidesWithTiles(rect.x, rect.y, rect.w, rect.h)

proc applyTurnCandidate(
  sim: var SimServer,
  playerIndex: int,
  turned: Actor,
  x, y: int,
  facingRight: bool
): bool =
  ## Applies a turn at one candidate position when it is tile-safe.
  if sim.playerBlockedByTilesAt(turned, x, y):
    return false
  sim.players[playerIndex].x = x
  sim.players[playerIndex].facingRight = facingRight
  true

proc tryTurnPlayer(
  sim: var SimServer,
  playerIndex: int,
  facingRight: bool
) =
  ## Turns a player and nudges horizontally out of tiles if needed.
  if sim.players[playerIndex].facingRight == facingRight:
    return

  let
    currentX = sim.players[playerIndex].x
    currentY = sim.players[playerIndex].y
    oldBounds = sim.playerCollisionBounds(sim.players[playerIndex])
  var turned = sim.players[playerIndex]
  turned.facingRight = facingRight

  if not sim.playerBlockedByTilesAt(turned, currentX, currentY):
    sim.players[playerIndex].facingRight = facingRight
    return

  let
    newBounds = sim.playerCollisionBounds(turned)
    preferredX = currentX + oldBounds.x - newBounds.x
    preferPositive = preferredX >= currentX

  if sim.applyTurnCandidate(
    playerIndex,
    turned,
    preferredX,
    currentY,
    facingRight
  ):
    return

  for distance in 1 .. PlayerSpriteSize:
    let firstX =
      if preferPositive:
        currentX + distance
      else:
        currentX - distance
    if sim.applyTurnCandidate(
      playerIndex,
      turned,
      firstX,
      currentY,
      facingRight
    ):
      return

    let secondX =
      if preferPositive:
        currentX - distance
      else:
        currentX + distance
    if sim.applyTurnCandidate(
      playerIndex,
      turned,
      secondX,
      currentY,
      facingRight
    ):
      return

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
    cameraY = sim.cameraYFor(player)
    startTx = max(0, cameraX div WorldTileSize)
    startTy = max(0, cameraY div WorldTileSize)
    endTx = min(
      LevelWidthTiles - 1,
      (cameraX + ViewportWidth - 1) div WorldTileSize
    )
    endTy = min(
      LevelHeightTiles - 1,
      (cameraY + ViewportHeight - 1) div WorldTileSize
    )

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        index = tileIndex(tx, ty)
        gid = sim.tileGids[index]
        spriteId =
          if gid == 0:
            0
          else:
            gid.tileSpriteId()
      if spriteId == 0:
        continue
      result.addObject(
        TileObjectBase + index,
        tx * WorldTileSize - cameraX,
        ty * WorldTileSize - cameraY,
        0,
        MapLayerId,
        spriteId
      )

  for i in 0 ..< sim.players.len:
    let other = sim.players[i]
    if other.dead:
      continue
    let
      boxX = other.x - cameraX
      boxY = other.y - cameraY
      spriteX = boxX - PlayerSpriteOffsetX
      spriteY = boxY - PlayerSpriteOffsetY
    result.addObject(
      PlayerObjectBase + i,
      spriteX,
      spriteY,
      boxY + 100,
      MapLayerId,
      other.color.playerSpriteId(
        other.facingRight,
        sim.animationFrame(other)
      )
    )
    when DebugPlayerBounds:
      result.addObject(
        DebugPlayerBoxObjectBase + i,
        boxX,
        boxY,
        boxY + 101,
        MapLayerId,
        DebugPlayerBoxSpriteId
      )
    result.addSpeechBubble(
      sim,
      other,
      i,
      boxX,
      boxY,
      boxY + 200
    )

  let pcx = sim.playerCenterX(player)
  for i in 0 ..< sim.players.len:
    if i == playerIndex or sim.players[i].dead:
      continue
    let
      other = sim.players[i]
      ocx = sim.playerCenterX(other)
      sx = ocx - cameraX
    if sx >= 0 and sx < ViewportWidth:
      continue
    let
      edgeX =
        if ocx < pcx:
          0
        else:
          ViewportWidth - 1
      osy = clamp(
        sim.playerCenterY(other) - cameraY,
        0,
        ViewportHeight - 1
      )
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

proc buildSpriteProtocolGlobalUpdates(
  sim: SimServer,
  state: PlayerViewerState,
  nextState: var PlayerViewerState
): seq[uint8] =
  ## Builds one sprite protocol update packet for a global viewer.
  nextState = state
  if not nextState.initialized:
    result.addSpriteProtocolInit(
      sim,
      LevelWidthPixels,
      LevelHeightPixels
    )
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

  for ty in 0 ..< LevelHeightTiles:
    for tx in 0 ..< LevelWidthTiles:
      let
        index = tileIndex(tx, ty)
        gid = sim.tileGids[index]
        spriteId =
          if gid == 0:
            0
          else:
            gid.tileSpriteId()
      if spriteId == 0:
        continue
      result.addObject(
        TileObjectBase + index,
        tx * WorldTileSize,
        ty * WorldTileSize,
        0,
        MapLayerId,
        spriteId
      )

  for i in 0 ..< sim.players.len:
    let player = sim.players[i]
    if player.dead:
      continue
    result.addObject(
      PlayerObjectBase + i,
      player.x - PlayerSpriteOffsetX,
      player.y - PlayerSpriteOffsetY,
      player.y + 100,
      MapLayerId,
      player.color.playerSpriteId(
        player.facingRight,
        sim.animationFrame(player)
      )
    )
    when DebugPlayerBounds:
      result.addObject(
        DebugPlayerBoxObjectBase + i,
        player.x,
        player.y,
        player.y + 101,
        MapLayerId,
        DebugPlayerBoxSpriteId
      )
    result.addSpeechBubble(
      sim,
      player,
      i,
      player.x,
      player.y,
      player.y + 200
    )

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
    sim.tryTurnPlayer(playerIndex, inputX > 0)
  else:
    p.velX = (p.velX * FrictionNum) div FrictionDen
    if abs(p.velX) < StopThreshold:
      p.velX = 0

  if not p.onGround and sim.hasGroundSupport(playerIndex):
    p.onGround = true

  if input.attack and p.onGround:
    p.velY = JumpVel
    p.onGround = false

proc collidesWithPlayerAt(
  sim: SimServer,
  pi: int,
  player: Actor,
  x, y: int
): int =
  ## Returns the first player with overlapping collision boxes.
  let rect = sim.playerCollisionRectAt(player, x, y)
  for j in 0 ..< sim.players.len:
    if j == pi or sim.players[j].dead:
      continue
    let otherRect = sim.playerCollisionRect(sim.players[j])
    if rectsOverlap(
      rect.x,
      rect.y,
      rect.w,
      rect.h,
      otherRect.x,
      otherRect.y,
      otherRect.w,
      otherRect.h
    ):
      return j
  -1

proc tryPushX(
  sim: var SimServer,
  playerIndex: int,
  step: int,
  depth = 0
): bool =
  ## Tries to push one horizontal chain of player boxes by one pixel.
  if depth > sim.players.len or sim.players[playerIndex].dead:
    return false
  let nx = sim.players[playerIndex].x + step
  if sim.playerBlockedByTilesAt(
    sim.players[playerIndex],
    nx,
    sim.players[playerIndex].y
  ):
    return false

  var checked = 0
  while checked <= sim.players.len:
    let hitPlayer = sim.collidesWithPlayerAt(
      playerIndex,
      sim.players[playerIndex],
      nx,
      sim.players[playerIndex].y
    )
    if hitPlayer < 0:
      sim.players[playerIndex].x = nx
      return true
    if not sim.tryPushX(hitPlayer, step, depth + 1):
      return false
    inc checked
  false

proc tryPushY(
  sim: var SimServer,
  playerIndex: int,
  step: int,
  depth = 0
): bool =
  ## Tries to push one vertical chain of player boxes by one pixel.
  if depth > sim.players.len or sim.players[playerIndex].dead:
    return false
  let ny = sim.players[playerIndex].y + step
  if sim.playerBlockedByTilesAt(
    sim.players[playerIndex],
    sim.players[playerIndex].x,
    ny
  ):
    return false

  var checked = 0
  while checked <= sim.players.len:
    let hitPlayer = sim.collidesWithPlayerAt(
      playerIndex,
      sim.players[playerIndex],
      sim.players[playerIndex].x,
      ny
    )
    if hitPlayer < 0:
      sim.players[playerIndex].y = ny
      return true
    if not sim.tryPushY(hitPlayer, step, depth + 1):
      return false
    inc checked
  false

proc movePlayerY(
  sim: var SimServer,
  p: var Actor,
  pi: int,
  step: int
): bool =
  ## Moves a player vertically by one pixel when the box path is clear.
  let ny = p.y + step
  if sim.playerBlockedByTilesAt(p, p.x, ny):
    return false
  let hitPlayer = sim.collidesWithPlayerAt(pi, p, p.x, ny)
  if hitPlayer >= 0:
    if step > 0:
      return false
    if not sim.tryPushY(hitPlayer, step):
      return false
  p.y = ny
  true

proc moveX(sim: var SimServer, p: var Actor, pi: int) =
  p.carryX += p.velX
  while abs(p.carryX) >= MotionScale:
    let step = (if p.carryX < 0: -1 else: 1)
    let nx = p.x + step
    let rect = sim.playerCollisionRectAt(p, nx, p.y)
    if rect.x < 0 or
      rect.x + rect.w > LevelWidthPixels or
      sim.collidesWithTiles(rect.x, rect.y, rect.w, rect.h):
        p.carryX = 0
        p.velX = 0
        break
    let hitPlayer = sim.collidesWithPlayerAt(
      pi,
      p,
      nx,
      p.y
    )
    if hitPlayer >= 0:
      if sim.tryPushX(hitPlayer, step):
        p.x = nx
        p.carryX -= step * MotionScale
      else:
        p.carryX = 0
      break
    p.x = nx
    p.carryX -= step * MotionScale

proc moveY(sim: var SimServer, p: var Actor, pi: int) =
  p.carryY += p.velY
  while abs(p.carryY) >= MotionScale:
    let step = (if p.carryY < 0: -1 else: 1)
    if not sim.movePlayerY(p, pi, step):
      p.carryY = 0
      if p.velY > 0:
        p.onGround = true
      p.velY = 0
      break
    p.carryY -= step * MotionScale

proc applyPhysics(sim: var SimServer, p: var Actor, pi: int) =
  p.velY = min(p.velY + Gravity, MaxFallSpeed)
  sim.moveX(p, pi)
  sim.moveY(p, pi)

  if p.onGround:
    if not sim.hasGroundSupport(pi):
      p.onGround = false

proc checkDeath(sim: var SimServer) =
  for i in 0 ..< sim.players.len:
    if sim.players[i].dead:
      continue
    let rect = sim.playerCollisionRect(sim.players[i])
    if rect.y > DeathY:
      sim.players[i].dead = true
      sim.players[i].respawnTimer = 48

proc checkGoal(sim: var SimServer) =
  for i in 0 ..< sim.players.len:
    if sim.players[i].dead:
      continue
    let rect = sim.playerCollisionRect(sim.players[i])
    var scored = false
    for ty in 0 ..< LevelHeightTiles:
      for tx in 0 ..< LevelWidthTiles:
        if sim.tiles[tileIndex(tx, ty)] != TileGoal:
          continue
        if rectsOverlap(
          rect.x,
          rect.y,
          rect.w,
          rect.h,
          tx * WorldTileSize,
          ty * WorldTileSize,
          WorldTileSize,
          WorldTileSize
        ):
          inc sim.players[i].score
          sim.respawnPlayer(i)
          scored = true
          break
      if scored:
        break

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
  sim.resolveOverlaps()
  sim.validateGroundSupport()
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
  appState.globalViewers = initTable[WebSocket, PlayerViewerState]()
  appState.chatMessages = initTable[WebSocket, string]()
  appState.closedSockets = @[]
  appState.tokens = @[]

proc inputStateFromMasks(currentMask, previousMask: uint8): InputState =
  result = decodeInputMask(currentMask)
  result.attack =
    (currentMask and ButtonA) != 0 and
    (previousMask and ButtonA) == 0

proc readSpriteInputText(message: string): string =
  ## Reads printable text from sprite player input messages.
  var offset = 0
  while offset < message.len:
    let messageType = message[offset].uint8
    inc offset
    case messageType
    of 0x81:
      if offset + 2 > message.len:
        return
      let length = int(uint16(message[offset].uint8) or
        (uint16(message[offset + 1].uint8) shl 8))
      offset += 2
      if offset + length > message.len:
        return
      for i in 0 ..< length:
        let value = message[offset + i].uint8
        if value >= 32'u8 and value < 127'u8:
          result.add(message[offset + i])
      offset += length
    of 0x82:
      if offset + 4 > message.len:
        return
      offset += 4
      if offset < message.len and message[offset].uint8 notin
          {0x81'u8, 0x82'u8, 0x83'u8, 0x84'u8}:
        inc offset
    of 0x83:
      if offset + 2 > message.len:
        return
      offset += 2
    of 0x84:
      if offset + 1 > message.len:
        return
      inc offset
    else:
      return

proc playerChatFromMessage(message: Message): string =
  ## Reads player chat from text or binary websocket messages.
  case message.kind
  of TextMessage:
    message.data
  of BinaryMessage:
    if message.data.isChatPacket():
      return message.data.blobToChat()
    message.data.readSpriteInputText()
  of Ping, Pong:
    ""

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  if websocket in appState.playerViewers:
    appState.playerViewers.del(websocket)
  if websocket in appState.chatMessages:
    appState.chatMessages.del(websocket)
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
  appState.chatMessages.clear()

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
  ## Returns true for sprite client static routes Jumper serves.
  case route
  of PlayerClientRoute, PlayerClientHtmlRoute, CoworldPlayerClientRoute,
      GlobalClientRoute, GlobalClientHtmlRoute, CoworldGlobalClientRoute,
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
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
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
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = PlayerViewerState()
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
    if message.kind == BinaryMessage and message.data.len == 2 and
        (
          message.data[0].uint8 == PacketInput or
          message.data[0].uint8 == 0x84'u8
        ):
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.playerViewers:
            appState.inputMasks[websocket] = message.data[1].uint8 and 0x7f'u8
    let chatText = message.playerChatFromMessage().cleanChatMessage()
    if chatText.len > 0:
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.playerViewers:
            appState.chatMessages[websocket] = chatText
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
  createThread(
    serverThread,
    serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port)
  )
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
      globalSockets: seq[WebSocket] = @[]
      globalStates: seq[PlayerViewerState] = @[]
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
          let previousMask = appState.lastAppliedMasks.getOrDefault(
            websocket,
            0
          )
          inputs[playerIndex] = inputStateFromMasks(currentMask, previousMask)
          appState.lastAppliedMasks[websocket] = currentMask
          let chatText = appState.chatMessages.getOrDefault(websocket, "")
          if chatText.len > 0:
            sim.players[playerIndex].message = chatText
            appState.chatMessages.del(websocket)

        for websocket, state in appState.globalViewers.pairs:
          globalSockets.add(websocket)
          globalStates.add(state)

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

    for i in 0 ..< globalSockets.len:
      var nextState: PlayerViewerState
      let packet = sim.buildSpriteProtocolGlobalUpdates(
        globalStates[i],
        nextState
      )
      try:
        globalSockets[i].send(blobFromBytes(packet), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalSockets[i] in appState.globalViewers:
              appState.globalViewers[globalSockets[i]] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(globalSockets[i])

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
    raise newException(
      ValueError,
      "Config field " & name & " must be a string."
    )
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

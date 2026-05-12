import
  std/[json, locks, monotimes, os, parseopt, random, strutils, tables, times],
  mummy, pixie, supersnappy,
  bitworld/aseprite, bitworld/clients, protocol, server

const
  BoardWidthCells = 250
  BoardHeightCells = 250
  CellPixels = 9
  WorldWidthPixels = BoardWidthCells * CellPixels
  WorldHeightPixels = BoardHeightCells * CellPixels
  BaseTerrainY = BoardHeightCells * 31 div 50
  PieceSpawnLiftCells = 8
  PieceSpawnNudgeCells = 1
  HorizontalScrollMargin = 32
  VerticalScrollMargin = 64
  BaseFallInterval = 40
  SoftFallInterval = 10
  MoveRepeatInterval = 5
  LockDelayTicks = 20
  LineClearLength = 8
  TerrainColor = 1'u8
  BackgroundColor = 0'u8
  ClearFlashTicks = 20
  ClearPauseTicks = 12
  TargetFps = 60
  GlobalSendInterval = 6
  PlayerWebSocketPath = "/player"
  HealthPath = "/healthz"
  GlobalWebSocketPath = "/global"
  AdminWebSocketPath = "/admin"
  ReplayWebSocketPath = "/replay"
  RewardWebSocketPath = "/reward"
  GlobalLayerId = 0
  GlobalFrameObjectBase = 10
  GlobalTerrainSpriteBase = 20
  GlobalClearSpriteBase = 40
  GlobalPlayerSpriteBase = 1000
  GlobalBlockObjectBase = 10
  MaxGlobalObjectId = 65535
  GlobalMapWidth = WorldWidthPixels
  GlobalMapHeight = WorldHeightPixels
  GlobalMapLayerType = 0
  GlobalZoomableFlag = 1
  BlockSpritePixels = 9
  BlockSpriteVariants = 16
  BlockPartCount = 8
  BlockPartRow = 1
  ConnectLeft = 1'u8
  ConnectRight = 2'u8
  ConnectUp = 4'u8
  ConnectDown = 8'u8
  BlockLeftEnd = 0
  BlockRightEnd = 1
  BlockTopEnd = 2
  BlockBottomEnd = 3
  BlockLeftConnection = 4
  BlockRightConnection = 5
  BlockTopConnection = 6
  BlockBottomConnection = 7
  CameraMaxY = (BaseTerrainY + 1) * CellPixels - ScreenHeight
  PreviewX = ScreenWidth - CellPixels * 4 - 2
  PlayerColors = [4'u8, 5'u8, 6'u8, 7'u8, 8'u8, 9'u8, 10'u8, 11'u8, 12'u8, 13'u8, 14'u8, 15'u8]

type
  RunConfig = object
    address: string
    port: int
    seed: int
    saveScoresPath: string
    maxTicks: int

  PieceKind = enum
    PieceI
    PieceO
    PieceT
    PieceL
    PieceJ
    PieceS
    PieceZ

  BlockOffset = tuple[x: int, y: int]

  ClearSegment = object
    y: int
    startX: int
    endX: int

  PendingClear = object
    segment: ClearSegment
    triggerPlayerId: int
    lineLength: int
    colorCount: int
    scoreValue: int

  RgbaColor = tuple[r, g, b, a: uint8]

  RgbaSprite = object
    width: int
    height: int
    pixels: seq[uint8]

  Player = object
    id: int
    name: string
    color: uint8
    rgbaColor: RgbaColor
    score: int
    alive: bool
    hasPiece: bool
    pieceKind: PieceKind
    nextKind: PieceKind
    rotation: int
    cellX: int
    cellY: int
    moveTicksX: int
    moveTicksY: int
    fallTicks: int
    lockTicks: int
    deepestCellY: int
    cameraX: int
    cameraY: int
    pendingSpawnCenterX: int
    pendingSpawnTopY: int
    pendingSpawn: bool

  SimServer = object
    players: seq[Player]
    settledColors: seq[uint8]
    settledOwners: seq[int]
    settledConnections: seq[uint8]
    settledCellIndices: seq[int]
    settledCellsDirty: bool
    terrain: seq[bool]
    blockParts: array[BlockPartCount, RgbaSprite]
    digitSprites: array[10, Sprite]
    letterSprites: seq[Sprite]
    fb: Framebuffer
    rng: Rand
    nextPlayerId: int
    flashColor: uint8
    clearQueue: seq[PendingClear]
    activeClear: PendingClear
    activeClearValid: bool
    clearFlashTimer: int
    clearPauseTimer: int
    clearCascadePlayerId: int
    clearDisplayPlayerId: int

  GlobalViewerState = object
    initialized: bool
    sentOwners: seq[int]
    sentTerrainSprites: bool
    sentClearSprites: bool

  SocketKind = enum
    SocketUnknown
    SocketPlayer
    SocketGlobal
    SocketReward

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerNames: Table[WebSocket, string]
    closedSockets: seq[WebSocket]
    spritePlayerViewers: Table[WebSocket, GlobalViewerState]
    globalViewers: Table[WebSocket, GlobalViewerState]
    rewardViewers: Table[WebSocket, bool]
    socketKinds: Table[WebSocket, SocketKind]
    resetRequested: bool

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

proc repoDir(): string =
  getCurrentDir() / ".."

proc gameDataDir(): string =
  ## Returns the Infinite Blocks data directory.
  let
    cwd = getCurrentDir()
    sourceDir = currentSourcePath().parentDir()
    candidates = [
      cwd / "data",
      cwd / "infinite_blocks" / "data",
      sourceDir / "data"
    ]
  for candidate in candidates:
    if dirExists(candidate):
      return candidate
  sourceDir / "data"

proc clientDataDir(): string =
  ## Returns the shared client data directory.
  repoDir() / "clients" / "data"

proc blockSpritesPath(): string =
  ## Returns the block sprite atlas path.
  gameDataDir() / "sprites.aseprite"

proc boardIndex(x, y: int): int =
  ## Returns the flat board index for one logical cell.
  y * BoardWidthCells + x

proc inBoardBounds(x, y: int): bool =
  ## Returns true when one logical cell is inside the board.
  x >= 0 and y >= 0 and x < BoardWidthCells and y < BoardHeightCells

proc worldClampPixel(x, maxValue: int): int =
  ## Clamps one world pixel coordinate against a non-negative limit.
  max(0, min(maxValue, x))

proc brightestPaletteColor(): uint8 =
  var
    bestIndex = 1
    bestValue = -1
  for i in 1 .. high(Palette):
    let swatch = Palette[i]
    let value = int(swatch.r) + int(swatch.g) + int(swatch.b)
    if value > bestValue:
      bestValue = value
      bestIndex = i
  bestIndex.uint8

proc putRect(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  for py in 0 ..< h:
    for px in 0 ..< w:
      fb.putPixel(x + px, y + py, color)

proc rgbaSpriteIndex(sprite: RgbaSprite, x, y: int): int =
  ## Returns the byte offset for one RGBA sprite pixel.
  (y * sprite.width + x) * 4

proc rgbaSpriteAt(sprite: RgbaSprite, x, y: int): RgbaColor =
  ## Reads one RGBA sprite pixel.
  if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height:
    return
  let offset = sprite.rgbaSpriteIndex(x, y)
  (
    r: sprite.pixels[offset],
    g: sprite.pixels[offset + 1],
    b: sprite.pixels[offset + 2],
    a: sprite.pixels[offset + 3]
  )

proc putRgbaSpritePixel(
  sprite: var RgbaSprite,
  x, y: int,
  color: RgbaColor
) =
  ## Writes one RGBA sprite pixel.
  if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height:
    return
  let offset = sprite.rgbaSpriteIndex(x, y)
  sprite.pixels[offset] = color.r
  sprite.pixels[offset + 1] = color.g
  sprite.pixels[offset + 2] = color.b
  sprite.pixels[offset + 3] = color.a

proc stainColor(source, tint: RgbaColor): RgbaColor =
  ## Applies a player tint while preserving sprite alpha.
  if source.a == 0'u8:
    return
  let strength = max(int(source.r), max(int(source.g), int(source.b)))
  (
    r: uint8(int(tint.r) * strength div 255),
    g: uint8(int(tint.g) * strength div 255),
    b: uint8(int(tint.b) * strength div 255),
    a: source.a
  )

proc blitPart(
  target: var RgbaSprite,
  part: RgbaSprite,
  tint: RgbaColor
) =
  ## Blits one stained block part into a composite sprite.
  for y in 0 ..< min(target.height, part.height):
    for x in 0 ..< min(target.width, part.width):
      let color = part.rgbaSpriteAt(x, y).stainColor(tint)
      if color.a == 0'u8:
        continue
      target.putRgbaSpritePixel(x, y, color)

proc blankRgbaSprite(): RgbaSprite =
  ## Builds one empty 9x9 RGBA sprite.
  RgbaSprite(
    width: BlockSpritePixels,
    height: BlockSpritePixels,
    pixels: newSeq[uint8](BlockSpritePixels * BlockSpritePixels * 4)
  )

proc sliceBlockPart(image: Image, index: int): RgbaSprite =
  ## Slices one 9x9 block-part sprite from the second atlas row.
  result = blankRgbaSprite()
  let
    tileX = index * BlockSpritePixels
    tileY = BlockPartRow * BlockSpritePixels
  if tileX + BlockSpritePixels > image.width or
      tileY + BlockSpritePixels > image.height:
    return
  for y in 0 ..< BlockSpritePixels:
    for x in 0 ..< BlockSpritePixels:
      let pixel = image[tileX + x, tileY + y]
      result.putRgbaSpritePixel(
        x,
        y,
        (r: pixel.r, g: pixel.g, b: pixel.b, a: pixel.a)
      )

proc loadBlockParts(path: string): array[BlockPartCount, RgbaSprite] =
  ## Loads the second-row 9x9 block part sprites.
  let image = readAsepriteImage(path)
  if image.width < BlockPartCount * BlockSpritePixels or
      image.height < (BlockPartRow + 1) * BlockSpritePixels:
    raise newException(
      IOError,
      "Block sprite atlas must contain 8 9x9 sprites on row 2: " & path
    )
  for i in 0 ..< result.len:
    result[i] = image.sliceBlockPart(i)

proc composeBlockSprite(
  parts: array[BlockPartCount, RgbaSprite],
  mask: uint8,
  tint: RgbaColor
): RgbaSprite =
  ## Builds one stained full-cell sprite for a connection mask.
  result = blankRgbaSprite()
  result.blitPart(
    parts[if (mask and ConnectLeft) != 0: BlockLeftConnection
          else: BlockLeftEnd],
    tint
  )
  result.blitPart(
    parts[if (mask and ConnectRight) != 0: BlockRightConnection
          else: BlockRightEnd],
    tint
  )
  result.blitPart(
    parts[if (mask and ConnectUp) != 0: BlockTopConnection
          else: BlockTopEnd],
    tint
  )
  result.blitPart(
    parts[if (mask and ConnectDown) != 0: BlockBottomConnection
          else: BlockBottomEnd],
    tint
  )

proc pieceCells(kind: PieceKind, rotation: int): array[4, BlockOffset] =
  case kind
  of PieceI:
    case rotation and 3
    of 0: [(x: 0, y: 1), (x: 1, y: 1), (x: 2, y: 1), (x: 3, y: 1)]
    of 1: [(x: 2, y: 0), (x: 2, y: 1), (x: 2, y: 2), (x: 2, y: 3)]
    of 2: [(x: 0, y: 2), (x: 1, y: 2), (x: 2, y: 2), (x: 3, y: 2)]
    else: [(x: 1, y: 0), (x: 1, y: 1), (x: 1, y: 2), (x: 1, y: 3)]
  of PieceO:
    [(x: 1, y: 0), (x: 2, y: 0), (x: 1, y: 1), (x: 2, y: 1)]
  of PieceT:
    case rotation and 3
    of 0: [(x: 1, y: 0), (x: 0, y: 1), (x: 1, y: 1), (x: 2, y: 1)]
    of 1: [(x: 1, y: 0), (x: 1, y: 1), (x: 2, y: 1), (x: 1, y: 2)]
    of 2: [(x: 0, y: 1), (x: 1, y: 1), (x: 2, y: 1), (x: 1, y: 2)]
    else: [(x: 1, y: 0), (x: 0, y: 1), (x: 1, y: 1), (x: 1, y: 2)]
  of PieceL:
    case rotation and 3
    of 0: [(x: 0, y: 0), (x: 0, y: 1), (x: 1, y: 1), (x: 2, y: 1)]
    of 1: [(x: 1, y: 0), (x: 2, y: 0), (x: 1, y: 1), (x: 1, y: 2)]
    of 2: [(x: 0, y: 1), (x: 1, y: 1), (x: 2, y: 1), (x: 2, y: 2)]
    else: [(x: 1, y: 0), (x: 1, y: 1), (x: 0, y: 2), (x: 1, y: 2)]
  of PieceJ:
    case rotation and 3
    of 0: [(x: 2, y: 0), (x: 0, y: 1), (x: 1, y: 1), (x: 2, y: 1)]
    of 1: [(x: 1, y: 0), (x: 1, y: 1), (x: 1, y: 2), (x: 2, y: 2)]
    of 2: [(x: 0, y: 1), (x: 1, y: 1), (x: 2, y: 1), (x: 0, y: 2)]
    else: [(x: 0, y: 0), (x: 1, y: 0), (x: 1, y: 1), (x: 1, y: 2)]
  of PieceS:
    case rotation and 3
    of 0: [(x: 1, y: 0), (x: 2, y: 0), (x: 0, y: 1), (x: 1, y: 1)]
    of 1: [(x: 1, y: 0), (x: 1, y: 1), (x: 2, y: 1), (x: 2, y: 2)]
    of 2: [(x: 1, y: 1), (x: 2, y: 1), (x: 0, y: 2), (x: 1, y: 2)]
    else: [(x: 0, y: 0), (x: 0, y: 1), (x: 1, y: 1), (x: 1, y: 2)]
  of PieceZ:
    case rotation and 3
    of 0: [(x: 0, y: 0), (x: 1, y: 0), (x: 1, y: 1), (x: 2, y: 1)]
    of 1: [(x: 2, y: 0), (x: 1, y: 1), (x: 2, y: 1), (x: 1, y: 2)]
    of 2: [(x: 0, y: 1), (x: 1, y: 1), (x: 1, y: 2), (x: 2, y: 2)]
    else: [(x: 1, y: 0), (x: 0, y: 1), (x: 1, y: 1), (x: 0, y: 2)]

proc randomPiece(sim: var SimServer): PieceKind =
  PieceKind(sim.rng.rand(high(PieceKind).ord))

proc colorForPlayer(playerId: int): uint8 =
  PlayerColors[(playerId - 1) mod PlayerColors.len]

proc colorChannel(value: float): uint8 =
  ## Converts one normalized color channel to an 8 bit value.
  let scaled = int(value * 255.0 + 0.5)
  max(0, min(255, scaled)).uint8

proc brightHsvColor(hueDegrees: int): RgbaColor =
  ## Returns a bright true-color RGBA value from an HSV hue.
  let
    hue = ((hueDegrees mod 360) + 360) mod 360
    sector = hue div 60
    fraction = float(hue mod 60) / 60.0
    saturation = 0.82
    value = 1.0
    p = value * (1.0 - saturation)
    q = value * (1.0 - saturation * fraction)
    t = value * (1.0 - saturation * (1.0 - fraction))
  var r, g, b: float
  case sector
  of 0:
    r = value
    g = t
    b = p
  of 1:
    r = q
    g = value
    b = p
  of 2:
    r = p
    g = value
    b = t
  of 3:
    r = p
    g = q
    b = value
  of 4:
    r = t
    g = p
    b = value
  else:
    r = value
    g = p
    b = q
  (
    r: colorChannel(r),
    g: colorChannel(g),
    b: colorChannel(b),
    a: 255'u8
  )

proc rgbaColorForPlayer(playerId: int): RgbaColor =
  ## Returns the bright HSV block color for one player id.
  brightHsvColor((playerId - 1) * 137)

proc pieceCenterPixel(player: Player): tuple[x: int, y: int] =
  if not player.hasPiece:
    return (player.cameraX + ScreenWidth div 2, player.cameraY + VerticalScrollMargin)
  var
    minX = high(int)
    maxX = low(int)
    minY = high(int)
    maxY = low(int)
  for cell in pieceCells(player.pieceKind, player.rotation):
    let
      x = (player.cellX + cell.x) * CellPixels
      y = (player.cellY + cell.y) * CellPixels
    minX = min(minX, x)
    maxX = max(maxX, x + CellPixels - 1)
    minY = min(minY, y)
    maxY = max(maxY, y + CellPixels - 1)
  ((minX + maxX) div 2, (minY + maxY) div 2)

proc pieceBounds(player: Player): tuple[minX, maxX, minY, maxY: int] =
  result.minX = high(int)
  result.maxX = low(int)
  result.minY = high(int)
  result.maxY = low(int)
  for cell in pieceCells(player.pieceKind, player.rotation):
    let
      x = player.cellX + cell.x
      y = player.cellY + cell.y
    result.minX = min(result.minX, x)
    result.maxX = max(result.maxX, x)
    result.minY = min(result.minY, y)
    result.maxY = max(result.maxY, y)

proc pieceBottomY(player: Player): int =
  ## Returns the lowest occupied row for one active piece.
  if not player.hasPiece:
    return low(int)
  player.pieceBounds().maxY

proc piecePixelBounds(player: Player): tuple[minX, maxX, minY, maxY: int] =
  let bounds = pieceBounds(player)
  (
    bounds.minX * CellPixels,
    bounds.maxX * CellPixels + CellPixels - 1,
    bounds.minY * CellPixels,
    bounds.maxY * CellPixels + CellPixels - 1
  )

proc clampCamera(player: var Player) =
  player.cameraX = worldClampPixel(player.cameraX, WorldWidthPixels - ScreenWidth)
  player.cameraY = worldClampPixel(player.cameraY, CameraMaxY)

proc positionCameraForSpawn(player: var Player, recenterHoriz: bool) =
  if not player.hasPiece:
    return
  let pixelBounds = piecePixelBounds(player)
  if recenterHoriz:
    let center = pieceCenterPixel(player)
    player.cameraX = center.x - ScreenWidth div 2
  player.cameraY = pixelBounds.minY - VerticalScrollMargin
  player.clampCamera()

proc updateCameraForPlayer(player: var Player) =
  if not player.hasPiece:
    return

  let pixelBounds = piecePixelBounds(player)
  if pixelBounds.minX - player.cameraX < HorizontalScrollMargin:
    player.cameraX = pixelBounds.minX - HorizontalScrollMargin
  elif pixelBounds.maxX - player.cameraX > ScreenWidth - 1 - HorizontalScrollMargin:
    player.cameraX = pixelBounds.maxX - (ScreenWidth - 1 - HorizontalScrollMargin)

  if pixelBounds.maxY - player.cameraY > ScreenHeight - 1 - VerticalScrollMargin:
    player.cameraY = pixelBounds.maxY - (ScreenHeight - 1 - VerticalScrollMargin)

  player.clampCamera()

proc hasInt(values: openArray[int], value: int): bool =
  ## Returns true when a small integer list contains a value.
  for item in values:
    if item == value:
      return true

proc addUniqueInt(values: var seq[int], value: int) =
  ## Adds an integer to a small list if it is not already present.
  if values.hasInt(value):
    return
  values.add(value)

proc canPlaceStatic(
  sim: SimServer,
  cellX, cellY: int,
  kind: PieceKind,
  rotation: int
): bool =
  ## Returns true when a piece avoids terrain and settled blocks.
  for cell in pieceCells(kind, rotation):
    let
      x = cellX + cell.x
      y = cellY + cell.y
    if not inBoardBounds(x, y):
      return false
    let index = boardIndex(x, y)
    if sim.terrain[index] or sim.settledColors[index] != 0:
      return false
  true

proc playerHasCell(player: Player, x, y: int): bool =
  ## Returns true when one active piece occupies a board cell.
  if not player.alive or not player.hasPiece:
    return false
  for cell in pieceCells(player.pieceKind, player.rotation):
    if player.cellX + cell.x == x and player.cellY + cell.y == y:
      return true

proc activeBlockerAt(
  sim: SimServer,
  ignoredPlayers: openArray[int],
  x, y: int
): int =
  ## Returns the active player index occupying a cell, or -1.
  for i in 0 ..< sim.players.len:
    if ignoredPlayers.hasInt(i):
      continue
    if sim.players[i].playerHasCell(x, y):
      return i
  -1

proc canPlaceIgnoring(
  sim: SimServer,
  cellX, cellY: int,
  kind: PieceKind,
  rotation: int,
  ignoredPlayers: openArray[int]
): bool =
  ## Returns true when a piece avoids static blocks and active players.
  if not sim.canPlaceStatic(cellX, cellY, kind, rotation):
    return false
  for cell in pieceCells(kind, rotation):
    let
      x = cellX + cell.x
      y = cellY + cell.y
    if sim.activeBlockerAt(ignoredPlayers, x, y) >= 0:
      return false
  true

proc canPlace(
  sim: SimServer,
  cellX, cellY: int,
  kind: PieceKind,
  rotation: int
): bool =
  ## Returns true when a piece can occupy a board position.
  let ignoredPlayers: array[0, int] = []
  sim.canPlaceIgnoring(cellX, cellY, kind, rotation, ignoredPlayers)

proc blockingPlayersFor(
  sim: SimServer,
  playerIndex, cellX, cellY, rotation: int,
  ignoredPlayers: openArray[int]
): seq[int] =
  ## Returns active player indices blocking a candidate piece position.
  let player = sim.players[playerIndex]
  for cell in pieceCells(player.pieceKind, rotation):
    let blocker = sim.activeBlockerAt(
      ignoredPlayers,
      cellX + cell.x,
      cellY + cell.y
    )
    if blocker >= 0:
      result.addUniqueInt(blocker)

proc collectPushes(
  sim: SimServer,
  playerIndex, dx, dy: int,
  movingPlayers: var seq[int]
): bool =
  ## Collects all active pieces that must move for one push to succeed.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if movingPlayers.hasInt(playerIndex):
    return true
  if not sim.players[playerIndex].alive or
      not sim.players[playerIndex].hasPiece:
    return false

  movingPlayers.add(playerIndex)
  let
    player = sim.players[playerIndex]
    nextX = player.cellX + dx
    nextY = player.cellY + dy
  if not sim.canPlaceStatic(
    nextX,
    nextY,
    player.pieceKind,
    player.rotation
  ):
    return false

  let blockers = sim.blockingPlayersFor(
    playerIndex,
    nextX,
    nextY,
    player.rotation,
    movingPlayers
  )
  for blocker in blockers:
    if not sim.collectPushes(blocker, dx, dy, movingPlayers):
      return false
  true

proc moveCollectedPlayers(
  sim: var SimServer,
  movingPlayers: openArray[int],
  dx, dy: int
) =
  ## Applies one already-validated push movement.
  if movingPlayers.len == 0:
    return
  for i in countdown(movingPlayers.high, 0):
    let playerIndex = movingPlayers[i]
    if playerIndex < 0 or playerIndex >= sim.players.len:
      continue
    sim.players[playerIndex].cellX += dx
    sim.players[playerIndex].cellY += dy

proc refreshLockDepth(sim: var SimServer, playerIndex: int) =
  ## Resets lock delay only after a piece reaches a new lower row.
  if playerIndex < 0 or
      playerIndex >= sim.players.len or
      not sim.players[playerIndex].alive or
      not sim.players[playerIndex].hasPiece:
    return
  let bottomY = sim.players[playerIndex].pieceBottomY()
  if bottomY > sim.players[playerIndex].deepestCellY:
    sim.players[playerIndex].deepestCellY = bottomY
    sim.players[playerIndex].lockTicks = 0

proc drawPiece(
  fb: var Framebuffer,
  player: Player,
  cameraX, cameraY: int,
  color: uint8
) =
  for cell in pieceCells(player.pieceKind, player.rotation):
    let
      worldX = (player.cellX + cell.x) * CellPixels
      worldY = (player.cellY + cell.y) * CellPixels
      screenX = worldX - cameraX
      screenY = worldY - cameraY
    fb.putRect(screenX, screenY, CellPixels, CellPixels, color)

proc drawPreview(
  fb: var Framebuffer,
  kind: PieceKind,
  color: uint8,
  screenX, screenY: int
) =
  let previewPlayer = Player(pieceKind: kind, rotation: 0, cellX: 0, cellY: 0)
  for cell in pieceCells(previewPlayer.pieceKind, previewPlayer.rotation):
    fb.putRect(screenX + cell.x * CellPixels, screenY + cell.y * CellPixels, CellPixels, CellPixels, color)

proc blitSolidSprite(
  fb: var Framebuffer,
  sprite: Sprite,
  screenX, screenY: int,
  color: uint8
) =
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      if sprite.pixels[sprite.spriteIndex(x, y)] != TransparentColorIndex:
        fb.putPixel(screenX + x, screenY + y, color)

proc renderNumber(
  fb: var Framebuffer,
  digitSprites: array[10, Sprite],
  value, screenX, screenY: int,
  showZero = true
): int =
  if value == 0 and not showZero:
    return 0
  let text = $max(0, value)
  var x = screenX
  for ch in text:
    let digit = ord(ch) - ord('0')
    fb.blitSprite(digitSprites[digit], x, screenY, 0, 0)
    x += digitSprites[digit].width
  x - screenX

proc renderSolidNumber(
  fb: var Framebuffer,
  digitSprites: array[10, Sprite],
  value, screenX, screenY: int,
  color: uint8
): int =
  let text = $max(0, value)
  var x = screenX
  for ch in text:
    let digit = ord(ch) - ord('0')
    fb.blitSolidSprite(digitSprites[digit], x, screenY, color)
    x += digitSprites[digit].width
  x - screenX

proc renderSolidText(
  fb: var Framebuffer,
  letterSprites: seq[Sprite],
  text: string,
  screenX, screenY: int,
  color: uint8
): int =
  var x = screenX
  for ch in text:
    if ch == ' ':
      x += 6
      continue
    let idx = letterIndex(ch)
    if idx >= 0 and idx < letterSprites.len:
      fb.blitSolidSprite(letterSprites[idx], x, screenY, color)
    x += 6
  x - screenX

proc initSimServer(seed: int): SimServer =
  result.rng = initRand(seed)
  result.settledColors = newSeq[uint8](BoardWidthCells * BoardHeightCells)
  result.settledOwners = newSeq[int](BoardWidthCells * BoardHeightCells)
  result.settledConnections = newSeq[uint8](BoardWidthCells * BoardHeightCells)
  result.settledCellIndices = @[]
  result.settledCellsDirty = false
  result.terrain = newSeq[bool](BoardWidthCells * BoardHeightCells)
  result.blockParts = loadBlockParts(blockSpritesPath())
  result.fb = initFramebuffer()
  loadPalette(clientDataDir() / "pallete.png")
  result.flashColor = brightestPaletteColor()
  result.digitSprites = loadDigitSprites(clientDataDir() / "numbers.png")
  result.letterSprites = loadLetterSprites(clientDataDir() / "letters.png")

  for x in 0 ..< BoardWidthCells:
    result.terrain[boardIndex(x, BaseTerrainY)] = true

proc findSpawnPosition(
  sim: SimServer,
  kind: PieceKind,
  desiredCenterX, desiredTopY: int
): tuple[found: bool, x: int, y: int] =
  let desiredX = desiredCenterX - 2 + PieceSpawnNudgeCells
  for offset in 0 ..< 80:
    let topY = max(0, desiredTopY - offset)
    if sim.canPlace(desiredX, topY, kind, 0):
      return (true, desiredX, topY)
  for offset in 1 ..< 40:
    let topY = min(BoardHeightCells - 4, desiredTopY + offset)
    if sim.canPlace(desiredX, topY, kind, 0):
      return (true, desiredX, topY)

proc respawnPlayer(sim: var SimServer, playerIndex, centerX, topY: int, recenterHoriz = false) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  let nextKind = sim.players[playerIndex].nextKind
  let spawn = sim.findSpawnPosition(nextKind, centerX, topY)
  if not spawn.found:
    sim.players[playerIndex].alive = false
    sim.players[playerIndex].hasPiece = false
    return

  sim.players[playerIndex].alive = true
  sim.players[playerIndex].hasPiece = true
  sim.players[playerIndex].pieceKind = nextKind
  sim.players[playerIndex].nextKind = sim.randomPiece()
  sim.players[playerIndex].rotation = 0
  sim.players[playerIndex].cellX = spawn.x
  sim.players[playerIndex].cellY = spawn.y
  sim.players[playerIndex].moveTicksX = 0
  sim.players[playerIndex].moveTicksY = 0
  sim.players[playerIndex].fallTicks = 0
  sim.players[playerIndex].lockTicks = 0
  sim.players[playerIndex].deepestCellY =
    sim.players[playerIndex].pieceBottomY()
  sim.players[playerIndex].positionCameraForSpawn(recenterHoriz)
  sim.players[playerIndex].pendingSpawn = false

proc addPlayer(sim: var SimServer, name: string): int =
  inc sim.nextPlayerId
  let playerId = sim.nextPlayerId
  sim.players.add Player(
    id: playerId,
    name: name,
    color: colorForPlayer(playerId),
    rgbaColor: rgbaColorForPlayer(playerId),
    score: 0,
    alive: true,
    hasPiece: false,
    pieceKind: sim.randomPiece(),
    nextKind: sim.randomPiece()
  )
  let playerIndex = sim.players.high
  sim.respawnPlayer(playerIndex, BoardWidthCells div 2, BaseTerrainY - PieceSpawnLiftCells, recenterHoriz = true)
  playerIndex

proc tryMove(sim: var SimServer, playerIndex, dx, dy: int): bool =
  ## Moves one active piece and pushes any blocking active pieces.
  if playerIndex < 0 or
      playerIndex >= sim.players.len or
      not sim.players[playerIndex].alive or
      not sim.players[playerIndex].hasPiece:
    return false
  if dx == 0 and dy == 0:
    return true

  var movingPlayers: seq[int] = @[]
  if not sim.collectPushes(playerIndex, dx, dy, movingPlayers):
    return false
  sim.moveCollectedPlayers(movingPlayers, dx, dy)
  true

proc tryRotate(sim: var SimServer, playerIndex: int) =
  ## Rotates one active piece when the target cells are unoccupied.
  if playerIndex < 0 or
      playerIndex >= sim.players.len or
      not sim.players[playerIndex].alive or
      not sim.players[playerIndex].hasPiece:
    return

  let
    ignoredPlayers = [playerIndex]
    nextRotation = (sim.players[playerIndex].rotation + 1) and 3
  for kick in [
    (x: 0, y: 0),
    (x: -1, y: 0),
    (x: 1, y: 0),
    (x: 0, y: -1),
    (x: -2, y: 0),
    (x: 2, y: 0)
  ]:
    let
      nextX = sim.players[playerIndex].cellX + kick.x
      nextY = sim.players[playerIndex].cellY + kick.y
    if sim.canPlaceIgnoring(
      nextX,
      nextY,
      sim.players[playerIndex].pieceKind,
      nextRotation,
      ignoredPlayers
    ):
      sim.players[playerIndex].rotation = nextRotation
      sim.players[playerIndex].cellX = nextX
      sim.players[playerIndex].cellY = nextY
      break

proc addUnique(values: var seq[int], value: int) =
  for existing in values:
    if existing == value:
      return
  values.add(value)

proc hasPieceOffset(cells: openArray[BlockOffset], x, y: int): bool =
  ## Returns true when a piece offset list contains one cell.
  for cell in cells:
    if cell.x == x and cell.y == y:
      return true

proc offsetConnectionMask(
  cells: openArray[BlockOffset],
  cell: BlockOffset
): uint8 =
  ## Returns the local connection mask for one piece cell.
  if cells.hasPieceOffset(cell.x - 1, cell.y):
    result = result or ConnectLeft
  if cells.hasPieceOffset(cell.x + 1, cell.y):
    result = result or ConnectRight
  if cells.hasPieceOffset(cell.x, cell.y - 1):
    result = result or ConnectUp
  if cells.hasPieceOffset(cell.x, cell.y + 1):
    result = result or ConnectDown

proc pieceConnectionMask(
  kind: PieceKind,
  rotation: int,
  cell: BlockOffset
): uint8 =
  ## Returns the connection mask for one block inside a piece.
  let cells = pieceCells(kind, rotation)
  cells.offsetConnectionMask(cell)

proc playerConnectionMask(player: Player, cell: BlockOffset): uint8 =
  ## Returns the connection mask for one active player block.
  pieceConnectionMask(player.pieceKind, player.rotation, cell)

proc terrainConnectionMask(x: int): uint8 =
  ## Returns the horizontal connection mask for one floor cell.
  if x > 0:
    result = result or ConnectLeft
  if x < BoardWidthCells - 1:
    result = result or ConnectRight

proc neighborFor(
  x, y: int,
  direction: uint8
): tuple[x: int, y: int] =
  ## Returns the neighboring cell for one connection bit.
  case direction
  of ConnectLeft:
    (x - 1, y)
  of ConnectRight:
    (x + 1, y)
  of ConnectUp:
    (x, y - 1)
  else:
    (x, y + 1)

proc oppositeConnection(direction: uint8): uint8 =
  ## Returns the opposite connection bit.
  case direction
  of ConnectLeft:
    ConnectRight
  of ConnectRight:
    ConnectLeft
  of ConnectUp:
    ConnectDown
  else:
    ConnectUp

proc clearConnectionTo(
  sim: var SimServer,
  x, y: int,
  direction: uint8
) =
  ## Removes one stored connection from an occupied settled cell.
  if not inBoardBounds(x, y):
    return
  let index = boardIndex(x, y)
  if sim.settledColors[index] == 0:
    return
  sim.settledConnections[index] =
    sim.settledConnections[index] and not direction

proc severConnectionsToSegment(sim: var SimServer, segment: ClearSegment) =
  ## Turns connections into end caps before a row segment is removed.
  for x in segment.startX .. segment.endX:
    sim.clearConnectionTo(x - 1, segment.y, ConnectRight)
    sim.clearConnectionTo(x + 1, segment.y, ConnectLeft)
    sim.clearConnectionTo(x, segment.y - 1, ConnectDown)
    sim.clearConnectionTo(x, segment.y + 1, ConnectUp)

proc pruneSettledConnections(sim: var SimServer) =
  ## Removes any stored connections that no longer have a matching neighbor.
  for y in 0 ..< BoardHeightCells:
    for x in 0 ..< BoardWidthCells:
      let index = boardIndex(x, y)
      if sim.settledColors[index] == 0:
        sim.settledConnections[index] = 0
        continue
      var mask = sim.settledConnections[index]
      for direction in [ConnectLeft, ConnectRight, ConnectUp, ConnectDown]:
        if (mask and direction) == 0:
          continue
        let neighbor = neighborFor(x, y, direction)
        if not inBoardBounds(neighbor.x, neighbor.y):
          mask = mask and not direction
          continue
        let neighborIndex = boardIndex(neighbor.x, neighbor.y)
        if sim.settledColors[neighborIndex] == 0 or
            (sim.settledConnections[neighborIndex] and
              direction.oppositeConnection()) == 0:
          mask = mask and not direction
      sim.settledConnections[index] = mask

proc hasStaticSupportBelow(sim: SimServer, playerIndex: int): bool =
  ## Returns true when terrain or settled blocks support a player piece.
  if playerIndex < 0 or
      playerIndex >= sim.players.len or
      not sim.players[playerIndex].alive or
      not sim.players[playerIndex].hasPiece:
    return false
  let player = sim.players[playerIndex]
  not sim.canPlaceStatic(
    player.cellX,
    player.cellY + 1,
    player.pieceKind,
    player.rotation
  )

proc findClearSegments(sim: SimServer): seq[ClearSegment] =
  for y in countdown(BoardHeightCells - 1, 0):
    var x = 0
    while x < BoardWidthCells:
      let index = boardIndex(x, y)
      if sim.settledColors[index] == 0:
        inc x
        continue
      let startX = x
      while x < BoardWidthCells and sim.settledColors[boardIndex(x, y)] != 0:
        inc x
      let endX = x - 1
      if endX - startX + 1 >= LineClearLength:
        result.add ClearSegment(y: y, startX: startX, endX: endX)

proc awardPendingClear(sim: var SimServer, clear: PendingClear) =
  for player in sim.players.mitems:
    if player.id == clear.triggerPlayerId:
      player.score += clear.scoreValue
      break

proc clearSegments(sim: var SimServer, segments: openArray[ClearSegment]) =
  for segment in segments:
    sim.severConnectionsToSegment(segment)
    for x in segment.startX .. segment.endX:
      let index = boardIndex(x, segment.y)
      sim.settledColors[index] = 0
      sim.settledOwners[index] = 0
      sim.settledConnections[index] = 0
  sim.settledCellsDirty = true

proc dropAboveSegmentOneRow(sim: var SimServer, segment: ClearSegment) =
  for x in segment.startX .. segment.endX:
    for y in countdown(segment.y, 1):
      let
        dstIndex = boardIndex(x, y)
        srcIndex = boardIndex(x, y - 1)
      sim.settledColors[dstIndex] = sim.settledColors[srcIndex]
      sim.settledOwners[dstIndex] = sim.settledOwners[srcIndex]
      sim.settledConnections[dstIndex] = sim.settledConnections[srcIndex]

    let topIndex = boardIndex(x, 0)
    sim.settledColors[topIndex] = 0
    sim.settledOwners[topIndex] = 0
    sim.settledConnections[topIndex] = 0
  sim.pruneSettledConnections()
  sim.settledCellsDirty = true

proc rebuildSettledCellIndices(sim: var SimServer) =
  ## Rebuilds the compact list of occupied settled cells.
  sim.settledCellIndices.setLen(0)
  for y in 0 ..< BoardHeightCells:
    for x in 0 ..< BoardWidthCells:
      let index = boardIndex(x, y)
      if sim.settledColors[index] != 0:
        sim.settledCellIndices.add(index)
  sim.settledCellsDirty = false

proc pendingClearFor(sim: SimServer, segment: ClearSegment, triggerPlayerId: int): PendingClear =
  var
    ownersSeen: seq[int]
    lineLength = segment.endX - segment.startX + 1
  for x in segment.startX .. segment.endX:
    let index = boardIndex(x, segment.y)
    if sim.settledColors[index] != 0:
      let owner = sim.settledOwners[index]
      if owner > 0:
        ownersSeen.addUnique(owner)
  PendingClear(
    segment: segment,
    triggerPlayerId: triggerPlayerId,
    lineLength: lineLength,
    colorCount: max(1, ownersSeen.len),
    scoreValue: lineLength * max(1, ownersSeen.len)
  )

proc enqueueDetectedClears(sim: var SimServer, triggerPlayerId: int): bool =
  let segments = sim.findClearSegments()
  if segments.len == 0:
    return false
  for segment in segments:
    sim.clearQueue.add sim.pendingClearFor(segment, triggerPlayerId)
  sim.clearCascadePlayerId = triggerPlayerId
  result = true

proc startNextClear(sim: var SimServer): bool =
  if sim.clearQueue.len == 0:
    return false
  sim.activeClear = sim.clearQueue[0]
  sim.clearQueue.delete(0)
  sim.activeClearValid = true
  sim.clearFlashTimer = ClearFlashTicks
  sim.clearDisplayPlayerId = sim.activeClear.triggerPlayerId
  true

proc finishPendingRespawns(sim: var SimServer) =
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].alive and sim.players[playerIndex].pendingSpawn:
      sim.respawnPlayer(
        playerIndex,
        sim.players[playerIndex].pendingSpawnCenterX,
        sim.players[playerIndex].pendingSpawnTopY
      )

proc finalizeActiveClear(sim: var SimServer) =
  if not sim.activeClearValid:
    return

  sim.awardPendingClear(sim.activeClear)
  sim.clearSegments([sim.activeClear.segment])
  sim.dropAboveSegmentOneRow(sim.activeClear.segment)
  sim.clearDisplayPlayerId = sim.activeClear.triggerPlayerId
  sim.activeClearValid = false
  sim.clearFlashTimer = 0

  sim.clearQueue.setLen(0)
  discard sim.enqueueDetectedClears(sim.clearCascadePlayerId)
  sim.clearPauseTimer = ClearPauseTicks

proc clearAnimationActive(sim: SimServer): bool =
  sim.activeClearValid or sim.clearQueue.len > 0 or sim.clearPauseTimer > 0

proc tickClearAnimation(sim: var SimServer) =
  if sim.activeClearValid:
    dec sim.clearFlashTimer
    if sim.clearFlashTimer <= 0:
      sim.finalizeActiveClear()
    return

  if sim.clearPauseTimer > 0:
    dec sim.clearPauseTimer
    if sim.clearPauseTimer == 0:
      if sim.clearQueue.len > 0:
        discard sim.startNextClear()
      else:
        sim.clearDisplayPlayerId = 0
        sim.finishPendingRespawns()
    return

  if sim.clearQueue.len > 0:
    discard sim.startNextClear()

proc lockPiece(sim: var SimServer, playerIndex: int) =
  ## Settles one active piece when its current cells are still valid.
  if playerIndex < 0 or
      playerIndex >= sim.players.len or
      not sim.players[playerIndex].alive or
      not sim.players[playerIndex].hasPiece:
    return

  let ignoredPlayers = [playerIndex]
  if not sim.canPlaceIgnoring(
    sim.players[playerIndex].cellX,
    sim.players[playerIndex].cellY,
    sim.players[playerIndex].pieceKind,
    sim.players[playerIndex].rotation,
    ignoredPlayers
  ):
    return

  let bounds = sim.players[playerIndex].pieceBounds()
  for cell in pieceCells(
    sim.players[playerIndex].pieceKind,
    sim.players[playerIndex].rotation
  ):
    let
      x = sim.players[playerIndex].cellX + cell.x
      y = sim.players[playerIndex].cellY + cell.y
      index = boardIndex(x, y)
    sim.settledColors[index] = sim.players[playerIndex].color
    sim.settledOwners[index] = sim.players[playerIndex].id
    sim.settledConnections[index] =
      sim.players[playerIndex].playerConnectionMask(cell)
    sim.settledCellIndices.add(index)
  sim.settledCellsDirty = true

  sim.players[playerIndex].hasPiece = false

  let
    nextCenterX = (bounds.minX + bounds.maxX) div 2
    nextTopY = bounds.minY - PieceSpawnLiftCells

  if sim.enqueueDetectedClears(sim.players[playerIndex].id):
    sim.players[playerIndex].pendingSpawn = true
    sim.players[playerIndex].pendingSpawnCenterX = nextCenterX
    sim.players[playerIndex].pendingSpawnTopY = nextTopY
    if not sim.activeClearValid and sim.clearPauseTimer == 0:
      discard sim.startNextClear()
  else:
    sim.respawnPlayer(playerIndex, nextCenterX, nextTopY)

proc applyInput(sim: var SimServer, playerIndex: int, input: InputState) =
  ## Applies one tick of player input to an active piece.
  if playerIndex < 0 or
      playerIndex >= sim.players.len or
      not sim.players[playerIndex].alive or
      not sim.players[playerIndex].hasPiece:
    return

  if sim.players[playerIndex].moveTicksX > 0:
    dec sim.players[playerIndex].moveTicksX
  if sim.players[playerIndex].moveTicksY > 0:
    dec sim.players[playerIndex].moveTicksY

  if input.attack:
    sim.tryRotate(playerIndex)

  let horizontal =
    (if input.left and not input.right: -1
     elif input.right and not input.left: 1
     else: 0)
  if horizontal != 0 and sim.players[playerIndex].moveTicksX == 0:
    discard sim.tryMove(playerIndex, horizontal, 0)
    sim.players[playerIndex].moveTicksX = MoveRepeatInterval

  let vertical = if input.down: 1 else: 0
  if vertical != 0 and sim.players[playerIndex].moveTicksY == 0:
    discard sim.tryMove(playerIndex, 0, vertical)
    sim.players[playerIndex].moveTicksY = MoveRepeatInterval

  inc sim.players[playerIndex].fallTicks
  let fallInterval = if input.down: SoftFallInterval else: BaseFallInterval
  if sim.players[playerIndex].fallTicks >= fallInterval:
    sim.players[playerIndex].fallTicks = 0
    discard sim.tryMove(playerIndex, 0, 1)

  sim.refreshLockDepth(playerIndex)
  if sim.hasStaticSupportBelow(playerIndex):
    inc sim.players[playerIndex].lockTicks
    if sim.players[playerIndex].lockTicks >= LockDelayTicks or input.select:
      sim.lockPiece(playerIndex)
  else:
    sim.players[playerIndex].lockTicks = 0

proc renderBoard(sim: var SimServer, cameraX, cameraY: int) =
  let
    startCellX = max(0, cameraX div CellPixels)
    startCellY = max(0, cameraY div CellPixels)
    endCellX = min(BoardWidthCells - 1, (cameraX + ScreenWidth - 1) div CellPixels)
    endCellY = min(BoardHeightCells - 1, (cameraY + ScreenHeight - 1) div CellPixels)

  for y in startCellY .. endCellY:
    for x in startCellX .. endCellX:
      let index = boardIndex(x, y)
      if sim.terrain[index]:
        sim.fb.putRect(x * CellPixels - cameraX, y * CellPixels - cameraY, CellPixels, CellPixels, TerrainColor)
      elif sim.settledColors[index] != 0:
        sim.fb.putRect(x * CellPixels - cameraX, y * CellPixels - cameraY, CellPixels, CellPixels, sim.settledColors[index])

proc renderActiveClear(sim: var SimServer, cameraX, cameraY: int) =
  if not sim.activeClearValid:
    return
  for x in sim.activeClear.segment.startX .. sim.activeClear.segment.endX:
    sim.fb.putRect(
      x * CellPixels - cameraX,
      sim.activeClear.segment.y * CellPixels - cameraY,
      CellPixels,
      CellPixels,
      sim.flashColor
    )

proc renderClearHud(sim: var SimServer) =
  if sim.clearDisplayPlayerId <= 0:
    return
  let
    playerNumber = sim.clearDisplayPlayerId mod 100
    popupY = 18
  var x = 0
  x += sim.fb.renderSolidText(sim.letterSprites, "P", x, popupY, sim.flashColor)
  x += sim.fb.renderSolidNumber(sim.digitSprites, playerNumber, x, popupY, sim.flashColor)
  if sim.activeClear.scoreValue > 0:
    x += 2
    x += sim.fb.renderSolidNumber(sim.digitSprites, sim.activeClear.scoreValue, x, popupY, sim.flashColor)
    if sim.activeClear.colorCount > 1:
      x += 2
      x += sim.fb.renderSolidNumber(sim.digitSprites, sim.activeClear.lineLength, x, popupY, sim.flashColor)
      x += sim.fb.renderSolidText(sim.letterSprites, "X", x, popupY, sim.flashColor)
      discard sim.fb.renderSolidNumber(sim.digitSprites, sim.activeClear.colorCount, x, popupY, sim.flashColor)

proc renderHud(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  let player = sim.players[playerIndex]
  discard sim.fb.renderNumber(sim.digitSprites, player.score, 0, 0, showZero = false)
  sim.fb.drawPreview(player.nextKind, player.color, ScreenWidth - 8, 0)
  sim.renderClearHud()

proc render(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(BackgroundColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return sim.fb.packed

  let player = sim.players[playerIndex]
  if not player.alive:
    sim.fb.blitText(sim.letterSprites, "GAME", 20, 26)
    sim.fb.blitText(sim.letterSprites, "OVER", 20, 34)
    sim.fb.packFramebuffer()
    return sim.fb.packed

  let
    cameraX = player.cameraX
    cameraY = player.cameraY

  sim.renderBoard(cameraX, cameraY)
  for otherPlayer in sim.players:
    if otherPlayer.alive and otherPlayer.hasPiece:
      sim.fb.drawPiece(otherPlayer, cameraX, cameraY, otherPlayer.color)
  sim.renderActiveClear(cameraX, cameraY)
  sim.renderHud(playerIndex)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc addU8(packet: var seq[uint8], value: uint8) =
  ## Appends one unsigned byte to a global protocol packet.
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

proc addU32(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 32 bit value.
  let v = uint32(value)
  for shift in countup(0, 24, 8):
    packet.add(uint8((v shr shift) and 0xff'u32))

proc addViewport(packet: var seq[uint8], layer, width, height: int) =
  ## Appends a global protocol viewport message.
  packet.addU8(0x05)
  packet.addU8(uint8(layer))
  packet.addU16(width)
  packet.addU16(height)

proc addLayer(packet: var seq[uint8], layer, layerType, flags: int) =
  ## Appends a global protocol layer definition message.
  packet.addU8(0x06)
  packet.addU8(uint8(layer))
  packet.addU8(uint8(layerType))
  packet.addU8(uint8(flags))

proc addSprite(
  packet: var seq[uint8],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label: string
) =
  ## Appends one global protocol sprite definition message.
  packet.addU8(0x01)
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

proc addObject(
  packet: var seq[uint8],
  objectId, x, y, z, layer, spriteId: int
) =
  ## Appends one global protocol object definition message.
  packet.addU8(0x02)
  packet.addU16(objectId)
  packet.addI16(x)
  packet.addI16(y)
  packet.addI16(z)
  packet.addU8(uint8(layer))
  packet.addU16(spriteId)

proc addClearObjects(packet: var seq[uint8]) =
  ## Appends a global protocol clear-objects message.
  packet.addU8(0x04)

proc addRgbaSprite(
  packet: var seq[uint8],
  spriteId: int,
  sprite: RgbaSprite,
  label: string
) =
  ## Appends one RGBA sprite definition.
  packet.addSprite(spriteId, sprite.width, sprite.height, sprite.pixels, label)

proc terrainRgbaColor(): RgbaColor =
  ## Returns the neutral floor color.
  (r: 104'u8, g: 116'u8, b: 130'u8, a: 255'u8)

proc clearRgbaColor(): RgbaColor =
  ## Returns the line-clear flash color.
  (r: 255'u8, g: 255'u8, b: 255'u8, a: 255'u8)

proc ownerBlockSpriteBase(owner: int): int =
  ## Returns the first sprite id for one owner color set.
  GlobalPlayerSpriteBase + (max(1, owner) - 1) * BlockSpriteVariants

proc ownerBlockSpriteId(owner: int, mask: uint8): int =
  ## Returns the sprite id for one owner connection mask.
  owner.ownerBlockSpriteBase() + int(mask and 0x0f'u8)

proc terrainBlockSpriteId(mask: uint8): int =
  ## Returns the sprite id for one terrain connection mask.
  GlobalTerrainSpriteBase + int(mask and 0x0f'u8)

proc clearBlockSpriteId(mask: uint8): int =
  ## Returns the sprite id for one clear-flash connection mask.
  GlobalClearSpriteBase + int(mask and 0x0f'u8)

proc addBlockSpriteSet(
  packet: var seq[uint8],
  spriteBase: int,
  parts: array[BlockPartCount, RgbaSprite],
  color: RgbaColor,
  label: string
) =
  ## Appends all composite block sprites for one color.
  for mask in 0 ..< BlockSpriteVariants:
    let sprite = composeBlockSprite(parts, mask.uint8, color)
    packet.addRgbaSprite(spriteBase + mask, sprite, label & " " & $mask)

proc addTerrainBlockSprites(
  packet: var seq[uint8],
  state: var GlobalViewerState,
  parts: array[BlockPartCount, RgbaSprite]
) =
  ## Appends terrain block sprites once per viewer.
  if state.sentTerrainSprites:
    return
  state.sentTerrainSprites = true
  packet.addBlockSpriteSet(
    GlobalTerrainSpriteBase,
    parts,
    terrainRgbaColor(),
    "terrain block"
  )

proc addClearBlockSprites(
  packet: var seq[uint8],
  state: var GlobalViewerState,
  parts: array[BlockPartCount, RgbaSprite]
) =
  ## Appends clear-flash block sprites once per viewer.
  if state.sentClearSprites:
    return
  state.sentClearSprites = true
  packet.addBlockSpriteSet(
    GlobalClearSpriteBase,
    parts,
    clearRgbaColor(),
    "clear block"
  )

proc addOwnerBlockSprites(
  packet: var seq[uint8],
  ownersAdded: var seq[int],
  owner: int,
  parts: array[BlockPartCount, RgbaSprite]
) =
  ## Appends owner block sprites once per viewer.
  if owner <= 0 or owner in ownersAdded:
    return
  ownersAdded.add(owner)
  packet.addBlockSpriteSet(
    owner.ownerBlockSpriteBase(),
    parts,
    rgbaColorForPlayer(owner),
    "player block " & $owner
  )

proc paletteRgbaColor(color: uint8): RgbaColor =
  ## Returns one palette color as a true-color RGBA value.
  let rgba = Palette[int(color and 0x0f'u8)]
  (
    r: rgba.r,
    g: rgba.g,
    b: rgba.b,
    a: rgba.a
  )

proc blockRgbaColor(owner: int, fallbackColor: uint8): RgbaColor =
  ## Returns a true-color block color for an owner.
  if owner > 0:
    return rgbaColorForPlayer(owner)
  paletteRgbaColor(fallbackColor)

proc addObjectIfRoom(
  packet: var seq[uint8],
  objectId: var int,
  x, y, z, spriteId: int
) =
  ## Appends one object while the protocol id space has room.
  if objectId > MaxGlobalObjectId:
    return
  packet.addObject(objectId, x, y, z, GlobalLayerId, spriteId)
  inc objectId

proc putRgbaColorPixel(
  pixels: var seq[uint8],
  pixelIndex: int,
  color: RgbaColor
) =
  ## Writes one true-color RGBA pixel.
  let offset = pixelIndex * 4
  pixels[offset] = color.r
  pixels[offset + 1] = color.g
  pixels[offset + 2] = color.b
  pixels[offset + 3] = color.a

proc rgbaFromPackedFrame(frame: openArray[uint8]): seq[uint8] =
  ## Converts one packed palette framebuffer to RGBA pixels.
  result = newSeq[uint8](ScreenWidth * ScreenHeight * 4)
  var pixelIndex = 0
  for byte in frame:
    for packedIndex in 0 .. 1:
      let colorIndex =
        if packedIndex == 0:
          byte and 0x0f'u8
        else:
          byte shr 4
      let
        color = Palette[int(colorIndex)]
        offset = pixelIndex * 4
      result[offset] = color.r
      result[offset + 1] = color.g
      result[offset + 2] = color.b
      result[offset + 3] = color.a
      inc pixelIndex

proc packedFramePixel(frame: openArray[uint8], x, y: int): uint8 =
  ## Returns one palette index from a packed framebuffer.
  if x < 0 or y < 0 or x >= ScreenWidth or y >= ScreenHeight:
    return 0
  let
    pixelIndex = y * ScreenWidth + x
    value = frame[pixelIndex div 2]
  if (pixelIndex and 1) == 0:
    value and 0x0f'u8
  else:
    value shr 4

proc putRgbaRectMasked(
  pixels: var seq[uint8],
  frame: openArray[uint8],
  x, y, w, h: int,
  sourceColor: uint8,
  color: RgbaColor
) =
  ## Recolors a packed-frame rectangle where the source color matches.
  for py in 0 ..< h:
    let sy = y + py
    if sy < 0 or sy >= ScreenHeight:
      continue
    for px in 0 ..< w:
      let sx = x + px
      if sx < 0 or sx >= ScreenWidth:
        continue
      if frame.packedFramePixel(sx, sy) == sourceColor:
        pixels.putRgbaColorPixel(sy * ScreenWidth + sx, color)

proc overlayRgbaBoardBlocks(
  sim: SimServer,
  pixels: var seq[uint8],
  frame: openArray[uint8],
  cameraX, cameraY: int
) =
  ## Recolors visible settled blocks with true-color owner colors.
  let
    startCellX = max(0, cameraX div CellPixels)
    startCellY = max(0, cameraY div CellPixels)
    endCellX = min(BoardWidthCells - 1, (cameraX + ScreenWidth - 1) div CellPixels)
    endCellY = min(BoardHeightCells - 1, (cameraY + ScreenHeight - 1) div CellPixels)
  for y in startCellY .. endCellY:
    for x in startCellX .. endCellX:
      let
        index = boardIndex(x, y)
        sourceColor = sim.settledColors[index]
      if sourceColor == 0:
        continue
      pixels.putRgbaRectMasked(
        frame,
        x * CellPixels - cameraX,
        y * CellPixels - cameraY,
        CellPixels,
        CellPixels,
        sourceColor,
        blockRgbaColor(sim.settledOwners[index], sourceColor)
      )

proc overlayRgbaPiece(
  pixels: var seq[uint8],
  frame: openArray[uint8],
  player: Player,
  cameraX, cameraY: int
) =
  ## Recolors one visible active piece with its true-color player color.
  for cell in pieceCells(player.pieceKind, player.rotation):
    let
      screenX = (player.cellX + cell.x) * CellPixels - cameraX
      screenY = (player.cellY + cell.y) * CellPixels - cameraY
    pixels.putRgbaRectMasked(
      frame,
      screenX,
      screenY,
      CellPixels,
      CellPixels,
      player.color,
      player.rgbaColor
    )

proc overlayRgbaPreview(
  pixels: var seq[uint8],
  frame: openArray[uint8],
  kind: PieceKind,
  sourceColor: uint8,
  color: RgbaColor,
  screenX, screenY: int
) =
  ## Recolors the next-piece preview with its true-color player color.
  let previewPlayer = Player(pieceKind: kind, rotation: 0, cellX: 0, cellY: 0)
  for cell in pieceCells(previewPlayer.pieceKind, previewPlayer.rotation):
    pixels.putRgbaRectMasked(
      frame,
      screenX + cell.x * CellPixels,
      screenY + cell.y * CellPixels,
      CellPixels,
      CellPixels,
      sourceColor,
      color
    )

proc renderSpriteFrame(sim: var SimServer, playerIndex: int): seq[uint8] =
  ## Renders a true-color sprite-protocol player frame.
  let frame = sim.render(playerIndex)
  result = rgbaFromPackedFrame(frame)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let player = sim.players[playerIndex]
  if not player.alive:
    return
  let
    cameraX = player.cameraX
    cameraY = player.cameraY
  sim.overlayRgbaBoardBlocks(result, frame, cameraX, cameraY)
  for otherPlayer in sim.players:
    if otherPlayer.alive and otherPlayer.hasPiece:
      result.overlayRgbaPiece(frame, otherPlayer, cameraX, cameraY)
  result.overlayRgbaPreview(
    frame,
    player.nextKind,
    player.color,
    player.rgbaColor,
    ScreenWidth - 8,
    0
  )

proc buildGlobalFramePacket(
  sim: var SimServer,
  playerIndex: int,
  state: GlobalViewerState,
  nextState: var GlobalViewerState
): seq[uint8] =
  ## Builds one global protocol packet for a sprite-object player frame.
  nextState = state
  if not state.initialized:
    result.addViewport(GlobalLayerId, ScreenWidth, ScreenHeight)
    result.addLayer(GlobalLayerId, GlobalMapLayerType, GlobalZoomableFlag)
    nextState.initialized = true
  result.addTerrainBlockSprites(nextState, sim.blockParts)
  result.addClearObjects()
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let player = sim.players[playerIndex]
  if not player.alive:
    return
  let
    cameraX = player.cameraX
    cameraY = player.cameraY
    startCellX = max(0, cameraX div CellPixels)
    startCellY = max(0, cameraY div CellPixels)
    endCellX = min(
      BoardWidthCells - 1,
      (cameraX + ScreenWidth - 1) div CellPixels
    )
    endCellY = min(
      BoardHeightCells - 1,
      (cameraY + ScreenHeight - 1) div CellPixels
    )
  var objectId = GlobalFrameObjectBase

  for y in startCellY .. endCellY:
    for x in startCellX .. endCellX:
      let index = boardIndex(x, y)
      if sim.terrain[index]:
        result.addObjectIfRoom(
          objectId,
          x * CellPixels - cameraX,
          y * CellPixels - cameraY,
          0,
          terrainBlockSpriteId(terrainConnectionMask(x))
        )
      elif sim.settledColors[index] != 0:
        let owner = sim.settledOwners[index]
        result.addOwnerBlockSprites(
          nextState.sentOwners,
          owner,
          sim.blockParts
        )
        result.addObjectIfRoom(
          objectId,
          x * CellPixels - cameraX,
          y * CellPixels - cameraY,
          1,
          ownerBlockSpriteId(owner, sim.settledConnections[index])
        )

  if sim.activeClearValid:
    result.addClearBlockSprites(nextState, sim.blockParts)
    for x in sim.activeClear.segment.startX .. sim.activeClear.segment.endX:
      let
        index = boardIndex(x, sim.activeClear.segment.y)
        mask =
          if inBoardBounds(x, sim.activeClear.segment.y):
            sim.settledConnections[index]
          else:
            0'u8
      result.addObjectIfRoom(
        objectId,
        x * CellPixels - cameraX,
        sim.activeClear.segment.y * CellPixels - cameraY,
        2,
        clearBlockSpriteId(mask)
      )

  for otherPlayer in sim.players:
    if not otherPlayer.alive or not otherPlayer.hasPiece:
      continue
    result.addOwnerBlockSprites(
      nextState.sentOwners,
      otherPlayer.id,
      sim.blockParts
    )
    for cell in pieceCells(otherPlayer.pieceKind, otherPlayer.rotation):
      result.addObjectIfRoom(
        objectId,
        (otherPlayer.cellX + cell.x) * CellPixels - cameraX,
        (otherPlayer.cellY + cell.y) * CellPixels - cameraY,
        3,
        ownerBlockSpriteId(
          otherPlayer.id,
          otherPlayer.playerConnectionMask(cell)
        )
      )

  result.addOwnerBlockSprites(nextState.sentOwners, player.id, sim.blockParts)
  for cell in pieceCells(player.nextKind, 0):
    result.addObjectIfRoom(
      objectId,
      PreviewX + cell.x * CellPixels,
      cell.y * CellPixels,
      4,
      ownerBlockSpriteId(player.id, pieceConnectionMask(player.nextKind, 0, cell))
    )

proc buildGlobalMapPacket(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState
): seq[uint8] =
  ## Builds one global protocol packet for the full board overview.
  nextState = state
  if not state.initialized:
    result.addViewport(GlobalLayerId, GlobalMapWidth, GlobalMapHeight)
    result.addLayer(GlobalLayerId, GlobalMapLayerType, GlobalZoomableFlag)
    nextState.initialized = true
  result.addTerrainBlockSprites(nextState, sim.blockParts)
  result.addClearObjects()
  if sim.activeClearValid:
    result.addClearBlockSprites(nextState, sim.blockParts)

  var objectId = GlobalBlockObjectBase
  if sim.settledCellsDirty:
    sim.rebuildSettledCellIndices()
  for x in 0 ..< BoardWidthCells:
    result.addObjectIfRoom(
      objectId,
      x * CellPixels,
      BaseTerrainY * CellPixels,
      0,
      terrainBlockSpriteId(terrainConnectionMask(x))
    )
  for index in sim.settledCellIndices:
    let color = sim.settledColors[index]
    if color == 0:
      continue
    let
      x = index mod BoardWidthCells
      y = index div BoardWidthCells
      owner = sim.settledOwners[index]
    result.addOwnerBlockSprites(
      nextState.sentOwners,
      owner,
      sim.blockParts
    )
    result.addObjectIfRoom(
      objectId,
      x * CellPixels,
      y * CellPixels,
      1,
      ownerBlockSpriteId(owner, sim.settledConnections[index])
    )

  if sim.activeClearValid:
    for x in sim.activeClear.segment.startX .. sim.activeClear.segment.endX:
      let
        index = boardIndex(x, sim.activeClear.segment.y)
        mask = sim.settledConnections[index]
      result.addObjectIfRoom(
        objectId,
        x * CellPixels,
        sim.activeClear.segment.y * CellPixels,
        2,
        clearBlockSpriteId(mask)
      )

  for player in sim.players:
    if not player.alive or not player.hasPiece:
      continue
    result.addOwnerBlockSprites(nextState.sentOwners, player.id, sim.blockParts)
    for cell in pieceCells(player.pieceKind, player.rotation):
      result.addObjectIfRoom(
        objectId,
        (player.cellX + cell.x) * CellPixels,
        (player.cellY + cell.y) * CellPixels,
        3,
        ownerBlockSpriteId(player.id, player.playerConnectionMask(cell))
      )

proc buildRewardPacket(sim: SimServer): string =
  for player in sim.players:
    result.add("reward ")
    result.add(player.name)
    result.add(" ")
    result.add($player.score)
    result.add("\n")

proc playerResultsJson(sim: SimServer): string =
  ## Builds the current per-player result JSON.
  var
    names = newJArray()
    scores = newJArray()
    alive = newJArray()
  for player in sim.players:
    names.add(%player.name)
    scores.add(%player.score)
    alive.add(%player.alive)
  let results = %*{
    "names": names,
    "scores": scores,
    "alive": alive
  }
  $results

proc writeScoresIfChanged(
  sim: SimServer,
  path: string,
  lastScores: var string
) =
  ## Writes scores when the serialized result changed.
  if path.len == 0:
    return
  let scores = sim.playerResultsJson()
  if scores == lastScores:
    return
  let dir = path.parentDir()
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)
  writeFile(path, scores & "\n")
  lastScores = scores

proc step(sim: var SimServer, inputs: openArray[InputState]) =
  if sim.clearAnimationActive():
    sim.tickClearAnimation()
    return

  for playerIndex in 0 ..< sim.players.len:
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: InputState()
    sim.applyInput(playerIndex, input)
    if playerIndex < sim.players.len and sim.players[playerIndex].alive and sim.players[playerIndex].hasPiece:
      sim.players[playerIndex].updateCameraForPlayer()
    if sim.clearAnimationActive():
      break

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerNames = initTable[WebSocket, string]()
  appState.closedSockets = @[]
  appState.spritePlayerViewers = initTable[WebSocket, GlobalViewerState]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.rewardViewers = initTable[WebSocket, bool]()
  appState.socketKinds = initTable[WebSocket, SocketKind]()
  appState.resetRequested = false

proc socketKind(websocket: WebSocket): SocketKind =
  ## Returns the current role for a websocket.
  appState.socketKinds.getOrDefault(websocket, SocketUnknown)

proc removeGlobalSocket(websocket: WebSocket) =
  ## Removes a global viewer websocket.
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  if websocket in appState.socketKinds:
    appState.socketKinds.del(websocket)

proc removeRewardSocket(websocket: WebSocket) =
  ## Removes a reward viewer websocket.
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket in appState.socketKinds:
    appState.socketKinds.del(websocket)

proc removePlayerSocket(sim: var SimServer, websocket: WebSocket) =
  ## Removes a player websocket and its player slot.
  if websocket in appState.spritePlayerViewers:
    appState.spritePlayerViewers.del(websocket)
  if websocket notin appState.playerIndices:
    if websocket in appState.socketKinds:
      appState.socketKinds.del(websocket)
    return

  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.playerNames.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  if websocket in appState.socketKinds:
    appState.socketKinds.del(websocket)

  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc removeUnknownSocket(sim: var SimServer, websocket: WebSocket) =
  ## Removes a websocket whose role was not recorded.
  if websocket in appState.playerIndices:
    sim.removePlayerSocket(websocket)
    return
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket in appState.spritePlayerViewers:
    appState.spritePlayerViewers.del(websocket)
  if websocket in appState.inputMasks:
    appState.inputMasks.del(websocket)
  if websocket in appState.lastAppliedMasks:
    appState.lastAppliedMasks.del(websocket)
  if websocket in appState.playerNames:
    appState.playerNames.del(websocket)
  if websocket in appState.socketKinds:
    appState.socketKinds.del(websocket)

proc removeSocket(sim: var SimServer, websocket: WebSocket) =
  ## Removes a websocket according to its recorded role.
  case websocket.socketKind()
  of SocketPlayer:
    sim.removePlayerSocket(websocket)
  of SocketGlobal:
    websocket.removeGlobalSocket()
  of SocketReward:
    websocket.removeRewardSocket()
  of SocketUnknown:
    sim.removeUnknownSocket(websocket)

proc sendGlobalMapPackets(
  sim: var SimServer,
  globalViewers: openArray[WebSocket],
  globalStates: openArray[GlobalViewerState]
) =
  ## Sends one compact full-map frame to all global viewers.
  if globalViewers.len == 0:
    return
  for i in 0 ..< globalViewers.len:
    let state =
      if i < globalStates.len:
        globalStates[i]
      else:
        GlobalViewerState()
    var nextState: GlobalViewerState
    let packetBlob = blobFromBytes(
      buildGlobalMapPacket(
        sim,
        state,
        nextState
      )
    )
    try:
      globalViewers[i].send(packetBlob, BinaryMessage)
      {.gcsafe.}:
        withLock appState.lock:
          if globalViewers[i].socketKind() == SocketGlobal and
              globalViewers[i] in appState.globalViewers:
            appState.globalViewers[globalViewers[i]] = nextState
    except:
      {.gcsafe.}:
        withLock appState.lock:
          sim.removeSocket(globalViewers[i])

proc cleanPlayerName(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc playerIdentity(request: Request): string =
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  let parts = request.remoteAddress.splitWhitespace()
  if parts.len >= 2:
    return parts[0] & ":" & parts[1]
  request.remoteAddress

proc isWebSocketUpgrade(request: Request): bool =
  ## Returns true when the request is a websocket upgrade.
  request.headers["Sec-WebSocket-Key"].len > 0

proc isSpritePlayerInputPacket(blob: string): bool =
  ## Returns true when a global protocol player input packet was received.
  blob.len == InputPacketBytes and blob[0].uint8 == 0x84'u8

proc serveClientHtml(request: Request, route: string): bool =
  ## Serves one static client file for a known client route.
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

proc serveStaticClientHtml(request: Request): bool =
  ## Serves one static client asset if the route matches.
  request.serveClientHtml(request.path)

proc serveHealthz(request: Request): bool =
  ## Serves the container health check endpoint.
  if request.path != HealthPath or request.httpMethod notin ["GET", "HEAD"]:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, "healthy")
  true

proc httpHandler(request: Request) =
  if request.serveHealthz():
    discard
  elif request.path == PlayerWebSocketPath and
      request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        if websocket in appState.globalViewers:
          appState.globalViewers.del(websocket)
        if websocket in appState.rewardViewers:
          appState.rewardViewers.del(websocket)
        appState.socketKinds[websocket] = SocketPlayer
        appState.playerNames[websocket] = request.playerIdentity()
        appState.spritePlayerViewers[websocket] = GlobalViewerState()
        appState.playerIndices[websocket] = 0x7fffffff
        appState.inputMasks[websocket] = 0
        appState.lastAppliedMasks[websocket] = 0
  elif (request.path == GlobalWebSocketPath or
      request.path == ReplayWebSocketPath or
      request.path == AdminWebSocketPath) and
      request.httpMethod == "GET" and request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        if websocket in appState.rewardViewers:
          appState.rewardViewers.del(websocket)
        if websocket in appState.spritePlayerViewers:
          appState.spritePlayerViewers.del(websocket)
        if websocket in appState.inputMasks:
          appState.inputMasks.del(websocket)
        if websocket in appState.lastAppliedMasks:
          appState.lastAppliedMasks.del(websocket)
        if websocket in appState.playerIndices:
          appState.playerIndices.del(websocket)
        if websocket in appState.playerNames:
          appState.playerNames.del(websocket)
        appState.socketKinds[websocket] = SocketGlobal
        appState.globalViewers[websocket] = GlobalViewerState()
  elif request.path == RewardWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        if websocket in appState.globalViewers:
          appState.globalViewers.del(websocket)
        if websocket in appState.spritePlayerViewers:
          appState.spritePlayerViewers.del(websocket)
        if websocket in appState.inputMasks:
          appState.inputMasks.del(websocket)
        if websocket in appState.lastAppliedMasks:
          appState.lastAppliedMasks.del(websocket)
        if websocket in appState.playerIndices:
          appState.playerIndices.del(websocket)
        if websocket in appState.playerNames:
          appState.playerNames.del(websocket)
        appState.socketKinds[websocket] = SocketReward
        appState.rewardViewers[websocket] = true
  elif request.serveStaticClientHtml():
    discard
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
    discard
  of MessageEvent:
    if message.kind == BinaryMessage and
        isSpritePlayerInputPacket(message.data):
      {.gcsafe.}:
        withLock appState.lock:
          if websocket.socketKind() == SocketPlayer and
              websocket in appState.inputMasks:
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
  let
    frameDuration = initDuration(nanoseconds = 1_000_000_000 div TargetFps)
    targetTick = previousTick + frameDuration
  if getMonoTime() < targetTick:
    let sleepMs = (targetTick - getMonoTime()).inMilliseconds
    if sleepMs > 1:
      sleep(int(sleepMs - 1))
    while getMonoTime() < targetTick:
      discard
    previousTick = targetTick
  else:
    previousTick = getMonoTime()

proc runServerLoop(
  host = DefaultHost,
  port = DefaultPort,
  seed = 0x1F1B10C,
  saveScoresPath = "",
  maxTicks = 0
) =
  initAppState()

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
    currentSeed = seed
    sim = initSimServer(currentSeed)
    lastTick = getMonoTime()
    runTicks = 0
    lastScores = ""
  sim.writeScoresIfChanged(saveScoresPath, lastScores)

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      playerGlobalStates: seq[GlobalViewerState] = @[]
      inputs: seq[InputState]
      shouldReset = false
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      rewardViewers: seq[WebSocket] = @[]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removeSocket(websocket)
        appState.closedSockets.setLen(0)

        if appState.resetRequested:
          shouldReset = true
          appState.resetRequested = false
          for websocket, value in appState.playerIndices.mpairs:
            if websocket.socketKind() == SocketPlayer:
              value = 0x7fffffff
          for _, value in appState.inputMasks.mpairs:
            value = 0
          for _, value in appState.lastAppliedMasks.mpairs:
            value = 0
        else:
          for websocket in appState.playerIndices.keys:
            if websocket.socketKind() != SocketPlayer:
              continue
            if appState.playerIndices[websocket] == 0x7fffffff:
              let name = appState.playerNames.getOrDefault(websocket, "unknown")
              appState.playerIndices[websocket] = sim.addPlayer(name)

          inputs = newSeq[InputState](sim.players.len)
          for websocket, playerIndex in appState.playerIndices.pairs:
            if websocket.socketKind() != SocketPlayer:
              continue
            if playerIndex < 0 or playerIndex >= inputs.len:
              continue
            let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
            let previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
            inputs[playerIndex] = decodeInputMask(currentMask)
            inputs[playerIndex].attack =
              (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0
            appState.lastAppliedMasks[websocket] = currentMask
            sockets.add(websocket)
            playerIndices.add(playerIndex)
            playerGlobalStates.add(
              appState.spritePlayerViewers.getOrDefault(
                websocket,
                GlobalViewerState()
              )
            )

        for websocket in appState.rewardViewers.keys:
          if websocket.socketKind() == SocketReward:
            rewardViewers.add(websocket)
        for websocket, state in appState.globalViewers.pairs:
          if websocket.socketKind() == SocketGlobal:
            globalViewers.add(websocket)
            globalStates.add(state)

    if shouldReset:
      inc currentSeed
      sim = initSimServer(currentSeed)
      runTicks = 0
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            if websocket.socketKind() != SocketPlayer:
              continue
            if appState.playerIndices[websocket] == 0x7fffffff:
              let name = appState.playerNames.getOrDefault(websocket, "unknown")
              appState.playerIndices[websocket] = sim.addPlayer(name)
            sockets.add(websocket)
            playerIndices.add(appState.playerIndices[websocket])
            playerGlobalStates.add(
              appState.spritePlayerViewers.getOrDefault(
                websocket,
                GlobalViewerState()
              )
            )
      for i in 0 ..< sockets.len:
        var nextState: GlobalViewerState
        let framePacket = blobFromBytes(
          buildGlobalFramePacket(
            sim,
            playerIndices[i],
            playerGlobalStates[i],
            nextState
          )
        )
        {.gcsafe.}:
          withLock appState.lock:
            if sockets[i].socketKind() == SocketPlayer and
                sockets[i] in appState.spritePlayerViewers:
              appState.spritePlayerViewers[sockets[i]] = nextState
        sockets[i].send(framePacket, BinaryMessage)
      let rewardPacket = sim.buildRewardPacket()
      for websocket in rewardViewers:
        websocket.send(rewardPacket, TextMessage)
      sim.sendGlobalMapPackets(globalViewers, globalStates)
      sim.writeScoresIfChanged(saveScoresPath, lastScores)
      runFrameLimiter(lastTick)
      continue

    sim.step(inputs)
    inc runTicks

    for i in 0 ..< sockets.len:
      var nextState: GlobalViewerState
      let frameBlob = blobFromBytes(
        buildGlobalFramePacket(
          sim,
          playerIndices[i],
          playerGlobalStates[i],
          nextState
        )
      )
      {.gcsafe.}:
        withLock appState.lock:
          if sockets[i].socketKind() == SocketPlayer and
              sockets[i] in appState.spritePlayerViewers:
            appState.spritePlayerViewers[sockets[i]] = nextState
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removeSocket(sockets[i])

    let rewardPacket = sim.buildRewardPacket()
    for websocket in rewardViewers:
      websocket.send(rewardPacket, TextMessage)

    if runTicks mod GlobalSendInterval == 0:
      sim.sendGlobalMapPackets(globalViewers, globalStates)

    sim.writeScoresIfChanged(saveScoresPath, lastScores)
    if maxTicks > 0 and runTicks >= maxTicks:
      httpServer.close()
      joinThread(serverThread)
      break

    runFrameLimiter(lastTick)

proc readConfigString(node: JsonNode, name: string, value: var string) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(ValueError, "Config field " & name & " must be a string.")
  value = item.getStr()

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(ValueError, "Config field " & name & " must be an integer.")
  value = item.getInt()

proc update(config: var RunConfig, jsonText: string) =
  if jsonText.len == 0:
    return
  let node = parseJson(jsonText)
  if node.kind != JObject:
    raise newException(ValueError, "Config must be a JSON object.")
  node.readConfigString("address", config.address)
  node.readConfigInt("port", config.port)
  node.readConfigInt("seed", config.seed)
  node.readConfigString("saveScores", config.saveScoresPath)
  node.readConfigString("saveScoresPath", config.saveScoresPath)
  node.readConfigString("save-scores", config.saveScoresPath)
  node.readConfigString("save-scores-path", config.saveScoresPath)
  node.readConfigInt("maxTicks", config.maxTicks)
  node.readConfigInt("max-ticks", config.maxTicks)

proc defaultScoresPath(): string =
  ## Returns the configured score save path from the environment.
  result = getEnv("COGAME_SAVE_RESULTS_PATH")
  if result.len == 0:
    result = getEnv("COGAME_RESULTS_PATH")

when isMainModule:
  var
    config = RunConfig(
      address: DefaultHost,
      port: DefaultPort,
      seed: 0x1F1B10C,
      saveScoresPath: defaultScoresPath(),
      maxTicks: 0
    )
    configJson = ""
    configPath = getEnv("COGAME_CONFIG_PATH")
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": config.address = val
      of "port": config.port = parseInt(val)
      of "seed": config.seed = parseInt(val)
      of "config": configJson = val
      of "config-file": configPath = val
      of "save-scores", "save-scores-path", "saveScoresPath":
        config.saveScoresPath = val
      of "max-ticks", "maxTicks":
        config.maxTicks = parseInt(val)
      else: discard
    else: discard
  if configPath.len > 0:
    config.update(readFile(configPath))
  if configJson.len > 0:
    config.update(configJson)
  if configPath.len > 0:
    echo "Using config file: " & configPath
  if config.saveScoresPath.len > 0:
    echo "Using results save file: " & config.saveScoresPath
  runServerLoop(
    config.address,
    config.port,
    seed = config.seed,
    saveScoresPath = config.saveScoresPath,
    maxTicks = config.maxTicks
  )

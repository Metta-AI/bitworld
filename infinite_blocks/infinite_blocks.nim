import mummy
import protocol, server
import std/[json, locks, monotimes, os, parseopt, random, strutils, tables, times]

const
  BoardWidthCells = 1000
  BoardHeightCells = 1000
  CellPixels = 2
  WorldWidthPixels = BoardWidthCells * CellPixels
  WorldHeightPixels = BoardHeightCells * CellPixels
  BaseTerrainY = BoardHeightCells div 2 + 120
  PieceSpawnLiftCells = 32
  ScreenScrollMargin = 32
  BaseFallInterval = 8
  SoftFallInterval = 2
  MoveRepeatInterval = 2
  LockDelayTicks = 8
  LineClearLength = 8
  TerrainColor = 1'u8
  BackgroundColor = 0'u8
  ClearFlashTicks = 8
  ClearPauseTicks = 5
  TargetFps = 24
  WebSocketPath = "/player"
  PlayerColors = [4'u8, 5'u8, 6'u8, 7'u8, 8'u8, 9'u8, 10'u8, 11'u8, 12'u8, 13'u8, 14'u8, 15'u8]

type
  RunConfig = object
    address: string
    port: int
    seed: int

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

  Player = object
    id: int
    name: string
    color: uint8
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
    cameraX: int
    cameraY: int
    pendingSpawnCenterX: int
    pendingSpawnTopY: int
    pendingSpawn: bool

  SimServer = object
    players: seq[Player]
    settledColors: seq[uint8]
    settledOwners: seq[int]
    terrain: seq[bool]
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

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerNames: Table[WebSocket, string]
    closedSockets: seq[WebSocket]
    rewardViewers: Table[WebSocket, bool]
    resetRequested: bool

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

proc repoDir(): string =
  getCurrentDir() / ".."

proc clientDataDir(): string =
  repoDir() / "clients" / "data"

proc boardIndex(x, y: int): int =
  y * BoardWidthCells + x

proc inBoardBounds(x, y: int): bool =
  x >= 0 and y >= 0 and x < BoardWidthCells and y < BoardHeightCells

proc worldClampPixel(x, maxValue: int): int =
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

proc pieceCenterPixel(player: Player): tuple[x: int, y: int] =
  if not player.hasPiece:
    return (player.cameraX + ScreenWidth div 2, player.cameraY + ScreenScrollMargin)
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
  player.cameraY = worldClampPixel(player.cameraY, WorldHeightPixels - ScreenHeight)

proc positionCameraForSpawn(player: var Player, recenterHoriz: bool) =
  if not player.hasPiece:
    return
  let pixelBounds = piecePixelBounds(player)
  if recenterHoriz:
    let center = pieceCenterPixel(player)
    player.cameraX = center.x - ScreenWidth div 2
  player.cameraY = pixelBounds.minY - ScreenScrollMargin
  player.clampCamera()

proc updateCameraForPlayer(player: var Player) =
  if not player.hasPiece:
    return

  let pixelBounds = piecePixelBounds(player)
  if pixelBounds.minX - player.cameraX < ScreenScrollMargin:
    player.cameraX = pixelBounds.minX - ScreenScrollMargin
  elif pixelBounds.maxX - player.cameraX > ScreenWidth - 1 - ScreenScrollMargin:
    player.cameraX = pixelBounds.maxX - (ScreenWidth - 1 - ScreenScrollMargin)

  if pixelBounds.maxY - player.cameraY > ScreenHeight - 1 - ScreenScrollMargin:
    player.cameraY = pixelBounds.maxY - (ScreenHeight - 1 - ScreenScrollMargin)

  player.clampCamera()

proc canPlace(sim: SimServer, cellX, cellY: int, kind: PieceKind, rotation: int): bool =
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
  result.terrain = newSeq[bool](BoardWidthCells * BoardHeightCells)
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
  let desiredX = desiredCenterX - 2
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
  sim.players[playerIndex].positionCameraForSpawn(recenterHoriz)
  sim.players[playerIndex].pendingSpawn = false

proc addPlayer(sim: var SimServer, name: string): int =
  inc sim.nextPlayerId
  let playerId = sim.nextPlayerId
  sim.players.add Player(
    id: playerId,
    name: name,
    color: colorForPlayer(playerId),
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
  if playerIndex < 0 or playerIndex >= sim.players.len or not sim.players[playerIndex].alive or not sim.players[playerIndex].hasPiece:
    return false
  let
    nextX = sim.players[playerIndex].cellX + dx
    nextY = sim.players[playerIndex].cellY + dy
  if sim.canPlace(nextX, nextY, sim.players[playerIndex].pieceKind, sim.players[playerIndex].rotation):
    sim.players[playerIndex].cellX = nextX
    sim.players[playerIndex].cellY = nextY
    sim.players[playerIndex].lockTicks = 0
    return true
  false

proc tryRotate(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len or not sim.players[playerIndex].alive or not sim.players[playerIndex].hasPiece:
    return

  let nextRotation = (sim.players[playerIndex].rotation + 1) and 3
  for kick in [(x: 0, y: 0), (x: -1, y: 0), (x: 1, y: 0), (x: 0, y: -1), (x: -2, y: 0), (x: 2, y: 0)]:
    let
      nextX = sim.players[playerIndex].cellX + kick.x
      nextY = sim.players[playerIndex].cellY + kick.y
    if sim.canPlace(nextX, nextY, sim.players[playerIndex].pieceKind, nextRotation):
      sim.players[playerIndex].rotation = nextRotation
      sim.players[playerIndex].cellX = nextX
      sim.players[playerIndex].cellY = nextY
      sim.players[playerIndex].lockTicks = 0
      break

proc addUnique(values: var seq[int], value: int) =
  for existing in values:
    if existing == value:
      return
  values.add(value)

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
    for x in segment.startX .. segment.endX:
      let index = boardIndex(x, segment.y)
      sim.settledColors[index] = 0
      sim.settledOwners[index] = 0

proc dropAboveSegmentOneRow(sim: var SimServer, segment: ClearSegment) =
  for x in segment.startX .. segment.endX:
    for y in countdown(segment.y, 1):
      let
        dstIndex = boardIndex(x, y)
        srcIndex = boardIndex(x, y - 1)
      sim.settledColors[dstIndex] = sim.settledColors[srcIndex]
      sim.settledOwners[dstIndex] = sim.settledOwners[srcIndex]

    let topIndex = boardIndex(x, 0)
    sim.settledColors[topIndex] = 0
    sim.settledOwners[topIndex] = 0

proc pendingClearFor(sim: SimServer, segment: ClearSegment, triggerPlayerId: int): PendingClear =
  var
    colorsSeen: array[16, bool]
    colorCount = 0
    lineLength = segment.endX - segment.startX + 1
  for x in segment.startX .. segment.endX:
    let index = boardIndex(x, segment.y)
    let color = sim.settledColors[index]
    if color != 0 and not colorsSeen[color.int]:
      colorsSeen[color.int] = true
      inc colorCount
  PendingClear(
    segment: segment,
    triggerPlayerId: triggerPlayerId,
    lineLength: lineLength,
    colorCount: max(1, colorCount),
    scoreValue: lineLength * max(1, colorCount)
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
  if playerIndex < 0 or playerIndex >= sim.players.len or not sim.players[playerIndex].alive or not sim.players[playerIndex].hasPiece:
    return

  let bounds = sim.players[playerIndex].pieceBounds()
  for cell in pieceCells(sim.players[playerIndex].pieceKind, sim.players[playerIndex].rotation):
    let
      x = sim.players[playerIndex].cellX + cell.x
      y = sim.players[playerIndex].cellY + cell.y
      index = boardIndex(x, y)
    sim.settledColors[index] = sim.players[playerIndex].color
    sim.settledOwners[index] = sim.players[playerIndex].id

  let
    nextCenterX = (bounds.minX + bounds.maxX) div 2
    nextTopY = bounds.minY - PieceSpawnLiftCells

  if sim.enqueueDetectedClears(sim.players[playerIndex].id):
    sim.players[playerIndex].hasPiece = false
    sim.players[playerIndex].pendingSpawn = true
    sim.players[playerIndex].pendingSpawnCenterX = nextCenterX
    sim.players[playerIndex].pendingSpawnTopY = nextTopY
    if not sim.activeClearValid and sim.clearPauseTimer == 0:
      discard sim.startNextClear()
  else:
    sim.respawnPlayer(playerIndex, nextCenterX, nextTopY)

proc applyInput(sim: var SimServer, playerIndex: int, input: InputState) =
  if playerIndex < 0 or playerIndex >= sim.players.len or not sim.players[playerIndex].alive or not sim.players[playerIndex].hasPiece:
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
    if sim.tryMove(playerIndex, 0, 1):
      sim.players[playerIndex].lockTicks = 0

  if not sim.canPlace(
    sim.players[playerIndex].cellX,
    sim.players[playerIndex].cellY + 1,
    sim.players[playerIndex].pieceKind,
    sim.players[playerIndex].rotation
  ):
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

proc buildRewardPacket(sim: SimServer): string =
  for player in sim.players:
    result.add("reward ")
    result.add(player.name)
    result.add(" ")
    result.add($player.score)
    result.add("\n")

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
  appState.rewardViewers = initTable[WebSocket, bool]()
  appState.resetRequested = false

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket notin appState.playerIndices:
    return

  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.playerNames.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)

  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

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

proc httpHandler(request: Request) =
  if request.path == WebSocketPath and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerNames[websocket] = request.playerIdentity()
  elif request.path == "/reward" and request.httpMethod == "GET":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.rewardViewers[websocket] = true
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
        if websocket notin appState.rewardViewers:
          appState.playerIndices[websocket] = 0x7fffffff
          appState.inputMasks[websocket] = 0
          appState.lastAppliedMasks[websocket] = 0
  of MessageEvent:
    if message.kind == BinaryMessage and isInputPacket(message.data):
      {.gcsafe.}:
        withLock appState.lock:
          let mask = blobToMask(message.data)
          if mask == 255'u8:
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

proc runFrameLimiter(previousTick: var MonoTime) =
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runServerLoop(
  host = DefaultHost,
  port = DefaultPort,
  seed = 0x1F1B10C
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

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[InputState]
      shouldReset = false
      rewardViewers: seq[WebSocket] = @[]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        if appState.resetRequested:
          shouldReset = true
          appState.resetRequested = false
          for _, value in appState.playerIndices.mpairs:
            value = 0x7fffffff
          for _, value in appState.inputMasks.mpairs:
            value = 0
          for _, value in appState.lastAppliedMasks.mpairs:
            value = 0
        else:
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == 0x7fffffff:
              let name = appState.playerNames.getOrDefault(websocket, "unknown")
              appState.playerIndices[websocket] = sim.addPlayer(name)

          inputs = newSeq[InputState](sim.players.len)
          for websocket, playerIndex in appState.playerIndices.pairs:
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

        for websocket in appState.rewardViewers.keys:
          rewardViewers.add(websocket)

    if shouldReset:
      inc currentSeed
      sim = initSimServer(currentSeed)
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            if appState.playerIndices[websocket] == 0x7fffffff:
              let name = appState.playerNames.getOrDefault(websocket, "unknown")
              appState.playerIndices[websocket] = sim.addPlayer(name)
            sockets.add(websocket)
            playerIndices.add(appState.playerIndices[websocket])
      for i in 0 ..< sockets.len:
        let frameBlob = blobFromBytes(sim.render(playerIndices[i]))
        sockets[i].send(frameBlob, BinaryMessage)
      let rewardPacket = sim.buildRewardPacket()
      for websocket in rewardViewers:
        websocket.send(rewardPacket, TextMessage)
      runFrameLimiter(lastTick)
      continue

    sim.step(inputs)

    for i in 0 ..< sockets.len:
      let frameBlob = blobFromBytes(sim.render(playerIndices[i]))
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    let rewardPacket = sim.buildRewardPacket()
    for websocket in rewardViewers:
      websocket.send(rewardPacket, TextMessage)

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

when isMainModule:
  var
    config = RunConfig(address: DefaultHost, port: DefaultPort, seed: 0x1F1B10C)
    configJson = ""
    configPath = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": config.address = val
      of "port": config.port = parseInt(val)
      of "config": configJson = val
      of "config-file": configPath = val
      else: discard
    else: discard
  if configPath.len > 0:
    config.update(readFile(configPath))
  if configJson.len > 0:
    config.update(configJson)
  runServerLoop(config.address, config.port, seed = config.seed)

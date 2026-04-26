import mummy, pixie
import protocol, server
import std/[algorithm, json, locks, monotimes, os, parseopt, random, strutils, tables, times]

const
  ClientDataDir = ".." / "client" / "data"
  FactoryDataDir = "data"
  PalettePath = ClientDataDir / "pallete.png"
  NumbersPath = ClientDataDir / "numbers.png"
  FactorySheetPath = FactoryDataDir / "factory_sheet.png"
  TargetFps = 24
  WebSocketPath = "/player"

  MapWidthTiles = 48
  MapHeightTiles = 48
  WorldTilePixels = 16
  WorldWidthPixels = MapWidthTiles * WorldTilePixels
  WorldHeightPixels = MapHeightTiles * WorldTilePixels

  SpawnSearchRadius = 7
  MoveRepeatInterval = 3
  ExtractSpawnInterval = 18
  ComboWindowTicks = 24

  ToolbarHeight = 8
  ToolbarIconSize = 8
  ToolbarGap = 1
  ToolbarY = ScreenHeight - ToolbarHeight

  SheetTileSize = 16
  SheetIconSize = 8
  SheetIconRowY = SheetTileSize

  BackgroundColor = 3'u8
  ToolbarColor = 1'u8
  ToolbarDimColor = 5'u8
  CursorSelfColor = 15'u8

  PlayerColors = [4'u8, 5'u8, 6'u8, 7'u8, 8'u8, 9'u8, 10'u8, 11'u8, 12'u8, 13'u8, 14'u8, 15'u8]

type
  RunConfig = object
    address: string
    port: int
    seed: int

  Direction = enum
    DirUp
    DirRight
    DirDown
    DirLeft

  OreKind = enum
    OreNone
    OreSquare
    OreCircle

  BuildingKind = enum
    BuildingNone
    BuildingBelt
    BuildingExtractor
    BuildingLaunchPad

  BuildTool = enum
    ToolLaunchPad
    ToolExtractor
    ToolBelt
    ToolEraser

  Cell = object
    ore: OreKind
    building: BuildingKind
    direction: Direction
    launchOwnerId: int

  MovingItem = object
    worldX: int
    worldY: int
    kind: OreKind

  ItemMoveAction = enum
    ItemMove
    ItemBlocked
    ItemDeliver
    ItemRemove

  MoveIntent = object
    action: ItemMoveAction
    nextX: int
    nextY: int
    ownerId: int
    stepDir: Direction

  Player = object
    id: int
    name: string
    color: uint8
    cursorX: int
    cursorY: int
    cameraX: int
    cameraY: int
    moveTicksX: int
    moveTicksY: int
    score: int
    selectedTool: BuildTool
    extractorRotation: Direction
    beltRotation: Direction
    hasLaunchPad: bool
    launchPadX: int
    launchPadY: int
    comboTicks: int
    lastDelivered: OreKind

  FactorySprites = object
    ground: Sprite
    squarePatch: Sprite
    circlePatch: Sprite
    belt: Sprite
    extractor: Sprite
    launchPadOwn: Sprite
    launchPadEnemy: Sprite
    cursorOuterMask: Sprite
    cursorInnerMask: Sprite
    itemSquare: Sprite
    itemCircle: Sprite
    toolbarSlotMask: Sprite
    toolLaunchPadIcon: Sprite
    toolExtractorIcon: Sprite
    toolBeltIcon: Sprite
    toolEraserIcon: Sprite

  SimServer = object
    players: seq[Player]
    cells: seq[Cell]
    items: seq[MovingItem]
    art: FactorySprites
    digitSprites: array[10, Sprite]
    fb: Framebuffer
    rng: Rand
    nextPlayerId: int
    tickCount: int

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

proc mapIndex(tx, ty: int): int =
  ty * MapWidthTiles + tx

proc inBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < MapWidthTiles and ty < MapHeightTiles

proc worldClampPixel(x, maxValue: int): int =
  max(0, min(maxValue, x))

proc delta(dir: Direction): tuple[dx, dy: int] =
  case dir
  of DirUp: (0, -1)
  of DirRight: (1, 0)
  of DirDown: (0, 1)
  of DirLeft: (-1, 0)

proc worldIndex(wx, wy: int): int =
  wy * WorldWidthPixels + wx

proc tileMinX(tx: int): int =
  tx * WorldTilePixels

proc tileMinY(ty: int): int =
  ty * WorldTilePixels

proc tileCenterX(tx: int): int =
  tileMinX(tx) + WorldTilePixels div 2

proc tileCenterY(ty: int): int =
  tileMinY(ty) + WorldTilePixels div 2

proc worldTileX(wx: int): int =
  wx div WorldTilePixels

proc worldTileY(wy: int): int =
  wy div WorldTilePixels

proc inWorldBounds(wx, wy: int): bool =
  wx >= 0 and wy >= 0 and wx < WorldWidthPixels and wy < WorldHeightPixels

proc playerColorFor(id: int): uint8 =
  PlayerColors[(id - 1) mod PlayerColors.len]

proc nextDirection(dir: Direction): Direction =
  case dir
  of DirUp: DirRight
  of DirRight: DirDown
  of DirDown: DirLeft
  of DirLeft: DirUp

proc toFacing(dir: Direction): Facing =
  # The authored factory sheet uses right-facing source art.
  # Map directions onto the framebuffer rotations from that basis.
  case dir
  of DirUp: FaceLeft
  of DirRight: FaceDown
  of DirDown: FaceRight
  of DirLeft: FaceUp

proc drawRect(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  for py in 0 ..< h:
    for px in 0 ..< w:
      fb.putPixel(x + px, y + py, color)

proc renderNumber(
  fb: var Framebuffer,
  digitSprites: array[10, Sprite],
  value, screenX, screenY: int
): int =
  let text = $max(0, value)
  var x = screenX
  for ch in text:
    let digit = ord(ch) - ord('0')
    fb.blitSprite(digitSprites[digit], x, screenY, 0, 0)
    x += digitSprites[digit].width
  x - screenX

proc spriteFromSheet(sheet: Image, x, y, w, h: int): Sprite =
  result = Sprite(width: w, height: h, pixels: newSeq[uint8](w * h))
  for py in 0 ..< h:
    for px in 0 ..< w:
      result.pixels[result.spriteIndex(px, py)] = nearestPaletteIndex(sheet[x + px, y + py])

proc blitScreenSprite(
  fb: var Framebuffer,
  sprite: Sprite,
  screenX, screenY: int,
  facing = FaceDown
) =
  fb.blitSprite(sprite, screenX, screenY, 0, 0, facing)

proc blitStencilSprite(
  fb: var Framebuffer,
  sprite: Sprite,
  screenX, screenY: int,
  color: uint8,
  facing = FaceDown
) =
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      if sprite.pixels[sprite.spriteIndex(x, y)] == TransparentColorIndex:
        continue
      var
        dx = 0
        dy = 0
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
      fb.putPixel(screenX + dx, screenY + dy, color)

proc loadFactorySprites(): FactorySprites =
  let sheet = readImage(FactorySheetPath)
  result.ground = spriteFromSheet(sheet, 0 * SheetTileSize, 0, SheetTileSize, SheetTileSize)
  result.squarePatch = spriteFromSheet(sheet, 1 * SheetTileSize, 0, SheetTileSize, SheetTileSize)
  result.circlePatch = spriteFromSheet(sheet, 2 * SheetTileSize, 0, SheetTileSize, SheetTileSize)
  result.belt = spriteFromSheet(sheet, 3 * SheetTileSize, 0, SheetTileSize, SheetTileSize)
  result.extractor = spriteFromSheet(sheet, 4 * SheetTileSize, 0, SheetTileSize, SheetTileSize)
  result.launchPadOwn = spriteFromSheet(sheet, 5 * SheetTileSize, 0, SheetTileSize, SheetTileSize)
  result.launchPadEnemy = spriteFromSheet(sheet, 6 * SheetTileSize, 0, SheetTileSize, SheetTileSize)
  result.cursorOuterMask = spriteFromSheet(sheet, 7 * SheetTileSize, 0, SheetTileSize, SheetTileSize)
  result.cursorInnerMask = spriteFromSheet(sheet, 8 * SheetTileSize, 0, SheetTileSize, SheetTileSize)

  result.itemSquare = spriteFromSheet(sheet, 0 * SheetIconSize, SheetIconRowY, SheetIconSize, SheetIconSize)
  result.itemCircle = spriteFromSheet(sheet, 1 * SheetIconSize, SheetIconRowY, SheetIconSize, SheetIconSize)
  result.toolbarSlotMask = spriteFromSheet(sheet, 2 * SheetIconSize, SheetIconRowY, SheetIconSize, SheetIconSize)
  result.toolLaunchPadIcon = spriteFromSheet(sheet, 3 * SheetIconSize, SheetIconRowY, SheetIconSize, SheetIconSize)
  result.toolExtractorIcon = spriteFromSheet(sheet, 4 * SheetIconSize, SheetIconRowY, SheetIconSize, SheetIconSize)
  result.toolBeltIcon = spriteFromSheet(sheet, 5 * SheetIconSize, SheetIconRowY, SheetIconSize, SheetIconSize)
  result.toolEraserIcon = spriteFromSheet(sheet, 6 * SheetIconSize, SheetIconRowY, SheetIconSize, SheetIconSize)

proc clearCell(cell: var Cell) =
  cell.building = BuildingNone
  cell.direction = DirRight
  cell.launchOwnerId = 0

proc paintPatch(sim: var SimServer, centerX, centerY, radius: int, ore: OreKind) =
  for dy in -radius .. radius:
    for dx in -radius .. radius:
      let tx = centerX + dx
      let ty = centerY + dy
      if not inBounds(tx, ty):
        continue
      if abs(dx) + abs(dy) <= radius + 1 and sim.rng.rand(99) < 82:
        sim.cells[mapIndex(tx, ty)].ore = ore

proc clearOreZone(sim: var SimServer, centerX, centerY, radius: int) =
  for dy in -radius .. radius:
    for dx in -radius .. radius:
      let tx = centerX + dx
      let ty = centerY + dy
      if inBounds(tx, ty):
        sim.cells[mapIndex(tx, ty)].ore = OreNone

proc seedOre(sim: var SimServer) =
  for _ in 0 ..< 72:
    let
      ore = if sim.rng.rand(1) == 0: OreSquare else: OreCircle
      tx = sim.rng.rand(MapWidthTiles - 1)
      ty = sim.rng.rand(MapHeightTiles - 1)
      radius = 1 + sim.rng.rand(2)
    sim.paintPatch(tx, ty, radius, ore)

  let
    centerX = MapWidthTiles div 2
    centerY = MapHeightTiles div 2

  sim.clearOreZone(centerX, centerY, 3)
  sim.paintPatch(centerX - 5, centerY - 2, 2, OreSquare)
  sim.paintPatch(centerX + 5, centerY - 2, 2, OreCircle)
  sim.paintPatch(centerX - 4, centerY + 4, 2, OreSquare)
  sim.paintPatch(centerX + 4, centerY + 4, 2, OreCircle)

proc recenterCamera(player: var Player) =
  let
    worldX = player.cursorX * WorldTilePixels + WorldTilePixels div 2
    worldY = player.cursorY * WorldTilePixels + WorldTilePixels div 2
  player.cameraX = worldClampPixel(worldX - ScreenWidth div 2, WorldWidthPixels - ScreenWidth)
  player.cameraY = worldClampPixel(worldY - ScreenHeight div 2, WorldHeightPixels - ScreenHeight)

proc distanceSquared(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc findPlayerSpawn(sim: var SimServer): tuple[x, y: int] =
  let
    centerX = MapWidthTiles div 2
    centerY = MapHeightTiles div 2
  var candidates: seq[tuple[x, y: int]] = @[]

  for radius in 0 .. SpawnSearchRadius:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        let tx = centerX + dx
        let ty = centerY + dy
        if not inBounds(tx, ty):
          continue

        var occupied = false
        for player in sim.players:
          if distanceSquared(tx, ty, player.cursorX, player.cursorY) <= 2:
            occupied = true
            break
        if not occupied:
          candidates.add((tx, ty))

    if candidates.len > 0:
      let pick = candidates[sim.rng.rand(candidates.high)]
      return pick

  (centerX, centerY)

proc removeItemsAt(sim: var SimServer, tx, ty: int) =
  var survivors: seq[MovingItem] = @[]
  for item in sim.items:
    if worldTileX(item.worldX) == tx and worldTileY(item.worldY) == ty:
      continue
    survivors.add(item)
  sim.items = survivors

proc removePlayerLaunchPad(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let player = sim.players[playerIndex]
  if not player.hasLaunchPad or not inBounds(player.launchPadX, player.launchPadY):
    sim.players[playerIndex].hasLaunchPad = false
    sim.players[playerIndex].launchPadX = -1
    sim.players[playerIndex].launchPadY = -1
    return

  let index = mapIndex(player.launchPadX, player.launchPadY)
  if sim.cells[index].building == BuildingLaunchPad and sim.cells[index].launchOwnerId == player.id:
    sim.cells[index].clearCell()
  sim.players[playerIndex].hasLaunchPad = false
  sim.players[playerIndex].launchPadX = -1
  sim.players[playerIndex].launchPadY = -1

proc addPlayer(sim: var SimServer, name: string): int =
  inc sim.nextPlayerId
  let spawn = sim.findPlayerSpawn()
  sim.players.add Player(
    id: sim.nextPlayerId,
    name: name,
    color: playerColorFor(sim.nextPlayerId),
    cursorX: spawn.x,
    cursorY: spawn.y,
    selectedTool: ToolLaunchPad,
    extractorRotation: DirRight,
    beltRotation: DirRight,
    launchPadX: -1,
    launchPadY: -1
  )
  sim.players[^1].recenterCamera()
  sim.players.high

proc playerIndexById(sim: SimServer, id: int): int =
  for i, player in sim.players:
    if player.id == id:
      return i
  -1

proc awardDelivery(sim: var SimServer, ownerId: int, ore: OreKind) =
  let playerIndex = sim.playerIndexById(ownerId)
  if playerIndex < 0:
    return
  inc sim.players[playerIndex].score
  if sim.players[playerIndex].comboTicks > 0 and
      sim.players[playerIndex].lastDelivered != OreNone and
      sim.players[playerIndex].lastDelivered != ore:
    inc sim.players[playerIndex].score
  sim.players[playerIndex].lastDelivered = ore
  sim.players[playerIndex].comboTicks = ComboWindowTicks

proc cycleTool(player: var Player) =
  player.selectedTool = BuildTool((player.selectedTool.ord + 1) mod (BuildTool.high.ord + 1))

proc currentToolDirection(player: Player, tool: BuildTool): Direction =
  case tool
  of ToolExtractor:
    player.extractorRotation
  of ToolBelt:
    player.beltRotation
  else:
    DirRight

proc toolBuildingKind(tool: BuildTool): BuildingKind =
  case tool
  of ToolExtractor:
    BuildingExtractor
  of ToolBelt:
    BuildingBelt
  else:
    BuildingNone

proc setToolRotation(player: var Player, tool: BuildTool, dir: Direction) =
  case tool
  of ToolExtractor:
    player.extractorRotation = dir
  of ToolBelt:
    player.beltRotation = dir
  else:
    discard

proc canPlaceDirectionalTool(cell: Cell, tool: BuildTool): bool =
  if cell.building == BuildingLaunchPad:
    return false
  case tool
  of ToolExtractor:
    cell.ore != OreNone
  of ToolBelt:
    true
  else:
    false

proc placeTool(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  let
    tx = sim.players[playerIndex].cursorX
    ty = sim.players[playerIndex].cursorY
    index = mapIndex(tx, ty)
    tool = sim.players[playerIndex].selectedTool

  case tool
  of ToolEraser:
    if sim.cells[index].building == BuildingLaunchPad:
      if sim.cells[index].launchOwnerId == sim.players[playerIndex].id:
        sim.removePlayerLaunchPad(playerIndex)
    else:
      sim.removeItemsAt(tx, ty)
      sim.cells[index].clearCell()
  of ToolLaunchPad:
    if sim.cells[index].building == BuildingLaunchPad:
      return
    if sim.players[playerIndex].hasLaunchPad:
      return
    sim.removeItemsAt(tx, ty)
    sim.cells[index].building = BuildingLaunchPad
    sim.cells[index].launchOwnerId = sim.players[playerIndex].id
    sim.cells[index].direction = DirUp
    sim.players[playerIndex].hasLaunchPad = true
    sim.players[playerIndex].launchPadX = tx
    sim.players[playerIndex].launchPadY = ty
  of ToolExtractor, ToolBelt:
    if not sim.cells[index].canPlaceDirectionalTool(tool):
      return
    var direction = sim.players[playerIndex].currentToolDirection(tool)
    if sim.cells[index].building == tool.toolBuildingKind():
      direction = nextDirection(sim.cells[index].direction)
      sim.players[playerIndex].setToolRotation(tool, direction)
    sim.removeItemsAt(tx, ty)
    sim.cells[index].building = tool.toolBuildingKind()
    sim.cells[index].direction = direction
    sim.cells[index].launchOwnerId = 0

proc applyInput(sim: var SimServer, playerIndex: int, input: InputState) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  if sim.players[playerIndex].moveTicksX > 0:
    dec sim.players[playerIndex].moveTicksX
  if sim.players[playerIndex].moveTicksY > 0:
    dec sim.players[playerIndex].moveTicksY

  let horizontal =
    (if input.left and not input.right: -1
     elif input.right and not input.left: 1
     else: 0)
  let vertical =
    (if input.up and not input.down: -1
     elif input.down and not input.up: 1
     else: 0)

  if horizontal != 0 and sim.players[playerIndex].moveTicksX == 0:
    sim.players[playerIndex].cursorX = clamp(sim.players[playerIndex].cursorX + horizontal, 0, MapWidthTiles - 1)
    sim.players[playerIndex].moveTicksX = MoveRepeatInterval

  if vertical != 0 and sim.players[playerIndex].moveTicksY == 0:
    sim.players[playerIndex].cursorY = clamp(sim.players[playerIndex].cursorY + vertical, 0, MapHeightTiles - 1)
    sim.players[playerIndex].moveTicksY = MoveRepeatInterval

  if input.b:
    sim.players[playerIndex].cycleTool()
  if input.attack:
    sim.placeTool(playerIndex)

  sim.players[playerIndex].recenterCamera()

proc extractorSpawnPixel(tx, ty: int, dir: Direction): tuple[x, y: int] =
  discard dir
  (tileCenterX(tx), tileCenterY(ty))

proc computeMoveIntent(sim: SimServer, item: MovingItem): MoveIntent =
  result.stepDir = DirRight
  if not inWorldBounds(item.worldX, item.worldY):
    result.action = ItemRemove
    return

  let
    tx = worldTileX(item.worldX)
    ty = worldTileY(item.worldY)
  if not inBounds(tx, ty):
    result.action = ItemRemove
    return

  let cell = sim.cells[mapIndex(tx, ty)]
  case cell.building
  of BuildingNone:
    result.action = ItemRemove
  of BuildingLaunchPad:
    result.action = ItemDeliver
    result.ownerId = cell.launchOwnerId
  of BuildingBelt, BuildingExtractor:
    let
      centerX = tileCenterX(tx)
      centerY = tileCenterY(ty)
    var
      nextX = item.worldX
      nextY = item.worldY

    # Each tile behaves like a one-pixel-wide lane. Items first steer onto the
    # lane center, then advance one pixel at a time in the tile's facing.
    case cell.direction
    of DirUp, DirDown:
      if item.worldX != centerX:
        if item.worldX < centerX:
          inc nextX
          result.stepDir = DirRight
        else:
          dec nextX
          result.stepDir = DirLeft
      else:
        let d = delta(cell.direction)
        nextY += d.dy
        result.stepDir = cell.direction
    of DirLeft, DirRight:
      if item.worldY != centerY:
        if item.worldY < centerY:
          inc nextY
          result.stepDir = DirDown
        else:
          dec nextY
          result.stepDir = DirUp
      else:
        let d = delta(cell.direction)
        nextX += d.dx
        result.stepDir = cell.direction

    if not inWorldBounds(nextX, nextY):
      result.action = ItemBlocked
      return

    let
      nextTx = worldTileX(nextX)
      nextTy = worldTileY(nextY)
    if not inBounds(nextTx, nextTy):
      result.action = ItemBlocked
      return

    if nextTx != tx or nextTy != ty:
      let nextCell = sim.cells[mapIndex(nextTx, nextTy)]
      case nextCell.building
      of BuildingLaunchPad:
        result.action = ItemDeliver
        result.ownerId = nextCell.launchOwnerId
      of BuildingBelt, BuildingExtractor:
        result.action = ItemMove
      of BuildingNone:
        result.action = ItemBlocked
    else:
      result.action = ItemMove

    result.nextX = nextX
    result.nextY = nextY

proc moveActionPriority(intent: MoveIntent): int =
  case intent.action
  of ItemDeliver, ItemRemove: 0
  of ItemMove: 1
  of ItemBlocked: 2

proc compareMoveOrder(items: seq[MovingItem], intents: seq[MoveIntent], a, b: int): int =
  let
    ia = items[a]
    ib = items[b]
    planA = intents[a]
    planB = intents[b]
  if planA.moveActionPriority() != planB.moveActionPriority():
    return cmp(planA.moveActionPriority(), planB.moveActionPriority())
  if planA.stepDir != planB.stepDir:
    return cmp(planA.stepDir.ord, planB.stepDir.ord)

  case planA.stepDir
  of DirRight:
    if ia.worldX != ib.worldX: return cmp(ib.worldX, ia.worldX)
    cmp(ia.worldY, ib.worldY)
  of DirLeft:
    if ia.worldX != ib.worldX: return cmp(ia.worldX, ib.worldX)
    cmp(ia.worldY, ib.worldY)
  of DirDown:
    if ia.worldY != ib.worldY: return cmp(ib.worldY, ia.worldY)
    cmp(ia.worldX, ib.worldX)
  of DirUp:
    if ia.worldY != ib.worldY: return cmp(ia.worldY, ib.worldY)
    cmp(ia.worldX, ib.worldX)

proc advanceItems(sim: var SimServer) =
  if sim.items.len == 0:
    return

  var occupied = newSeq[bool](WorldWidthPixels * WorldHeightPixels)
  for item in sim.items:
    if inWorldBounds(item.worldX, item.worldY):
      occupied[worldIndex(item.worldX, item.worldY)] = true

  var intents = newSeq[MoveIntent](sim.items.len)
  for i, item in sim.items:
    intents[i] = sim.computeMoveIntent(item)

  var order = newSeq[int](sim.items.len)
  for i in 0 ..< order.len:
    order[i] = i
  let
    itemsSnapshot = sim.items
    intentsSnapshot = intents
  order.sort(proc(a, b: int): int = compareMoveOrder(itemsSnapshot, intentsSnapshot, a, b))

  var removed = newSeq[bool](sim.items.len)

  for itemIndex in order:
    if removed[itemIndex]:
      continue

    let
      item = sim.items[itemIndex]
      currentIndex = worldIndex(item.worldX, item.worldY)
      intent = intents[itemIndex]
    case intent.action
    of ItemDeliver:
      occupied[currentIndex] = false
      sim.awardDelivery(intent.ownerId, item.kind)
      removed[itemIndex] = true
    of ItemRemove:
      occupied[currentIndex] = false
      removed[itemIndex] = true
    of ItemBlocked:
      discard
    of ItemMove:
      let nextIndex = worldIndex(intent.nextX, intent.nextY)
      if occupied[nextIndex]:
        continue
      occupied[currentIndex] = false
      occupied[nextIndex] = true
      sim.items[itemIndex].worldX = intent.nextX
      sim.items[itemIndex].worldY = intent.nextY

  var survivors: seq[MovingItem] = @[]
  for i, item in sim.items:
    if not removed[i]:
      survivors.add(item)
  sim.items = survivors

proc spawnExtractorItems(sim: var SimServer) =
  var occupied = newSeq[bool](WorldWidthPixels * WorldHeightPixels)
  for item in sim.items:
    if inWorldBounds(item.worldX, item.worldY):
      occupied[worldIndex(item.worldX, item.worldY)] = true

  for ty in 0 ..< MapHeightTiles:
    for tx in 0 ..< MapWidthTiles:
      let index = mapIndex(tx, ty)
      let cell = sim.cells[index]
      if cell.building != BuildingExtractor or cell.ore == OreNone:
        continue
      let phase = (tx * 7 + ty * 11) mod ExtractSpawnInterval
      if (sim.tickCount + phase) mod ExtractSpawnInterval != 0:
        continue
      let spawn = extractorSpawnPixel(tx, ty, cell.direction)
      if occupied[worldIndex(spawn.x, spawn.y)]:
        continue
      sim.items.add MovingItem(
        worldX: spawn.x,
        worldY: spawn.y,
        kind: cell.ore
      )
      occupied[worldIndex(spawn.x, spawn.y)] = true

proc renderOreTile(sim: var SimServer, cell: Cell, screenX, screenY: int) =
  case cell.ore
  of OreNone:
    discard
  of OreSquare:
    sim.fb.blitScreenSprite(sim.art.squarePatch, screenX, screenY)
  of OreCircle:
    sim.fb.blitScreenSprite(sim.art.circlePatch, screenX, screenY)

proc renderBuilding(sim: var SimServer, player: Player, cell: Cell, screenX, screenY: int) =
  case cell.building
  of BuildingNone:
    discard
  of BuildingBelt:
    sim.fb.blitScreenSprite(sim.art.belt, screenX, screenY, cell.direction.toFacing())
  of BuildingExtractor:
    sim.fb.blitScreenSprite(sim.art.extractor, screenX, screenY, cell.direction.toFacing())
  of BuildingLaunchPad:
    let sprite =
      if cell.launchOwnerId == player.id: sim.art.launchPadOwn
      else: sim.art.launchPadEnemy
    sim.fb.blitScreenSprite(sprite, screenX, screenY)

proc renderItems(sim: var SimServer, cameraX, cameraY: int) =
  for item in sim.items:
    let sprite =
      case item.kind
      of OreSquare: sim.art.itemSquare
      of OreCircle: sim.art.itemCircle
      of OreNone: continue
    let
      screenX = item.worldX - cameraX - sprite.width div 2
      screenY = item.worldY - cameraY - sprite.height div 2
    sim.fb.blitScreenSprite(sprite, screenX, screenY)

proc renderCursors(sim: var SimServer, playerIndex: int, cameraX, cameraY: int) =
  for index, player in sim.players:
    let
      screenX = player.cursorX * WorldTilePixels - cameraX
      screenY = player.cursorY * WorldTilePixels - cameraY
      color = if index == playerIndex: CursorSelfColor else: player.color
    sim.fb.blitStencilSprite(sim.art.cursorOuterMask, screenX, screenY, color)
    if index == playerIndex and (sim.tickCount div 8) mod 2 == 0:
      sim.fb.blitStencilSprite(sim.art.cursorInnerMask, screenX, screenY, color)

proc renderScore(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let scoreText = $sim.players[playerIndex].score
  let width = max(1, scoreText.len) * 6 + 2
  sim.fb.drawRect(0, 0, width, 7, ToolbarColor)
  discard sim.fb.renderNumber(sim.digitSprites, sim.players[playerIndex].score, 1, 0)

proc drawToolIcon(sim: var SimServer, tool: BuildTool, x, y: int, player: Player) =
  case tool
  of ToolLaunchPad:
    sim.fb.blitScreenSprite(sim.art.toolLaunchPadIcon, x, y)
  of ToolExtractor:
    sim.fb.blitScreenSprite(sim.art.toolExtractorIcon, x, y, player.extractorRotation.toFacing())
  of ToolBelt:
    sim.fb.blitScreenSprite(sim.art.toolBeltIcon, x, y, player.beltRotation.toFacing())
  of ToolEraser:
    sim.fb.blitScreenSprite(sim.art.toolEraserIcon, x, y)

proc renderToolbar(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let player = sim.players[playerIndex]
  sim.fb.drawRect(0, ToolbarY, ScreenWidth, ToolbarHeight, ToolbarColor)

  for tool in BuildTool:
    let x = tool.ord * (ToolbarIconSize + ToolbarGap)
    let selected = tool == player.selectedTool
    sim.fb.blitStencilSprite(
      sim.art.toolbarSlotMask,
      x,
      ToolbarY,
      if selected: CursorSelfColor else: ToolbarDimColor
    )
    sim.drawToolIcon(tool, x, ToolbarY, player)

proc renderWorld(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  let
    player = sim.players[playerIndex]
    cameraX = player.cameraX
    cameraY = player.cameraY
    startTx = max(0, cameraX div WorldTilePixels)
    startTy = max(0, cameraY div WorldTilePixels)
    endTx = min(MapWidthTiles - 1, (cameraX + ScreenWidth - 1) div WorldTilePixels)
    endTy = min(MapHeightTiles - 1, (cameraY + ScreenHeight - 1) div WorldTilePixels)

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        screenX = tx * WorldTilePixels - cameraX
        screenY = ty * WorldTilePixels - cameraY
        cell = sim.cells[mapIndex(tx, ty)]
      sim.fb.blitScreenSprite(sim.art.ground, screenX, screenY)
      sim.renderOreTile(cell, screenX, screenY)
      if cell.building != BuildingExtractor:
        sim.renderBuilding(player, cell, screenX, screenY)

  sim.renderItems(cameraX, cameraY)

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        screenX = tx * WorldTilePixels - cameraX
        screenY = ty * WorldTilePixels - cameraY
        cell = sim.cells[mapIndex(tx, ty)]
      if cell.building == BuildingExtractor:
        sim.renderBuilding(player, cell, screenX, screenY)

  sim.renderCursors(playerIndex, cameraX, cameraY)

proc render(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(BackgroundColor)
  if playerIndex >= 0 and playerIndex < sim.players.len:
    sim.renderWorld(playerIndex)
    sim.renderScore(playerIndex)
    sim.renderToolbar(playerIndex)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc rewardScore(sim: SimServer, playerIndex: int): int =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return 0
  let player = sim.players[playerIndex]
  var buildProgress = 0
  for cell in sim.cells:
    case cell.building
    of BuildingLaunchPad:
      if cell.launchOwnerId == player.id:
        buildProgress += 4
    of BuildingExtractor:
      buildProgress += 3
    of BuildingBelt:
      inc buildProgress
    else:
      discard
  let itemProgress = min(12, sim.items.len)
  player.score * 32 + buildProgress + itemProgress

proc buildRewardPacket(sim: SimServer): string =
  for i, player in sim.players:
    result.add("reward ")
    result.add(player.name)
    result.add(" ")
    result.add($sim.rewardScore(i))
    result.add("\n")

proc step(sim: var SimServer, inputs: openArray[InputState]) =
  inc sim.tickCount

  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].comboTicks > 0:
      dec sim.players[playerIndex].comboTicks

  for playerIndex in 0 ..< sim.players.len:
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: InputState()
    sim.applyInput(playerIndex, input)

  sim.advanceItems()
  sim.spawnExtractorItems()

proc initSimServer(seed: int): SimServer =
  result.rng = initRand(seed)
  result.cells = newSeq[Cell](MapWidthTiles * MapHeightTiles)
  result.fb = initFramebuffer()
  loadPalette(PalettePath)
  result.art = loadFactorySprites()
  result.digitSprites = loadDigitSprites(NumbersPath)
  result.seedOre()

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
    sim.removePlayerLaunchPad(removedIndex)
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

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  seed = 0xB0F512
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
            inputs[playerIndex].b =
              (currentMask and ButtonB) != 0 and (previousMask and ButtonB) == 0
            inputs[playerIndex].select = false
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
    config = RunConfig(address: DefaultHost, port: DefaultPort, seed: 0xB0F512)
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

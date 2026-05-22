import mummy, pixie
import bitworld/cogame_runtime
import protocol except TileSize
import server except ScreenWidth, ScreenHeight
import sprite_render
import replays
import std/[json, locks, monotimes, os, parseopt, strutils, tables, times]

const
  FancyTileSize = 12
  WorldWidthTiles = 18
  WorldHeightTiles = 18
  WorldWidthPixels = WorldWidthTiles * FancyTileSize
  WorldHeightPixels = WorldHeightTiles * FancyTileSize
  MotionScale = 256
  Accel = 136
  FrictionNum = 200
  FrictionDen = 256
  MaxSpeed = 1280
  StopThreshold = 20
  MinPlayerSpawnSpacing = 24
  WashWorkNeeded = 28
  ChopWorkNeeded = 20
  MaxReturnCount = 9
  SaladScoreValue = 3
  TargetFps = 24
  WebSocketPath = "/player"
  CarryOffsetY = 0

type
  RunConfig = object
    address: string
    port: int
    seed: int
    maxTicks: int
    maxGames: int
    tokens: seq[string]
    resultsPath: string
    saveReplayPath: string
    configJson: string

  ItemKind = enum
    DirtyDishItem
    CleanDishItem
    TomatoItem
    LettuceItem
    ChoppedTomatoItem
    ChoppedLettuceItem
    TomatoPlateItem
    LettucePlateItem
    SaladItem

  SheetSpriteKind = enum
    SheetFloor
    SheetSelection
    SheetCounter
    SheetDirtyReturn
    SheetCleanRack
    SheetWashStation
    SheetFridge
    SheetCuttingStation
    SheetDirtyDish
    SheetCleanDish
    SheetTomato
    SheetLettuce
    SheetChoppedTomato
    SheetChoppedLettuce

  StationKind = enum
    CounterStation
    DirtyReturnStation
    WashStation
    DeliveryStation
    TomatoFridgeStation
    LettuceFridgeStation
    CuttingStation

  FloorItem = object
    tx: int
    ty: int
    kind: ItemKind

  Station = object
    kind: StationKind
    tx: int
    ty: int
    storedCount: int
    slotOccupied: bool
    slotItem: ItemKind
    workProgress: int

  Player = object
    name: string
    x: int
    y: int
    sprite: Sprite
    facing: Facing
    velX: int
    velY: int
    carryX: int
    carryY: int
    carrying: bool
    carriedItem: ItemKind
    score: int

  PlayerInput = object
    up: bool
    down: bool
    left: bool
    right: bool
    pickPressed: bool
    interactPressed: bool
    interactHeld: bool

  SimServer = object
    players: seq[Player]
    tiles: seq[bool]
    stations: seq[Station]
    floorItems: seq[FloorItem]
    sheetSprites: array[SheetSpriteKind, Sprite]
    playerSprites: seq[Sprite]
    rgbaSheetSprites: array[SheetSpriteKind, RgbaSprite]
    rgbaPlayerSprites: seq[RgbaSprite]

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerNames: Table[WebSocket, string]
    playerViewerStates: Table[WebSocket, SpriteViewerState]
    closedSockets: seq[WebSocket]
    rewardViewers: Table[WebSocket, bool]
    globalViewers: Table[WebSocket, SpriteViewerState]
    resetRequested: bool

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

proc tileIndex(tx, ty: int): int =
  ty * WorldWidthTiles + tx

proc dataDir(): string =
  getCurrentDir() / "data"

proc repoDir(): string =
  getCurrentDir() / ".."

proc clientDataDir(): string =
  repoDir() / "clients" / "data"

proc palettePath(): string =
  clientDataDir() / "pallete.png"

proc sheetPath(): string =
  dataDir() / "spritesheet.png"


proc inTileBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles

proc worldClampPixel(x, maxValue: int): int =
  x.clamp(0, maxValue)

proc distanceSquared(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc sheetCellSprite(sheet: Image, cellX, cellY: int): Sprite =
  spriteFromImage(
    sheet.subImage(cellX * FancyTileSize, cellY * FancyTileSize, FancyTileSize, FancyTileSize)
  )

proc defaultPlayerSprite(sim: SimServer): Sprite =
  sim.playerSprites[0]

proc playerSprite(sim: SimServer, playerIndex: int): Sprite =
  sim.playerSprites[playerIndex mod sim.playerSprites.len]

proc singleItemSprite(sim: SimServer, kind: ItemKind): Sprite =
  case kind
  of DirtyDishItem: sim.sheetSprites[SheetDirtyDish]
  of CleanDishItem: sim.sheetSprites[SheetCleanDish]
  of TomatoItem: sim.sheetSprites[SheetTomato]
  of LettuceItem: sim.sheetSprites[SheetLettuce]
  of ChoppedTomatoItem: sim.sheetSprites[SheetChoppedTomato]
  of ChoppedLettuceItem: sim.sheetSprites[SheetChoppedLettuce]
  else:
    raise newException(ValueError, "Composite item needs layered rendering: " & $kind)

proc isChoppable(item: ItemKind): bool =
  item in {TomatoItem, LettuceItem}

proc choppedVersion(item: ItemKind): ItemKind =
  case item
  of TomatoItem: ChoppedTomatoItem
  of LettuceItem: ChoppedLettuceItem
  else: item


proc stationBaseSprite(sim: SimServer, kind: StationKind): Sprite =
  case kind
  of CounterStation: sim.sheetSprites[SheetCounter]
  of DirtyReturnStation: sim.sheetSprites[SheetDirtyReturn]
  of WashStation: sim.sheetSprites[SheetWashStation]
  of DeliveryStation: sim.sheetSprites[SheetCleanRack]
  of TomatoFridgeStation, LettuceFridgeStation: sim.sheetSprites[SheetFridge]
  of CuttingStation: sim.sheetSprites[SheetCuttingStation]


proc stationIndexAt(sim: SimServer, tx, ty: int): int =
  for i, station in sim.stations:
    if station.tx == tx and station.ty == ty:
      return i
  -1

proc floorItemIndexAt(sim: SimServer, tx, ty: int): int =
  for i, item in sim.floorItems:
    if item.tx == tx and item.ty == ty:
      return i
  -1

proc addStation(
  sim: var SimServer,
  kind: StationKind,
  tx, ty: int,
  storedCount = 0
) =
  if not inTileBounds(tx, ty):
    return

  let index = sim.stationIndexAt(tx, ty)
  let station = Station(kind: kind, tx: tx, ty: ty, storedCount: storedCount)
  if index >= 0:
    sim.stations[index] = station
  else:
    sim.stations.add(station)
  sim.tiles[tileIndex(tx, ty)] = true

proc setStationItem(sim: var SimServer, tx, ty: int, item: ItemKind) =
  let index = sim.stationIndexAt(tx, ty)
  if index < 0:
    return
  sim.stations[index].slotOccupied = true
  sim.stations[index].slotItem = item
  sim.stations[index].workProgress = 0

proc initKitchen(sim: var SimServer) =
  for tx in 0 ..< WorldWidthTiles:
    sim.addStation(CounterStation, tx, 0)
    sim.addStation(CounterStation, tx, WorldHeightTiles - 1)

  for ty in 1 ..< WorldHeightTiles - 1:
    sim.addStation(CounterStation, 0, ty)
    sim.addStation(CounterStation, WorldWidthTiles - 1, ty)

  for tx in 3 .. 14:
    sim.addStation(CounterStation, tx, 3)

  for ty in 4 .. 5:
    sim.addStation(CounterStation, 3, ty)
    sim.addStation(CounterStation, 14, ty)

  sim.addStation(DirtyReturnStation, 5, 3, storedCount = 3)
  sim.addStation(TomatoFridgeStation, 7, 3)
  sim.addStation(LettuceFridgeStation, 9, 3)
  sim.addStation(CuttingStation, 11, 3)
  sim.addStation(DeliveryStation, 13, 3)
  sim.addStation(WashStation, 9, 9)
  sim.setStationItem(4, 3, CleanDishItem)
  sim.setStationItem(6, 3, CleanDishItem)

proc canOccupy(sim: SimServer, x, y, width, height: int): bool =
  if x < 0 or y < 0 or x + width > WorldWidthPixels or y + height > WorldHeightPixels:
    return false

  let
    startTx = x div FancyTileSize
    startTy = y div FancyTileSize
    endTx = (x + width - 1) div FancyTileSize
    endTy = (y + height - 1) div FancyTileSize

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      if sim.tiles[tileIndex(tx, ty)]:
        return false
  true

proc findPlayerSpawn(sim: SimServer): tuple[x, y: int] =
  let
    centerTx = WorldWidthTiles div 2
    centerTy = WorldHeightTiles - 4
    minSpacingSq = MinPlayerSpawnSpacing * MinPlayerSpawnSpacing
    playerSprite = sim.defaultPlayerSprite()

  for radius in 0 .. 6:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        let
          tx = centerTx + dx
          ty = centerTy + dy
        if not inTileBounds(tx, ty):
          continue
        let
          px = tx * FancyTileSize
          py = ty * FancyTileSize
        if not sim.canOccupy(px, py, playerSprite.width, playerSprite.height):
          continue
        var tooClose = false
        for player in sim.players:
          if distanceSquared(px, py, player.x, player.y) < minSpacingSq:
            tooClose = true
            break
        if not tooClose:
          return (px, py)

  (centerTx * FancyTileSize, centerTy * FancyTileSize)

proc addPlayer(sim: var SimServer, name: string): int =
  let
    spawn = sim.findPlayerSpawn()
    playerSprite = sim.playerSprite(sim.players.len)
  sim.players.add Player(
    name: name,
    x: spawn.x,
    y: spawn.y,
    sprite: playerSprite,
    facing: FaceDown
  )
  sim.players.high

proc initSimServer(seed: int): SimServer =
  discard seed
  let sheetImage = readImage(sheetPath())
  result.tiles = newSeq[bool](WorldWidthTiles * WorldHeightTiles)
  loadPalette(palettePath())
  result.sheetSprites[SheetFloor] = sheetImage.sheetCellSprite(0, 0)
  result.sheetSprites[SheetSelection] = sheetImage.sheetCellSprite(1, 0)
  result.sheetSprites[SheetCounter] = sheetImage.sheetCellSprite(2, 0)
  result.sheetSprites[SheetDirtyReturn] = sheetImage.sheetCellSprite(3, 0)
  result.sheetSprites[SheetCleanRack] = sheetImage.sheetCellSprite(4, 0)
  result.sheetSprites[SheetWashStation] = sheetImage.sheetCellSprite(5, 0)
  result.sheetSprites[SheetFridge] = sheetImage.sheetCellSprite(6, 0)
  result.sheetSprites[SheetCuttingStation] = sheetImage.sheetCellSprite(7, 0)
  result.sheetSprites[SheetDirtyDish] = sheetImage.sheetCellSprite(0, 2)
  result.sheetSprites[SheetCleanDish] = sheetImage.sheetCellSprite(1, 2)
  result.sheetSprites[SheetTomato] = sheetImage.sheetCellSprite(2, 2)
  result.sheetSprites[SheetLettuce] = sheetImage.sheetCellSprite(3, 2)
  result.sheetSprites[SheetChoppedTomato] = sheetImage.sheetCellSprite(4, 2)
  result.sheetSprites[SheetChoppedLettuce] = sheetImage.sheetCellSprite(5, 2)
  result.playerSprites = @[
    sheetImage.sheetCellSprite(0, 1),
    sheetImage.sheetCellSprite(1, 1),
    sheetImage.sheetCellSprite(2, 1),
    sheetImage.sheetCellSprite(3, 1)
  ]
  for kind in SheetSpriteKind:
    result.rgbaSheetSprites[kind] = paletteToRgba(
      Palette, result.sheetSprites[kind].pixels,
      result.sheetSprites[kind].width, result.sheetSprites[kind].height
    )
  for sprite in result.playerSprites:
    result.rgbaPlayerSprites.add(paletteToRgba(Palette, sprite.pixels, sprite.width, sprite.height))
  result.initKitchen()

proc applyMomentumAxis(
  sim: SimServer,
  player: var Player,
  carry: var int,
  velocity: int,
  horizontal: bool
) =
  carry += velocity
  while abs(carry) >= MotionScale:
    let step = (if carry < 0: -1 else: 1)
    if horizontal:
      if sim.canOccupy(player.x + step, player.y, player.sprite.width, player.sprite.height):
        player.x += step
        carry -= step * MotionScale
      else:
        carry = 0
        break
    else:
      if sim.canOccupy(player.x, player.y + step, player.sprite.width, player.sprite.height):
        player.y += step
        carry -= step * MotionScale
      else:
        carry = 0
        break

proc applyMovementInput(sim: var SimServer, playerIndex: int, input: PlayerInput) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  var inputX = 0
  var inputY = 0
  if input.left:
    dec inputX
  if input.right:
    inc inputX
  if input.up:
    dec inputY
  if input.down:
    inc inputY

  if inputX != 0:
    sim.players[playerIndex].velX =
      clamp(sim.players[playerIndex].velX + inputX * Accel, -MaxSpeed, MaxSpeed)
  else:
    sim.players[playerIndex].velX =
      (sim.players[playerIndex].velX * FrictionNum) div FrictionDen
    if abs(sim.players[playerIndex].velX) < StopThreshold:
      sim.players[playerIndex].velX = 0

  if inputY != 0:
    sim.players[playerIndex].velY =
      clamp(sim.players[playerIndex].velY + inputY * Accel, -MaxSpeed, MaxSpeed)
  else:
    sim.players[playerIndex].velY =
      (sim.players[playerIndex].velY * FrictionNum) div FrictionDen
    if abs(sim.players[playerIndex].velY) < StopThreshold:
      sim.players[playerIndex].velY = 0

  if inputX < 0:
    sim.players[playerIndex].facing = FaceLeft
  elif inputX > 0:
    sim.players[playerIndex].facing = FaceRight
  elif inputY < 0:
    sim.players[playerIndex].facing = FaceUp
  elif inputY > 0:
    sim.players[playerIndex].facing = FaceDown

  sim.applyMomentumAxis(
    sim.players[playerIndex],
    sim.players[playerIndex].carryX,
    sim.players[playerIndex].velX,
    true
  )
  sim.applyMomentumAxis(
    sim.players[playerIndex],
    sim.players[playerIndex].carryY,
    sim.players[playerIndex].velY,
    false
  )

proc interactionTile(player: Player): tuple[tx, ty: int] =
  var
    px = player.x + player.sprite.width div 2
    py = player.y + player.sprite.height div 2

  case player.facing
  of FaceUp:
    py = player.y - 1
  of FaceDown:
    py = player.y + player.sprite.height
  of FaceLeft:
    px = player.x - 1
  of FaceRight:
    px = player.x + player.sprite.width

  (px div FancyTileSize, py div FancyTileSize)

proc clearCarry(sim: var SimServer, playerIndex: int) =
  sim.players[playerIndex].carrying = false

proc giveCarry(sim: var SimServer, playerIndex: int, item: ItemKind) =
  sim.players[playerIndex].carrying = true
  sim.players[playerIndex].carriedItem = item

proc handlePickup(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].carrying:
    return

  let target = sim.players[playerIndex].interactionTile()
  if not inTileBounds(target.tx, target.ty):
    return

  let floorIndex = sim.floorItemIndexAt(target.tx, target.ty)
  if floorIndex >= 0:
    let item = sim.floorItems[floorIndex].kind
    sim.floorItems.delete(floorIndex)
    sim.giveCarry(playerIndex, item)
    return

  let stationIndex = sim.stationIndexAt(target.tx, target.ty)
  if stationIndex < 0:
    return

  case sim.stations[stationIndex].kind
  of DirtyReturnStation:
    if sim.stations[stationIndex].storedCount > 0:
      dec sim.stations[stationIndex].storedCount
      sim.giveCarry(playerIndex, DirtyDishItem)
  of WashStation, CuttingStation:
    if sim.stations[stationIndex].slotOccupied:
      let item = sim.stations[stationIndex].slotItem
      sim.stations[stationIndex].slotOccupied = false
      sim.stations[stationIndex].workProgress = 0
      sim.giveCarry(playerIndex, item)
  of CounterStation:
    if sim.stations[stationIndex].slotOccupied:
      let item = sim.stations[stationIndex].slotItem
      sim.stations[stationIndex].slotOccupied = false
      sim.giveCarry(playerIndex, item)
  of TomatoFridgeStation:
    sim.giveCarry(playerIndex, TomatoItem)
  of LettuceFridgeStation:
    sim.giveCarry(playerIndex, LettuceItem)
  of DeliveryStation:
    discard

proc tileCanHoldFloorItem(sim: SimServer, tx, ty: int): bool =
  inTileBounds(tx, ty) and
    not sim.tiles[tileIndex(tx, ty)] and
    sim.floorItemIndexAt(tx, ty) < 0

proc combinePlateItem(targetItem: var ItemKind, carriedItem: ItemKind): bool =
  if targetItem == CleanDishItem and carriedItem == ChoppedTomatoItem:
    targetItem = TomatoPlateItem
    return true
  if targetItem == CleanDishItem and carriedItem == ChoppedLettuceItem:
    targetItem = LettucePlateItem
    return true
  if targetItem == TomatoPlateItem and carriedItem == ChoppedLettuceItem:
    targetItem = SaladItem
    return true
  if targetItem == LettucePlateItem and carriedItem == ChoppedTomatoItem:
    targetItem = SaladItem
    return true
  false

proc firstStationIndex(sim: SimServer, kind: StationKind): int =
  for i, station in sim.stations:
    if station.kind == kind:
      return i
  -1

proc handleInteract(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if not sim.players[playerIndex].carrying:
    return

  let
    target = sim.players[playerIndex].interactionTile()
    item = sim.players[playerIndex].carriedItem
  if not inTileBounds(target.tx, target.ty):
    return

  let floorIndex = sim.floorItemIndexAt(target.tx, target.ty)
  if floorIndex >= 0:
    if combinePlateItem(sim.floorItems[floorIndex].kind, item):
      sim.clearCarry(playerIndex)
      return

  let stationIndex = sim.stationIndexAt(target.tx, target.ty)
  if stationIndex >= 0:
    case sim.stations[stationIndex].kind
    of DirtyReturnStation:
      if item == DirtyDishItem and sim.stations[stationIndex].storedCount < MaxReturnCount:
        inc sim.stations[stationIndex].storedCount
        sim.clearCarry(playerIndex)
        return
      if item == SaladItem and sim.stations[stationIndex].storedCount < MaxReturnCount:
        inc sim.stations[stationIndex].storedCount
        sim.players[playerIndex].score += SaladScoreValue
        sim.clearCarry(playerIndex)
        return
    of WashStation:
      if item == DirtyDishItem and not sim.stations[stationIndex].slotOccupied:
        sim.stations[stationIndex].slotOccupied = true
        sim.stations[stationIndex].slotItem = DirtyDishItem
        sim.stations[stationIndex].workProgress = 0
        sim.clearCarry(playerIndex)
        return
    of CuttingStation:
      if item.isChoppable() and not sim.stations[stationIndex].slotOccupied:
        sim.stations[stationIndex].slotOccupied = true
        sim.stations[stationIndex].slotItem = item
        sim.stations[stationIndex].workProgress = 0
        sim.clearCarry(playerIndex)
        return
    of DeliveryStation:
      if item == SaladItem:
        let dirtyReturnIndex = sim.firstStationIndex(DirtyReturnStation)
        if dirtyReturnIndex >= 0 and sim.stations[dirtyReturnIndex].storedCount < MaxReturnCount:
          inc sim.stations[dirtyReturnIndex].storedCount
        sim.players[playerIndex].score += SaladScoreValue
        sim.clearCarry(playerIndex)
        return
    of CounterStation:
      if sim.stations[stationIndex].slotOccupied:
        if combinePlateItem(sim.stations[stationIndex].slotItem, item):
          sim.clearCarry(playerIndex)
          return
      else:
        sim.stations[stationIndex].slotOccupied = true
        sim.stations[stationIndex].slotItem = item
        sim.stations[stationIndex].workProgress = 0
        sim.clearCarry(playerIndex)
        return
    of TomatoFridgeStation, LettuceFridgeStation:
      discard

  if sim.tileCanHoldFloorItem(target.tx, target.ty):
    sim.floorItems.add FloorItem(tx: target.tx, ty: target.ty, kind: item)
    sim.clearCarry(playerIndex)

proc countStationHelpers(sim: SimServer, station: Station, inputs: openArray[PlayerInput]): int =
  for playerIndex in 0 ..< min(sim.players.len, inputs.len):
    if not inputs[playerIndex].interactHeld or sim.players[playerIndex].carrying:
      continue
    let target = sim.players[playerIndex].interactionTile()
    if target.tx == station.tx and target.ty == station.ty:
      inc result

proc updateStations(sim: var SimServer, inputs: openArray[PlayerInput]) =
  for station in sim.stations.mitems:
    case station.kind
    of WashStation:
      if not station.slotOccupied or station.slotItem != DirtyDishItem:
        continue
      let helpers = sim.countStationHelpers(station, inputs)
      if helpers <= 0:
        continue
      station.workProgress += helpers
      if station.workProgress >= WashWorkNeeded:
        station.slotItem = CleanDishItem
        station.workProgress = 0
    of CuttingStation:
      if not station.slotOccupied or not station.slotItem.isChoppable():
        continue
      let helpers = sim.countStationHelpers(station, inputs)
      if helpers <= 0:
        continue
      station.workProgress += helpers
      if station.workProgress >= ChopWorkNeeded:
        station.slotItem = station.slotItem.choppedVersion()
        station.workProgress = 0
    else:
      discard


const
  MapLayerId = 0
  MapLayerType = 0
  ZoomableLayerFlag = 1
  TopLeftLayerId = 1
  TopLeftLayerType = 1
  UiLayerFlag = 2

  FloorSpriteId = 1
  StationSpriteBase = 10    # +SheetSpriteKind.ord
  ItemSpriteBase = 30       # +ItemKind.ord
  PlayerSpriteBase = 50     # +playerIndex
  SelectionSpriteId = 5

  TileObjectBase = 100      # +tileIndex (up to 324 tiles)
  ItemObjectBase = 500      # +stationIndex or floorItemIndex
  PlayerObjectBase = 900    # +playerIndex
  SelectionObjectId = 950
  HudObjectId = 960

proc buildSpriteFrame(
  sim: SimServer,
  playerIndex: int,
  state: SpriteViewerState,
  nextState: var SpriteViewerState,
  isGlobal: bool
): seq[uint8] =
  result = @[]
  nextState = state

  if not nextState.initialized:
    result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
    if isGlobal:
      result.addViewport(MapLayerId, WorldWidthPixels, WorldHeightPixels)
    else:
      result.addViewport(MapLayerId, SpriteScreenWidth, SpriteScreenHeight)
      result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
      result.addViewport(TopLeftLayerId, SpriteScreenWidth, 12)
    nextState.initialized = true

  var currentIds: seq[int] = @[]

  # Determine visible area
  var cameraX, cameraY, viewW, viewH: int
  if isGlobal:
    cameraX = 0
    cameraY = 0
    viewW = WorldWidthPixels
    viewH = WorldHeightPixels
  else:
    if playerIndex < 0 or playerIndex >= sim.players.len:
      for objectId in state.objectIds:
        if objectId notin currentIds:
          result.addDeleteObject(objectId)
      nextState.objectIds = currentIds
      return
    let player = sim.players[playerIndex]
    cameraX = worldClampPixel(
      player.x + player.sprite.width div 2 - SpriteScreenWidth div 2,
      WorldWidthPixels - SpriteScreenWidth
    )
    cameraY = worldClampPixel(
      player.y + player.sprite.height div 2 - SpriteScreenHeight div 2,
      WorldHeightPixels - SpriteScreenHeight
    )
    viewW = SpriteScreenWidth
    viewH = SpriteScreenHeight

  # Render kitchen tiles
  let
    startTx = max(0, cameraX div FancyTileSize)
    startTy = max(0, cameraY div FancyTileSize)
    endTx = min(WorldWidthTiles - 1, (cameraX + viewW - 1) div FancyTileSize)
    endTy = min(WorldHeightTiles - 1, (cameraY + viewH - 1) div FancyTileSize)

  # Floor sprite (send once via cache)
  result.addSpriteCached(nextState.spriteCache,
    FloorSpriteId, sim.rgbaSheetSprites[SheetFloor].width,
    sim.rgbaSheetSprites[SheetFloor].height,
    sim.rgbaSheetSprites[SheetFloor].pixels, "floor")

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        objId = TileObjectBase + ty * WorldWidthTiles + tx
        sx = tx * FancyTileSize - cameraX
        sy = ty * FancyTileSize - cameraY
      currentIds.add(objId)

      let stationIndex = sim.stationIndexAt(tx, ty)
      if stationIndex < 0:
        result.addObject(objId, sx, sy, 0, MapLayerId, FloorSpriteId)
      else:
        let station = sim.stations[stationIndex]
        let sprKind = case station.kind
          of CounterStation: SheetCounter
          of DirtyReturnStation: SheetDirtyReturn
          of WashStation: SheetWashStation
          of DeliveryStation: SheetCleanRack
          of TomatoFridgeStation, LettuceFridgeStation: SheetFridge
          of CuttingStation: SheetCuttingStation
        let sprId = StationSpriteBase + sprKind.ord
        result.addSpriteCached(nextState.spriteCache,
          sprId, sim.rgbaSheetSprites[sprKind].width,
          sim.rgbaSheetSprites[sprKind].height,
          sim.rgbaSheetSprites[sprKind].pixels, "station")
        result.addObject(objId, sx, sy, 0, MapLayerId, sprId)

        # Items on stations
        var itemToShow = ItemKind.low
        var showItem = false
        case station.kind
        of CounterStation:
          if station.slotOccupied:
            itemToShow = station.slotItem
            showItem = true
        of DirtyReturnStation:
          if station.storedCount > 0:
            itemToShow = DirtyDishItem
            showItem = true
        of TomatoFridgeStation:
          itemToShow = TomatoItem
          showItem = true
        of LettuceFridgeStation:
          itemToShow = LettuceItem
          showItem = true
        of WashStation:
          if station.slotOccupied:
            itemToShow = station.slotItem
            showItem = true
        of CuttingStation:
          if station.slotOccupied:
            itemToShow = station.slotItem
            showItem = true
        of DeliveryStation:
          discard

        if showItem:
          let itemSprId = ItemSpriteBase + itemToShow.ord
          let itemObjId = ItemObjectBase + stationIndex
          let itemSprKind = case itemToShow
            of DirtyDishItem: SheetDirtyDish
            of CleanDishItem: SheetCleanDish
            of TomatoItem: SheetTomato
            of LettuceItem: SheetLettuce
            of ChoppedTomatoItem: SheetChoppedTomato
            of ChoppedLettuceItem: SheetChoppedLettuce
            of TomatoPlateItem: SheetCleanDish
            of LettucePlateItem: SheetCleanDish
            of SaladItem: SheetCleanDish
          result.addSpriteCached(nextState.spriteCache,
            itemSprId, sim.rgbaSheetSprites[itemSprKind].width,
            sim.rgbaSheetSprites[itemSprKind].height,
            sim.rgbaSheetSprites[itemSprKind].pixels, "item")
          result.addObject(itemObjId, sx, sy, 1, MapLayerId, itemSprId)
          currentIds.add(itemObjId)

  # Players
  for pi, player in sim.players:
    let
      sx = player.x - cameraX
      sy = player.y - cameraY
    if sx > -FancyTileSize and sx < viewW and sy > -FancyTileSize and sy < viewH:
      let
        sprIdx = pi mod sim.rgbaPlayerSprites.len
        sprId = PlayerSpriteBase + sprIdx
        objId = PlayerObjectBase + pi
      result.addSpriteCached(nextState.spriteCache,
        sprId, sim.rgbaPlayerSprites[sprIdx].width,
        sim.rgbaPlayerSprites[sprIdx].height,
        sim.rgbaPlayerSprites[sprIdx].pixels, "player")
      result.addObject(objId, sx, sy, sy + 100, MapLayerId, sprId)
      currentIds.add(objId)

      if player.carrying:
        let
          carrySprKind = case player.carriedItem
            of DirtyDishItem: SheetDirtyDish
            of CleanDishItem: SheetCleanDish
            of TomatoItem: SheetTomato
            of LettuceItem: SheetLettuce
            of ChoppedTomatoItem: SheetChoppedTomato
            of ChoppedLettuceItem: SheetChoppedLettuce
            of TomatoPlateItem: SheetCleanDish
            of LettucePlateItem: SheetCleanDish
            of SaladItem: SheetCleanDish
          carrySprId = ItemSpriteBase + player.carriedItem.ord
          carryObjId = PlayerObjectBase + 100 + pi
        result.addSpriteCached(nextState.spriteCache,
          carrySprId, sim.rgbaSheetSprites[carrySprKind].width,
          sim.rgbaSheetSprites[carrySprKind].height,
          sim.rgbaSheetSprites[carrySprKind].pixels, "carry")
        result.addObject(carryObjId, sx, sy + CarryOffsetY, sy + 101, MapLayerId, carrySprId)
        currentIds.add(carryObjId)

  # Selection indicator (player view only)
  if not isGlobal and playerIndex >= 0 and playerIndex < sim.players.len:
    let target = sim.players[playerIndex].interactionTile()
    if inTileBounds(target.tx, target.ty):
      let
        sx = target.tx * FancyTileSize - cameraX
        sy = target.ty * FancyTileSize - cameraY
      result.addSpriteCached(nextState.spriteCache,
        SelectionSpriteId, sim.rgbaSheetSprites[SheetSelection].width,
        sim.rgbaSheetSprites[SheetSelection].height,
        sim.rgbaSheetSprites[SheetSelection].pixels, "selection")
      result.addObject(SelectionObjectId, sx, sy, -1, MapLayerId, SelectionSpriteId)
      currentIds.add(SelectionObjectId)

  # Delete objects that disappeared
  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

proc rewardScore(sim: SimServer, playerIndex: int): int =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return 0
  proc itemProgress(item: ItemKind): int =
    case item
    of DirtyDishItem, TomatoItem, LettuceItem:
      1
    of CleanDishItem, ChoppedTomatoItem, ChoppedLettuceItem:
      3
    of TomatoPlateItem, LettucePlateItem:
      5
    of SaladItem:
      8

  let player = sim.players[playerIndex]
  var progress = player.score * 32
  if player.carrying:
    progress += itemProgress(player.carriedItem)
  for floorItem in sim.floorItems:
    progress += max(1, itemProgress(floorItem.kind) div 2)
  for station in sim.stations:
    case station.kind
    of DirtyReturnStation:
      progress += station.storedCount
    of CounterStation, WashStation, CuttingStation:
      if station.slotOccupied:
        progress += itemProgress(station.slotItem)
      progress += station.workProgress div 4
    else:
      discard
  progress

proc buildRewardPacket(sim: SimServer): string =
  for i, player in sim.players:
    result.add("reward ")
    result.add(player.name)
    result.add(" ")
    result.add($sim.rewardScore(i))
    result.add("\n")

proc step(sim: var SimServer, inputs: openArray[PlayerInput]) =
  for playerIndex in 0 ..< sim.players.len:
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: PlayerInput()
    sim.applyMovementInput(playerIndex, input)

  for playerIndex in 0 ..< sim.players.len:
    if playerIndex < inputs.len and inputs[playerIndex].pickPressed:
      sim.handlePickup(playerIndex)

  for playerIndex in 0 ..< sim.players.len:
    if playerIndex < inputs.len and inputs[playerIndex].interactPressed:
      sim.handleInteract(playerIndex)

  sim.updateStations(inputs)

proc gameHash*(sim: SimServer): uint64 =
  var h = 0xcbf29ce484222325'u64
  for player in sim.players:
    h = h xor uint64(player.x)
    h = h * 0x100000001b3'u64
    h = h xor uint64(player.y)
    h = h * 0x100000001b3'u64
    h = h xor uint64(player.score)
    h = h * 0x100000001b3'u64
  h

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerNames = initTable[WebSocket, string]()
  appState.closedSockets = @[]
  appState.rewardViewers = initTable[WebSocket, bool]()
  appState.globalViewers = initTable[WebSocket, SpriteViewerState]()
  appState.playerViewerStates = initTable[WebSocket, SpriteViewerState]()
  appState.resetRequested = false

proc playerInputFromMasks(currentMask, previousMask: uint8): PlayerInput =
  let decoded = decodeInputMask(currentMask)
  result.up = decoded.up
  result.down = decoded.down
  result.left = decoded.left
  result.right = decoded.right
  result.pickPressed = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0
  result.interactPressed = (currentMask and ButtonB) != 0 and (previousMask and ButtonB) == 0
  result.interactHeld = (currentMask and ButtonB) != 0

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  if websocket in appState.playerViewerStates:
    appState.playerViewerStates.del(websocket)
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

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc serveClientHtml(request: Request, filename: string) =
  let path = repoDir() / "clients" / filename
  if not fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(404, headers, "Client not found: " & filename)
    return
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, readFile(path))

proc serveSnappyJs(request: Request) =
  let path = repoDir() / "clients" / "snappyjs.min.js"
  if not fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(404, headers, "snappyjs not found")
    return
  var headers: HttpHeaders
  headers["Content-Type"] = "application/javascript; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, readFile(path))

var serverTokens: seq[string]

proc httpHandler(request: Request) =
  if request.path == "/healthz" and request.httpMethod in ["GET", "HEAD"]:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    {.gcsafe.}:
      let token = request.queryParams.getOrDefault("token", "")
      var allowed = true
      if serverTokens.len > 0:
        allowed = token in serverTokens
      if not allowed:
        var headers: HttpHeaders
        headers["Content-Type"] = "text/plain"
        request.respond(403, headers, "invalid token")
        return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerNames[websocket] = request.playerIdentity()
  elif (request.path == "/global" or request.path == "/admin" or
      request.path == "/replay") and
      request.httpMethod == "GET" and request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initSpriteViewerState()
  elif request.path == "/reward" and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.rewardViewers[websocket] = true
  elif request.path.endsWith("snappyjs.min.js"):
    request.serveSnappyJs()
  elif request.path == "/" or request.path == WebSocketPath or
      request.path == "/global" or request.path == "/admin" or
      request.path == "/replay" or
      request.path == "/clients/global" or request.path == "/clients/player" or
      request.path == "/clients/admin" or request.path == "/clients/replay":
    request.serveClientHtml("global_client.html")
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
        if websocket in appState.playerNames:
          appState.playerIndices[websocket] = 0x7fffffff
          appState.inputMasks[websocket] = 0
          appState.lastAppliedMasks[websocket] = 0
          appState.playerViewerStates[websocket] = initSpriteViewerState()
  of MessageEvent:
    if message.kind != BinaryMessage or message.data.len < 2:
      return
    let header = message.data[0].uint8
    if header == 0x00 or header == 0x84:
      {.gcsafe.}:
        withLock appState.lock:
          let mask = message.data[1].uint8 and 0x7F
          if mask == 127'u8:
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

proc writeResults(sim: SimServer, path: string) =
  if path.len == 0:
    return
  var names = newJArray()
  var scores = newJArray()
  for player in sim.players:
    names.add(%player.name)
    scores.add(%player.score)
  let results = %*{"names": names, "scores": scores}
  let dir = path.parentDir()
  if dir.len > 0:
    createDir(dir)
  writeFile(path, $results & "\n")

proc writeReplay(path: string) =
  if path.len == 0:
    return
  let dir = path.parentDir()
  if dir.len > 0:
    createDir(dir)
  writeFile(path, "{}\n")

proc runServerLoop(
  host = DefaultHost,
  port = DefaultPort,
  seed = 0,
  maxTicks = 0,
  maxGames = 0,
  resultsPath = "",
  saveReplayPath = "",
  configJson = ""
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
    tickCount = 0
    gameCount = 0
    replayWriter = openReplayWriter(saveReplayPath, configJson)

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[PlayerInput]
      shouldReset = false
      rewardViewers: seq[WebSocket] = @[]
      globalViewers: seq[WebSocket] = @[]

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
              let playerIndex = sim.addPlayer(name)
              appState.playerIndices[websocket] = playerIndex
              if replayWriter.enabled:
                replayWriter.writeJoin(tickTime(tickCount), playerIndex, name, 0, "")

          inputs = newSeq[PlayerInput](sim.players.len)
          for websocket, playerIndex in appState.playerIndices.pairs:
            if playerIndex < 0 or playerIndex >= inputs.len:
              continue
            let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
            let previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
            inputs[playerIndex] = playerInputFromMasks(currentMask, previousMask)
            if replayWriter.enabled and currentMask != previousMask:
              while replayWriter.lastMasks.len <= playerIndex:
                replayWriter.lastMasks.add(0)
              if currentMask != replayWriter.lastMasks[playerIndex]:
                replayWriter.writeInput(ReplayInput(
                  time: tickTime(tickCount),
                  player: uint8(playerIndex),
                  keys: currentMask
                ))
                replayWriter.lastMasks[playerIndex] = currentMask
            appState.lastAppliedMasks[websocket] = currentMask
            sockets.add(websocket)
            playerIndices.add(playerIndex)

        for websocket in appState.rewardViewers.keys:
          rewardViewers.add(websocket)
        for websocket in appState.globalViewers.keys:
          globalViewers.add(websocket)

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
          for ws in appState.playerViewerStates.keys:
            appState.playerViewerStates[ws] = initSpriteViewerState()
          for ws in appState.globalViewers.keys:
            appState.globalViewers[ws] = initSpriteViewerState()
      runFrameLimiter(lastTick)
      continue

    sim.step(inputs)
    inc tickCount

    if replayWriter.enabled:
      replayWriter.writeHash(uint32(tickCount), sim.gameHash())

    if maxTicks > 0 and tickCount >= maxTicks:
      inc gameCount
      if maxGames > 0 and gameCount >= maxGames:
        sim.writeResults(resultsPath)
        closeReplayWriter(replayWriter)
        quit(0)
      tickCount = 0
      inc currentSeed
      sim = initSimServer(currentSeed)
      {.gcsafe.}:
        withLock appState.lock:
          for ws in appState.playerViewerStates.keys:
            appState.playerViewerStates[ws] = initSpriteViewerState()
          for ws in appState.globalViewers.keys:
            appState.globalViewers[ws] = initSpriteViewerState()

    for i in 0 ..< sockets.len:
      var viewState: SpriteViewerState
      {.gcsafe.}:
        withLock appState.lock:
          viewState = appState.playerViewerStates.getOrDefault(
            sockets[i], initSpriteViewerState())
      var nextState: SpriteViewerState
      let packet = sim.buildSpriteFrame(playerIndices[i], viewState, nextState, false)
      if packet.len > 0:
        try:
          sockets[i].send(blobFromBytes(packet), BinaryMessage)
          {.gcsafe.}:
            withLock appState.lock:
              appState.playerViewerStates[sockets[i]] = nextState
        except:
          {.gcsafe.}:
            withLock appState.lock:
              sim.removePlayer(sockets[i])

    for i in 0 ..< globalViewers.len:
      var viewState: SpriteViewerState
      {.gcsafe.}:
        withLock appState.lock:
          viewState = appState.globalViewers.getOrDefault(
            globalViewers[i], initSpriteViewerState())
      var nextState: SpriteViewerState
      let packet = sim.buildSpriteFrame(-1, viewState, nextState, true)
      if packet.len > 0:
        try:
          globalViewers[i].send(blobFromBytes(packet), BinaryMessage)
          {.gcsafe.}:
            withLock appState.lock:
              appState.globalViewers[globalViewers[i]] = nextState
        except:
          {.gcsafe.}:
            withLock appState.lock:
              appState.globalViewers.del(globalViewers[i])

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
  node.readConfigInt("maxTicks", config.maxTicks)
  node.readConfigInt("maxGames", config.maxGames)
  if node.hasKey("tokens") and node["tokens"].kind == JArray:
    config.tokens = @[]
    for item in node["tokens"]:
      config.tokens.add(item.getStr())

when isMainModule:
  var
    config = RunConfig(address: DefaultHost, port: DefaultPort, seed: 0)
    configJson = ""
    configPath = ""
    pendingOption = ""

  let envConfigPath = pathFromCogameEnv(CogameConfigUriEnv)
  if envConfigPath.len > 0:
    configPath = envConfigPath
  let envResultsPath = pathFromCogameEnv(CogameResultsUriEnv)
  if envResultsPath.len > 0:
    config.resultsPath = envResultsPath
  config.saveReplayPath = pathFromCogameEnv(CogameSaveReplayUriEnv)

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      pendingOption = ""
      case key
      of "address":
        if val.len > 0: config.address = val
        else: pendingOption = "address"
      of "port":
        if val.len > 0: config.port = parseInt(val)
        else: pendingOption = "port"
      of "config":
        configJson = val
      of "config-file":
        configPath = val
      of "save-scores", "results":
        config.resultsPath = val
      else: discard
    of cmdArgument:
      case pendingOption
      of "address": config.address = key
      of "port": config.port = parseInt(key)
      else: discard
      pendingOption = ""
    else: discard
  if configPath.len > 0:
    let configText = readFile(configPath)
    config.update(configText)
    config.configJson = configText
  if configJson.len > 0:
    config.update(configJson)
    config.configJson = configJson
  serverTokens = config.tokens
  runServerLoop(config.address, config.port, seed = config.seed,
    maxTicks = config.maxTicks, maxGames = config.maxGames,
    resultsPath = config.resultsPath,
    saveReplayPath = config.saveReplayPath,
    configJson = config.configJson)

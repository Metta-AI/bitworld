import mummy, pixie
import protocol except TileSize
import server
import std/[locks, monotimes, os, parseopt, strutils, tables, times]

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
  TargetFps = 24.0
  WebSocketPath = "/ws"
  FloorBackdropColor = 3'u8
  DishOffsetY = 2
  CarryOffsetY = -6
  WashBarOffsetX = 2
  WashBarOffsetY = 1
  WashBarWidth = 8

type
  ItemKind = enum
    DirtyDishItem
    CleanDishItem
    TomatoItem
    LettuceItem
    ChoppedTomatoItem
    ChoppedLettuceItem
    TomatoPlateItem
    SaladItem

  SheetSpriteKind = enum
    SheetFloor
    SheetFloorAccent
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
    digitSprites: array[10, Sprite]
    fb: Framebuffer

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

proc tileIndex(tx, ty: int): int =
  ty * WorldWidthTiles + tx

proc dataDir(): string =
  getAppDir() / "data"

proc repoDir(): string =
  getAppDir() / ".."

proc clientDataDir(): string =
  repoDir() / "client" / "data"

proc palettePath(): string =
  clientDataDir() / "pallete.png"

proc sheetPath(): string =
  dataDir() / "spritesheet.png"

proc numbersPath(): string =
  clientDataDir() / "numbers.png"

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

proc drawItem(
  sim: var SimServer,
  kind: ItemKind,
  worldX, worldY, cameraX, cameraY: int
) =
  case kind
  of TomatoPlateItem:
    sim.fb.blitSprite(sim.singleItemSprite(CleanDishItem), worldX, worldY, cameraX, cameraY)
    sim.fb.blitSprite(sim.singleItemSprite(ChoppedTomatoItem), worldX, worldY, cameraX, cameraY)
  of SaladItem:
    sim.fb.blitSprite(sim.singleItemSprite(CleanDishItem), worldX, worldY, cameraX, cameraY)
    sim.fb.blitSprite(sim.singleItemSprite(ChoppedTomatoItem), worldX, worldY, cameraX, cameraY)
    sim.fb.blitSprite(sim.singleItemSprite(ChoppedLettuceItem), worldX, worldY, cameraX, cameraY)
  else:
    sim.fb.blitSprite(sim.singleItemSprite(kind), worldX, worldY, cameraX, cameraY)

proc stationBaseSprite(sim: SimServer, kind: StationKind): Sprite =
  case kind
  of CounterStation: sim.sheetSprites[SheetCounter]
  of DirtyReturnStation: sim.sheetSprites[SheetDirtyReturn]
  of WashStation: sim.sheetSprites[SheetWashStation]
  of DeliveryStation: sim.sheetSprites[SheetCleanRack]
  of TomatoFridgeStation, LettuceFridgeStation: sim.sheetSprites[SheetFridge]
  of CuttingStation: sim.sheetSprites[SheetCuttingStation]

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

proc addPlayer(sim: var SimServer): int =
  let
    spawn = sim.findPlayerSpawn()
    playerSprite = sim.playerSprite(sim.players.len)
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    sprite: playerSprite,
    facing: FaceDown
  )
  sim.players.high

proc initSimServer(): SimServer =
  let sheetImage = readImage(sheetPath())
  result.fb = initFramebuffer()
  result.tiles = newSeq[bool](WorldWidthTiles * WorldHeightTiles)
  loadPalette(palettePath())
  result.sheetSprites[SheetFloor] = sheetImage.sheetCellSprite(0, 0)
  result.sheetSprites[SheetFloorAccent] = sheetImage.sheetCellSprite(1, 0)
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
  result.digitSprites = loadDigitSprites(numbersPath())
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
  if targetItem == TomatoPlateItem and carriedItem == ChoppedLettuceItem:
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

proc drawActionProgress(
  sim: var SimServer,
  progress, totalWork, worldX, worldY, cameraX, cameraY: int
) =
  let
    filledWidth = max(
      1,
      min(WashBarWidth, (progress * WashBarWidth + totalWork - 1) div totalWork)
    )
    screenX = worldX - cameraX + WashBarOffsetX
    screenY = worldY - cameraY + WashBarOffsetY
  for barX in 0 ..< WashBarWidth:
    sim.fb.putPixel(screenX + barX, screenY, 1)
    sim.fb.putPixel(screenX + barX, screenY + 1, 1)
  for barX in 0 ..< filledWidth:
    sim.fb.putPixel(screenX + barX, screenY, 10)
    sim.fb.putPixel(screenX + barX, screenY + 1, 14)

proc renderKitchen(sim: var SimServer, cameraX, cameraY: int) =
  let
    startTx = max(0, cameraX div FancyTileSize)
    startTy = max(0, cameraY div FancyTileSize)
    endTx = min(WorldWidthTiles - 1, (cameraX + ScreenWidth - 1) div FancyTileSize)
    endTy = min(WorldHeightTiles - 1, (cameraY + ScreenHeight - 1) div FancyTileSize)

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        worldX = tx * FancyTileSize
        worldY = ty * FancyTileSize
        floorSprite =
          if ((tx + ty) and 1) == 0: sim.sheetSprites[SheetFloorAccent]
          else: sim.sheetSprites[SheetFloor]
      sim.fb.blitSprite(floorSprite, worldX, worldY, cameraX, cameraY)

      let stationIndex = sim.stationIndexAt(tx, ty)
      if stationIndex < 0:
        continue

      let station = sim.stations[stationIndex]
      sim.fb.blitSprite(sim.stationBaseSprite(station.kind), worldX, worldY, cameraX, cameraY)
      case station.kind
      of CounterStation:
        if station.slotOccupied:
          sim.drawItem(station.slotItem, worldX, worldY + DishOffsetY, cameraX, cameraY)
      of DirtyReturnStation:
        if station.storedCount > 0:
          sim.drawItem(DirtyDishItem, worldX, worldY + DishOffsetY, cameraX, cameraY)
      of DeliveryStation:
        discard
      of TomatoFridgeStation:
        sim.drawItem(TomatoItem, worldX, worldY, cameraX, cameraY)
      of LettuceFridgeStation:
        sim.drawItem(LettuceItem, worldX, worldY, cameraX, cameraY)
      of WashStation:
        if station.slotOccupied:
          sim.drawItem(station.slotItem, worldX, worldY, cameraX, cameraY)
        if station.slotOccupied and station.slotItem == DirtyDishItem and station.workProgress > 0:
          sim.drawActionProgress(station.workProgress, WashWorkNeeded, worldX, worldY, cameraX, cameraY)
      of CuttingStation:
        if station.slotOccupied:
          sim.drawItem(station.slotItem, worldX, worldY, cameraX, cameraY)
        if station.slotOccupied and station.slotItem.isChoppable() and station.workProgress > 0:
          sim.drawActionProgress(station.workProgress, ChopWorkNeeded, worldX, worldY, cameraX, cameraY)

proc renderFloorItems(sim: var SimServer, cameraX, cameraY: int) =
  for item in sim.floorItems:
    sim.drawItem(
      item.kind,
      item.tx * FancyTileSize,
      item.ty * FancyTileSize,
      cameraX,
      cameraY
    )

proc renderPlayers(sim: var SimServer, cameraX, cameraY: int) =
  for player in sim.players:
    sim.fb.blitSprite(player.sprite, player.x, player.y, cameraX, cameraY)
    if player.carrying:
      sim.drawItem(
        player.carriedItem,
        player.x,
        player.y + CarryOffsetY,
        cameraX,
        cameraY
      )

proc renderHud(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  sim.fb.renderNumber(sim.digitSprites, sim.players[playerIndex].score, 0, 0)

proc buildFramePacket(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.fb.clearFrame(FloorBackdropColor)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return sim.fb.packed

  let player = sim.players[playerIndex]
  let
    cameraX = worldClampPixel(
      player.x + player.sprite.width div 2 - ScreenWidth div 2,
      WorldWidthPixels - ScreenWidth
    )
    cameraY = worldClampPixel(
      player.y + player.sprite.height div 2 - ScreenHeight div 2,
      WorldHeightPixels - ScreenHeight
    )

  sim.renderKitchen(cameraX, cameraY)
  sim.renderFloorItems(cameraX, cameraY)
  sim.renderPlayers(cameraX, cameraY)
  sim.renderHud(playerIndex)
  sim.fb.packFramebuffer()
  sim.fb.packed

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

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.closedSockets = @[]

proc playerInputFromMasks(currentMask, previousMask: uint8): PlayerInput =
  let decoded = decodeInputMask(currentMask)
  result.up = decoded.up
  result.down = decoded.down
  result.left = decoded.left
  result.right = decoded.right
  result.pickPressed = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0
  result.interactPressed = (currentMask and ButtonSelect) != 0 and (previousMask and ButtonSelect) == 0
  result.interactHeld = (currentMask and ButtonSelect) != 0

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
    request.respond(200, headers, "Fancy Cookout WebSocket server")

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

proc runServerLoop(host = DefaultHost, port = DefaultPort) =
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
      inputs: seq[PlayerInput]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] == 0x7fffffff:
            appState.playerIndices[websocket] = sim.addPlayer()

        inputs = newSeq[PlayerInput](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
          let previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = playerInputFromMasks(currentMask, previousMask)
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
    pendingOption = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      pendingOption = ""
      case key
      of "address":
        if val.len > 0:
          address = val
        else:
          pendingOption = "address"
      of "port":
        if val.len > 0:
          port = parseInt(val)
        else:
          pendingOption = "port"
      else: discard
    of cmdArgument:
      case pendingOption
      of "address":
        address = key
      of "port":
        port = parseInt(key)
      else:
        discard
      pendingOption = ""
    else: discard
  runServerLoop(address, port)

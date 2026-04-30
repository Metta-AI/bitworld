import mummy, pixie
import protocol except TileSize
import server
import std/[algorithm, json, locks, monotimes, os, parseopt, strutils, tables, times]

const
  MbTileSize = 8
  WorldWidthTiles = 32
  WorldHeightTiles = 32
  WorldWidthPixels = WorldWidthTiles * MbTileSize
  WorldHeightPixels = WorldHeightTiles * MbTileSize
  MotionScale = 256
  Accel = 136
  FrictionNum = 200
  FrictionDen = 256
  MaxSpeed = 1280
  StopThreshold = 20
  MinPlayerSpawnSpacing = 16
  GatherWorkNeeded = 48
  CraftWorkNeeded = 72
  NodeRespawnTicks = 240
  StartingGold = 100
  MaxSellSlots = 4
  TargetFps = 24
  WebSocketPath = "/player"
  FloorBackdropColor = 3'u8
  ProgressBarWidth = 6
  WoodBasePrice = 5
  StoneBasePrice = 5
  WoodGearBasePrice = 20
  StoneGearBasePrice = 20
  MaxSignalIcons = 4
  HubCenterTx = 16
  HubCenterTy = 16

type
  RunConfig = object
    address: string
    port: int
    seed: int

  Role = enum
    NoRole
    Gatherer
    Crafter

  ItemKind = enum
    WoodItem
    StoneItem
    WoodGear
    StoneGear

  PlayerState = enum
    Idle
    Gathering
    Crafting
    AtSellStall
    AtBuyStall

  TileKind = enum
    GrassTile
    PathTile
    WallTile

  WorldObjectKind = enum
    GatherNodeObj
    CraftStationObj
    SellStallObj
    BuyStallObj
    GathererStallObj
    CrafterStallObj

  WorldObject = object
    kind: WorldObjectKind
    tx, ty: int
    material: ItemKind
    depleted: bool
    respawnTimer: int

  MarketListing = object
    sellerIndex: int
    item: ItemKind
    quantity: int
    priceEach: int

  Inventory = object
    wood: int
    stone: int
    woodGear: int
    stoneGear: int

  Player = object
    name: string
    x, y: int
    sprite: Sprite
    facing: Facing
    velX, velY: int
    carryX, carryY: int
    role: Role
    gathererLevel: int
    crafterLevel: int
    gold: int
    inv: Inventory
    state: PlayerState
    actionProgress: int
    actionTargetIndex: int
    sellItemCursor: int
    sellPrice: int
    buyItemCursor: int
    buyQuantity: int
    listings: seq[MarketListing]
    signalIcon: int

  PlayerInput = object
    up, down, left, right: bool
    aPressed, aHeld: bool
    bPressed: bool
    selectPressed: bool

  SimServer = object
    players: seq[Player]
    tileKinds: seq[TileKind]
    tiles: seq[bool]
    objects: seq[WorldObject]
    npcListings: seq[MarketListing]
    playerSprites: seq[Sprite]
    digitSprites: array[10, Sprite]
    letterSprites: seq[Sprite]
    fb: Framebuffer
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

proc tileIndex(tx, ty: int): int =
  ty * WorldWidthTiles + tx

proc repoDir(): string =
  getCurrentDir() / ".."

proc clientDataDir(): string =
  repoDir() / "clients" / "data"

proc palettePath(): string =
  clientDataDir() / "pallete.png"

proc numbersPath(): string =
  clientDataDir() / "numbers.png"

proc lettersPath(): string =
  clientDataDir() / "letters.png"

proc inTileBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles

proc worldClampPixel(x, maxValue: int): int =
  x.clamp(0, maxValue)

proc makeOutlinedSprite(fill, outline: uint8, size: int): Sprite =
  result.width = size
  result.height = size
  result.pixels = newSeq[uint8](size * size)
  for y in 0 ..< size:
    for x in 0 ..< size:
      if x == 0 or y == 0 or x == size - 1 or y == size - 1:
        result.pixels[y * size + x] = outline
      else:
        result.pixels[y * size + x] = fill

proc makePlayerSprite(): Sprite =
  result.width = 7
  result.height = 7
  result.pixels = newSeq[uint8](7 * 7)
  for y in 0 ..< 7:
    for x in 0 ..< 7:
      if y == 0 and x >= 2 and x <= 4:
        result.pixels[y * 7 + x] = 7
      elif y >= 1 and y <= 2 and x >= 1 and x <= 5:
        result.pixels[y * 7 + x] = 7
      elif y >= 3 and y <= 4 and x >= 2 and x <= 4:
        result.pixels[y * 7 + x] = 7
      elif y >= 5 and y <= 6 and (x == 1 or x == 2 or x == 4 or x == 5):
        result.pixels[y * 7 + x] = 7
      else:
        result.pixels[y * 7 + x] = TransparentColorIndex

proc itemBasePrice(item: ItemKind): int =
  case item
  of WoodItem: WoodBasePrice
  of StoneItem: StoneBasePrice
  of WoodGear: WoodGearBasePrice
  of StoneGear: StoneGearBasePrice

proc itemCount(inv: Inventory, item: ItemKind): int =
  case item
  of WoodItem: inv.wood
  of StoneItem: inv.stone
  of WoodGear: inv.woodGear
  of StoneGear: inv.stoneGear

proc addItem(inv: var Inventory, item: ItemKind, count: int = 1) =
  case item
  of WoodItem: inv.wood += count
  of StoneItem: inv.stone += count
  of WoodGear: inv.woodGear += count
  of StoneGear: inv.stoneGear += count

proc removeItem(inv: var Inventory, item: ItemKind, count: int = 1): bool =
  let current = inv.itemCount(item)
  if current < count:
    return false
  case item
  of WoodItem: inv.wood -= count
  of StoneItem: inv.stone -= count
  of WoodGear: inv.woodGear -= count
  of StoneGear: inv.stoneGear -= count
  true

proc inventoryValue(inv: Inventory): int =
  inv.wood * itemBasePrice(WoodItem) +
  inv.stone * itemBasePrice(StoneItem) +
  inv.woodGear * itemBasePrice(WoodGear) +
  inv.stoneGear * itemBasePrice(StoneGear)

proc sellableItems(inv: Inventory): seq[ItemKind] =
  if inv.wood > 0: result.add WoodItem
  if inv.stone > 0: result.add StoneItem
  if inv.woodGear > 0: result.add WoodGear
  if inv.stoneGear > 0: result.add StoneGear

proc craftableItem(inv: Inventory): ItemKind =
  if inv.wood >= 3:
    return WoodGear
  if inv.stone >= 3:
    return StoneGear
  WoodGear

proc hasCraftMaterials(inv: Inventory): bool =
  inv.wood >= 3 or inv.stone >= 3

proc craftMaterialItem(gear: ItemKind): ItemKind =
  case gear
  of WoodGear: WoodItem
  of StoneGear: StoneItem
  else: WoodItem

proc objectIndexAt(sim: SimServer, tx, ty: int): int =
  for i, obj in sim.objects:
    if obj.tx == tx and obj.ty == ty:
      return i
  -1

proc addObject(sim: var SimServer, kind: WorldObjectKind, tx, ty: int, material = WoodItem) =
  if not inTileBounds(tx, ty):
    return
  sim.objects.add WorldObject(kind: kind, tx: tx, ty: ty, material: material)
  if kind != GatherNodeObj:
    sim.tiles[tileIndex(tx, ty)] = true

proc initMap(sim: var SimServer) =
  for tx in 0 ..< WorldWidthTiles:
    sim.tiles[tileIndex(tx, 0)] = true
    sim.tiles[tileIndex(tx, WorldHeightTiles - 1)] = true
    sim.tileKinds[tileIndex(tx, 0)] = WallTile
    sim.tileKinds[tileIndex(tx, WorldHeightTiles - 1)] = WallTile
  for ty in 1 ..< WorldHeightTiles - 1:
    sim.tiles[tileIndex(0, ty)] = true
    sim.tiles[tileIndex(WorldWidthTiles - 1, ty)] = true
    sim.tileKinds[tileIndex(0, ty)] = WallTile
    sim.tileKinds[tileIndex(WorldWidthTiles - 1, ty)] = WallTile

  for ty in HubCenterTy - 3 .. HubCenterTy + 3:
    for tx in HubCenterTx - 4 .. HubCenterTx + 4:
      if inTileBounds(tx, ty):
        sim.tileKinds[tileIndex(tx, ty)] = PathTile

  sim.addObject(GathererStallObj, HubCenterTx - 3, HubCenterTy - 2)
  sim.addObject(CrafterStallObj, HubCenterTx + 3, HubCenterTy - 2)

  sim.addObject(CraftStationObj, HubCenterTx - 1, HubCenterTy + 2)
  sim.addObject(CraftStationObj, HubCenterTx + 1, HubCenterTy + 2)

  sim.addObject(SellStallObj, HubCenterTx - 3, HubCenterTy)
  sim.addObject(SellStallObj, HubCenterTx - 3, HubCenterTy + 1)

  sim.addObject(BuyStallObj, HubCenterTx + 3, HubCenterTy)
  sim.addObject(BuyStallObj, HubCenterTx + 3, HubCenterTy + 1)

  let woodPositions = [
    (HubCenterTx - 6, HubCenterTy - 6),
    (HubCenterTx + 6, HubCenterTy - 6),
    (HubCenterTx - 7, HubCenterTy),
    (HubCenterTx + 7, HubCenterTy),
    (HubCenterTx - 6, HubCenterTy + 6),
    (HubCenterTx + 6, HubCenterTy + 6),
    (HubCenterTx, HubCenterTy - 7),
    (HubCenterTx, HubCenterTy + 7),
  ]
  for pos in woodPositions:
    sim.addObject(GatherNodeObj, pos[0], pos[1], WoodItem)

  let stonePositions = [
    (HubCenterTx - 11, HubCenterTy - 11),
    (HubCenterTx + 11, HubCenterTy - 11),
    (HubCenterTx - 12, HubCenterTy),
    (HubCenterTx + 12, HubCenterTy),
    (HubCenterTx - 11, HubCenterTy + 11),
    (HubCenterTx + 11, HubCenterTy + 11),
    (HubCenterTx, HubCenterTy - 12),
    (HubCenterTx, HubCenterTy + 12),
  ]
  for pos in stonePositions:
    sim.addObject(GatherNodeObj, pos[0], pos[1], StoneItem)

proc initNpcListings(sim: var SimServer) =
  for _ in 0 ..< 4:
    sim.npcListings.add MarketListing(sellerIndex: -1, item: WoodItem, quantity: 1, priceEach: WoodBasePrice)
  for _ in 0 ..< 4:
    sim.npcListings.add MarketListing(sellerIndex: -1, item: StoneItem, quantity: 1, priceEach: StoneBasePrice)
  for _ in 0 ..< 2:
    sim.npcListings.add MarketListing(sellerIndex: -1, item: WoodGear, quantity: 1, priceEach: WoodGearBasePrice)
  for _ in 0 ..< 2:
    sim.npcListings.add MarketListing(sellerIndex: -1, item: StoneGear, quantity: 1, priceEach: StoneGearBasePrice)

proc canOccupy(sim: SimServer, x, y, width, height: int): bool =
  if x < 0 or y < 0 or x + width > WorldWidthPixels or y + height > WorldHeightPixels:
    return false
  let
    startTx = x div MbTileSize
    startTy = y div MbTileSize
    endTx = (x + width - 1) div MbTileSize
    endTy = (y + height - 1) div MbTileSize
  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      if inTileBounds(tx, ty) and sim.tiles[tileIndex(tx, ty)]:
        return false
  true

proc findPlayerSpawn(sim: SimServer): tuple[x, y: int] =
  let
    centerX = HubCenterTx * MbTileSize
    centerY = HubCenterTy * MbTileSize
    minSpacingSq = MinPlayerSpawnSpacing * MinPlayerSpawnSpacing

  for radius in 0 .. 8:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        let
          px = centerX + dx * MbTileSize
          py = centerY + dy * MbTileSize
        if not sim.canOccupy(px, py, 7, 7):
          continue
        var tooClose = false
        for player in sim.players:
          let ddx = px - player.x
          let ddy = py - player.y
          if ddx * ddx + ddy * ddy < minSpacingSq:
            tooClose = true
            break
        if not tooClose:
          return (px, py)
  (centerX, centerY)

proc addPlayer(sim: var SimServer, name: string): int =
  let spawn = sim.findPlayerSpawn()
  sim.players.add Player(
    name: name,
    x: spawn.x,
    y: spawn.y,
    sprite: sim.playerSprites[sim.players.len mod sim.playerSprites.len],
    facing: FaceDown,
    gold: StartingGold,
    sellPrice: 10,
    buyQuantity: 1,
    signalIcon: -1
  )
  sim.players.high

proc initSimServer(seed: int): SimServer =
  discard seed
  result.fb = initFramebuffer()
  result.tiles = newSeq[bool](WorldWidthTiles * WorldHeightTiles)
  result.tileKinds = newSeq[TileKind](WorldWidthTiles * WorldHeightTiles)
  loadPalette(palettePath())

  result.playerSprites = @[
    makePlayerSprite(),
    makePlayerSprite(),
    makePlayerSprite(),
    makePlayerSprite()
  ]
  result.digitSprites = loadDigitSprites(numbersPath())
  if fileExists(lettersPath()):
    result.letterSprites = loadLetterSprites(lettersPath())

  result.initMap()
  result.initNpcListings()

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
  if sim.players[playerIndex].state != Idle:
    return

  var inputX = 0
  var inputY = 0
  if input.left: dec inputX
  if input.right: inc inputX
  if input.up: dec inputY
  if input.down: inc inputY

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

  if inputX < 0: sim.players[playerIndex].facing = FaceLeft
  elif inputX > 0: sim.players[playerIndex].facing = FaceRight
  elif inputY < 0: sim.players[playerIndex].facing = FaceUp
  elif inputY > 0: sim.players[playerIndex].facing = FaceDown

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
  of FaceUp: py = player.y - 1
  of FaceDown: py = player.y + player.sprite.height
  of FaceLeft: px = player.x - 1
  of FaceRight: px = player.x + player.sprite.width
  (px div MbTileSize, py div MbTileSize)

proc cancelAction(sim: var SimServer, playerIndex: int) =
  sim.players[playerIndex].state = Idle
  sim.players[playerIndex].actionProgress = 0
  sim.players[playerIndex].actionTargetIndex = -1
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0

proc handleAction(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let player = sim.players[playerIndex]

  if player.state in {AtSellStall, AtBuyStall}:
    case player.state
    of AtSellStall:
      let sellable = player.inv.sellableItems()
      if sellable.len > 0 and player.listings.len < MaxSellSlots:
        let cursor = player.sellItemCursor mod max(1, sellable.len)
        let item = sellable[cursor]
        if sim.players[playerIndex].inv.removeItem(item):
          sim.players[playerIndex].listings.add MarketListing(
            sellerIndex: playerIndex,
            item: item,
            quantity: 1,
            priceEach: player.sellPrice
          )
    of AtBuyStall:
      let wantedItem = ItemKind(player.buyItemCursor mod (ord(high(ItemKind)) + 1))
      var bought = 0
      var remaining = player.buyQuantity

      var allListings: seq[tuple[listing: ptr MarketListing, isNpc: bool, index: int]]
      for i in 0 ..< sim.npcListings.len:
        if sim.npcListings[i].item == wantedItem and sim.npcListings[i].quantity > 0:
          allListings.add (listing: addr sim.npcListings[i], isNpc: true, index: i)
      for pi in 0 ..< sim.players.len:
        for li in 0 ..< sim.players[pi].listings.len:
          if sim.players[pi].listings[li].item == wantedItem and
             sim.players[pi].listings[li].quantity > 0:
            allListings.add (listing: addr sim.players[pi].listings[li], isNpc: false, index: li)

      allListings.sort(proc(a, b: tuple[listing: ptr MarketListing, isNpc: bool, index: int]): int =
        cmp(a.listing.priceEach, b.listing.priceEach)
      )

      for entry in allListings:
        if remaining <= 0 or sim.players[playerIndex].gold < entry.listing.priceEach:
          break
        let canBuy = min(remaining, entry.listing.quantity)
        let cost = canBuy * entry.listing.priceEach
        if sim.players[playerIndex].gold < cost:
          continue
        sim.players[playerIndex].gold -= cost
        sim.players[playerIndex].inv.addItem(wantedItem, canBuy)
        entry.listing.quantity -= canBuy
        if not entry.isNpc and entry.listing.sellerIndex >= 0 and
           entry.listing.sellerIndex < sim.players.len:
          sim.players[entry.listing.sellerIndex].gold += cost
        remaining -= canBuy
        bought += canBuy

      for pi in 0 ..< sim.players.len:
        var i = sim.players[pi].listings.high
        while i >= 0:
          if sim.players[pi].listings[i].quantity <= 0:
            sim.players[pi].listings.delete(i)
          dec i
      var i = sim.npcListings.high
      while i >= 0:
        if sim.npcListings[i].quantity <= 0:
          sim.npcListings.delete(i)
        dec i

    else: discard
    return

  if player.state != Idle:
    return

  let target = player.interactionTile()
  if not inTileBounds(target.tx, target.ty):
    return

  let objIndex = sim.objectIndexAt(target.tx, target.ty)
  if objIndex < 0:
    return

  let obj = sim.objects[objIndex]
  case obj.kind
  of GathererStallObj:
    sim.players[playerIndex].role = Gatherer
  of CrafterStallObj:
    sim.players[playerIndex].role = Crafter
  of GatherNodeObj:
    if player.role == Gatherer and not obj.depleted:
      sim.players[playerIndex].state = Gathering
      sim.players[playerIndex].actionProgress = 0
      sim.players[playerIndex].actionTargetIndex = objIndex
  of CraftStationObj:
    if player.role == Crafter and player.inv.hasCraftMaterials():
      sim.players[playerIndex].state = Crafting
      sim.players[playerIndex].actionProgress = 0
      sim.players[playerIndex].actionTargetIndex = objIndex
  of SellStallObj:
    sim.players[playerIndex].state = AtSellStall
    sim.players[playerIndex].sellItemCursor = 0
  of BuyStallObj:
    sim.players[playerIndex].state = AtBuyStall
    sim.players[playerIndex].buyItemCursor = 0
    sim.players[playerIndex].buyQuantity = 1

proc handleCancel(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].state != Idle:
    sim.cancelAction(playerIndex)

proc updateActionProgress(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let state = sim.players[playerIndex].state
  if state == Gathering:
    inc sim.players[playerIndex].actionProgress
    if sim.players[playerIndex].actionProgress >= GatherWorkNeeded:
      let objIdx = sim.players[playerIndex].actionTargetIndex
      if objIdx >= 0 and objIdx < sim.objects.len:
        let material = sim.objects[objIdx].material
        sim.players[playerIndex].inv.addItem(material)
        sim.objects[objIdx].depleted = true
        sim.objects[objIdx].respawnTimer = NodeRespawnTicks
        inc sim.players[playerIndex].gathererLevel
      sim.cancelAction(playerIndex)
  elif state == Crafting:
    inc sim.players[playerIndex].actionProgress
    if sim.players[playerIndex].actionProgress >= CraftWorkNeeded:
      let gear = sim.players[playerIndex].inv.craftableItem()
      let material = craftMaterialItem(gear)
      if sim.players[playerIndex].inv.removeItem(material, 3):
        sim.players[playerIndex].inv.addItem(gear)
        inc sim.players[playerIndex].crafterLevel
      sim.cancelAction(playerIndex)

proc handleStallInput(sim: var SimServer, playerIndex: int, input: PlayerInput) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  case sim.players[playerIndex].state
  of AtSellStall:
    if input.up:
      sim.players[playerIndex].sellPrice = min(999, sim.players[playerIndex].sellPrice + 1)
    if input.down:
      sim.players[playerIndex].sellPrice = max(1, sim.players[playerIndex].sellPrice - 1)
    if input.left:
      dec sim.players[playerIndex].sellItemCursor
      if sim.players[playerIndex].sellItemCursor < 0:
        sim.players[playerIndex].sellItemCursor = max(0, sim.players[playerIndex].inv.sellableItems().len - 1)
    if input.right:
      let sellable = sim.players[playerIndex].inv.sellableItems()
      if sellable.len > 0:
        sim.players[playerIndex].sellItemCursor = (sim.players[playerIndex].sellItemCursor + 1) mod sellable.len
  of AtBuyStall:
    if input.up:
      sim.players[playerIndex].buyQuantity = min(99, sim.players[playerIndex].buyQuantity + 1)
    if input.down:
      sim.players[playerIndex].buyQuantity = max(1, sim.players[playerIndex].buyQuantity - 1)
    if input.left:
      sim.players[playerIndex].buyItemCursor =
        (sim.players[playerIndex].buyItemCursor + ord(high(ItemKind))) mod (ord(high(ItemKind)) + 1)
    if input.right:
      sim.players[playerIndex].buyItemCursor =
        (sim.players[playerIndex].buyItemCursor + 1) mod (ord(high(ItemKind)) + 1)
  else: discard

proc cycleSignal(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  inc sim.players[playerIndex].signalIcon
  if sim.players[playerIndex].signalIcon >= MaxSignalIcons:
    sim.players[playerIndex].signalIcon = -1

proc updateNodes(sim: var SimServer) =
  for obj in sim.objects.mitems:
    if obj.kind == GatherNodeObj and obj.depleted:
      dec obj.respawnTimer
      if obj.respawnTimer <= 0:
        obj.depleted = false

proc step(sim: var SimServer, inputs: openArray[PlayerInput]) =
  for playerIndex in 0 ..< sim.players.len:
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: PlayerInput()
    sim.applyMovementInput(playerIndex, input)

  for playerIndex in 0 ..< sim.players.len:
    if playerIndex < inputs.len and inputs[playerIndex].aPressed:
      sim.handleAction(playerIndex)

  for playerIndex in 0 ..< sim.players.len:
    if playerIndex < inputs.len and inputs[playerIndex].bPressed:
      sim.handleCancel(playerIndex)

  for playerIndex in 0 ..< sim.players.len:
    if playerIndex < inputs.len and inputs[playerIndex].selectPressed:
      sim.cycleSignal(playerIndex)

  for playerIndex in 0 ..< sim.players.len:
    if playerIndex < inputs.len and inputs[playerIndex].aHeld:
      sim.updateActionProgress(playerIndex)
    elif sim.players[playerIndex].state in {Gathering, Crafting}:
      sim.cancelAction(playerIndex)

  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].state in {AtSellStall, AtBuyStall}:
      if playerIndex < inputs.len:
        sim.handleStallInput(playerIndex, inputs[playerIndex])

  sim.updateNodes()
  inc sim.tickCount

proc objectSprite(kind: WorldObjectKind, depleted: bool, material: ItemKind): Sprite =
  case kind
  of GatherNodeObj:
    if depleted:
      makeOutlinedSprite(5, 1, MbTileSize)
    elif material == WoodItem:
      makeOutlinedSprite(11, 4, MbTileSize)
    else:
      makeOutlinedSprite(6, 5, MbTileSize)
  of CraftStationObj:
    makeOutlinedSprite(6, 0, MbTileSize)
  of SellStallObj:
    makeOutlinedSprite(9, 4, MbTileSize)
  of BuyStallObj:
    makeOutlinedSprite(12, 4, MbTileSize)
  of GathererStallObj:
    makeOutlinedSprite(11, 3, MbTileSize)
  of CrafterStallObj:
    makeOutlinedSprite(8, 2, MbTileSize)

proc roleTint(role: Role): uint8 =
  case role
  of NoRole: 6'u8
  of Gatherer: 11'u8
  of Crafter: 12'u8

proc signalColor(icon: int): uint8 =
  case icon
  of 0: 4'u8
  of 1: 6'u8
  of 2: 9'u8
  of 3: 14'u8
  else: 7'u8

proc itemShortName(item: ItemKind): string =
  case item
  of WoodItem: "WOOD"
  of StoneItem: "STONE"
  of WoodGear: "WGEAR"
  of StoneGear: "SGEAR"

proc roleShortName(role: Role): string =
  case role
  of NoRole: "NONE"
  of Gatherer: "GATH"
  of Crafter: "CRAF"

proc renderTerrain(sim: var SimServer, cameraX, cameraY: int) =
  let
    startTx = max(0, cameraX div MbTileSize)
    startTy = max(0, cameraY div MbTileSize)
    endTx = min(WorldWidthTiles - 1, (cameraX + ScreenWidth - 1) div MbTileSize)
    endTy = min(WorldHeightTiles - 1, (cameraY + ScreenHeight - 1) div MbTileSize)

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        worldX = tx * MbTileSize
        worldY = ty * MbTileSize
        screenX = worldX - cameraX
        screenY = worldY - cameraY
        tileKind = sim.tileKinds[tileIndex(tx, ty)]
      let color =
        case tileKind
        of GrassTile: 3'u8
        of PathTile: 5'u8
        of WallTile: 1'u8
      for py in 0 ..< MbTileSize:
        for px in 0 ..< MbTileSize:
          sim.fb.putPixel(screenX + px, screenY + py, color)

proc renderObjects(sim: var SimServer, cameraX, cameraY: int) =
  for obj in sim.objects:
    let sprite = objectSprite(obj.kind, obj.depleted, obj.material)
    sim.fb.blitSprite(
      sprite,
      obj.tx * MbTileSize,
      obj.ty * MbTileSize,
      cameraX,
      cameraY
    )

proc renderSelection(sim: var SimServer, playerIndex, cameraX, cameraY: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let target = sim.players[playerIndex].interactionTile()
  if not inTileBounds(target.tx, target.ty):
    return
  let
    worldX = target.tx * MbTileSize
    worldY = target.ty * MbTileSize
    screenX = worldX - cameraX
    screenY = worldY - cameraY
  for px in 0 ..< MbTileSize:
    sim.fb.putPixel(screenX + px, screenY, 10)
    sim.fb.putPixel(screenX + px, screenY + MbTileSize - 1, 10)
  for py in 1 ..< MbTileSize - 1:
    sim.fb.putPixel(screenX, screenY + py, 10)
    sim.fb.putPixel(screenX + MbTileSize - 1, screenY + py, 10)

proc renderPlayers(sim: var SimServer, cameraX, cameraY: int) =
  for player in sim.players:
    let tint = roleTint(player.role)
    sim.fb.blitSpriteTinted(player.sprite, player.x, player.y, cameraX, cameraY, tint)

    if player.signalIcon >= 0:
      let
        iconX = player.x + player.sprite.width div 2 - 1
        iconY = player.y - 4
        color = signalColor(player.signalIcon)
        screenX = iconX - cameraX
        screenY = iconY - cameraY
      for py in 0 ..< 3:
        for px in 0 ..< 3:
          sim.fb.putPixel(screenX + px, screenY + py, color)

proc drawProgressBar(sim: var SimServer, progress, total, screenX, screenY: int) =
  let filledWidth = max(1, min(ProgressBarWidth, (progress * ProgressBarWidth + total - 1) div total))
  for px in 0 ..< ProgressBarWidth:
    sim.fb.putPixel(screenX + px, screenY, 1)
    sim.fb.putPixel(screenX + px, screenY + 1, 1)
  for px in 0 ..< filledWidth:
    sim.fb.putPixel(screenX + px, screenY, 10)
    sim.fb.putPixel(screenX + px, screenY + 1, 14)

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
  let player = sim.players[playerIndex]

  sim.fb.renderNumber(sim.digitSprites, player.gold, 1, 1)

  if sim.letterSprites.len > 0:
    let roleName = roleShortName(player.role)
    sim.fb.blitText(sim.letterSprites, roleName, ScreenWidth - roleName.len * 6 - 1, 1)

  let invY = 9
  sim.fb.renderNumber(sim.digitSprites, player.inv.wood, 1, invY)
  if sim.letterSprites.len > 0:
    sim.fb.blitText(sim.letterSprites, "W", 1 + 18, invY)
  sim.fb.renderNumber(sim.digitSprites, player.inv.stone, 40, invY)
  if sim.letterSprites.len > 0:
    sim.fb.blitText(sim.letterSprites, "S", 40 + 18, invY)

  if player.state == Gathering:
    sim.drawProgressBar(player.actionProgress, GatherWorkNeeded, 50, ScreenHeight - 5)
  elif player.state == Crafting:
    sim.drawProgressBar(player.actionProgress, CraftWorkNeeded, 50, ScreenHeight - 5)

  if player.state == AtSellStall:
    for px in 0 ..< ScreenWidth:
      for py in ScreenHeight - 20 ..< ScreenHeight:
        sim.fb.putPixel(px, py, 0)
    if sim.letterSprites.len > 0:
      sim.fb.blitText(sim.letterSprites, "SELL", 2, ScreenHeight - 18)
      let sellable = player.inv.sellableItems()
      if sellable.len > 0:
        let cursor = player.sellItemCursor mod max(1, sellable.len)
        let itemName = itemShortName(sellable[cursor])
        sim.fb.blitText(sim.letterSprites, itemName, 2, ScreenHeight - 11)
    sim.fb.renderNumber(sim.digitSprites, player.sellPrice, 50, ScreenHeight - 11)
    if sim.letterSprites.len > 0:
      sim.fb.blitText(sim.letterSprites, "G", 50 + 24, ScreenHeight - 11)

  if player.state == AtBuyStall:
    for px in 0 ..< ScreenWidth:
      for py in ScreenHeight - 20 ..< ScreenHeight:
        sim.fb.putPixel(px, py, 0)
    if sim.letterSprites.len > 0:
      sim.fb.blitText(sim.letterSprites, "BUY", 2, ScreenHeight - 18)
      let itemName = itemShortName(ItemKind(player.buyItemCursor mod (ord(high(ItemKind)) + 1)))
      sim.fb.blitText(sim.letterSprites, itemName, 2, ScreenHeight - 11)
    sim.fb.renderNumber(sim.digitSprites, player.buyQuantity, 50, ScreenHeight - 11)
    if sim.letterSprites.len > 0:
      sim.fb.blitText(sim.letterSprites, "X", 50 + 18, ScreenHeight - 11)

proc render(sim: var SimServer, playerIndex: int): seq[uint8] =
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

  sim.renderTerrain(cameraX, cameraY)
  sim.renderObjects(cameraX, cameraY)
  sim.renderSelection(playerIndex, cameraX, cameraY)
  sim.renderPlayers(cameraX, cameraY)
  sim.renderHud(playerIndex)
  sim.fb.packFramebuffer()
  sim.fb.packed

proc rewardScore(sim: SimServer, playerIndex: int): int =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return 0
  let player = sim.players[playerIndex]
  result = player.gold
  result += player.inv.inventoryValue()
  for listing in player.listings:
    result += listing.priceEach * listing.quantity

proc buildRewardPacket(sim: SimServer): string =
  for i, player in sim.players:
    result.add("reward ")
    result.add(player.name)
    result.add(" ")
    result.add($sim.rewardScore(i))
    result.add("\n")

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

proc playerInputFromMasks(currentMask, previousMask: uint8): PlayerInput =
  let decoded = decodeInputMask(currentMask)
  result.up = decoded.up
  result.down = decoded.down
  result.left = decoded.left
  result.right = decoded.right
  result.aPressed = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0
  result.aHeld = (currentMask and ButtonA) != 0
  result.bPressed = (currentMask and ButtonB) != 0 and (previousMask and ButtonB) == 0
  result.selectPressed = (currentMask and ButtonSelect) != 0 and (previousMask and ButtonSelect) == 0

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
    for listing in sim.npcListings.mitems:
      if listing.sellerIndex == removedIndex:
        listing.sellerIndex = -1
      elif listing.sellerIndex > removedIndex:
        dec listing.sellerIndex

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
    request.respond(200, headers, "Marketboard WebSocket server")

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
  seed = 0
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
      inputs: seq[PlayerInput]
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
    config = RunConfig(address: DefaultHost, port: DefaultPort, seed: 0)
    configJson = ""
    configPath = ""
    pendingOption = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      pendingOption = ""
      case key
      of "address":
        if val.len > 0:
          config.address = val
        else:
          pendingOption = "address"
      of "port":
        if val.len > 0:
          config.port = parseInt(val)
        else:
          pendingOption = "port"
      of "config":
        configJson = val
      of "config-file":
        configPath = val
      else: discard
    of cmdArgument:
      case pendingOption
      of "address":
        config.address = key
      of "port":
        config.port = parseInt(key)
      else: discard
      pendingOption = ""
    else: discard
  if configPath.len > 0:
    config.update(readFile(configPath))
  if configJson.len > 0:
    config.update(configJson)
  runServerLoop(config.address, config.port, seed = config.seed)

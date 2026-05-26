import std/[algorithm, json]
import bitworld/server

const
  MbTileSize* = 8
  WorldWidthTiles* = 48
  WorldHeightTiles* = 48
  WorldWidthPixels* = WorldWidthTiles * MbTileSize
  WorldHeightPixels* = WorldHeightTiles * MbTileSize
  MotionScale* = 256
  Accel* = 80
  FrictionNum* = 180
  FrictionDen* = 256
  MaxSpeed* = 320
  StopThreshold* = 20
  MinPlayerSpawnSpacing* = 16
  GatherWorkNeeded* = 48
  CraftWorkNeeded* = 48
  CraftWorkT1* = 48
  CraftWorkT2* = 72
  CraftWorkT3* = 120
  NodeRespawnTicks* = 120
  NodeRespawnT1* = 120
  NodeRespawnT2* = 180
  NodeRespawnT3* = 240
  StartingGold* = 500
  MaxSellSlots* = 8
  ListingExpiryTicks* = 3000
  WoodBasePrice* = 3
  StoneBasePrice* = 3
  HardwoodBasePrice* = 8
  CopperBasePrice* = 8
  IronwoodBasePrice* = 15
  IronBasePrice* = 15
  GearBasePrice* = 15
  T1GearBasePrice* = 15
  T2GearBasePrice* = 30
  T3GearBasePrice* = 60
  MaxSignalIcons* = 4
  HubCenterTx* = 24
  HubCenterTy* = 24
  GearSlotCount* = 5
  GearBonusPerSlot* = 10

type
  Role* = enum
    NoRole
    Gatherer
    Crafter

  GearSlot* = enum
    SlotHat
    SlotShirt
    SlotGloves
    SlotPants
    SlotShoes

  ItemKind* = enum
    WoodItem
    HardwoodItem
    IronwoodItem
    StoneItem
    CopperItem
    IronItem
    LeatherHat
    LeatherShirt
    LeatherGloves
    LeatherPants
    LeatherShoes
    ChainHat
    ChainShirt
    ChainGloves
    ChainPants
    ChainShoes
    PlateHat
    PlateShirt
    PlateGloves
    PlatePants
    PlateShoes

  PlayerState* = enum
    Idle
    Gathering
    Crafting
    AtSellStall
    AtBuyStall

  TileKind* = enum
    GrassTile
    PathTile
    WallTile

  WorldObjectKind* = enum
    GatherNodeObj
    CraftStationObj
    SellStallObj
    BuyStallObj
    GathererStallObj
    CrafterStallObj
    CancelStallObj

  WorldObject* = object
    kind*: WorldObjectKind
    tx*, ty*: int
    material*: ItemKind
    depleted*: bool
    respawnTimer*: int
    craftSlot*: GearSlot
    craftTier*: int

  MarketListing* = object
    sellerIndex*: int
    item*: ItemKind
    quantity*: int
    priceEach*: int
    age*: int

  Inventory* = object
    counts*: array[ItemKind, int]

  Player* = object
    name*: string
    x*, y*: int
    sprite*: Sprite
    facing*: Facing
    velX*, velY*: int
    carryX*, carryY*: int
    role*: Role
    gathererLevel*: int
    crafterLevel*: int
    gold*: int
    inv*: Inventory
    gathererGear*: array[GearSlotCount, ItemKind]
    crafterGear*: array[GearSlotCount, ItemKind]
    state*: PlayerState
    actionProgress*: int
    actionTargetIndex*: int
    sellItemCursor*: int
    sellPrice*: int
    buyItemCursor*: int
    buyQuantity*: int
    craftCursor*: int
    listings*: seq[MarketListing]
    signalIcon*: int

  PlayerInput* = object
    up*, down*, left*, right*: bool
    aPressed*, aHeld*: bool
    bPressed*: bool
    selectPressed*: bool

  SimServer* = object
    players*: seq[Player]
    tileKinds*: seq[TileKind]
    tiles*: seq[bool]
    objects*: seq[WorldObject]
    npcListings*: seq[MarketListing]
    playerSprites*: seq[Sprite]
    digitSprites*: array[10, Sprite]
    letterSprites*: seq[Sprite]
    fb*: Framebuffer
    tickCount*: int

proc tileIndex*(tx, ty: int): int =
  ty * WorldWidthTiles + tx

proc inTileBounds*(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < WorldWidthTiles and ty < WorldHeightTiles

proc makePlayerSprite*(): Sprite =
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

proc wood*(inv: Inventory): int = inv.counts[WoodItem]
proc stone*(inv: Inventory): int = inv.counts[StoneItem]
proc hardwood*(inv: Inventory): int = inv.counts[HardwoodItem]
proc copper*(inv: Inventory): int = inv.counts[CopperItem]
proc ironwood*(inv: Inventory): int = inv.counts[IronwoodItem]
proc iron*(inv: Inventory): int = inv.counts[IronItem]
proc `wood=`*(inv: var Inventory, val: int) = inv.counts[WoodItem] = val
proc `stone=`*(inv: var Inventory, val: int) = inv.counts[StoneItem] = val

const RawMaterials* = {WoodItem, HardwoodItem, IronwoodItem, StoneItem, CopperItem, IronItem}

proc isRawMaterial*(item: ItemKind): bool =
  item in RawMaterials

proc isGearItem*(item: ItemKind): bool =
  not item.isRawMaterial()

proc materialTier*(item: ItemKind): int =
  case item
  of WoodItem, StoneItem: 1
  of HardwoodItem, CopperItem: 2
  of IronwoodItem, IronItem: 3
  else: 0

proc gearTier*(item: ItemKind): int =
  case item
  of LeatherHat .. LeatherShoes: 1
  of ChainHat .. ChainShoes: 2
  of PlateHat .. PlateShoes: 3
  else: 0

proc gearSlotOf*(item: ItemKind): GearSlot =
  case item
  of LeatherHat, ChainHat, PlateHat: SlotHat
  of LeatherShirt, ChainShirt, PlateShirt: SlotShirt
  of LeatherGloves, ChainGloves, PlateGloves: SlotGloves
  of LeatherPants, ChainPants, PlatePants: SlotPants
  of LeatherShoes, ChainShoes, PlateShoes: SlotShoes
  else: SlotHat

proc gearForSlot*(slot: GearSlot, tier: int): ItemKind =
  case tier
  of 2:
    case slot
    of SlotHat: ChainHat
    of SlotShirt: ChainShirt
    of SlotGloves: ChainGloves
    of SlotPants: ChainPants
    of SlotShoes: ChainShoes
  of 3:
    case slot
    of SlotHat: PlateHat
    of SlotShirt: PlateShirt
    of SlotGloves: PlateGloves
    of SlotPants: PlatePants
    of SlotShoes: PlateShoes
  else:
    case slot
    of SlotHat: LeatherHat
    of SlotShirt: LeatherShirt
    of SlotGloves: LeatherGloves
    of SlotPants: LeatherPants
    of SlotShoes: LeatherShoes

proc craftRecipeMaterial*(item: ItemKind): ItemKind =
  case item
  of LeatherHat, LeatherGloves, LeatherShoes: WoodItem
  of LeatherShirt, LeatherPants: StoneItem
  of ChainHat, ChainGloves, ChainShoes: CopperItem
  of ChainShirt, ChainPants: HardwoodItem
  of PlateHat, PlateGloves, PlateShoes: IronItem
  of PlateShirt, PlatePants: IronwoodItem
  else: WoodItem

proc craftWorkForTier*(tier: int): int =
  case tier
  of 2: CraftWorkT2
  of 3: CraftWorkT3
  else: CraftWorkT1

proc nodeRespawnForMaterial*(material: ItemKind): int =
  case materialTier(material)
  of 2: NodeRespawnT2
  of 3: NodeRespawnT3
  else: NodeRespawnT1

proc itemBasePrice*(item: ItemKind): int =
  case item
  of WoodItem: WoodBasePrice
  of StoneItem: StoneBasePrice
  of HardwoodItem: HardwoodBasePrice
  of CopperItem: CopperBasePrice
  of IronwoodItem: IronwoodBasePrice
  of IronItem: IronBasePrice
  of LeatherHat .. LeatherShoes: T1GearBasePrice
  of ChainHat .. ChainShoes: T2GearBasePrice
  of PlateHat .. PlateShoes: T3GearBasePrice

proc activeGear*(player: Player): array[GearSlotCount, ItemKind] =
  case player.role
  of Gatherer, NoRole: player.gathererGear
  of Crafter: player.crafterGear

proc setActiveGearSlot*(player: var Player, slot: GearSlot, item: ItemKind) =
  case player.role
  of Gatherer, NoRole: player.gathererGear[ord(slot)] = item
  of Crafter: player.crafterGear[ord(slot)] = item

proc isGearSlotFilled*(player: Player, slot: GearSlot): bool =
  player.activeGear()[ord(slot)].isGearItem()

proc equippedGearCount*(player: Player): int =
  let gear = player.activeGear()
  for i in 0 ..< GearSlotCount:
    if gear[i].isGearItem():
      inc result

proc tryEquipGear*(player: var Player, item: ItemKind): bool =
  if not item.isGearItem(): return false
  let slot = gearSlotOf(item)
  if player.isGearSlotFilled(slot): return false
  player.setActiveGearSlot(slot, item)
  true

proc autoEquipFromInventory*(player: var Player) =
  for item in ItemKind:
    if not item.isGearItem(): continue
    if player.inv.counts[item] <= 0: continue
    let slot = gearSlotOf(item)
    let currentTier = gearTier(player.activeGear()[ord(slot)])
    let newTier = gearTier(item)
    if not player.isGearSlotFilled(slot) or newTier > currentTier:
      if not player.isGearSlotFilled(slot):
        player.setActiveGearSlot(slot, item)
        player.inv.counts[item] -= 1
      elif newTier > currentTier:
        let oldItem = player.activeGear()[ord(slot)]
        player.setActiveGearSlot(slot, item)
        player.inv.counts[item] -= 1
        player.inv.counts[oldItem] += 1

proc tryUpgradeGear*(player: var Player, item: ItemKind): bool =
  if not item.isGearItem(): return false
  let slot = gearSlotOf(item)
  let currentTier = gearTier(player.activeGear()[ord(slot)])
  let newTier = gearTier(item)
  if newTier <= currentTier: return false
  player.setActiveGearSlot(slot, item)
  true

proc hasFullGearSetOfTier*(player: Player, tier: int): bool =
  let gear = player.activeGear()
  for i in 0 ..< GearSlotCount:
    if not gear[i].isGearItem(): return false
    if gearTier(gear[i]) < tier: return false
  true

proc canGatherMaterial*(player: Player, material: ItemKind): bool =
  let tier = materialTier(material)
  if tier <= 1: return true
  player.hasFullGearSetOfTier(tier - 1)

proc canCraftFromMaterial*(player: Player, material: ItemKind): bool =
  let tier = materialTier(material)
  if tier <= 1: return true
  player.hasFullGearSetOfTier(tier - 1)

proc effectiveGatherWork*(player: Player): int =
  let bonus = player.equippedGearCount() * GearBonusPerSlot
  max(1, GatherWorkNeeded * (100 - bonus) div 100)

proc effectiveMaxSpeed*(player: Player): int =
  let bonus = player.equippedGearCount() * GearBonusPerSlot
  MaxSpeed * (100 + bonus) div 100

proc itemCount*(inv: Inventory, item: ItemKind): int =
  inv.counts[item]

proc addItem*(inv: var Inventory, item: ItemKind, count: int = 1) =
  inv.counts[item] += count

proc removeItem*(inv: var Inventory, item: ItemKind, count: int = 1): bool =
  if inv.counts[item] < count: return false
  inv.counts[item] -= count
  true

proc inventoryValue*(inv: Inventory): int =
  for item in ItemKind:
    result += inv.counts[item] * itemBasePrice(item)

proc sellableItems*(inv: Inventory): seq[ItemKind] =
  for item in ItemKind:
    if inv.counts[item] > 0:
      result.add item

proc hasCraftMaterials*(inv: Inventory): bool =
  for mat in [WoodItem, StoneItem, HardwoodItem, CopperItem, IronwoodItem, IronItem]:
    if inv.counts[mat] >= 3: return true
  false

proc craftableItem*(player: Player): ItemKind =
  for offset in 0 ..< GearSlotCount:
    let slotIdx = (player.craftCursor + offset) mod GearSlotCount
    let slot = GearSlot(slotIdx)
    for tier in countdown(3, 1):
      let gear = gearForSlot(slot, tier)
      let material = craftRecipeMaterial(gear)
      if player.inv.counts[material] >= 3 and player.canCraftFromMaterial(material):
        return gear
  gearForSlot(GearSlot(player.craftCursor mod GearSlotCount), 1)

proc craftStationItem*(obj: WorldObject): ItemKind =
  gearForSlot(obj.craftSlot, obj.craftTier)

proc canCraftAt*(player: Player, obj: WorldObject): bool =
  if player.role != Crafter: return false
  let gear = obj.craftStationItem()
  let material = craftRecipeMaterial(gear)
  player.inv.counts[material] >= 3 and player.canCraftFromMaterial(material)

proc objectIndexAt*(sim: SimServer, tx, ty: int): int =
  for i, obj in sim.objects:
    if obj.tx == tx and obj.ty == ty:
      return i
  -1

proc isUsefulObject*(player: Player, obj: WorldObject): bool =
  case obj.kind
  of GatherNodeObj:
    not obj.depleted and player.role == Gatherer and
    player.canGatherMaterial(obj.material)
  of CraftStationObj:
    player.canCraftAt(obj)
  of SellStallObj, BuyStallObj, GathererStallObj, CrafterStallObj, CancelStallObj:
    true

proc addObject*(sim: var SimServer, kind: WorldObjectKind, tx, ty: int, material = WoodItem) =
  if not inTileBounds(tx, ty):
    return
  sim.objects.add WorldObject(kind: kind, tx: tx, ty: ty, material: material)
  if kind != GatherNodeObj:
    sim.tiles[tileIndex(tx, ty)] = true

proc addCraftStation*(sim: var SimServer, tx, ty: int, slot: GearSlot, tier: int) =
  if not inTileBounds(tx, ty):
    return
  sim.objects.add WorldObject(kind: CraftStationObj, tx: tx, ty: ty,
                              craftSlot: slot, craftTier: tier)
  sim.tiles[tileIndex(tx, ty)] = true

proc initMap*(sim: var SimServer) =
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

  # North plaza — role selection (y=18..19)
  for ty in 18 .. 19:
    for tx in HubCenterTx - 3 .. HubCenterTx + 3:
      if inTileBounds(tx, ty):
        sim.tileKinds[tileIndex(tx, ty)] = PathTile
  sim.addObject(GathererStallObj, HubCenterTx - 2, 18)
  sim.addObject(CrafterStallObj, HubCenterTx + 2, 18)

  # Main street connecting north to south (x=center, y=19..30)
  for ty in 20 .. 30:
    for tx in HubCenterTx - 1 .. HubCenterTx + 1:
      if inTileBounds(tx, ty):
        sim.tileKinds[tileIndex(tx, ty)] = PathTile

  # West market — sell stalls (x=18..20, y=22..24)
  for ty in 22 .. 24:
    for tx in 18 .. HubCenterTx - 1:
      if inTileBounds(tx, ty):
        sim.tileKinds[tileIndex(tx, ty)] = PathTile
  sim.addObject(SellStallObj, 18, 22)
  sim.addObject(SellStallObj, 18, 24)

  # East market — buy stalls (x=28..30, y=22..24)
  for ty in 22 .. 24:
    for tx in HubCenterTx + 1 .. 30:
      if inTileBounds(tx, ty):
        sim.tileKinds[tileIndex(tx, ty)] = PathTile
  sim.addObject(BuyStallObj, 30, 22)
  sim.addObject(BuyStallObj, 30, 24)

  # Cancel stall — center of main street
  sim.addObject(CancelStallObj, HubCenterTx, 21)

  # South workshop — craft stations spaced out (every other tile)
  for ty in 26 .. 32:
    for tx in HubCenterTx - 5 .. HubCenterTx + 5:
      if inTileBounds(tx, ty):
        sim.tileKinds[tileIndex(tx, ty)] = PathTile
  for slotIdx in 0 ..< GearSlotCount:
    for tier in 1 .. 3:
      let tx = HubCenterTx - 4 + slotIdx * 2
      let ty = 27 + (tier - 1) * 2
      sim.addCraftStation(tx, ty, GearSlot(slotIdx), tier)

  # T1 gathering — close ring around town
  let woodPositions = [
    (HubCenterTx - 10, HubCenterTy - 10),
    (HubCenterTx + 10, HubCenterTy - 10),
    (HubCenterTx - 12, HubCenterTy),
    (HubCenterTx + 12, HubCenterTy),
    (HubCenterTx - 10, HubCenterTy + 10),
    (HubCenterTx + 10, HubCenterTy + 10),
    (HubCenterTx, HubCenterTy - 12),
    (HubCenterTx, HubCenterTy + 12),
    (HubCenterTx - 12, HubCenterTy - 5),
    (HubCenterTx + 12, HubCenterTy - 5),
    (HubCenterTx - 12, HubCenterTy + 5),
    (HubCenterTx + 12, HubCenterTy + 5),
  ]
  for pos in woodPositions:
    sim.addObject(GatherNodeObj, pos[0], pos[1], WoodItem)

  let stonePositions = [
    (HubCenterTx - 10, HubCenterTy - 5),
    (HubCenterTx + 10, HubCenterTy - 5),
    (HubCenterTx - 10, HubCenterTy + 5),
    (HubCenterTx + 10, HubCenterTy + 5),
    (HubCenterTx - 5, HubCenterTy - 10),
    (HubCenterTx + 5, HubCenterTy + 10),
    (HubCenterTx + 5, HubCenterTy - 10),
    (HubCenterTx - 5, HubCenterTy + 10),
  ]
  for pos in stonePositions:
    sim.addObject(GatherNodeObj, pos[0], pos[1], StoneItem)

  # T2 gathering — mid ring
  let hardwoodPositions = [
    (HubCenterTx - 16, HubCenterTy - 16),
    (HubCenterTx + 16, HubCenterTy - 16),
    (HubCenterTx - 16, HubCenterTy + 16),
    (HubCenterTx + 16, HubCenterTy + 16),
  ]
  for pos in hardwoodPositions:
    sim.addObject(GatherNodeObj, pos[0], pos[1], HardwoodItem)

  let copperPositions = [
    (HubCenterTx - 18, HubCenterTy),
    (HubCenterTx + 18, HubCenterTy),
    (HubCenterTx, HubCenterTy - 18),
    (HubCenterTx, HubCenterTy + 18),
  ]
  for pos in copperPositions:
    sim.addObject(GatherNodeObj, pos[0], pos[1], CopperItem)

  # T3 gathering — map corners
  let ironwoodPositions = [
    (3, 3), (44, 3), (3, 44),
  ]
  for pos in ironwoodPositions:
    sim.addObject(GatherNodeObj, pos[0], pos[1], IronwoodItem)

  let ironPositions = [
    (44, 44), (3, 24), (44, 24),
  ]
  for pos in ironPositions:
    sim.addObject(GatherNodeObj, pos[0], pos[1], IronItem)

proc initNpcListings*(sim: var SimServer) =
  for _ in 0 ..< 4:
    sim.npcListings.add MarketListing(sellerIndex: -1, item: WoodItem, quantity: 1, priceEach: WoodBasePrice)
  for _ in 0 ..< 4:
    sim.npcListings.add MarketListing(sellerIndex: -1, item: StoneItem, quantity: 1, priceEach: StoneBasePrice)
  discard

proc canOccupy*(sim: SimServer, x, y, width, height: int): bool =
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

proc findPlayerSpawn*(sim: SimServer): tuple[x, y: int] =
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

proc addPlayer*(sim: var SimServer, name: string): int =
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

proc initSimServer*(seed: int): SimServer =
  discard seed
  result.tiles = newSeq[bool](WorldWidthTiles * WorldHeightTiles)
  result.tileKinds = newSeq[TileKind](WorldWidthTiles * WorldHeightTiles)
  result.playerSprites = @[
    makePlayerSprite(),
    makePlayerSprite(),
    makePlayerSprite(),
    makePlayerSprite()
  ]
  result.initMap()
  result.initNpcListings()

proc applyMomentumAxis*(
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

proc applyMovementInput*(sim: var SimServer, playerIndex: int, input: PlayerInput) =
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

  let maxSpd = sim.players[playerIndex].effectiveMaxSpeed()
  if inputX != 0:
    sim.players[playerIndex].velX =
      clamp(sim.players[playerIndex].velX + inputX * Accel, -maxSpd, maxSpd)
  else:
    sim.players[playerIndex].velX =
      (sim.players[playerIndex].velX * FrictionNum) div FrictionDen
    if abs(sim.players[playerIndex].velX) < StopThreshold:
      sim.players[playerIndex].velX = 0

  if inputY != 0:
    sim.players[playerIndex].velY =
      clamp(sim.players[playerIndex].velY + inputY * Accel, -maxSpd, maxSpd)
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

proc standingTile*(player: Player): tuple[tx, ty: int] =
  let
    px = player.x + player.sprite.width div 2
    py = player.y + player.sprite.height div 2
  (px div MbTileSize, py div MbTileSize)

proc interactionTile*(player: Player): tuple[tx, ty: int] =
  let
    centerTx = (player.x + player.sprite.width div 2) div MbTileSize
    centerTy = (player.y + player.sprite.height div 2) div MbTileSize
  case player.facing
  of FaceUp: (centerTx, centerTy - 1)
  of FaceDown: (centerTx, centerTy + 1)
  of FaceLeft: (centerTx - 1, centerTy)
  of FaceRight: (centerTx + 1, centerTy)

proc bestInteractionTile*(sim: SimServer, player: Player): tuple[tx, ty: int] =
  let primary = player.interactionTile()
  if inTileBounds(primary.tx, primary.ty):
    let idx = sim.objectIndexAt(primary.tx, primary.ty)
    if idx >= 0 and player.isUsefulObject(sim.objects[idx]):
      return primary
  let standing = player.standingTile()
  if inTileBounds(standing.tx, standing.ty):
    let idx = sim.objectIndexAt(standing.tx, standing.ty)
    if idx >= 0 and player.isUsefulObject(sim.objects[idx]):
      return standing
  var bestDist = int.high
  var bestTile = primary
  for dy in -2 .. 2:
    for dx in -2 .. 2:
      let dist = abs(dx) + abs(dy)
      if dist == 0 or dist > 2: continue
      let tx = standing.tx + dx
      let ty = standing.ty + dy
      if not inTileBounds(tx, ty): continue
      let idx = sim.objectIndexAt(tx, ty)
      if idx >= 0 and player.isUsefulObject(sim.objects[idx]) and dist < bestDist:
        bestDist = dist
        bestTile = (tx, ty)
  bestTile

proc cancelAction*(sim: var SimServer, playerIndex: int) =
  sim.players[playerIndex].state = Idle
  sim.players[playerIndex].actionProgress = 0
  sim.players[playerIndex].actionTargetIndex = -1
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0

proc handleAction*(sim: var SimServer, playerIndex: int) =
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
        for _ in 0 ..< canBuy:
          if not sim.players[playerIndex].tryEquipGear(wantedItem):
            if not sim.players[playerIndex].tryUpgradeGear(wantedItem):
              sim.players[playerIndex].inv.addItem(wantedItem)
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
  var objIndex = -1
  if inTileBounds(target.tx, target.ty):
    objIndex = sim.objectIndexAt(target.tx, target.ty)
  if objIndex >= 0 and sim.objects[objIndex].kind == CraftStationObj and
     not player.canCraftAt(sim.objects[objIndex]):
    objIndex = -1
  if objIndex < 0:
    let standing = player.standingTile()
    if inTileBounds(standing.tx, standing.ty):
      objIndex = sim.objectIndexAt(standing.tx, standing.ty)
  if objIndex < 0:
    return

  let obj = sim.objects[objIndex]
  case obj.kind
  of GathererStallObj:
    sim.players[playerIndex].role = Gatherer
  of CrafterStallObj:
    sim.players[playerIndex].role = Crafter
  of GatherNodeObj:
    if player.role == Gatherer and not obj.depleted and
       player.canGatherMaterial(obj.material):
      sim.players[playerIndex].state = Gathering
      sim.players[playerIndex].actionProgress = 0
      sim.players[playerIndex].actionTargetIndex = objIndex
  of CraftStationObj:
    if player.canCraftAt(obj):
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
  of CancelStallObj:
    for listing in sim.players[playerIndex].listings:
      sim.players[playerIndex].inv.addItem(listing.item, listing.quantity)
    sim.players[playerIndex].listings.setLen(0)

proc handleCancel*(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  if sim.players[playerIndex].state != Idle:
    sim.cancelAction(playerIndex)

proc updateActionProgress*(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let state = sim.players[playerIndex].state
  if state == Gathering:
    inc sim.players[playerIndex].actionProgress
    let gatherNeeded = sim.players[playerIndex].effectiveGatherWork()
    if sim.players[playerIndex].actionProgress >= gatherNeeded:
      let objIdx = sim.players[playerIndex].actionTargetIndex
      if objIdx >= 0 and objIdx < sim.objects.len:
        let material = sim.objects[objIdx].material
        sim.players[playerIndex].inv.addItem(material)
        sim.objects[objIdx].depleted = true
        sim.objects[objIdx].respawnTimer = nodeRespawnForMaterial(material)
        inc sim.players[playerIndex].gathererLevel
      sim.cancelAction(playerIndex)
  elif state == Crafting:
    inc sim.players[playerIndex].actionProgress
    let objIdx = sim.players[playerIndex].actionTargetIndex
    if objIdx < 0 or objIdx >= sim.objects.len:
      sim.cancelAction(playerIndex)
      return
    let gear = sim.objects[objIdx].craftStationItem()
    let craftWork = craftWorkForTier(gearTier(gear))
    if sim.players[playerIndex].actionProgress >= craftWork:
      let material = craftRecipeMaterial(gear)
      if sim.players[playerIndex].inv.removeItem(material, 3):
        sim.players[playerIndex].inv.addItem(gear)
        inc sim.players[playerIndex].crafterLevel
      sim.cancelAction(playerIndex)

proc handleStallInput*(sim: var SimServer, playerIndex: int, input: PlayerInput) =
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

proc cycleSignal*(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  inc sim.players[playerIndex].signalIcon
  if sim.players[playerIndex].signalIcon >= MaxSignalIcons:
    sim.players[playerIndex].signalIcon = -1

proc updateNodes*(sim: var SimServer) =
  for obj in sim.objects.mitems:
    if obj.kind == GatherNodeObj and obj.depleted:
      dec obj.respawnTimer
      if obj.respawnTimer <= 0:
        obj.depleted = false

proc step*(sim: var SimServer, inputs: openArray[PlayerInput]) =
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

  for playerIndex in 0 ..< sim.players.len:
    var i = sim.players[playerIndex].listings.high
    while i >= 0:
      inc sim.players[playerIndex].listings[i].age
      if sim.players[playerIndex].listings[i].age >= ListingExpiryTicks:
        sim.players[playerIndex].inv.addItem(sim.players[playerIndex].listings[i].item)
        sim.players[playerIndex].listings.delete(i)
      dec i

  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].state == Idle:
      sim.players[playerIndex].autoEquipFromInventory()

  sim.updateNodes()
  inc sim.tickCount

proc itemShortName*(item: ItemKind): string =
  case item
  of WoodItem: "WOOD"
  of HardwoodItem: "HDWD"
  of IronwoodItem: "IRWD"
  of StoneItem: "STONE"
  of CopperItem: "COPR"
  of IronItem: "IRON"
  of LeatherHat: "L HAT"
  of LeatherShirt: "L SHRT"
  of LeatherGloves: "L GLVS"
  of LeatherPants: "L PNTS"
  of LeatherShoes: "L SHOE"
  of ChainHat: "C HAT"
  of ChainShirt: "C SHRT"
  of ChainGloves: "C GLVS"
  of ChainPants: "C PNTS"
  of ChainShoes: "C SHOE"
  of PlateHat: "P HAT"
  of PlateShirt: "P SHRT"
  of PlateGloves: "P GLVS"
  of PlatePants: "P PNTS"
  of PlateShoes: "P SHOE"

proc objectLabel*(obj: WorldObject): string =
  case obj.kind
  of GatherNodeObj:
    if obj.depleted:
      return "DEPLETED"
    case obj.material
    of WoodItem: "WOOD NODE"
    of HardwoodItem: "HDWD NODE"
    of IronwoodItem: "IRWD NODE"
    of StoneItem: "STONE NODE"
    of CopperItem: "COPR NODE"
    of IronItem: "IRON NODE"
    else: "NODE"
  of CraftStationObj:
    let slotName = case obj.craftSlot
      of SlotHat: "HAT"
      of SlotShirt: "SHRT"
      of SlotGloves: "GLVS"
      of SlotPants: "PNTS"
      of SlotShoes: "SHOE"
    "T" & $obj.craftTier & " " & slotName
  of SellStallObj: "SELL"
  of BuyStallObj: "BUY"
  of GathererStallObj: "GATHERER"
  of CrafterStallObj: "CRAFTER"
  of CancelStallObj: "CANCEL"

proc roleShortName*(role: Role): string =
  case role
  of NoRole: "NONE"
  of Gatherer: "GATH"
  of Crafter: "CRAF"

proc rewardScore*(sim: SimServer, playerIndex: int): int =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return 0
  let player = sim.players[playerIndex]
  result = player.gold
  result += player.inv.inventoryValue()
  for i in 0 ..< GearSlotCount:
    if player.gathererGear[i].isGearItem():
      result += itemBasePrice(player.gathererGear[i])
    if player.crafterGear[i].isGearItem():
      result += itemBasePrice(player.crafterGear[i])
  for listing in player.listings:
    result += listing.priceEach * listing.quantity

proc totalMarketCap*(sim: SimServer): int =
  for i in 0 ..< sim.players.len:
    result += sim.rewardScore(i)

proc buildRewardPacket*(sim: SimServer): string =
  for i, player in sim.players:
    result.add("reward ")
    result.add(player.name)
    result.add(" ")
    result.add($sim.rewardScore(i))
    result.add("\n")

proc buildStateJson*(sim: SimServer, playerIndex: int): string =
  var root = newJObject()
  root["tick"] = %sim.tickCount

  if playerIndex >= 0 and playerIndex < sim.players.len:
    let p = sim.players[playerIndex]
    var pj = newJObject()
    pj["index"] = %playerIndex
    pj["name"] = %p.name
    pj["x"] = %p.x
    pj["y"] = %p.y
    pj["tx"] = %((p.x + p.sprite.width div 2) div MbTileSize)
    pj["ty"] = %((p.y + p.sprite.height div 2) div MbTileSize)
    pj["facing"] = %($p.facing)
    pj["role"] = %($p.role)
    pj["gold"] = %p.gold
    pj["state"] = %($p.state)
    pj["actionProgress"] = %p.actionProgress
    pj["actionTargetIndex"] = %p.actionTargetIndex
    pj["sellPrice"] = %p.sellPrice
    pj["sellItemCursor"] = %p.sellItemCursor
    pj["buyQuantity"] = %p.buyQuantity
    pj["buyItemCursor"] = %p.buyItemCursor
    pj["signalIcon"] = %p.signalIcon
    var inv = newJObject()
    for item in ItemKind:
      inv[$item] = %p.inv.counts[item]
    pj["inv"] = inv
    pj["equippedGearCount"] = %p.equippedGearCount()
    var gear = newJArray()
    let activeG = p.activeGear()
    for i in 0 ..< GearSlotCount:
      gear.add %($activeG[i])
    pj["equippedGear"] = gear
    var gatherGear = newJArray()
    for i in 0 ..< GearSlotCount:
      gatherGear.add %($p.gathererGear[i])
    pj["gathererGear"] = gatherGear
    var craftGear = newJArray()
    for i in 0 ..< GearSlotCount:
      craftGear.add %($p.crafterGear[i])
    pj["crafterGear"] = craftGear
    var listings = newJArray()
    for l in p.listings:
      var lj = newJObject()
      lj["item"] = %($l.item)
      lj["quantity"] = %l.quantity
      lj["priceEach"] = %l.priceEach
      listings.add lj
    pj["listings"] = listings
    root["player"] = pj

  var objects = newJArray()
  for obj in sim.objects:
    var oj = newJObject()
    oj["kind"] = %($obj.kind)
    oj["tx"] = %obj.tx
    oj["ty"] = %obj.ty
    oj["material"] = %($obj.material)
    oj["depleted"] = %obj.depleted
    if obj.kind == CraftStationObj:
      oj["craftSlot"] = %ord(obj.craftSlot)
      oj["craftTier"] = %obj.craftTier
    objects.add oj
  root["objects"] = objects

  var players = newJArray()
  for i, p in sim.players:
    if i == playerIndex:
      continue
    var pj = newJObject()
    pj["index"] = %i
    pj["name"] = %p.name
    pj["x"] = %p.x
    pj["y"] = %p.y
    pj["role"] = %($p.role)
    pj["state"] = %($p.state)
    pj["signalIcon"] = %p.signalIcon
    players.add pj
  root["players"] = players

  var npcListings = newJArray()
  for l in sim.npcListings:
    var lj = newJObject()
    lj["item"] = %($l.item)
    lj["quantity"] = %l.quantity
    lj["priceEach"] = %l.priceEach
    npcListings.add lj
  root["npcListings"] = npcListings

  var playerListings = newJArray()
  for i, p in sim.players:
    for l in p.listings:
      var lj = newJObject()
      lj["sellerIndex"] = %l.sellerIndex
      lj["item"] = %($l.item)
      lj["quantity"] = %l.quantity
      lj["priceEach"] = %l.priceEach
      playerListings.add lj
  root["playerListings"] = playerListings

  $root

proc mixHash(hash: var uint64, value: uint64) =
  hash = hash xor value
  hash *= 1099511628211'u64

proc mixHashInt(hash: var uint64, value: int) =
  hash.mixHash(cast[uint64](int64(value)))

proc mixHashBool(hash: var uint64, value: bool) =
  hash.mixHashInt(ord(value))

proc gameHash*(sim: SimServer): uint64 =
  result = 14695981039346656037'u64
  result.mixHashInt(sim.tickCount)
  result.mixHashInt(sim.players.len)
  for player in sim.players:
    result.mixHashInt(player.x)
    result.mixHashInt(player.y)
    result.mixHashInt(player.velX)
    result.mixHashInt(player.velY)
    result.mixHashInt(player.carryX)
    result.mixHashInt(player.carryY)
    result.mixHashInt(ord(player.facing))
    result.mixHashInt(ord(player.role))
    result.mixHashInt(ord(player.state))
    result.mixHashInt(player.gold)
    result.mixHashInt(player.actionProgress)
    result.mixHashInt(player.actionTargetIndex)
    for item in ItemKind:
      result.mixHashInt(player.inv.counts[item])
    for i in 0 ..< GearSlotCount:
      result.mixHashInt(ord(player.gathererGear[i]))
    for i in 0 ..< GearSlotCount:
      result.mixHashInt(ord(player.crafterGear[i]))
    result.mixHashInt(player.listings.len)
    for listing in player.listings:
      result.mixHashInt(ord(listing.item))
      result.mixHashInt(listing.quantity)
      result.mixHashInt(listing.priceEach)
  for obj in sim.objects:
    result.mixHashBool(obj.depleted)
    result.mixHashInt(obj.respawnTimer)
  for listing in sim.npcListings:
    result.mixHashInt(ord(listing.item))
    result.mixHashInt(listing.quantity)
    result.mixHashInt(listing.priceEach)

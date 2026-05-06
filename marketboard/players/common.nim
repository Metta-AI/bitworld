import std/[heapqueue, json, math, options, sets]
import whisky
import protocol

const
  ItemNames* = [
    "WoodItem", "HardwoodItem", "IronwoodItem",
    "StoneItem", "CopperItem", "IronItem",
    "LeatherHat", "LeatherShirt", "LeatherGloves", "LeatherPants", "LeatherShoes",
    "ChainHat", "ChainShirt", "ChainGloves", "ChainPants", "ChainShoes",
    "PlateHat", "PlateShirt", "PlateGloves", "PlatePants", "PlateShoes",
  ]
  GearSlotCount* = 5
  BotMaxSellSlots* = 8
  GearItemNames* = [
    "LeatherHat", "LeatherShirt", "LeatherGloves", "LeatherPants", "LeatherShoes",
    "ChainHat", "ChainShirt", "ChainGloves", "ChainPants", "ChainShoes",
    "PlateHat", "PlateShirt", "PlateGloves", "PlatePants", "PlateShoes",
  ]
  RawMaterialNames* = [
    "WoodItem", "HardwoodItem", "IronwoodItem",
    "StoneItem", "CopperItem", "IronItem",
  ]

type
  BotInventory* = object
    counts*: array[21, int]

  BotListing* = object
    sellerIndex*: int
    item*: string
    quantity*: int
    priceEach*: int

  BotObject* = object
    kind*: string
    tx*, ty*: int
    material*: string
    depleted*: bool
    craftSlot*: int
    craftTier*: int

  BotOtherPlayer* = object
    index*: int
    name*: string
    x*, y*: int
    role*: string
    state*: string
    signalIcon*: int

  BotPlayer* = object
    index*: int
    name*: string
    x*, y*: int
    tx*, ty*: int
    facing*: string
    role*: string
    gold*: int
    state*: string
    actionProgress*: int
    actionTargetIndex*: int
    sellPrice*: int
    sellItemCursor*: int
    buyQuantity*: int
    buyItemCursor*: int
    signalIcon*: int
    inv*: BotInventory
    equippedGear*: array[GearSlotCount, string]
    gathererGear*: array[GearSlotCount, string]
    crafterGear*: array[GearSlotCount, string]
    equippedGearCount*: int
    listings*: seq[BotListing]

  GameState* = object
    tick*: int
    player*: BotPlayer
    objects*: seq[BotObject]
    players*: seq[BotOtherPlayer]
    npcListings*: seq[BotListing]
    playerListings*: seq[BotListing]

  PricingState* = object
    lastListingCount*: int
    staleTicks*: int
    demandTicks*: int

proc itemIndex*(name: string): int =
  for i, n in ItemNames:
    if n == name: return i
  -1

proc wood*(inv: BotInventory): int = inv.counts[0]
proc hardwood*(inv: BotInventory): int = inv.counts[1]
proc ironwood*(inv: BotInventory): int = inv.counts[2]
proc stone*(inv: BotInventory): int = inv.counts[3]
proc copper*(inv: BotInventory): int = inv.counts[4]
proc iron*(inv: BotInventory): int = inv.counts[5]

proc itemCount*(inv: BotInventory, name: string): int =
  let idx = itemIndex(name)
  if idx >= 0: inv.counts[idx] else: 0

proc hasAnyGear*(inv: BotInventory): bool =
  for i in 6 ..< 21:
    if inv.counts[i] > 0: return true
  false

proc isGearItem*(name: string): bool =
  name in GearItemNames

proc dynamicPrice*(ps: var PricingState, currentListings: int, baseTarget: int): int =
  ## Adjust price based on whether listings are selling or stale.
  if currentListings < ps.lastListingCount:
    inc ps.demandTicks
    ps.staleTicks = 0
  elif ps.lastListingCount > 0:
    inc ps.staleTicks
    ps.demandTicks = 0
  ps.lastListingCount = currentListings
  result = baseTarget
  if ps.staleTicks >= 5:
    result = baseTarget - 2
  elif ps.staleTicks >= 2:
    result = baseTarget - 1
  elif ps.demandTicks >= 3:
    result = baseTarget + 2
  elif ps.demandTicks >= 1:
    result = baseTarget + 1
  result = max(max(1, baseTarget div 2), result)

proc parseInventory(node: JsonNode): BotInventory =
  for i, name in ItemNames:
    if node.hasKey(name):
      result.counts[i] = node[name].getInt()

proc parseListing(node: JsonNode): BotListing =
  result.sellerIndex = node.getOrDefault("sellerIndex").getInt(-1)
  result.item = node["item"].getStr()
  result.quantity = node["quantity"].getInt()
  result.priceEach = node["priceEach"].getInt()

proc parseGameState*(jsonStr: string): GameState =
  let root = parseJson(jsonStr)
  result.tick = root["tick"].getInt()

  if root.hasKey("player"):
    let p = root["player"]
    result.player.index = p["index"].getInt()
    result.player.name = p["name"].getStr()
    result.player.x = p["x"].getInt()
    result.player.y = p["y"].getInt()
    result.player.tx = p["tx"].getInt()
    result.player.ty = p["ty"].getInt()
    result.player.facing = p["facing"].getStr()
    result.player.role = p["role"].getStr()
    result.player.gold = p["gold"].getInt()
    result.player.state = p["state"].getStr()
    result.player.actionProgress = p["actionProgress"].getInt()
    result.player.actionTargetIndex = p["actionTargetIndex"].getInt()
    result.player.sellPrice = p["sellPrice"].getInt()
    result.player.sellItemCursor = p["sellItemCursor"].getInt()
    result.player.buyQuantity = p["buyQuantity"].getInt()
    result.player.buyItemCursor = p["buyItemCursor"].getInt()
    result.player.signalIcon = p["signalIcon"].getInt()
    result.player.inv = parseInventory(p["inv"])
    result.player.equippedGearCount = p["equippedGearCount"].getInt()
    if p.hasKey("equippedGear"):
      var gearIdx = 0
      for g in p["equippedGear"]:
        if gearIdx < GearSlotCount:
          result.player.equippedGear[gearIdx] = g.getStr()
        inc gearIdx
    if p.hasKey("gathererGear"):
      var gearIdx = 0
      for g in p["gathererGear"]:
        if gearIdx < GearSlotCount:
          result.player.gathererGear[gearIdx] = g.getStr()
        inc gearIdx
    if p.hasKey("crafterGear"):
      var gearIdx = 0
      for g in p["crafterGear"]:
        if gearIdx < GearSlotCount:
          result.player.crafterGear[gearIdx] = g.getStr()
        inc gearIdx
    for l in p["listings"]:
      result.player.listings.add parseListing(l)

  for obj in root["objects"]:
    var bo = BotObject(
      kind: obj["kind"].getStr(),
      tx: obj["tx"].getInt(),
      ty: obj["ty"].getInt(),
      material: obj["material"].getStr(),
      depleted: obj["depleted"].getBool()
    )
    if obj.hasKey("craftSlot"):
      bo.craftSlot = obj["craftSlot"].getInt()
    if obj.hasKey("craftTier"):
      bo.craftTier = obj["craftTier"].getInt()
    result.objects.add bo

  for p in root["players"]:
    result.players.add BotOtherPlayer(
      index: p["index"].getInt(),
      name: p["name"].getStr(),
      x: p["x"].getInt(),
      y: p["y"].getInt(),
      role: p["role"].getStr(),
      state: p["state"].getStr(),
      signalIcon: p["signalIcon"].getInt()
    )

  for l in root["npcListings"]:
    result.npcListings.add parseListing(l)

  for l in root["playerListings"]:
    result.playerListings.add parseListing(l)

const BotTileSize = 8

proc connectBot*(host: string, port: int, name: string): WebSocket =
  let url = "ws://" & host & ":" & $port & "/state?name=" & name
  newWebSocket(url)

proc sendInput*(ws: WebSocket, mask: uint8) =
  let packet = blobFromMask(mask)
  ws.send(packet, BinaryMessage)

proc buildMask*(up = false, down = false, left = false, right = false,
                a = false, b = false, select = false): uint8 =
  if up: result = result or ButtonUp
  if down: result = result or ButtonDown
  if left: result = result or ButtonLeft
  if right: result = result or ButtonRight
  if a: result = result or ButtonA
  if b: result = result or ButtonB
  if select: result = result or ButtonSelect

proc receiveState*(ws: WebSocket): Option[GameState] =
  let msgOpt = ws.receiveMessage()
  if msgOpt.isSome:
    let msg = msgOpt.get()
    if msg.kind == TextMessage and msg.data.len > 0:
      return some(parseGameState(msg.data))
  none(GameState)

proc isOnTile*(px, py, tx, ty: int): bool =
  let
    playerTx = (px + 3) div BotTileSize
    playerTy = (py + 3) div BotTileSize
  playerTx == tx and playerTy == ty

proc isAdjacentTo*(px, py, tx, ty: int): bool =
  let
    playerTx = (px + 3) div BotTileSize
    playerTy = (py + 3) div BotTileSize
    dx = abs(playerTx - tx)
    dy = abs(playerTy - ty)
  (dx <= 1 and dy <= 1) and (dx + dy <= 1)

proc manhattanDist*(px, py, tx, ty: int): int =
  let
    playerTx = (px + 3) div BotTileSize
    playerTy = (py + 3) div BotTileSize
  abs(playerTx - tx) + abs(playerTy - ty)

proc walkToward*(px, py, targetTx, targetTy: int): uint8 =
  let
    targetPx = targetTx * BotTileSize
    targetPy = targetTy * BotTileSize
    dx = targetPx - px
    dy = targetPy - py
  if abs(dx) > abs(dy):
    if dx < 0: buildMask(left = true)
    else: buildMask(right = true)
  elif dy != 0:
    if dy < 0: buildMask(up = true)
    else: buildMask(down = true)
  else:
    0'u8

type
  WalkState* = object
    lastX*, lastY*: int
    stuckTicks*: int
    useAltAxis*: bool

proc initWalkState*(): WalkState =
  WalkState()

proc smartWalkToward*(ws: var WalkState, px, py, targetTx, targetTy: int): uint8 =
  if px == ws.lastX and py == ws.lastY:
    inc ws.stuckTicks
    if ws.stuckTicks > 6:
      ws.useAltAxis = not ws.useAltAxis
      ws.stuckTicks = 0
  else:
    ws.stuckTicks = 0
    ws.useAltAxis = false
  ws.lastX = px
  ws.lastY = py

  let
    targetPx = targetTx * BotTileSize
    targetPy = targetTy * BotTileSize
    dx = targetPx - px
    dy = targetPy - py

  if ws.useAltAxis:
    if dy != 0:
      if dy < 0: buildMask(up = true) else: buildMask(down = true)
    elif dx != 0:
      if dx < 0: buildMask(left = true) else: buildMask(right = true)
    else:
      0'u8
  else:
    if abs(dx) > abs(dy):
      if dx < 0: buildMask(left = true) else: buildMask(right = true)
    elif dy != 0:
      if dy < 0: buildMask(up = true) else: buildMask(down = true)
    elif dx != 0:
      if dx < 0: buildMask(left = true) else: buildMask(right = true)
    else:
      0'u8

proc facingMask*(targetTx, targetTy, playerTx, playerTy: int): uint8 =
  let dx = targetTx - playerTx
  let dy = targetTy - playerTy
  if abs(dx) > abs(dy):
    if dx < 0: buildMask(left = true)
    else: buildMask(right = true)
  else:
    if dy < 0: buildMask(up = true)
    else: buildMask(down = true)

proc nearestObject*(state: GameState, kind: string, undepleted = true,
                    material = ""): Option[BotObject] =
  var bestDist = int.high
  var bestObj: BotObject
  var found = false
  for obj in state.objects:
    if obj.kind != kind: continue
    if undepleted and obj.depleted: continue
    if material.len > 0 and obj.material != material: continue
    let dist = manhattanDist(state.player.x, state.player.y, obj.tx, obj.ty)
    if dist < bestDist:
      bestDist = dist
      bestObj = obj
      found = true
  if found: some(bestObj) else: none(BotObject)

proc leastContestedNode*(state: GameState, kind: string, material: string): Option[BotObject] =
  var bestScore = int.high
  var bestObj: BotObject
  var found = false
  for obj in state.objects:
    if obj.kind != kind: continue
    if obj.depleted: continue
    if material.len > 0 and obj.material != material: continue
    let dist = manhattanDist(state.player.x, state.player.y, obj.tx, obj.ty)
    var penalty = 0
    for other in state.players:
      if other.state != "Gathering" and other.state != "Idle": continue
      let otherDist = abs((other.x + 3) div BotTileSize - obj.tx) +
                      abs((other.y + 3) div BotTileSize - obj.ty)
      if otherDist <= 3:
        penalty += (4 - otherDist) * 3
    let score = dist + penalty
    if score < bestScore:
      bestScore = score
      bestObj = obj
      found = true
  if found: some(bestObj) else: none(BotObject)

proc cheapestListing*(listings: seq[BotListing], item: string): Option[BotListing] =
  var best: BotListing
  var found = false
  for l in listings:
    if l.item != item or l.quantity <= 0: continue
    if not found or l.priceEach < best.priceEach:
      best = l
      found = true
  if found: some(best) else: none(BotListing)

proc allListings*(state: GameState): seq[BotListing] =
  result = state.npcListings & state.playerListings

proc botItemBasePrice*(item: string): int =
  case item
  of "WoodItem": 3
  of "StoneItem": 3
  of "HardwoodItem": 7
  of "CopperItem": 7
  of "IronwoodItem": 12
  of "IronItem": 12
  of "LeatherHat", "LeatherShirt", "LeatherGloves", "LeatherPants", "LeatherShoes": 15
  of "ChainHat", "ChainShirt", "ChainGloves", "ChainPants", "ChainShoes": 35
  of "PlateHat", "PlateShirt", "PlateGloves", "PlatePants", "PlateShoes": 70
  else: 3

proc cheapestPrice*(state: GameState, item: string): int =
  let all = state.allListings()
  let listing = cheapestListing(all, item)
  if listing.isSome: listing.get().priceEach else: int.high

proc highestPrice*(state: GameState, item: string): int =
  var best = 0
  for l in state.allListings():
    if l.item == item and l.quantity > 0 and l.priceEach > best:
      best = l.priceEach
  best

proc supplyCount*(state: GameState, item: string): int =
  for l in state.allListings():
    if l.item == item:
      result += l.quantity

proc visibleListings*(state: GameState, cachedListings: seq[BotListing]): seq[BotListing] =
  if state.player.state in ["AtBuyStall", "AtSellStall"]:
    state.allListings()
  else:
    cachedListings

proc cheapestPriceCached*(state: GameState, item: string, cached: seq[BotListing]): int =
  let listings = visibleListings(state, cached)
  let listing = cheapestListing(listings, item)
  if listing.isSome: listing.get().priceEach else: int.high

proc supplyCountCached*(state: GameState, item: string, cached: seq[BotListing]): int =
  for l in visibleListings(state, cached):
    if l.item == item:
      result += l.quantity

proc hasListingsCached*(state: GameState, item: string, cached: seq[BotListing]): bool =
  for l in visibleListings(state, cached):
    if l.item == item and l.quantity > 0: return true
  false

proc hasListings*(state: GameState, item: string): bool =
  for l in state.allListings():
    if l.item == item and l.quantity > 0: return true
  false

proc materialCostForGear*(state: GameState, tier: int = 1): int =
  var prices: seq[int]
  case tier
  of 1:
    prices.add cheapestPrice(state, "WoodItem")
    prices.add cheapestPrice(state, "StoneItem")
  of 2:
    prices.add cheapestPrice(state, "HardwoodItem")
    prices.add cheapestPrice(state, "CopperItem")
  of 3:
    prices.add cheapestPrice(state, "IronwoodItem")
    prices.add cheapestPrice(state, "IronItem")
  else:
    prices.add cheapestPrice(state, "WoodItem")
    prices.add cheapestPrice(state, "StoneItem")
  var cheapest = int.high
  for p in prices:
    if p < cheapest: cheapest = p
  if cheapest >= int.high div 3:
    return int.high
  cheapest * 3

proc gearSlotName*(index: int): string =
  case index
  of 0: "Hat"
  of 1: "Shirt"
  of 2: "Gloves"
  of 3: "Pants"
  of 4: "Shoes"
  else: "Unknown"

proc firstEmptyGearSlot*(player: BotPlayer): int =
  for i in 0 ..< GearSlotCount:
    if player.equippedGear[i] == "" or not isGearItem(player.equippedGear[i]):
      return i
  -1

const
  T1GearNames* = ["LeatherHat", "LeatherShirt", "LeatherGloves", "LeatherPants", "LeatherShoes"]
  T2GearNames* = ["ChainHat", "ChainShirt", "ChainGloves", "ChainPants", "ChainShoes"]
  T3GearNames* = ["PlateHat", "PlateShirt", "PlateGloves", "PlatePants", "PlateShoes"]

proc gearItemForSlot*(slot: int, tier: int = 1): string =
  case tier
  of 2: T2GearNames[slot.clamp(0, 4)]
  of 3: T3GearNames[slot.clamp(0, 4)]
  else: T1GearNames[slot.clamp(0, 4)]

proc gearTier*(name: string): int =
  if name in T1GearNames: 1
  elif name in T2GearNames: 2
  elif name in T3GearNames: 3
  else: 0

proc hasFullGearSet*(player: BotPlayer, tier: int): bool =
  for i in 0 ..< GearSlotCount:
    let gt = gearTier(player.equippedGear[i])
    if gt < tier: return false
  true

proc canGatherTier*(player: BotPlayer, tier: int): bool =
  if tier <= 1: return true
  player.hasFullGearSet(tier - 1)

proc highestGatherableTier*(player: BotPlayer): int =
  result = 1
  if player.hasFullGearSet(1): result = 2
  if player.hasFullGearSet(2): result = 3

proc itemCursorIndex*(item: string): int =
  for i, name in ItemNames:
    if name == item: return i
  0

proc hasAffordableGear*(state: GameState, player: BotPlayer, tier: int = 1): bool =
  let slot = firstEmptyGearSlot(player)
  if slot < 0: return false
  let all = state.allListings()
  let item = gearItemForSlot(slot, tier)
  let listing = cheapestListing(all, item)
  if listing.isSome and listing.get().priceEach <= player.gold:
    return true
  false

proc bestGearTier*(state: GameState, slot: int, gold: int): int =
  let all = state.allListings()
  for tier in [1, 2, 3]:
    let item = gearItemForSlot(slot, tier)
    let listing = cheapestListing(all, item)
    if listing.isSome and listing.get().priceEach <= gold:
      return tier
  1

proc nextGearTarget*(state: GameState, player: BotPlayer): tuple[slot: int, tier: int, item: string] =
  result = (-1, 0, "")
  let all = state.allListings()
  let hasT1 = player.hasFullGearSet(1)
  let hasT2 = player.hasFullGearSet(2)
  for goalTier in 1 .. 3:
    if goalTier == 2 and not hasT1: continue
    if goalTier == 3 and not hasT2: continue
    var bestSlot = -1
    var bestTier = 0
    var bestPrice = int.high
    for i in 0 ..< GearSlotCount:
      let currentTier = gearTier(player.equippedGear[i])
      if currentTier >= goalTier: continue
      for targetTier in goalTier .. 3:
        let item = gearItemForSlot(i, targetTier)
        let listing = cheapestListing(all, item)
        if listing.isSome and listing.get().priceEach < bestPrice:
          bestSlot = i
          bestTier = targetTier
          bestPrice = listing.get().priceEach
    if bestSlot >= 0:
      return (bestSlot, bestTier, gearItemForSlot(bestSlot, bestTier))
  if not hasT1:
    for i in 0 ..< GearSlotCount:
      let currentTier = gearTier(player.equippedGear[i])
      if currentTier >= 1: continue
      var bestTier = 0
      var bestPrice = int.high
      for targetTier in 1 .. 3:
        let item = gearItemForSlot(i, targetTier)
        let listing = cheapestListing(all, item)
        if listing.isSome and listing.get().priceEach < bestPrice:
          bestTier = targetTier
          bestPrice = listing.get().priceEach
      if bestTier > 0:
        return (i, bestTier, gearItemForSlot(i, bestTier))

proc hasAffordableGearUpgrade*(state: GameState, player: BotPlayer): bool =
  let target = nextGearTarget(state, player)
  if target.slot < 0: return false
  let all = state.allListings()
  let listing = cheapestListing(all, target.item)
  listing.isSome and listing.get().priceEach <= player.gold

proc nextGearTargetCached*(state: GameState, player: BotPlayer, cached: seq[BotListing]): tuple[slot: int, tier: int, item: string] =
  result = (-1, 0, "")
  let all = visibleListings(state, cached)
  let hasT1 = player.hasFullGearSet(1)
  let hasT2 = player.hasFullGearSet(2)
  for goalTier in 1 .. 3:
    if goalTier == 2 and not hasT1: continue
    if goalTier == 3 and not hasT2: continue
    var bestSlot = -1
    var bestTier = 0
    var bestPrice = int.high
    for i in 0 ..< GearSlotCount:
      let currentTier = gearTier(player.equippedGear[i])
      if currentTier >= goalTier: continue
      for targetTier in goalTier .. 3:
        let item = gearItemForSlot(i, targetTier)
        let listing = cheapestListing(all, item)
        if listing.isSome and listing.get().priceEach < bestPrice:
          bestSlot = i
          bestTier = targetTier
          bestPrice = listing.get().priceEach
    if bestSlot >= 0:
      return (bestSlot, bestTier, gearItemForSlot(bestSlot, bestTier))
  if not hasT1:
    for i in 0 ..< GearSlotCount:
      let currentTier = gearTier(player.equippedGear[i])
      if currentTier >= 1: continue
      var bestTier = 0
      var bestPrice = int.high
      for targetTier in 1 .. 3:
        let item = gearItemForSlot(i, targetTier)
        let listing = cheapestListing(all, item)
        if listing.isSome and listing.get().priceEach < bestPrice:
          bestTier = targetTier
          bestPrice = listing.get().priceEach
      if bestTier > 0:
        return (i, bestTier, gearItemForSlot(i, bestTier))

proc hasAffordableGearUpgradeCached*(state: GameState, player: BotPlayer, cached: seq[BotListing]): bool =
  let target = nextGearTargetCached(state, player, cached)
  if target.slot < 0: return false
  let listings = visibleListings(state, cached)
  let listing = cheapestListing(listings, target.item)
  listing.isSome and listing.get().priceEach <= player.gold

proc lowestNeededGearTier*(player: BotPlayer): int =
  if not player.hasFullGearSet(1): return 1
  if not player.hasFullGearSet(2): return 2
  if not player.hasFullGearSet(3): return 3
  0

proc materialsForTier*(tier: int): tuple[matA, matB: string] =
  case tier
  of 2: ("HardwoodItem", "CopperItem")
  of 3: ("IronwoodItem", "IronItem")
  else: ("WoodItem", "StoneItem")

proc bestAvailableCraftTier*(state: GameState, player: BotPlayer): int =
  let maxTier = highestGatherableTier(player)
  if maxTier >= 2 and hasFullGearSet(player, 1):
    let (matA, matB) = materialsForTier(maxTier)
    let hasA = hasListings(state, matA)
    let hasB = hasListings(state, matB)
    if hasA or hasB:
      let priceA = if hasA: cheapestPrice(state, matA) else: int.high
      let priceB = if hasB: cheapestPrice(state, matB) else: int.high
      if player.gold >= min(priceA, priceB):
        return maxTier
  for tier in countdown(maxTier, 1):
    let (matA, matB) = materialsForTier(tier)
    let hasA = hasListings(state, matA)
    let hasB = hasListings(state, matB)
    if hasA or hasB:
      let priceA = if hasA: cheapestPrice(state, matA) else: int.high
      let priceB = if hasB: cheapestPrice(state, matB) else: int.high
      if player.gold >= min(priceA, priceB):
        return tier
  1

proc bestUsefulCraftTier*(state: GameState, player: BotPlayer): int =
  let maxTier = highestGatherableTier(player)
  let minTier = lowestNeededGearTier(player)
  let floorTier = max(1, minTier)
  for tier in countdown(maxTier, floorTier):
    let (matA, matB) = materialsForTier(tier)
    let hasA = hasListings(state, matA)
    let hasB = hasListings(state, matB)
    if hasA or hasB:
      let priceA = if hasA: cheapestPrice(state, matA) else: int.high
      let priceB = if hasB: cheapestPrice(state, matB) else: int.high
      if player.gold >= min(priceA, priceB):
        return tier
  floorTier

proc demandAwareCraftTier*(state: GameState, player: BotPlayer): int =
  let maxTier = highestGatherableTier(player)
  let baseTier = bestAvailableCraftTier(state, player)
  if baseTier <= 1: return baseTier
  let all = state.allListings()
  for tier in 1 ..< baseTier:
    let (matA, matB) = materialsForTier(tier)
    let matSupply = supplyCount(state, matA) + supplyCount(state, matB)
    if matSupply < 3: continue
    let slotNames = case tier
      of 2: T2GearNames
      of 3: T3GearNames
      else: T1GearNames
    var gearSupply = 0
    for l in all:
      for s in 0 ..< GearSlotCount:
        if l.item == slotNames[s]:
          gearSupply += l.quantity
          break
    if gearSupply == 0:
      let priceA = if hasListings(state, matA): cheapestPrice(state, matA) else: int.high
      let priceB = if hasListings(state, matB): cheapestPrice(state, matB) else: int.high
      if player.gold >= min(priceA, priceB):
        return tier
  baseTier

proc canSellMore*(player: BotPlayer): bool =
  player.listings.len < BotMaxSellSlots

proc shouldCancelListings*(player: BotPlayer): bool =
  player.listings.len >= BotMaxSellSlots

proc hasLowTierListings*(player: BotPlayer): bool =
  let minNeeded = lowestNeededGearTier(player)
  if minNeeded <= 1: return false
  for l in player.listings:
    if l.item in ["WoodItem", "StoneItem"] and minNeeded >= 2: return true
    if l.item in ["HardwoodItem", "CopperItem"] and minNeeded >= 3: return true
    if isGearItem(l.item) and gearTier(l.item) < minNeeded: return true
  false

proc hasHighTierGearInv*(player: BotPlayer, minTier: int): bool =
  for name in GearItemNames:
    if player.inv.itemCount(name) > 0 and gearTier(name) >= minTier:
      return true
  false

proc shouldCancelStaleCrafterListings*(player: BotPlayer): bool =
  ## Cancel low-tier gear listings when slots are full and crafter can produce
  ## higher-tier gear (even if it hasn't crafted it yet).
  let maxTier = highestGatherableTier(player)
  if maxTier <= 1: return false
  if player.listings.len < BotMaxSellSlots: return false
  var lowTierCount = 0
  for l in player.listings:
    if isGearItem(l.item) and gearTier(l.item) < maxTier:
      inc lowTierCount
  lowTierCount >= 3

proc hasOnlyLowTierGearInv*(player: BotPlayer, targetTier: int): bool =
  if targetTier <= 1: return false
  for name in GearItemNames:
    if player.inv.itemCount(name) > 0:
      if gearTier(name) >= targetTier: return false
  true

proc shouldCancelForUpgrade*(player: BotPlayer): bool =
  hasFullGearSet(player, 1) and player.listings.len > 0 and hasLowTierListings(player)

proc hasHighTierMaterials*(inv: BotInventory, minTier: int): bool =
  if minTier <= 2:
    if inv.hardwood > 0 or inv.copper > 0: return true
  if minTier <= 3:
    if inv.ironwood > 0 or inv.iron > 0: return true
  false

proc hasOnlyLowTierMaterials*(player: BotPlayer): bool =
  let maxTier = highestGatherableTier(player)
  if maxTier <= 1: return false
  let hasLow = player.inv.wood > 0 or player.inv.stone > 0
  let hasHigh = player.inv.hardwood > 0 or player.inv.copper > 0 or
                player.inv.ironwood > 0 or player.inv.iron > 0
  hasLow and not hasHigh

proc firstGearSellCursor*(player: BotPlayer, minTier: int = 1): int =
  var idx = 0
  var bestIdx = -1
  var bestTier = 0
  for i, name in ItemNames:
    if player.inv.itemCount(name) > 0:
      if isGearItem(name):
        let tier = gearTier(name)
        if tier >= minTier and tier > bestTier:
          bestTier = tier
          bestIdx = idx
      inc idx
  bestIdx

proc sellCursorItemName*(player: BotPlayer): string =
  var idx = 0
  for i, name in ItemNames:
    if player.inv.itemCount(name) > 0:
      if idx == player.sellItemCursor:
        return name
      inc idx
  "LeatherHat"

proc isSellableAtTier*(itemName: string, maxTier: int): bool =
  if maxTier >= 3:
    return itemName in ["IronwoodItem", "IronItem"]
  elif maxTier >= 2:
    return itemName in ["HardwoodItem", "CopperItem", "IronwoodItem", "IronItem"]
  else:
    return itemName in RawMaterialNames

proc nextSellCursorForTier*(player: BotPlayer): int =
  let maxTier = highestGatherableTier(player)
  var idx = 0
  for i, name in ItemNames:
    if player.inv.itemCount(name) > 0:
      if isSellableAtTier(name, maxTier):
        return idx
      inc idx
  -1

proc bestSellCursor*(player: BotPlayer): int =
  let maxTier = highestGatherableTier(player)
  var idx = 0
  var bestIdx = -1
  var bestValue = 0
  for i, name in ItemNames:
    if player.inv.itemCount(name) > 0:
      if isSellableAtTier(name, maxTier) or isGearItem(name):
        let value = botItemBasePrice(name)
        if value > bestValue:
          bestValue = value
          bestIdx = idx
      inc idx
  bestIdx

proc canAffordAnyMaterial*(state: GameState, player: BotPlayer): bool =
  for tier in countdown(3, 1):
    let (matA, matB) = materialsForTier(tier)
    if hasListings(state, matA) and cheapestPrice(state, matA) <= player.gold:
      return true
    if hasListings(state, matB) and cheapestPrice(state, matB) <= player.gold:
      return true
  false

proc canAffordUsefulMaterial*(state: GameState, player: BotPlayer): bool =
  let minTier = lowestNeededGearTier(player)
  if minTier == 0: return false
  for tier in countdown(3, minTier):
    let (matA, matB) = materialsForTier(tier)
    if hasListings(state, matA) and cheapestPrice(state, matA) <= player.gold:
      return true
    if hasListings(state, matB) and cheapestPrice(state, matB) <= player.gold:
      return true
  false

proc hasEnoughMaterialsForUsefulCraft*(player: BotPlayer): bool =
  let minTier = lowestNeededGearTier(player)
  if minTier == 0: return false
  case minTier
  of 3: player.inv.ironwood >= 3 or player.inv.iron >= 3
  of 2: player.inv.hardwood >= 3 or player.inv.copper >= 3 or
        player.inv.ironwood >= 3 or player.inv.iron >= 3
  else: player.inv.wood >= 3 or player.inv.stone >= 3 or
        player.inv.hardwood >= 3 or player.inv.copper >= 3 or
        player.inv.ironwood >= 3 or player.inv.iron >= 3

proc craftRecipeMaterialName*(gearName: string): string =
  case gearName
  of "LeatherHat", "LeatherGloves", "LeatherShoes": "WoodItem"
  of "LeatherShirt", "LeatherPants": "StoneItem"
  of "ChainHat", "ChainGloves", "ChainShoes": "CopperItem"
  of "ChainShirt", "ChainPants": "HardwoodItem"
  of "PlateHat", "PlateGloves", "PlateShoes": "IronItem"
  of "PlateShirt", "PlatePants": "IronwoodItem"
  else: "WoodItem"

proc neededCraftMaterial*(player: BotPlayer): string =
  let minTier = lowestNeededGearTier(player)
  if minTier == 0: return ""
  for slot in 0 ..< GearSlotCount:
    let currentTier = gearTier(player.equippedGear[slot])
    if currentTier < minTier:
      let gearName = gearItemForSlot(slot, minTier)
      return craftRecipeMaterialName(gearName)
  ""

proc marketNeedsCraftTier*(state: GameState, player: BotPlayer): int =
  let all = state.allListings()
  let maxTier = highestGatherableTier(player)
  for tier in 1 .. maxTier:
    var totalSupply = 0
    for s in 0 ..< GearSlotCount:
      let gearName = gearItemForSlot(s, tier)
      for l in all:
        if l.item == gearName:
          totalSupply += l.quantity
    if totalSupply == 0:
      return tier
  maxTier

proc underSuppliedMaterial*(player: BotPlayer, state: GameState, tier: int): string =
  let (matA, matB) = materialsForTier(tier)
  let slotNames = case tier
    of 2: T2GearNames
    of 3: T3GearNames
    else: T1GearNames
  let all = state.allListings()
  var matAMarket, matBMarket = 0
  for l in all:
    for s in 0 ..< GearSlotCount:
      if l.item == slotNames[s]:
        let mat = craftRecipeMaterialName(l.item)
        if mat == matA: inc matAMarket
        elif mat == matB: inc matBMarket
        break
  for i in 0 ..< GearSlotCount:
    let gearName = slotNames[i]
    if player.inv.itemCount(gearName) > 0:
      let mat = craftRecipeMaterialName(gearName)
      if mat == matA: inc matAMarket
      elif mat == matB: inc matBMarket
  if matBMarket < matAMarket: matB
  elif matAMarket < matBMarket: matA
  else: ""

proc hasAnyRawMaterials*(inv: BotInventory): bool =
  inv.wood > 0 or inv.stone > 0 or inv.hardwood > 0 or
  inv.copper > 0 or inv.ironwood > 0 or inv.iron > 0

proc hasSellableMaterials*(player: BotPlayer): bool =
  let maxTier = highestGatherableTier(player)
  if maxTier >= 3:
    return player.inv.ironwood > 0 or player.inv.iron > 0
  elif maxTier >= 2:
    return player.inv.hardwood > 0 or player.inv.copper > 0 or
           player.inv.ironwood > 0 or player.inv.iron > 0
  else:
    return player.inv.wood > 0 or player.inv.stone > 0

proc hasEnoughMaterialsForCraft*(inv: BotInventory): bool =
  inv.wood >= 3 or inv.stone >= 3 or inv.hardwood >= 3 or
  inv.copper >= 3 or inv.ironwood >= 3 or inv.iron >= 3

proc shouldSwitchToCrafter*(state: GameState, player: BotPlayer): bool =
  if player.hasFullGearSet(3): return false
  let target = nextGearTarget(state, player)
  if target.slot >= 0: return false
  hasEnoughMaterialsForCraft(player.inv)

proc materialForCraftStation*(slot: int, tier: int): string =
  let gearName = gearItemForSlot(slot, tier)
  craftRecipeMaterialName(gearName)

proc hasMaterialsForStation*(inv: BotInventory, slot: int, tier: int): bool =
  let mat = materialForCraftStation(slot, tier)
  inv.itemCount(mat) >= 3

proc bestCraftStation*(state: GameState, player: BotPlayer): Option[BotObject] =
  var supplyCount: array[3, array[5, int]]
  let all = state.allListings()
  for l in all:
    let t = gearTier(l.item)
    if t == 0: continue
    for s in 0 ..< GearSlotCount:
      if l.item == gearItemForSlot(s, t):
        supplyCount[t - 1][s] += l.quantity
        break
  for s in 0 ..< GearSlotCount:
    for t in 1 .. 3:
      let gearName = gearItemForSlot(s, t)
      supplyCount[t - 1][s] += player.inv.itemCount(gearName)

  var selfNeedSlot = -1
  var selfNeedTier = 0
  let needed = lowestNeededGearTier(player)
  if needed > 0 and needed <= highestGatherableTier(player):
    for s in 0 ..< GearSlotCount:
      if gearTier(player.equippedGear[s]) < needed:
        selfNeedSlot = s
        selfNeedTier = needed
        break

  var bestObj: BotObject
  var bestScore = int.high
  var found = false
  let rotation = (state.tick div 500) mod GearSlotCount
  for obj in state.objects:
    if obj.kind != "CraftStationObj": continue
    if not player.inv.hasMaterialsForStation(obj.craftSlot, obj.craftTier):
      continue
    if obj.craftTier >= 2 and not player.hasFullGearSet(obj.craftTier - 1):
      continue
    if obj.craftSlot == selfNeedSlot and obj.craftTier == selfNeedTier:
      return some(obj)
    let supply = supplyCount[obj.craftTier - 1][obj.craftSlot]
    let tieBreak = (obj.craftSlot + GearSlotCount - rotation) mod GearSlotCount
    let score = supply * 100 + tieBreak
    if score < bestScore:
      bestScore = score
      bestObj = obj
      found = true
  if found: some(bestObj) else: none(BotObject)

proc preferredMaterial*(baseMaterial: string, tier: int): string =
  case baseMaterial
  of "WoodItem":
    case tier
    of 2: "HardwoodItem"
    of 3: "IronwoodItem"
    else: "WoodItem"
  of "StoneItem":
    case tier
    of 2: "CopperItem"
    of 3: "IronItem"
    else: "StoneItem"
  else: ""

proc nearestGatherableNode*(state: GameState, player: BotPlayer,
                            preferMaterial: string = "",
                            cachedListings: seq[BotListing] = @[]): Option[BotObject] =
  let maxTier = highestGatherableTier(player)
  if preferMaterial.len > 0 and maxTier <= 1:
    let baseNode = leastContestedNode(state, "GatherNodeObj", preferMaterial)
    if baseNode.isSome: return baseNode
  var targetTier = maxTier
  if maxTier >= 2 and not player.canSellMore:
    for lower in 1 ..< maxTier:
      let (lowA, lowB) = materialsForTier(lower)
      let lowSupply = supplyCountCached(state, lowA, cachedListings) +
                      supplyCountCached(state, lowB, cachedListings)
      if lowSupply == 0:
        targetTier = lower
        break
  for tier in countdown(targetTier, 1):
    let (matA, matB) = materialsForTier(tier)
    if preferMaterial.len > 0:
      let preferred = preferredMaterial(preferMaterial, tier)
      let node = leastContestedNode(state, "GatherNodeObj", preferred)
      if node.isSome: return node
    let supA = supplyCountCached(state, matA, cachedListings)
    let supB = supplyCountCached(state, matB, cachedListings)
    let (first, second) = if supB < supA: (matB, matA) else: (matA, matB)
    let nodeFirst = leastContestedNode(state, "GatherNodeObj", first)
    if nodeFirst.isSome: return nodeFirst
    let nodeSecond = leastContestedNode(state, "GatherNodeObj", second)
    if nodeSecond.isSome: return nodeSecond
  none(BotObject)

# ── A* Pathfinding ──

const
  MapWidth* = 48
  MapHeight* = 48

type
  TilePos* = tuple[tx, ty: int]

  PathNode = object
    pos: TilePos
    gCost: int
    hCost: int
    parent: int

  Navigator* = object
    path*: seq[TilePos]
    pathIndex*: int
    blocked: set[uint16]
    lastPx, lastPy: int
    stuckTicks: int
    useAltAxis: bool

proc fCost(node: PathNode): int = node.gCost + node.hCost
proc `<`(a, b: PathNode): bool = a.fCost < b.fCost

proc tileKey(tx, ty: int): uint16 =
  uint16(ty * MapWidth + tx)

proc buildCollisionMap*(state: GameState): Navigator =
  for tx in 0 ..< MapWidth:
    result.blocked.incl tileKey(tx, 0)
    result.blocked.incl tileKey(tx, MapHeight - 1)
  for ty in 1 ..< MapHeight - 1:
    result.blocked.incl tileKey(0, ty)
    result.blocked.incl tileKey(MapWidth - 1, ty)
  for obj in state.objects:
    if obj.kind != "GatherNodeObj":
      result.blocked.incl tileKey(obj.tx, obj.ty)

proc isWalkable(nav: Navigator, tx, ty: int): bool =
  if tx < 0 or ty < 0 or tx >= MapWidth or ty >= MapHeight:
    return false
  tileKey(tx, ty) notin nav.blocked

proc findPath*(nav: Navigator, startTx, startTy, goalTx, goalTy: int): seq[TilePos] =
  if startTx == goalTx and startTy == goalTy:
    return @[(startTx, startTy)]
  # Allow pathfinding TO a blocked tile (we want to get adjacent)
  var openHeap = initHeapQueue[PathNode]()
  openHeap.push PathNode(
    pos: (startTx, startTy),
    gCost: 0,
    hCost: abs(startTx - goalTx) + abs(startTy - goalTy),
    parent: -1
  )
  var closedSet = initHashSet[uint16]()
  var allNodes: seq[PathNode]

  while openHeap.len > 0:
    let current = openHeap.pop()
    let key = tileKey(current.pos.tx, current.pos.ty)
    if key in closedSet:
      continue
    closedSet.incl key
    let currentIdx = allNodes.len
    allNodes.add current

    if current.pos.tx == goalTx and current.pos.ty == goalTy:
      var path: seq[TilePos]
      var idx = currentIdx
      while idx >= 0:
        path.add allNodes[idx].pos
        idx = allNodes[idx].parent
      # Reverse to get start->goal order
      for i in 0 ..< path.len div 2:
        swap(path[i], path[path.len - 1 - i])
      return path

    const dirs = [(0, -1), (0, 1), (-1, 0), (1, 0)]
    for (dx, dy) in dirs:
      let nx = current.pos.tx + dx
      let ny = current.pos.ty + dy
      let nkey = tileKey(nx, ny)
      if nkey in closedSet: continue
      # Allow walking to the goal tile even if blocked (for adjacent interaction)
      let isGoal = (nx == goalTx and ny == goalTy)
      if not isGoal and not nav.isWalkable(nx, ny): continue
      if nx < 0 or ny < 0 or nx >= MapWidth or ny >= MapHeight: continue
      openHeap.push PathNode(
        pos: (nx, ny),
        gCost: current.gCost + 1,
        hCost: abs(nx - goalTx) + abs(ny - goalTy),
        parent: currentIdx
      )
  @[]

proc findPathAdjacent*(nav: Navigator, startTx, startTy, goalTx, goalTy: int): seq[TilePos] =
  ## Find path to a tile adjacent to the goal (for interacting with collision objects).
  var bestPath: seq[TilePos]
  var bestLen = int.high
  const dirs = [(0, -1), (0, 1), (-1, 0), (1, 0)]
  for (dx, dy) in dirs:
    let adjTx = goalTx + dx
    let adjTy = goalTy + dy
    if not nav.isWalkable(adjTx, adjTy): continue
    let path = nav.findPath(startTx, startTy, adjTx, adjTy)
    if path.len > 0 and path.len < bestLen:
      bestPath = path
      bestLen = path.len
  bestPath

proc navigateTo*(nav: var Navigator, state: GameState, targetTx, targetTy: int) =
  ## Compute a path from current player position to target tile.
  nav = buildCollisionMap(state)
  let path = nav.findPath(state.player.tx, state.player.ty, targetTx, targetTy)
  nav.path = path
  nav.pathIndex = if path.len > 1: 1 else: 0

proc navigateAdjacent*(nav: var Navigator, state: GameState, targetTx, targetTy: int) =
  ## Compute a path to a tile adjacent to the target (for collision objects).
  nav = buildCollisionMap(state)
  let path = nav.findPathAdjacent(state.player.tx, state.player.ty, targetTx, targetTy)
  nav.path = path
  nav.pathIndex = if path.len > 1: 1 else: 0

proc followPath*(nav: var Navigator, px, py: int): uint8 =
  if nav.path.len == 0 or nav.pathIndex >= nav.path.len:
    return 0'u8
  let target = nav.path[nav.pathIndex]
  if isOnTile(px, py, target.tx, target.ty):
    inc nav.pathIndex
    nav.stuckTicks = 0
    nav.useAltAxis = false
    if nav.pathIndex >= nav.path.len:
      return 0'u8
    return nav.followPath(px, py)

  if px == nav.lastPx and py == nav.lastPy:
    inc nav.stuckTicks
    if nav.stuckTicks > 12:
      nav.useAltAxis = not nav.useAltAxis
      nav.stuckTicks = 0
  else:
    nav.stuckTicks = 0
    nav.useAltAxis = false
  nav.lastPx = px
  nav.lastPy = py

  let
    targetPx = target.tx * BotTileSize
    targetPy = target.ty * BotTileSize
    dx = targetPx - px
    dy = targetPy - py

  if nav.useAltAxis:
    if abs(dx) > abs(dy):
      if dy != 0:
        if dy < 0: buildMask(up = true) else: buildMask(down = true)
      elif dx != 0:
        if dx < 0: buildMask(left = true) else: buildMask(right = true)
      else: 0'u8
    else:
      if dx != 0:
        if dx < 0: buildMask(left = true) else: buildMask(right = true)
      elif dy != 0:
        if dy < 0: buildMask(up = true) else: buildMask(down = true)
      else: 0'u8
  else:
    walkToward(px, py, target.tx, target.ty)

proc hasPath*(nav: Navigator): bool =
  nav.path.len > 0 and nav.pathIndex < nav.path.len

proc pathTarget*(nav: Navigator): TilePos =
  if nav.path.len > 0:
    nav.path[^1]
  else:
    (0, 0)

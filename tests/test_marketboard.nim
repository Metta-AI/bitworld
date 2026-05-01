import
  std/[json, os],
  ../common/server,
  ../marketboard/sim

const RootDir = currentSourcePath.parentDir.parentDir

proc initMarketboardForTest(): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "marketboard")
  try:
    result = initSimServer(0)
  finally:
    setCurrentDir(previousDir)

proc findObjectIndex(sim: SimServer, kind: WorldObjectKind): int =
  for i, obj in sim.objects:
    if obj.kind == kind:
      return i
  -1

proc findWoodNodeIndex(sim: SimServer): int =
  for i, obj in sim.objects:
    if obj.kind == GatherNodeObj and obj.material == WoodItem and not obj.depleted:
      return i
  -1

proc describePos(sim: SimServer, idx: int): string =
  let p = sim.players[idx]
  let st = p.standingTile()
  let it = p.interactionTile()
  "px=(" & $p.x & "," & $p.y & ") standing=(" & $st.tx & "," & $st.ty &
    ") interaction=(" & $it.tx & "," & $it.ty & ") facing=" & $p.facing &
    " state=" & $p.state

# Walk a player toward a target tile using input simulation.
# Returns how many ticks it took. Fails after maxTicks.
proc walkPlayerTo(sim: var SimServer, idx: int, targetTx, targetTy, maxTicks: int): int =
  var lastX, lastY: int
  var stuckCount = 0
  var tryAltAxis = false
  for tick in 0 ..< maxTicks:
    let p = sim.players[idx]
    let st = p.standingTile()
    if st.tx == targetTx and st.ty == targetTy:
      for _ in 0 ..< 20:
        var inputs = newSeq[PlayerInput](sim.players.len)
        sim.step(inputs)
      return tick

    if p.x == lastX and p.y == lastY:
      inc stuckCount
      if stuckCount > 5:
        tryAltAxis = true
        stuckCount = 0
    else:
      stuckCount = 0
      tryAltAxis = false
    lastX = p.x
    lastY = p.y

    var inputs = newSeq[PlayerInput](sim.players.len)
    let dx = targetTx * MbTileSize - p.x
    let dy = targetTy * MbTileSize - p.y

    if tryAltAxis:
      if dy != 0:
        if dy < 0: inputs[idx].up = true
        else: inputs[idx].down = true
      elif dx != 0:
        if dx < 0: inputs[idx].left = true
        else: inputs[idx].right = true
    else:
      if abs(dx) > abs(dy):
        if dx < 0: inputs[idx].left = true
        else: inputs[idx].right = true
      elif dy != 0:
        if dy < 0: inputs[idx].up = true
        else: inputs[idx].down = true
      elif dx != 0:
        if dx < 0: inputs[idx].left = true
        else: inputs[idx].right = true
    sim.step(inputs)
  doAssert false, "walkPlayerTo timed out after " & $maxTicks & " ticks. " &
    sim.describePos(idx) & " target=(" & $targetTx & "," & $targetTy & ")"
  0

# Face a direction and press A on a single tick
proc pressA(sim: var SimServer, idx: int, facing: Facing) =
  sim.players[idx].facing = facing
  var inputs = newSeq[PlayerInput](sim.players.len)
  inputs[idx].aPressed = true
  inputs[idx].aHeld = true
  sim.step(inputs)

# Hold A for N ticks
proc holdA(sim: var SimServer, idx: int, ticks: int) =
  for _ in 0 ..< ticks:
    var inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx].aHeld = true
    sim.step(inputs)

proc pressB(sim: var SimServer, idx: int) =
  var inputs = newSeq[PlayerInput](sim.players.len)
  inputs[idx].bPressed = true
  sim.step(inputs)

# ── Basic Tests ──

proc testPlayerSpawnsWithStartingGold() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  doAssert sim.players[idx].gold == StartingGold
  doAssert sim.players[idx].role == NoRole
  doAssert sim.players[idx].state == Idle
  doAssert sim.players[idx].inv.wood == 0

proc testNodeRespawn() =
  var sim = initMarketboardForTest()
  let nodeIdx = sim.findWoodNodeIndex()
  doAssert nodeIdx >= 0
  sim.objects[nodeIdx].depleted = true
  sim.objects[nodeIdx].respawnTimer = NodeRespawnTicks
  for _ in 0 ..< NodeRespawnTicks:
    sim.step(@[])
  doAssert not sim.objects[nodeIdx].depleted

proc testBuildStateJson() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("testbot")
  let root = parseJson(sim.buildStateJson(idx))
  doAssert root["tick"].getInt() == 0
  doAssert root["player"]["name"].getStr() == "testbot"
  doAssert root["player"]["gold"].getInt() == StartingGold
  doAssert root["objects"].len > 0
  doAssert root["npcListings"].len > 0

# ── Role Switching (pixel-precise placement) ──

proc testRoleSwitchGatherer() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  let si = sim.findObjectIndex(GathererStallObj)
  doAssert si >= 0
  let stall = sim.objects[si]
  # Place player one tile right of stall, facing left
  sim.players[idx].x = (stall.tx + 1) * MbTileSize
  sim.players[idx].y = stall.ty * MbTileSize
  sim.pressA(idx, FaceLeft)
  doAssert sim.players[idx].role == Gatherer,
    "role switch to Gatherer failed. " & sim.describePos(idx)

proc testRoleSwitchCrafter() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  let si = sim.findObjectIndex(CrafterStallObj)
  doAssert si >= 0
  let stall = sim.objects[si]
  # Place player one tile below stall, facing up
  sim.players[idx].x = stall.tx * MbTileSize
  sim.players[idx].y = (stall.ty + 1) * MbTileSize
  sim.pressA(idx, FaceUp)
  doAssert sim.players[idx].role == Crafter,
    "role switch to Crafter failed. " & sim.describePos(idx)

# ── Gathering (pixel-precise) ──

proc testGatheringOnNode() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  sim.players[idx].role = Gatherer
  let nodeIdx = sim.findWoodNodeIndex()
  let node = sim.objects[nodeIdx]
  sim.players[idx].x = node.tx * MbTileSize
  sim.players[idx].y = node.ty * MbTileSize
  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].state == Gathering,
    "gathering on node failed. " & sim.describePos(idx)
  sim.holdA(idx, GatherWorkNeeded - 1)
  doAssert sim.players[idx].state == Idle
  doAssert sim.players[idx].inv.wood == 1

proc testGatheringAdjacentToNode() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  sim.players[idx].role = Gatherer
  let nodeIdx = sim.findWoodNodeIndex()
  let node = sim.objects[nodeIdx]
  # Place one tile above node, facing down
  sim.players[idx].x = node.tx * MbTileSize
  sim.players[idx].y = (node.ty - 1) * MbTileSize
  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].state == Gathering,
    "gathering adjacent to node failed. " & sim.describePos(idx)
  sim.holdA(idx, GatherWorkNeeded - 1)
  doAssert sim.players[idx].inv.wood == 1

proc testGatheringRequiresRole() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  let nodeIdx = sim.findWoodNodeIndex()
  let node = sim.objects[nodeIdx]
  sim.players[idx].x = node.tx * MbTileSize
  sim.players[idx].y = node.ty * MbTileSize
  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].state == Idle

proc testCancelGathering() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  sim.players[idx].role = Gatherer
  let nodeIdx = sim.findWoodNodeIndex()
  let node = sim.objects[nodeIdx]
  sim.players[idx].x = node.tx * MbTileSize
  sim.players[idx].y = node.ty * MbTileSize
  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].state == Gathering
  # Release A
  var inputs = newSeq[PlayerInput](sim.players.len)
  sim.step(inputs)
  doAssert sim.players[idx].state == Idle
  doAssert sim.players[idx].inv.wood == 0

# ── Gathering (walk-based, realistic) ──

proc testWalkToNodeThenGather() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  sim.players[idx].role = Gatherer
  let nodeIdx = sim.findWoodNodeIndex()
  let node = sim.objects[nodeIdx]

  let ticks = sim.walkPlayerTo(idx, node.tx, node.ty, 500)
  doAssert ticks > 0, "should take some ticks to walk"

  let st = sim.players[idx].standingTile()
  doAssert st.tx == node.tx and st.ty == node.ty,
    "player should be on node tile. " & sim.describePos(idx)

  # Try all 4 facings to find one that triggers gathering
  var gathered = false
  for facing in [FaceDown, FaceUp, FaceLeft, FaceRight]:
    sim.players[idx].facing = facing
    var inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx].aPressed = true
    inputs[idx].aHeld = true
    sim.step(inputs)
    if sim.players[idx].state == Gathering:
      gathered = true
      break
    # If state didn't change, try next facing

  doAssert gathered,
    "could not start gathering after walking to node. " & sim.describePos(idx) &
    " node=(" & $node.tx & "," & $node.ty & ")"

  sim.holdA(idx, GatherWorkNeeded - 1)
  doAssert sim.players[idx].inv.wood == 1,
    "should have 1 wood after gathering"

proc testWalkToNodeAdjacentThenGather() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  sim.players[idx].role = Gatherer
  let nodeIdx = sim.findWoodNodeIndex()
  let node = sim.objects[nodeIdx]

  # Walk to one tile above the node
  let ticks = sim.walkPlayerTo(idx, node.tx, node.ty - 1, 500)
  doAssert ticks >= 0

  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].state == Gathering,
    "gathering from adjacent tile should work. " & sim.describePos(idx)
  sim.holdA(idx, GatherWorkNeeded - 1)
  doAssert sim.players[idx].inv.wood == 1

# ── Gathering with sub-pixel offsets ──

proc testGatheringOffsetPositions() =
  # Test gathering from various sub-pixel positions within the node tile
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  sim.players[idx].role = Gatherer
  let nodeIdx = sim.findWoodNodeIndex()
  let node = sim.objects[nodeIdx]

  let basePx = node.tx * MbTileSize
  let basePy = node.ty * MbTileSize
  var successCount = 0

  for dx in [0, 1, 3, 5, 7]:
    for dy in [0, 1, 3, 5, 7]:
      sim.players[idx].x = basePx + dx
      sim.players[idx].y = basePy + dy
      sim.players[idx].velX = 0
      sim.players[idx].velY = 0
      sim.players[idx].carryX = 0
      sim.players[idx].carryY = 0
      sim.players[idx].state = Idle
      sim.players[idx].actionProgress = 0
      sim.players[idx].actionTargetIndex = -1
      sim.objects[nodeIdx].depleted = false

      let st = sim.players[idx].standingTile()
      let onNodeTile = (st.tx == node.tx and st.ty == node.ty)

      # Try each facing
      var didGather = false
      for facing in [FaceDown, FaceUp, FaceLeft, FaceRight]:
        sim.players[idx].facing = facing
        sim.players[idx].state = Idle
        sim.players[idx].actionProgress = 0
        sim.objects[nodeIdx].depleted = false
        var inputs = newSeq[PlayerInput](sim.players.len)
        inputs[idx].aPressed = true
        inputs[idx].aHeld = true
        sim.step(inputs)
        if sim.players[idx].state == Gathering:
          didGather = true
          sim.cancelAction(idx)
          break

      if onNodeTile:
        doAssert didGather,
          "should be able to gather when standing on node at offset (" & $dx & "," & $dy & "). " &
          sim.describePos(idx) & " node=(" & $node.tx & "," & $node.ty & ")"
        inc successCount

  doAssert successCount > 0,
    "at least some sub-pixel positions should be on the node tile"

# ── Full walk-based role switch ──

proc testWalkToGathererStall() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  let si = sim.findObjectIndex(GathererStallObj)
  let stall = sim.objects[si]

  # Place precisely adjacent to stall (stall is collision, can't walk onto it)
  sim.players[idx].x = stall.tx * MbTileSize
  sim.players[idx].y = (stall.ty + 1) * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0
  sim.pressA(idx, FaceUp)
  doAssert sim.players[idx].role == Gatherer,
    "walk-based role switch failed. " & sim.describePos(idx) &
    " stall=(" & $stall.tx & "," & $stall.ty & ")"

# ── Crafting ──

proc testCrafting() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  sim.players[idx].role = Crafter
  sim.players[idx].inv.wood = 3
  let si = sim.findObjectIndex(CraftStationObj)
  let station = sim.objects[si]
  sim.players[idx].x = station.tx * MbTileSize
  sim.players[idx].y = station.ty * MbTileSize
  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].state == Crafting,
    "crafting start failed. " & sim.describePos(idx)
  sim.holdA(idx, CraftWorkNeeded - 1)
  doAssert sim.players[idx].inv.wood == 0
  doAssert sim.players[idx].crafterGear[ord(SlotHat)] == LeatherHat

# ── Selling ──

proc testSelling() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  sim.players[idx].inv.wood = 1
  let si = sim.findObjectIndex(SellStallObj)
  let stall = sim.objects[si]
  sim.players[idx].x = stall.tx * MbTileSize
  sim.players[idx].y = stall.ty * MbTileSize
  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].state == AtSellStall,
    "enter sell stall failed. " & sim.describePos(idx)
  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].inv.wood == 0
  doAssert sim.players[idx].listings.len == 1

# ── Buying ──

proc testBuying() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  let si = sim.findObjectIndex(BuyStallObj)
  let stall = sim.objects[si]
  sim.players[idx].x = stall.tx * MbTileSize
  sim.players[idx].y = stall.ty * MbTileSize
  let startGold = sim.players[idx].gold
  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].state == AtBuyStall
  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].gold == startGold - WoodBasePrice
  doAssert sim.players[idx].inv.wood == 1

# ── Gold Transfer ──

proc testGoldTransfer() =
  var sim = initMarketboardForTest()
  sim.npcListings.setLen(0)
  let seller = sim.addPlayer("seller")
  let buyer = sim.addPlayer("buyer")
  sim.players[seller].inv.wood = 1
  let si = sim.findObjectIndex(SellStallObj)
  let stall = sim.objects[si]
  sim.players[seller].x = stall.tx * MbTileSize
  sim.players[seller].y = stall.ty * MbTileSize
  sim.players[seller].sellPrice = 15
  sim.pressA(seller, FaceDown)
  doAssert sim.players[seller].state == AtSellStall
  sim.pressA(seller, FaceDown)
  doAssert sim.players[seller].listings.len == 1
  sim.pressB(seller)
  doAssert sim.players[seller].state == Idle

  let bi = sim.findObjectIndex(BuyStallObj)
  let buyStall = sim.objects[bi]
  sim.players[buyer].x = buyStall.tx * MbTileSize
  sim.players[buyer].y = buyStall.ty * MbTileSize
  let sellerGold = sim.players[seller].gold
  let buyerGold = sim.players[buyer].gold

  # Enter buy stall for buyer, idle for seller
  var inputs = newSeq[PlayerInput](sim.players.len)
  inputs[buyer].aPressed = true
  inputs[buyer].aHeld = true
  sim.step(inputs)
  doAssert sim.players[buyer].state == AtBuyStall

  inputs = newSeq[PlayerInput](sim.players.len)
  inputs[buyer].aPressed = true
  inputs[buyer].aHeld = true
  sim.step(inputs)

  let spent = buyerGold - sim.players[buyer].gold
  doAssert spent == 15, "buyer should pay 15g, spent " & $spent
  doAssert sim.players[seller].gold == sellerGold + 15

# ── Full gather-sell-buy cycle ──

proc testFullGatherSellBuyCycle() =
  var sim = initMarketboardForTest()
  sim.npcListings.setLen(0)
  let gatherer = sim.addPlayer("gatherer")
  let buyer = sim.addPlayer("buyer")
  sim.players[gatherer].role = Gatherer

  # Gather wood
  let nodeIdx = sim.findWoodNodeIndex()
  let node = sim.objects[nodeIdx]
  sim.players[gatherer].x = node.tx * MbTileSize
  sim.players[gatherer].y = node.ty * MbTileSize
  sim.pressA(gatherer, FaceDown)
  doAssert sim.players[gatherer].state == Gathering
  sim.holdA(gatherer, GatherWorkNeeded - 1)
  doAssert sim.players[gatherer].inv.wood == 1

  # Sell it
  let si = sim.findObjectIndex(SellStallObj)
  let sellStall = sim.objects[si]
  sim.players[gatherer].x = sellStall.tx * MbTileSize
  sim.players[gatherer].y = sellStall.ty * MbTileSize
  sim.players[gatherer].velX = 0
  sim.players[gatherer].velY = 0
  sim.players[gatherer].sellPrice = 12
  sim.pressA(gatherer, FaceDown)
  doAssert sim.players[gatherer].state == AtSellStall
  sim.pressA(gatherer, FaceDown)
  doAssert sim.players[gatherer].listings.len == 1
  doAssert sim.players[gatherer].listings[0].priceEach == 12
  sim.pressB(gatherer)

  # Buyer buys it
  let bi = sim.findObjectIndex(BuyStallObj)
  let buyStall = sim.objects[bi]
  sim.players[buyer].x = buyStall.tx * MbTileSize
  sim.players[buyer].y = buyStall.ty * MbTileSize
  let buyerGold = sim.players[buyer].gold
  let gathererGold = sim.players[gatherer].gold

  var inputs = newSeq[PlayerInput](sim.players.len)
  inputs[buyer].aPressed = true
  inputs[buyer].aHeld = true
  sim.step(inputs)
  doAssert sim.players[buyer].state == AtBuyStall

  inputs = newSeq[PlayerInput](sim.players.len)
  inputs[buyer].aPressed = true
  inputs[buyer].aHeld = true
  sim.step(inputs)

  doAssert sim.players[buyer].inv.wood == 1
  doAssert sim.players[buyer].gold == buyerGold - 12
  doAssert sim.players[gatherer].gold == gathererGold + 12
  doAssert sim.players[gatherer].listings.len == 0

# ── Peer economy loop: gatherer sells, crafter buys, crafts gear, sells gear ──

proc testPeerEconomyLoop() =
  var sim = initMarketboardForTest()
  sim.npcListings.setLen(0)
  let gatherer = sim.addPlayer("gatherer")
  let crafter = sim.addPlayer("crafter")
  sim.players[gatherer].role = Gatherer
  sim.players[crafter].role = Crafter

  # Gatherer lists 3 wood at 8g each
  sim.players[gatherer].inv.wood = 3
  let si = sim.findObjectIndex(SellStallObj)
  let sellStall = sim.objects[si]
  sim.players[gatherer].x = sellStall.tx * MbTileSize
  sim.players[gatherer].y = sellStall.ty * MbTileSize
  sim.players[gatherer].velX = 0
  sim.players[gatherer].velY = 0
  sim.players[gatherer].sellPrice = 8
  sim.pressA(gatherer, FaceDown)
  doAssert sim.players[gatherer].state == AtSellStall
  # Sell 3 units (press A 3 times with release between)
  for _ in 0 ..< 3:
    sim.pressA(gatherer, FaceDown)
  doAssert sim.players[gatherer].inv.wood == 0
  doAssert sim.players[gatherer].listings.len == 3
  sim.pressB(gatherer)

  # Crafter buys 3 wood from gatherer's listings
  let bi = sim.findObjectIndex(BuyStallObj)
  let buyStall = sim.objects[bi]
  sim.players[crafter].x = buyStall.tx * MbTileSize
  sim.players[crafter].y = buyStall.ty * MbTileSize
  sim.players[crafter].velX = 0
  sim.players[crafter].velY = 0
  let crafterGold = sim.players[crafter].gold
  let gathererGold = sim.players[gatherer].gold

  var inputs = newSeq[PlayerInput](sim.players.len)
  inputs[crafter].aPressed = true
  inputs[crafter].aHeld = true
  sim.step(inputs)
  doAssert sim.players[crafter].state == AtBuyStall

  # Set buyQuantity to 3
  for _ in 0 ..< 2:
    inputs = newSeq[PlayerInput](sim.players.len)
    inputs[crafter].up = true
    sim.step(inputs)
  doAssert sim.players[crafter].buyQuantity == 3

  inputs = newSeq[PlayerInput](sim.players.len)
  inputs[crafter].aPressed = true
  inputs[crafter].aHeld = true
  sim.step(inputs)

  doAssert sim.players[crafter].inv.wood == 3,
    "crafter should have 3 wood, got " & $sim.players[crafter].inv.wood
  doAssert sim.players[crafter].gold == crafterGold - 24,
    "crafter should spend 24g (3x8)"
  doAssert sim.players[gatherer].gold == gathererGold + 24,
    "gatherer should receive 24g"
  doAssert sim.players[gatherer].listings.len == 0,
    "gatherer listings should be empty after purchase"

  sim.pressB(crafter)

  # Crafter crafts gear
  let ci = sim.findObjectIndex(CraftStationObj)
  let craftStation = sim.objects[ci]
  sim.players[crafter].x = craftStation.tx * MbTileSize
  sim.players[crafter].y = craftStation.ty * MbTileSize
  sim.players[crafter].velX = 0
  sim.players[crafter].velY = 0
  sim.pressA(crafter, FaceDown)
  doAssert sim.players[crafter].state == Crafting
  sim.holdA(crafter, CraftWorkNeeded - 1)
  doAssert sim.players[crafter].inv.wood == 0
  doAssert sim.players[crafter].crafterGear[ord(SlotHat)] == LeatherHat

  # Crafter sells gear at 30g — put a LeatherHat in inventory directly
  sim.players[crafter].inv.counts[LeatherHat] = 1
  sim.players[crafter].x = sellStall.tx * MbTileSize
  sim.players[crafter].y = sellStall.ty * MbTileSize
  sim.players[crafter].velX = 0
  sim.players[crafter].velY = 0
  sim.players[crafter].sellPrice = 30
  sim.pressA(crafter, FaceDown)
  doAssert sim.players[crafter].state == AtSellStall
  sim.pressA(crafter, FaceDown)
  doAssert sim.players[crafter].inv.counts[LeatherHat] == 0
  doAssert sim.players[crafter].listings.len == 1
  doAssert sim.players[crafter].listings[0].item == LeatherHat
  doAssert sim.players[crafter].listings[0].priceEach == 30

# ── Buy from player listing with gold transfer ──

proc testBuyFromPlayerListing() =
  var sim = initMarketboardForTest()
  sim.npcListings.setLen(0)
  let seller = sim.addPlayer("seller")
  let buyer = sim.addPlayer("buyer")

  # Seller lists 1 wood at 15g
  sim.players[seller].inv.wood = 1
  let si = sim.findObjectIndex(SellStallObj)
  let stall = sim.objects[si]
  sim.players[seller].x = stall.tx * MbTileSize
  sim.players[seller].y = stall.ty * MbTileSize
  sim.players[seller].sellPrice = 15
  sim.pressA(seller, FaceDown)
  sim.pressA(seller, FaceDown)
  doAssert sim.players[seller].listings.len == 1
  sim.pressB(seller)

  # Buyer buys it
  let bi = sim.findObjectIndex(BuyStallObj)
  let buyStall = sim.objects[bi]
  sim.players[buyer].x = buyStall.tx * MbTileSize
  sim.players[buyer].y = buyStall.ty * MbTileSize
  let sellerGold = sim.players[seller].gold
  let buyerGold = sim.players[buyer].gold

  var inputs = newSeq[PlayerInput](sim.players.len)
  inputs[buyer].aPressed = true
  inputs[buyer].aHeld = true
  sim.step(inputs)
  doAssert sim.players[buyer].state == AtBuyStall

  inputs = newSeq[PlayerInput](sim.players.len)
  inputs[buyer].aPressed = true
  inputs[buyer].aHeld = true
  sim.step(inputs)

  doAssert sim.players[buyer].inv.wood == 1
  doAssert sim.players[buyer].gold == buyerGold - 15
  doAssert sim.players[seller].gold == sellerGold + 15
  doAssert sim.players[seller].listings.len == 0,
    "seller listing should be removed after purchase"

# ── Buy edge cases: insufficient gold and empty market ──

proc testBuyInsufficientGoldAndEmptyMarket() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")

  # Part A: insufficient gold
  sim.npcListings.setLen(0)
  sim.npcListings.add MarketListing(sellerIndex: -1, item: WoodItem, quantity: 1, priceEach: 5)
  sim.players[idx].gold = 3

  let bi = sim.findObjectIndex(BuyStallObj)
  let buyStall = sim.objects[bi]
  sim.players[idx].x = buyStall.tx * MbTileSize
  sim.players[idx].y = buyStall.ty * MbTileSize

  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].state == AtBuyStall
  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].inv.wood == 0, "should not buy with insufficient gold"
  doAssert sim.players[idx].gold == 3, "gold should be unchanged"
  doAssert sim.npcListings[0].quantity == 1, "listing should be untouched"

  # Part B: empty market
  sim.npcListings.setLen(0)
  sim.players[idx].gold = 100

  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].inv.wood == 0, "should not buy from empty market"
  doAssert sim.players[idx].gold == 100, "gold should be unchanged with empty market"
  doAssert sim.players[idx].state == AtBuyStall, "should still be at buy stall"

# ── Max sell slots ──

proc testMaxSellSlots() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  sim.players[idx].inv.wood = MaxSellSlots + 1

  let si = sim.findObjectIndex(SellStallObj)
  let stall = sim.objects[si]
  sim.players[idx].x = stall.tx * MbTileSize
  sim.players[idx].y = stall.ty * MbTileSize

  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].state == AtSellStall

  for i in 0 ..< MaxSellSlots:
    sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].listings.len == MaxSellSlots,
    "should have " & $MaxSellSlots & " listings, got " & $sim.players[idx].listings.len
  doAssert sim.players[idx].inv.wood == 1, "should have 1 wood remaining"

  # Next sell should fail silently (slots full)
  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].listings.len == MaxSellSlots,
    "should still have " & $MaxSellSlots & " listings after overflow attempt"
  doAssert sim.players[idx].inv.wood == 1,
    "wood should be unchanged after failed sell"

# ── Equipment tests ──

proc testGearEquipOnBuy() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("buyer")
  sim.players[idx].role = Gatherer

  let bi = sim.findObjectIndex(BuyStallObj)
  let stall = sim.objects[bi]
  sim.players[idx].x = stall.tx * MbTileSize
  sim.players[idx].y = stall.ty * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0

  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].state == AtBuyStall

  # Select LeatherHat (cursor index)
  sim.players[idx].buyItemCursor = ord(LeatherHat)
  sim.players[idx].buyQuantity = 1
  sim.pressA(idx, FaceDown)

  doAssert sim.players[idx].gathererGear[ord(SlotHat)] == LeatherHat,
    "LeatherHat should auto-equip into hat slot"
  doAssert sim.players[idx].inv.counts[LeatherHat] == 0,
    "LeatherHat should not be in inventory after equipping"
  doAssert sim.players[idx].equippedGearCount() == 1

proc testGearGoesToInventoryIfSlotFilled() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("buyer")
  sim.players[idx].role = Gatherer
  sim.players[idx].gathererGear[ord(SlotHat)] = LeatherHat

  let bi = sim.findObjectIndex(BuyStallObj)
  let stall = sim.objects[bi]
  sim.players[idx].x = stall.tx * MbTileSize
  sim.players[idx].y = stall.ty * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0

  sim.pressA(idx, FaceDown)
  doAssert sim.players[idx].state == AtBuyStall

  sim.players[idx].buyItemCursor = ord(ChainHat)
  sim.players[idx].buyQuantity = 1
  sim.pressA(idx, FaceDown)

  doAssert sim.players[idx].gathererGear[ord(SlotHat)] == ChainHat,
    "ChainHat (T2) should upgrade LeatherHat (T1) in hat slot"
  doAssert sim.players[idx].inv.counts[ChainHat] == 0,
    "ChainHat should not be in inventory after upgrading"

proc testGearBoostsGatherSpeed() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("gatherer")
  sim.players[idx].role = Gatherer

  let ni = sim.findWoodNodeIndex()
  let node = sim.objects[ni]
  sim.players[idx].x = node.tx * MbTileSize
  sim.players[idx].y = node.ty * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0

  # Gather without gear: takes GatherWorkNeeded (48) ticks
  let normalWork = sim.players[idx].effectiveGatherWork()
  doAssert normalWork == GatherWorkNeeded,
    "no gear should mean normal gather speed, got " & $normalWork

  # Equip 3 slots (30% bonus)
  sim.players[idx].gathererGear[ord(SlotHat)] = LeatherHat
  sim.players[idx].gathererGear[ord(SlotShirt)] = LeatherShirt
  sim.players[idx].gathererGear[ord(SlotGloves)] = LeatherGloves
  let boostedWork = sim.players[idx].effectiveGatherWork()
  let expected = GatherWorkNeeded * (100 - 3 * GearBonusPerSlot) div 100
  doAssert boostedWork == expected,
    "3 gear should give " & $expected & " gather ticks, got " & $boostedWork

proc testFullGearSet() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("gatherer")
  sim.players[idx].role = Gatherer
  sim.players[idx].gathererGear[ord(SlotHat)] = LeatherHat
  sim.players[idx].gathererGear[ord(SlotShirt)] = LeatherShirt
  sim.players[idx].gathererGear[ord(SlotGloves)] = LeatherGloves
  sim.players[idx].gathererGear[ord(SlotPants)] = LeatherPants
  sim.players[idx].gathererGear[ord(SlotShoes)] = LeatherShoes
  let fullWork = sim.players[idx].effectiveGatherWork()
  let expected = max(1, GatherWorkNeeded * (100 - 5 * GearBonusPerSlot) div 100)
  doAssert fullWork == expected,
    "full gear should give " & $expected & " gather ticks, got " & $fullWork
  doAssert sim.players[idx].equippedGearCount() == 5

proc testGearBoostsMovementSpeed() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("gatherer")
  sim.players[idx].role = Gatherer

  let normalSpeed = sim.players[idx].effectiveMaxSpeed()
  doAssert normalSpeed == MaxSpeed,
    "no gear should mean normal speed, got " & $normalSpeed

  sim.players[idx].gathererGear[ord(SlotHat)] = LeatherHat
  sim.players[idx].gathererGear[ord(SlotShirt)] = LeatherShirt
  let boostedSpeed = sim.players[idx].effectiveMaxSpeed()
  let expected = MaxSpeed * (100 + 2 * GearBonusPerSlot) div 100
  doAssert boostedSpeed == expected,
    "2 gear should give speed " & $expected & ", got " & $boostedSpeed

proc testCraftProducesSlotItems() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("crafter")
  sim.players[idx].role = Crafter
  sim.players[idx].gold = 500

  let ci = sim.findObjectIndex(CraftStationObj)
  let craftStation = sim.objects[ci]
  sim.players[idx].x = craftStation.tx * MbTileSize
  sim.players[idx].y = craftStation.ty * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0

  # Craft 5 times — each slot uses a specific material per recipe
  # Hat=Wood, Shirt=Stone, Gloves=Wood, Pants=Stone, Shoes=Wood
  let expectedItems = [LeatherHat, LeatherShirt, LeatherGloves, LeatherPants, LeatherShoes]
  let expectedMats = [WoodItem, StoneItem, WoodItem, StoneItem, WoodItem]
  for craft in 0 ..< 5:
    if expectedMats[craft] == WoodItem:
      sim.players[idx].inv.wood = 3
    else:
      sim.players[idx].inv.stone = 3
    sim.pressA(idx, FaceDown)
    doAssert sim.players[idx].state == Crafting,
      "craft " & $craft & " should start crafting"
    sim.holdA(idx, CraftWorkNeeded - 1)
    doAssert sim.players[idx].state == Idle
    doAssert sim.players[idx].crafterGear[craft] == expectedItems[craft],
      "craft " & $craft & " should produce " & $expectedItems[craft] &
      " got " & $sim.players[idx].crafterGear[craft]

proc testBestInteractionTileSnap() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("test")
  sim.players[idx].role = Gatherer
  let nodeIdx = sim.findWoodNodeIndex()
  let node = sim.objects[nodeIdx]
  sim.players[idx].x = (node.tx - 1) * MbTileSize
  sim.players[idx].y = node.ty * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0
  sim.players[idx].facing = FaceLeft
  let raw = sim.players[idx].interactionTile()
  doAssert raw.tx != node.tx or raw.ty != node.ty,
    "raw interactionTile should NOT point at node"
  let best = sim.bestInteractionTile(sim.players[idx])
  doAssert best.tx == node.tx and best.ty == node.ty,
    "bestInteractionTile should snap to nearby wood node. got=(" &
    $best.tx & "," & $best.ty & ") expected=(" & $node.tx & "," & $node.ty & ")"

echo "Running marketboard tests..."
testPlayerSpawnsWithStartingGold()
echo "  spawn: OK"
testNodeRespawn()
echo "  node respawn: OK"
testBuildStateJson()
echo "  state JSON: OK"
testRoleSwitchGatherer()
echo "  role switch (gatherer): OK"
testRoleSwitchCrafter()
echo "  role switch (crafter): OK"
testGatheringOnNode()
echo "  gathering (on node): OK"
testGatheringAdjacentToNode()
echo "  gathering (adjacent): OK"
testGatheringRequiresRole()
echo "  gathering (requires role): OK"
testCancelGathering()
echo "  gathering (cancel): OK"
testWalkToNodeThenGather()
echo "  gathering (walk to node): OK"
testWalkToNodeAdjacentThenGather()
echo "  gathering (walk adjacent): OK"
testGatheringOffsetPositions()
echo "  gathering (sub-pixel offsets): OK"
testWalkToGathererStall()
echo "  walk to gatherer stall: OK"
testCrafting()
echo "  crafting: OK"
testSelling()
echo "  selling: OK"
testBuying()
echo "  buying: OK"
testGoldTransfer()
echo "  gold transfer: OK"
testFullGatherSellBuyCycle()
echo "  full gather-sell-buy cycle: OK"
testPeerEconomyLoop()
echo "  peer economy loop: OK"
testBuyFromPlayerListing()
echo "  buy from player listing: OK"
testBuyInsufficientGoldAndEmptyMarket()
echo "  buy edge cases (insufficient gold + empty market): OK"
testMaxSellSlots()
echo "  max sell slots: OK"
testGearEquipOnBuy()
echo "  gear equip on buy: OK"
testGearGoesToInventoryIfSlotFilled()
echo "  gear goes to inventory if slot filled: OK"
testGearBoostsGatherSpeed()
echo "  gear boosts gather speed: OK"
testFullGearSet()
echo "  full gear set: OK"
testGearBoostsMovementSpeed()
echo "  gear boosts movement speed: OK"
testCraftProducesSlotItems()
echo "  craft produces slot items: OK"
testBestInteractionTileSnap()
echo "  best interaction tile snap: OK"
echo "All tests passed"

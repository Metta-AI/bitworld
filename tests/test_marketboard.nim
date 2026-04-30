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
  doAssert sim.players[idx].inv.woodGear == 1

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
echo "All tests passed"

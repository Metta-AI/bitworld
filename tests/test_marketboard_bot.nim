import
  std/[json, options, os],
  ../common/protocol,
  ../common/server,
  ../marketboard/sim,
  ../marketboard/players/common

const RootDir = currentSourcePath.parentDir.parentDir

proc initMarketboardForTest(): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "marketboard")
  try:
    result = initSimServer(0)
  finally:
    setCurrentDir(previousDir)

# Convert a bot mask into sim PlayerInput, tracking previous mask for edge detection
proc maskToInput(currentMask, previousMask: uint8): PlayerInput =
  let decoded = decodeInputMask(currentMask)
  result.up = decoded.up
  result.down = decoded.down
  result.left = decoded.left
  result.right = decoded.right
  result.aPressed = (currentMask and ButtonA) != 0 and (previousMask and ButtonA) == 0
  result.aHeld = (currentMask and ButtonA) != 0
  result.bPressed = (currentMask and ButtonB) != 0 and (previousMask and ButtonB) == 0
  result.selectPressed = (currentMask and ButtonSelect) != 0 and (previousMask and ButtonSelect) == 0

proc testStateJsonRoundTrip() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("bot")
  sim.players[idx].role = Gatherer
  sim.players[idx].inv.wood = 3
  sim.players[idx].gold = 50

  let state = parseGameState(sim.buildStateJson(idx))
  doAssert state.player.role == "Gatherer"
  doAssert state.player.inv.wood == 3
  doAssert state.player.gold == 50
  doAssert state.player.name == "bot"
  doAssert state.objects.len > 0

  var foundGatherNode = false
  for obj in state.objects:
    if obj.kind == "GatherNodeObj" and obj.material == "WoodItem":
      foundGatherNode = true
      break
  doAssert foundGatherNode

proc testWalkTowardProducesMovement() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("bot")
  let startX = sim.players[idx].x
  let startY = sim.players[idx].y

  # Walk right for a few ticks
  var prevMask = 0'u8
  for _ in 0 ..< 30:
    let mask = walkToward(sim.players[idx].x, sim.players[idx].y, 25, 16)
    var inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(mask, prevMask)
    sim.step(inputs)
    prevMask = mask

  doAssert sim.players[idx].x != startX or sim.players[idx].y != startY,
    "walkToward should cause actual movement"

proc testBotCanSwitchRole() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("bot")

  var prevMask = 0'u8
  var switched = false
  var nav: Navigator

  for tick in 0 ..< 500:
    let state = parseGameState(sim.buildStateJson(idx))
    if state.player.role == "Gatherer":
      switched = true
      break

    let stallOpt = nearestObject(state, "GathererStallObj")
    if stallOpt.isNone:
      continue
    let stall = stallOpt.get()

    var mask: uint8
    if isAdjacentTo(state.player.x, state.player.y, stall.tx, stall.ty):
      mask = facingMask(stall.tx, stall.ty, state.player.tx, state.player.ty) or ButtonA
    else:
      if not nav.hasPath or tick mod 30 == 0:
        nav.navigateAdjacent(state, stall.tx, stall.ty)
      mask = nav.followPath(state.player.x, state.player.y)

    var inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(mask, prevMask)
    sim.step(inputs)
    prevMask = mask

  doAssert switched, "bot should switch to Gatherer within 500 ticks"

proc testBotCanWalkToNode() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("bot")
  sim.players[idx].role = Gatherer

  var prevMask = 0'u8
  var reachedNode = false
  var nav: Navigator

  for tick in 0 ..< 600:
    let state = parseGameState(sim.buildStateJson(idx))
    let nodeOpt = nearestObject(state, "GatherNodeObj", material = "WoodItem")
    if nodeOpt.isNone:
      break
    let node = nodeOpt.get()

    if isOnTile(state.player.x, state.player.y, node.tx, node.ty) or
       isAdjacentTo(state.player.x, state.player.y, node.tx, node.ty):
      reachedNode = true
      break

    if not nav.hasPath or tick mod 30 == 0:
      nav.navigateTo(state, node.tx, node.ty)
    let mask = nav.followPath(state.player.x, state.player.y)
    var inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(mask, prevMask)
    sim.step(inputs)
    prevMask = mask

  doAssert reachedNode, "bot should reach a wood node within 600 ticks"

proc testBotFullGatherCycle() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("bot")
  sim.players[idx].role = Gatherer

  # Teleport near a wood node to skip walking
  var nodeIdx = -1
  for i, obj in sim.objects:
    if obj.kind == GatherNodeObj and obj.material == WoodItem and not obj.depleted:
      nodeIdx = i
      break
  doAssert nodeIdx >= 0
  let node = sim.objects[nodeIdx]
  sim.players[idx].x = node.tx * MbTileSize
  sim.players[idx].y = node.ty * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0

  var prevMask = 0'u8
  var gathered = false

  for tick in 0 ..< GatherWorkNeeded + 10:
    let state = parseGameState(sim.buildStateJson(idx))

    if state.player.inv.wood > 0:
      gathered = true
      break

    var mask: uint8
    if state.player.state == "Gathering":
      mask = ButtonA
    elif state.player.state == "Idle":
      let nodeOpt = nearestObject(state, "GatherNodeObj", material = "WoodItem")
      if nodeOpt.isSome:
        let n = nodeOpt.get()
        mask = facingMask(n.tx, n.ty, state.player.tx, state.player.ty) or ButtonA
    else:
      mask = 0

    var inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(mask, prevMask)
    sim.step(inputs)
    prevMask = mask

  doAssert gathered,
    "bot should gather wood. inv.wood=" & $sim.players[idx].inv.wood &
    " state=" & $sim.players[idx].state

proc testBotFullGatherSellCycle() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("bot")
  sim.players[idx].role = Gatherer

  # Teleport to node, gather
  var nodeIdx = -1
  for i, obj in sim.objects:
    if obj.kind == GatherNodeObj and obj.material == WoodItem:
      nodeIdx = i
      break
  let node = sim.objects[nodeIdx]
  sim.players[idx].x = node.tx * MbTileSize
  sim.players[idx].y = node.ty * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0

  # Gather
  var prevMask = 0'u8
  for tick in 0 ..< GatherWorkNeeded + 10:
    let state = parseGameState(sim.buildStateJson(idx))
    var mask: uint8
    if state.player.state == "Gathering":
      mask = ButtonA
    else:
      let n = nearestObject(state, "GatherNodeObj", material = "WoodItem")
      if n.isSome:
        mask = facingMask(n.get().tx, n.get().ty, state.player.tx, state.player.ty) or ButtonA
    var inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(mask, prevMask)
    sim.step(inputs)
    prevMask = mask
    if sim.players[idx].inv.wood > 0:
      break

  doAssert sim.players[idx].inv.wood > 0, "should have gathered wood"

  # Teleport directly on the sell stall (SellStallObj is collision, so place ON it for standingTile interaction)
  # Actually, sell stalls ARE collision tiles, so place adjacent and face toward it
  var sellStall: BotObject
  for obj in sim.objects:
    if obj.kind == SellStallObj:
      sellStall = BotObject(kind: "SellStallObj", tx: obj.tx, ty: obj.ty)
      break
  # Place to the right of the stall
  sim.players[idx].x = (sellStall.tx + 1) * MbTileSize
  sim.players[idx].y = sellStall.ty * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0
  sim.players[idx].facing = FaceLeft

  prevMask = 0'u8
  var sold = false
  # Face left toward the stall then press A
  var inputs = newSeq[PlayerInput](sim.players.len)
  inputs[idx] = maskToInput(buildMask(left = true), 0)
  sim.step(inputs)
  prevMask = buildMask(left = true)

  for tick in 0 ..< 30:
    let state = parseGameState(sim.buildStateJson(idx))
    var mask: uint8
    if state.player.state == "AtSellStall":
      if state.player.inv.wood == 0:
        mask = ButtonB
        if state.player.listings.len > 0:
          sold = true
      else:
        # Alternate A on/off so aPressed triggers each time
        if (prevMask and ButtonA) != 0:
          mask = 0
        else:
          mask = ButtonA
    elif state.player.state == "Idle":
      if sold:
        break
      # Alternate A on/off
      if (prevMask and ButtonA) != 0:
        mask = 0
      else:
        mask = ButtonA
    inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(mask, prevMask)
    sim.step(inputs)
    prevMask = mask

  doAssert sold, "bot should have sold wood. listings=" & $sim.players[idx].listings.len &
    " inv.wood=" & $sim.players[idx].inv.wood &
    " state=" & $sim.players[idx].state

proc testBotFullBuyCraftSellCycle() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("bot")
  sim.players[idx].role = Crafter

  # --- Buy phase: teleport adjacent to BuyStallObj, buy 3 wood ---
  var buyStallTx, buyStallTy: int
  for obj in sim.objects:
    if obj.kind == BuyStallObj:
      buyStallTx = obj.tx
      buyStallTy = obj.ty
      break
  # Place to the left of the buy stall
  sim.players[idx].x = (buyStallTx - 1) * MbTileSize
  sim.players[idx].y = buyStallTy * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0
  sim.players[idx].facing = FaceRight

  let startGold = sim.players[idx].gold
  var prevMask = 0'u8

  # Face right toward stall then press A to enter
  var inputs = newSeq[PlayerInput](sim.players.len)
  inputs[idx] = maskToInput(buildMask(right = true), 0)
  sim.step(inputs)
  prevMask = buildMask(right = true)

  # Enter buy stall: press A without direction to avoid cursor shift from right input
  for tick in 0 ..< 10:
    let state = parseGameState(sim.buildStateJson(idx))
    if state.player.state == "AtBuyStall":
      break
    var mask: uint8
    if (prevMask and ButtonA) != 0:
      mask = 0
    else:
      mask = ButtonA
    inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(mask, prevMask)
    sim.step(inputs)
    prevMask = mask

  doAssert sim.players[idx].state == AtBuyStall, "should be at buy stall, state=" & $sim.players[idx].state

  # Set buyQuantity to 3 (default is 1, press up twice)
  for _ in 0 ..< 2:
    inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(ButtonUp, 0)
    sim.step(inputs)
  doAssert sim.players[idx].buyQuantity == 3, "buyQuantity should be 3, got " & $sim.players[idx].buyQuantity

  # Press A to buy
  prevMask = ButtonUp
  inputs = newSeq[PlayerInput](sim.players.len)
  inputs[idx] = maskToInput(ButtonA, prevMask)
  sim.step(inputs)
  prevMask = ButtonA

  doAssert sim.players[idx].inv.wood == 3, "should have 3 wood, got " & $sim.players[idx].inv.wood
  doAssert sim.players[idx].gold == startGold - 3 * WoodBasePrice,
    "gold should decrease by 15, got " & $sim.players[idx].gold

  # Exit buy stall
  inputs = newSeq[PlayerInput](sim.players.len)
  inputs[idx] = maskToInput(0, prevMask)
  sim.step(inputs)
  prevMask = 0
  inputs = newSeq[PlayerInput](sim.players.len)
  inputs[idx] = maskToInput(ButtonB, prevMask)
  sim.step(inputs)
  prevMask = ButtonB

  doAssert sim.players[idx].state == Idle, "should be idle after exiting buy stall"

  # --- Craft phase: teleport to CraftStationObj, craft gear ---
  var craftTx, craftTy: int
  for obj in sim.objects:
    if obj.kind == CraftStationObj:
      craftTx = obj.tx
      craftTy = obj.ty
      break
  sim.players[idx].x = craftTx * MbTileSize
  sim.players[idx].y = craftTy * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0

  # Press A to start crafting
  prevMask = 0
  for tick in 0 ..< 5:
    let state = parseGameState(sim.buildStateJson(idx))
    if state.player.state == "Crafting":
      break
    var mask: uint8
    if (prevMask and ButtonA) != 0:
      mask = 0
    else:
      mask = facingMask(craftTx, craftTy, state.player.tx, state.player.ty) or ButtonA
    inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(mask, prevMask)
    sim.step(inputs)
    prevMask = mask

  doAssert sim.players[idx].state == Crafting, "should be crafting, state=" & $sim.players[idx].state

  # Hold A for CraftWorkNeeded ticks
  for _ in 0 ..< CraftWorkNeeded:
    inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(ButtonA, ButtonA)
    sim.step(inputs)

  doAssert sim.players[idx].inv.wood == 0, "wood should be consumed, got " & $sim.players[idx].inv.wood
  doAssert sim.players[idx].crafterGear[ord(SlotHat)] == LeatherHat, "should have LeatherHat equipped"
  doAssert sim.players[idx].state == Idle, "should be idle after crafting"

  # Put a gear item in inventory for the sell test (crafted one auto-equipped)
  sim.players[idx].inv.counts[LeatherHat] = 1

  # --- Sell phase: teleport to SellStallObj, sell gear ---
  var sellStallTx, sellStallTy: int
  for obj in sim.objects:
    if obj.kind == SellStallObj:
      sellStallTx = obj.tx
      sellStallTy = obj.ty
      break
  sim.players[idx].x = (sellStallTx + 1) * MbTileSize
  sim.players[idx].y = sellStallTy * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0
  sim.players[idx].facing = FaceLeft

  # Face toward stall
  prevMask = 0
  inputs = newSeq[PlayerInput](sim.players.len)
  inputs[idx] = maskToInput(buildMask(left = true), 0)
  sim.step(inputs)
  prevMask = buildMask(left = true)

  # Enter sell stall
  for tick in 0 ..< 10:
    let state = parseGameState(sim.buildStateJson(idx))
    if state.player.state == "AtSellStall":
      break
    var mask: uint8
    if (prevMask and ButtonA) != 0:
      mask = 0
    else:
      mask = ButtonA
    inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(mask, prevMask)
    sim.step(inputs)
    prevMask = mask

  doAssert sim.players[idx].state == AtSellStall, "should be at sell stall"

  # Set price to 30 (default is 10, press up 20 times)
  for _ in 0 ..< 20:
    inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(ButtonUp, 0)
    sim.step(inputs)
  doAssert sim.players[idx].sellPrice == 30, "sellPrice should be 30, got " & $sim.players[idx].sellPrice

  # Press A to confirm sell
  prevMask = ButtonUp
  inputs = newSeq[PlayerInput](sim.players.len)
  inputs[idx] = maskToInput(ButtonA, prevMask)
  sim.step(inputs)

  doAssert sim.players[idx].inv.counts[LeatherHat] == 0, "LeatherHat should be sold, got " & $sim.players[idx].inv.counts[LeatherHat]
  doAssert sim.players[idx].listings.len == 1, "should have 1 listing, got " & $sim.players[idx].listings.len
  doAssert sim.players[idx].listings[0].item == LeatherHat, "listing should be LeatherHat"
  doAssert sim.players[idx].listings[0].priceEach == 30, "listing price should be 30"

echo "Running bot integration tests..."
testStateJsonRoundTrip()
echo "  state JSON round-trip: OK"
testWalkTowardProducesMovement()
echo "  walkToward produces movement: OK"
testBotCanSwitchRole()
echo "  bot can switch role: OK"
testBotCanWalkToNode()
echo "  bot can walk to node: OK"
testBotFullGatherCycle()
echo "  bot full gather cycle: OK"
testBotFullGatherSellCycle()
echo "  bot full gather-sell cycle: OK"
testBotFullBuyCraftSellCycle()
echo "  bot full buy-craft-sell cycle: OK"
echo "All bot tests passed"

import
  std/[json, options, os],
  ../common/protocol,
  ../common/server,
  ../marketboard/sim,
  ../marketboard/players/common,
  ../marketboard/players/still_forge as sf,
  ../marketboard/players/iron_works as iw,
  ../marketboard/players/colm as co,
  ../marketboard/players/zorori as zo,
  ../marketboard/players/solenne as so,
  ../marketboard/players/rkhenna as rk,
  ../marketboard/players/pipitori as pi

const RootDir = currentSourcePath.parentDir.parentDir

proc findObjectIndex(sim: SimServer, kind: WorldObjectKind): int =
  for i, obj in sim.objects:
    if obj.kind == kind:
      return i
  -1

proc initMarketboardForTest(): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "marketboard")
  try:
    result = initSimServer(0)
  finally:
    setCurrentDir(previousDir)

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

proc testTotalMarketCap() =
  var sim = initMarketboardForTest()
  sim.npcListings.setLen(0)
  let p0 = sim.addPlayer("alice")
  let p1 = sim.addPlayer("bob")
  sim.players[p0].gold = 50
  sim.players[p0].inv.wood = 2
  sim.players[p1].gold = 80
  sim.players[p1].gathererGear[ord(SlotHat)] = LeatherHat

  let cap = sim.totalMarketCap()
  let expected = (50 + 2 * WoodBasePrice) + (80 + T1GearBasePrice)
  doAssert cap == expected,
    "totalMarketCap should be " & $expected & ", got " & $cap
  doAssert cap == sim.rewardScore(p0) + sim.rewardScore(p1),
    "totalMarketCap should equal sum of rewardScores"

proc testMarketCapGrowsWithGathering() =
  var sim = initMarketboardForTest()
  sim.npcListings.setLen(0)
  let idx = sim.addPlayer("gatherer")
  sim.players[idx].role = Gatherer

  let initialCap = sim.totalMarketCap()
  doAssert initialCap == StartingGold

  let nodeIdx = sim.findObjectIndex(GatherNodeObj)
  doAssert nodeIdx >= 0
  let node = sim.objects[nodeIdx]
  sim.players[idx].x = node.tx * MbTileSize
  sim.players[idx].y = node.ty * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0

  sim.players[idx].facing = FaceDown
  var inputs = newSeq[PlayerInput](sim.players.len)
  inputs[idx].aPressed = true
  inputs[idx].aHeld = true
  sim.step(inputs)
  doAssert sim.players[idx].state == Gathering

  for _ in 0 ..< GatherWorkNeeded:
    inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx].aHeld = true
    sim.step(inputs)

  let finalCap = sim.totalMarketCap()
  doAssert finalCap == initialCap + WoodBasePrice,
    "gathering should increase market cap by " & $WoodBasePrice &
    ", got " & $finalCap & " (was " & $initialCap & ")"

proc testMarketCapPreservedByCrafting() =
  var sim = initMarketboardForTest()
  sim.npcListings.setLen(0)
  let idx = sim.addPlayer("crafter")
  sim.players[idx].role = Crafter
  sim.players[idx].inv.wood = 3

  let initialCap = sim.totalMarketCap()
  let expectedInitial = StartingGold + 3 * WoodBasePrice
  doAssert initialCap == expectedInitial

  let ci = sim.findObjectIndex(CraftStationObj)
  let station = sim.objects[ci]
  sim.players[idx].x = station.tx * MbTileSize
  sim.players[idx].y = station.ty * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0

  sim.players[idx].facing = FaceDown
  var inputs = newSeq[PlayerInput](sim.players.len)
  inputs[idx].aPressed = true
  inputs[idx].aHeld = true
  sim.step(inputs)
  doAssert sim.players[idx].state == Crafting

  for _ in 0 ..< CraftWorkNeeded:
    inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx].aHeld = true
    sim.step(inputs)

  let finalCap = sim.totalMarketCap()
  doAssert finalCap == StartingGold + T1GearBasePrice,
    "crafting 3 wood (15g) into gear (20g) should give cap " &
    $(StartingGold + T1GearBasePrice) & ", got " & $finalCap

proc testMarketCapPreservedByTrading() =
  var sim = initMarketboardForTest()
  sim.npcListings.setLen(0)
  let seller = sim.addPlayer("seller")
  let buyer = sim.addPlayer("buyer")
  sim.players[seller].inv.wood = 1

  let si = sim.findObjectIndex(SellStallObj)
  let stall = sim.objects[si]
  sim.players[seller].x = stall.tx * MbTileSize
  sim.players[seller].y = stall.ty * MbTileSize
  sim.players[seller].sellPrice = WoodBasePrice

  let initialCap = sim.totalMarketCap()

  sim.players[seller].facing = FaceDown
  var inputs = newSeq[PlayerInput](sim.players.len)
  inputs[seller].aPressed = true
  inputs[seller].aHeld = true
  sim.step(inputs)
  doAssert sim.players[seller].state == AtSellStall

  inputs = newSeq[PlayerInput](sim.players.len)
  inputs[seller].aPressed = true
  inputs[seller].aHeld = true
  sim.step(inputs)
  doAssert sim.players[seller].listings.len == 1

  let afterListCap = sim.totalMarketCap()
  doAssert afterListCap == initialCap,
    "listing at base price should not change cap, got " & $afterListCap & " (was " & $initialCap & ")"

  inputs = newSeq[PlayerInput](sim.players.len)
  inputs[seller].bPressed = true
  sim.step(inputs)

  let bi = sim.findObjectIndex(BuyStallObj)
  let buyStall = sim.objects[bi]
  sim.players[buyer].x = buyStall.tx * MbTileSize
  sim.players[buyer].y = buyStall.ty * MbTileSize

  inputs = newSeq[PlayerInput](sim.players.len)
  inputs[buyer].aPressed = true
  inputs[buyer].aHeld = true
  sim.step(inputs)
  doAssert sim.players[buyer].state == AtBuyStall

  inputs = newSeq[PlayerInput](sim.players.len)
  inputs[buyer].aPressed = true
  inputs[buyer].aHeld = true
  sim.step(inputs)

  let afterTradeCap = sim.totalMarketCap()
  doAssert afterTradeCap == afterListCap,
    "trading should not change market cap, got " & $afterTradeCap &
    " (was " & $afterListCap & ")"

proc testMaterialCostForGearNoOverflow() =
  let state = GameState(
    npcListings: @[],
    playerListings: @[]
  )
  let cost = materialCostForGear(state)
  doAssert cost == int.high,
    "empty market should return int.high, got " & $cost

  let stateWithWood = GameState(
    npcListings: @[BotListing(item: "WoodItem", quantity: 1, priceEach: 5)],
    playerListings: @[]
  )
  let cost2 = materialCostForGear(stateWithWood)
  doAssert cost2 == 15,
    "wood at 5g should give cost 15, got " & $cost2

proc testBuyMaterialsExitsOnEmptyMarket() =
  var sim = initMarketboardForTest()
  sim.npcListings.setLen(0)
  let idx = sim.addPlayer("bot")
  sim.players[idx].role = Crafter
  sim.players[idx].gold = 100

  let bi = sim.findObjectIndex(BuyStallObj)
  let stall = sim.objects[bi]
  sim.players[idx].x = (stall.tx - 1) * MbTileSize
  sim.players[idx].y = stall.ty * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0
  sim.players[idx].facing = FaceRight

  var inputs = newSeq[PlayerInput](sim.players.len)
  inputs[idx] = maskToInput(buildMask(right = true), 0)
  sim.step(inputs)
  var prevMask = buildMask(right = true)

  for _ in 0 ..< 10:
    let state = parseGameState(sim.buildStateJson(idx))
    if state.player.state == "AtBuyStall":
      break
    var mask: uint8
    if (prevMask and ButtonA) != 0: mask = 0
    else: mask = ButtonA
    inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(mask, prevMask)
    sim.step(inputs)
    prevMask = mask

  doAssert sim.players[idx].state == AtBuyStall

  var bot = iw.BotState(phase: iw.BuyMaterials)
  var exited = false
  for tick in 0 ..< 30:
    let state = parseGameState(sim.buildStateJson(idx))
    let mask = bot.decide(state)
    inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(mask, bot.prevMask)
    sim.step(inputs)
    bot.prevMask = mask
    if bot.phase != iw.BuyMaterials:
      exited = true
      break

  doAssert exited, "iron_works should exit BuyMaterials when market is empty"

proc testStartCraftingExitsWithoutMaterials() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("bot")
  sim.players[idx].role = Crafter

  let ci = sim.findObjectIndex(CraftStationObj)
  let station = sim.objects[ci]
  sim.players[idx].x = station.tx * MbTileSize
  sim.players[idx].y = station.ty * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0

  var bot = iw.BotState(phase: iw.StartCrafting)
  var exited = false
  for tick in 0 ..< 15:
    let state = parseGameState(sim.buildStateJson(idx))
    let mask = bot.decide(state)
    var inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(mask, bot.prevMask)
    sim.step(inputs)
    bot.prevMask = mask
    if bot.phase != iw.StartCrafting:
      exited = true
      break

  doAssert exited, "iron_works should exit StartCrafting without materials"

proc testStartGatheringExitsWhenDepleted() =
  var sim = initMarketboardForTest()
  let idx = sim.addPlayer("bot")
  sim.players[idx].role = Gatherer

  for obj in sim.objects.mitems:
    if obj.kind == GatherNodeObj:
      obj.depleted = true
      obj.respawnTimer = 9999

  var nodeIdx = -1
  for i, obj in sim.objects:
    if obj.kind == GatherNodeObj:
      nodeIdx = i
      break
  let node = sim.objects[nodeIdx]
  sim.players[idx].x = node.tx * MbTileSize
  sim.players[idx].y = node.ty * MbTileSize
  sim.players[idx].velX = 0
  sim.players[idx].velY = 0

  var bot = sf.BotState(phase: sf.StartGathering)
  var exited = false
  for tick in 0 ..< 15:
    let state = parseGameState(sim.buildStateJson(idx))
    let mask = bot.decide(state)
    var inputs = newSeq[PlayerInput](sim.players.len)
    inputs[idx] = maskToInput(mask, bot.prevMask)
    sim.step(inputs)
    bot.prevMask = mask
    if bot.phase != sf.StartGathering:
      exited = true
      break

  doAssert exited, "still_forge should exit StartGathering when all nodes depleted"

proc testFullEconomySimulation() =
  var sim = initMarketboardForTest()

  let names = ["StillForge", "IronWorks", "Colm", "Zorori", "Solenne", "Rkhenna", "Pipitori"]
  var indices: array[7, int]
  for i, name in names:
    indices[i] = sim.addPlayer(name)

  let initialCap = sim.totalMarketCap()
  doAssert initialCap == 7 * StartingGold,
    "initial market cap should be " & $(7 * StartingGold) & ", got " & $initialCap

  var sfBot = sf.BotState(phase: sf.WaitForState)
  var iwBot = iw.BotState(phase: iw.WaitForState)
  var coBot = co.BotState(phase: co.WaitForState)
  var zoBot = zo.BotState(phase: zo.WaitForState)
  var soBot = so.BotState(phase: so.WaitForState)
  var rkBot = rk.BotState(phase: rk.WaitForState)
  var piBot = pi.BotState(phase: pi.WaitForState)

  var prevMasks: array[7, uint8]

  const SimTicks = 5000

  for tick in 0 ..< SimTicks:
    var masks: array[7, uint8]

    let s0 = parseGameState(sim.buildStateJson(indices[0]))
    masks[0] = sfBot.decide(s0)
    sfBot.prevMask = masks[0]

    let s1 = parseGameState(sim.buildStateJson(indices[1]))
    masks[1] = iwBot.decide(s1)
    iwBot.prevMask = masks[1]

    let s2 = parseGameState(sim.buildStateJson(indices[2]))
    masks[2] = coBot.decide(s2)
    coBot.prevMask = masks[2]

    let s3 = parseGameState(sim.buildStateJson(indices[3]))
    masks[3] = zoBot.decide(s3)
    zoBot.prevMask = masks[3]

    let s4 = parseGameState(sim.buildStateJson(indices[4]))
    masks[4] = soBot.decide(s4)
    soBot.prevMask = masks[4]

    let s5 = parseGameState(sim.buildStateJson(indices[5]))
    masks[5] = rkBot.decide(s5)
    rkBot.prevMask = masks[5]

    let s6 = parseGameState(sim.buildStateJson(indices[6]))
    masks[6] = piBot.decide(s6)
    piBot.prevMask = masks[6]

    var inputs = newSeq[PlayerInput](sim.players.len)
    for i in 0 ..< 7:
      inputs[indices[i]] = maskToInput(masks[i], prevMasks[i])
    sim.step(inputs)
    prevMasks = masks


  let finalCap = sim.totalMarketCap()
  echo "  Initial market cap: ", initialCap
  echo "  Final market cap:   ", finalCap
  echo "  Value created:      ", finalCap - initialCap
  for i, name in names:
    let score = sim.rewardScore(indices[i])
    let role = sim.players[indices[i]].role
    let gearCount = sim.players[indices[i]].equippedGearCount()
    echo "    ", name, ": score=", score, " role=", role, " gear=", gearCount, "/5"

  doAssert finalCap >= 900,
    "market cap should reach 900+, got " & $finalCap

  var anyTraded = false
  for i in 0 ..< 7:
    if sim.players[indices[i]].gold != StartingGold:
      anyTraded = true
      break
  doAssert anyTraded, "at least one bot should have traded (gold != starting gold)"

echo "Running economy tests..."
testTotalMarketCap()
echo "  total market cap calculation: OK"
testMarketCapGrowsWithGathering()
echo "  market cap grows with gathering: OK"
testMarketCapPreservedByCrafting()
echo "  market cap preserved by crafting: OK"
testMarketCapPreservedByTrading()
echo "  market cap preserved by trading: OK"
testMaterialCostForGearNoOverflow()
echo "  materialCostForGear no overflow: OK"
testBuyMaterialsExitsOnEmptyMarket()
echo "  BuyMaterials exits on empty market: OK"
testStartCraftingExitsWithoutMaterials()
echo "  StartCrafting exits without materials: OK"
testStartGatheringExitsWhenDepleted()
echo "  StartGathering exits when depleted: OK"
testFullEconomySimulation()
echo "  full economy simulation: OK"
echo "All economy tests passed"

# R'khenna Tia -- Miqo'te Seeker. Flipper/role-switcher.
# Reads market prices and switches between Gatherer and Crafter to exploit
# whichever is more profitable. Sells at current market rate.

import std/[options, os, parseopt, strutils]
import whisky
import protocol
import common

const
  BasePrice = 5
  MaterialScarcityThreshold = BasePrice * 2
  GearProfitThreshold = 3

type
  BotPhase* = enum
    WaitForState
    EvaluateMarket
    PathToGathererStall
    InteractGathererStall
    PathToCrafterStall
    InteractCrafterStall
    PathToNode
    StartGathering
    HoldGathering
    PathToBuyStall
    InteractBuyStall
    BuyMaterials
    ExitBuyMat
    PathToCraftStation
    StartCrafting
    HoldCrafting
    PathToSellStall
    InteractSellStall
    SetPrice
    ConfirmSell
    ExitSell
    CheckGear
    PathToBuyGearStall
    InteractBuyGearStall
    SelectGearItem
    BuyGear
    ExitBuyGear
    PathToCancelStall
    InteractCancelStall

  BotState* = object
    phase*: BotPhase
    nav*: Navigator
    prevMask*: uint8
    ticksInPhase*: int
    wantedRole*: string
    targetGearItem*: string
    targetGearCursor*: int
    pricingState*: PricingState
    lastSeenListings*: seq[BotListing]

proc decide*(bot: var BotState, state: GameState): uint8 =
  let p = state.player
  if p.state in ["AtBuyStall", "AtSellStall"]:
    bot.lastSeenListings = state.allListings()
  inc bot.ticksInPhase
  if bot.ticksInPhase > 600:
    bot.phase = WaitForState
    bot.ticksInPhase = 0
    return 0

  case bot.phase
  of WaitForState:
    bot.ticksInPhase = 0
    if p.state in ["AtSellStall", "AtBuyStall"]:
      return ButtonB
    bot.phase = EvaluateMarket
    return 0

  of EvaluateMarket:
    bot.ticksInPhase = 0
    let tier = bestAvailableCraftTier(state, p)
    let (matA, matB) = materialsForTier(tier)
    let matPrice = min(cheapestPrice(state, matA), cheapestPrice(state, matB))
    let gearPrice = cheapestPrice(state, gearItemForSlot(0, tier))
    let matCost = materialCostForGear(state, tier)

    if matPrice >= MaterialScarcityThreshold:
      bot.wantedRole = "Gatherer"
    elif gearPrice < int.high and matCost < int.high and gearPrice > matCost * GearProfitThreshold:
      bot.wantedRole = "Crafter"
    else:
      bot.wantedRole = "Gatherer"

    if p.role == bot.wantedRole or p.role == "NoRole":
      if p.role == "NoRole":
        if bot.wantedRole == "Gatherer":
          bot.phase = PathToGathererStall
        else:
          bot.phase = PathToCrafterStall
      elif p.role == "Gatherer":
        if hasAffordableGearUpgradeCached(state, p, bot.lastSeenListings):
          bot.phase = CheckGear
        elif shouldCancelListings(p) or shouldCancelForUpgrade(p):
          bot.phase = PathToCancelStall
        elif p.hasSellableMaterials and p.canSellMore:
          bot.phase = PathToSellStall
        else:
          bot.phase = PathToNode
      else:
        if shouldCancelListings(p) or shouldCancelForUpgrade(p):
          bot.phase = PathToCancelStall
        elif p.inv.hasAnyGear and p.canSellMore:
          bot.phase = PathToSellStall
        elif hasEnoughMaterialsForCraft(p.inv):
          bot.phase = PathToCraftStation
        elif hasAffordableGearUpgradeCached(state, p, bot.lastSeenListings):
          bot.phase = CheckGear
        else:
          bot.phase = PathToBuyStall
    else:
      if p.role == "Gatherer":
        if hasAffordableGearUpgradeCached(state, p, bot.lastSeenListings):
          bot.phase = CheckGear
        elif shouldCancelListings(p) or shouldCancelForUpgrade(p):
          bot.phase = PathToCancelStall
        elif p.hasSellableMaterials and p.canSellMore:
          bot.phase = PathToSellStall
        else:
          bot.phase = PathToNode
      else:
        if shouldCancelListings(p) or shouldCancelForUpgrade(p):
          bot.phase = PathToCancelStall
        elif p.inv.hasAnyGear and p.canSellMore:
          bot.phase = PathToSellStall
        elif hasEnoughMaterialsForCraft(p.inv):
          bot.phase = PathToCraftStation
        elif hasAffordableGearUpgradeCached(state, p, bot.lastSeenListings):
          bot.phase = CheckGear
        else:
          bot.phase = PathToBuyStall
    return 0

  of PathToGathererStall:
    if p.role == "Gatherer":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    let stallOpt = nearestObject(state, "GathererStallObj")
    if stallOpt.isNone: return 0
    let stall = stallOpt.get()
    if isAdjacentTo(p.x, p.y, stall.tx, stall.ty):
      bot.phase = InteractGathererStall
      bot.ticksInPhase = 0
      return facingMask(stall.tx, stall.ty, p.tx, p.ty)
    if not bot.nav.hasPath or bot.ticksInPhase mod 30 == 1:
      bot.nav.navigateAdjacent(state, stall.tx, stall.ty)
    return bot.nav.followPath(p.x, p.y)

  of InteractGathererStall:
    if p.role == "Gatherer":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if bot.ticksInPhase > 20:
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      return 0
    let stallOpt = nearestObject(state, "GathererStallObj")
    if stallOpt.isSome:
      let stall = stallOpt.get()
      return facingMask(stall.tx, stall.ty, p.tx, p.ty) or ButtonA
    return ButtonA

  of PathToCrafterStall:
    if p.role == "Crafter":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    let stallOpt = nearestObject(state, "CrafterStallObj")
    if stallOpt.isNone: return 0
    let stall = stallOpt.get()
    if isAdjacentTo(p.x, p.y, stall.tx, stall.ty):
      bot.phase = InteractCrafterStall
      bot.ticksInPhase = 0
      return facingMask(stall.tx, stall.ty, p.tx, p.ty)
    if not bot.nav.hasPath or bot.ticksInPhase mod 30 == 1:
      bot.nav.navigateAdjacent(state, stall.tx, stall.ty)
    return bot.nav.followPath(p.x, p.y)

  of InteractCrafterStall:
    if p.role == "Crafter":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if bot.ticksInPhase > 20:
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      return 0
    let stallOpt = nearestObject(state, "CrafterStallObj")
    if stallOpt.isSome:
      let stall = stallOpt.get()
      return facingMask(stall.tx, stall.ty, p.tx, p.ty) or ButtonA
    return ButtonA

  of PathToNode:
    if p.hasSellableMaterials and p.canSellMore:
      bot.phase = PathToSellStall
      bot.ticksInPhase = 0
      return 0
    let nodeOpt = nearestGatherableNode(state, p, cachedListings = bot.lastSeenListings)
    if nodeOpt.isNone:
      let anyNode = nearestObject(state, "GatherNodeObj", undepleted = false)
      if anyNode.isSome:
        let node = anyNode.get()
        if not bot.nav.hasPath or bot.ticksInPhase mod 30 == 1:
          bot.nav.navigateTo(state, node.tx, node.ty)
        return bot.nav.followPath(p.x, p.y)
      return 0
    let node = nodeOpt.get()
    if isOnTile(p.x, p.y, node.tx, node.ty) or isAdjacentTo(p.x, p.y, node.tx, node.ty):
      bot.phase = StartGathering
      bot.ticksInPhase = 0
      return facingMask(node.tx, node.ty, p.tx, p.ty)
    if not bot.nav.hasPath or bot.ticksInPhase mod 30 == 1:
      bot.nav.navigateTo(state, node.tx, node.ty)
    return bot.nav.followPath(p.x, p.y)

  of StartGathering:
    if p.state == "Gathering":
      bot.phase = HoldGathering
      bot.ticksInPhase = 0
      return ButtonA
    if bot.ticksInPhase > 10:
      bot.phase = PathToNode
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      return 0
    let nodeOpt = nearestGatherableNode(state, p, cachedListings = bot.lastSeenListings)
    if nodeOpt.isSome:
      let node = nodeOpt.get()
      return facingMask(node.tx, node.ty, p.tx, p.ty) or ButtonA
    return ButtonA

  of HoldGathering:
    if p.state == "Idle":
      bot.ticksInPhase = 0
      if hasAffordableGearUpgradeCached(state, p, bot.lastSeenListings):
        bot.phase = CheckGear
      elif shouldCancelListings(p):
        bot.phase = PathToCancelStall
      elif p.hasSellableMaterials and p.canSellMore:
        bot.phase = PathToSellStall
      else:
        bot.phase = WaitForState
      return 0
    return ButtonA

  of PathToBuyStall:
    if hasEnoughMaterialsForCraft(p.inv):
      bot.phase = PathToCraftStation
      bot.ticksInPhase = 0
      return 0
    let stallOpt = nearestObject(state, "BuyStallObj")
    if stallOpt.isNone: return 0
    let stall = stallOpt.get()
    if isAdjacentTo(p.x, p.y, stall.tx, stall.ty):
      bot.phase = InteractBuyStall
      bot.ticksInPhase = 0
      return facingMask(stall.tx, stall.ty, p.tx, p.ty)
    if not bot.nav.hasPath or bot.ticksInPhase mod 30 == 1:
      bot.nav.navigateAdjacent(state, stall.tx, stall.ty)
    return bot.nav.followPath(p.x, p.y)

  of InteractBuyStall:
    if p.state == "AtBuyStall":
      bot.phase = BuyMaterials
      bot.ticksInPhase = 0
      return 0
    if bot.ticksInPhase > 20:
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      return 0
    return ButtonA

  of BuyMaterials:
    if p.state != "AtBuyStall":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if hasEnoughMaterialsForCraft(p.inv):
      bot.phase = ExitBuyMat
      bot.ticksInPhase = 0
      return 0
    let selfTier = lowestNeededGearTier(p)
    let craftTier = if selfTier > 0 and selfTier <= highestGatherableTier(p):
        let (sA, sB) = materialsForTier(selfTier)
        let selfAvail = hasListings(state, sA) or hasListings(state, sB)
        if selfAvail: selfTier else: demandAwareCraftTier(state, p)
      else:
        demandAwareCraftTier(state, p)
    let (matA, matB) = materialsForTier(craftTier)
    let priceA = cheapestPrice(state, matA)
    let priceB = cheapestPrice(state, matB)
    let availA = hasListings(state, matA)
    let availB = hasListings(state, matB)
    var useB = false
    if availA and availB:
      useB = priceB < priceA
    elif availB:
      useB = true
    elif not availA:
      bot.phase = ExitBuyMat
      bot.ticksInPhase = 0
      return 0
    let matName = if useB: matB else: matA
    let matPrice = if useB: priceB else: priceA
    let have = p.inv.itemCount(matName)
    let needed = 3 - have
    if needed <= 0:
      bot.phase = ExitBuyMat
      bot.ticksInPhase = 0
      return 0
    if p.gold < matPrice:
      bot.phase = ExitBuyMat
      bot.ticksInPhase = 0
      return 0
    let targetCursor = itemCursorIndex(matName)
    if p.buyItemCursor < targetCursor:
      return ButtonRight
    if p.buyItemCursor > targetCursor:
      return ButtonLeft
    if p.buyQuantity < needed:
      return ButtonUp
    if p.buyQuantity > needed:
      return ButtonDown
    if (bot.prevMask and ButtonA) != 0:
      return 0
    return ButtonA

  of ExitBuyMat:
    if p.state == "Idle":
      bot.ticksInPhase = 0
      if hasEnoughMaterialsForCraft(p.inv):
        bot.phase = PathToCraftStation
      else:
        bot.phase = WaitForState
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

  of PathToCraftStation:
    if not hasEnoughMaterialsForCraft(p.inv):
      bot.phase = PathToBuyStall
      bot.ticksInPhase = 0
      return 0
    let stationOpt = nearestObject(state, "CraftStationObj", undepleted = false)
    if stationOpt.isNone: return 0
    let station = stationOpt.get()
    if isOnTile(p.x, p.y, station.tx, station.ty) or isAdjacentTo(p.x, p.y, station.tx, station.ty):
      bot.phase = StartCrafting
      bot.ticksInPhase = 0
      return facingMask(station.tx, station.ty, p.tx, p.ty)
    if not bot.nav.hasPath or bot.ticksInPhase mod 30 == 1:
      bot.nav.navigateAdjacent(state, station.tx, station.ty)
    return bot.nav.followPath(p.x, p.y)

  of StartCrafting:
    if p.state == "Crafting":
      bot.phase = HoldCrafting
      bot.ticksInPhase = 0
      return ButtonA
    if not hasEnoughMaterialsForCraft(p.inv):
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      return 0
    let stationOpt = nearestObject(state, "CraftStationObj", undepleted = false)
    if stationOpt.isSome:
      let station = stationOpt.get()
      return facingMask(station.tx, station.ty, p.tx, p.ty) or ButtonA
    return ButtonA

  of HoldCrafting:
    if p.state == "Idle":
      bot.ticksInPhase = 0
      if p.inv.hasAnyGear:
        bot.phase = PathToSellStall
      else:
        bot.phase = WaitForState
      return 0
    return ButtonA

  of PathToSellStall:
    let hasItems = hasAnyRawMaterials(p.inv) or p.inv.hasAnyGear
    if not hasItems:
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    let stallOpt = nearestObject(state, "SellStallObj")
    if stallOpt.isNone: return 0
    let stall = stallOpt.get()
    if isAdjacentTo(p.x, p.y, stall.tx, stall.ty):
      bot.phase = InteractSellStall
      bot.ticksInPhase = 0
      return facingMask(stall.tx, stall.ty, p.tx, p.ty)
    if not bot.nav.hasPath or bot.ticksInPhase mod 30 == 1:
      bot.nav.navigateAdjacent(state, stall.tx, stall.ty)
    return bot.nav.followPath(p.x, p.y)

  of InteractSellStall:
    if p.state == "AtSellStall":
      bot.phase = SetPrice
      bot.ticksInPhase = 0
      return 0
    if bot.ticksInPhase > 20:
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      return 0
    let stallOpt = nearestObject(state, "SellStallObj")
    if stallOpt.isSome:
      let stall = stallOpt.get()
      return facingMask(stall.tx, stall.ty, p.tx, p.ty) or ButtonA
    return ButtonA

  of SetPrice:
    if p.state != "AtSellStall":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    let itemName = sellCursorItemName(p)
    if p.role == "Gatherer":
      let maxTier = highestGatherableTier(p)
      if not isSellableAtTier(itemName, maxTier):
        let target = nextSellCursorForTier(p)
        if target < 0 or target == p.sellItemCursor:
          bot.phase = ExitSell
          bot.ticksInPhase = 0
          return 0
        if p.sellItemCursor < target:
          return ButtonRight
        return ButtonLeft
    let baseTarget = botItemBasePrice(itemName) + 1
    let targetPrice = dynamicPrice(bot.pricingState, p.listings.len, baseTarget)
    if p.sellPrice < targetPrice:
      return ButtonUp
    elif p.sellPrice > targetPrice:
      return ButtonDown
    bot.phase = ConfirmSell
    bot.ticksInPhase = 0
    return 0

  of ConfirmSell:
    if p.state != "AtSellStall":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if not hasAnyRawMaterials(p.inv) and not p.inv.hasAnyGear:
      bot.phase = ExitSell
      bot.ticksInPhase = 0
      return 0
    if p.listings.len >= BotMaxSellSlots:
      bot.phase = ExitSell
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      bot.phase = SetPrice
      bot.ticksInPhase = 0
      return 0
    return ButtonA

  of ExitSell:
    if p.state == "Idle":
      bot.phase = CheckGear
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

  of CheckGear:
    bot.ticksInPhase = 0
    let target = nextGearTargetCached(state, p, bot.lastSeenListings)
    if target.slot < 0:
      bot.phase = WaitForState
      return 0
    let all = state.allListings()
    let listing = cheapestListing(all, target.item)
    if listing.isNone or listing.get().priceEach > p.gold:
      bot.phase = WaitForState
      return 0
    bot.targetGearItem = target.item
    bot.targetGearCursor = itemCursorIndex(bot.targetGearItem)
    bot.phase = PathToBuyGearStall
    return 0

  of PathToBuyGearStall:
    let stallOpt = nearestObject(state, "BuyStallObj")
    if stallOpt.isNone: return 0
    let stall = stallOpt.get()
    if isAdjacentTo(p.x, p.y, stall.tx, stall.ty):
      bot.phase = InteractBuyGearStall
      bot.ticksInPhase = 0
      return facingMask(stall.tx, stall.ty, p.tx, p.ty)
    if not bot.nav.hasPath or bot.ticksInPhase mod 30 == 1:
      bot.nav.navigateAdjacent(state, stall.tx, stall.ty)
    return bot.nav.followPath(p.x, p.y)

  of InteractBuyGearStall:
    if p.state == "AtBuyStall":
      bot.phase = SelectGearItem
      bot.ticksInPhase = 0
      return 0
    if bot.ticksInPhase > 20:
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      return 0
    return ButtonA

  of SelectGearItem:
    if p.state != "AtBuyStall":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if p.buyItemCursor < bot.targetGearCursor:
      return ButtonRight
    if p.buyItemCursor > bot.targetGearCursor:
      return ButtonLeft
    bot.phase = BuyGear
    bot.ticksInPhase = 0
    return 0

  of BuyGear:
    if p.state != "AtBuyStall":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if p.buyQuantity < 1:
      return ButtonUp
    if (bot.prevMask and ButtonA) != 0:
      bot.phase = ExitBuyGear
      bot.ticksInPhase = 0
      return 0
    return ButtonA

  of ExitBuyGear:
    if p.state == "Idle":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

  of PathToCancelStall:
    let stallOpt = nearestObject(state, "CancelStallObj")
    if stallOpt.isNone:
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    let stall = stallOpt.get()
    if isAdjacentTo(p.x, p.y, stall.tx, stall.ty):
      bot.phase = InteractCancelStall
      bot.ticksInPhase = 0
      return facingMask(stall.tx, stall.ty, p.tx, p.ty)
    if not bot.nav.hasPath or bot.ticksInPhase mod 30 == 1:
      bot.nav.navigateAdjacent(state, stall.tx, stall.ty)
    return bot.nav.followPath(p.x, p.y)

  of InteractCancelStall:
    if p.listings.len == 0:
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if bot.ticksInPhase > 20:
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      return 0
    let stallOpt = nearestObject(state, "CancelStallObj")
    if stallOpt.isSome:
      let stall = stallOpt.get()
      return facingMask(stall.tx, stall.ty, p.tx, p.ty) or ButtonA
    return ButtonA

proc runBot(host: string, port: int, name: string) =
  echo "R'khenna connecting to ", host, ":", port, " as ", name
  let ws = connectBot(host, port, name)
  var bot = BotState(phase: WaitForState)

  while true:
    let stateOpt = receiveState(ws)
    if stateOpt.isNone:
      continue
    let state = stateOpt.get()

    let mask = bot.decide(state)
    sendInput(ws, mask)
    bot.prevMask = mask


when isMainModule:
  var
    host = "localhost"
    port = 8080
    name = "Rkhenna"
    pendingOption = ""

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      pendingOption = ""
      case key
      of "address":
        if val.len > 0: host = val
        else: pendingOption = "address"
      of "port":
        if val.len > 0: port = parseInt(val)
        else: pendingOption = "port"
      of "name":
        if val.len > 0: name = val
        else: pendingOption = "name"
      else: discard
    of cmdArgument:
      case pendingOption
      of "address": host = key
      of "port": port = parseInt(key)
      of "name": name = key
      else: discard
      pendingOption = ""
    else: discard

  runBot(host, port, name)

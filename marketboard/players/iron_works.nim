# Iron Works -- Roegadyn Hellsguard. Specialist crafter.
# Picks the Crafter role at game start and never switches. Buys wood from
# the market, crafts gear at the station, sells gear at a fair margin.
# The forgemaster counterpart to Still Forge the gatherer.

import std/[options, os, parseopt, strutils]
import whisky
import protocol
import common

type
  BotPhase* = enum
    WaitForState
    PathToCrafterStall
    InteractCrafterStall
    CheckGear
    PathToBuyGearStall
    InteractBuyGearStall
    SelectGearItem
    BuyGearItem
    ExitBuyGear
    PathToBuyStall
    InteractBuyStall
    BuyMaterials
    ExitBuy
    PathToCraftStation
    StartCrafting
    HoldCrafting
    PathToSellStall
    InteractSellStall
    SelectSellItem
    SetPrice
    ConfirmSell
    ExitSell
    PathToCancelStall
    InteractCancelStall

  BotState* = object
    phase*: BotPhase
    nav*: Navigator
    prevMask*: uint8
    ticksInPhase*: int
    targetGearItem*: string
    targetGearCursor*: int
    targetBuyCursor*: int
    pricingState*: PricingState
    buyMatFlip*: bool
    targetMatName*: string
    targetMatNeeded*: int
    cancelCycles*: int
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
    if p.role == "Crafter":
      let maxTier = highestGatherableTier(p)
      if bot.cancelCycles > 0 and (not canAffordAnyMaterial(state, p) or p.hasFullGearSet(3)):
        bot.cancelCycles = 0
      if (shouldCancelListings(p) or shouldCancelForUpgrade(p)) and not p.hasFullGearSet(3):
        bot.phase = PathToCancelStall
      elif p.inv.hasAnyGear and p.canSellMore and
           (not p.hasFullGearSet(3) and bot.cancelCycles < 3 or p.hasHighTierGearInv(maxTier)):
        bot.phase = PathToSellStall
      elif hasEnoughMaterialsForCraft(p.inv):
        bot.phase = PathToCraftStation
      elif hasAffordableGearUpgradeCached(state, p, bot.lastSeenListings):
        bot.phase = CheckGear
      elif canAffordAnyMaterial(state, p):
        bot.phase = PathToBuyStall
      elif p.listings.len > 0 and not p.hasFullGearSet(3):
        bot.phase = PathToCancelStall
      else:
        bot.phase = WaitForState
    else:
      bot.phase = PathToCrafterStall
    return 0

  of PathToCrafterStall:
    if p.role == "Crafter":
      bot.phase = PathToBuyStall
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
      bot.phase = PathToBuyStall
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

  of CheckGear:
    let target = nextGearTargetCached(state, p, bot.lastSeenListings)
    if target.slot < 0:
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    bot.targetGearCursor = target.slot
    bot.phase = PathToBuyGearStall
    bot.ticksInPhase = 0
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
    bot.phase = BuyGearItem
    bot.ticksInPhase = 0
    return 0

  of BuyGearItem:
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
      bot.phase = CheckGear
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

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
      bot.targetMatName = ""
      bot.targetMatNeeded = 0
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
      bot.phase = ExitBuy
      bot.ticksInPhase = 0
      return 0
    if bot.targetMatName.len == 0:
      let selfTier = lowestNeededGearTier(p)
      let craftTier = if selfTier > 0 and selfTier <= highestGatherableTier(p):
          let (sA, sB) = materialsForTier(selfTier)
          let selfAvail = hasListings(state, sA) or hasListings(state, sB)
          if selfAvail: selfTier else: demandAwareCraftTier(state, p)
        else:
          demandAwareCraftTier(state, p)
      let (matA, matB) = materialsForTier(craftTier)
      let availA = hasListings(state, matA)
      let availB = hasListings(state, matB)
      let priceA = if availA: cheapestPrice(state, matA) else: int.high
      let priceB = if availB: cheapestPrice(state, matB) else: int.high
      let haveA = p.inv.itemCount(matA)
      let haveB = p.inv.itemCount(matB)
      let needed = underSuppliedMaterial(p, state, craftTier)
      var preferred, fallback: string
      if needed.len > 0 and needed == matB:
        preferred = matB; fallback = matA
      elif needed.len > 0 and needed == matA:
        preferred = matA; fallback = matB
      elif bot.buyMatFlip:
        preferred = matB; fallback = matA
      else:
        preferred = matA; fallback = matB
      bot.buyMatFlip = not bot.buyMatFlip
      let prefAvail = if preferred == matA: availA else: availB
      let prefPrice = if preferred == matA: priceA else: priceB
      let fbAvail = if fallback == matA: availA else: availB
      let fbPrice = if fallback == matA: priceA else: priceB
      let havePref = p.inv.itemCount(preferred)
      let haveFb = p.inv.itemCount(fallback)
      if havePref < 3 and prefAvail and p.gold >= prefPrice:
        bot.targetMatName = preferred
        bot.targetMatNeeded = 3 - havePref
      elif haveFb < 3 and fbAvail and p.gold >= fbPrice:
        bot.targetMatName = fallback
        bot.targetMatNeeded = 3 - haveFb
      else:
        bot.phase = ExitBuy
        bot.ticksInPhase = 0
        return 0
    if bot.targetMatNeeded <= 0:
      bot.phase = ExitBuy
      bot.ticksInPhase = 0
      return 0
    if p.gold < cheapestPrice(state, bot.targetMatName):
      bot.phase = ExitBuy
      bot.ticksInPhase = 0
      return 0
    let targetCursor = itemCursorIndex(bot.targetMatName)
    if p.buyItemCursor < targetCursor:
      return ButtonRight
    if p.buyItemCursor > targetCursor:
      return ButtonLeft
    if p.buyQuantity < bot.targetMatNeeded:
      return ButtonUp
    if p.buyQuantity > bot.targetMatNeeded:
      return ButtonDown
    if (bot.prevMask and ButtonA) != 0:
      return 0
    return ButtonA

  of ExitBuy:
    if p.state == "Idle":
      bot.ticksInPhase = 0
      if hasEnoughMaterialsForCraft(p.inv):
        bot.cancelCycles = 0
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
    let stationOpt = bestCraftStation(state, p)
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
    let stationOpt = bestCraftStation(state, p)
    if stationOpt.isSome:
      let station = stationOpt.get()
      return facingMask(station.tx, station.ty, p.tx, p.ty) or ButtonA
    return ButtonA

  of HoldCrafting:
    if p.state == "Idle":
      bot.ticksInPhase = 0
      bot.cancelCycles = 0
      if p.inv.hasAnyGear and p.canSellMore:
        bot.phase = PathToSellStall
      else:
        bot.phase = WaitForState
      return 0
    return ButtonA

  of PathToSellStall:
    if not p.inv.hasAnyGear:
      bot.phase = PathToBuyStall
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
      bot.phase = SelectSellItem
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

  of SelectSellItem:
    if p.state != "AtSellStall":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    let maxTier = highestGatherableTier(p)
    let minSellTier = if p.hasFullGearSet(3): maxTier else: 1
    let gearCursor = firstGearSellCursor(p, minSellTier)
    if gearCursor < 0:
      bot.phase = ExitSell
      bot.ticksInPhase = 0
      return 0
    if p.sellItemCursor < gearCursor:
      return ButtonRight
    if p.sellItemCursor > gearCursor:
      return ButtonLeft
    bot.phase = SetPrice
    bot.ticksInPhase = 0
    return 0

  of SetPrice:
    if p.state != "AtSellStall":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    let itemName = sellCursorItemName(p)
    let baseTarget = botItemBasePrice(itemName) + 2
    var targetPrice = dynamicPrice(bot.pricingState, p.listings.len, baseTarget)
    if bot.cancelCycles > 0:
      targetPrice = max(baseTarget div 2, targetPrice - bot.cancelCycles)
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
    if not p.inv.hasAnyGear:
      bot.phase = ExitSell
      bot.ticksInPhase = 0
      return 0
    if p.listings.len >= BotMaxSellSlots:
      bot.phase = ExitSell
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      bot.phase = SelectSellItem
      bot.ticksInPhase = 0
      return 0
    return ButtonA

  of ExitSell:
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
      inc bot.cancelCycles
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
  echo "Iron Works connecting to ", host, ":", port, " as ", name
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
    name = "IronWorks"
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

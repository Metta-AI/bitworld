# Pipitori Lalori -- Lalafell Plainsfolk. Gouger.
# Pure market manipulator. Never picks a role, never gathers or crafts.
# Scans the market for cheap listings, buys them, and relists at 3-4x the price.
# If nothing cheap is available, idles and waits.

import std/[options, os, parseopt, strutils]
import whisky
import protocol
import common

const
  BuyThresholdMultiplier = 2
  RelistMultiplier = 3
  WaitTicks = 60

type
  BotPhase* = enum
    WaitForState
    ScanMarket
    WaitForOpportunity
    PathToBuyStall
    InteractBuyStall
    SelectItem
    SetBuyQuantity
    ConfirmBuy
    ExitBuy
    PathToSellStall
    InteractSellStall
    SetPrice
    ConfirmSell
    ExitSell

  BotState* = object
    phase*: BotPhase
    nav*: Navigator
    prevMask*: uint8
    ticksInPhase*: int
    targetItem*: string
    targetCursor*: int
    buyPrice*: int
    waitCounter*: int

proc decide*(bot: var BotState, state: GameState): uint8 =
  let p = state.player
  inc bot.ticksInPhase

  case bot.phase
  of WaitForState:
    bot.ticksInPhase = 0
    if p.inv.hasAnyGear or p.inv.wood > 0 or p.inv.stone > 0:
      bot.phase = PathToSellStall
    else:
      bot.phase = ScanMarket
    return 0

  of ScanMarket:
    bot.ticksInPhase = 0
    var bestItem = ""
    var bestMargin = 0
    var bestPrice = 0
    let all = state.allListings()
    for name in ItemNames:
      let listing = cheapestListing(all, name)
      if listing.isNone: continue
      let l = listing.get()
      let basePrice = if name == "WoodItem" or name == "StoneItem": 5 else: 20
      if l.priceEach <= basePrice * BuyThresholdMultiplier:
        let margin = basePrice * RelistMultiplier - l.priceEach
        if margin > bestMargin:
          bestMargin = margin
          bestItem = name
          bestPrice = l.priceEach
    if bestItem.len > 0 and p.gold >= bestPrice:
      bot.targetItem = bestItem
      bot.targetCursor = itemCursorIndex(bestItem)
      bot.buyPrice = bestPrice
      bot.phase = PathToBuyStall
    else:
      bot.phase = WaitForOpportunity
      bot.waitCounter = 0
    return 0

  of WaitForOpportunity:
    inc bot.waitCounter
    if bot.waitCounter >= WaitTicks:
      bot.phase = ScanMarket
      bot.ticksInPhase = 0
    return 0

  of PathToBuyStall:
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
      bot.phase = SelectItem
      bot.ticksInPhase = 0
      return 0
    if bot.ticksInPhase > 20:
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      return 0
    let stallOpt = nearestObject(state, "BuyStallObj")
    if stallOpt.isSome:
      let stall = stallOpt.get()
      return facingMask(stall.tx, stall.ty, p.tx, p.ty) or ButtonA
    return ButtonA

  of SelectItem:
    if p.state != "AtBuyStall":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if bot.ticksInPhase > 20:
      bot.phase = ExitBuy
      bot.ticksInPhase = 0
      return 0
    if p.buyItemCursor < bot.targetCursor:
      return ButtonRight
    if p.buyItemCursor > bot.targetCursor:
      return ButtonLeft
    bot.phase = SetBuyQuantity
    bot.ticksInPhase = 0
    return 0

  of SetBuyQuantity:
    if p.state != "AtBuyStall":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if p.buyQuantity < 1:
      return ButtonUp
    bot.phase = ConfirmBuy
    bot.ticksInPhase = 0
    return 0

  of ConfirmBuy:
    if p.state != "AtBuyStall":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    if bot.ticksInPhase > 10:
      bot.phase = ExitBuy
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      bot.phase = ExitBuy
      bot.ticksInPhase = 0
      return 0
    return ButtonA

  of ExitBuy:
    if p.state == "Idle":
      let hasItems = p.inv.wood > 0 or p.inv.stone > 0 or p.inv.hasAnyGear
      if hasItems:
        bot.phase = PathToSellStall
      else:
        bot.phase = ScanMarket
      bot.ticksInPhase = 0
      return 0
    if bot.ticksInPhase > 20:
      bot.phase = ScanMarket
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

  of PathToSellStall:
    let hasItems = p.inv.wood > 0 or p.inv.stone > 0 or p.inv.hasAnyGear
    if not hasItems:
      bot.phase = ScanMarket
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
    let targetPrice = max(1, bot.buyPrice * RelistMultiplier)
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
    if p.inv.wood == 0 and p.inv.stone == 0 and not p.inv.hasAnyGear:
      bot.phase = ExitSell
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      return 0
    return ButtonA

  of ExitSell:
    if p.state == "Idle":
      bot.phase = ScanMarket
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

proc runBot(host: string, port: int, name: string) =
  echo "Pipitori connecting to ", host, ":", port, " as ", name
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

    if bot.ticksInPhase > 300:
      echo "Pipitori stuck in ", bot.phase, " for ", bot.ticksInPhase, " ticks, resetting"
      bot.phase = WaitForState
      bot.ticksInPhase = 0

when isMainModule:
  var
    host = "localhost"
    port = 8080
    name = "Pipitori"
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

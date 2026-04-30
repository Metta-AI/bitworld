# Iron Works -- Roegadyn Hellsguard. Specialist crafter.
# Picks the Crafter role at game start and never switches. Buys wood from
# the market, crafts gear at the station, sells gear at a fair margin.
# The forgemaster counterpart to Still Forge the gatherer.

import std/[options, os, parseopt, strutils]
import whisky
import protocol
import common

type
  BotPhase = enum
    WaitForState
    PathToCrafterStall
    InteractCrafterStall
    PathToBuyStall
    InteractBuyStall
    BuyMaterials
    ExitBuy
    PathToCraftStation
    StartCrafting
    HoldCrafting
    PathToSellStall
    InteractSellStall
    SetPrice
    ConfirmSell
    ExitSell

  BotState = object
    phase: BotPhase
    nav: Navigator
    prevMask: uint8
    ticksInPhase: int

proc decide(bot: var BotState, state: GameState): uint8 =
  let p = state.player
  inc bot.ticksInPhase

  case bot.phase
  of WaitForState:
    bot.ticksInPhase = 0
    if p.role == "Crafter":
      if p.inv.woodGear > 0 or p.inv.stoneGear > 0:
        bot.phase = PathToSellStall
      elif p.inv.wood >= 3:
        bot.phase = PathToCraftStation
      else:
        bot.phase = PathToBuyStall
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
    if (bot.prevMask and ButtonA) != 0:
      return 0
    let stallOpt = nearestObject(state, "CrafterStallObj")
    if stallOpt.isSome:
      let stall = stallOpt.get()
      return facingMask(stall.tx, stall.ty, p.tx, p.ty) or ButtonA
    return ButtonA

  of PathToBuyStall:
    if p.inv.wood >= 3:
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
    if (bot.prevMask and ButtonA) != 0:
      return 0
    # Press A only — no direction, to avoid buyItemCursor shift from left/right
    return ButtonA

  of BuyMaterials:
    if p.state != "AtBuyStall":
      bot.phase = WaitForState
      bot.ticksInPhase = 0
      return 0
    let needed = 3 - p.inv.wood
    if needed <= 0:
      bot.phase = ExitBuy
      bot.ticksInPhase = 0
      return 0
    if p.buyQuantity < needed:
      return ButtonUp
    if p.buyQuantity > needed:
      return ButtonDown
    if (bot.prevMask and ButtonA) != 0:
      return 0
    return ButtonA

  of ExitBuy:
    if p.state == "Idle":
      bot.ticksInPhase = 0
      if p.inv.wood >= 3:
        bot.phase = PathToCraftStation
      else:
        bot.phase = PathToBuyStall
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

  of PathToCraftStation:
    if p.inv.wood < 3:
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
      if p.inv.woodGear > 0 or p.inv.stoneGear > 0:
        bot.phase = PathToSellStall
      else:
        bot.phase = PathToBuyStall
      return 0
    return ButtonA

  of PathToSellStall:
    if p.inv.woodGear == 0 and p.inv.stoneGear == 0:
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
      bot.phase = SetPrice
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
    let targetPrice = 30
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
    if p.inv.woodGear == 0 and p.inv.stoneGear == 0:
      bot.phase = ExitSell
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      return 0
    return ButtonA

  of ExitSell:
    if p.state == "Idle":
      bot.phase = PathToBuyStall
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

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

    if bot.ticksInPhase > 300:
      echo "Iron Works stuck in ", bot.phase, " for ", bot.ticksInPhase, " ticks, resetting"
      bot.phase = WaitForState
      bot.ticksInPhase = 0

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

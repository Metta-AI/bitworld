# Still Forge -- Roegadyn Hellsguard. Specialist gatherer.
# Picks one role at game start and never switches. Gathers wood, returns to sell
# at a fair markup above base value. Steady and reliable -- the backbone of a
# healthy economy.

import std/[options, os, parseopt, strutils]
import whisky
import protocol
import common

type
  BotPhase = enum
    WaitForState
    PathToGathererStall
    InteractGathererStall
    PathToWoodNode
    StartGathering
    HoldGathering
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
    if p.role == "Gatherer":
      if p.inv.wood > 0:
        bot.phase = PathToSellStall
      else:
        bot.phase = PathToWoodNode
    else:
      bot.phase = PathToGathererStall
    return 0

  of PathToGathererStall:
    if p.role == "Gatherer":
      bot.phase = PathToWoodNode
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
      bot.phase = PathToWoodNode
      bot.ticksInPhase = 0
      return 0
    # Release A first so aPressed triggers
    if (bot.prevMask and ButtonA) != 0:
      return 0
    let stallOpt = nearestObject(state, "GathererStallObj")
    if stallOpt.isSome:
      let stall = stallOpt.get()
      return facingMask(stall.tx, stall.ty, p.tx, p.ty) or ButtonA
    return ButtonA

  of PathToWoodNode:
    let nodeOpt = nearestObject(state, "GatherNodeObj", material = "WoodItem")
    if nodeOpt.isNone: return 0
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
    # Release A so aPressed triggers
    if (bot.prevMask and ButtonA) != 0:
      return 0
    let nodeOpt = nearestObject(state, "GatherNodeObj", material = "WoodItem")
    if nodeOpt.isSome:
      let node = nodeOpt.get()
      return facingMask(node.tx, node.ty, p.tx, p.ty) or ButtonA
    return ButtonA

  of HoldGathering:
    if p.state == "Idle":
      bot.ticksInPhase = 0
      if p.inv.wood > 0:
        bot.phase = PathToSellStall
      else:
        bot.phase = PathToWoodNode
      return 0
    return ButtonA

  of PathToSellStall:
    if p.inv.wood == 0:
      bot.phase = PathToWoodNode
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
    let targetPrice = 8
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
    if p.inv.wood == 0 and p.inv.stone == 0 and p.inv.woodGear == 0 and p.inv.stoneGear == 0:
      bot.phase = ExitSell
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonA) != 0:
      return 0
    return ButtonA

  of ExitSell:
    if p.state == "Idle":
      bot.phase = PathToWoodNode
      bot.ticksInPhase = 0
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

proc runBot(host: string, port: int, name: string) =
  echo "Still Forge connecting to ", host, ":", port, " as ", name
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
      echo "Still Forge stuck in ", bot.phase, " for ", bot.ticksInPhase, " ticks, resetting"
      bot.phase = WaitForState
      bot.ticksInPhase = 0

when isMainModule:
  var
    host = "localhost"
    port = 8080
    name = "StillForge"
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

import std/options
import protocol
import common

type
  ActionKind* = enum
    akSetRole
    akGather
    akSell
    akBuyGear
    akBuyMaterials
    akCraft
    akIdle

  Action* = object
    case kind*: ActionKind
    of akSetRole:
      roleStall*: string
    of akGather:
      gatherMaterial*: string
      targetNode*: Option[BotObject]
    of akSell:
      discard
    of akBuyGear:
      targetGear*: string
      targetGearCursor*: int
    of akBuyMaterials:
      buyMaterial*: string
      buyMaterialCursor*: int
      buyQuantity*: int
    of akCraft:
      discard
    of akIdle:
      discard

  ExecPhase* = enum
    epNavigate
    epInteract
    epPerform
    epExit

  Commitment* = object
    action*: Action
    ticksActive*: int
    execPhase*: ExecPhase
    phaseStartTick*: int
    itemsListedThisVisit*: int

  PersonalityWeights* = object
    gatherWoodBias*: float
    gatherStoneBias*: float
    sellUrgency*: float
    gearPriority*: float
    batchPatience*: float
    interruptThreshold*: float
    craftInterest*: float
    buyMaterialsUrgency*: float

  UtilityBot* = object
    weights*: PersonalityWeights
    commitment*: Option[Commitment]
    buyGearCooldownUntil*: int
    buyGearFailCount*: int
    buyMatCooldownUntil*: int
    buyMatFailCount*: int
    nav*: Navigator
    pricingState*: PricingState
    prevMask*: uint8
    ticksTotal*: int
    phase*: string


proc sellableItemCount(player: BotPlayer): int =
  for name in RawMaterialNames:
    result += player.inv.itemCount(name)
  if player.inv.hasAnyGear:
    result += 1

proc distToNearest(state: GameState, kind: string): int =
  let obj = nearestObject(state, kind)
  if obj.isSome:
    manhattanDist(state.player.x, state.player.y, obj.get().tx, obj.get().ty)
  else:
    999

proc scoreGather(state: GameState, bot: UtilityBot, node: BotObject): float =
  let p = state.player
  let dist = max(1, manhattanDist(p.x, p.y, node.tx, node.ty))
  let basePrice = float(botItemBasePrice(node.material))
  let materialBias = case node.material
    of "WoodItem", "HardwoodItem", "IronwoodItem": bot.weights.gatherWoodBias
    of "StoneItem", "CopperItem", "IronItem": bot.weights.gatherStoneBias
    else: 1.0
  (basePrice * materialBias) / float(dist)

proc scoreSell(state: GameState, bot: UtilityBot): float =
  let p = state.player
  if not p.canSellMore: return 0.0
  var totalValue = 0
  var itemCount = 0
  if bot.weights.craftInterest <= 0.0:
    for name in RawMaterialNames:
      let count = p.inv.itemCount(name)
      if count > 0:
        totalValue += count * botItemBasePrice(name)
        itemCount += count
  for name in GearItemNames:
    let count = p.inv.itemCount(name)
    if count > 0:
      totalValue += count * botItemBasePrice(name)
      itemCount += count
  if itemCount == 0: return 0.0
  let minItems = max(3, int(bot.weights.batchPatience + 1.0))
  if itemCount < minItems and not p.inv.hasAnyGear: return 0.0
  let fullness = float(itemCount) / (3.0 + bot.weights.batchPatience * 2.0)
  float(totalValue) * bot.weights.sellUrgency * min(1.0, fullness)

proc equippedGearCount(p: BotPlayer): int =
  for i in 0 ..< 5:
    if isGearItem(p.equippedGear[i]):
      result += 1

proc scoreBuyGear(state: GameState, bot: UtilityBot): float =
  let p = state.player
  if bot.ticksTotal < bot.buyGearCooldownUntil: return 0.0
  let equipped = equippedGearCount(p)
  if equipped >= 5: return 0.0
  let all = state.allListings()
  let target = nextGearTarget(state, p)
  if target.slot >= 0:
    let listing = cheapestListing(all, target.item)
    if listing.isSome and listing.get().priceEach <= p.gold:
      let gearValue = float(botItemBasePrice(target.item))
      return gearValue * bot.weights.gearPriority / 5.0
  0.0

proc scoreBuyMaterials(state: GameState, bot: UtilityBot): float =
  let p = state.player
  if bot.weights.buyMaterialsUrgency <= 0.0: return 0.0
  if p.role != "Crafter": return 0.0
  if bot.ticksTotal < bot.buyMatCooldownUntil: return 0.0
  if hasEnoughMaterialsForCraft(p.inv): return 0.0
  let craftTier = demandAwareCraftTier(state, p)
  let (matA, matB) = materialsForTier(craftTier)
  let availA = hasListings(state, matA)
  let availB = hasListings(state, matB)
  if not availA and not availB: return 0.0
  let cheapest = min(
    if availA: cheapestPrice(state, matA) else: int.high,
    if availB: cheapestPrice(state, matB) else: int.high)
  if cheapest > p.gold: return 0.0
  let totalAvailable = supplyCount(state, matA) + supplyCount(state, matB)
  if totalAvailable < 3: return 0.0
  float(botItemBasePrice(matA)) * bot.weights.buyMaterialsUrgency * 2.0

proc scoreCraft(state: GameState, bot: UtilityBot): float =
  let p = state.player
  if bot.weights.craftInterest <= 0.0: return 0.0
  if p.role != "Crafter": return 0.0
  if not hasEnoughMaterialsForCraft(p.inv): return 0.0
  let station = bestCraftStation(state, p)
  if station.isNone: return 0.0
  let tier = station.get().craftTier
  let gearValue = float(botItemBasePrice(gearItemForSlot(station.get().craftSlot, tier)))
  gearValue * bot.weights.craftInterest

proc desiredRole(bot: UtilityBot): string =
  if bot.weights.craftInterest > 0.0: "Crafter" else: "Gatherer"

proc bestAction(state: GameState, bot: UtilityBot): tuple[action: Action, score: float] =
  let p = state.player
  let wantedRole = bot.desiredRole()

  if p.role != wantedRole:
    let stallObj = if wantedRole == "Crafter": "CrafterStallObj" else: "GathererStallObj"
    return (Action(kind: akSetRole, roleStall: stallObj), 1000.0)

  var bestScore = 0.01
  var bestAction = Action(kind: akIdle)

  let node = nearestGatherableNode(state, p)
  if node.isSome:
    let gs = scoreGather(state, bot, node.get())
    if gs > bestScore:
      bestScore = gs
      bestAction = Action(kind: akGather, gatherMaterial: node.get().material,
                          targetNode: node)

  let ss = scoreSell(state, bot)
  if ss > bestScore:
    bestScore = ss
    bestAction = Action(kind: akSell)

  let bgs = scoreBuyGear(state, bot)
  if bgs > bestScore:
    bestScore = bgs
    let target = nextGearTarget(state, p)
    if target.slot >= 0:
      bestAction = Action(kind: akBuyGear, targetGear: target.item,
                          targetGearCursor: itemCursorIndex(target.item))

  let bms = scoreBuyMaterials(state, bot)
  if bms > bestScore:
    bestScore = bms
    let craftTier = demandAwareCraftTier(state, p)
    let (matA, matB) = materialsForTier(craftTier)
    let availA = hasListings(state, matA)
    let availB = hasListings(state, matB)
    let mat = if availA and availB:
        (if cheapestPrice(state, matA) <= cheapestPrice(state, matB): matA else: matB)
      elif availA: matA
      elif availB: matB
      else: matA
    let needed = 3 - p.inv.itemCount(mat)
    bestAction = Action(kind: akBuyMaterials, buyMaterial: mat,
                        buyMaterialCursor: itemCursorIndex(mat),
                        buyQuantity: max(1, needed))

  let cs = scoreCraft(state, bot)
  if cs > bestScore:
    bestScore = cs
    bestAction = Action(kind: akCraft)

  (bestAction, bestScore)

proc isComplete(c: Commitment, state: GameState, bot: UtilityBot): bool =
  let p = state.player
  case c.action.kind
  of akSetRole:
    return p.role == bot.desiredRole()
  of akGather:
    discard
  of akSell:
    if c.execPhase == epExit and p.state == "Idle":
      return true
    if p.state == "Idle" and c.execPhase >= epPerform:
      return true
  of akBuyGear:
    if c.execPhase == epExit and p.state == "Idle":
      return true
  of akBuyMaterials:
    if c.execPhase == epExit and p.state == "Idle":
      return true
    if c.execPhase == epPerform and hasEnoughMaterialsForCraft(p.inv):
      return true
  of akCraft:
    if c.execPhase == epPerform and p.state == "Idle":
      return true
  of akIdle:
    return c.ticksActive > 30
  false

proc isInvalid(c: Commitment, state: GameState, bot: UtilityBot): bool =
  if state.player.state in ["AtSellStall", "AtBuyStall"]:
    return false
  if c.execPhase == epNavigate and bot.nav.hasPath and c.ticksActive < 500:
    return false
  if c.execPhase in {epInteract, epPerform, epExit}:
    return c.ticksActive - c.phaseStartTick > 100
  c.ticksActive > 500

proc executeSetRole(bot: var UtilityBot, state: GameState, c: var Commitment): uint8 =
  let p = state.player
  if p.role == bot.desiredRole(): return 0
  let stallOpt = nearestObject(state, c.action.roleStall)
  if stallOpt.isNone: return 0
  let stall = stallOpt.get()
  case c.execPhase
  of epNavigate:
    if isAdjacentTo(p.x, p.y, stall.tx, stall.ty):
      c.execPhase = epInteract
      return facingMask(stall.tx, stall.ty, p.tx, p.ty)
    if not bot.nav.hasPath or c.ticksActive mod 30 == 1:
      bot.nav.navigateAdjacent(state, stall.tx, stall.ty)
    return bot.nav.followPath(p.x, p.y)
  of epInteract:
    if p.role == bot.desiredRole(): return 0
    if (bot.prevMask and ButtonA) != 0:
      return 0
    return facingMask(stall.tx, stall.ty, p.tx, p.ty) or ButtonA
  of epPerform, epExit:
    return 0

proc executeGather(bot: var UtilityBot, state: GameState, c: var Commitment): uint8 =
  let p = state.player
  if c.action.targetNode.isNone: return 0
  var node = c.action.targetNode.get()

  case c.execPhase
  of epNavigate:
    if p.state == "Gathering":
      c.execPhase = epPerform
      return ButtonA
    if node.depleted:
      let next = nearestGatherableNode(state, p,
                                       cachedListings = state.allListings())
      if next.isNone: return 0
      c.action = Action(kind: akGather, gatherMaterial: next.get().material,
                        targetNode: next)
      node = next.get()
      bot.nav = Navigator()
    if isAdjacentTo(p.x, p.y, node.tx, node.ty):
      c.execPhase = epInteract
      return facingMask(node.tx, node.ty, p.tx, p.ty)
    if not bot.nav.hasPath or c.ticksActive mod 30 == 1:
      bot.nav.navigateTo(state, node.tx, node.ty)
    return bot.nav.followPath(p.x, p.y)
  of epInteract:
    if p.state == "Gathering":
      c.execPhase = epPerform
      return ButtonA
    return facingMask(node.tx, node.ty, p.tx, p.ty) or ButtonA
  of epPerform:
    if p.state == "Idle":
      c.execPhase = epNavigate
      let next = nearestGatherableNode(state, p,
                                       cachedListings = state.allListings())
      if next.isSome:
        c.action = Action(kind: akGather, gatherMaterial: next.get().material,
                          targetNode: next)
        bot.nav = Navigator()
      return 0
    return ButtonA
  of epExit:
    return 0

proc executeSell(bot: var UtilityBot, state: GameState, c: var Commitment): uint8 =
  let p = state.player

  case c.execPhase
  of epNavigate:
    if p.state == "AtSellStall":
      c.execPhase = epPerform
      c.phaseStartTick = c.ticksActive
      return 0
    let stallOpt = nearestObject(state, "SellStallObj")
    if stallOpt.isNone: return 0
    let stall = stallOpt.get()
    if isAdjacentTo(p.x, p.y, stall.tx, stall.ty):
      c.execPhase = epInteract
      c.phaseStartTick = c.ticksActive
      return facingMask(stall.tx, stall.ty, p.tx, p.ty)
    if not bot.nav.hasPath or c.ticksActive mod 30 == 1:
      bot.nav.navigateAdjacent(state, stall.tx, stall.ty)
    return bot.nav.followPath(p.x, p.y)
  of epInteract:
    if p.state == "AtSellStall":
      c.execPhase = epPerform
      c.phaseStartTick = c.ticksActive
      return 0
    if c.ticksActive - c.phaseStartTick > 30:
      c.execPhase = epExit
      return 0
    let stallOpt = nearestObject(state, "SellStallObj")
    if stallOpt.isSome:
      let stall = stallOpt.get()
      let face = facingMask(stall.tx, stall.ty, p.tx, p.ty)
      if (bot.prevMask and ButtonA) != 0:
        return face
      if (bot.prevMask and face) == 0:
        return face
      return face or ButtonA
    if (bot.prevMask and ButtonA) != 0:
      return 0
    return ButtonA
  of epPerform:
    if p.state != "AtSellStall":
      c.execPhase = epExit
      return 0
    if not hasAnyRawMaterials(p.inv) and not p.inv.hasAnyGear:
      c.execPhase = epExit
      return 0
    if p.listings.len >= BotMaxSellSlots:
      c.execPhase = epExit
      return 0
    if c.itemsListedThisVisit >= 3:
      c.execPhase = epExit
      return 0
    let itemName = sellCursorItemName(p)
    if isGearItem(itemName):
      let basePrice = botItemBasePrice(itemName)
      let targetPrice = max(basePrice, dynamicPrice(bot.pricingState, p.listings.len, basePrice))
      if p.sellPrice < targetPrice:
        return ButtonUp
      elif p.sellPrice > targetPrice:
        return ButtonDown
      if (bot.prevMask and ButtonA) != 0:
        c.itemsListedThisVisit += 1
        return 0
      return ButtonA
    let maxTier = highestGatherableTier(p)
    if not isSellableAtTier(itemName, maxTier):
      let target = bestSellCursor(p)
      if target < 0 or target == p.sellItemCursor:
        c.execPhase = epExit
        return 0
      if p.sellItemCursor < target:
        return ButtonRight
      return ButtonLeft
    let cheapest = cheapestPrice(state, itemName)
    let basePrice = botItemBasePrice(itemName)
    let baseTarget = if cheapest < int.high: max(basePrice, cheapest - 1) else: basePrice
    let targetPrice = max(basePrice, dynamicPrice(bot.pricingState, p.listings.len, baseTarget))
    if p.sellPrice < targetPrice:
      return ButtonUp
    elif p.sellPrice > targetPrice:
      return ButtonDown
    if (bot.prevMask and ButtonA) != 0:
      c.itemsListedThisVisit += 1
      return 0
    return ButtonA
  of epExit:
    if p.state == "Idle":
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

proc buyGearFail(bot: var UtilityBot) =
  bot.buyGearFailCount += 1
  bot.buyGearCooldownUntil = bot.ticksTotal + min(3000, 500 * bot.buyGearFailCount)

proc executeBuyGear(bot: var UtilityBot, state: GameState, c: var Commitment): uint8 =
  let p = state.player

  case c.execPhase
  of epNavigate:
    if p.state == "AtBuyStall":
      let target = nextGearTarget(state, p)
      if target.slot < 0 or
         (let listing = cheapestListing(state.allListings(), target.item);
          listing.isNone or listing.get().priceEach > p.gold):
        bot.buyGearFail()
        c.execPhase = epExit
        return ButtonB
      bot.buyGearFailCount = 0
      c.action = Action(kind: akBuyGear, targetGear: target.item,
                        targetGearCursor: itemCursorIndex(target.item))
      c.execPhase = epPerform
      c.phaseStartTick = c.ticksActive
      return 0
    let stallOpt = nearestObject(state, "BuyStallObj")
    if stallOpt.isNone: return 0
    let stall = stallOpt.get()
    if isAdjacentTo(p.x, p.y, stall.tx, stall.ty):
      c.execPhase = epInteract
      c.phaseStartTick = c.ticksActive
      return facingMask(stall.tx, stall.ty, p.tx, p.ty)
    if not bot.nav.hasPath or c.ticksActive mod 30 == 1:
      bot.nav.navigateAdjacent(state, stall.tx, stall.ty)
    return bot.nav.followPath(p.x, p.y)
  of epInteract:
    if p.state == "AtBuyStall":
      let target = nextGearTarget(state, p)
      if target.slot < 0 or
         (let listing = cheapestListing(state.allListings(), target.item);
          listing.isNone or listing.get().priceEach > p.gold):
        bot.buyGearFail()
        c.execPhase = epExit
        return ButtonB
      bot.buyGearFailCount = 0
      c.action = Action(kind: akBuyGear, targetGear: target.item,
                        targetGearCursor: itemCursorIndex(target.item))
      c.execPhase = epPerform
      c.phaseStartTick = c.ticksActive
      return 0
    if c.ticksActive - c.phaseStartTick > 30:
      bot.buyGearFail()
      c.execPhase = epExit
      return 0
    let stallOpt2 = nearestObject(state, "BuyStallObj")
    if stallOpt2.isSome:
      let stall2 = stallOpt2.get()
      if (bot.prevMask and ButtonA) != 0:
        return facingMask(stall2.tx, stall2.ty, p.tx, p.ty)
      return facingMask(stall2.tx, stall2.ty, p.tx, p.ty) or ButtonA
    if (bot.prevMask and ButtonA) != 0:
      return 0
    return ButtonA
  of epPerform:
    if p.state != "AtBuyStall":
      c.execPhase = epExit
      return 0
    if p.buyItemCursor < c.action.targetGearCursor:
      return ButtonRight
    if p.buyItemCursor > c.action.targetGearCursor:
      return ButtonLeft
    if p.buyQuantity < 1:
      return ButtonUp
    if (bot.prevMask and ButtonA) != 0:
      bot.buyGearFailCount = 0
      c.execPhase = epExit
      return 0
    return ButtonA
  of epExit:
    if p.state == "Idle":
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

proc executeBuyMaterials(bot: var UtilityBot, state: GameState, c: var Commitment): uint8 =
  let p = state.player

  case c.execPhase
  of epNavigate:
    if p.state == "AtBuyStall":
      c.execPhase = epPerform
      c.phaseStartTick = c.ticksActive
      return 0
    let stallOpt = nearestObject(state, "BuyStallObj")
    if stallOpt.isNone: return 0
    let stall = stallOpt.get()
    if isAdjacentTo(p.x, p.y, stall.tx, stall.ty):
      c.execPhase = epInteract
      c.phaseStartTick = c.ticksActive
      return facingMask(stall.tx, stall.ty, p.tx, p.ty)
    if not bot.nav.hasPath or c.ticksActive mod 30 == 1:
      bot.nav.navigateAdjacent(state, stall.tx, stall.ty)
    return bot.nav.followPath(p.x, p.y)
  of epInteract:
    if p.state == "AtBuyStall":
      c.execPhase = epPerform
      c.phaseStartTick = c.ticksActive
      return 0
    if c.ticksActive - c.phaseStartTick > 30:
      bot.buyMatFailCount += 1
      bot.buyMatCooldownUntil = bot.ticksTotal + min(3000, 300 * bot.buyMatFailCount)
      c.execPhase = epExit
      return 0
    let stall2 = nearestObject(state, "BuyStallObj")
    if stall2.isSome:
      if (bot.prevMask and ButtonA) != 0:
        return facingMask(stall2.get().tx, stall2.get().ty, p.tx, p.ty)
      return facingMask(stall2.get().tx, stall2.get().ty, p.tx, p.ty) or ButtonA
    if (bot.prevMask and ButtonA) != 0:
      return 0
    return ButtonA
  of epPerform:
    if p.state != "AtBuyStall":
      c.execPhase = epExit
      return 0
    if hasEnoughMaterialsForCraft(p.inv):
      c.execPhase = epExit
      return 0
    let mat = c.action.buyMaterial
    let listing = cheapestListing(state.allListings(), mat)
    if listing.isNone or listing.get().priceEach > p.gold:
      bot.buyMatFailCount += 1
      bot.buyMatCooldownUntil = bot.ticksTotal + min(3000, 300 * bot.buyMatFailCount)
      c.execPhase = epExit
      return 0
    let needed = max(1, 3 - p.inv.itemCount(mat))
    if p.buyItemCursor < c.action.buyMaterialCursor:
      return ButtonRight
    if p.buyItemCursor > c.action.buyMaterialCursor:
      return ButtonLeft
    if p.buyQuantity < needed:
      return ButtonUp
    if p.buyQuantity > needed:
      return ButtonDown
    if (bot.prevMask and ButtonA) != 0:
      bot.buyMatFailCount = 0
      c.execPhase = epExit
      return 0
    return ButtonA
  of epExit:
    if p.state == "Idle":
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

proc executeCraft(bot: var UtilityBot, state: GameState, c: var Commitment): uint8 =
  let p = state.player

  case c.execPhase
  of epNavigate:
    if p.state == "Crafting":
      c.execPhase = epPerform
      return ButtonA
    let stationOpt = bestCraftStation(state, p)
    if stationOpt.isNone: return 0
    let station = stationOpt.get()
    if isAdjacentTo(p.x, p.y, station.tx, station.ty):
      c.execPhase = epInteract
      return facingMask(station.tx, station.ty, p.tx, p.ty)
    if not bot.nav.hasPath or c.ticksActive mod 30 == 1:
      bot.nav.navigateAdjacent(state, station.tx, station.ty)
      if not bot.nav.hasPath:
        bot.nav.navigateTo(state, station.tx, station.ty)
    return bot.nav.followPath(p.x, p.y)
  of epInteract:
    if p.state == "Crafting":
      c.execPhase = epPerform
      return ButtonA
    if (bot.prevMask and ButtonA) != 0:
      return 0
    let stationOpt = bestCraftStation(state, p)
    if stationOpt.isSome:
      let station = stationOpt.get()
      return facingMask(station.tx, station.ty, p.tx, p.ty) or ButtonA
    return ButtonA
  of epPerform:
    if p.state == "Idle":
      return 0
    return ButtonA
  of epExit:
    return 0

proc execute(bot: var UtilityBot, state: GameState): uint8 =
  if bot.commitment.isNone: return 0
  var c = bot.commitment.get()
  c.ticksActive += 1
  let p = state.player
  # If stuck at a stall but our action doesn't need the stall, press B to exit
  if p.state in ["AtSellStall", "AtBuyStall"]:
    let needsStall = c.action.kind in {akSell, akBuyGear, akBuyMaterials}
    if not needsStall:
      if (bot.prevMask and ButtonB) == 0:
        bot.commitment = some(c)
        return buildMask(b = true)
      else:
        bot.commitment = some(c)
        return 0
  let mask = case c.action.kind
    of akSetRole: executeSetRole(bot, state, c)
    of akGather: executeGather(bot, state, c)
    of akSell: executeSell(bot, state, c)
    of akBuyGear: executeBuyGear(bot, state, c)
    of akBuyMaterials: executeBuyMaterials(bot, state, c)
    of akCraft: executeCraft(bot, state, c)
    of akIdle: 0'u8
  bot.commitment = some(c)
  mask

proc decide*(bot: var UtilityBot, state: GameState): uint8 =
  bot.ticksTotal += 1

  discard

  let (newAction, newScore) = bestAction(state, bot)

  if bot.commitment.isSome:
    var c = bot.commitment.get()
    if isComplete(c, state, bot):
      bot.commitment = none(Commitment)
    elif isInvalid(c, state, bot):
      if c.action.kind == akBuyMaterials:
        bot.buyMatFailCount += 1
        bot.buyMatCooldownUntil = bot.ticksTotal + min(3000, 500 * bot.buyMatFailCount)
      elif c.action.kind == akBuyGear:
        bot.buyGearFail()
      bot.commitment = none(Commitment)
    else:
      let currentScore = case c.action.kind
        of akGather:
          if c.action.targetNode.isSome:
            scoreGather(state, bot, c.action.targetNode.get())
          else: 0.0
        of akSetRole: 1000.0
        of akSell: scoreSell(state, bot)
        of akBuyGear: scoreBuyGear(state, bot)
        of akBuyMaterials: scoreBuyMaterials(state, bot)
        of akCraft: scoreCraft(state, bot)
        of akIdle: 0.01
      if c.ticksActive >= 10 and newScore > currentScore * bot.weights.interruptThreshold:
        bot.commitment = none(Commitment)

  if bot.commitment.isNone:
    bot.commitment = some(Commitment(action: newAction, ticksActive: 0, execPhase: epNavigate))
    bot.nav = Navigator()

  let mask = execute(bot, state)
  bot.prevMask = mask

  if bot.commitment.isSome:
    let c = bot.commitment.get()
    let subPhase = case c.execPhase
      of epNavigate: ".Navigate"
      of epInteract: ".Interact"
      of epPerform: ".Perform"
      of epExit: ".Exit"
    bot.phase = case c.action.kind
      of akSetRole: "SetRole" & subPhase
      of akGather: "Gather(" & c.action.gatherMaterial & ")" & subPhase
      of akSell: "Sell" & subPhase
      of akBuyGear: "BuyGear(" & c.action.targetGear & ")" & subPhase
      of akBuyMaterials: "BuyMat(" & c.action.buyMaterial & ")" & subPhase
      of akCraft: "Craft" & subPhase
      of akIdle: "Idle"
  else:
    bot.phase = "Deciding"

  mask

import std/options
import protocol
import common

type
  ActionKind* = enum
    akSetRole
    akGather
    akSell
    akBuyGear
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

  PersonalityWeights* = object
    gatherWoodBias*: float
    gatherStoneBias*: float
    sellUrgency*: float
    gearPriority*: float
    batchPatience*: float
    interruptThreshold*: float

  UtilityBot* = object
    weights*: PersonalityWeights
    commitment*: Option[Commitment]
    lastSeenListings*: seq[BotListing]
    lastSeenTick*: int
    buyGearCooldownUntil*: int
    nav*: Navigator
    pricingState*: PricingState
    prevMask*: uint8
    ticksTotal*: int
    phase*: string


proc sellableItemCount(player: BotPlayer): int =
  for name in RawMaterialNames:
    result += player.inv.itemCount(name)

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
  (basePrice * materialBias * bot.weights.batchPatience) / float(dist)

proc scoreSell(state: GameState, bot: UtilityBot): float =
  let p = state.player
  let itemCount = sellableItemCount(p)
  if itemCount == 0: return 0.0
  if not p.canSellMore: return 0.0
  let dist = max(1, distToNearest(state, "SellStallObj"))
  var totalValue = 0
  for name in RawMaterialNames:
    let count = p.inv.itemCount(name)
    if count > 0:
      totalValue += count * botItemBasePrice(name)
  (float(totalValue) * bot.weights.sellUrgency) / float(dist)

proc scoreBuyGear(state: GameState, bot: UtilityBot): float =
  let p = state.player
  if bot.lastSeenListings.len == 0: return 0.0
  if bot.ticksTotal < bot.buyGearCooldownUntil: return 0.0
  let staleness = bot.ticksTotal - bot.lastSeenTick
  if staleness > 1000: return 0.0
  let target = nextGearTargetCached(state, p, bot.lastSeenListings)
  if target.slot < 0: return 0.0
  let listings = visibleListings(state, bot.lastSeenListings)
  let listing = cheapestListing(listings, target.item)
  if listing.isNone or listing.get().priceEach > p.gold: return 0.0
  let dist = max(1, distToNearest(state, "BuyStallObj"))
  let gearValue = float(botItemBasePrice(target.item))
  let freshness = max(0.3, 1.0 - (float(staleness) / 1000.0))
  (gearValue * bot.weights.gearPriority * freshness) / float(dist)

proc bestAction(state: GameState, bot: UtilityBot): tuple[action: Action, score: float] =
  let p = state.player

  if p.role != "Gatherer":
    return (Action(kind: akSetRole, roleStall: "GathererStallObj"), 1000.0)

  var bestScore = 0.01
  var bestAction = Action(kind: akIdle)

  let node = nearestGatherableNode(state, p,
                                   cachedListings = bot.lastSeenListings)
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
    let target = nextGearTargetCached(state, p, bot.lastSeenListings)
    bestAction = Action(kind: akBuyGear, targetGear: target.item,
                        targetGearCursor: itemCursorIndex(target.item))

  (bestAction, bestScore)

proc isComplete(c: Commitment, state: GameState, bot: UtilityBot): bool =
  let p = state.player
  case c.action.kind
  of akSetRole:
    return p.role == "Gatherer"
  of akGather:
    discard
  of akSell:
    if c.execPhase == epExit and p.state == "Idle":
      return true
    if c.execPhase == epPerform and not hasAnyRawMaterials(p.inv):
      return true
    if c.execPhase == epPerform and not p.canSellMore:
      return true
  of akBuyGear:
    if c.execPhase == epExit and p.state == "Idle":
      return true
  of akIdle:
    return c.ticksActive > 30
  false

proc isInvalid(c: Commitment, state: GameState): bool =
  c.ticksActive > 600

proc executeSetRole(bot: var UtilityBot, state: GameState, c: var Commitment): uint8 =
  let p = state.player
  if p.role == "Gatherer": return 0
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
    if p.role == "Gatherer": return 0
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
                                       cachedListings = bot.lastSeenListings)
      if next.isNone: return 0
      c.action = Action(kind: akGather, gatherMaterial: next.get().material,
                        targetNode: next)
      node = next.get()
      bot.nav = Navigator()
    if isAdjacentTo(p.x, p.y, node.tx, node.ty):
      c.execPhase = epInteract
      return facingMask(node.tx, node.ty, p.tx, p.ty)
    if not bot.nav.hasPath or c.ticksActive mod 30 == 1:
      bot.nav.navigateAdjacent(state, node.tx, node.ty)
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
                                       cachedListings = bot.lastSeenListings)
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
      return 0
    let stallOpt = nearestObject(state, "SellStallObj")
    if stallOpt.isNone: return 0
    let stall = stallOpt.get()
    if isAdjacentTo(p.x, p.y, stall.tx, stall.ty):
      c.execPhase = epInteract
      return facingMask(stall.tx, stall.ty, p.tx, p.ty)
    if not bot.nav.hasPath or c.ticksActive mod 30 == 1:
      bot.nav.navigateAdjacent(state, stall.tx, stall.ty)
    return bot.nav.followPath(p.x, p.y)
  of epInteract:
    if p.state == "AtSellStall":
      c.execPhase = epPerform
      return 0
    if c.ticksActive > 20 and (bot.prevMask and ButtonA) != 0:
      return 0
    let stallOpt = nearestObject(state, "SellStallObj")
    if stallOpt.isSome:
      let stall = stallOpt.get()
      return facingMask(stall.tx, stall.ty, p.tx, p.ty) or ButtonA
    return ButtonA
  of epPerform:
    if p.state != "AtSellStall":
      c.execPhase = epExit
      return 0
    if not hasAnyRawMaterials(p.inv):
      c.execPhase = epExit
      return 0
    if p.listings.len >= BotMaxSellSlots:
      c.execPhase = epExit
      return 0
    let itemName = sellCursorItemName(p)
    let maxTier = highestGatherableTier(p)
    if not isSellableAtTier(itemName, maxTier):
      let target = nextSellCursorForTier(p)
      if target < 0 or target == p.sellItemCursor:
        c.execPhase = epExit
        return 0
      if p.sellItemCursor < target:
        return ButtonRight
      return ButtonLeft
    let cheapest = cheapestPrice(state, itemName)
    let floor = max(1, botItemBasePrice(itemName) div 2)
    let baseTarget = if cheapest < int.high: max(floor, cheapest - 1) else: botItemBasePrice(itemName)
    let targetPrice = dynamicPrice(bot.pricingState, p.listings.len, baseTarget)
    if p.sellPrice < targetPrice:
      return ButtonUp
    elif p.sellPrice > targetPrice:
      return ButtonDown
    if (bot.prevMask and ButtonA) != 0:
      return 0
    return ButtonA
  of epExit:
    if p.state == "Idle":
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

proc executeBuyGear(bot: var UtilityBot, state: GameState, c: var Commitment): uint8 =
  let p = state.player

  case c.execPhase
  of epNavigate:
    if p.state == "AtBuyStall":
      let target = nextGearTarget(state, p)
      if target.slot < 0 or
         (let listing = cheapestListing(state.allListings(), target.item);
          listing.isNone or listing.get().priceEach > p.gold):
        bot.buyGearCooldownUntil = bot.ticksTotal + 500
        c.execPhase = epExit
        return ButtonB
      c.action = Action(kind: akBuyGear, targetGear: target.item,
                        targetGearCursor: itemCursorIndex(target.item))
      c.execPhase = epPerform
      return 0
    let stallOpt = nearestObject(state, "BuyStallObj")
    if stallOpt.isNone: return 0
    let stall = stallOpt.get()
    if isAdjacentTo(p.x, p.y, stall.tx, stall.ty):
      c.execPhase = epInteract
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
        bot.buyGearCooldownUntil = bot.ticksTotal + 500
        c.execPhase = epExit
        return ButtonB
      c.action = Action(kind: akBuyGear, targetGear: target.item,
                        targetGearCursor: itemCursorIndex(target.item))
      c.execPhase = epPerform
      return 0
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
      c.execPhase = epExit
      return 0
    return ButtonA
  of epExit:
    if p.state == "Idle":
      return 0
    if (bot.prevMask and ButtonB) != 0:
      return 0
    return ButtonB

proc execute(bot: var UtilityBot, state: GameState): uint8 =
  if bot.commitment.isNone: return 0
  var c = bot.commitment.get()
  c.ticksActive += 1
  let mask = case c.action.kind
    of akSetRole: executeSetRole(bot, state, c)
    of akGather: executeGather(bot, state, c)
    of akSell: executeSell(bot, state, c)
    of akBuyGear: executeBuyGear(bot, state, c)
    of akIdle: 0'u8
  bot.commitment = some(c)
  mask

proc decide*(bot: var UtilityBot, state: GameState): uint8 =
  bot.ticksTotal += 1

  if state.player.state in ["AtBuyStall", "AtSellStall"]:
    bot.lastSeenListings = state.allListings()
    bot.lastSeenTick = bot.ticksTotal

  let (newAction, newScore) = bestAction(state, bot)

  if bot.commitment.isSome:
    var c = bot.commitment.get()
    if isComplete(c, state, bot):
      bot.commitment = none(Commitment)
    elif isInvalid(c, state):
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
    bot.phase = case c.action.kind
      of akSetRole: "SetRole"
      of akGather: "Gather(" & c.action.gatherMaterial & ")"
      of akSell: "Sell"
      of akBuyGear: "BuyGear(" & c.action.targetGear & ")"
      of akIdle: "Idle"
  else:
    bot.phase = "Deciding"

  mask

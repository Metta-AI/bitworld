import std/[algorithm, json, math, sequtils, strformat, strutils]
import sim

const
  DroughtThresholdTicks* = 48
  PriceWindowSize = 10
  MarketCapMilestones = [200, 300, 500, 750, 1000, 1500, 2000, 3000]
  MassRoleSwitchWindow = 48
  CorneringThreshold = 0.5

type
  LegendEventKind* = enum
    LeadChange
    MarketCapMilestone
    PriceSpike
    PriceCrash
    SupplyDrought
    DroughtEnd
    FirstGearComplete
    MassRoleSwitch
    MarketCornering
    CrashRecovery
    WealthReversal

  LegendEvent* = object
    tick*: int
    kind*: LegendEventKind
    description*: string
    players*: seq[int]
    value*: int
    excitement*: float

  LegendTracker* = object
    events*: seq[LegendEvent]
    prevLeaderIdx: int
    prevMarketCap: int
    peakMarketCap: int
    inCrash: bool
    crashFloor: int
    priceHistory: array[ItemKind, seq[int]]
    droughtStart: array[ItemKind, int]
    prevRoles: seq[Role]
    prevGolds: seq[int]
    milestonesReached: set[uint16]
    gearCompleted: seq[bool]
    recentRoleSwitches: seq[tuple[tick: int, player: int, fromRole, toRole: Role]]
    corneringReported: seq[tuple[player: int, item: ItemKind]]

proc initLegendTracker*(): LegendTracker =
  result.prevLeaderIdx = -1
  for item in ItemKind:
    result.droughtStart[item] = -1

proc addEvent(tracker: var LegendTracker, tick: int, kind: LegendEventKind,
              desc: string, players: seq[int] = @[], value: int = 0,
              excitement: float = 1.0) =
  tracker.events.add LegendEvent(
    tick: tick, kind: kind, description: desc,
    players: players, value: value, excitement: excitement
  )

proc shortName(item: ItemKind): string =
  case item
  of WoodItem: "Wood"
  of HardwoodItem: "Hdwd"
  of IronwoodItem: "Irwd"
  of StoneItem: "Stone"
  of CopperItem: "Copper"
  of IronItem: "Iron"
  else: $item

proc nick(name: string): string =
  if name.len <= 8: name
  else: name[0..6]

proc cheapestListingPrice(sim: SimServer, item: ItemKind): int =
  result = int.high
  for listing in sim.npcListings:
    if listing.item == item and listing.quantity > 0 and listing.priceEach < result:
      result = listing.priceEach
  for player in sim.players:
    for listing in player.listings:
      if listing.item == item and listing.quantity > 0 and listing.priceEach < result:
        result = listing.priceEach

proc hasAnyListings(sim: SimServer, item: ItemKind): bool =
  for listing in sim.npcListings:
    if listing.item == item and listing.quantity > 0:
      return true
  for player in sim.players:
    for listing in player.listings:
      if listing.item == item and listing.quantity > 0:
        return true
  false

proc totalSupply(sim: SimServer, item: ItemKind): int =
  for listing in sim.npcListings:
    if listing.item == item:
      result += listing.quantity
  for player in sim.players:
    result += player.inv.counts[item]
    for listing in player.listings:
      if listing.item == item:
        result += listing.quantity

proc playerSupply(sim: SimServer, playerIdx: int, item: ItemKind): int =
  let player = sim.players[playerIdx]
  result = player.inv.counts[item]
  for listing in player.listings:
    if listing.item == item:
      result += listing.quantity

proc rollingAvg(prices: seq[int]): int =
  if prices.len == 0: return 0
  var sum = 0
  for p in prices: sum += p
  sum div prices.len

proc detectLeadChange(tracker: var LegendTracker, sim: SimServer) =
  if sim.players.len < 2: return
  var bestIdx = 0
  var bestScore = sim.rewardScore(0)
  for i in 1 ..< sim.players.len:
    let score = sim.rewardScore(i)
    if score > bestScore:
      bestScore = score
      bestIdx = i

  if tracker.prevLeaderIdx >= 0 and bestIdx != tracker.prevLeaderIdx:
    let prevScore = sim.rewardScore(tracker.prevLeaderIdx)
    let desc = &"{nick(sim.players[bestIdx].name)} leads!"
    tracker.addEvent(sim.tickCount, LeadChange, desc,
      @[bestIdx, tracker.prevLeaderIdx], bestScore,
      float(bestScore - prevScore) + 5.0)
  tracker.prevLeaderIdx = bestIdx

proc detectMarketCapMilestones(tracker: var LegendTracker, sim: SimServer) =
  let cap = sim.totalMarketCap()
  for i, threshold in MarketCapMilestones:
    if cap >= threshold and uint16(i) notin tracker.milestonesReached:
      tracker.milestonesReached.incl uint16(i)
      let desc = &"Cap hits {threshold}g!"
      tracker.addEvent(sim.tickCount, MarketCapMilestone, desc,
        value = threshold, excitement = float(threshold) / 100.0)

proc detectPriceEvents(tracker: var LegendTracker, sim: SimServer) =
  for item in RawMaterials:
    let price = cheapestListingPrice(sim, item)
    if price == int.high: continue

    let avg = rollingAvg(tracker.priceHistory[item])
    if avg > 0:
      if price >= avg * 2:
        let desc = &"{shortName(item)} spike! {price}g"
        tracker.addEvent(sim.tickCount, PriceSpike, desc,
          value = price, excitement = float(price - avg))
      elif price * 2 <= avg:
        let desc = &"{shortName(item)} crash! {price}g"
        tracker.addEvent(sim.tickCount, PriceCrash, desc,
          value = price, excitement = float(avg - price))

    tracker.priceHistory[item].add price
    if tracker.priceHistory[item].len > PriceWindowSize:
      tracker.priceHistory[item].delete(0)

proc detectSupplyDroughts(tracker: var LegendTracker, sim: SimServer) =
  for item in RawMaterials:
    let available = sim.hasAnyListings(item)
    if not available:
      if tracker.droughtStart[item] < 0:
        tracker.droughtStart[item] = sim.tickCount
      elif sim.tickCount - tracker.droughtStart[item] == DroughtThresholdTicks:
        let desc = &"{shortName(item)} drought!"
        tracker.addEvent(sim.tickCount, SupplyDrought, desc,
          value = sim.tickCount - tracker.droughtStart[item],
          excitement = 3.0)
    else:
      if tracker.droughtStart[item] >= 0 and
          sim.tickCount - tracker.droughtStart[item] >= DroughtThresholdTicks:
        let duration = sim.tickCount - tracker.droughtStart[item]
        let desc = &"{shortName(item)} back!"
        tracker.addEvent(sim.tickCount, DroughtEnd, desc,
          value = duration, excitement = float(duration) / 24.0)
      tracker.droughtStart[item] = -1

proc detectFirstGearComplete(tracker: var LegendTracker, sim: SimServer) =
  while tracker.gearCompleted.len < sim.players.len:
    tracker.gearCompleted.add false
  for i in 0 ..< sim.players.len:
    if not tracker.gearCompleted[i]:
      if sim.players[i].equippedGearCount() >= GearSlotCount:
        tracker.gearCompleted[i] = true
        let desc = &"{nick(sim.players[i].name)} full gear!"
        tracker.addEvent(sim.tickCount, FirstGearComplete, desc,
          @[i], excitement = 8.0)

proc detectRoleSwitches(tracker: var LegendTracker, sim: SimServer) =
  if tracker.prevRoles.len != sim.players.len:
    tracker.prevRoles = newSeq[Role](sim.players.len)
    for i in 0 ..< sim.players.len:
      tracker.prevRoles[i] = sim.players[i].role
    return

  for i in 0 ..< sim.players.len:
    let cur = sim.players[i].role
    let prev = tracker.prevRoles[i]
    if cur != prev and cur != NoRole and prev != NoRole:
      tracker.recentRoleSwitches.add (tick: sim.tickCount, player: i, fromRole: prev, toRole: cur)
    tracker.prevRoles[i] = cur

  tracker.recentRoleSwitches.keepItIf(sim.tickCount - it.tick <= MassRoleSwitchWindow)

  if tracker.recentRoleSwitches.len >= 2:
    let players = tracker.recentRoleSwitches.mapIt(it.player).deduplicate()
    if players.len >= 2:
      let names = players.mapIt(nick(sim.players[it].name)).join(",")
      let desc = &"Role rush! {names}"
      tracker.addEvent(sim.tickCount, MassRoleSwitch, desc,
        players, excitement = float(players.len) * 5.0)
      tracker.recentRoleSwitches.setLen(0)

proc detectMarketCornering(tracker: var LegendTracker, sim: SimServer) =
  for item in RawMaterials:
    let total = sim.totalSupply(item)
    if total < 3: continue
    for i in 0 ..< sim.players.len:
      let held = sim.playerSupply(i, item)
      if float(held) / float(total) > CorneringThreshold:
        var alreadyReported = false
        for r in tracker.corneringReported:
          if r.player == i and r.item == item:
            alreadyReported = true
            break
        if not alreadyReported:
          tracker.corneringReported.add (player: i, item: item)
          let pct = (held * 100) div total
          let desc = &"{nick(sim.players[i].name)} corners {shortName(item)}!"
          tracker.addEvent(sim.tickCount, MarketCornering, desc,
            @[i], held, excitement = 10.0)

proc detectCrashRecovery(tracker: var LegendTracker, sim: SimServer) =
  let cap = sim.totalMarketCap()
  if cap > tracker.peakMarketCap:
    tracker.peakMarketCap = cap

  if not tracker.inCrash and tracker.peakMarketCap > 0 and
      float(tracker.peakMarketCap - cap) / float(tracker.peakMarketCap) > 0.2:
    tracker.inCrash = true
    tracker.crashFloor = cap
    let desc = &"Market crash! -{((tracker.peakMarketCap - cap) * 100) div tracker.peakMarketCap}%"
    tracker.addEvent(sim.tickCount, CrashRecovery, desc,
      value = cap, excitement = 15.0)

  if tracker.inCrash:
    if cap < tracker.crashFloor:
      tracker.crashFloor = cap
    if tracker.crashFloor > 0 and
        float(cap - tracker.crashFloor) / float(tracker.crashFloor) > 0.15:
      let desc = &"Recovery! +{((cap - tracker.crashFloor) * 100) div tracker.crashFloor}%"
      tracker.addEvent(sim.tickCount, CrashRecovery, desc,
        value = cap, excitement = 20.0)
      tracker.inCrash = false
      tracker.peakMarketCap = cap

  tracker.prevMarketCap = cap

proc detectWealthReversal(tracker: var LegendTracker, sim: SimServer) =
  if sim.players.len < 2: return
  if tracker.prevGolds.len != sim.players.len:
    tracker.prevGolds = newSeq[int](sim.players.len)
    for i in 0 ..< sim.players.len:
      tracker.prevGolds[i] = sim.rewardScore(i)
    return

  var prevBest, prevWorst, curBest, curWorst: int
  var prevBestScore = int.low
  var prevWorstScore = int.high
  var curBestScore = int.low
  var curWorstScore = int.high

  for i in 0 ..< sim.players.len:
    if tracker.prevGolds[i] > prevBestScore:
      prevBestScore = tracker.prevGolds[i]
      prevBest = i
    if tracker.prevGolds[i] < prevWorstScore:
      prevWorstScore = tracker.prevGolds[i]
      prevWorst = i
    let cur = sim.rewardScore(i)
    if cur > curBestScore:
      curBestScore = cur
      curBest = i
    if cur < curWorstScore:
      curWorstScore = cur
      curWorst = i

  if prevWorst == curBest and prevBest != curBest and prevBestScore > prevWorstScore:
    let desc = &"{nick(sim.players[curBest].name)} last to 1st!"
    tracker.addEvent(sim.tickCount, WealthReversal, desc,
      @[curBest], curBestScore, excitement = 25.0)

  for i in 0 ..< sim.players.len:
    tracker.prevGolds[i] = sim.rewardScore(i)

proc analyze*(tracker: var LegendTracker, sim: SimServer) =
  tracker.detectLeadChange(sim)
  tracker.detectMarketCapMilestones(sim)
  tracker.detectPriceEvents(sim)
  tracker.detectSupplyDroughts(sim)
  tracker.detectFirstGearComplete(sim)
  tracker.detectRoleSwitches(sim)
  tracker.detectMarketCornering(sim)
  tracker.detectCrashRecovery(sim)
  tracker.detectWealthReversal(sim)

proc eventToJson(event: LegendEvent): JsonNode =
  result = newJObject()
  result["tick"] = %event.tick
  result["kind"] = %($event.kind)
  result["description"] = %event.description
  result["players"] = %event.players
  result["value"] = %event.value
  result["excitement"] = %event.excitement

proc toJson*(tracker: LegendTracker): JsonNode =
  result = newJObject()
  result["eventCount"] = %tracker.events.len
  var events = newJArray()
  for e in tracker.events:
    events.add eventToJson(e)
  result["events"] = events

  var sorted = tracker.events
  sorted.sort(proc(a, b: LegendEvent): int = cmp(b.excitement, a.excitement))
  var topEvents = newJArray()
  for i in 0 ..< min(10, sorted.len):
    topEvents.add eventToJson(sorted[i])
  result["topEvents"] = topEvents

proc topEvents*(tracker: LegendTracker, count: int): seq[LegendEvent] =
  var sorted = tracker.events
  sorted.sort(proc(a, b: LegendEvent): int = cmp(b.excitement, a.excitement))
  for i in 0 ..< min(count, sorted.len):
    result.add sorted[i]

proc summary*(tracker: LegendTracker, playerCount: int, totalTicks: int): string =
  result = &"A {totalTicks}-tick match with {playerCount} players. "
  var kindCounts: array[LegendEventKind, int]
  for e in tracker.events:
    inc kindCounts[e.kind]

  var parts: seq[string]
  if kindCounts[LeadChange] > 0:
    parts.add &"{kindCounts[LeadChange]} lead changes"
  if kindCounts[MarketCapMilestone] > 0:
    parts.add &"{kindCounts[MarketCapMilestone]} market cap milestones"
  if kindCounts[FirstGearComplete] > 0:
    parts.add &"{kindCounts[FirstGearComplete]} players completed gear"
  if kindCounts[SupplyDrought] > 0:
    parts.add &"{kindCounts[SupplyDrought]} supply droughts"
  if kindCounts[MarketCornering] > 0:
    parts.add &"{kindCounts[MarketCornering]} market cornering events"
  if kindCounts[CrashRecovery] > 0:
    parts.add &"{kindCounts[CrashRecovery]} crash/recovery events"
  if kindCounts[WealthReversal] > 0:
    parts.add &"{kindCounts[WealthReversal]} wealth reversals"

  if parts.len > 0:
    result.add parts.join(", ") & "."
  else:
    result.add "A quiet match with no major events."

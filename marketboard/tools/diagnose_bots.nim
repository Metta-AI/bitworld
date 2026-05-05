import std/[algorithm, json, os, parseopt, random, strformat, strutils, tables]
import
  ../sim,
  ../replays,
  ../players/common,
  ../players/still_forge as sf,
  ../players/iron_works as iw,
  ../players/colm as colm_bot,
  ../players/zorori as zr,
  ../players/solenne as sol,
  ../players/rkhenna as rk,
  ../players/pipitori as pip,
  ../players/kukumo as kuku,
  ../players/ktorra as kt,
  ../players/staelhart as stael

const
  BotCount = 10
  MinBots = 5
  MaxBots = 11

type
  BotKind = enum
    bkStillForge
    bkIronWorks
    bkColm
    bkZorori
    bkSolenne
    bkRkhenna
    bkPipitori
    bkKukumo
    bkKtorra
    bkStaelhart

  BotRunner = object
    kind: BotKind
    name: string
    prevMask: uint8
    case botKind: BotKind
    of bkStillForge: sfState: sf.BotState
    of bkIronWorks: iwState: iw.BotState
    of bkColm: colmState: colm_bot.BotState
    of bkZorori: zrState: zr.BotState
    of bkSolenne: solState: sol.BotState
    of bkRkhenna: rkState: rk.BotState
    of bkPipitori: pipState: pip.BotState
    of bkKukumo: kukuState: kuku.BotState
    of bkKtorra: ktState: kt.BotState
    of bkStaelhart: staelState: stael.BotState

  DiagConfig = object
    seed: int
    ticks: int
    interval: int
    fixedLineup: bool
    filter: string

proc botName(kind: BotKind, index: int): string =
  case kind
  of bkStillForge: "StillForge" & $index
  of bkIronWorks: "IronWorks" & $index
  of bkColm: "Colm" & $index
  of bkZorori: "Zorori" & $index
  of bkSolenne: "Solenne" & $index
  of bkRkhenna: "Rkhenna" & $index
  of bkPipitori: "Pipitori" & $index
  of bkKukumo: "Kukumo" & $index
  of bkKtorra: "Ktorra" & $index
  of bkStaelhart: "Staelhart" & $index

proc initBotRunner(kind: BotKind, index: int): BotRunner =
  let name = botName(kind, index)
  case kind
  of bkStillForge:
    result = BotRunner(kind: bkStillForge, botKind: bkStillForge, name: name)
  of bkIronWorks:
    result = BotRunner(kind: bkIronWorks, botKind: bkIronWorks, name: name)
  of bkColm:
    result = BotRunner(kind: bkColm, botKind: bkColm, name: name)
  of bkZorori:
    result = BotRunner(kind: bkZorori, botKind: bkZorori, name: name)
  of bkSolenne:
    result = BotRunner(kind: bkSolenne, botKind: bkSolenne, name: name)
  of bkRkhenna:
    result = BotRunner(kind: bkRkhenna, botKind: bkRkhenna, name: name)
  of bkPipitori:
    result = BotRunner(kind: bkPipitori, botKind: bkPipitori, name: name)
  of bkKukumo:
    result = BotRunner(kind: bkKukumo, botKind: bkKukumo, name: name)
  of bkKtorra:
    result = BotRunner(kind: bkKtorra, botKind: bkKtorra, name: name)
  of bkStaelhart:
    result = BotRunner(kind: bkStaelhart, botKind: bkStaelhart, name: name)

proc decide(bot: var BotRunner, state: GameState): uint8 =
  case bot.botKind
  of bkStillForge: sf.decide(bot.sfState, state)
  of bkIronWorks: iw.decide(bot.iwState, state)
  of bkColm: colm_bot.decide(bot.colmState, state)
  of bkZorori: zr.decide(bot.zrState, state)
  of bkSolenne: sol.decide(bot.solState, state)
  of bkRkhenna: rk.decide(bot.rkState, state)
  of bkPipitori: pip.decide(bot.pipState, state)
  of bkKukumo: kuku.decide(bot.kukuState, state)
  of bkKtorra: kt.decide(bot.ktState, state)
  of bkStaelhart: stael.decide(bot.staelState, state)

proc phaseName(bot: BotRunner): string =
  case bot.botKind
  of bkStillForge: $bot.sfState.phase
  of bkIronWorks: $bot.iwState.phase
  of bkColm: $bot.colmState.phase
  of bkZorori: $bot.zrState.phase
  of bkSolenne: $bot.solState.phase
  of bkRkhenna: $bot.rkState.phase
  of bkPipitori: $bot.pipState.phase
  of bkKukumo: bot.kukuState.phase
  of bkKtorra: bot.ktState.phase
  of bkStaelhart: bot.staelState.phase

proc ticksInPhase(bot: BotRunner): int =
  case bot.botKind
  of bkStillForge: bot.sfState.ticksInPhase
  of bkIronWorks: bot.iwState.ticksInPhase
  of bkColm: bot.colmState.ticksInPhase
  of bkZorori: bot.zrState.ticksInPhase
  of bkSolenne: bot.solState.ticksInPhase
  of bkRkhenna: bot.rkState.ticksInPhase
  of bkPipitori: bot.pipState.ticksInPhase
  of bkKukumo: bot.kukuState.ticksInPhase
  of bkKtorra: bot.ktState.ticksInPhase
  of bkStaelhart: bot.staelState.ticksInPhase

proc generateLineup(rng: var Rand, fixed: bool): seq[BotKind] =
  if fixed:
    for kind in BotKind:
      result.add kind
    return
  let count = rng.rand(MinBots .. MaxBots)
  for _ in 0 ..< count:
    result.add BotKind(rng.rand(BotCount - 1))
  var hasCrafter = false
  for kind in result:
    if kind in {bkIronWorks, bkSolenne, bkRkhenna, bkStaelhart}:
      hasCrafter = true
      break
  if not hasCrafter:
    let crafters = [bkIronWorks, bkSolenne, bkRkhenna, bkStaelhart]
    result[0] = crafters[rng.rand(3)]
  rng.shuffle(result)

proc playerGearTiers(p: Player): seq[int] =
  for s in 0 ..< 5:
    let g = p.gathererGear[s]
    let c = p.crafterGear[s]
    let gt: int = (case g
      of LeatherHat .. LeatherShoes: 1
      of ChainHat .. ChainShoes: 2
      of PlateHat .. PlateShoes: 3
      else: 0)
    let ct: int = (case c
      of LeatherHat .. LeatherShoes: 1
      of ChainHat .. ChainShoes: 2
      of PlateHat .. PlateShoes: 3
      else: 0)
    result.add max(gt, ct)

proc gearStr(tiers: seq[int]): string =
  "[" & tiers.join(",") & "]"

proc invSummary(p: Player): string =
  var parts: seq[string]
  if p.inv.counts[WoodItem] > 0: parts.add &"W:{p.inv.counts[WoodItem]}"
  if p.inv.counts[StoneItem] > 0: parts.add &"S:{p.inv.counts[StoneItem]}"
  if p.inv.counts[HardwoodItem] > 0: parts.add &"Hw:{p.inv.counts[HardwoodItem]}"
  if p.inv.counts[CopperItem] > 0: parts.add &"Cu:{p.inv.counts[CopperItem]}"
  if p.inv.counts[IronwoodItem] > 0: parts.add &"Iw:{p.inv.counts[IronwoodItem]}"
  if p.inv.counts[IronItem] > 0: parts.add &"Fe:{p.inv.counts[IronItem]}"
  var gearCount = 0
  for i in 6 ..< 21:
    gearCount += p.inv.counts[ItemKind(i)]
  if gearCount > 0: parts.add &"gear:{gearCount}"
  if parts.len == 0: "empty"
  else: parts.join(" ")

proc marketSummary(sim: SimServer): string =
  var matCounts: array[6, int]
  var gearCounts: array[3, int]
  for p in sim.players:
    for l in p.listings:
      case l.item
      of WoodItem: matCounts[0] += l.quantity
      of StoneItem: matCounts[1] += l.quantity
      of HardwoodItem: matCounts[2] += l.quantity
      of CopperItem: matCounts[3] += l.quantity
      of IronwoodItem: matCounts[4] += l.quantity
      of IronItem: matCounts[5] += l.quantity
      else:
        let t = gearTier(l.item)
        if t > 0: gearCounts[t-1] += l.quantity
  &"mats[W:{matCounts[0]} S:{matCounts[1]} Hw:{matCounts[2]} Cu:{matCounts[3]} Iw:{matCounts[4]} Fe:{matCounts[5]}] gear[T1:{gearCounts[0]} T2:{gearCounts[1]} T3:{gearCounts[2]}]"

proc parseArgs(): DiagConfig =
  result.seed = 0
  result.ticks = 100000
  result.interval = 1000
  result.fixedLineup = false
  result.filter = ""
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "seed": result.seed = parseInt(p.val)
      of "ticks": result.ticks = parseInt(p.val)
      of "interval": result.interval = parseInt(p.val)
      of "fixed-lineup": result.fixedLineup = true
      of "filter": result.filter = p.val
      else: discard
    of cmdArgument: discard

proc run(config: DiagConfig) =
  let previousDir = getCurrentDir()
  setCurrentDir(getCurrentDir() / "marketboard")

  createDir(previousDir / "tmp")
  var traceFile = open(previousDir / "tmp/diag_trace.txt", fmWrite)
  var reportFile = open(previousDir / "tmp/diag_report.txt", fmWrite)

  var rng = initRand(config.seed)
  let lineup = generateLineup(rng, config.fixedLineup)

  var sim = initSimServer(0)
  var bots: seq[BotRunner]

  var nameCounters: array[BotKind, int]
  for kind in lineup:
    inc nameCounters[kind]
    let bot = initBotRunner(kind, nameCounters[kind])
    discard sim.addPlayer(bot.name)
    bots.add bot

  traceFile.writeLine &"=== Diagnose Bots: seed={config.seed} ticks={config.ticks} interval={config.interval} ==="
  traceFile.writeLine &"Lineup: {lineup}"
  traceFile.writeLine ""

  # Track state for change detection
  type PlayerSnapshot = object
    gear: seq[int]
    gold: int
    role: string
    listingCount: int

  var lastPhase: seq[string]
  var lastSnap: seq[PlayerSnapshot]
  var phaseHist: seq[CountTable[string]]
  var phaseTicks: seq[CountTable[string]]
  var goldEarned: seq[int]
  var goldSpent: seq[int]
  var prevGold: seq[int]

  for i in 0 ..< bots.len:
    lastPhase.add ""
    lastSnap.add PlayerSnapshot(gear: @[0,0,0,0,0], gold: 0, role: "", listingCount: 0)
    phaseHist.add initCountTable[string]()
    phaseTicks.add initCountTable[string]()
    goldEarned.add 0
    goldSpent.add 0
    prevGold.add 500

  for tick in 0 ..< config.ticks:
    var inputs = newSeq[PlayerInput](sim.players.len)
    for i in 0 ..< bots.len:
      if i >= sim.players.len: break
      let stateJson = sim.buildStateJson(i)
      let state = parseGameState(stateJson)
      let mask = bots[i].decide(state)
      inputs[i] = maskToPlayerInput(mask, bots[i].prevMask)
      bots[i].prevMask = mask
      case bots[i].botKind
      of bkStillForge: bots[i].sfState.prevMask = mask
      of bkIronWorks: bots[i].iwState.prevMask = mask
      of bkColm: bots[i].colmState.prevMask = mask
      of bkZorori: bots[i].zrState.prevMask = mask
      of bkSolenne: bots[i].solState.prevMask = mask
      of bkRkhenna: bots[i].rkState.prevMask = mask
      of bkPipitori: bots[i].pipState.prevMask = mask
      of bkKukumo: bots[i].kukuState.util.prevMask = mask
      of bkKtorra: bots[i].ktState.util.prevMask = mask
      of bkStaelhart: bots[i].staelState.util.prevMask = mask

      # Log phase transitions and accumulate ticks
      let phase = bots[i].phaseName()
      if lastPhase[i].len > 0:
        phaseTicks[i].inc(lastPhase[i])
      if phase != lastPhase[i]:
        phaseHist[i].inc(phase)
        let matchFilter = config.filter.len == 0 or bots[i].name.toLowerAscii.contains(config.filter.toLowerAscii)
        if matchFilter and lastPhase[i].len > 0:
          let p = sim.players[i]
          let gears = playerGearTiers(p)
          traceFile.writeLine &"  [{tick:6d}] {bots[i].name:12s} {lastPhase[i]} -> {phase}  gold={p.gold} gear={gears.gearStr()} inv=({invSummary(p)})"
        lastPhase[i] = phase

    sim.step(inputs)

    for i in 0 ..< bots.len:
      if i >= sim.players.len: break
      let g = sim.players[i].gold
      let delta = g - prevGold[i]
      if delta > 0: goldEarned[i] += delta
      elif delta < 0: goldSpent[i] += -delta
      prevGold[i] = g

    # Periodic full status dump
    if sim.tickCount mod config.interval == 0:
      traceFile.writeLine ""
      traceFile.writeLine &"--- tick {sim.tickCount} {marketSummary(sim)} ---"
      for i in 0 ..< bots.len:
        let p = sim.players[i]
        let gears = playerGearTiers(p)
        let snap = PlayerSnapshot(
          gear: gears,
          gold: p.gold,
          role: $p.role,
          listingCount: p.listings.len
        )
        var changes: seq[string]
        if snap.gear != lastSnap[i].gear:
          changes.add &"GEAR {lastSnap[i].gear.gearStr()}->{gears.gearStr()}"
        if snap.role != lastSnap[i].role and lastSnap[i].role.len > 0:
          changes.add &"ROLE {lastSnap[i].role}->{snap.role}"
        let goldDelta = snap.gold - lastSnap[i].gold
        if goldDelta != 0:
          let sign = if goldDelta > 0: "+" else: ""
          changes.add &"gold{sign}{goldDelta}"
        lastSnap[i] = snap
        let changeStr = if changes.len > 0: " << " & changes.join(", ") else: ""
        let matchFilter = config.filter.len == 0 or bots[i].name.toLowerAscii.contains(config.filter.toLowerAscii)
        if matchFilter:
          traceFile.writeLine &"  {bots[i].name:12s} phase={bots[i].phaseName():20s} role={$p.role:10s} gold={p.gold:5d} gear={gears.gearStr()} list={p.listings.len} inv=({invSummary(p)}){changeStr}"

  traceFile.close()

  # Report file
  reportFile.writeLine "=== Final State ==="
  reportFile.writeLine &"  {marketSummary(sim)}"
  reportFile.writeLine ""
  for i in 0 ..< bots.len:
    let p = sim.players[i]
    let gears = playerGearTiers(p)
    var listItems: seq[string]
    for l in p.listings:
      listItems.add &"{l.item}@{l.priceEach}"
    let listStr = if listItems.len > 0: listItems.join(",") else: "none"
    reportFile.writeLine &"  {bots[i].name:12s} role={$p.role:10s} gold={p.gold:5d} gear={gears.gearStr()} listings={listStr}"

  reportFile.writeLine ""
  reportFile.writeLine "=== Bot Scores ==="
  reportFile.writeLine "  score = gear_value + gold_earned + listing_value"
  reportFile.writeLine "  (measures total value contributed to the economy)"
  reportFile.writeLine ""
  for i in 0 ..< bots.len:
    let p = sim.players[i]
    let gears = playerGearTiers(p)
    # Gear value: T1=15, T2=35, T3=70 per slot (matches gear base prices)
    var gearValue = 0
    for g in gears:
      case g
      of 1: gearValue += 15
      of 2: gearValue += 35
      of 3: gearValue += 70
      else: discard
    # Listing value (goods currently for sale — value available to others)
    var listingValue = 0
    for l in p.listings:
      listingValue += l.priceEach * l.quantity
    let score = gearValue + goldEarned[i] + listingValue
    reportFile.writeLine &"  {bots[i].name:12s} score={score:5d}  gear_val={gearValue:3d} earned={goldEarned[i]:4d}g spent={goldSpent[i]:4d}g listings={listingValue:3d}g"

  reportFile.writeLine ""
  reportFile.writeLine "=== Time Breakdown (ticks per phase category) ==="
  for i in 0 ..< bots.len:
    let matchFilter = config.filter.len == 0 or bots[i].name.toLowerAscii.contains(config.filter.toLowerAscii)
    if not matchFilter: continue
    var travel, gathering, crafting, selling, buying, idle, other = 0
    for phase, ticks in phaseTicks[i]:
      let pl = phase.toLowerAscii
      if pl.contains(".navigate"):
        travel += ticks
      elif pl.contains("pathto") or pl.contains("walkto"):
        travel += ticks
      elif pl.contains(".perform") and pl.contains("gather"):
        gathering += ticks
      elif pl.contains("gather") or pl.contains("startgather") or pl.contains("holdgather"):
        gathering += ticks
      elif pl.contains(".perform") and pl.contains("craft"):
        crafting += ticks
      elif pl.contains("craft") or pl.contains("holdcraft") or pl.contains("startcraft"):
        crafting += ticks
      elif pl.contains("sell") or pl.contains("setprice") or pl.contains("confirmsell") or pl.contains("exitsell"):
        selling += ticks
      elif pl.contains("buy") or pl.contains("exitbuy"):
        buying += ticks
      elif pl.contains("wait") or pl.contains("idle") or pl.contains("evaluate"):
        idle += ticks
      else:
        other += ticks
    let total = travel + gathering + crafting + selling + buying + idle + other
    if total == 0: continue
    let pct = proc(v: int): string = &"{v:5d} ({100*v div total:2d}%)"
    reportFile.writeLine &"  {bots[i].name:12s} travel={pct(travel)} gather={pct(gathering)} craft={pct(crafting)} sell={pct(selling)} buy={pct(buying)} idle={pct(idle)} other={pct(other)}"

  reportFile.writeLine ""
  reportFile.writeLine "=== Economy Summary ==="
  reportFile.writeLine ""
  reportFile.writeLine "  --- Per-Bot Assets ---"
  var totalGold, totalListingValue = 0
  var gearCounts: array[4, int]
  for i in 0 ..< bots.len:
    let p = sim.players[i]
    totalGold += p.gold
    let gears = playerGearTiers(p)
    for g in gears:
      inc gearCounts[g]
    reportFile.writeLine &"  {bots[i].name:12s} gold={p.gold:5d} role={$p.role:10s} gear={gears.gearStr()}"
    reportFile.writeLine &"    inventory: W={p.inv.counts[WoodItem]} S={p.inv.counts[StoneItem]} Hw={p.inv.counts[HardwoodItem]} Cu={p.inv.counts[CopperItem]} Iw={p.inv.counts[IronwoodItem]} Fe={p.inv.counts[IronItem]}"
    var invGearCount = 0
    for gi in 6 ..< 21:
      invGearCount += p.inv.counts[ItemKind(gi)]
    if invGearCount > 0:
      reportFile.writeLine &"    gear in inv: {invGearCount} pieces"
    if p.listings.len > 0:
      reportFile.writeLine &"    listings ({p.listings.len}):"
      for l in p.listings:
        totalListingValue += l.priceEach * l.quantity
        reportFile.writeLine &"      {l.item} x{l.quantity} @{l.priceEach}g (total {l.priceEach * l.quantity}g)"
    else:
      reportFile.writeLine &"    listings: none"

  reportFile.writeLine ""
  reportFile.writeLine "  --- Market State ---"
  var matSupply: array[6, int]
  var matValue: array[6, int]
  var gearSupply: array[3, int]
  var gearValue: array[3, int]
  for p in sim.players:
    for l in p.listings:
      case l.item
      of WoodItem: matSupply[0] += l.quantity; matValue[0] += l.priceEach * l.quantity
      of StoneItem: matSupply[1] += l.quantity; matValue[1] += l.priceEach * l.quantity
      of HardwoodItem: matSupply[2] += l.quantity; matValue[2] += l.priceEach * l.quantity
      of CopperItem: matSupply[3] += l.quantity; matValue[3] += l.priceEach * l.quantity
      of IronwoodItem: matSupply[4] += l.quantity; matValue[4] += l.priceEach * l.quantity
      of IronItem: matSupply[5] += l.quantity; matValue[5] += l.priceEach * l.quantity
      else:
        let t = gearTier(l.item)
        if t > 0:
          gearSupply[t-1] += l.quantity
          gearValue[t-1] += l.priceEach * l.quantity
  reportFile.writeLine &"    Wood:     qty={matSupply[0]:3d}  value={matValue[0]:5d}g"
  reportFile.writeLine &"    Stone:    qty={matSupply[1]:3d}  value={matValue[1]:5d}g"
  reportFile.writeLine &"    Hardwood: qty={matSupply[2]:3d}  value={matValue[2]:5d}g"
  reportFile.writeLine &"    Copper:   qty={matSupply[3]:3d}  value={matValue[3]:5d}g"
  reportFile.writeLine &"    Ironwood: qty={matSupply[4]:3d}  value={matValue[4]:5d}g"
  reportFile.writeLine &"    Iron:     qty={matSupply[5]:3d}  value={matValue[5]:5d}g"
  reportFile.writeLine &"    T1 gear:  qty={gearSupply[0]:3d}  value={gearValue[0]:5d}g"
  reportFile.writeLine &"    T2 gear:  qty={gearSupply[1]:3d}  value={gearValue[1]:5d}g"
  reportFile.writeLine &"    T3 gear:  qty={gearSupply[2]:3d}  value={gearValue[2]:5d}g"

  reportFile.writeLine ""
  reportFile.writeLine "  --- Totals ---"
  reportFile.writeLine &"    Total gold held:     {totalGold}g"
  reportFile.writeLine &"    Total listing value: {totalListingValue}g"
  reportFile.writeLine &"    Gear equipped:       empty={gearCounts[0]} T1={gearCounts[1]} T2={gearCounts[2]} T3={gearCounts[3]}"
  reportFile.writeLine &"    Gear slots filled:   {gearCounts[1]+gearCounts[2]+gearCounts[3]}/{bots.len * 5}"

  reportFile.writeLine ""
  reportFile.writeLine "=== Phase Ticks (detailed) ==="
  for i in 0 ..< bots.len:
    let matchFilter = config.filter.len == 0 or bots[i].name.toLowerAscii.contains(config.filter.toLowerAscii)
    if not matchFilter: continue
    reportFile.writeLine &"  {bots[i].name}:"
    var sorted: seq[(int, string)]
    for phase, ticks in phaseTicks[i]:
      sorted.add (ticks, phase)
    sorted.sort(proc(a, b: (int, string)): int = cmp(b[0], a[0]))
    for (ticks, phase) in sorted[0 ..< min(10, sorted.len)]:
      let pct = 100 * ticks div config.ticks
      reportFile.writeLine &"    {phase:25s} {ticks:6d} ticks ({pct:2d}%)"

  reportFile.close()
  echo &"Wrote tmp/diag_trace.txt and tmp/diag_report.txt"

  setCurrentDir(previousDir)

when isMainModule:
  try:
    run(parseArgs())
  except ValueError as e:
    echo e.msg
    echo "Usage: diagnose_bots [--seed:N] [--ticks:N] [--interval:N] [--fixed-lineup] [--filter:name]"
    quit(1)

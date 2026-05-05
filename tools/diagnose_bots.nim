import std/[algorithm, json, os, parseopt, random, strformat, strutils, tables]
import
  ../marketboard/sim,
  ../marketboard/replays,
  ../marketboard/players/common,
  ../marketboard/players/still_forge as sf,
  ../marketboard/players/iron_works as iw,
  ../marketboard/players/colm as colm_bot,
  ../marketboard/players/zorori as zr,
  ../marketboard/players/solenne as sol,
  ../marketboard/players/rkhenna as rk,
  ../marketboard/players/pipitori as pip

const
  BotCount = 7
  MinBots = 5
  MaxBots = 9

type
  BotKind = enum
    bkStillForge
    bkIronWorks
    bkColm
    bkZorori
    bkSolenne
    bkRkhenna
    bkPipitori

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

proc decide(bot: var BotRunner, state: GameState): uint8 =
  case bot.botKind
  of bkStillForge: sf.decide(bot.sfState, state)
  of bkIronWorks: iw.decide(bot.iwState, state)
  of bkColm: colm_bot.decide(bot.colmState, state)
  of bkZorori: zr.decide(bot.zrState, state)
  of bkSolenne: sol.decide(bot.solState, state)
  of bkRkhenna: rk.decide(bot.rkState, state)
  of bkPipitori: pip.decide(bot.pipState, state)

proc phaseName(bot: BotRunner): string =
  case bot.botKind
  of bkStillForge: $bot.sfState.phase
  of bkIronWorks: $bot.iwState.phase
  of bkColm: $bot.colmState.phase
  of bkZorori: $bot.zrState.phase
  of bkSolenne: $bot.solState.phase
  of bkRkhenna: $bot.rkState.phase
  of bkPipitori: $bot.pipState.phase

proc ticksInPhase(bot: BotRunner): int =
  case bot.botKind
  of bkStillForge: bot.sfState.ticksInPhase
  of bkIronWorks: bot.iwState.ticksInPhase
  of bkColm: bot.colmState.ticksInPhase
  of bkZorori: bot.zrState.ticksInPhase
  of bkSolenne: bot.solState.ticksInPhase
  of bkRkhenna: bot.rkState.ticksInPhase
  of bkPipitori: bot.pipState.ticksInPhase

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
    if kind in {bkIronWorks, bkSolenne, bkRkhenna}:
      hasCrafter = true
      break
  if not hasCrafter:
    let crafters = [bkIronWorks, bkSolenne, bkRkhenna]
    result[0] = crafters[rng.rand(2)]
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

  echo &"=== Diagnose Bots: seed={config.seed} ticks={config.ticks} interval={config.interval} ==="
  echo &"Lineup: {lineup}"
  echo ""

  # Track state for change detection
  type PlayerSnapshot = object
    gear: seq[int]
    gold: int
    role: string
    listingCount: int

  var lastPhase: seq[string]
  var lastSnap: seq[PlayerSnapshot]
  var phaseHist: seq[CountTable[string]]

  for i in 0 ..< bots.len:
    lastPhase.add ""
    lastSnap.add PlayerSnapshot(gear: @[0,0,0,0,0], gold: 0, role: "", listingCount: 0)
    phaseHist.add initCountTable[string]()

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

      # Log phase transitions
      let phase = bots[i].phaseName()
      if phase != lastPhase[i]:
        phaseHist[i].inc(phase)
        let matchFilter = config.filter.len == 0 or bots[i].name.toLowerAscii.contains(config.filter.toLowerAscii)
        if matchFilter and lastPhase[i].len > 0:
          let p = sim.players[i]
          let gears = playerGearTiers(p)
          echo &"  [{tick:6d}] {bots[i].name:12s} {lastPhase[i]} -> {phase}  gold={p.gold} gear={gears.gearStr()} inv=({invSummary(p)})"
        lastPhase[i] = phase

    sim.step(inputs)

    # Periodic full status dump
    if sim.tickCount mod config.interval == 0:
      echo ""
      echo &"--- tick {sim.tickCount} {marketSummary(sim)} ---"
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
          echo &"  {bots[i].name:12s} phase={bots[i].phaseName():20s} role={$p.role:10s} gold={p.gold:5d} gear={gears.gearStr()} list={p.listings.len} inv=({invSummary(p)}){changeStr}"

  echo ""
  echo "=== Final State ==="
  echo &"  {marketSummary(sim)}"
  echo ""
  for i in 0 ..< bots.len:
    let p = sim.players[i]
    let gears = playerGearTiers(p)
    var listItems: seq[string]
    for l in p.listings:
      listItems.add &"{l.item}@{l.priceEach}"
    let listStr = if listItems.len > 0: listItems.join(",") else: "none"
    echo &"  {bots[i].name:12s} role={$p.role:10s} gold={p.gold:5d} gear={gears.gearStr()} listings={listStr}"

  echo ""
  echo "=== Phase Time Distribution ==="
  for i in 0 ..< bots.len:
    let matchFilter = config.filter.len == 0 or bots[i].name.toLowerAscii.contains(config.filter.toLowerAscii)
    if not matchFilter: continue
    echo &"  {bots[i].name}:"
    var sorted: seq[(int, string)]
    for phase, count in phaseHist[i]:
      sorted.add (count, phase)
    sorted.sort(proc(a, b: (int, string)): int = cmp(b[0], a[0]))
    for (count, phase) in sorted[0 ..< min(8, sorted.len)]:
      echo &"    {phase:25s} {count:6d}x"

  setCurrentDir(previousDir)

when isMainModule:
  try:
    run(parseArgs())
  except ValueError as e:
    echo e.msg
    echo "Usage: diagnose_bots [--seed:N] [--ticks:N] [--interval:N] [--fixed-lineup] [--filter:name]"
    quit(1)

import std/[algorithm, json, os, parseopt, random, strformat, strutils]
import
  ../sim,
  ../excitement,
  ../legends,
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
  DefaultMatches = 100
  DefaultTicks = 5000
  DefaultTop = 5
  DefaultReplayDir = "replays"
  BotCount = 10
  MinBots = 5
  MaxBots = 11

type
  BotKind* = enum
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

  BatchConfig = object
    matches: int
    ticks: int
    top: int
    replayDir: string
    fixedLineup: bool

  MatchResult = object
    seed: int
    score: float
    lineup: seq[string]
    replayPath: string
    topMoments: seq[int]
    legendEventCount: int
    topLegendEvents: seq[LegendEvent]

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

proc runMatch(seed: int, ticks: int, replayPath: string, fixedLineup: bool): MatchResult =
  var rng = initRand(seed)
  let lineup = generateLineup(rng, fixedLineup)

  var sim = initSimServer(0)
  var bots: seq[BotRunner]
  var writer = openMbReplayWriter(replayPath, "{}")
  var tracker: ExcitementTracker
  var legendTracker = initLegendTracker()

  var nameCounters: array[BotKind, int]
  for kind in lineup:
    inc nameCounters[kind]
    let bot = initBotRunner(kind, nameCounters[kind])
    let idx = sim.addPlayer(bot.name)
    bots.add bot
    writer.writeJoin(tickTime(sim.tickCount), idx, bot.name)
    while writer.lastMasks.len <= idx:
      writer.lastMasks.add(0)

  for tick in 0 ..< ticks:
    var inputs = newSeq[PlayerInput](sim.players.len)
    for i in 0 ..< bots.len:
      if i >= sim.players.len:
        break
      let stateJson = sim.buildStateJson(i)
      let state = parseGameState(stateJson)
      let mask = bots[i].decide(state)


      if i < writer.lastMasks.len and mask != writer.lastMasks[i]:
        writer.writeInput(MbReplayInput(
          time: tickTime(sim.tickCount),
          player: uint8(i),
          keys: mask
        ))
        writer.lastMasks[i] = mask

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

    sim.step(inputs)
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())

    legendTracker.analyze(sim)
    if sim.tickCount mod SnapshotInterval == 0:
      tracker.recordTick(sim)

  writer.closeMbReplayWriter()

  for i, p in sim.players:
    var gearTiers: seq[int]
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
      gearTiers.add max(gt, ct)
    let minTier = min(gearTiers)
    let maxTier = max(gearTiers)
    var listItems: seq[string]
    for l in p.listings:
      listItems.add &"{l.item}@{l.priceEach}"
    let listStr = if listItems.len > 0: listItems.join(",") else: "none"
    echo &"    {p.name:12s} role={p.role:<10s} gold={p.gold:5d} gear=[{gearTiers.join(\",\")}] listings={listStr}"

  let legendsPath = replayPath.replace(".mbreplay", ".legends.json")
  var legendJson = legendTracker.toJson()
  legendJson["replayFile"] = %replayPath
  legendJson["totalTicks"] = %sim.tickCount
  legendJson["summary"] = %legendTracker.summary(sim.players.len, sim.tickCount)
  writeFile(legendsPath, $legendJson)

  result.seed = seed
  result.score = tracker.excitementScore()
  result.lineup = newSeq[string](lineup.len)
  for i, kind in lineup:
    result.lineup[i] = $kind
  result.replayPath = replayPath
  result.topMoments = tracker.topMoments(3)
  result.legendEventCount = legendTracker.events.len
  result.topLegendEvents = legendTracker.topEvents(3)

proc parseArgs(): BatchConfig =
  result.matches = DefaultMatches
  result.ticks = DefaultTicks
  result.top = DefaultTop
  result.replayDir = DefaultReplayDir

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "matches":
        result.matches = parseInt(val)
      of "ticks":
        result.ticks = parseInt(val)
      of "top":
        result.top = parseInt(val)
      of "replay-dir":
        result.replayDir = val
      of "fixed-lineup":
        result.fixedLineup = true
      else:
        raise newException(ValueError, "Unknown option: --" & key)
    else:
      discard

proc run(config: BatchConfig) =
  let previousDir = getCurrentDir()
  let rootDir = getCurrentDir()
  setCurrentDir(rootDir / "marketboard")

  createDir(rootDir / config.replayDir)

  var results: seq[MatchResult]

  echo &"Running {config.matches} matches, {config.ticks} ticks each..."
  echo ""

  for i in 0 ..< config.matches:
    let seed = i
    let replayPath = rootDir / config.replayDir / &"match_{seed:04d}.mbreplay"
    let res = runMatch(seed, config.ticks, replayPath, config.fixedLineup)
    results.add res

    let lineupStr = res.lineup.join(", ")
    echo &"  match {seed:4d}: score={res.score:8.2f}  legends={res.legendEventCount:3d}  bots=[{lineupStr}]"

  setCurrentDir(previousDir)

  results.sort(proc(a, b: MatchResult): int = cmp(b.score, a.score))

  echo ""
  echo &"Top {config.top} most exciting matches:"
  echo &"{'=':#>60}"
  for i in 0 ..< min(config.top, results.len):
    let r = results[i]
    let lineupStr = r.lineup.join(", ")
    echo &"  #{i+1}: seed={r.seed:4d}  score={r.score:8.2f}"
    echo &"       bots=[{lineupStr}]"
    echo &"       replay: {r.replayPath}"
    if r.topMoments.len > 0:
      echo &"       key moments at ticks: {r.topMoments}"
    if r.topLegendEvents.len > 0:
      echo &"       top legend events ({r.legendEventCount} total):"
      for le in r.topLegendEvents:
        echo &"         tick {le.tick:5d}: {le.description}"
    echo ""

  if results.len > config.top:
    for i in config.top ..< results.len:
      try:
        removeFile(results[i].replayPath)
        removeFile(results[i].replayPath.replace(".mbreplay", ".legends.json"))
      except CatchableError:
        discard
    echo &"Kept top {config.top} replays, removed {results.len - config.top} others."

when isMainModule:
  try:
    run(parseArgs())
  except ValueError as e:
    echo e.msg
    echo "Usage: batch_market [--matches:100] [--ticks:5000] [--top:5] [--replay-dir:replays/] [--fixed-lineup]"
    quit(1)

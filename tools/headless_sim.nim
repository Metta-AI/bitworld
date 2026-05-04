import std/[os, parseopt, strformat, strutils]
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

const RootDir = currentSourcePath.parentDir.parentDir
const NumGearSlots = common.GearSlotCount

proc printCheckpoint(server: SimServer, tick: int,
                     bots: tuple[sf: sf.BotState, iw: iw.BotState,
                                 co: colm_bot.BotState, zo: zr.BotState,
                                 so: sol.BotState, rk: rk.BotState,
                                 pi: pip.BotState],
                     indices: array[7, int], names: array[7, string]) =
  echo &"\n=== tick {tick} ==="
  var totalListings = 0
  for i in 0 ..< 7:
    totalListings += server.players[indices[i]].listings.len

  for i, name in names:
    let p = server.players[indices[i]]
    let gc = p.equippedGearCount()
    let gear = p.activeGear()
    var gearStr = ""
    for s in 0 ..< NumGearSlots:
      if gearStr.len > 0: gearStr.add ","
      gearStr.add $gear[s]
    echo &"  {name:12s} gold={p.gold:<4d} gear={gc}/5 role={p.role:<9s} state={p.state}"
    echo &"    inv: wood={p.inv.counts[WoodItem]} stone={p.inv.counts[StoneItem]} hw={p.inv.counts[HardwoodItem]} cu={p.inv.counts[CopperItem]} iw={p.inv.counts[IronwoodItem]} ir={p.inv.counts[IronItem]}"
    echo &"    equipped: [{gearStr}]"
    var invGear = 0
    for item in LeatherHat..PlateShoes:
      invGear += p.inv.counts[item]
    if invGear > 0 or p.listings.len > 0:
      echo &"    invGear={invGear} listings={p.listings.len}"
    if p.role == Crafter:
      echo &"    crafterLvl={p.crafterLevel}"
    if p.role == Gatherer:
      echo &"    gathererLvl={p.gathererLevel}"

  let phases = [
    &"SF={bots.sf.phase}", &"IW={bots.iw.phase}",
    &"CO={bots.co.phase}", &"ZO={bots.zo.phase}",
    &"SO={bots.so.phase}", &"RK={bots.rk.phase}",
    &"PI={bots.pi.phase}"
  ]
  echo &"  phases: {phases.join(\"  \")}"
  echo &"  market: NPC={server.npcListings.len} player={totalListings} cap={server.totalMarketCap()}"

  if totalListings > 0:
    echo "  listings:"
    for pi in 0 ..< server.players.len:
      for li in server.players[pi].listings:
        echo &"    {server.players[pi].name} sells {li.item} qty={li.quantity} @{li.priceEach}g"

proc printStuckDiagnosis(server: SimServer, indices: array[7, int], names: array[7, string],
                         prevGold: array[7, int], tick: int) =
  var stuck: seq[string]
  for i, name in names:
    let p = server.players[indices[i]]
    if p.gold == prevGold[i] and p.state == Idle:
      var reason = ""
      if p.role == Crafter:
        if p.listings.len >= MaxSellSlots:
          reason = "sell slots full"
        elif p.gold == 0:
          reason = "no gold"
        elif not p.inv.hasCraftMaterials():
          reason = "no materials"
      elif p.role == Gatherer:
        if p.listings.len >= MaxSellSlots:
          reason = "sell slots full"
        elif p.equippedGearCount() >= NumGearSlots:
          reason = "full gear, nothing to buy"
      if reason.len > 0:
        stuck.add &"{name}({reason})"
  if stuck.len > 0:
    echo &"  STUCK: {stuck.join(\", \")}"

when isMainModule:
  var ticks = 60000
  var interval = 5000

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "ticks":
        if val.len > 0: ticks = parseInt(val)
      of "interval":
        if val.len > 0: interval = parseInt(val)
      else: discard
    else: discard

  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "marketboard")

  var server = initSimServer(0)

  let names = ["StillForge", "IronWorks", "Colm", "Zorori", "Solenne", "Rkhenna", "Pipitori"]
  var indices: array[7, int]
  for i, name in names:
    indices[i] = server.addPlayer(name)

  var sfBot = sf.BotState(phase: sf.WaitForState)
  var iwBot = iw.BotState(phase: iw.WaitForState)
  var coBot = colm_bot.BotState(phase: colm_bot.WaitForState)
  var zoBot = zr.BotState(phase: zr.WaitForState)
  var soBot = sol.BotState(phase: sol.WaitForState)
  var rkBot = rk.BotState(phase: rk.WaitForState)
  var piBot = pip.BotState(phase: pip.WaitForState)

  var prevMasks: array[7, uint8]
  var prevGold: array[7, int]
  for i in 0 ..< 7:
    prevGold[i] = server.players[indices[i]].gold

  echo &"Headless sim: {ticks} ticks, checkpoints every {interval}"
  echo &"Starting gold: {StartingGold}  Max sell slots: {MaxSellSlots}"
  echo &"Prices: T1 mat={WoodBasePrice}g  T2 mat={HardwoodBasePrice}g  T3 mat={IronwoodBasePrice}g"

  for tick in 0 ..< ticks:
    var masks: array[7, uint8]

    masks[0] = sfBot.decide(parseGameState(server.buildStateJson(indices[0])))
    sfBot.prevMask = masks[0]
    masks[1] = iwBot.decide(parseGameState(server.buildStateJson(indices[1])))
    iwBot.prevMask = masks[1]
    masks[2] = coBot.decide(parseGameState(server.buildStateJson(indices[2])))
    coBot.prevMask = masks[2]
    masks[3] = zoBot.decide(parseGameState(server.buildStateJson(indices[3])))
    zoBot.prevMask = masks[3]
    masks[4] = soBot.decide(parseGameState(server.buildStateJson(indices[4])))
    soBot.prevMask = masks[4]
    masks[5] = rkBot.decide(parseGameState(server.buildStateJson(indices[5])))
    rkBot.prevMask = masks[5]
    masks[6] = piBot.decide(parseGameState(server.buildStateJson(indices[6])))
    piBot.prevMask = masks[6]

    var inputs = newSeq[PlayerInput](server.players.len)
    for i in 0 ..< 7:
      inputs[indices[i]] = maskToPlayerInput(masks[i], prevMasks[i])
    server.step(inputs)
    prevMasks = masks

    if (tick + 1) mod interval == 0:
      let botState = (sf: sfBot, iw: iwBot, co: coBot, zo: zoBot,
                      so: soBot, rk: rkBot, pi: piBot)
      printCheckpoint(server, tick + 1, botState, indices, names)
      printStuckDiagnosis(server, indices, names, prevGold, tick + 1)
      for i in 0 ..< 7:
        prevGold[i] = server.players[indices[i]].gold

  echo "\n=== Final Summary ==="
  var totalScore = 0
  for i, name in names:
    let score = server.rewardScore(indices[i])
    totalScore += score
    let p = server.players[indices[i]]
    let gc = p.equippedGearCount()
    echo &"  {name:12s} score={score:<5d} gold={p.gold:<4d} gear={gc}/5 role={p.role} lvl={max(p.gathererLevel, p.crafterLevel)}"
  echo &"  Total market cap: {server.totalMarketCap()}"
  echo &"  Total score: {totalScore}"

  setCurrentDir(previousDir)

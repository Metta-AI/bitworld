## Phase 1 trace smoke test.
##
## Exercises `openTrace` / `beginRound` / `traceFrame` / `closeTrace`
## by stepping a bot through synthetic frames and confirming:
##
##   - manifest.json exists, parses, has expected top-level fields.
##   - events.jsonl has at least one round_start line.
##   - decisions.jsonl has at least one branch_id line.
##   - parity is preserved: a parallel bot with no trace produces the
##     same mask sequence.
##
## Not a full property test — just a "did it run" check. Real parity
## verification stays in `parity.nim`.

import std/[json, os, random, strutils, tables]
import protocol

import ../bot
import ../types
import ../trace

const ScreenLen = ScreenWidth * ScreenHeight

proc fillBlack(buf: var seq[uint8]) =
  for i in 0 ..< buf.len:
    buf[i] = 0

proc fillRandom(buf: var seq[uint8], rng: var Rand) =
  for i in 0 ..< buf.len:
    buf[i] = uint8(rng.rand(15))

proc main() =
  let traceRoot = getTempDir() / "modulabot_trace_smoke"
  removeDir(traceRoot)
  createDir(traceRoot)

  let seed = 4242'i64
  var
    botTraced = bot.initBot(masterSeed = seed)
    botBaseline = bot.initBot(masterSeed = seed)
    rng = initRand(seed)
    buf = newSeq[uint8](ScreenLen)
    rng2 = initRand(seed)
    buf2 = newSeq[uint8](ScreenLen)

  # Open a trace on the traced bot only.
  botTraced.trace = openTrace(
    rootDir        = traceRoot,
    botName        = "smoke-bot",
    level          = tlDecisions,
    snapshotPeriod = 60,
    captureFrames  = false,
    harnessMeta    = """{"experiment_id":"smoke-1"}""",
    masterSeed     = seed,
    framesPath     = "",
    configJson     = """{"transport":"none"}"""
  )
  botTraced.trace.beginRound(botTraced, isMidRound = false)

  let frames = 60
  var divergent = 0
  for i in 0 ..< frames:
    if (i div 25) mod 2 == 0:
      fillRandom(buf, rng)
      fillRandom(buf2, rng2)
    else:
      fillBlack(buf)
      fillBlack(buf2)
    let maskTraced = botTraced.stepUnpackedFrame(buf)
    let maskBaseline = botBaseline.stepUnpackedFrame(buf2)
    if maskTraced != maskBaseline:
      inc divergent

  botTraced.trace.closeTrace(botTraced, "smoke_end")

  echo "frames=", frames, " divergent=", divergent
  if divergent != 0:
    echo "FAIL: trace perturbed decisions"
    quit(1)

  # Locate the round directory (there should be exactly one).
  let sessionDir = traceRoot / "smoke-bot"
  var roundDir = ""
  for kind, path in walkDir(sessionDir):
    if kind == pcDir:
      for kind2, sub in walkDir(path):
        if kind2 == pcDir and sub.extractFilename.startsWith("round-"):
          roundDir = sub
          break
      if roundDir.len > 0: break
  if roundDir.len == 0:
    echo "FAIL: no round directory written under ", sessionDir
    quit(1)
  echo "round_dir=", roundDir

  # manifest.json sanity
  let manifestPath = roundDir / "manifest.json"
  if not fileExists(manifestPath):
    echo "FAIL: missing manifest.json"
    quit(1)
  let manifest = parseFile(manifestPath)
  doAssert manifest.kind == JObject
  doAssert manifest.hasKey("schema_version")
  doAssert manifest["schema_version"].getInt in [1, 2, 3]
  doAssert manifest.hasKey("session_id")
  doAssert manifest.hasKey("round_id")
  doAssert manifest.hasKey("started_unix_ms")
  doAssert manifest.hasKey("ended_unix_ms")
  doAssert manifest.hasKey("ended_reason")
  doAssert manifest.hasKey("self")
  doAssert manifest.hasKey("config")
  doAssert manifest.hasKey("tuning_snapshot")
  doAssert manifest.hasKey("trace_settings")
  doAssert manifest.hasKey("summary_counters")
  doAssert manifest.hasKey("harness_meta")
  doAssert manifest["harness_meta"].kind == JObject
  doAssert manifest["harness_meta"].hasKey("experiment_id")
  doAssert manifest["tuning_snapshot"]["TeleportThresholdPx"].getInt == 32
  let counters = manifest["summary_counters"]
  doAssert counters["ticks_total"].getInt == frames
  echo "manifest.json: OK ticks_total=", counters["ticks_total"].getInt,
       " events=", counters["events_emitted"].getInt,
       " decisions=", counters["branch_transitions"].getInt

  # events.jsonl: at least round_start
  let eventsPath = roundDir / "events.jsonl"
  if not fileExists(eventsPath):
    echo "FAIL: missing events.jsonl"
    quit(1)
  var sawRoundStart = false
  for line in lines(eventsPath):
    if line.len == 0: continue
    let node = parseJson(line)
    doAssert node.hasKey("tick")
    doAssert node.hasKey("type")
    if node["type"].getStr == "round_start":
      sawRoundStart = true
  if not sawRoundStart:
    echo "FAIL: no round_start in events.jsonl"
    quit(1)
  echo "events.jsonl: OK"

  # decisions.jsonl: at least one line, every line has branch_id
  let decisionsPath = roundDir / "decisions.jsonl"
  if not fileExists(decisionsPath):
    echo "FAIL: missing decisions.jsonl"
    quit(1)
  var decisionLines = 0
  let knownBranches = [
    "bot.interstitial.role_reveal",
    "bot.interstitial.game_over",
    "bot.localizing",
    "bot.not_localized",
    "policy_crew.idle.no_goal",
    "policy_crew.task.astar",
    "policy_crew.task.precise_approach",
    "policy_crew.task.start_hold",
    "policy_crew.task.continue_hold",
    "policy_crew.task.ghost_nav",
    "policy_crew.body.report_in_range",
    "policy_crew.body.navigate_to_body",
    "policy_imp.body.self_report",
    "policy_imp.body.flee",
    "policy_imp.kill.in_range",
    "policy_imp.kill.hunt",
    "policy_imp.fake_task.holding",
    "policy_imp.fake_task.setup",
    "policy_imp.fake_task.setup_in_tail",
    "policy_imp.fake_task.setup_in_wander",
    "policy_imp.central_room.force_leave",
    "policy_imp.follow.tail",
    "policy_imp.wander.next_target",
    "policy_imp.wander.idle_unreachable",
    "policy_imp.wander.idle_no_target",
    "voting.idle.already_voted",
    "voting.cursor.move",
    "voting.cursor.listen",
    "voting.press_a"
  ]
  var seenBranches = initCountTable[string]()
  for line in lines(decisionsPath):
    if line.len == 0: continue
    let node = parseJson(line)
    doAssert node.hasKey("branch_id")
    doAssert node.hasKey("intent")
    doAssert node.hasKey("tick")
    let bid = node["branch_id"].getStr
    seenBranches.inc(bid)
    if bid notin knownBranches:
      echo "FAIL: unknown branch_id ", bid
      quit(1)
    inc decisionLines
  if decisionLines == 0:
    echo "FAIL: decisions.jsonl is empty"
    quit(1)
  echo "decisions.jsonl: OK distinct_branches=", seenBranches.len,
       " total=", decisionLines
  for bid, count in seenBranches.pairs:
    echo "  ", bid, " x", count

  # snapshots.jsonl: at least one line at the period boundary (tick=60)
  let snapshotsPath = roundDir / "snapshots.jsonl"
  if not fileExists(snapshotsPath):
    echo "FAIL: missing snapshots.jsonl"
    quit(1)
  var snapshotLines = 0
  for line in lines(snapshotsPath):
    if line.len == 0: continue
    let node = parseJson(line)
    doAssert node.hasKey("tick")
    doAssert node.hasKey("self")
    doAssert node.hasKey("visible")
    doAssert node.hasKey("evidence_top")
    doAssert node.hasKey("task_model_summary")
    inc snapshotLines
  doAssert snapshotLines >= 1
  echo "snapshots.jsonl: OK lines=", snapshotLines

  echo "all checks passed"

when isMainModule:
  main()

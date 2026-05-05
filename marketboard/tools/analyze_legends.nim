import std/[algorithm, json, os, parseopt, strformat, strutils]
import
  ../sim,
  ../replays,
  ../legends

proc analyzeReplay(replayPath: string, verbose: bool): tuple[json: JsonNode, summary: string, topScore: float] =
  let absReplayPath = absolutePath(replayPath)
  let previousDir = getCurrentDir()
  setCurrentDir(getCurrentDir() / "marketboard")
  defer: setCurrentDir(previousDir)

  let data = loadMbReplay(absReplayPath)
  var sim = initSimServer(0)
  var replay = initMbReplayPlayer(data)
  var tracker = initLegendTracker()

  while replay.playing:
    replay.stepReplay(sim)
    tracker.analyze(sim)

  let totalTicks = sim.tickCount
  var output = tracker.toJson()
  output["replayFile"] = %replayPath
  output["totalTicks"] = %totalTicks
  output["summary"] = %tracker.summary(sim.players.len, totalTicks)

  let top = tracker.topEvents(1)
  let topScore = if top.len > 0: top[0].excitement else: 0.0

  (output, tracker.summary(sim.players.len, totalTicks), topScore)

proc analyzeSingle(replayPath: string) =
  echo &"Analyzing {replayPath}..."
  let (output, summary, _) = analyzeReplay(replayPath, true)

  let outPath = replayPath.replace(".mbreplay", ".legends.json")
  writeFile(outPath, $output)
  echo &"  Wrote {outPath}"
  echo &"  Events: {output[\"eventCount\"].getInt()}"
  echo &"  Summary: {summary}"
  echo ""

  let topEvents = output["topEvents"]
  if topEvents.len > 0:
    echo "Top events:"
    for i in 0 ..< min(5, topEvents.len):
      let e = topEvents[i]
      echo &"  tick {e[\"tick\"].getInt():5d}: [{e[\"kind\"].getStr()}] {e[\"description\"].getStr()} (excitement: {e[\"excitement\"].getFloat():.1f})"

proc analyzeBatch(replayDir: string, top: int) =
  var replays: seq[string]
  for file in walkDir(replayDir):
    if file.path.endsWith(".mbreplay"):
      replays.add file.path
  replays.sort()

  if replays.len == 0:
    echo &"No .mbreplay files found in {replayDir}"
    return

  echo &"Analyzing {replays.len} replays in {replayDir}..."
  echo ""

  type ReplayResult = tuple[path: string, eventCount: int, topScore: float, summary: string]
  var results: seq[ReplayResult]

  for path in replays:
    try:
      let (output, summary, topScore) = analyzeReplay(path, false)
      let outPath = path.replace(".mbreplay", ".legends.json")
      writeFile(outPath, $output)
      let eventCount = output["eventCount"].getInt()
      results.add (path, eventCount, topScore, summary)
      echo &"  {extractFilename(path)}: {eventCount} events, top excitement: {topScore:.1f}"
    except CatchableError as e:
      echo &"  {extractFilename(path)}: ERROR - {e.msg}"

  results.sort(proc(a, b: ReplayResult): int = cmp(b.topScore, a.topScore))

  echo ""
  echo &"Top {min(top, results.len)} most eventful replays:"
  echo &"{'=':#>60}"
  for i in 0 ..< min(top, results.len):
    let r = results[i]
    echo &"  #{i+1}: {extractFilename(r.path)}"
    echo &"       events: {r.eventCount}, top excitement: {r.topScore:.1f}"
    echo &"       {r.summary}"
    echo ""

when isMainModule:
  var
    replayPath = ""
    replayDir = ""
    top = 5

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "replay":
        replayPath = val
      of "replay-dir":
        replayDir = val
      of "top":
        top = parseInt(val)
      else:
        raise newException(ValueError, "Unknown option: --" & key)
    of cmdArgument:
      if replayPath.len == 0:
        replayPath = key
    else:
      discard

  if replayPath.len > 0:
    analyzeSingle(replayPath)
  elif replayDir.len > 0:
    analyzeBatch(replayDir, top)
  else:
    echo "Usage:"
    echo "  analyze_legends --replay:path/to/match.mbreplay"
    echo "  analyze_legends --replay-dir:replays/ [--top:5]"
    quit(1)

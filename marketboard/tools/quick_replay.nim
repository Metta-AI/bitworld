import std/[os, osproc, strutils, parseopt, strformat]

const
  BatchSource = "marketboard" / "tools" / "batch_market.nim"
  ViewerSource = "marketboard" / "replay_viewer.nim"
  FullmapSource = "marketboard" / "fullmap_viewer.nim"
  HeadlessSource = "marketboard" / "tools" / "headless_sim.nim"
  DefaultTicks = 10000
  DefaultReplayDir = "replays"

when isMainModule:
  var ticks = DefaultTicks
  var headless = false
  var playerCam = false
  var checkpointInterval = 5000
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      if key == "ticks" and val.len > 0:
        ticks = parseInt(val)
      elif key == "headless":
        headless = true
      elif key == "player-cam":
        playerCam = true
      elif key == "interval" and val.len > 0:
        checkpointInterval = parseInt(val)
    else: discard

  let nimExe = findExe("nim")
  if nimExe.len == 0:
    echo "Unable to find 'nim' on PATH."
    quit(1)

  if headless:
    echo "Running headless sim..."
    quit(execCmd(&"{nimExe} r {HeadlessSource} --ticks:{ticks} --interval:{checkpointInterval}"))
  else:
    echo &"Recording 1 match ({ticks} ticks)..."
    var rc = execCmd(&"{nimExe} r {BatchSource} --matches:1 --ticks:{ticks} --fixed-lineup")
    if rc != 0:
      echo "Match recording failed."
      quit(rc)

    let replayPath = absolutePath(DefaultReplayDir / "match_0000.mbreplay")
    if not fileExists(replayPath):
      echo "Replay file not found at ", replayPath
      quit(1)

    let activeViewer = if playerCam: ViewerSource else: FullmapSource
    echo "Opening replay viewer..."
    quit(execCmd(&"{nimExe} r {activeViewer} {replayPath}"))

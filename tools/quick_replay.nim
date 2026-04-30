import std/[os, osproc, strutils, parseopt, strformat]

const
  BatchSource = "tools" / "batch_market.nim"
  ViewerSource = "marketboard" / "replay_viewer.nim"
  DefaultTicks = 10000
  DefaultReplayDir = "replays"

proc repoRoot(): string =
  absolutePath(getCurrentDir())

when isMainModule:
  var ticks = DefaultTicks
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      if key == "ticks" and val.len > 0:
        ticks = parseInt(val)
    else: discard

  let
    rootDir = repoRoot()
    nimExe = findExe("nim")
  if nimExe.len == 0:
    echo "Unable to find 'nim' on PATH."
    quit(1)

  echo "Compiling batch runner..."
  var rc = execCmd(&"{nimExe} c {rootDir / BatchSource}")
  if rc != 0:
    quit(rc)

  echo "Compiling replay viewer..."
  rc = execCmd(&"{nimExe} c {rootDir / ViewerSource}")
  if rc != 0:
    quit(rc)

  echo &"Recording 1 match ({ticks} ticks)..."
  let batchExe = rootDir / BatchSource.changeFileExt(ExeExts[0])
  rc = execCmd(&"{batchExe} --matches:1 --ticks:{ticks} --fixed-lineup")
  if rc != 0:
    echo "Match recording failed."
    quit(rc)

  let replayPath = rootDir / DefaultReplayDir / "match_0000.mbreplay"
  if not fileExists(replayPath):
    echo "Replay file not found at ", replayPath
    quit(1)

  echo "Opening replay viewer..."
  let viewerExe = rootDir / ViewerSource.changeFileExt(ExeExts[0])
  let viewerWorkDir = rootDir / "marketboard"
  quit(execShellCmd(&"cd {viewerWorkDir} && {viewerExe} {replayPath}"))

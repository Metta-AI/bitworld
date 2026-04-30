## Cron-style sweeper for modulabot frames dumps.
##
## The trace writer keeps every per-round frames dump forever
## (~117 MB/game uncompressed). This tool walks the trace tree,
## decides which rounds to keep, and removes the external frames
## dump file pointed at by each pruned round's
## `manifest.json → config.frames_dump_path`. The rest of the round
## (manifest, events, decisions, snapshots) is preserved unchanged —
## only the large frames dump is swept.
##
## Retention policy (TRACING.md §14.6):
##   * Keep the most recent K rounds across the whole trace tree
##     (default K = 10). "Most recent" is ordered by `manifest.json`
##     `started_unix_ms`; if that key is missing we fall back to the
##     filesystem mtime of the round directory.
##   * A round is pinned (never swept) if a `RETAIN` sentinel file
##     exists inside its round directory. Pinned rounds do not count
##     against the K budget.
##
## Usage:
##   nim r tools/frames_sweep.nim --root:<trace-root> [--keep:10]
##                                [--dry-run] [--verbose]
##
## `--dry-run` prints the planned actions without deleting anything.
## Exit code is 0 on success (including nothing-to-do), non-zero on
## hard failures (unreadable root, failed deletes).

import std/[algorithm, json, os, parseopt, strformat, strutils, times]

type
  RoundEntry = object
    roundDir:      string
    framesPath:    string       ## from manifest.config.frames_dump_path
    startedUnixMs: int64        ## orderable key; 0 if unknown
    pinned:        bool         ## RETAIN sentinel present
    sessionId:     string
    roundId:       int

proc parseStartedUnixMs(node: JsonNode): int64 =
  ## Reads `started_unix_ms` from a parsed manifest, returning 0 if
  ## missing or malformed. Accepts both integer and numeric-string
  ## encodings for defensive robustness.
  if node.kind != JObject:
    return 0
  if not node.hasKey("started_unix_ms"):
    return 0
  let raw = node["started_unix_ms"]
  case raw.kind
  of JInt:    int64(raw.getInt)
  of JString:
    try: parseBiggestInt(raw.getStr).int64
    except ValueError: 0
  else: 0

proc parseFramesPath(node: JsonNode): string =
  ## Returns `config.frames_dump_path` from a manifest node, or "" if
  ## frames were not dumped for this round.
  if node.kind != JObject or not node.hasKey("config"):
    return ""
  let config = node["config"]
  if config.kind != JObject or not config.hasKey("frames_dump_path"):
    return ""
  let val = config["frames_dump_path"]
  if val.kind == JString: val.getStr else: ""

proc loadRound(roundDir: string): RoundEntry =
  result.roundDir = roundDir
  result.pinned = fileExists(roundDir / "RETAIN")
  let manifestPath = roundDir / "manifest.json"
  if not fileExists(manifestPath):
    try:
      result.startedUnixMs = int64(getLastModificationTime(roundDir).toUnix * 1000)
    except OSError:
      result.startedUnixMs = 0
    return
  let node =
    try: parseFile(manifestPath)
    except JsonParsingError, ValueError, IOError, OSError:
      return
  result.framesPath    = parseFramesPath(node)
  result.startedUnixMs = parseStartedUnixMs(node)
  if result.startedUnixMs == 0:
    try:
      result.startedUnixMs = int64(getLastModificationTime(roundDir).toUnix * 1000)
    except OSError:
      result.startedUnixMs = 0
  if node.kind == JObject:
    if node.hasKey("session_id"):
      result.sessionId = node["session_id"].getStr
    if node.hasKey("round_id"):
      result.roundId = node["round_id"].getInt

proc walkRounds(root: string): seq[RoundEntry] =
  result = @[]
  if not dirExists(root):
    return
  for kindBot, botDir in walkDir(root):
    if kindBot != pcDir: continue
    for kindSession, sessionDir in walkDir(botDir):
      if kindSession != pcDir: continue
      for kindRound, roundDir in walkDir(sessionDir):
        if kindRound != pcDir: continue
        if not roundDir.lastPathPart.startsWith("round-"): continue
        result.add(loadRound(roundDir))

proc removeQuietly(path: string, dryRun, verbose: bool): bool =
  if path.len == 0:
    return true
  if not fileExists(path):
    if verbose:
      echo &"  skip (already absent): {path}"
    return true
  if dryRun:
    echo &"  [dry] rm {path}"
    return true
  try:
    removeFile(path)
    if verbose:
      echo &"  rm {path}"
    true
  except OSError as e:
    echo &"  FAIL rm {path}: {e.msg}"
    false

proc main() =
  var root = ""
  var keep = 10
  var dryRun = false
  var verbose = false
  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "root":    root = val
      of "keep":
        try: keep = parseInt(val)
        except ValueError:
          echo &"bad --keep: {val}"
          quit(2)
      of "dry-run": dryRun = true
      of "verbose": verbose = true
      of "help", "h":
        echo "usage: frames_sweep --root:<trace-root> [--keep:10] " &
             "[--dry-run] [--verbose]"
        quit(0)
      else: discard
    else: discard
  if root.len == 0:
    echo "missing --root"
    quit(2)
  if keep < 0:
    keep = 0
  var entries = walkRounds(root)
  if entries.len == 0:
    echo &"frames_sweep: no rounds found under {root}"
    return

  # Newest first — we keep the first `keep` unpinned entries.
  entries.sort(proc(a, b: RoundEntry): int =
    cmp(b.startedUnixMs, a.startedUnixMs))

  var kept = 0
  var pinned = 0
  var sweptCount = 0
  var sweptFailures = 0
  for entry in entries:
    if entry.pinned:
      inc pinned
      if verbose:
        echo &"pin  {entry.roundDir}"
      continue
    if kept < keep:
      inc kept
      if verbose:
        echo &"keep {entry.roundDir}"
      continue
    if entry.framesPath.len == 0:
      # Nothing to sweep for this round (no frames dump).
      continue
    echo &"sweep {entry.roundDir}"
    if not removeQuietly(entry.framesPath, dryRun, verbose):
      inc sweptFailures
      continue
    inc sweptCount

  echo &"frames_sweep: rounds={entries.len} pinned={pinned} " &
       &"kept={kept} swept={sweptCount} failed={sweptFailures}" &
       (if dryRun: " [dry-run]" else: "")
  if sweptFailures > 0:
    quit(1)

when isMainModule:
  main()

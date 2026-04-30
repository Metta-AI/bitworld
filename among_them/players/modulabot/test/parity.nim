## Parity harness.
##
## Two test modes:
##
##   1. **Self-consistency (default).** Two modulabot instances with
##      the same master seed run through the same frame stream and
##      diff their output masks every tick. Any divergence is a
##      determinism bug (uninitialized state, hidden global,
##      non-substream RNG read, etc.).
##
##   2. **v2 comparison (`--vs:v2`).** One modulabot and one
##      evidencebot_v2 instance run through the same frame stream
##      and diff their output masks. This is the strategy-parity
##      test: divergence is a bug if it appears in
##      crewmate / interstitial / vote paths, and an *expected*
##      drift on RNG-dependent imposter paths (v2 seeds RNG from
##      clock+pid with no override; modulabot seeds from `--seed`
##      via Q6 substreams).
##
## ## Frame sources
##
##   * `--mode:black` — all-zero frames, exercises interstitial path.
##   * `--mode:random` — random palette indices, exercises localize-
##     fail path. Slow (~6 s/frame).
##   * `--mode:mixed` — alternates blocks of black + random.
##   * `--replay:<file>` — captured real-game frames via
##     `modulabot --frames:<file>`. Each frame is
##     `ScreenWidth*ScreenHeight = 16384` raw bytes; the capture
##     file is a flat concatenation, record count is `filesize / 16384`.

import std/[parseopt, random, strformat, strutils]
import protocol

import ../bot
import ../types
import ../trace
import ../../evidencebot_v2  # v2's Bot, initBot, decideNextMask now exported

const
  DefaultFrameCount = 200
  ScreenLen = ScreenWidth * ScreenHeight

# ---------------------------------------------------------------------------
# Frame generators
# ---------------------------------------------------------------------------

type
  Mode = enum
    ModeRandom    ## random palette indices
    ModeBlack     ## all-zero (interstitial)
    ModeMixed     ## alternates blocks of random + black

proc parseMode(s: string): Mode =
  case s
  of "random": ModeRandom
  of "black": ModeBlack
  of "mixed": ModeMixed
  else: ModeRandom

proc fillRandomFrame(frame: var seq[uint8], rng: var Rand) =
  if frame.len != ScreenLen:
    frame.setLen(ScreenLen)
  for i in 0 ..< frame.len:
    frame[i] = uint8(rng.rand(15))

proc fillBlackFrame(frame: var seq[uint8]) =
  if frame.len != ScreenLen:
    frame.setLen(ScreenLen)
  for i in 0 ..< frame.len:
    frame[i] = 0

proc fillFrame(frame: var seq[uint8], mode: Mode, rng: var Rand,
              tick: int) =
  case mode
  of ModeRandom: fillRandomFrame(frame, rng)
  of ModeBlack: fillBlackFrame(frame)
  of ModeMixed:
    if (tick div 25) mod 2 == 0:
      fillRandomFrame(frame, rng)
    else:
      fillBlackFrame(frame)

# ---------------------------------------------------------------------------
# Replay frame loader
# ---------------------------------------------------------------------------

proc loadReplayFrames(path: string): seq[seq[uint8]] =
  ## Loads a flat-concatenated frame dump (one frame = ScreenLen
  ## bytes). Returns an empty seq if the file doesn't exist or is
  ## not a multiple of ScreenLen.
  let data =
    try: readFile(path)
    except IOError: return @[]
  if data.len mod ScreenLen != 0:
    echo &"replay file {path} has invalid size {data.len} (not a multiple of {ScreenLen})"
    return @[]
  let count = data.len div ScreenLen
  result = newSeq[seq[uint8]](count)
  for i in 0 ..< count:
    result[i] = newSeq[uint8](ScreenLen)
    for j in 0 ..< ScreenLen:
      result[i][j] = uint8(data[i * ScreenLen + j])

# ---------------------------------------------------------------------------
# Self-consistency harness
# ---------------------------------------------------------------------------

proc runSelfConsistency(frames: seq[seq[uint8]], seed: int64,
                       verbose: bool, traceDir: string): int =
  ## Builds two modulabot instances with the same master seed, runs
  ## them through the same frame stream, returns the count of
  ## divergent frames. Q6's per-consumer substreams + identical seed
  ## means imposter RNG paths should also match byte-for-byte.
  ##
  ## When `traceDir` is non-empty, attaches a trace writer to bot A
  ## only. The expectation is that trace output is non-perturbing —
  ## divergence here would mean the writer has a side effect on the
  ## bot (TRACING.md §13.2).
  var
    botA = bot.initBot(masterSeed = seed)
    botB = bot.initBot(masterSeed = seed)
    divergent = 0
  if traceDir.len > 0:
    botA.trace = openTrace(
      rootDir        = traceDir,
      botName        = "parity-A",
      level          = tlDecisions,
      snapshotPeriod = 60,
      captureFrames  = false,
      harnessMeta    = """{"experiment_id":"parity"}""",
      masterSeed     = seed,
      framesPath     = "",
      configJson     = """{"transport":"none","mode":"parity"}"""
    )
    botA.trace.beginRound(botA, isMidRound = false)
  for i, frame in frames:
    let maskA = botA.stepUnpackedFrame(frame)
    let maskB = botB.stepUnpackedFrame(frame)
    if maskA != maskB:
      inc divergent
      if verbose:
        echo &"  frame {i:>4}: A={maskA:#04x}  B={maskB:#04x}  DIVERGE"
    elif verbose:
      echo &"  frame {i:>4}: {maskA:#04x}  match"
  if not botA.trace.isNil:
    botA.trace.closeTrace(botA, "parity_end")
  divergent

proc runVsV2(frames: seq[seq[uint8]], seed: int64,
            verbose: bool): tuple[divergent, total: int] =
  ## Builds one modulabot and one evidencebot_v2 instance and runs
  ## them through the same frame stream, diffing output masks.
  ##
  ## v2 has no `--seed` plumbing (its `initBot()` seeds from
  ## `getTime() ^ pid`). For non-RNG paths (crewmate, interstitial,
  ## vote, perception) divergence is a real bug. For RNG-dependent
  ## imposter paths (random innocent picks, fake-task die rolls,
  ## followee swap selection) divergence is *expected*; this proc
  ## reports raw counts and lets the caller interpret.
  var
    mb = bot.initBot(masterSeed = seed)
    v2 = evidencebot_v2.initBot()
    divergent = 0
  for i, frame in frames:
    let mbMask = mb.stepUnpackedFrame(frame)
    let v2Mask = evidencebot_v2.stepUnpackedFrame(v2, frame)
    if mbMask != v2Mask:
      inc divergent
      if verbose:
        echo &"  frame {i:>4}: mb={mbMask:#04x}  v2={v2Mask:#04x}  DIVERGE"
    elif verbose:
      echo &"  frame {i:>4}: {mbMask:#04x}  match"
  (divergent, frames.len)

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

type
  TestMode = enum
    TestSelf      ## modulabot vs modulabot
    TestVsV2      ## modulabot vs evidencebot_v2

proc parseTest(s: string): TestMode =
  case s
  of "self", "": TestSelf
  of "v2": TestVsV2
  else: TestSelf

proc main() =
  var
    frameCount = DefaultFrameCount
    seed = 42'i64
    mode = ModeRandom
    verbose = false
    replayPath = ""
    test = TestSelf
    traceDir = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "frames": frameCount = parseInt(val)
      of "seed": seed = parseInt(val).int64
      of "mode": mode = parseMode(val)
      of "verbose": verbose = true
      of "replay": replayPath = val
      of "vs": test = parseTest(val)
      of "trace-dir": traceDir = val
      else: discard
    else: discard

  var frames: seq[seq[uint8]]
  if replayPath.len > 0:
    frames = loadReplayFrames(replayPath)
    if frames.len == 0:
      echo &"replay {replayPath}: no frames loaded"
      quit(2)
    echo &"parity vs={test}: replay={replayPath} frames={frames.len} seed={seed}"
  else:
    echo &"parity vs={test}: frames={frameCount} seed={seed} mode={mode}"
    var
      rng = initRand(seed xor 0xDEADBEEF'i64)
      buf = newSeq[uint8](ScreenLen)
    frames = newSeq[seq[uint8]](frameCount)
    for i in 0 ..< frameCount:
      fillFrame(buf, mode, rng, i)
      frames[i] = buf  # copies

  let (divergent, total) =
    case test
    of TestSelf: (runSelfConsistency(frames, seed, verbose, traceDir),
                  frames.len)
    of TestVsV2: runVsV2(frames, seed, verbose)

  let pct =
    if total > 0: divergent.float * 100.0 / total.float
    else: 0.0
  echo &"\nresult: {total - divergent}/{total} match " &
       &"({100.0 - pct:.1f}% parity)"
  if divergent > 0:
    quit(1)

when isMainModule:
  main()

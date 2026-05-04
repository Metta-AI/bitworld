## Camera localization: patch-hash global search, local frame-fit refit,
## spiral fallback, and the interstitial detector.
##
## Phase 1 port from v2:696-914 (patch hashing + scoring), v2:1149-1306
## (interstitial / near-frame / spiral / dispatcher), v2:1357-1372
## (visible-map memoization).
##
## Q2 resolved (option c) removed v2's inlined sprite scans from
## `updateLocation`; the orchestrator now runs `actors.scanAll` first
## using the prev-frame camera, calls `updateLocation` here, and may
## re-scan post-lock if the camera jumped further than
## `tuning.TeleportThresholdPx`. As a consequence the v2 forward-decl
## block at v2:843-930 is gone.
##
## Cross-record helpers (`reseedAfterInterstitial`, `resetRoundState`)
## live in `bot.nim` because they touch most sub-records; this module
## only owns Perception camera state and the patch tables.

import std/[algorithm, monotimes, times]

import protocol
import ../../sim

import types
import geometry
import frame

const
  FullFrameFitMaxErrors* = 420
  LocalFrameFitMaxErrors* = 320
  FrameFitMinCompared* = 12000
  LocalFrameSearchRadius* = 8
  PatchSize* = 8
  PatchGridW* = ScreenWidth div PatchSize
  PatchGridH* = ScreenHeight div PatchSize
  PatchHashBase* = 16777619'u64
  PatchHashSeed* = 14695981039346656037'u64
  PatchMaxMatches* = 4096
  PatchTopCandidates* = 16
  PatchMinVotes* = 3
  InterstitialBlackPercent* = 30

# ---------------------------------------------------------------------------
# Comparators (kept module-internal because only this module uses them)
# ---------------------------------------------------------------------------

proc `<`(a, b: PatchEntry): bool =
  if a.hash == b.hash:
    if a.cameraY == b.cameraY:
      a.cameraX < b.cameraX
    else:
      a.cameraY < b.cameraY
  else:
    a.hash < b.hash

proc cmpPatchCandidate(a, b: PatchCandidate): int =
  if a.votes != b.votes:
    return cmp(b.votes, a.votes)
  if a.cameraY != b.cameraY:
    return cmp(a.cameraY, b.cameraY)
  cmp(a.cameraX, b.cameraX)

# ---------------------------------------------------------------------------
# Camera scoring (full-frame fit)
# ---------------------------------------------------------------------------

type
  CameraScore* = object
    score*: int
    errors*: int
    compared*: int

proc scoreCamera*(bot: Bot, cameraX, cameraY,
                 maxErrors: int): CameraScore =
  ## Counts map-fit errors for one camera candidate over a full
  ## 128×128 frame. Early-exits once errors exceed `maxErrors`.
  ## Verbatim from v2:696-721.
  for sy in 0 ..< ScreenHeight:
    for sx in 0 ..< ScreenWidth:
      let frameColor = bot.io.unpacked[sy * ScreenWidth + sx]
      if bot.ignoreFramePixel(frameColor, sx, sy):
        continue
      let
        mx = cameraX + sx
        my = cameraY + sy
        mapColor =
          if inMap(mx, my):
            bot.sim.mapPixels[mapIndexSafe(mx, my)]
          else:
            MapVoidColor
      if frameColor == mapColor:
        inc result.compared
      elif ShadowMap[mapColor and 0x0f] == frameColor:
        inc result.compared
      else:
        inc result.compared
        inc result.errors
        if result.errors > maxErrors:
          result.score = -result.errors
          return
  result.score = result.compared - result.errors * ScreenWidth

# ---------------------------------------------------------------------------
# Patch-hash table (built once at construction)
# ---------------------------------------------------------------------------

proc patchHashAdd(hash: uint64, color: uint8): uint64 =
  hash * PatchHashBase + uint64(color and 0x0f) + 1'u64

proc patchMapColor(sim: SimServer, x, y: int): uint8 =
  if inMap(x, y):
    sim.mapPixels[mapIndexSafe(x, y)]
  else:
    MapVoidColor

proc mapPatchHash(sim: SimServer, x, y: int): uint64 =
  result = PatchHashSeed
  for py in 0 ..< PatchSize:
    for px in 0 ..< PatchSize:
      result = patchHashAdd(result, sim.patchMapColor(x + px, y + py))

proc framePatchHash(bot: Bot, sx, sy: int, hash: var uint64): bool =
  ## Hashes one clean (no-dynamic-pixel) 8×8 frame patch. Returns
  ## false if any pixel inside the patch is dynamic — those patches
  ## can't safely contribute votes.
  hash = PatchHashSeed
  for py in 0 ..< PatchSize:
    for px in 0 ..< PatchSize:
      let
        x = sx + px
        y = sy + py
        color = bot.io.unpacked[y * ScreenWidth + x]
      if bot.ignoreFramePixel(color, x, y):
        return false
      hash = patchHashAdd(hash, color)
  true

proc buildPatchEntries*(bot: var Bot) =
  ## Builds the static patch-hash index. Called once from `initBot`
  ## after `sim` is loaded.
  let
    minX = minCameraX()
    maxX = maxCameraX() + ScreenWidth - PatchSize
    minY = minCameraY()
    maxY = maxCameraY() + ScreenHeight - PatchSize
    width = maxCameraX() - minCameraX() + 1
    height = maxCameraY() - minCameraY() + 1
  bot.percep.patchEntries = @[]
  bot.percep.patchEntries.setLen((maxX - minX + 1) * (maxY - minY + 1))
  var i = 0
  for y in minY .. maxY:
    for x in minX .. maxX:
      bot.percep.patchEntries[i] = PatchEntry(
        hash: bot.sim.mapPatchHash(x, y),
        cameraX: x,
        cameraY: y
      )
      inc i
  bot.percep.patchEntries.sort()
  bot.percep.patchVotes = newSeq[uint16](width * height)
  bot.percep.patchTouched = @[]
  bot.percep.patchCandidates = @[]

proc patchHashRange(entries: openArray[PatchEntry],
                   hash: uint64): tuple[first, last: int] =
  ## Binary-search the sorted entries for the contiguous range with
  ## the given hash.
  var
    lo = 0
    hi = entries.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if entries[mid].hash < hash:
      lo = mid + 1
    else:
      hi = mid
  result.first = lo
  hi = entries.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if entries[mid].hash > hash:
      hi = mid
    else:
      lo = mid + 1
  result.last = lo

proc addPatchVote(bot: var Bot, x, y: int) =
  if x < minCameraX() or x > maxCameraX() or
      y < minCameraY() or y > maxCameraY():
    return
  if not cameraCanHoldPlayer(x, y):
    return
  let index = cameraIndex(x, y)
  if bot.percep.patchVotes[index] == 0:
    bot.percep.patchTouched.add(index)
  bot.percep.patchVotes[index] = bot.percep.patchVotes[index] + 1

proc collectPatchCandidates(bot: var Bot) =
  bot.percep.patchCandidates.setLen(0)
  for index in bot.percep.patchTouched:
    let votes = bot.percep.patchVotes[index].int
    if votes < PatchMinVotes:
      continue
    bot.percep.patchCandidates.add(PatchCandidate(
      votes: votes,
      cameraX: cameraIndexX(index),
      cameraY: cameraIndexY(index)
    ))
  bot.percep.patchCandidates.sort(cmpPatchCandidate)
  if bot.percep.patchCandidates.len > PatchTopCandidates:
    bot.percep.patchCandidates.setLen(PatchTopCandidates)

proc clearPatchVotes(bot: var Bot) =
  for index in bot.percep.patchTouched:
    bot.percep.patchVotes[index] = 0
  bot.percep.patchTouched.setLen(0)

# ---------------------------------------------------------------------------
# Lock helpers
# ---------------------------------------------------------------------------

proc acceptCameraScore(score: CameraScore, maxErrors: int): bool =
  ## True when a camera score is good enough to trust as a lock.
  score.errors <= maxErrors and score.compared >= FrameFitMinCompared

proc setCameraLock(bot: var Bot, x, y: int,
                  score: CameraScore, lock: CameraLock) =
  bot.percep.cameraX = x
  bot.percep.cameraY = y
  bot.percep.cameraScore = score.score
  bot.percep.cameraLock = lock
  bot.percep.localized = true

# ---------------------------------------------------------------------------
# Locator strategies
# ---------------------------------------------------------------------------

proc locateByPatches(bot: var Bot): bool =
  ## Cheap-ish global localizer: hash 8×8 frame patches, look each up
  ## in the static map index, vote for camera offsets, score the
  ## top-N candidates with `scoreCamera`. v2:853-896.
  if bot.percep.patchEntries.len == 0:
    return false
  bot.clearPatchVotes()
  for py in 0 ..< PatchGridH:
    for px in 0 ..< PatchGridW:
      let
        sx = px * PatchSize
        sy = py * PatchSize
      var hash = 0'u64
      if not bot.framePatchHash(sx, sy, hash):
        continue
      let r = patchHashRange(bot.percep.patchEntries, hash)
      if r.last - r.first > PatchMaxMatches:
        continue
      for i in r.first ..< r.last:
        let
          entry = bot.percep.patchEntries[i]
          x = entry.cameraX - sx
          y = entry.cameraY - sy
        bot.addPatchVote(x, y)
  bot.collectPatchCandidates()
  var
    bestScore = CameraScore(score: low(int), errors: high(int), compared: 0)
    bestX = 0
    bestY = 0
  for candidate in bot.percep.patchCandidates:
    let score = bot.scoreCamera(candidate.cameraX, candidate.cameraY,
                                FullFrameFitMaxErrors)
    if score.errors < bestScore.errors or
        (score.errors == bestScore.errors and
        score.compared > bestScore.compared):
      bestScore = score
      bestX = candidate.cameraX
      bestY = candidate.cameraY
  bot.clearPatchVotes()
  if not acceptCameraScore(bestScore, FullFrameFitMaxErrors):
    return false
  bot.setCameraLock(bestX, bestY, bestScore, FrameMapLock)
  true

proc locateNearFrame(bot: var Bot): bool =
  ## Cheap incremental refit within `LocalFrameSearchRadius` of the
  ## previous lock. Used as the common-case path between frames.
  if not bot.percep.localized:
    return false
  var
    bestScore = CameraScore(score: low(int), errors: high(int), compared: 0)
    bestX = bot.percep.cameraX
    bestY = bot.percep.cameraY
  let
    minX = max(minCameraX(), bot.percep.cameraX - LocalFrameSearchRadius)
    maxX = min(maxCameraX(), bot.percep.cameraX + LocalFrameSearchRadius)
    minY = max(minCameraY(), bot.percep.cameraY - LocalFrameSearchRadius)
    maxY = min(maxCameraY(), bot.percep.cameraY + LocalFrameSearchRadius)
  for y in minY .. maxY:
    for x in minX .. maxX:
      let score = bot.scoreCamera(x, y, LocalFrameFitMaxErrors)
      if score.errors < bestScore.errors or
          (score.errors == bestScore.errors and
          score.compared > bestScore.compared):
        bestScore = score
        bestX = x
        bestY = y
        if bestScore.errors == 0 and
            bestScore.compared >= FrameFitMinCompared:
          break
    if bestScore.errors == 0 and bestScore.compared >= FrameFitMinCompared:
      break
  if not acceptCameraScore(bestScore, LocalFrameFitMaxErrors):
    return false
  bot.setCameraLock(bestX, bestY, bestScore, LocalFrameMapLock)
  true

proc locateByFrame(bot: var Bot): bool =
  ## Full localizer: try patches first, then fall back to a spiral
  ## search around the last good camera (or the button if we never
  ## had one). Updates perf timers as it goes.
  let patchStart = getMonoTime()
  if bot.locateByPatches():
    bot.perf.localizePatchMicros = int((getMonoTime() - patchStart).inMicroseconds)
    bot.perf.localizeSpiralMicros = 0
    return true
  bot.perf.localizePatchMicros = int((getMonoTime() - patchStart).inMicroseconds)
  let spiralStart = getMonoTime()
  var
    bestScore = CameraScore(score: low(int), errors: high(int), compared: 0)
    bestX =
      if bot.percep.gameStarted:
        bot.percep.cameraX
      else:
        bot.sim.buttonCameraX()
    bestY =
      if bot.percep.gameStarted:
        bot.percep.cameraY
      else:
        bot.sim.buttonCameraY()
  let
    minX = minCameraX()
    maxX = maxCameraX()
    minY = minCameraY()
    maxY = maxCameraY()
    seedX = clamp(bestX, minX, maxX)
    seedY = clamp(bestY, minY, maxY)
    maxRadius = max(
      max(abs(seedX - minX), abs(seedX - maxX)),
      max(abs(seedY - minY), abs(seedY - maxY))
    )
  bestX = seedX
  bestY = seedY

  template tryCamera(x, y: int): bool =
    if x < minX or x > maxX or y < minY or y > maxY:
      false
    elif not cameraCanHoldPlayer(x, y):
      false
    else:
      let score = bot.scoreCamera(x, y, FullFrameFitMaxErrors)
      if score.errors < bestScore.errors or
          (score.errors == bestScore.errors and
          score.compared > bestScore.compared):
        bestScore = score
        bestX = x
        bestY = y
        bestScore.errors == 0 and
          bestScore.compared >= FrameFitMinCompared
      else:
        false

  var done = tryCamera(seedX, seedY)
  for radius in 1 .. maxRadius:
    if done:
      break
    for dx in -radius .. radius:
      if tryCamera(seedX + dx, seedY - radius):
        done = true
        break
      if tryCamera(seedX + dx, seedY + radius):
        done = true
        break
    if done:
      break
    for dy in -radius + 1 .. radius - 1:
      if tryCamera(seedX - radius, seedY + dy):
        done = true
        break
      if tryCamera(seedX + radius, seedY + dy):
        done = true
        break
  if not acceptCameraScore(bestScore, FullFrameFitMaxErrors):
    bot.percep.cameraLock = NoLock
    bot.percep.cameraScore = bestScore.score
    bot.percep.localized = false
    bot.perf.localizeSpiralMicros =
      int((getMonoTime() - spiralStart).inMicroseconds)
    return false
  bot.setCameraLock(bestX, bestY, bestScore, FrameMapLock)
  bot.perf.localizeSpiralMicros =
    int((getMonoTime() - spiralStart).inMicroseconds)
  true

# ---------------------------------------------------------------------------
# Interstitial detection
# ---------------------------------------------------------------------------

proc isInterstitialScreen*(bot: Bot): bool =
  ## True when ≥30% of the frame is the SpaceColor (black). Beats v2's
  ## old four-corners check for robustness against UI bleed.
  var black = 0
  for color in bot.io.unpacked:
    if color == SpaceColor:
      inc black
  black * 100 >= bot.io.unpacked.len * InterstitialBlackPercent

# ---------------------------------------------------------------------------
# Per-frame entry point
# ---------------------------------------------------------------------------

proc updateLocation*(bot: var Bot) =
  ## Localizes the camera against the current frame. Caller must have
  ## already determined the frame is NOT an interstitial — that
  ## decision lives in the orchestrator.
  ##
  ## Strategy: try the cheap local refit first, fall back to the
  ## spiral / patch global search only if the local refit fails.
  ## Verbatim port of v2's non-interstitial path through
  ## `updateLocation` (v2:1337-1355) minus the inlined sprite scans
  ## (Q2 resolved — those run in the orchestrator now, ahead of this
  ## proc, against the prev-frame camera).
  bot.perf.localizeLocalMicros = 0
  bot.perf.localizePatchMicros = 0
  bot.perf.localizeSpiralMicros = 0
  bot.percep.lastCameraX = bot.percep.cameraX
  bot.percep.lastCameraY = bot.percep.cameraY
  let localStart = getMonoTime()
  if bot.locateNearFrame():
    bot.perf.localizeLocalMicros =
      int((getMonoTime() - localStart).inMicroseconds)
    return
  bot.perf.localizeLocalMicros =
    int((getMonoTime() - localStart).inMicroseconds)
  discard bot.locateByFrame()

# ---------------------------------------------------------------------------
# Visible-map memoization
# ---------------------------------------------------------------------------

proc rememberVisibleMap*(bot: var Bot) =
  ## Copies visible walk and wall knowledge into the coarse map model.
  ## Used by the debug viewer to draw what the bot has seen so far.
  if not bot.percep.localized:
    return
  for sy in 0 ..< ScreenHeight:
    for sx in 0 ..< ScreenWidth:
      let
        mx = bot.percep.cameraX + sx
        my = bot.percep.cameraY + sy
      if not inMap(mx, my):
        continue
      let idx = mapIndexSafe(mx, my)
      if bot.sim.wallMask[idx]:
        bot.percep.mapTiles[idx] = TileWall
      elif bot.sim.walkMask[idx]:
        bot.percep.mapTiles[idx] = TileOpen

# ---------------------------------------------------------------------------
# Reseed helper
# ---------------------------------------------------------------------------

proc reseedCameraAtHome*(bot: var Bot) =
  ## Resets just the camera fields to a known-good seed (home if we
  ## have one, otherwise the button). The full per-sub-record
  ## post-interstitial reseed lives in `bot.nim`'s
  ## `reseedAfterInterstitial` and composes this with motion / goal /
  ## task-hold clears.
  if bot.percep.homeSet:
    bot.percep.cameraX = cameraXForWorld(bot.percep.homeX)
    bot.percep.cameraY = cameraYForWorld(bot.percep.homeY)
  else:
    bot.percep.cameraX = bot.sim.buttonCameraX()
    bot.percep.cameraY = bot.sim.buttonCameraY()
  bot.percep.lastCameraX = bot.percep.cameraX
  bot.percep.lastCameraY = bot.percep.cameraY
  bot.percep.cameraLock = NoLock
  bot.percep.cameraScore = 0
  bot.percep.localized = false

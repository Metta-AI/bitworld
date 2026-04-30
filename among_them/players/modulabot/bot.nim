## Bot composition, construction, and the per-frame orchestrator.
##
## Phase 1 wired: `decideNextMask` runs the full per-frame pipeline
## from DESIGN.md §5 against the ported leaf modules. Strategy parity
## with evidencebot_v2 is the bar — verbatim port modulo the
## architectural changes documented in DESIGN.md (Q2 perception
## ordering, Q6 RNG splits, Q8 explicit paths).

import std/[monotimes, os, random, times]
import pixie
import protocol
import ../../sim
import ../../../common/server

import types
import tuning
import frame
import geometry
import ascii
import localize
import actors
import motion
import voting
import tasks
import evidence
import policy_crew
import policy_imp
import diag

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

proc moduleSourcePath*(): string {.compileTime.} =
  ## Returns this file's source path at compile time. Used by callers to
  ## derive default `gameRoot`/`atlasPath` without a setCurrentDir side
  ## effect (Q8 resolved).
  currentSourcePath()

const
  # `currentSourcePath()` is `.../among_them/players/modulabot/bot.nim`.
  # Two parentDir() walks up reach `.../among_them/players/`, three reach
  # `.../among_them/`, four reach `.../bitworld/`.
  ThisFile = currentSourcePath()
  DefaultGameRoot* = ThisFile.parentDir().parentDir().parentDir()
  DefaultBitworldRoot* = DefaultGameRoot.parentDir()
  DefaultAtlasPath* = DefaultBitworldRoot / "clients" / "dist" / "atlas.png"

proc defaultPaths*(mapPath = ""): Paths =
  ## Builds a `Paths` record using the compile-time defaults. `mapPath`
  ## passed empty leaves it empty (so `sim` uses its own DefaultMapPath
  ## resolution). Pass an absolute path or a path that resolves relative
  ## to `gameRoot`.
  Paths(
    gameRoot: DefaultGameRoot,
    atlasPath: DefaultAtlasPath,
    mapPath: mapPath
  )

# ---------------------------------------------------------------------------
# Sub-record initializers
# ---------------------------------------------------------------------------
#
# These follow the convention from DESIGN.md §3: each sub-record gets a
# small `init<Name>` proc that returns a properly-sentinel'd instance. The
# Nim default-zero rules don't give us `-1` sentinels for "no goal" /
# "unknown colour" / "no followee", so explicit initializers are required.

proc initRngStreams*(masterSeed: int64): RngStreams =
  ## Q6 resolved: derive each consumer's substream from a master seed via a
  ## deterministic decorrelation step (xor with a per-stream constant
  ## drawn from the SplitMix64 family of magic numbers). Adding a new
  ## consumer means adding a field plus a fresh per-stream constant; do
  ## not reuse constants between fields.
  result.imposterChat = initRand(masterSeed xor 0x9e3779b97f4a7c15'i64)
  result.imposterTask = initRand(masterSeed xor 0xbf58476d1ce4e5b9'i64)
  result.imposterFollow = initRand(masterSeed xor 0x94d049bb133111eb'i64)
  result.voteTie = initRand(masterSeed xor 0x2545f4914f6cdd1d'i64)

proc initIdentity*(): Identity =
  result.selfColor = -1
  # `knownImposters` and `lastSeen` zero-initialize correctly.

proc initEvidence*(): Evidence =
  for i in 0 ..< PlayerColorCount:
    result.prevCrewmateX[i] = -1
    result.prevCrewmateY[i] = -1
  result.prevBodies = @[]

proc initImposterState*(): ImposterState =
  result.goalIndex = -1
  result.followeeColor = -1
  result.fakeTaskIndex = -1
  result.prevNearTaskIndex = -1
  # `centralRoomTicks` and `forceLeaveUntilTick` are zero-initialized.
  # Tick-stamp sentinels at 0 are fine — `frameTick` starts at 0 too, and
  # a check like `tick - lastKillTick < threshold` uses signed arithmetic.

proc initVotingState*(): VotingState =
  result.cursor = VoteUnknown
  result.selfSlot = VoteUnknown
  result.target = VoteUnknown
  result.startTick = -1
  result.chatSusColor = VoteUnknown
  for i in 0 ..< MaxPlayers:
    result.slots[i].colorIndex = VoteUnknown
    result.slots[i].alive = false
  for i in 0 ..< PlayerColorCount:
    result.choices[i] = VoteUnknown

proc initChatState*(): ChatState =
  result.lastBodySeenX = low(int)
  result.lastBodySeenY = low(int)
  result.lastBodyReportX = low(int)
  result.lastBodyReportY = low(int)

proc initTasks*(taskCount: int): Tasks =
  result.radar = newSeq[bool](taskCount)
  result.checkout = newSeq[bool](taskCount)
  result.states = newSeq[TaskState](taskCount)
  result.iconMisses = newSeq[int](taskCount)
  result.resolved = newSeq[bool](taskCount)
  result.holdIndex = -1

proc initGoal*(): Goal =
  result.index = -1

proc initPerception*(taskCount: int): Perception =
  result.cameraLock = NoLock
  result.mapTiles = newSeq[TileKnowledge](MapWidth * MapHeight)
  # Patch tables are sized and populated by `localize` in phase 1; phase 0
  # leaves them empty.

proc initFrameIO*(): FrameIO =
  result.packed = newSeq[uint8](ProtocolBytes)
  result.unpacked = newSeq[uint8](ScreenWidth * ScreenHeight)

# ---------------------------------------------------------------------------
# Sprite slicing
# ---------------------------------------------------------------------------

proc sheetSprite(sheet: Image, cellX, cellY: int): Sprite =
  ## Extracts one SpriteSize×SpriteSize sprite from the sheet. Mirrors
  ## v2's helper of the same name.
  spriteFromImage(
    sheet.subImage(cellX * SpriteSize, cellY * SpriteSize, SpriteSize, SpriteSize)
  )

proc loadSprites*(): Sprites =
  ## Loads all six reference sprites from the static sheet. The cell
  ## indices match v2:3982-3987.
  let sheet = loadSpriteSheet()
  result.player = sheet.sheetSprite(0, 0)
  result.body = sheet.sheetSprite(1, 0)
  result.killButton = sheet.sheetSprite(3, 0)
  result.task = sheet.sheetSprite(4, 0)
  result.ghost = sheet.sheetSprite(6, 0)
  result.ghostIcon = sheet.sheetSprite(7, 0)

# ---------------------------------------------------------------------------
# initBot
# ---------------------------------------------------------------------------

proc initBot*(paths: Paths = defaultPaths(), masterSeed: int64 = 0): Bot =
  ## Builds a fresh bot. `paths` controls where map / atlas data is read
  ## from; `masterSeed = 0` means "derive from clock and pid", anything
  ## non-zero is used verbatim (useful for reproducible parity tests).
  ##
  ## Q8 resolved: no setCurrentDir. Sim's own path resolution
  ## (`resolveMapPath`, `spriteSheetPath`) falls back to `gameDir()` —
  ## itself derived from `currentSourcePath()` — so dropping the cwd
  ## change is safe.
  result.paths = paths

  var config = defaultGameConfig()
  if paths.mapPath.len > 0:
    config.mapPath = paths.mapPath
  result.sim = initSimServer(config)

  result.sprites = loadSprites()

  let seed =
    if masterSeed != 0: masterSeed
    else: getTime().toUnix() xor int64(getCurrentProcessId())
  result.rngs = initRngStreams(seed)

  let taskCount = result.sim.tasks.len
  result.io = initFrameIO()
  result.percep = initPerception(taskCount)
  result.motion = Motion()
  result.tasks = initTasks(taskCount)
  result.goal = initGoal()
  result.identity = initIdentity()
  result.evidence = initEvidence()
  result.imposter = initImposterState()
  result.voting = initVotingState()
  result.chat = initChatState()
  result.diag = Diag(intent: "waiting for first frame")
  result.perf = Perf()

  result.role = RoleCrewmate

  # Patch-hash table: built once. The orchestrator consumes it every
  # frame; doing this in the leaf module's owning init proc would
  # require it to know about the Bot envelope, so we call from here.
  result.buildPatchEntries()
  result.percep.cameraX = result.sim.buttonCameraX()
  result.percep.cameraY = result.sim.buttonCameraY()
  result.percep.lastCameraX = result.percep.cameraX
  result.percep.lastCameraY = result.percep.cameraY

# ---------------------------------------------------------------------------
# Per-frame pipeline (inert in phase 0; phase 1 fills in the leaf calls).
# ---------------------------------------------------------------------------

proc snapshotPrevFrame*(p: var Perception) =
  ## Records the current camera as the previous-frame anchor for next
  ## frame's pre-localize sprite scan. See DESIGN.md §5.
  if p.localized:
    p.prev.valid = true
    p.prev.cameraX = p.cameraX
    p.prev.cameraY = p.cameraY
  else:
    p.prev.valid = false

# ---------------------------------------------------------------------------
# Round / interstitial lifecycle helpers (cross-record; live here)
# ---------------------------------------------------------------------------

proc resetRoundState*(bot: var Bot) =
  ## Per-round reset triggered by a CREW WINS / IMPS WIN screen. Touches
  ## most sub-records, so it lives in the orchestrator module rather
  ## than any single sub-record's owner. Verbatim port of v2:1061-1098
  ## modulo sub-record renames.
  bot.percep.localized = false
  bot.percep.gameStarted = false
  bot.percep.homeSet = false
  bot.percep.homeX = 0
  bot.percep.homeY = 0
  bot.role = RoleCrewmate
  bot.isGhost = false
  bot.ghostIconFrames = 0
  bot.imposter.killReady = false
  bot.imposter.goalIndex = -1
  bot.imposter.followeeColor = -1
  bot.imposter.followeeSinceTick = 0
  bot.imposter.fakeTaskIndex = -1
  bot.imposter.fakeTaskUntilTick = 0
  bot.imposter.fakeTaskCooldownTick = 0
  bot.imposter.prevNearTaskIndex = -1
  bot.imposter.lastKillTick = 0
  bot.imposter.lastKillX = 0
  bot.imposter.lastKillY = 0
  bot.imposter.centralRoomTicks = 0
  bot.imposter.forceLeaveUntilTick = 0
  bot.percep.cameraLock = NoLock
  bot.percep.cameraScore = 0
  bot.motion.haveMotionSample = false
  bot.motion.velocityX = 0
  bot.motion.velocityY = 0
  bot.motion.stuckFrames = 0
  bot.motion.jiggleTicks = 0
  bot.motion.jiggleSide = 0
  bot.motion.desiredMask = 0
  bot.motion.controllerMask = 0
  bot.tasks.holdTicks = 0
  bot.tasks.holdIndex = -1
  bot.chat.pendingChat = ""
  bot.chat.lastBodySeenX = low(int)
  bot.chat.lastBodySeenY = low(int)
  bot.chat.lastBodyReportX = low(int)
  bot.chat.lastBodyReportY = low(int)
  bot.identity.selfColor = -1
  bot.clearVotingState()
  for i in 0 ..< bot.identity.lastSeen.len:
    bot.identity.lastSeen[i] = 0
  for i in 0 ..< bot.identity.knownImposters.len:
    bot.identity.knownImposters[i] = false
  for i in 0 ..< PlayerColorCount:
    bot.evidence.nearBodyTicks[i] = 0
    bot.evidence.witnessedKillTicks[i] = 0
    bot.evidence.prevCrewmateX[i] = -1
    bot.evidence.prevCrewmateY[i] = -1
  bot.evidence.prevBodies.setLen(0)
  bot.goal.index = -1
  bot.goal.name = ""
  bot.goal.has = false
  bot.goal.hasPathStep = false
  bot.goal.path.setLen(0)
  bot.percep.radarDots.setLen(0)
  bot.percep.visibleTaskIcons.setLen(0)
  bot.percep.visibleCrewmates.setLen(0)
  bot.percep.visibleBodies.setLen(0)
  bot.percep.visibleGhosts.setLen(0)
  if bot.tasks.radar.len != bot.sim.tasks.len:
    bot.tasks.radar = newSeq[bool](bot.sim.tasks.len)
  else:
    for i in 0 ..< bot.tasks.radar.len:
      bot.tasks.radar[i] = false
  if bot.tasks.checkout.len != bot.sim.tasks.len:
    bot.tasks.checkout = newSeq[bool](bot.sim.tasks.len)
  else:
    for i in 0 ..< bot.tasks.checkout.len:
      bot.tasks.checkout[i] = false
  if bot.tasks.states.len != bot.sim.tasks.len:
    bot.tasks.states = newSeq[TaskState](bot.sim.tasks.len)
  else:
    for i in 0 ..< bot.tasks.states.len:
      bot.tasks.states[i] = TaskNotDoing
  if bot.tasks.iconMisses.len != bot.sim.tasks.len:
    bot.tasks.iconMisses = newSeq[int](bot.sim.tasks.len)
  else:
    for i in 0 ..< bot.tasks.iconMisses.len:
      bot.tasks.iconMisses[i] = 0
  if bot.tasks.resolved.len != bot.sim.tasks.len:
    bot.tasks.resolved = newSeq[bool](bot.sim.tasks.len)
  else:
    for i in 0 ..< bot.tasks.resolved.len:
      bot.tasks.resolved[i] = false

proc reseedAfterInterstitial*(bot: var Bot) =
  ## Called when leaving an interstitial (transition from
  ## `bot.percep.interstitial = true` last frame to `false` this
  ## frame). Reseeds the camera at home and clears the per-sub-record
  ## state that v2's `reseedLocalizationAtHome` clears (motion, goal,
  ## task hold). The actual camera reseed is delegated to
  ## `localize.reseedCameraAtHome`.
  bot.reseedCameraAtHome()
  bot.motion.haveMotionSample = false
  bot.motion.velocityX = 0
  bot.motion.velocityY = 0
  bot.motion.stuckFrames = 0
  bot.motion.jiggleTicks = 0
  bot.motion.jiggleSide = 0
  bot.motion.desiredMask = 0
  bot.motion.controllerMask = 0
  bot.tasks.holdTicks = 0
  bot.tasks.holdIndex = -1
  bot.goal.index = -1
  bot.goal.name = ""
  bot.goal.has = false
  bot.goal.hasPathStep = false
  bot.goal.path.setLen(0)

# ---------------------------------------------------------------------------
# Per-frame pipeline
# ---------------------------------------------------------------------------

proc decideNextMask*(bot: var Bot): uint8 =
  ## Master per-frame orchestrator. Implements the pipeline from
  ## DESIGN.md §5. Strategy parity with v2:3922-4032.
  ##
  ## Every code path through this proc must set `bot.diag.branchId`
  ## via `bot.fired(...)` before returning; downstream tracing work
  ## relies on this invariant.
  let centerStart = getMonoTime()
  let wasInterstitial = bot.percep.interstitial
  bot.diag.branchId = ""

  # 1. Cheap interstitial gate. Lives in `localize` because it scans
  # the unpacked frame for black-pixel ratio.
  bot.percep.interstitial = bot.isInterstitialScreen()
  if bot.percep.interstitial:
    bot.percep.interstitialText = bot.detectInterstitialText()
    bot.percep.visibleTaskIcons.setLen(0)
    bot.percep.visibleCrewmates.setLen(0)
    bot.percep.visibleBodies.setLen(0)
    bot.percep.visibleGhosts.setLen(0)
    if bot.percep.interstitialText.isGameOverText() and
        bot.percep.lastGameOverText != bot.percep.interstitialText:
      bot.resetRoundState()
      bot.percep.lastGameOverText = bot.percep.interstitialText
    elif not bot.parseVotingScreen():
      bot.rememberRoleReveal()
    bot.perf.centerMicros = int((getMonoTime() - centerStart).inMicroseconds)
    bot.perf.astarMicros = 0
    bot.motion.updateMotionState(bot.percep, bot.io.lastMask)
    bot.goal.has = false
    bot.goal.hasPathStep = false
    bot.goal.path.setLen(0)
    if bot.voting.active:
      let mask = bot.decideVotingMask()
      bot.percep.snapshotPrevFrame()
      return mask
    bot.motion.desiredMask = 0
    bot.motion.controllerMask = 0
    let intent =
      if bot.percep.interstitialText.len > 0:
        "interstitial: " & bot.percep.interstitialText
      else:
        "interstitial screen mode"
    if bot.percep.interstitialText.isGameOverText():
      bot.fired("bot.interstitial.game_over", intent)
    else:
      bot.fired("bot.interstitial.role_reveal", intent)
    bot.thought(bot.diag.intent)
    bot.percep.snapshotPrevFrame()
    return 0

  bot.percep.interstitialText = ""
  bot.percep.lastGameOverText = ""
  if bot.voting.active:
    bot.clearVotingState()
  if wasInterstitial:
    bot.reseedAfterInterstitial()

  # 2. First-pass actor sprite scans. Q2 option (c): use the
  # previous-frame camera if available so dynamic-pixel ignore masks
  # are populated before localization.
  let preLockCameraX = bot.percep.cameraX
  let preLockCameraY = bot.percep.cameraY
  let spriteStart = getMonoTime()
  bot.scanAll()
  bot.perf.spriteScanMicros = int((getMonoTime() - spriteStart).inMicroseconds)

  # 3. Localize. Cheap local refit first, falls back to patch + spiral.
  bot.updateLocation()

  # 4. If camera jumped beyond the teleport threshold, sprite scans
  # were against a stale camera; re-scan.
  if bot.percep.localized and (
      abs(bot.percep.cameraX - preLockCameraX) > TeleportThresholdPx or
      abs(bot.percep.cameraY - preLockCameraY) > TeleportThresholdPx):
    bot.scanAll()

  bot.perf.centerMicros = int((getMonoTime() - centerStart).inMicroseconds)
  bot.perf.astarMicros = 0

  # 5. Motion + map memory + task state.
  bot.motion.updateMotionState(bot.percep, bot.io.lastMask)
  bot.rememberVisibleMap()
  bot.updateTaskGuesses()
  bot.updateTaskIcons()

  bot.goal.has = false
  bot.goal.hasPathStep = false
  bot.goal.path.setLen(0)
  bot.motion.desiredMask = 0
  bot.motion.controllerMask = 0
  bot.fired("bot.localizing", "localizing")
  if not bot.percep.localized:
    bot.fired("bot.not_localized", "waiting for a reliable map lock")
    bot.thought("waiting for a reliable map lock")
    bot.percep.snapshotPrevFrame()
    return 0

  # 6. Evidence + home memory then policy dispatch.
  bot.updateEvidence()
  bot.rememberHome()

  let mask =
    if bot.role == RoleImposter and not bot.isGhost:
      bot.decideImposterMask()
    else:
      bot.decideCrewmateMask()

  # 7. End-of-frame snapshot for next frame's first-pass scan.
  bot.percep.snapshotPrevFrame()
  mask

# ---------------------------------------------------------------------------
# Public step entry points (called by both the websocket runner and the
# FFI batch shim).
# ---------------------------------------------------------------------------

proc stepUnpackedFrame*(bot: var Bot, frame: openArray[uint8]): uint8 =
  ## Steps a bot one frame given an already-unpacked palette-index buffer.
  let frameLen = ScreenWidth * ScreenHeight
  if frame.len != frameLen:
    return bot.io.lastMask
  if bot.io.unpacked.len != frameLen:
    bot.io.unpacked.setLen(frameLen)
  for i in 0 ..< frameLen:
    bot.io.unpacked[i] = frame[i] and 0x0f
  inc bot.frameTick
  result = bot.decideNextMask()
  bot.io.lastMask = result

proc stepPackedFrame*(bot: var Bot, frame: openArray[uint8]): uint8 =
  ## Steps a bot one frame given a packed 4-bit framebuffer.
  if frame.len != ProtocolBytes:
    return bot.io.lastMask
  if bot.io.packed.len != frame.len:
    bot.io.packed.setLen(frame.len)
  for i, value in frame:
    bot.io.packed[i] = value
  unpack4bpp(bot.io.packed, bot.io.unpacked)
  inc bot.frameTick
  result = bot.decideNextMask()
  bot.io.lastMask = result

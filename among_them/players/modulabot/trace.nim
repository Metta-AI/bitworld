## Structured trace generation for the outer-loop self-improvement
## harness. See TRACING.md for the full design.
##
## Phase 1 scope (this file): manifest + events + decisions, with
## branch-transition detection and the edge-triggered events the bot
## already detects in its existing state. Snapshots and per-line chat
## capture come in Phase 2.
##
## Determinism contract: this module reads `Bot` state only after
## `decideNextMask` has returned; it never mutates `Bot` (other than
## installing/clearing a `TraceWriter` reference at lifecycle
## boundaries, which is a separate proc). It makes no RNG calls. All
## I/O is wrapped in `try/except: discard` — trace failures must never
## crash the bot.

import std/[json, os, strutils, tables, times]

import ../../sim
import types
import diag
import geometry
import evidence
import motion
import voting
import tuning_snapshot

const
  SchemaVersion = 2
    ## v2 bump (DESIGN.md §13.6): trace writer consumes the new
    ## `Memory` event log as single source of truth for body
    ## discoveries. Existing event shapes are unchanged; v1 readers
    ## can consume v2 traces without modification.
  StuckFrameThresholdLocal = StuckFrameThreshold
    ## Local alias to avoid pulling motion's full namespace; this is
    ## the value `motion.updateMotionState` uses to begin a jiggle.
  EventsFileName = "events.jsonl"
  DecisionsFileName = "decisions.jsonl"
  SnapshotsFileName = "snapshots.jsonl"
  ManifestFileName = "manifest.json"
  PartialManifestSentinelKey = "ended_reason"

proc nowMs(): int64 =
  ## Wall-clock milliseconds since unix epoch. Captured at every emit
  ## site for `wall_ms` (round-relative) and at lifecycle edges for
  ## `started_unix_ms` / `ended_unix_ms`.
  int64(epochTime() * 1000.0)

proc safeFsName(s: string): string =
  ## Strips characters that aren't safe in path segments on common
  ## filesystems (notably Windows). Used for sessionId / botName.
  result = newStringOfCap(s.len)
  for ch in s:
    case ch
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.':
      result.add(ch)
    else:
      result.add('-')

proc deriveSessionId(): string =
  ## ISO8601-ish UTC timestamp + PID. Colons replaced with hyphens for
  ## Windows path safety (TRACING.md §14.10).
  let ts = utc(now())
  result = ts.format("yyyy-MM-dd'T'HH-mm-ss'Z'") & "-" & $getCurrentProcessId()

proc roundDirFor(t: TraceWriter, roundId: int): string =
  ## Per-round directory: <root>/<bot>/<session>/<round>.
  t.rootDir / safeFsName(t.botName) / t.sessionId / "round-" &
    intToStr(roundId, 4)

# ---------------------------------------------------------------------------
# JSON line emission helpers
# ---------------------------------------------------------------------------

proc writeJsonLine(file: File, node: JsonNode) =
  ## Single-line JSON serialisation + flush. Wrapped at every call
  ## site in try/except so I/O errors never crash the bot.
  if file.isNil:
    return
  try:
    file.write($node)
    file.write('\n')
    file.flushFile()
  except IOError, OSError:
    discard

proc emitEvent(t: TraceWriter, tick: int, kind: string,
               extra: JsonNode = nil) =
  ## Writes one line to events.jsonl. `extra` may be a JObject whose
  ## fields will be merged into the emitted record, or nil for
  ## payload-less events.
  if t.isNil or t.level == tlOff or not t.roundOpen:
    return
  let line = %*{
    "tick":     tick,
    "wall_ms":  nowMs() - t.roundStartedUnixMs,
    "type":     kind
  }
  if extra != nil and extra.kind == JObject:
    for k, v in extra.pairs:
      line[k] = v
  writeJsonLine(t.eventsFile, line)
  inc t.counters.eventsEmitted

proc emitDecision(t: TraceWriter, bot: Bot, mask: uint8,
                  prevBranch: string, prevDuration: int) =
  ## Writes one line to decisions.jsonl on a branch transition.
  if t.isNil or t.level in {tlOff, tlEvents} or not t.roundOpen:
    return
  let goalNode =
    if bot.goal.has:
      let g = %*{
        "name":       bot.goal.name,
        "index":      bot.goal.index,
        "world_pos":  [bot.goal.x, bot.goal.y]
      }
      if bot.goal.path.len > 0:
        g["path_len"] = %bot.goal.path.len
      g
    else:
      newJNull()
  let line = %*{
    "tick":      bot.frameTick,
    "wall_ms":   nowMs() - t.roundStartedUnixMs,
    "branch_id": bot.diag.branchId,
    "intent":    bot.diag.intent,
    "thought":   bot.diag.lastThought,
    "from":      (if prevBranch.len == 0: newJNull()
                  else: %prevBranch),
    "duration_ticks_in_prev_branch": prevDuration,
    "mask":      movementName(mask),
    "self": {
      "world_pos":   [bot.percep.playerWorldX(), bot.percep.playerWorldY()],
      "room":        bot.percep.roomName(bot.sim),
      "camera_lock": bot.percep.cameraLock.cameraLockName(),
      "localized":   bot.percep.localized
    },
    "goal": goalNode
  }
  writeJsonLine(t.decisionsFile, line)

# ---------------------------------------------------------------------------
# Body diff helpers
# ---------------------------------------------------------------------------
#
# Prior to v2, the trace writer kept its own `prevBodyWorldPositions`
# shadow and diffed the visible-body list frame-to-frame. That state
# is redundant with `Memory.bodies`, which already captures the
# round-lifetime set of distinct bodies with deterministic dedup.
# The writer now observes `memory.bodies.len` growth instead; this is
# the §13.6 single-source-of-truth refactor.

# ---------------------------------------------------------------------------
# Manifest write
# ---------------------------------------------------------------------------

proc countersToJson(c: ManifestCounters): JsonNode =
  %*{
    "ticks_total":         c.ticksTotal,
    "ticks_localized":     c.ticksLocalized,
    "frames_dropped":      c.framesDropped,
    "meetings_attended":   c.meetingsAttended,
    "votes_cast":          c.votesCast,
    "skips_voted":         c.skipsVoted,
    "kills_executed":      c.killsExecuted,
    "kills_witnessed":     c.killsWitnessed,
    "bodies_seen_first":   c.bodiesSeenFirst,
    "bodies_reported":     c.bodiesReported,
    "tasks_completed":     c.tasksCompleted,
    "chats_sent":          c.chatsSent,
    "chats_observed":      c.chatsObserved,
    "stuck_episodes":      c.stuckEpisodes,
    "branch_transitions":  c.branchTransitions,
    "events_emitted":      c.eventsEmitted,
    "snapshots_emitted":   c.snapshotsEmitted
  }

proc roleString(role: BotRole): string =
  case role
  of RoleUnknown: "unknown"
  of RoleCrewmate: "crew"
  of RoleImposter: "imposter"

proc resolveResult(text: string): string =
  ## Maps a final game-over title into a normalised result string.
  let upper = text.toUpperAscii()
  if upper.contains("CREW"): "crew_wins"
  elif upper.contains("IMP"): "imps_win"
  elif text.len == 0: "unknown"
  else: "unknown"

proc knownImposterNames(bot: Bot): JsonNode =
  result = newJArray()
  for i, known in bot.identity.knownImposters:
    if known:
      result.add(%playerColorName(i))

proc writeManifest(t: TraceWriter, bot: Bot, ended: bool,
                   endedReason: string, finalGameOverText: string) =
  ## Writes manifest.json. Called once at round start (with
  ## `ended=false`) and rewritten at round end.
  if t.isNil or t.roundDir.len == 0:
    return
  let path = t.roundDir / ManifestFileName
  let selfColor = bot.identity.selfColor
  let selfNode = %*{
    "name":             t.botName,
    "color_index":      selfColor,
    "color_name":       (if selfColor >= 0 and selfColor < PlayerColorNames.len:
                           %playerColorName(selfColor)
                         else: newJNull()),
    "role":             roleString(bot.role),
    "ended_as_ghost":   bot.isGhost,
    "known_imposters":  knownImposterNames(bot)
  }
  var harness = newJObject()
  if t.harnessMeta.len > 0:
    try:
      let parsed = parseJson(t.harnessMeta)
      if parsed.kind == JObject:
        harness = parsed
    except JsonParsingError, ValueError:
      harness = %*{"raw": t.harnessMeta}
  let traceSettings = %*{
    "level":                  ($t.level)[2 .. ^1].toLowerAscii(),
    "snapshot_period_ticks":  t.snapshotPeriod,
    "speaker_attribution":    "color_pip",
    "frames_dump_captured":   t.captureFrames
  }
  var configNode: JsonNode = newJObject()
  if t.config.len > 0:
    try:
      configNode = parseJson(t.config)
      if configNode.kind != JObject:
        configNode = %*{"raw": t.config}
    except JsonParsingError, ValueError:
      configNode = %*{"raw": t.config}
  configNode["master_seed"] = %t.masterSeed
  configNode["frames_dump_path"] =
    if t.framesPath.len > 0: %t.framesPath else: newJNull()
  var tuningNode: JsonNode = newJObject()
  if t.tuningSnapshot.len > 0:
    try:
      tuningNode = parseJson(t.tuningSnapshot)
    except JsonParsingError, ValueError:
      tuningNode = newJObject()
  let manifest = %*{
    "schema_version":     SchemaVersion,
    "session_id":         t.sessionId,
    "round_id":           t.roundId,
    "bot_name":           t.botName,
    "bot_version": {
      "git_sha":          (if harness.hasKey("git_sha"): harness["git_sha"]
                           else: newJNull()),
      "build_flags":      newJArray()
    },
    "started_unix_ms":    t.roundStartedUnixMs,
    "ended_unix_ms":      (if ended: %nowMs() else: newJNull()),
    "ended_reason":       (if ended: %endedReason else: newJNull()),
    "result":             (if ended: %resolveResult(finalGameOverText)
                           else: newJNull()),
    "started_mid_round":  t.startedMidRound,
    "self":               selfNode,
    "config":             configNode,
    "tuning_snapshot":    tuningNode,
    "trace_settings":     traceSettings,
    "summary_counters":   countersToJson(t.counters),
    "harness_meta":       harness
  }
  try:
    createDir(t.roundDir)
    let f = open(path, fmWrite)
    defer: f.close()
    f.write(manifest.pretty(2))
    f.write('\n')
  except IOError, OSError:
    discard

# ---------------------------------------------------------------------------
# Round lifecycle
# ---------------------------------------------------------------------------

proc closeRoundFiles(t: TraceWriter) =
  for f in [addr t.eventsFile, addr t.decisionsFile,
            addr t.snapshotsFile, addr t.framesFile]:
    if not f[].isNil:
      try: f[].close()
      except IOError, OSError: discard
      f[] = nil

proc resetCounters(t: TraceWriter) =
  t.counters = ManifestCounters()

proc resetShadow(t: TraceWriter, bot: Bot) =
  t.prevBranchId = ""
  t.prevBranchEnterTick = bot.frameTick
  t.prevLocalized = bot.percep.localized
  t.prevCameraLock = bot.percep.cameraLock
  t.prevSelfColor = bot.identity.selfColor
  t.prevRole = bot.role
  t.prevIsGhost = bot.isGhost
  t.prevKillReady = bot.imposter.killReady
  t.prevInterstitial = bot.percep.interstitial
  t.prevInterstitialText = bot.percep.interstitialText
  t.prevGameOverText = bot.percep.lastGameOverText
  t.prevTaskStates = bot.tasks.states
  t.prevTaskResolved = bot.tasks.resolved
  t.prevSelfVoteChoice = VoteUnknown
  for i in 0 ..< t.prevVoteChoices.len:
    t.prevVoteChoices[i] = VoteUnknown
  t.prevStuckActive = false
  t.prevStuckStartTick = 0
  t.prevBodiesCount = bot.memory.bodies.len
  t.meetingActive = false
  t.meetingIndex = 0
  t.meetingStartTick = 0
  t.meetingVoteCast = false
  t.lastSnapshotTick = bot.frameTick
  t.warnedEmptyBranchId = false

proc beginRound*(t: TraceWriter, bot: var Bot, isMidRound: bool) =
  ## Opens a fresh round directory and writes a preliminary manifest.
  ## Called on session open (first frame) and after every detected
  ## game-over edge.
  if t.isNil or t.level == tlOff:
    return
  t.roundId = t.nextRoundId
  inc t.nextRoundId
  t.roundDir = roundDirFor(t, t.roundId)
  t.roundStartedUnixMs = nowMs()
  t.roundStartTick = bot.frameTick
  t.startedMidRound = isMidRound
  resetCounters(t)
  resetShadow(t, bot)
  try:
    createDir(t.roundDir)
    t.eventsFile = open(t.roundDir / EventsFileName, fmAppend)
    if t.level in {tlDecisions, tlFull}:
      t.decisionsFile = open(t.roundDir / DecisionsFileName, fmAppend)
    if t.snapshotPeriod > 0:
      t.snapshotsFile = open(t.roundDir / SnapshotsFileName, fmAppend)
  except IOError, OSError:
    closeRoundFiles(t)
    t.roundOpen = false
    return
  t.roundOpen = true
  writeManifest(t, bot, ended = false, endedReason = "",
                finalGameOverText = "")
  emitEvent(t, bot.frameTick, "round_start",
            (if isMidRound: %*{"started_mid_round": true} else: nil))

proc endRound*(t: TraceWriter, bot: var Bot, reason: string,
               gameOverText: string) =
  ## Closes the current round: emits any final events, writes the
  ## final manifest, and closes file handles. Idempotent.
  if t.isNil or not t.roundOpen:
    return
  if reason == "game_over_text" and gameOverText.len > 0:
    emitEvent(t, bot.frameTick, "game_over",
              %*{
                "title":  gameOverText,
                "result": resolveResult(gameOverText)
              })
  writeManifest(t, bot, ended = true, endedReason = reason,
                finalGameOverText = gameOverText)
  closeRoundFiles(t)
  t.roundOpen = false

# ---------------------------------------------------------------------------
# Public open / close
# ---------------------------------------------------------------------------

proc openTrace*(rootDir, botName: string, level: TraceLevel,
                snapshotPeriod: int, captureFrames: bool,
                harnessMeta: string, masterSeed: int64,
                framesPath: string,
                configJson: string): TraceWriter =
  ## Constructs a new trace writer. Does NOT open a round directory —
  ## call `beginRound` once the bot is ready (after `initBot`). Returns
  ## a writer with `level = tlOff` if root directory creation fails.
  result = TraceWriter(
    rootDir:        rootDir,
    botName:        if botName.len > 0: botName else: "modulabot",
    sessionId:      deriveSessionId(),
    level:          level,
    snapshotPeriod: snapshotPeriod,
    captureFrames:  captureFrames,
    harnessMeta:    harnessMeta,
    bootedUnixMs:   nowMs(),
    nextRoundId:    0,
    masterSeed:     masterSeed,
    framesPath:     framesPath,
    config:         configJson,
    tuningSnapshot: $tuningSnapshot()
  )
  try:
    createDir(result.rootDir / safeFsName(result.botName) / result.sessionId)
  except IOError, OSError:
    result.level = tlOff

proc closeTrace*(t: TraceWriter, bot: var Bot, reason: string) =
  ## Final flush at process exit. Closes any open round.
  if t.isNil:
    return
  if t.roundOpen:
    endRound(t, bot, reason, bot.percep.lastGameOverText)

# ---------------------------------------------------------------------------
# Per-frame trace hook
# ---------------------------------------------------------------------------

proc detectAndEmitEvents(t: TraceWriter, bot: var Bot) =
  let tick = bot.frameTick

  # Localization edges
  if bot.percep.localized != t.prevLocalized:
    if bot.percep.localized:
      emitEvent(t, tick, "localized", %*{
        "lock":     bot.percep.cameraLock.cameraLockName(),
        "camera":   [bot.percep.cameraX, bot.percep.cameraY],
        "score":    bot.percep.cameraScore
      })
    else:
      emitEvent(t, tick, "lost_localization", %*{
        "prior_lock": t.prevCameraLock.cameraLockName()
      })
    t.prevLocalized = bot.percep.localized
  t.prevCameraLock = bot.percep.cameraLock

  # Self-color
  if bot.identity.selfColor != t.prevSelfColor:
    if bot.identity.selfColor >= 0 and t.prevSelfColor < 0:
      emitEvent(t, tick, "self_color_known", %*{
        "color": playerColorName(bot.identity.selfColor),
        "index": bot.identity.selfColor
      })
    elif bot.identity.selfColor >= 0 and t.prevSelfColor >= 0:
      emitEvent(t, tick, "self_color_changed", %*{
        "color": playerColorName(bot.identity.selfColor),
        "index": bot.identity.selfColor,
        "prev_color": playerColorName(t.prevSelfColor),
        "prev_index": t.prevSelfColor
      })
    t.prevSelfColor = bot.identity.selfColor

  # Role
  if bot.role != t.prevRole:
    if t.prevRole == RoleUnknown and bot.role != RoleUnknown:
      let via =
        if bot.imposter.killReady: "kill_button_lit"
        elif bot.role == RoleImposter: "kill_button_dim"
        else: "default"
      emitEvent(t, tick, "role_known", %*{
        "role": roleString(bot.role),
        "via":  via
      })
    t.prevRole = bot.role

  # Ghost transition
  if bot.isGhost != t.prevIsGhost:
    if bot.isGhost:
      emitEvent(t, tick, "became_ghost", nil)
    t.prevIsGhost = bot.isGhost

  # Kill cooldown transitions (imposter only)
  if bot.role == RoleImposter and bot.imposter.killReady != t.prevKillReady:
    if bot.imposter.killReady:
      emitEvent(t, tick, "kill_cooldown_ready", nil)
    else:
      emitEvent(t, tick, "kill_cooldown_used", nil)
    t.prevKillReady = bot.imposter.killReady

  # Task state changes
  let n = min(bot.tasks.states.len, t.prevTaskStates.len)
  for i in 0 ..< n:
    if bot.tasks.states[i] != t.prevTaskStates[i]:
      var taskName = "task-" & $i
      if i < bot.sim.tasks.len:
        taskName = bot.sim.tasks[i].name
      emitEvent(t, tick, "task_state_change", %*{
        "index": i,
        "name":  taskName,
        "from":  $t.prevTaskStates[i],
        "to":    $bot.tasks.states[i]
      })
      if bot.tasks.states[i] == TaskCompleted and
          t.prevTaskStates[i] != TaskCompleted:
        emitEvent(t, tick, "task_completed", %*{
          "index": i,
          "name":  taskName
        })
        inc t.counters.tasksCompleted
  if t.prevTaskStates.len != bot.tasks.states.len:
    t.prevTaskStates = bot.tasks.states
  else:
    for i in 0 ..< n:
      t.prevTaskStates[i] = bot.tasks.states[i]

  # Task "resolved-not-mine" latch
  let m = min(bot.tasks.resolved.len, t.prevTaskResolved.len)
  for i in 0 ..< m:
    if bot.tasks.resolved[i] and not t.prevTaskResolved[i]:
      var taskName = "task-" & $i
      if i < bot.sim.tasks.len:
        taskName = bot.sim.tasks[i].name
      # Only emit if the task wasn't actually completed by us.
      if bot.tasks.states[i] != TaskCompleted:
        emitEvent(t, tick, "task_resolved_not_mine", %*{
          "index": i,
          "name":  taskName
        })
  if t.prevTaskResolved.len != bot.tasks.resolved.len:
    t.prevTaskResolved = bot.tasks.resolved
  else:
    for i in 0 ..< m:
      t.prevTaskResolved[i] = bot.tasks.resolved[i]

  # Body diff: replaced v1's per-frame position-shadow with a
  # simple length-growth check against memory.bodies. memory owns
  # dedup (MemoryBodyDedupPx), so each new entry is guaranteed to
  # be a distinct body worth emitting once. Witness translation
  # runs off the BodyEvent payload that memory already recorded.
  if bot.memory.bodies.len > t.prevBodiesCount:
    for i in t.prevBodiesCount ..< bot.memory.bodies.len:
      let bev = bot.memory.bodies[i]
      var witnesses = newJArray()
      for w in bev.witnesses:
        witnesses.add(%playerColorName(w.colorIndex))
      let recentKill =
        bot.role == RoleImposter and
        bot.imposter.lastKillTick > 0 and
        bev.tick - bot.imposter.lastKillTick <= 60
      emitEvent(t, bev.tick, "body_seen_first", %*{
        "world_pos":          [bev.x, bev.y],
        "room":               bot.sim.roomNameAt(bev.x, bev.y),
        "witnesses_nearby":   witnesses,
        "self_recent_kill":   recentKill,
        "is_new_body":        bev.isNewBody
      })
      inc t.counters.bodiesSeenFirst
      # Tier-2 kill_witnessed: one event per witness on a new-body
      # discovery, matching v1's behaviour. Persistent / first-seen
      # dead bodies (where isNewBody=false) do not emit kill_witnessed.
      if bev.isNewBody:
        for w in bev.witnesses:
          emitEvent(t, bev.tick, "kill_witnessed", %*{
            "suspect":          playerColorName(w.colorIndex),
            "body_world_pos":   [bev.x, bev.y],
            "room":             bot.sim.roomNameAt(bev.x, bev.y)
          })
          inc t.counters.killsWitnessed
    t.prevBodiesCount = bot.memory.bodies.len

  # Kill executed (imposter): edge on imposter.lastKillTick
  if bot.role == RoleImposter and
      bot.imposter.lastKillTick == tick and bot.imposter.lastKillTick > 0:
    var targetColor = newJNull()
    # Best-effort target lookup: scan visible crewmates near the
    # last-kill position; if exactly one matches, attribute it.
    var bestColor = -1
    var bestDist = high(int)
    for cm in bot.percep.visibleCrewmates:
      let world = bot.percep.visibleCrewmateWorld(cm)
      let
        dx = world.x - bot.imposter.lastKillX
        dy = world.y - bot.imposter.lastKillY
        d2 = dx * dx + dy * dy
      if d2 < bestDist:
        bestDist = d2
        bestColor = cm.colorIndex
    if bestColor >= 0:
      targetColor = %playerColorName(bestColor)
    emitEvent(t, tick, "kill_executed", %*{
      "target_color":  targetColor,
      "world_pos":     [bot.imposter.lastKillX, bot.imposter.lastKillY],
      "room":          bot.sim.roomNameAt(bot.imposter.lastKillX,
                                          bot.imposter.lastKillY)
    })
    inc t.counters.killsExecuted

  # Body reported (own): branchId is one of the report branches, mask
  # has ButtonA, and bot.chat.pendingChat got populated this frame
  # with a "body in" message.
  let isReportBranch =
    bot.diag.branchId == "policy_crew.body.report_in_range" or
    bot.diag.branchId == "policy_imp.body.self_report"
  if isReportBranch:
    emitEvent(t, tick, "body_reported", nil)
    inc t.counters.bodiesReported

  # Stuck detection
  let stuckActive = bot.motion.stuckFrames >= StuckFrameThresholdLocal or
                    bot.motion.jiggleTicks > 0
  if stuckActive and not t.prevStuckActive:
    emitEvent(t, tick, "stuck_detected", %*{
      "world_pos":    [bot.percep.playerWorldX(), bot.percep.playerWorldY()],
      "goal":         (if bot.goal.has: %bot.goal.name else: newJNull())
    })
    t.prevStuckStartTick = tick
    inc t.counters.stuckEpisodes
  elif not stuckActive and t.prevStuckActive:
    emitEvent(t, tick, "stuck_resolved", %*{
      "ticks_jiggling": tick - t.prevStuckStartTick
    })
  t.prevStuckActive = stuckActive

  # Interstitial transitions
  if bot.percep.interstitial != t.prevInterstitial:
    if bot.percep.interstitial:
      # Entering interstitial. If it parses as a voting screen, this
      # is a meeting start.
      if bot.voting.active:
        inc t.meetingIndex
        t.meetingActive = true
        t.meetingStartTick = tick
        t.meetingVoteCast = false
        t.meetingSelfQueuedNormalized = ""
        t.meetingSeenChat.setLen(0)
        emitEvent(t, tick, "meeting_started", %*{
          "meeting_index":            t.meetingIndex,
          "ticks_since_round_start":  tick - t.roundStartTick,
          "interstitial_text":        bot.percep.interstitialText
        })
        inc t.counters.meetingsAttended
    else:
      # Leaving interstitial.
      if t.meetingActive:
        emitEvent(t, tick, "meeting_ended", %*{
          "meeting_index":   t.meetingIndex,
          "duration_ticks":  tick - t.meetingStartTick
        })
        t.meetingActive = false
        # Clear shadow vote choices for next meeting
        for i in 0 ..< t.prevVoteChoices.len:
          t.prevVoteChoices[i] = VoteUnknown
        t.prevSelfVoteChoice = VoteUnknown
    t.prevInterstitial = bot.percep.interstitial
  t.prevInterstitialText = bot.percep.interstitialText

  # Role-revealed: detect on interstitial title CREWMATE / IMPS
  if bot.percep.interstitial:
    let title = bot.percep.interstitialText
    let upperTitle = title.toUpperAscii()
    if (upperTitle == "CREWMATE" or upperTitle == "IMPS") and
        title != t.prevInterstitialText:
      emitEvent(t, tick, "role_revealed", %*{
        "title":     title,
        "teammates": knownImposterNames(bot)
      })

  # Chat-observed: every new OCR'd line during this meeting.
  if bot.voting.active and t.meetingActive:
    for line in bot.voting.chatLines:
      let norm = normalizeChatText(line.text)
      if norm.len == 0:
        continue
      if norm in t.meetingSeenChat:
        continue
      t.meetingSeenChat.add(norm)
      var qPlaceholder = 0
      for ch in line.text:
        if ch == '?': inc qPlaceholder
      let quality = if qPlaceholder == 0: "clean" else: "noisy"
      let isSelf = t.meetingSelfQueuedNormalized.len > 0 and
                   norm == t.meetingSelfQueuedNormalized
      let speakerNode =
        if line.speakerColor >= 0 and line.speakerColor < PlayerColorCount:
          %playerColorName(line.speakerColor)
        else:
          newJNull()
      emitEvent(t, tick, "chat_observed", %*{
        "meeting_index":      t.meetingIndex,
        "line":               line.text,
        "first_seen_tick":    tick,
        "ocr_quality":        quality,
        "speaker":            speakerNode,
        "matches_self_chat":  isSelf
      })
      inc t.counters.chatsObserved

  # Vote tracking — only meaningful while voting screen is active
  if bot.voting.active and t.meetingActive:
    # Per-color votes
    for ci in 0 ..< bot.voting.choices.len:
      if bot.voting.choices[ci] != t.prevVoteChoices[ci] and
          bot.voting.choices[ci] != VoteUnknown:
        var targetName = "unknown"
        if bot.voting.choices[ci] == VoteSkip or
            bot.voting.choices[ci] == bot.voting.playerCount:
          targetName = "skip"
        elif bot.voting.choices[ci] >= 0 and
            bot.voting.choices[ci] < bot.voting.slots.len and
            bot.voting.slots[bot.voting.choices[ci]].colorIndex >= 0:
          let tc = bot.voting.slots[bot.voting.choices[ci]].colorIndex
          targetName = playerColorName(tc)
        emitEvent(t, tick, "vote_observed", %*{
          "voter":  playerColorName(ci),
          "target": targetName
        })
        t.prevVoteChoices[ci] = bot.voting.choices[ci]

    # Self vote cast
    let selfChoice = selfVoteChoice(bot)
    if selfChoice != VoteUnknown and t.prevSelfVoteChoice == VoteUnknown and
        not t.meetingVoteCast:
      var targetName = "skip"
      if selfChoice >= 0 and selfChoice < bot.voting.slots.len and
          bot.voting.slots[selfChoice].colorIndex >= 0:
        targetName = playerColorName(bot.voting.slots[selfChoice].colorIndex)
      let rationale =
        if bot.role == RoleImposter and bot.voting.chatSusColor >= 0:
          "chat_sus_color"
        elif bot.role == RoleImposter:
          "most_recent_suspect"
        elif targetName == "skip":
          "no_evidence"
        else:
          "evidence_based"
      emitEvent(t, tick, "vote_cast", %*{
        "target":                       targetName,
        "ticks_after_meeting_start":    tick - t.meetingStartTick,
        "rationale":                    rationale
      })
      inc t.counters.votesCast
      if targetName == "skip":
        inc t.counters.skipsVoted
      t.meetingVoteCast = true
      t.prevSelfVoteChoice = selfChoice

  # Frames-dropped accumulator
  t.counters.framesDropped = bot.io.skippedFrames
  if bot.percep.localized:
    inc t.counters.ticksLocalized

proc taskStateName(state: TaskState): string =
  case state
  of TaskNotDoing: "not_doing"
  of TaskMaybe: "maybe"
  of TaskMandatory: "mandatory"
  of TaskCompleted: "completed"

proc evidenceTopJson(bot: Bot, limit: int): JsonNode =
  ## Returns the top suspects by recency: most-recent witnessedKill
  ## first, then most-recent nearBody. Skips self and known imposter
  ## teammates.
  result = newJArray()
  type SuspectEntry = tuple[colorIndex, witTick, nearTick: int]
  var entries: seq[SuspectEntry] = @[]
  for ci in 0 ..< PlayerColorCount:
    if ci == bot.identity.selfColor: continue
    if bot.knownImposterColor(ci): continue
    let
      witT = bot.evidence.witnessedKillTicks[ci]
      nearT = bot.evidence.nearBodyTicks[ci]
    if witT == 0 and nearT == 0: continue
    entries.add((ci, witT, nearT))
  # Simple sort: witnessed-kill recency desc, then near-body recency desc.
  for i in 0 ..< entries.len:
    for j in i + 1 ..< entries.len:
      let a = entries[i]
      let b = entries[j]
      let aKey = (a.witTick, a.nearTick)
      let bKey = (b.witTick, b.nearTick)
      if bKey > aKey:
        entries[i] = b
        entries[j] = a
  let take = min(entries.len, limit)
  for i in 0 ..< take:
    let e = entries[i]
    let now = bot.frameTick
    result.add(%*{
      "color": playerColorName(e.colorIndex),
      "witnessed_kill_age_ticks":
        (if e.witTick > 0: %(now - e.witTick) else: newJNull()),
      "near_body_age_ticks":
        (if e.nearTick > 0: %(now - e.nearTick) else: newJNull())
    })

proc taskModelSummaryJson(bot: Bot): JsonNode =
  var counts = initTable[string, int]()
  counts["not_doing"] = 0
  counts["maybe"] = 0
  counts["mandatory"] = 0
  counts["completed"] = 0
  for s in bot.tasks.states:
    case s
    of TaskNotDoing: inc counts["not_doing"]
    of TaskMaybe: inc counts["maybe"]
    of TaskMandatory: inc counts["mandatory"]
    of TaskCompleted: inc counts["completed"]
  var resolvedCount = 0
  for r in bot.tasks.resolved:
    if r: inc resolvedCount
  result = %*{
    "completed":         counts["completed"],
    "mandatory":         counts["mandatory"],
    "maybe":             counts["maybe"],
    "not_doing":         counts["not_doing"],
    "resolved_not_mine": resolvedCount
  }

proc visibleListJson(bot: Bot): JsonNode =
  var crewmates = newJArray()
  for cm in bot.percep.visibleCrewmates:
    let world = bot.percep.visibleCrewmateWorld(cm)
    crewmates.add(%*{
      "color":     (if cm.colorIndex >= 0:
                      %playerColorName(cm.colorIndex)
                    else:
                      newJNull()),
      "world_pos": [world.x, world.y]
    })
  var bodies = newJArray()
  for b in bot.percep.visibleBodies:
    let world = bot.percep.visibleBodyWorld(b)
    bodies.add(%*{"world_pos": [world.x, world.y]})
  var ghosts = newJArray()
  for g in bot.percep.visibleGhosts:
    ghosts.add(%*{"world_pos": [
      bot.percep.cameraX + g.x, bot.percep.cameraY + g.y]})
  result = %*{
    "crewmates": crewmates,
    "bodies":    bodies,
    "ghosts":    ghosts
  }

proc imposterStateJson(bot: Bot): JsonNode =
  if bot.role != RoleImposter:
    return newJNull()
  result = %*{
    "followee_color":
      (if bot.imposter.followeeColor >= 0:
        %playerColorName(bot.imposter.followeeColor)
      else:
        newJNull()),
    "followee_since_tick":  bot.imposter.followeeSinceTick,
    "fake_task_index":
      (if bot.imposter.fakeTaskIndex >= 0:
        %bot.imposter.fakeTaskIndex
      else:
        newJNull()),
    "central_room_ticks":   bot.imposter.centralRoomTicks,
    "force_leave_until":    bot.imposter.forceLeaveUntilTick,
    "last_kill_tick":       bot.imposter.lastKillTick,
    "kill_ready":           bot.imposter.killReady
  }

proc votingStateJson(bot: Bot): JsonNode =
  if not bot.voting.active:
    return newJNull()
  result = %*{
    "player_count":   bot.voting.playerCount,
    "self_slot":      bot.voting.selfSlot,
    "cursor":         bot.voting.cursor,
    "target":         bot.voting.target,
    "chat_sus_color":
      (if bot.voting.chatSusColor >= 0:
        %playerColorName(bot.voting.chatSusColor)
      else:
        newJNull()),
    "start_tick":     bot.voting.startTick
  }

proc emitSnapshot(t: TraceWriter, bot: Bot) =
  ## Emits one belief-state snapshot to snapshots.jsonl.
  if t.isNil or t.snapshotsFile.isNil or t.level == tlOff or
      not t.roundOpen:
    return
  let line = %*{
    "tick":     bot.frameTick,
    "wall_ms":  nowMs() - t.roundStartedUnixMs,
    "self": {
      "role":             roleString(bot.role),
      "is_ghost":         bot.isGhost,
      "color":
        (if bot.identity.selfColor >= 0:
          %playerColorName(bot.identity.selfColor)
        else:
          newJNull()),
      "world_pos":        [bot.percep.playerWorldX(),
                           bot.percep.playerWorldY()],
      "room":             bot.percep.roomName(bot.sim),
      "kill_ready":       bot.imposter.killReady,
      "task_hold_ticks":  bot.tasks.holdTicks,
      "localized":        bot.percep.localized,
      "camera_lock":      bot.percep.cameraLock.cameraLockName(),
      "camera_score":     bot.percep.cameraScore
    },
    "visible":             visibleListJson(bot),
    "evidence_top":        evidenceTopJson(bot, 5),
    "task_model_summary":  taskModelSummaryJson(bot),
    "imposter_state":      imposterStateJson(bot),
    "voting":              votingStateJson(bot),
    "stuck_frames":        bot.motion.stuckFrames,
    "frames_dropped_total": bot.io.skippedFrames
  }
  writeJsonLine(t.snapshotsFile, line)
  inc t.counters.snapshotsEmitted
  t.lastSnapshotTick = bot.frameTick

proc emitChatSent*(t: TraceWriter, bot: var Bot, text: string) =
  ## Public entry called by the runner immediately after a pending
  ## chat message hits the wire. Distinct from the `chat_observed`
  ## events emitted by the per-frame OCR diff (Phase 2). Also stamps
  ## the normalized form into `meetingSelfQueuedNormalized` so that
  ## subsequent chat_observed events can flag `matches_self_chat`.
  if t.isNil or t.level == tlOff or not t.roundOpen:
    return
  emitEvent(t, bot.frameTick, "chat_sent", %*{
    "text":           text,
    "queued_at_tick": bot.frameTick   # best-effort; queueing is per-frame
  })
  inc t.counters.chatsSent
  t.meetingSelfQueuedNormalized = normalizeChatText(text)

proc warnEmptyBranchOnce(t: TraceWriter, tick: int) =
  ## One-shot warning if branchId is empty after decideNextMask
  ## returns. See TRACING.md §8.4.
  if t.warnedEmptyBranchId:
    return
  t.warnedEmptyBranchId = true
  emitEvent(t, tick, "trace_warning", %*{
    "kind":     "empty_branch_id",
    "message":  "decideNextMask returned without calling bot.fired(...). " &
                "Branch coverage gap; please update TRACING.md §8.2."
  })

proc traceFrame*(t: TraceWriter, bot: var Bot, mask: uint8) =
  ## Top-level per-frame trace hook. Called from `decideNextMask` after
  ## the policy has run (and branchId has been set). Diff-detects
  ## events, emits decision-transition lines, handles round transitions.
  if t.isNil or t.level == tlOff:
    return
  inc t.counters.ticksTotal

  # Detect game-over edge first; resetRoundState in bot.nim flips
  # lastGameOverText before traceFrame runs, so we use our own shadow
  # to detect the transition.
  if bot.percep.lastGameOverText != t.prevGameOverText:
    if bot.percep.lastGameOverText.len > 0 and t.roundOpen:
      # Round just ended due to game-over text.
      endRound(t, bot, "game_over_text", bot.percep.lastGameOverText)
    t.prevGameOverText = bot.percep.lastGameOverText
    if not t.roundOpen:
      beginRound(t, bot, isMidRound = false)

  if not t.roundOpen:
    return

  try:
    detectAndEmitEvents(t, bot)
  except CatchableError:
    discard

  # Branch transition
  if bot.diag.branchId != t.prevBranchId:
    let prevDuration =
      if t.prevBranchId.len == 0: 0
      else: bot.frameTick - t.prevBranchEnterTick
    emitDecision(t, bot, mask, t.prevBranchId, prevDuration)
    inc t.counters.branchTransitions
    t.prevBranchId = bot.diag.branchId
    t.prevBranchEnterTick = bot.frameTick
  elif t.level == tlFull:
    # In full mode, emit per-frame even when branch unchanged.
    emitDecision(t, bot, mask, t.prevBranchId, 0)

  # One-shot warning if a code path forgot to call bot.fired(...).
  if bot.diag.branchId.len == 0:
    warnEmptyBranchOnce(t, bot.frameTick)

  # Periodic snapshot. Also fires immediately after any
  # `meeting_started` event we just emitted (events first, then
  # snapshots — TRACING.md §14.5).
  if t.snapshotPeriod > 0 and not t.snapshotsFile.isNil:
    let dueByPeriod =
      bot.frameTick - t.lastSnapshotTick >= t.snapshotPeriod
    let dueByMeeting =
      t.meetingActive and t.meetingStartTick == bot.frameTick
    if dueByPeriod or dueByMeeting:
      try:
        emitSnapshot(t, bot)
      except CatchableError:
        discard

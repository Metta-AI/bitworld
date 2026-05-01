## LLM voting state machine + context assembly.
##
## Implements LLM_VOTING.md §2–§5 (state machines, pipelines, prompt
## architecture) for both roles. **Deviates from §6** (async side-
## channel HTTP in Nim) in favour of Option B from the implementation
## amendment: Nim owns everything except the HTTP call itself. The
## Python wrapper (`cogames/amongthem_policy.py`) polls for a pending
## request via the FFI each frame, performs the provider call through
## `anthropic.AnthropicBedrock` / `anthropic.Anthropic`, and feeds the
## JSON back through another FFI entry point. This avoids SigV4
## signing in Nim and lets us reuse Softmax's existing Bedrock
## credential chain (`AWS_PROFILE`, `AWS_REGION`, or IAM env vars)
## uploaded through `cogames upload --secret-env` (see
## `packages/cogames/POLICY_SECRETS.md`).
##
## All call sites in other modules are gated behind `when defined(modTalksLlm)`
## so the non-LLM build is bit-for-bit identical to modulabot.
## This module itself compiles unconditionally — the gating happens at
## its callers in `bot.nim` and the FFI in `ffi/lib.nim`. Leaving the
## code compiled but unreachable keeps the impl honest (syntactic
## changes in `types.nim` break both builds the same way) and avoids
## scattered `when defined` fragments inside every proc.
##
## Determinism: the LLM layer introduces non-determinism by design
## (remote model). Therefore this module must NOT be called by any
## code path that parity tests rely on; it is entered only when
## `LlmVotingState.enabled == true`, which is flipped only by the
## Python wrapper at load time when the LLM provider client has been
## successfully constructed. The `--mode:llm-mock` parity mode from
## §11 of LLM_VOTING.md is deferred — the FFI hook gives us the same
## deterministic injection point for free once a mock response file
## is wired into the Python side.

import std/[json, sequtils, strutils, tables, times]

import types
import tuning
import voting
import evidence         # PlayerColorNames, playerColorName, evidenceBasedSuspect
import memory           # roomIdAt helper for context JSON
import trace            # emitLlmDispatched / emitLlmDecision / emitLlmError

# Session counters live on `bot.llm`; trace emitters live on
# `bot.trace`. Both are safe to touch even when tracing is off — the
# trace helpers no-op on a nil writer and the counters are plain
# integers. Guarding at call sites would just clutter.

# ---------------------------------------------------------------------------
# Room helpers
# ---------------------------------------------------------------------------

proc roomNameForId(bot: Bot, roomId: int): string =
  ## Resolves a room index to its human-readable name. Used when
  ## serialising memory events to JSON. We pass names (not ids) to the
  ## LLM — the model has no table of "room 7 means storage".
  if roomId < 0 or roomId >= bot.sim.rooms.len:
    return "unknown"
  bot.sim.rooms[roomId].name

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc initLlmVotingState*(): LlmVotingState =
  result.stage = lvsIdle
  result.hypothesis.valid = false
  result.imposterStrategy.valid = false
  result.imposterStrategy.bestTarget = -1
  result.voteTarget = -1
  result.lastReactionTick = low(int)
  result.request.pending = false
  result.request.callKind = lckNone
  result.hasUnreadChat = false
  result.meetingStartTick = -1
  result.enabled = false

proc resetLlmVotingState*(s: var LlmVotingState) =
  ## Clears per-meeting state. `enabled` is preserved — it's a
  ## process-lifetime flag set by the FFI, not a per-round one.
  let wasEnabled = s.enabled
  s = initLlmVotingState()
  s.enabled = wasEnabled

# ---------------------------------------------------------------------------
# Chat history management
# ---------------------------------------------------------------------------

proc normalizeForDedup*(line: string): string =
  ## Aggressive normalization — lowercased, alnum-only, single spaces.
  ## Mirrors `voting.normalizeChatText` but kept local so this module
  ## doesn't re-import every voting helper.
  var hadSpace = true
  for ch in line:
    var outCh = ch
    if ch in {'A'..'Z'}:
      outCh = char(ord(ch) - ord('A') + ord('a'))
    if outCh in {'a'..'z'} or outCh in {'0'..'9'}:
      result.add(outCh)
      hadSpace = false
    elif not hadSpace:
      result.add(' ')
      hadSpace = true
  result = result.strip()

proc ingestChatLines*(bot: var Bot) =
  ## Pulls new lines out of `bot.voting.chatLines`, diffs against the
  ## `seenLines` dedup set, appends true-novelty entries to
  ## `chatHistory`, and flags `hasUnreadChat`.
  ##
  ## Speaker attribution (Sprint 2.1): primary source is the pip
  ## detector in `voting.detectChatSpeaker`, which runs during
  ## `parseVotingScreen` and stamps each `VoteChatLine.speakerColor`.
  ## Fall back to substring-matching our own `myStatements` only when
  ## the pip was unattributed (-1) — once we know a line was spoken
  ## by our own color we can mark it `mine` with confidence and
  ## short-circuit the fuzzy match.
  var s = addr bot.llmVoting
  for entry in bot.voting.chatLines:
    let raw = entry.text
    let norm = normalizeForDedup(raw)
    if norm.len == 0:
      continue
    var seen = false
    for existing in s.seenLines:
      if existing == norm:
        seen = true
        break
    if seen:
      continue
    s.seenLines.add(norm)
    # Attribution: pip detector wins. On a confident self-color pip
    # this skips the fuzzy substring scan. Fuzzy fallback is kept for
    # lines whose pip detection failed (pip area obscured or
    # ambiguous) so we don't regress on multi-line dedup.
    var mine = false
    if entry.speakerColor >= 0 and entry.speakerColor == bot.identity.selfColor:
      mine = true
    elif entry.speakerColor < 0:
      for own in s.myStatements:
        let ownNorm = normalizeForDedup(own)
        if ownNorm.len == 0:
          continue
        if ownNorm == norm or
            (norm.len >= 4 and ownNorm.contains(norm)) or
            (ownNorm.len >= 4 and norm.contains(ownNorm)):
          mine = true
          break
    s.chatHistory.add(LlmChatEntry(
      speakerColor: entry.speakerColor,
      line: raw,
      tickObserved: bot.frameTick,
      mine: mine
    ))
    if not mine:
      s.hasUnreadChat = true

# ---------------------------------------------------------------------------
# Context assembly (JSON)
# ---------------------------------------------------------------------------

proc colorsAlive(bot: Bot): seq[int] =
  for i in 0 ..< bot.voting.playerCount:
    let slot = bot.voting.slots[i]
    if slot.alive and slot.colorIndex >= 0 and
        slot.colorIndex < PlayerColorNames.len:
      result.add(slot.colorIndex)

proc colorNameArray(ids: openArray[int]): JsonNode =
  result = newJArray()
  for c in ids:
    result.add(%playerColorName(c))

proc safeColorsArray(bot: Bot): JsonNode =
  result = newJArray()
  for i in 0 ..< PlayerColorCount:
    if bot.identity.knownImposters[i] and i != bot.identity.selfColor:
      result.add(%playerColorName(i))
  # Include self as safe — we never target ourselves.
  if bot.identity.selfColor >= 0:
    result.add(%playerColorName(bot.identity.selfColor))

proc evidenceScoresJson(bot: Bot): JsonNode =
  result = newJObject()
  let alive = bot.colorsAlive()
  for c in alive:
    if c == bot.identity.selfColor:
      continue
    let summary = bot.memory.summaries[c]
    var entry = newJObject()
    entry["near_body_count"] = %summary.timesNearBody
    entry["witnessed_kill"] = %(summary.timesWitnessedKill > 0)
    entry["last_seen_room"] = %roomNameForId(bot, summary.lastSeenRoomId)
    entry["last_seen_ticks_ago"] =
      if summary.lastSeenTick > 0:
        %(bot.frameTick - summary.lastSeenTick)
      else:
        %(-1)
    entry["task_completions_observed"] = %summary.distinctTasksObserved
    result[playerColorName(c)] = entry

proc roundEventsJson(bot: Bot): JsonNode =
  result = newJObject()
  # Bodies
  var bodies = newJArray()
  for body in bot.memory.bodies:
    var b = newJObject()
    b["room"] = %roomNameForId(bot, body.roomId)
    b["tick_relative"] = %(bot.frameTick - body.tick)
    var wits = newJArray()
    for w in body.witnesses:
      wits.add(%playerColorName(w.colorIndex))
    b["witnesses_near"] = wits
    b["is_new_body"] = %body.isNewBody
    bodies.add(b)
  result["bodies"] = bodies
  # Sightings (since last meeting — memory trims these at meeting close)
  var sightings = newJArray()
  let cap = 40
    ## Cap to bound context size; most-recent first.
  var count = 0
  for i in countdown(bot.memory.sightings.high, 0):
    if count >= cap:
      break
    let s = bot.memory.sightings[i]
    if s.colorIndex == bot.identity.selfColor:
      continue
    var entry = newJObject()
    entry["color"] = %playerColorName(s.colorIndex)
    entry["room"] = %roomNameForId(bot, s.roomId)
    entry["tick_relative"] = %(bot.frameTick - s.tick)
    sightings.add(entry)
    inc count
  result["sightings_since_last_meeting"] = sightings
  # Alibis
  var alibis = newJArray()
  for a in bot.memory.alibis:
    var entry = newJObject()
    entry["color"] = %playerColorName(a.colorIndex)
    entry["task_index"] = %a.taskIndex
    entry["tick_relative"] = %(bot.frameTick - a.tick)
    alibis.add(entry)
  result["alibis"] = alibis

proc priorMeetingsJson(bot: Bot): JsonNode =
  ## Past-meeting summary for the LLM. `ejected` is -1 in v1 (not
  ## detected yet — see DESIGN.md §13.9) so we omit it rather than
  ## lie. `chat_summary` carries raw OCR lines.
  result = newJArray()
  for m in bot.memory.meetings:
    var entry = newJObject()
    if m.ejected >= 0 and m.ejected < PlayerColorNames.len:
      entry["ejected"] = %playerColorName(m.ejected)
    else:
      entry["ejected"] = newJNull()
    # selfVote is a slot index; translate to colour name if possible.
    if m.selfVote == VoteSkip:
      entry["self_vote"] = %"skip"
    elif m.selfVote >= 0 and m.selfVote < bot.voting.playerCount:
      let c = bot.voting.slots[m.selfVote].colorIndex
      entry["self_vote"] =
        if c >= 0 and c < PlayerColorNames.len:
          %playerColorName(c)
        else:
          newJNull()
    else:
      entry["self_vote"] = newJNull()
    var chat = newJArray()
    for line in m.chatLines:
      # Emit speaker attribution now that it's available (Sprint 2.1).
      # Past meetings gain a "<color>: <text>" prefix so the LLM can
      # weigh prior claims by speaker without a schema change to the
      # array shape. Unattributed lines stay bare.
      if line.speakerColor >= 0 and
          line.speakerColor < PlayerColorNames.len:
        chat.add(%(playerColorName(line.speakerColor) & ": " & line.text))
      else:
        chat.add(%line.text)
    entry["chat_summary"] = chat
    result.add(entry)

proc chatLogJson(bot: Bot; recentOnly: bool; limit = 30): JsonNode =
  ## Serializes chat history. `recentOnly = true` returns only entries
  ## observed since the last reaction call (used for the crewmate
  ## `react` task). `recentOnly = false` returns the full log for the
  ## imposter `imposter_react` task (Q-LLM8: imposter must see every
  ## prior claim to avoid contradicting them).
  result = newJArray()
  let sinceTick =
    if recentOnly: bot.llmVoting.lastReactionTick
    else: low(int)
  var taken = 0
  # Walk oldest-to-newest so the LLM reads conversation in order.
  for entry in bot.llmVoting.chatHistory:
    if entry.tickObserved < sinceTick:
      continue
    if taken >= limit:
      break
    var o = newJObject()
    o["speaker"] =
      if entry.speakerColor >= 0 and entry.speakerColor < PlayerColorNames.len:
        %playerColorName(entry.speakerColor)
      else:
        newJNull()
    o["line"] = %entry.line
    o["tick_relative"] = %(bot.frameTick - entry.tickObserved)
    o["mine"] = %entry.mine
    result.add(o)
    inc taken

proc myStatementsJson(bot: Bot): JsonNode =
  result = newJArray()
  for line in bot.llmVoting.myStatements:
    result.add(%line)

proc myLocationHistoryJson(bot: Bot; limit = 20): JsonNode =
  ## Serializes the bot's own room-transition log for imposter LLM
  ## contexts (Sprint 2.2). Emits newest-first, capped at `limit`
  ## entries, tick-relative to the current frame. Empty array when
  ## `Memory.selfKeyframes` hasn't accumulated anything yet.
  result = newJArray()
  let kf = bot.memory.selfKeyframes
  var taken = 0
  for i in countdown(kf.high, 0):
    if taken >= limit:
      break
    let e = kf[i]
    result.add(%*{
      "room":          roomNameForId(bot, e.roomId),
      "tick_relative": bot.frameTick - e.tick
    })
    inc taken

# ---------------------------------------------------------------------------
# Per-task context builders
# ---------------------------------------------------------------------------
#
# Each builder returns a `JsonNode` instead of a serialised string so
# `dispatchCall` can apply the Sprint 3.4 trim policy before the
# context crosses the FFI boundary. The trim helper drops oversized
# fields in priority order — see `trimContextInPlace` below.

proc trimContextInPlace*(ctx: JsonNode, maxBytes: int): bool =
  ## Mutates `ctx` (a JObject) in place by progressively dropping or
  ## shrinking known-large fields until its serialized form fits in
  ## `maxBytes`. Returns true on success, false when even the
  ## fully-trimmed context exceeds the budget.
  ##
  ## Trim order, gentlest → most aggressive (Sprint 3.4):
  ##   1. Halve `round_events.sightings_since_last_meeting` (oldest
  ##      first, since the array is newest-first by emission order).
  ##   2. Halve `chat_since_last_update`.
  ##   3. Halve `full_chat_log` (imposter-only).
  ##   4. Drop `prior_meetings[].chat_summary` arrays (keep meeting
  ##      structure, lose verbatim chat).
  ##   5. Drop `prior_meetings` entirely.
  ##   6. Drop `round_events.sightings_since_last_meeting` entirely.
  ##   7. Drop `evidence_scores` (last resort — strips the headline
  ##      reasoning input).
  ##
  ## Each step re-checks `$ctx`.len; we stop as soon as the budget
  ## clears. The most-recent half of every truncated array is kept
  ## because more-recent observations are more decision-relevant.
  if ctx.kind != JObject:
    return ($ctx).len <= maxBytes
  if ($ctx).len <= maxBytes:
    return true

  proc halveArrayKeepNewest(arr: JsonNode) =
    if arr.isNil or arr.kind != JArray:
      return
    let keep = arr.len div 2
    if keep == 0 and arr.len > 0:
      return
    # Arrays we trim are newest-first (countdown emit order), so we
    # keep the first `keep` entries and drop the older tail.
    while arr.len > keep:
      arr.elems.delete(arr.elems.high)

  template fits: bool = ($ctx).len <= maxBytes

  # 1. Sightings.
  if ctx.hasKey("round_events"):
    let re = ctx["round_events"]
    if re.kind == JObject and re.hasKey("sightings_since_last_meeting"):
      halveArrayKeepNewest(re["sightings_since_last_meeting"])
  if fits: return true

  # 2. Recent chat.
  if ctx.hasKey("chat_since_last_update"):
    halveArrayKeepNewest(ctx["chat_since_last_update"])
  if fits: return true

  # 3. Full chat log (imposter).
  if ctx.hasKey("full_chat_log"):
    halveArrayKeepNewest(ctx["full_chat_log"])
  if fits: return true

  # 4. Prior-meeting chat summaries.
  if ctx.hasKey("prior_meetings") and ctx["prior_meetings"].kind == JArray:
    for m in ctx["prior_meetings"]:
      if m.kind == JObject and m.hasKey("chat_summary"):
        m["chat_summary"] = newJArray()
  if fits: return true

  # 5. Drop prior_meetings entirely.
  if ctx.hasKey("prior_meetings"):
    ctx.delete("prior_meetings")
  if fits: return true

  # 6. Drop sightings entirely.
  if ctx.hasKey("round_events") and ctx["round_events"].kind == JObject:
    let re = ctx["round_events"]
    if re.hasKey("sightings_since_last_meeting"):
      re.delete("sightings_since_last_meeting")
  if fits: return true

  # 7. Drop evidence_scores. Beyond this we have nothing else safe
  # to shed without changing semantics; if still over budget, the
  # caller emits llm_error{reason: "context_overflow"}.
  if ctx.hasKey("evidence_scores"):
    ctx.delete("evidence_scores")
  fits

proc buildHypothesisContext(bot: Bot): JsonNode =
  ## LLM_VOTING.md §3.1 crewmate hypothesis.
  result = newJObject()
  result["task"] = %"hypothesis"
  result["role_hint"] = %"crewmate"
  result["self_color"] = %playerColorName(bot.identity.selfColor)
  result["living_players"] = colorNameArray(bot.colorsAlive())
  result["round_events"] = roundEventsJson(bot)
  result["prior_meetings"] = priorMeetingsJson(bot)
  result["evidence_scores"] = evidenceScoresJson(bot)
  # Schema for constrained output (provider will validate).
  var schema = newJObject()
  schema["suspects"] = %* [{
    "color": "string (must be one of living_players)",
    "likelihood": "float 0..1",
    "reasoning": "one sentence"
  }]
  schema["confidence"] = %"high|medium|low"
  schema["key_evidence"] = %["string", "..."]
  result["response_schema"] = schema

proc buildAccuseContext(bot: Bot): JsonNode =
  ## LLM_VOTING.md §3.2 crewmate accusation chat.
  result = newJObject()
  result["task"] = %"accuse"
  let h = bot.llmVoting.hypothesis
  if h.suspects.len > 0:
    let top = h.suspects[0]
    result["suspect"] = %playerColorName(top.colorIndex)
    result["likelihood"] = %top.likelihood
    result["reasoning"] = %top.reasoning
  result["key_evidence"] = block:
    var arr = newJArray()
    for e in h.keyEvidence:
      arr.add(%e)
    arr
  result["self_color"] = %playerColorName(bot.identity.selfColor)
  result["max_chat_len"] = %LlmMaxChatLen
  var schema = newJObject()
  schema["chat"] = %("string, <= " & $LlmMaxChatLen & " chars, name the suspect")
  result["response_schema"] = schema

proc buildReactContext(bot: Bot): JsonNode =
  ## LLM_VOTING.md §3.3 crewmate react / belief-update.
  result = newJObject()
  result["task"] = %"react"
  result["self_color"] = %playerColorName(bot.identity.selfColor)
  var hyp = newJObject()
  hyp["suspects"] = block:
    var arr = newJArray()
    for s in bot.llmVoting.hypothesis.suspects:
      var o = newJObject()
      o["color"] = %playerColorName(s.colorIndex)
      o["likelihood"] = %s.likelihood
      o["reasoning"] = %s.reasoning
      arr.add(o)
    arr
  hyp["confidence"] = %bot.llmVoting.hypothesis.confidence
  result["current_hypothesis"] = hyp
  result["chat_since_last_update"] = chatLogJson(bot, recentOnly = true)
  result["my_prior_statements"] = myStatementsJson(bot)
  result["living_players"] = colorNameArray(bot.colorsAlive())
  var schema = newJObject()
  schema["suspects"] = %* [{
    "color": "string",
    "likelihood": "float 0..1",
    "reasoning": "one sentence"
  }]
  schema["confidence"] = %"high|medium|low"
  schema["action"] = %"speak|ask|silent"
  schema["chat"] = %("string or null, <= " & $LlmMaxChatLen & " chars")
  result["response_schema"] = schema

proc buildStrategizeContext(bot: Bot): JsonNode =
  ## LLM_VOTING.md §4.1 imposter strategy.
  ## Critical: `safe_colors` comes from `knownImposters` + self. Never
  ## let the model target anyone in that list. The prompt (system
  ## message, §5.3) enforces this; we also reject any response whose
  ## `best_target` is in safe_colors at parse time.
  result = newJObject()
  result["task"] = %"strategize"
  result["safe_colors"] = safeColorsArray(bot)
  result["self_color"] = %playerColorName(bot.identity.selfColor)
  result["living_players"] = colorNameArray(bot.colorsAlive())
  # Self location history from `Memory.selfKeyframes` (Sprint 2.2).
  # Empty until the bot has transitioned between named rooms; the
  # system prompt ("only claim locations you've been to") makes an
  # empty list a safe fallback (LLM stays vague rather than
  # fabricating).
  result["my_location_history"] = myLocationHistoryJson(bot)
  # Bodies this round and their witness colours.
  var bodies = newJArray()
  for body in bot.memory.bodies:
    var b = newJObject()
    b["room"] = %roomNameForId(bot, body.roomId)
    b["tick_relative"] = %(bot.frameTick - body.tick)
    var near = newJArray()
    for w in body.witnesses:
      near.add(%playerColorName(w.colorIndex))
    b["near_players"] = near
    bodies.add(b)
  result["bodies_this_round"] = bodies
  result["evidence_scores"] = evidenceScoresJson(bot)
  result["prior_meetings"] = priorMeetingsJson(bot)
  result["my_prior_statements"] = myStatementsJson(bot)
  var schema = newJObject()
  schema["best_target"] =
    %"string — a living non-safe player to target for ejection"
  schema["strategy"] = %"bandwagon|preemptive|deflect"
  schema["timing"] = %"early|mid|late"
  schema["reasoning"] = %"internal, one sentence"
  schema["initial_chat"] =
    %("string or null, <= " & $LlmMaxChatLen & " chars")
  result["response_schema"] = schema

proc buildImposterReactContext(bot: Bot): JsonNode =
  ## LLM_VOTING.md §4.2. Note the full chat log (Q-LLM8).
  result = newJObject()
  result["task"] = %"imposter_react"
  let strat = bot.llmVoting.imposterStrategy
  result["strategy"] = %strat.strategy
  result["best_target"] =
    if strat.bestTarget >= 0 and strat.bestTarget < PlayerColorNames.len:
      %playerColorName(strat.bestTarget)
    else:
      newJNull()
  result["timing"] = %strat.timing
  result["safe_colors"] = safeColorsArray(bot)
  result["self_color"] = %playerColorName(bot.identity.selfColor)
  result["living_players"] = colorNameArray(bot.colorsAlive())
  result["my_location_history"] = myLocationHistoryJson(bot)
  result["bodies_this_round"] = block:
    var arr = newJArray()
    for body in bot.memory.bodies:
      var b = newJObject()
      b["room"] = %roomNameForId(bot, body.roomId)
      b["tick_relative"] = %(bot.frameTick - body.tick)
      arr.add(b)
    arr
  result["full_chat_log"] = chatLogJson(bot, recentOnly = false, limit = 80)
  result["my_prior_statements"] = myStatementsJson(bot)
  var schema = newJObject()
  schema["action"] = %"corroborate|deflect|accuse|silent"
  schema["chat"] =
    %("string or null, <= " & $LlmMaxChatLen & " chars")
  schema["reasoning"] = %"internal, one sentence"
  result["response_schema"] = schema

proc buildPersuadeContext(bot: Bot): JsonNode =
  result = newJObject()
  result["task"] = %"persuade"
  let h = bot.llmVoting.hypothesis
  if h.suspects.len > 0:
    result["suspect"] = %playerColorName(h.suspects[0].colorIndex)
  result["key_evidence"] = block:
    var arr = newJArray()
    for e in h.keyEvidence:
      arr.add(%e)
    arr
  var schema = newJObject()
  schema["chat"] =
    %("string, <= " & $LlmMaxChatLen & " chars, persuade others to vote")
  result["response_schema"] = schema

# ---------------------------------------------------------------------------
# Request dispatch
# ---------------------------------------------------------------------------

proc dispatchCall(bot: var Bot; kind: LlmCallKind) =
  ## Populates the request slot. Only one call is in flight at a time.
  ## If the previous slot is still pending (Python hasn't dequeued it
  ## yet), do nothing — the previous request wins. This shouldn't
  ## normally happen because the state machine only dispatches after
  ## consuming the previous response.
  ##
  ## Emits an `llm_dispatched` trace event and bumps session
  ## `totalDispatched` / `byKindDispatched` so the harness can pair
  ## each dispatch with its eventual decision or error.
  ##
  ## Sprint 3.4: applies `trimContextInPlace` before serialization,
  ## then re-checks the size budget. If even the trimmed context
  ## exceeds the budget the dispatch is aborted and an `llm_error`
  ## with `reason: "context_overflow"` is emitted; the state
  ## machine falls back to rule-based voting at vote time.
  if bot.llmVoting.request.pending:
    return
  let ctxNode =
    case kind
    of lckHypothesis:     buildHypothesisContext(bot)
    of lckAccuse:         buildAccuseContext(bot)
    of lckReact:          buildReactContext(bot)
    of lckStrategize:     buildStrategizeContext(bot)
    of lckImposterReact:  buildImposterReactContext(bot)
    of lckPersuade:       buildPersuadeContext(bot)
    of lckNone:           nil
  if ctxNode.isNil or ctxNode.kind != JObject:
    return
  # Apply trim policy before serialization. `LlmMaxContextLen` is
  # the soft target the trim policy aims for; `LlmMaxContextBytes`
  # is the hard ceiling that maps to the FFI buffer size on the
  # Python side. Trimming aggressively at the soft target leaves
  # headroom for the Python wrapper's prompt envelope.
  let fits = trimContextInPlace(ctxNode, LlmMaxContextLen)
  let contextJson = $ctxNode
  if not fits or contextJson.len > LlmMaxContextBytes:
    inc bot.llm.counters.totalErrored
    inc bot.llm.counters.byKindErrored[kind]
    if not bot.trace.isNil:
      emitLlmError(bot.trace, bot, kind, bot.llmVoting.stage,
                   "context_overflow",
                   "context " & $contextJson.len & " bytes exceeds " &
                   "LlmMaxContextBytes after trim",
                   bot.frameTick, 0'i64, contextJson)
    # Degrade gracefully: bump fallback counter and let the state
    # machine reach `lvsListening` so vote-time fallback fires.
    inc bot.llm.counters.totalFallbacks
    if bot.llmVoting.stage in {lvsFormingHypothesis, lvsFormingStrategy}:
      bot.llmVoting.stage = lvsListening
    return
  if contextJson.len == 0:
    return
  let wallMs = int64(epochTime() * 1000.0)
  bot.llmVoting.request = LlmRequestSlot(
    pending: true,
    callKind: kind,
    stage: bot.llmVoting.stage,
    contextJson: contextJson,
    contextBytes: contextJson.len,
    dispatchedTick: bot.frameTick,
    dispatchedWallMs: wallMs
  )
  inc bot.llm.counters.totalDispatched
  inc bot.llm.counters.byKindDispatched[kind]
  if not bot.trace.isNil:
    emitLlmDispatched(bot.trace, bot, kind, bot.llmVoting.stage,
                      contextJson.len)

# ---------------------------------------------------------------------------
# Response handling
# ---------------------------------------------------------------------------

proc confidenceFromLikelihood*(l: float32): string =
  if l >= LlmAccuseThreshold: "high"
  elif l >= 0.45'f32: "medium"
  else: "low"

proc colorIndexByName*(name: string): int =
  ## Case-insensitive, whitespace-trimmed match against PlayerColorNames.
  let norm = name.strip().toLowerAscii()
  if norm.len == 0:
    return -1
  for i, candidate in PlayerColorNames:
    if candidate.toLowerAscii() == norm:
      return i
  -1

proc transliterateAscii*(text: string): string =
  ## Maps common non-ASCII Unicode characters to their nearest ASCII
  ## equivalents (Sprint 4.5). The BitWorld chat renderer's PixelFont
  ## only handles printable ASCII (`pixelfonts.glyphIndex` indexes into
  ## a single printable-ASCII range and falls back to `?` for anything
  ## else); LLM-generated chat that uses smart quotes / em-dashes /
  ## ellipses / non-Latin punctuation looked clipped before this proc
  ## existed.
  ##
  ## Strategy: a hand-curated mapping for the high-traffic punctuation
  ## the model emits, plus a passthrough for printable ASCII. Anything
  ## not in either set is dropped (safer than letting it become a `?`
  ## glyph that signals an error to the OCR validator).
  result = newStringOfCap(text.len)
  var i = 0
  while i < text.len:
    let b0 = text[i]
    if ord(b0) < 0x80:
      # Printable ASCII passes through; control chars become spaces
      # (matches the prior behavior of `clampChat`).
      if ord(b0) >= 0x20 and ord(b0) < 0x7F:
        result.add(b0)
      elif b0 == '\n' or b0 == '\t':
        result.add(' ')
      inc i
      continue
    # Multi-byte UTF-8 sequence. Decode minimally then map.
    var codepoint = 0
    var skip = 1
    if (ord(b0) and 0xE0) == 0xC0 and i + 1 < text.len:
      codepoint = ((ord(b0) and 0x1F) shl 6) or
                  (ord(text[i + 1]) and 0x3F)
      skip = 2
    elif (ord(b0) and 0xF0) == 0xE0 and i + 2 < text.len:
      codepoint = ((ord(b0) and 0x0F) shl 12) or
                  ((ord(text[i + 1]) and 0x3F) shl 6) or
                  (ord(text[i + 2]) and 0x3F)
      skip = 3
    elif (ord(b0) and 0xF8) == 0xF0 and i + 3 < text.len:
      codepoint = ((ord(b0) and 0x07) shl 18) or
                  ((ord(text[i + 1]) and 0x3F) shl 12) or
                  ((ord(text[i + 2]) and 0x3F) shl 6) or
                  (ord(text[i + 3]) and 0x3F)
      skip = 4
    else:
      # Invalid lead byte — skip one and resync.
      inc i
      continue
    case codepoint
    # Quote pairs.
    of 0x2018, 0x2019, 0x201A, 0x201B, 0x2032: result.add('\'')
    of 0x201C, 0x201D, 0x201E, 0x201F, 0x2033: result.add('"')
    # Dashes.
    of 0x2013, 0x2014, 0x2015, 0x2212: result.add('-')
    # Ellipsis.
    of 0x2026:
      result.add('.')
      result.add('.')
      result.add('.')
    # Various spaces → single space.
    of 0x00A0, 0x2002, 0x2003, 0x2009, 0x200A: result.add(' ')
    # Bullet variants.
    of 0x2022, 0x2023, 0x25E6: result.add('*')
    # Currency we might see in chat.
    of 0x20AC: result.add('E')           ## € → E (best-effort)
    of 0x00A3: result.add('L')           ## £ → L
    of 0x00A5: result.add('Y')           ## ¥ → Y
    # Anything else: drop. Better than emitting a sentinel that the
    # OCR validator treats as a question mark.
    else: discard
    inc i, skip

proc clampChat*(text: string): string =
  ## Trim to `LlmMaxChatLen` at a word boundary when possible.
  ## Transliterates non-ASCII via `transliterateAscii` before
  ## counting characters (Sprint 4.5).
  let cleaned = transliterateAscii(text).strip()
  if cleaned.len <= LlmMaxChatLen:
    return cleaned
  var cut = cleaned[0 ..< LlmMaxChatLen]
  let sp = cut.rfind(' ')
  if sp >= LlmMaxChatLen div 2:
    cut = cut[0 ..< sp]
  cut.strip()

proc isSafeColor*(bot: Bot; colorIndex: int): bool =
  if colorIndex < 0 or colorIndex >= PlayerColorCount:
    return true
  if colorIndex == bot.identity.selfColor:
    return true
  bot.identity.knownImposters[colorIndex]

proc parseSuspects*(node: JsonNode): seq[LlmSuspect] =
  if node.isNil or node.kind != JArray:
    return
  for item in node:
    if item.kind != JObject:
      continue
    var s: LlmSuspect
    s.colorIndex = -1
    if item.hasKey("color") and item["color"].kind == JString:
      s.colorIndex = colorIndexByName(item["color"].getStr())
    if item.hasKey("likelihood"):
      let n = item["likelihood"]
      if n.kind == JFloat:
        s.likelihood = n.getFloat().float32
      elif n.kind == JInt:
        s.likelihood = n.getInt().float32
    if item.hasKey("reasoning") and item["reasoning"].kind == JString:
      s.reasoning = item["reasoning"].getStr()
    if s.colorIndex >= 0:
      result.add(s)
  # Sort by likelihood desc (stable).
  var changed = true
  while changed:
    changed = false
    for i in 0 ..< result.len - 1:
      if result[i].likelihood < result[i + 1].likelihood:
        swap(result[i], result[i + 1])
        changed = true

proc queueOurChat(bot: var Bot; text: string) =
  ## Routes LLM-generated chat through the existing `pendingChat`
  ## mechanism. Respects LLM_VOTING.md §8 constraint: do not overwrite
  ## a message that hasn't been sent yet.
  if text.len == 0:
    return
  if bot.chat.pendingChat.len > 0:
    # Already queued; don't clobber. Track the statement anyway so
    # the LLM doesn't regenerate it on the next react tick.
    return
  bot.chat.pendingChat = text
  bot.llmVoting.myStatements.add(text)

proc applyHypothesisResponse(bot: var Bot; data: JsonNode) =
  var h: LlmHypothesis
  h.suspects = parseSuspects(data.getOrDefault("suspects"))
  if data.hasKey("confidence") and data["confidence"].kind == JString:
    h.confidence = data["confidence"].getStr().toLowerAscii()
  if data.hasKey("key_evidence") and data["key_evidence"].kind == JArray:
    for item in data["key_evidence"]:
      if item.kind == JString:
        h.keyEvidence.add(item.getStr())
  # If confidence missing, derive from top likelihood.
  if h.confidence.len == 0 and h.suspects.len > 0:
    h.confidence = confidenceFromLikelihood(h.suspects[0].likelihood)
  h.valid = h.suspects.len > 0
  bot.llmVoting.hypothesis = h
  # Drop any hypothesis suspect that names a known imposter — that's
  # obviously wrong (we'd be targeting a teammate). Shouldn't happen
  # for crewmates since knownImposters is empty for them, but defensive.
  bot.llmVoting.hypothesis.suspects.keepItIf:
    not bot.isSafeColor(it.colorIndex)
  if bot.llmVoting.hypothesis.suspects.len == 0:
    bot.llmVoting.hypothesis.valid = false
  # Transition based on confidence.
  if bot.llmVoting.hypothesis.valid and h.confidence == "high":
    bot.llmVoting.stage = lvsAccusing
    dispatchCall(bot, lckAccuse)
  else:
    bot.llmVoting.stage = lvsListening

proc applyAccuseResponse(bot: var Bot; data: JsonNode) =
  var text = ""
  if data.hasKey("chat") and data["chat"].kind == JString:
    text = clampChat(data["chat"].getStr())
  queueOurChat(bot, text)
  bot.llmVoting.stage = lvsReacting

proc applyReactResponse(bot: var Bot; data: JsonNode) =
  # Updated hypothesis (may be partial)
  if data.hasKey("suspects"):
    let newSuspects = parseSuspects(data["suspects"])
    if newSuspects.len > 0:
      bot.llmVoting.hypothesis.suspects = newSuspects
      bot.llmVoting.hypothesis.valid = true
      bot.llmVoting.hypothesis.suspects.keepItIf:
        not bot.isSafeColor(it.colorIndex)
  if data.hasKey("confidence") and data["confidence"].kind == JString:
    bot.llmVoting.hypothesis.confidence =
      data["confidence"].getStr().toLowerAscii()
  # Chat
  var action = "silent"
  if data.hasKey("action") and data["action"].kind == JString:
    action = data["action"].getStr().toLowerAscii()
  if action != "silent" and data.hasKey("chat") and
      data["chat"].kind == JString:
    let text = clampChat(data["chat"].getStr())
    queueOurChat(bot, text)
  bot.llmVoting.lastReactionTick = bot.frameTick
  bot.llmVoting.hasUnreadChat = false

proc applyStrategizeResponse(bot: var Bot; data: JsonNode) =
  var strat: LlmImposterStrategy
  strat.bestTarget = -1
  if data.hasKey("best_target") and data["best_target"].kind == JString:
    let c = colorIndexByName(data["best_target"].getStr())
    if c >= 0 and not bot.isSafeColor(c):
      strat.bestTarget = c
  if data.hasKey("strategy") and data["strategy"].kind == JString:
    strat.strategy = data["strategy"].getStr().toLowerAscii()
  if data.hasKey("timing") and data["timing"].kind == JString:
    strat.timing = data["timing"].getStr().toLowerAscii()
  strat.valid = strat.bestTarget >= 0
  bot.llmVoting.imposterStrategy = strat
  # Optional initial chat.
  if data.hasKey("initial_chat") and data["initial_chat"].kind == JString:
    let text = clampChat(data["initial_chat"].getStr())
    if text.len > 0:
      queueOurChat(bot, text)
      bot.llmVoting.stage = lvsAccusing
      return
  if strat.strategy == "preemptive":
    bot.llmVoting.stage = lvsAccusing
  else:
    bot.llmVoting.stage = lvsListening

proc applyImposterReactResponse(bot: var Bot; data: JsonNode) =
  var action = "silent"
  if data.hasKey("action") and data["action"].kind == JString:
    action = data["action"].getStr().toLowerAscii()
  if action != "silent" and data.hasKey("chat") and
      data["chat"].kind == JString:
    let text = clampChat(data["chat"].getStr())
    queueOurChat(bot, text)
  bot.llmVoting.lastReactionTick = bot.frameTick
  bot.llmVoting.hasUnreadChat = false

proc applyPersuadeResponse(bot: var Bot; data: JsonNode) =
  if data.hasKey("chat") and data["chat"].kind == JString:
    let text = clampChat(data["chat"].getStr())
    queueOurChat(bot, text)

proc currentConfidenceForTrace(bot: Bot; kind: LlmCallKind): string =
  ## Extracts the confidence string to record in an `llm_decision`
  ## event. For hypothesis/react the hypothesis carries it directly.
  ## For strategize we stringify validity + strategy so the harness
  ## sees whether the imposter got a usable plan. Chat-only calls
  ## (accuse/persuade/imposter_react) have no confidence concept —
  ## return empty and let the emitter write null.
  case kind
  of lckHypothesis, lckReact, lckPersuade:
    if bot.llmVoting.hypothesis.valid:
      bot.llmVoting.hypothesis.confidence
    else:
      "invalid"
  of lckStrategize:
    if bot.llmVoting.imposterStrategy.valid:
      bot.llmVoting.imposterStrategy.strategy
    else:
      "invalid"
  of lckAccuse, lckImposterReact:
    ""  # chat-only — no confidence output
  of lckNone:
    ""

proc onLlmResponse*(bot: var Bot; kind: LlmCallKind;
                    responseJson: string; errored: bool) =
  ## Called by the FFI when the Python wrapper feeds back a response
  ## (or an error). `kind` is echoed back so we can tolerate stale
  ## responses if the state machine has moved on. On parse/validation
  ## failure we treat the slot as errored and transition to the
  ## fallback path.
  ##
  ## Observability (LLM_SPRINTS.md §1.1-§1.2): every code path below
  ## emits exactly one `llm_decision` OR one `llm_error` event (never
  ## both) and bumps the matching counter, so the harness can reliably
  ## pair dispatches with outcomes.
  ##
  ## Sprint 4.2 stale-response rule: a response that arrives after the
  ## state machine has already transitioned past its dispatch stage is
  ## treated as stale. Two cases:
  ##   * meeting ended (`lvsIdle`) — the entire LlmVotingState has
  ##     been reset; applying the response would mutate the next
  ##     meeting's state.
  ##   * forming-stage call (hypothesis / strategize) but the bot has
  ##     advanced past forming — the fallback path already fired
  ##     when the dispatch budget elapsed; applying the response
  ##     would overwrite a valid evidence-based decision.
  ## Stale responses are dropped with `llm_error{reason: "stale"}`
  ## but the request slot is still cleared so the state machine can
  ## dispatch the next call.
  let stageBefore = bot.llmVoting.stage
  let dispatchedTick = bot.llmVoting.request.dispatchedTick
  let dispatchedWallMs = bot.llmVoting.request.dispatchedWallMs
  let dispatchStage = bot.llmVoting.request.stage
  # `contextBytes` survives `llmTakePendingRequest`'s clear of
  # `contextJson`; reading `.contextJson.len` here would be zero in
  # the live FFI path because Python has already taken the payload.
  let contextBytes = bot.llmVoting.request.contextBytes
  let pendingChatBefore = bot.chat.pendingChat.len

  bot.llmVoting.request.pending = false
  bot.llmVoting.request.callKind = lckNone

  # --- Stale-response path (Sprint 4.2) -----------------------------------
  let isFormingKind = kind in {lckHypothesis, lckStrategize}
  let stageMovedPastForming =
    isFormingKind and
    dispatchStage in {lvsFormingHypothesis, lvsFormingStrategy} and
    stageBefore notin {lvsFormingHypothesis, lvsFormingStrategy}
  let meetingEnded = stageBefore == lvsIdle and dispatchStage != lvsIdle
  if stageMovedPastForming or meetingEnded:
    inc bot.llm.counters.totalErrored
    inc bot.llm.counters.byKindErrored[kind]
    if not bot.trace.isNil:
      emitLlmError(bot.trace, bot, kind, stageBefore, "stale",
                   (if meetingEnded: "meeting ended before response"
                    else: "stage advanced past dispatch"),
                   dispatchedTick, dispatchedWallMs, responseJson)
    return

  # --- Error paths ---------------------------------------------------------
  if errored or responseJson.len == 0:
    inc bot.llm.counters.totalErrored
    inc bot.llm.counters.byKindErrored[kind]
    let wasForming = stageBefore in {lvsFormingHypothesis, lvsFormingStrategy}
    if wasForming:
      bot.llmVoting.stage = lvsListening
      inc bot.llm.counters.totalFallbacks
    if not bot.trace.isNil:
      emitLlmError(bot.trace, bot, kind, stageBefore,
                   (if errored: "http" else: "empty_response"),
                   "provider error or empty response",
                   dispatchedTick, dispatchedWallMs, "")
    return

  var parsed: JsonNode
  try:
    parsed = parseJson(responseJson)
  except CatchableError as err:
    inc bot.llm.counters.totalErrored
    inc bot.llm.counters.byKindErrored[kind]
    let wasForming = stageBefore in {lvsFormingHypothesis, lvsFormingStrategy}
    if wasForming:
      bot.llmVoting.stage = lvsListening
      inc bot.llm.counters.totalFallbacks
    if not bot.trace.isNil:
      emitLlmError(bot.trace, bot, kind, stageBefore,
                   "parse", err.msg,
                   dispatchedTick, dispatchedWallMs, responseJson)
    return

  if parsed.isNil or parsed.kind != JObject:
    inc bot.llm.counters.totalErrored
    inc bot.llm.counters.byKindErrored[kind]
    if not bot.trace.isNil:
      emitLlmError(bot.trace, bot, kind, stageBefore,
                   "validation", "response was not a JSON object",
                   dispatchedTick, dispatchedWallMs, responseJson)
    return

  # --- Success path --------------------------------------------------------
  case kind
  of lckHypothesis:     applyHypothesisResponse(bot, parsed)
  of lckAccuse:         applyAccuseResponse(bot, parsed)
  of lckReact:          applyReactResponse(bot, parsed)
  of lckStrategize:     applyStrategizeResponse(bot, parsed)
  of lckImposterReact:  applyImposterReactResponse(bot, parsed)
  of lckPersuade:       applyPersuadeResponse(bot, parsed)
  of lckNone:           discard

  inc bot.llm.counters.totalCompleted
  inc bot.llm.counters.byKindCompleted[kind]
  let chatQueued =
    pendingChatBefore == 0 and bot.chat.pendingChat.len > 0
  if chatQueued:
    inc bot.llm.counters.totalChatQueued
  # Detect "soft fallback": a forming-stage response that was parseable
  # but didn't produce a valid hypothesis/strategy, so the state
  # machine degraded to Listening and will fall back at vote time.
  let softFallback =
    (kind == lckHypothesis and not bot.llmVoting.hypothesis.valid) or
    (kind == lckStrategize and not bot.llmVoting.imposterStrategy.valid)
  if softFallback:
    inc bot.llm.counters.totalFallbacks
  if not bot.trace.isNil:
    emitLlmDecision(bot.trace, bot, kind,
                    stageBefore, bot.llmVoting.stage,
                    currentConfidenceForTrace(bot, kind),
                    dispatchedTick, dispatchedWallMs,
                    contextBytes, responseJson.len,
                    chatQueued, softFallback)

# ---------------------------------------------------------------------------
# Vote target decision
# ---------------------------------------------------------------------------

proc chooseVoteTarget(bot: var Bot) =
  ## Populates `llmVoting.voteTarget` at the moment we commit to the
  ## vote (stage transitions to lvsVoting). Called from `tick` when
  ## either the hypothesis is high-confidence or VoteListenTicks
  ## has elapsed.
  bot.llmVoting.voteTarget = -1
  if bot.role == RoleImposter and not bot.isGhost:
    let strat = bot.llmVoting.imposterStrategy
    if strat.valid and strat.bestTarget >= 0 and
        not bot.isSafeColor(strat.bestTarget):
      # Validate target is still alive.
      var alive = false
      for i in 0 ..< bot.voting.playerCount:
        if bot.voting.slots[i].colorIndex == strat.bestTarget and
            bot.voting.slots[i].alive:
          alive = true
          break
      if alive:
        bot.llmVoting.voteTarget = strat.bestTarget
    return
  # Crewmate path.
  let h = bot.llmVoting.hypothesis
  if h.valid and h.suspects.len > 0:
    let top = h.suspects[0]
    if top.likelihood >= LlmVoteThreshold and
        not bot.isSafeColor(top.colorIndex):
      # Validate alive.
      var alive = false
      for i in 0 ..< bot.voting.playerCount:
        if bot.voting.slots[i].colorIndex == top.colorIndex and
            bot.voting.slots[i].alive:
          alive = true
          break
      if alive:
        bot.llmVoting.voteTarget = top.colorIndex
        return
  # Fallback: evidence-based (the rule-based suspect).
  let evSuspect = bot.evidenceBasedSuspect()
  if evSuspect.found:
    bot.llmVoting.voteTarget = evSuspect.colorIndex

# ---------------------------------------------------------------------------
# Public lifecycle hooks (called from bot.nim)
# ---------------------------------------------------------------------------

proc onMeetingStart*(bot: var Bot) =
  ## Called the first frame `bot.voting.active` is true. Dispatches
  ## the Stage-1 call for the bot's role.
  ##
  ## Pre-condition: `bot.llmVoting.stage == lvsIdle`. If the caller
  ## re-invokes this mid-meeting (e.g. after a spurious voting-screen
  ## reparse), we're already past Idle and no-op.
  if not bot.llmVoting.enabled:
    return
  if bot.llmVoting.stage != lvsIdle:
    return
  resetLlmVotingState(bot.llmVoting)
  bot.llmVoting.meetingStartTick = bot.frameTick
  bot.llmVoting.enabled = true
  if bot.role == RoleImposter and not bot.isGhost:
    bot.llmVoting.stage = lvsFormingStrategy
    dispatchCall(bot, lckStrategize)
  else:
    bot.llmVoting.stage = lvsFormingHypothesis
    dispatchCall(bot, lckHypothesis)

# Forward declarations for mock-LLM harness procs defined below. The
# mock section lives after `tickLlmVoting` for readability (lifecycle
# → mock harness → FFI surface) but `tickLlmVoting` needs to invoke
# the pump. Nim's lookup requires the name to be visible before first
# call, so we pre-declare here. `parseLlmCallKind` lives in the FFI
# section (called by `modulabot_set_llm_response`) but the mock
# loader parses fixture entries using the same mapping.
proc llmMockPump*(bot: var Bot)
proc parseLlmCallKind*(name: string): LlmCallKind

proc tickLlmVoting*(bot: var Bot) =
  ## Advances the state machine each frame while voting is active.
  ## Idempotent when nothing has changed. Must be called AFTER
  ## `parseVotingScreen` so `bot.voting.chatLines` is fresh.
  if not bot.llmVoting.enabled:
    return
  if not bot.voting.active:
    return
  if bot.llmVoting.stage == lvsIdle:
    onMeetingStart(bot)
    return

  # Ingest new chat lines regardless of stage — they feed the
  # Reacting loop and the imposter's full chat log for next strategize.
  ingestChatLines(bot)

  # Decide whether to dispatch a reaction call.
  let cooldownOk =
    bot.frameTick - bot.llmVoting.lastReactionTick >=
      LlmChatReactionCooldownTicks
  if bot.llmVoting.stage == lvsReacting or
      bot.llmVoting.stage == lvsListening:
    if bot.llmVoting.hasUnreadChat and cooldownOk and
        not bot.llmVoting.request.pending:
      if bot.role == RoleImposter and not bot.isGhost:
        dispatchCall(bot, lckImposterReact)
      else:
        dispatchCall(bot, lckReact)

  # Commit to vote if either (a) hypothesis confidence is high, or
  # (b) VoteListenTicks has elapsed.
  let listenElapsed =
    bot.llmVoting.meetingStartTick >= 0 and
    bot.frameTick - bot.llmVoting.meetingStartTick >= VoteListenTicks
  let highConfidence =
    bot.role != RoleImposter and
    bot.llmVoting.hypothesis.valid and
    bot.llmVoting.hypothesis.confidence == "high"
  if bot.llmVoting.stage != lvsVoting and
      bot.llmVoting.stage != lvsFormingHypothesis and
      bot.llmVoting.stage != lvsFormingStrategy and
      (highConfidence or listenElapsed):
    chooseVoteTarget(bot)
    bot.llmVoting.stage = lvsVoting
    # Optional persuasion (crewmate, high confidence).
    when LlmPersuadeEnabled:
      if bot.role != RoleImposter and highConfidence and
          not bot.llmVoting.request.pending:
        dispatchCall(bot, lckPersuade)

  # Mock-LLM hook: in test runs the fixture pump delivers scripted
  # responses immediately after dispatch. Real-provider runs skip
  # this (mock.enabled is false) and wait for Python to feed
  # responses via the FFI. Pumping AFTER the dispatch logic ensures
  # the stage transitions triggered by each mock response are
  # visible to the next iteration.
  if bot.llm.mock.enabled:
    llmMockPump(bot)

proc onMeetingEnd*(bot: var Bot) =
  ## Called when the voting screen closes. Resets state for the next
  ## meeting but preserves `enabled` and the myStatements log is
  ## cleared because next meeting's constraints differ.
  resetLlmVotingState(bot.llmVoting)

# ---------------------------------------------------------------------------
# Mock LLM harness (Sprint 3.1-3.2)
# ---------------------------------------------------------------------------
#
# Deterministic scripted-response queue used by `test/parity.nim --mode:llm-mock`
# and by the `--llm-mock:PATH` CLI flag. When enabled, `llmMockPump` drains
# any pending request immediately with the next fixture entry, bypassing the
# Python wrapper and the real provider entirely.
#
# Fixture format (JSONL, one entry per line):
#
#   {"kind": "hypothesis",       "response": {...}, "errored": false}
#   {"kind": "strategize",       "response": {...}, "errored": false}
#   {"kind": "imposter_react",   "response": {},    "errored": true}
#
# Unknown fields are ignored. `response` is stringified back to JSON and
# fed to `onLlmResponse` exactly as if Python had returned it, so every
# downstream behaviour (parsing, validation, fallback) is exercised.

proc llmMockLoadFromFile*(bot: var Bot; path: string) =
  ## Parses a JSONL fixture into `bot.llm.mock`. Each non-empty line
  ## must be a JSON object. Malformed lines raise — callers should
  ## validate fixtures at test-authoring time rather than silently
  ## swallow errors that would make the scripted test look like it
  ## passed.
  bot.llm.mock.entries.setLen(0)
  bot.llm.mock.cursor = 0
  bot.llm.mock.mismatchCount = 0
  let lines = readFile(path).splitLines()
  for lineNum, raw in lines:
    let line = raw.strip()
    if line.len == 0:
      continue
    let node = parseJson(line)
    if node.kind != JObject:
      raise newException(ValueError,
        "llm-mock:" & path & ":" & $(lineNum + 1) &
        " expected a JSON object")
    let kindStr =
      if node.hasKey("kind"): node["kind"].getStr()
      else: ""
    let kind = parseLlmCallKind(kindStr)
    if kind == lckNone and kindStr != "none":
      raise newException(ValueError,
        "llm-mock:" & path & ":" & $(lineNum + 1) &
        " unknown call kind '" & kindStr & "'")
    var errored = false
    if node.hasKey("errored"):
      errored = node["errored"].getBool()
    var responseJson = ""
    if not errored and node.hasKey("response"):
      responseJson = $node["response"]
    bot.llm.mock.entries.add(LlmMockEntry(
      kind: kind,
      responseJson: responseJson,
      errored: errored
    ))

proc llmMockEnable*(bot: var Bot; path: string) =
  ## Loads the fixture at `path` and flips both `llm.mock.enabled`
  ## and `llmVoting.enabled` so `tickLlmVoting` will dispatch and
  ## the mock pump will deliver responses. Safe to call in place of
  ## `llmEnable` — this is the entry point the CLI / parity harness
  ## use. Real Bedrock / Anthropic is bypassed when the mock is
  ## enabled.
  llmMockLoadFromFile(bot, path)
  bot.llm.mock.enabled = true
  bot.llmVoting.enabled = true
  if not bot.trace.isNil:
    setLlmLayerActive(bot.trace, bot)

proc llmMockPump*(bot: var Bot) =
  ## Delivers the next fixture entry if one is queued and a request
  ## is pending. Called from `tickLlmVoting`; also called by CLI
  ## drivers that poll outside the state machine (e.g. to flush
  ## final responses at end of run).
  ##
  ## Strict FIFO: an entry whose `kind` doesn't match the pending
  ## request is STILL consumed, but the response is injected as an
  ## error and the mismatch is counted for diagnostics. Fixture
  ## authors are expected to script the exact dispatch order; any
  ## divergence is a real test failure.
  ##
  ## Pumps in a bounded loop: applying a response often dispatches
  ## the next call (e.g. hypothesis → accuse), so draining those
  ## transitively within a single tick makes fixture-driven tests
  ## finish in O(fixtures) ticks rather than one-per-dispatch.
  ## The bound prevents runaway loops if the state machine ever
  ## degenerates.
  if not bot.llm.mock.enabled:
    return
  const PumpLimitPerCall = 16
  var pumped = 0
  while pumped < PumpLimitPerCall and bot.llmVoting.request.pending:
    inc pumped
    if bot.llm.mock.cursor >= bot.llm.mock.entries.len:
      # Out of fixture entries but the state machine still has
      # requests in flight. Inject an error so the bot degrades to
      # rule-based voting rather than wedging.
      let kind = bot.llmVoting.request.callKind
      onLlmResponse(bot, kind, "", true)
      continue
    let entry = bot.llm.mock.entries[bot.llm.mock.cursor]
    let pendingKind = bot.llmVoting.request.callKind
    inc bot.llm.mock.cursor
    if entry.kind != pendingKind:
      inc bot.llm.mock.mismatchCount
      # Still echo the pending-kind back to onLlmResponse so the
      # state machine's transition rules fire on the correct stage;
      # but mark errored so the fixture author's intent isn't
      # incorrectly applied.
      onLlmResponse(bot, pendingKind, "", true)
      continue
    onLlmResponse(bot, entry.kind, entry.responseJson, entry.errored)

# ---------------------------------------------------------------------------
# FFI surface (called from `ffi/lib.nim`)
# ---------------------------------------------------------------------------

proc llmEnable*(bot: var Bot) =
  ## Called by the FFI (`modulabot_enable_llm`) once Python has
  ## successfully constructed a provider client. Flips the state-
  ## machine gate so `tickLlmVoting` actually does work. Also marks
  ## the trace manifest so runs can be classified as "LLM live" vs.
  ## "built but not enabled" without inspecting event volume.
  bot.llmVoting.enabled = true
  if not bot.trace.isNil:
    setLlmLayerActive(bot.trace, bot)

proc llmTakePendingRequest*(bot: var Bot): tuple[kind: LlmCallKind,
                                                  contextJson: string] =
  ## Atomically removes the pending request from the slot and returns
  ## it. Python-side polls this each frame; when it gets a non-none
  ## kind, it kicks off the LLM call.
  if not bot.llmVoting.request.pending:
    return (lckNone, "")
  result = (bot.llmVoting.request.callKind, bot.llmVoting.request.contextJson)
  # Keep `pending = true` until the response arrives — marking it
  # consumed here would race: a provider-side error would leave the
  # state machine wedged with no "the request is in flight" flag.
  # The slot only clears on `onLlmResponse`.
  # What we DO need to do: let Python know it's already taken.
  # Set a sentinel: swap kind to lckNone so a second poll returns
  # (lckNone, "") while we wait for the response. The real kind is
  # recovered via the return value to the caller.
  bot.llmVoting.request.callKind = lckNone
  bot.llmVoting.request.contextJson = ""

proc llmPeekPendingKind*(bot: Bot): LlmCallKind =
  ## Non-consuming view of the request slot. Useful for tracing /
  ## debug stats without disturbing the state machine.
  if bot.llmVoting.request.pending:
    bot.llmVoting.request.callKind
  else:
    lckNone

proc llmCallKindName*(kind: LlmCallKind): string =
  case kind
  of lckNone:           "none"
  of lckHypothesis:     "hypothesis"
  of lckAccuse:         "accuse"
  of lckReact:          "react"
  of lckStrategize:     "strategize"
  of lckImposterReact:  "imposter_react"
  of lckPersuade:       "persuade"

proc parseLlmCallKind*(name: string): LlmCallKind =
  case name.strip().toLowerAscii()
  of "hypothesis":     lckHypothesis
  of "accuse":         lckAccuse
  of "react":          lckReact
  of "strategize":     lckStrategize
  of "imposter_react": lckImposterReact
  of "persuade":       lckPersuade
  else:                lckNone

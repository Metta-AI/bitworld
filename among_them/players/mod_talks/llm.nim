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

proc normalizeForDedup(line: string): string =
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
  ## Speaker attribution stays -1 (Q-LLM9 deferred). We *do* detect
  ## lines that match something we queued ourselves this meeting so
  ## the LLM isn't reasoning about its own statements as if they came
  ## from a stranger.
  var s = addr bot.llmVoting
  for raw in bot.voting.chatLines:
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
    # Was this one of ours?
    var mine = false
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
      speakerColor: -1,
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
      chat.add(%line)
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

# ---------------------------------------------------------------------------
# Per-task context builders
# ---------------------------------------------------------------------------

proc buildHypothesisContext(bot: Bot): string =
  ## LLM_VOTING.md §3.1 crewmate hypothesis.
  var ctx = newJObject()
  ctx["task"] = %"hypothesis"
  ctx["role_hint"] = %"crewmate"
  ctx["self_color"] = %playerColorName(bot.identity.selfColor)
  ctx["living_players"] = colorNameArray(bot.colorsAlive())
  ctx["round_events"] = roundEventsJson(bot)
  ctx["prior_meetings"] = priorMeetingsJson(bot)
  ctx["evidence_scores"] = evidenceScoresJson(bot)
  # Schema for constrained output (provider will validate).
  var schema = newJObject()
  schema["suspects"] = %* [{
    "color": "string (must be one of living_players)",
    "likelihood": "float 0..1",
    "reasoning": "one sentence"
  }]
  schema["confidence"] = %"high|medium|low"
  schema["key_evidence"] = %["string", "..."]
  ctx["response_schema"] = schema
  $ctx

proc buildAccuseContext(bot: Bot): string =
  ## LLM_VOTING.md §3.2 crewmate accusation chat.
  var ctx = newJObject()
  ctx["task"] = %"accuse"
  let h = bot.llmVoting.hypothesis
  if h.suspects.len > 0:
    let top = h.suspects[0]
    ctx["suspect"] = %playerColorName(top.colorIndex)
    ctx["likelihood"] = %top.likelihood
    ctx["reasoning"] = %top.reasoning
  ctx["key_evidence"] = block:
    var arr = newJArray()
    for e in h.keyEvidence:
      arr.add(%e)
    arr
  ctx["self_color"] = %playerColorName(bot.identity.selfColor)
  ctx["max_chat_len"] = %LlmMaxChatLen
  var schema = newJObject()
  schema["chat"] = %("string, <= " & $LlmMaxChatLen & " chars, name the suspect")
  ctx["response_schema"] = schema
  $ctx

proc buildReactContext(bot: Bot): string =
  ## LLM_VOTING.md §3.3 crewmate react / belief-update.
  var ctx = newJObject()
  ctx["task"] = %"react"
  ctx["self_color"] = %playerColorName(bot.identity.selfColor)
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
  ctx["current_hypothesis"] = hyp
  ctx["chat_since_last_update"] = chatLogJson(bot, recentOnly = true)
  ctx["my_prior_statements"] = myStatementsJson(bot)
  ctx["living_players"] = colorNameArray(bot.colorsAlive())
  var schema = newJObject()
  schema["suspects"] = %* [{
    "color": "string",
    "likelihood": "float 0..1",
    "reasoning": "one sentence"
  }]
  schema["confidence"] = %"high|medium|low"
  schema["action"] = %"speak|ask|silent"
  schema["chat"] = %("string or null, <= " & $LlmMaxChatLen & " chars")
  ctx["response_schema"] = schema
  $ctx

proc buildStrategizeContext(bot: Bot): string =
  ## LLM_VOTING.md §4.1 imposter strategy.
  ## Critical: `safe_colors` comes from `knownImposters` + self. Never
  ## let the model target anyone in that list. The prompt (system
  ## message, §5.3) enforces this; we also reject any response whose
  ## `best_target` is in safe_colors at parse time.
  var ctx = newJObject()
  ctx["task"] = %"strategize"
  ctx["safe_colors"] = safeColorsArray(bot)
  ctx["self_color"] = %playerColorName(bot.identity.selfColor)
  ctx["living_players"] = colorNameArray(bot.colorsAlive())
  # My own location history — last N sightings of self (we don't log
  # our own sightings; use the memory summary + last meeting events).
  # TODO: extend memory to log self-position keyframes. For now we
  # pass self's last room via the most recent summary write (which
  # actors.nim doesn't currently update for self). Pass an empty list
  # until this lands; imposter constraint is "don't fabricate
  # locations" so empty is safe (LLM will say less, not more).
  ctx["my_location_history"] = newJArray()
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
  ctx["bodies_this_round"] = bodies
  ctx["evidence_scores"] = evidenceScoresJson(bot)
  ctx["prior_meetings"] = priorMeetingsJson(bot)
  ctx["my_prior_statements"] = myStatementsJson(bot)
  var schema = newJObject()
  schema["best_target"] =
    %"string — a living non-safe player to target for ejection"
  schema["strategy"] = %"bandwagon|preemptive|deflect"
  schema["timing"] = %"early|mid|late"
  schema["reasoning"] = %"internal, one sentence"
  schema["initial_chat"] =
    %("string or null, <= " & $LlmMaxChatLen & " chars")
  ctx["response_schema"] = schema
  $ctx

proc buildImposterReactContext(bot: Bot): string =
  ## LLM_VOTING.md §4.2. Note the full chat log (Q-LLM8).
  var ctx = newJObject()
  ctx["task"] = %"imposter_react"
  let strat = bot.llmVoting.imposterStrategy
  ctx["strategy"] = %strat.strategy
  ctx["best_target"] =
    if strat.bestTarget >= 0 and strat.bestTarget < PlayerColorNames.len:
      %playerColorName(strat.bestTarget)
    else:
      newJNull()
  ctx["timing"] = %strat.timing
  ctx["safe_colors"] = safeColorsArray(bot)
  ctx["self_color"] = %playerColorName(bot.identity.selfColor)
  ctx["living_players"] = colorNameArray(bot.colorsAlive())
  ctx["my_location_history"] = newJArray()
  ctx["bodies_this_round"] = block:
    var arr = newJArray()
    for body in bot.memory.bodies:
      var b = newJObject()
      b["room"] = %roomNameForId(bot, body.roomId)
      b["tick_relative"] = %(bot.frameTick - body.tick)
      arr.add(b)
    arr
  ctx["full_chat_log"] = chatLogJson(bot, recentOnly = false, limit = 80)
  ctx["my_prior_statements"] = myStatementsJson(bot)
  var schema = newJObject()
  schema["action"] = %"corroborate|deflect|accuse|silent"
  schema["chat"] =
    %("string or null, <= " & $LlmMaxChatLen & " chars")
  schema["reasoning"] = %"internal, one sentence"
  ctx["response_schema"] = schema
  $ctx

proc buildPersuadeContext(bot: Bot): string =
  var ctx = newJObject()
  ctx["task"] = %"persuade"
  let h = bot.llmVoting.hypothesis
  if h.suspects.len > 0:
    ctx["suspect"] = %playerColorName(h.suspects[0].colorIndex)
  ctx["key_evidence"] = block:
    var arr = newJArray()
    for e in h.keyEvidence:
      arr.add(%e)
    arr
  var schema = newJObject()
  schema["chat"] =
    %("string, <= " & $LlmMaxChatLen & " chars, persuade others to vote")
  ctx["response_schema"] = schema
  $ctx

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
  if bot.llmVoting.request.pending:
    return
  let contextJson =
    case kind
    of lckHypothesis:     buildHypothesisContext(bot)
    of lckAccuse:         buildAccuseContext(bot)
    of lckReact:          buildReactContext(bot)
    of lckStrategize:     buildStrategizeContext(bot)
    of lckImposterReact:  buildImposterReactContext(bot)
    of lckPersuade:       buildPersuadeContext(bot)
    of lckNone:           ""
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

proc confidenceFromLikelihood(l: float32): string =
  if l >= LlmAccuseThreshold: "high"
  elif l >= 0.45'f32: "medium"
  else: "low"

proc colorIndexByName(name: string): int =
  ## Case-insensitive, whitespace-trimmed match against PlayerColorNames.
  let norm = name.strip().toLowerAscii()
  if norm.len == 0:
    return -1
  for i, candidate in PlayerColorNames:
    if candidate.toLowerAscii() == norm:
      return i
  -1

proc clampChat(text: string): string =
  ## Trim to `LlmMaxChatLen` at a word boundary when possible. Strips
  ## control characters and non-printable ASCII.
  var cleaned = ""
  for ch in text.strip():
    if ord(ch) >= 0x20 and ord(ch) < 0x7F:
      cleaned.add(ch)
    elif ch == '\n' or ch == '\t':
      cleaned.add(' ')
  if cleaned.len <= LlmMaxChatLen:
    return cleaned
  var cut = cleaned[0 ..< LlmMaxChatLen]
  let sp = cut.rfind(' ')
  if sp >= LlmMaxChatLen div 2:
    cut = cut[0 ..< sp]
  cut.strip()

proc isSafeColor(bot: Bot; colorIndex: int): bool =
  if colorIndex < 0 or colorIndex >= PlayerColorCount:
    return true
  if colorIndex == bot.identity.selfColor:
    return true
  bot.identity.knownImposters[colorIndex]

proc parseSuspects(node: JsonNode): seq[LlmSuspect] =
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
  let stageBefore = bot.llmVoting.stage
  let dispatchedTick = bot.llmVoting.request.dispatchedTick
  let dispatchedWallMs = bot.llmVoting.request.dispatchedWallMs
  # `contextBytes` survives `llmTakePendingRequest`'s clear of
  # `contextJson`; reading `.contextJson.len` here would be zero in
  # the live FFI path because Python has already taken the payload.
  let contextBytes = bot.llmVoting.request.contextBytes
  let pendingChatBefore = bot.chat.pendingChat.len

  bot.llmVoting.request.pending = false
  bot.llmVoting.request.callKind = lckNone

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

proc onMeetingEnd*(bot: var Bot) =
  ## Called when the voting screen closes. Resets state for the next
  ## meeting but preserves `enabled` and the myStatements log is
  ## cleared because next meeting's constraints differ.
  resetLlmVotingState(bot.llmVoting)

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

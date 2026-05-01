# mod_talks — LLM Integration Sprint Plan

Tracks remaining work to turn the mod_talks LLM layer from "wired but
under-instrumented and input-starved" into a measurable, improvable bot.

Each item is a discrete checkbox. Sub-bullets are acceptance criteria.
Keep this file updated as work lands: flip the checkbox, strike through
items that get dropped or superseded, and add follow-ups inline rather
than starting a new doc.

**Reference:** the triggering report lives in conversation history; the
design docs are `DESIGN.md §14`, `LLM_VOTING.md`, `TRACING.md`, and
`TODO.md`. Where this plan and those docs disagree, this plan is the
current intent — update the docs during Sprint 1's documentation sweep.

---

## Sprint 1 — Make it debuggable

Goal: every subsequent sprint depends on being able to answer
"what did the LLM do, and how long did it take?" from a trace file.
Ship this first.

**Status:** ✅ Landed 2026-04-30. All acceptance criteria met
(100% self-consistency parity preserved across seeds 1/42/100/7777
in both `-d:modTalksLlm` and non-LLM builds; manifest carries the
new LLM flags and session counters; `validate_trace` accepts the
new event types and schema v3).

### 1.1 `llm_decision` trace event

- [x] Emit an event on every `onLlmResponse` transition and on every
      fallback (timeout / parse fail / state machine abandon).
- [x] Payload: `{call_kind, stage_before, stage_after, confidence,
      latency_ms, fallback: bool, context_bytes, response_bytes,
      chat_queued: bool}`.
- [x] `latency_ms` derived from wall-clock `dispatchedWallMs` recorded
      on the request slot. Frame-tick deltas (`ticks_in_flight`,
      `dispatched_tick`) also emitted for cross-checking.
- [x] Added `"llm_decision"` to `test/validate_trace.nim:KnownEventTypes`.
- [x] Schema bumped to v3 (additive). Validator accepts v1, v2, v3.

### 1.2 `llm_error` trace event

- [x] Emitted on HTTP error (`errored=1`), empty response, parse
      failure, or non-object JSON response.
- [x] Payload: `{call_kind, stage, reason, detail,
      response_preview, latency_ms, dispatched_tick}`.
- [x] `response_preview` capped at 200 chars.
- [x] Added to `KnownEventTypes`.
- [x] Reasons currently emitted: `"http"`, `"empty_response"`,
      `"parse"`, `"validation"`. `"timeout"`/`"stale"`/`"context_overflow"`
      are in the vocabulary but not fired yet — they land in Sprints
      3–4.

### 1.3 Dispatch event (`llm_dispatched`)

- [x] Emitted from `dispatchCall` when a new request hits the slot.
      Payload: `{call_kind, stage, context_bytes}`.
- [x] Added to `KnownEventTypes`.
- [x] `llm_layer_active` bonus event also emitted once per process
      when `llmEnable` fires (the FFI ack from the Python wrapper),
      so the harness can mark the exact tick the LLM went live.

### 1.4 Manifest `llm_layer_active` bit

- [x] `trace_settings.llm_layer_active: bool` — flipped true by
      `llmEnable` via `setLlmLayerActive`.
- [x] `trace_settings.llm_compiled_in: bool` — set at
      `openTrace` from the `-d:modTalksLlm` compile flag.
- [x] Both appear in every manifest regardless of LLM state so the
      harness can trivially filter runs.
- [x] `validate_trace` enforces both fields on schema v3 manifests.

### 1.5 `LlmState` session counters

- [x] `LlmState` sub-record added to `Bot` alongside `LlmVotingState`.
- [x] Counters: `totalDispatched, totalCompleted, totalErrored,
      totalFallbacks, totalChatQueued`, plus per-`LlmCallKind` arrays
      `byKindDispatched/Completed/Errored`.
- [x] Incremented inline from `dispatchCall` / `onLlmResponse`.
- [x] Process-lifetime (not per-round); surfaced in every manifest
      under `summary_counters.llm` as a point-in-time snapshot.
- [x] `LlmConfig` (provider, model, timeouts) deferred to Sprint 5 —
      Python wrapper owns provider selection end-to-end for now.

### 1.6 Documentation sweep

- [x] `DESIGN.md §14` header — "Status: initial integration shipped;
      see LLM_SPRINTS.md for remaining work."
- [x] `LLM_VOTING.md` header — added "Implementation status" section
      replacing the stale "design only" block.
- [x] `LLM_VOTING.md §12 Q-LLM1 / Q-LLM6` / `DESIGN.md §14.6` —
      resolved (AnthropicBedrock + credential chain).
- [x] `TODO.md` "LLM voting integration (planned, not yet started)"
      — replaced with a pointer to `LLM_SPRINTS.md`.
- [x] `TODO.md` speaker-attribution entry — cross-linked to Sprint 2.1.
- [x] `DESIGN.md §11 Phase 4` — updated to "in progress" with full
      breakdown of shipped vs. pending.

### 1.7 Sprint 1 acceptance

- [x] Non-LLM build compiles clean; `mod_talks` binary + `libmodulabot.dylib`
      both produced successfully with `-d:modulabotLibrary`.
- [x] LLM build (`-d:modTalksLlm`) compiles clean.
- [x] Self-consistency parity 500/500 across seeds 1/42/100/7777 in
      both builds (black mode).
- [x] Trace captured from a parity run contains schema_version=3,
      `trace_settings.llm_compiled_in` + `.llm_layer_active` set
      correctly (true+false in LLM build, false+false in non-LLM
      build), and `summary_counters.llm` with all zero counters
      (parity harness doesn't exercise LLM paths).
- [x] `validate_trace --root:<captured>` passes on both builds.
- [x] `gen_branch_ids` produces no diff (no new branch-id call sites
      were added; `fired(...)` coverage unchanged).

**Deferred to Sprint 1.5 follow-up (open):**

- [x] **Live end-to-end verification.** Ran `launch_mod_talks_llm_local.py`
      against Bedrock (`claude-sonnet-4-5-20250929-v1:0`, region
      `us-east-1`, `AWS_PROFILE=softmax`). 8 agents, 2500-step game.
      Every agent emitted exactly one `llm_layer_active` event at
      tick 1 and at least one `llm_dispatched` → `llm_decision` pair
      at the first meeting (hypothesis for crewmates, strategize for
      imposters). Real Bedrock latency observed: 5.7 s–33 s per call.
      `chat_queued: true` fired on at least one strategize response
      (imposter opened with a preemptive accusation). Agents 001, 003
      killed, 006 used cooldown — normal imposter behavior.
- [x] **`MODULABOT_TRACE_DIR` plumbing for the FFI path.** The env
      var previously only worked in the CLI runner. Added
      `_arm_trace_if_requested` to `cogames/amongthem_policy.py` that
      calls `modulabot_init_trace` before `modulabot_new_policy`.
      Honors the same env vars as the CLI (`MODULABOT_TRACE_LEVEL`,
      `MODULABOT_TRACE_SNAPSHOT_PERIOD`, `MODULABOT_TRACE_META`,
      `MODULABOT_TRACE_FRAMES_DUMP`).
- [x] **`context_bytes` preservation.** Bug caught during live run:
      `llm_decision` events were reporting `context_bytes: 0`
      because `llmTakePendingRequest` clears `contextJson` before
      `onLlmResponse` runs. Added `contextBytes: int` to
      `LlmRequestSlot` (set at dispatch, survives the take) so the
      decision event records the true dispatch-time size.

**Known pre-existing limitations surfaced by the live run (tracked for
Sprint 1.x / Sprint 2 follow-up, NOT blocking Sprint 1 sign-off):**

- [ ] **Stale manifest on truncated runs.** The manifest is written
      at `beginRound` and rewritten at `endRound`. In the FFI path,
      `modulabot_enable_llm` fires on the first frame (after the
      initial manifest has been written), so until the round closes
      with a `game_over` text, the on-disk manifest shows
      `llm_layer_active: false` and zero `summary_counters.llm`.
      The emitted events are correct; only the snapshot file is
      stale. Fix options: add a `modulabot_close_trace` FFI entry
      Python calls on shutdown, periodic manifest rewrite every N
      ticks, or include `summary_counters` in every N-th snapshot
      file. Revisit in Sprint 2 or 3 depending on harness needs.
- [ ] **`validate_trace` rejects truncated rounds.** Rule "unclosed
      meetings at end of round" fails whenever a game is cut short
      with `--max-steps` mid-meeting. Not a Sprint 1 regression —
      it was the behavior before this work landed. Consider a
      `--allow-truncated` validator flag, or a separate
      `round_truncated` event emitted by a process-exit hook.

---

## Sprint 2 — Close the hard prereq and the highest-leverage input gaps

Goal: give the model the inputs it's been starving on. Speaker
attribution was declared a hard prerequisite in `LLM_VOTING.md §1.5`
and shipped unbuilt; the other three items in this sprint are
single-digit-LOC callers of already-written memory machinery or
modest perception passes.

**Status:** ✅ Landed 2026-04-30. Parity 500/500 black-mode across
seeds {1, 42, 100, 7777} in both builds; live Bedrock smoke
(`--max-steps 5000`) emitted expected events with
`speaker_attribution: color_pip` in the manifest.

### 2.1 Speaker attribution (Q-LLM9 prerequisite)

- [x] Implemented `detectChatSpeaker` in `voting.nim`: scans
      pixels in `x=[1..13], y=[textY..textY+7]` for
      `PlayerColors` palette matches, returns dominant color
      index (or -1 on low confidence).
- [x] `voting.chatLines` type changed from `seq[string]` to
      `seq[VoteChatLine]` carrying `(speakerColor, text)`.
- [x] `MeetingEvent.chatLines` type updated to match; long-term
      memory now stores speaker attribution.
- [x] `llm.nim:ingestChatLines` reads `entry.speakerColor`;
      falls back to substring-matching `myStatements` only when
      pip detection failed.
- [x] `trace.nim` emits real `speaker` field on `chat_observed`
      events (was hardcoded null).
- [x] Manifest `trace_settings.speaker_attribution` flipped from
      `"none"` to `"color_pip"`.

Implementation notes:
- Multi-line message support falls out of the geometry
  automatically: the sim renders one 12×12 sprite per message but
  each text row of a multi-line message overlaps the sprite
  vertically, so every line self-attributes without needing an
  explicit "inherit from previous row" rule.
- Unit test deferred to Sprint 3 — the pip detector needs a
  captured voting-screen fixture, which the mock-LLM harness
  (Sprint 3.1) will need too; bundling makes sense.

### 2.2 Self-position keyframes → `my_location_history`

- [x] `Memory.selfKeyframes: seq[SelfKeyframe]` +
      `lastSelfRoomId: int` added to `types.nim`.
- [x] `observeSelfRoom` proc in `memory.nim` with ring-buffer
      cap (`MemorySelfKeyframeCap = 64`) and
      don't-log-corridors rule (roomId=-1 is skipped but
      `lastSelfRoomId` is still invalidated so the next real
      room arrival emits a fresh entry).
- [x] Hooked from `bot.nim:decideNextMaskCore` after
      `rememberHome`, before policy dispatch.
- [x] `myLocationHistoryJson` helper in `llm.nim` emits
      newest-first, capped at 20 entries; replaces the hardcoded
      empty arrays in `buildStrategizeContext` and
      `buildImposterReactContext`.
- [x] NOT trimmed at meeting boundaries — imposter needs the
      full pre-meeting history to build alibis.

### 2.3 Alibi log wiring

- [x] `updateAlibiObservations` proc in `tasks.nim` iterates
      `(visibleCrewmate × sim.tasks)` and calls
      `memory.appendAlibi` when crewmate world-position is
      within `MemoryAlibiMatchRadius = 28` px of a task centre
      AND the task icon is currently rendered
      (`taskIconVisibleFor`).
- [x] Hooked after `updateTaskIcons` in `bot.nim`.
- [x] Dedup rules in `memory.nim` unchanged; per-(color, task)
      suppression within `MemoryAlibiCooldownTicks` works.

Implementation notes:
- The icon-visibility requirement filters out alibis at
  already-completed tasks (whose icons vanish), keeping the
  signal aligned with "actually-using-terminal" rather than
  "standing near the furniture".
- Self is filtered at the proc level (`crewmate.colorIndex ==
  bot.identity.selfColor`) so we don't alibi ourselves.

### 2.4 Ejection detection → `MeetingEvent.ejected`

- [x] `detectResultEjection` proc in `voting.nim` reads the
      post-vote result frame: returns -2 for "NO ONE DIED"
      text-detection, else scans the 12×12 centered sprite
      for `PlayerColors` palette pixels and returns the
      dominant color index (or -1 on low-confidence).
- [x] `VotingState.resultEjected` field added; preserved
      across `clearVotingState` (cleared only at round reset).
- [x] `finalizeMeeting` proc in `bot.nim` extracted from the
      inline code. Appends `MeetingEvent` with
      `ejected = bot.voting.resultEjected`, records vote
      accounting, trims memory, clears voting/LLM state.
- [x] Interstitial branch of `decideNextMaskCore` calls
      `detectResultEjection` on the true→false transition
      frame (the result screen) before clearVotingState
      cascades.

Implementation notes — **latent bug caught and fixed**:
- The pre-Sprint-2.4 code appended `MeetingEvent` only in the
  non-interstitial branch of `decideNextMaskCore` (original
  `bot.nim:425` block). That branch is unreachable in practice:
  the result frame is itself an interstitial, so `parseVotingScreen`
  fails there and `clearVotingState` fires inside the interstitial
  branch before control ever reaches the non-interstitial block.
  The fix moves meeting finalization into the interstitial branch
  (where it actually runs) and keeps the non-interstitial block
  as belt-and-suspenders for unobserved edge cases.
- `ejected: int` schema now distinguishes three cases: `-1`
  (detection failed / unknown), `-2` (result frame showed NO ONE
  DIED — skipped vote), else color index. `llm.nim` serializes
  the `-2` case as JSON null for consistency with prior-meetings
  schema; `-1` also serializes as null but with lower confidence
  (the harness can compare `meetings_attended` against
  `non_null_ejected_count` to see detector hit rate).

### 2.5 Sprint 2 acceptance

- [x] Non-LLM and LLM (`-d:modTalksLlm`) builds both compile
      clean.
- [x] `libmodulabot.dylib` rebuilds successfully via
      `build_modulabot.py` with `MODULABOT_LLM=1`.
- [x] Self-consistency parity 500/500 black-mode across seeds
      {1, 42, 100, 7777} in both builds.
- [x] Live Bedrock smoke (`--max-steps 5000`): 8 agents
      connected, Bedrock calls succeeded, per-agent events
      captured, manifest carries
      `trace_settings.speaker_attribution: "color_pip"` and
      schema v3.
- [x] `validate_trace` passes on the captured rounds
      structurally; the pre-existing "unclosed meetings" rule
      still fires on truncated runs (known Sprint 1 limitation).

**Deferred / follow-ups:**
- Unit test for `detectChatSpeaker` and `detectResultEjection`
  — deferred to Sprint 3 where the mock-LLM harness will also
  need a captured voting-screen fixture; bundling the fixtures
  keeps the test data unified.
- Live verification of `chat_observed` events with real speakers
  blocked on Sprint 4.1 (concurrent LLM dispatch): under the
  current single-lock dispatcher, 8 agents × ~20s/call
  serializes so long that games truncate before multiple
  chat lines accumulate during a meeting. Every piece of
  plumbing needed is in place; Sprint 4 unlocks the timing
  budget needed to exercise it end-to-end.
- Reporter detection (who pressed the meeting button) remains
  deferred — lower leverage than ejection outcome, moved from
  Sprint 2 to parking lot per the plan doc.

---

## Sprint 3 — Make it regression-safe

Goal: refactoring `llm.nim` is currently high-risk because nothing
tests it. Fix that before any prompt engineering sprint or provider
swap.

**Status:** ✅ Landed 2026-04-30. Mock harness running through the
parity test, 51 unit tests pass, context-trim policy in place,
parity 500/500 across {1, 42, 100, 7777} in four matrices
(non-LLM, LLM, mock-basic, mock-errored).

### 3.1 Mock LLM mode — CLI flag + FFI hook

- [x] `LlmMockEntry` + `LlmMock` types in `types.nim`; loaded into
      `LlmState.mock`.
- [x] `llmMockLoadFromFile` parses JSONL fixtures (skips blank
      lines, raises on unknown call kinds, raises on non-object
      lines).
- [x] `llmMockEnable` flips both `mock.enabled` and
      `llmVoting.enabled` so `tickLlmVoting` becomes active and
      consumes scripted responses instead of dispatching real
      provider calls.
- [x] `llmMockPump` drains pending requests in a bounded loop
      (16 per tick max) — applying a response often dispatches
      the next call, so transitive draining keeps fixture-driven
      tests fast.
- [x] Strict FIFO with kind-mismatch detection: a fixture entry
      whose `kind` doesn't match the pending call is consumed but
      injected as an error and counted in
      `mock.mismatchCount` for diagnostics.
- [x] Out-of-fixtures behavior: when the bot has more requests
      than the fixture has entries, remaining calls are
      auto-errored so the bot degrades to rule-based voting
      rather than wedging.
- [x] `--llm-mock:PATH` CLI flag in `modulabot.nim` (also reads
      `MODTALKS_LLM_MOCK` env var). When the build lacks
      `-d:modTalksLlm`, the flag is warned and ignored.

Implementation note — design choice on dispatch path:
- The plan originally proposed a Python-side mock (Python reads
  the JSONL file and feeds via `modulabot_set_llm_response`).
  Implemented entirely in Nim instead because (1) `parity.nim`
  doesn't run Python, (2) it keeps the test surface simpler, and
  (3) the same code path is exercised end-to-end as a live game,
  just without the HTTP round-trip. Trade-off: the Python wrapper
  doesn't see scripted responses through its own code, but
  Sprint 4 brings concurrency to Python anyway and that
  refactor will deserve its own integration test.

### 3.2 Parity harness `--mode:llm-mock`

- [x] Added `--llm-mock:PATH` to `test/parity.nim`. When set,
      `runSelfConsistency` loads the same fixture into both bot
      instances before stepping. They consume entries in lockstep
      and must produce identical masks.
- [x] Two reference fixtures shipped under
      `test/fixtures/`:
      - `llm_mock_basic.jsonl` — a clean run through every call
        kind (hypothesis, accuse, react, strategize,
        imposter_react, persuade) with realistic responses.
      - `llm_mock_all_errored.jsonl` — every entry errored, used
        to verify the fallback path stays parity-clean.
- [x] Parity 500/500 across seeds {1, 42, 100, 7777} in both
      mock fixtures.

### 3.3 Unit tests for `llm.nim`

- [x] New file: `test/llm_unit.nim`. Exits non-zero on first
      failure; prints per-test pass/fail labels.
- [x] 51 tests covering:
  - [x] `clampChat` — short, control-char strip, newline-to-space,
        word-boundary truncation.
  - [x] `colorIndexByName` — exact, case-insensitive, whitespace
        tolerance, unknown, empty.
  - [x] `confidenceFromLikelihood` — three-tier mapping including
        inclusive thresholds at 0.75 and 0.45.
  - [x] `normalizeForDedup` — lowercasing, punctuation collapse,
        idempotence.
  - [x] `parseSuspects` — sort, drop unknown colors, missing
        fields, nil node.
  - [x] `isSafeColor` — self, known imposter, out-of-range
        defensive cases.
  - [x] `llmMockLoadFromFile` — basic, blank-line tolerance,
        unknown-kind rejection, non-object rejection.
  - [x] `initLlmVotingState` / `resetLlmVotingState` — defaults,
        `enabled` preservation across reset.
  - [x] `trimContextInPlace` (Sprint 3.4) — already-fits, halve
        sightings, drop chat summaries, fully-unfittable case.

### 3.4 Context-size enforcement

- [x] Refactored builders (`buildHypothesisContext` et al.) to
      return `JsonNode` instead of pre-serialized strings.
      `dispatchCall` now serializes once after applying trim.
- [x] `trimContextInPlace` proc in `llm.nim`: progressive 7-tier
      trim policy applied to the JSON tree:
  1. Halve `round_events.sightings_since_last_meeting`.
  2. Halve `chat_since_last_update`.
  3. Halve `full_chat_log`.
  4. Drop `prior_meetings[].chat_summary` arrays.
  5. Drop `prior_meetings` entirely.
  6. Drop `round_events.sightings_since_last_meeting` entirely.
  7. Drop `evidence_scores` (last resort).
- [x] Two budget constants in `tuning.nim`:
      `LlmMaxContextLen = 7500` (soft target the trim aims for)
      and `LlmMaxContextBytes = 15500` (hard ceiling matching
      `_LLM_CONTEXT_BUFFER_SIZE` from the Python wrapper minus
      ~900 bytes safety margin).
- [x] On overflow (trim couldn't reduce below the hard ceiling):
      emit `llm_error{reason: "context_overflow"}`, bump fallback
      counter, transition forming-stage to listening so vote-time
      fallback fires. No `LlmRequestSlot` is created.
- [x] Newest-first array order preserved by all halvers — the
      most recent observations are most decision-relevant.

### 3.5 Sprint 3 acceptance

- [x] All builds compile clean (non-LLM CLI, LLM CLI,
      `libmodulabot.dylib`, `parity`, `parity_llm`, `llm_unit`).
- [x] Self-consistency parity 500/500 across seeds
      {1, 42, 100, 7777} × matrices
      {non-LLM, LLM, mock-basic, mock-errored}.
- [x] `llm_unit.nim` runs all 51 tests green.
- [x] Mock-LLM parity exercises the full state machine end-to-end
      including dispatchCall, applyHypothesisResponse,
      applyStrategizeResponse, applyAccuseResponse, etc., yet
      remains deterministic.

---

## Sprint 4 — Make it fast and robust

Goal: the current Python dispatch path serializes every agent's LLM
call behind a single lock. An 8-agent batch with 2 s provider latency
wastes 14 s of wall time per frame. Also: retries, schema enforcement,
prefix rename.

**Status:** ✅ Landed 2026-04-30 (4.6 explicitly deferred — see below).
Live Bedrock smoke confirms 3-4× concurrency speedup: p50 latency
dropped from ~33 s in Sprint 1 (single lock, 8 agents serialised) to
~9.2 s in Sprint 4 (concurrent dispatch, same 8-agent batch).
Parity 500/500 across seeds {1, 42, 100, 7777} preserved across all
four matrices.

### 4.1 Concurrent provider dispatch

- [x] `_AnthropicController._lock` removed. SDK is thread-safe; the
      lock was a redundant serialiser.
- [x] `AmongThemPolicy._executor: ThreadPoolExecutor` lazy-allocated
      with `max_workers = num_agents`. `__del__` shuts down with
      `cancel_futures=True` to avoid hanging the interpreter.
- [x] `_dispatch_llm` (replaces `_service_llm`) submits one future
      per pending request and returns immediately. Per-agent
      bookkeeping in `self._inflight: dict[int, _LlmFuture]`.
- [x] `_gather_llm_futures` runs at the end of every `step_batch`
      with a wall-clock deadline (`MODTALKS_LLM_DEADLINE_SECONDS`,
      default 12 s). Futures still running at the deadline are
      LEFT in `_inflight` and re-checked next step rather than
      cancelled — many providers don't honour cancellation cleanly
      and we don't want to leak connections.

### 4.2 Per-call-kind timeouts + stale-response drop

- [x] `PER_KIND_TIMEOUT_SECONDS` table in `amongthem_policy.py`
      (`hypothesis`/`strategize` 20 s; `react`/`imposter_react`
      15 s; `accuse`/`persuade` 10 s). Threaded through
      `_AnthropicController.complete(timeout_seconds=...)`.
- [x] Stale-response detection in `llm.nim:onLlmResponse` —
      compares `request.stage` (captured at dispatch) against
      current `bot.llmVoting.stage`. Two stale conditions:
      (a) forming-stage call but stage advanced past forming
      (b) meeting ended (`lvsIdle`).
- [x] Stale responses emit `llm_error{reason: "stale"}`, bump
      counters, and are dropped without applying — protecting
      vote decisions from being clobbered by a delayed response.

### 4.3 Anthropic tool-use structured output

- [x] `_LLM_TOOL_DEFINITIONS` table — six tools, one per call
      kind, with JSON-schema input shapes mirroring
      `LLM_VOTING.md §5.4` verbatim.
- [x] `_AnthropicController.complete` switches to tool-use when
      `kind` matches a known tool: `tools=[tool]` plus
      `tool_choice={"type":"tool","name":...}` forces the model
      to emit a structured response. The `tool_use` content
      block's `input` field is serialised back to JSON for Nim.
- [x] Schema-in-prompt path retained as fallback for unknown
      kinds and tool-use responses that lack the expected block
      (defensive — shouldn't fire in practice).

### 4.4 Retry + exponential backoff

- [x] `_MAX_RETRIES = 2`, `_RETRY_BACKOFF_SECONDS = (0.5, 1.5)`.
- [x] `_is_retryable` helper: returns True for
      `RateLimitError`, `APITimeoutError`, `APIConnectionError`,
      `InternalServerError`, `ServiceUnavailableError`, plus any
      exception with a 5xx `status_code`. 4xx auth/validation
      errors are NOT retried.
- [x] Retry loop respects the per-call `timeout_seconds` budget
      — if the next backoff would push past the deadline, abandon
      retry and return empty (Nim's fallback fires).

### 4.5 Non-ASCII chat handling

- [x] `transliterateAscii` proc in `llm.nim` decodes UTF-8
      manually and maps common punctuation (smart quotes,
      em-dash, ellipsis, non-breaking space, bullets, common
      currency) to ASCII equivalents. Anything unmapped is
      dropped — better than letting the BitWorld PixelFont
      render `?` glyphs.
- [x] `clampChat` rewritten to call `transliterateAscii` first.
      Word-boundary truncation logic preserved.
- [x] Three new unit tests covering smart quotes, em-dash,
      ellipsis, and emoji-drop behaviour.

### 4.6 FFI / binary prefix rename — DEFERRED

- [ ] Renaming `modulabot_*` → `mod_talks_*` exports + binary
      names is a large, low-impact churn that touches every
      `cogames/amongthem_policy.py` call site, the build script,
      symbol exports, and downstream tests. Consensus: defer
      until either (a) a new bot family forks from mod_talks
      and there's actually a name collision to resolve, or
      (b) the cogames submission flow demands a specific name.
      Current code is internally consistent: `mod_talks` as the
      project / directory / class name, `modulabot_*` as the
      legacy FFI prefix. Tracked in `TODO.md`.

### 4.7 Sprint 4 acceptance

- [x] All builds compile clean: non-LLM CLI, LLM CLI,
      `libmodulabot.dylib`, `parity`, `parity_llm`, `llm_unit`.
- [x] Self-consistency parity 500/500 across seeds
      {1, 42, 100, 7777} × matrices
      {non-LLM, LLM, mock-basic, mock-errored}.
- [x] `llm_unit.nim` runs all 56 tests green (3 new
      transliterate tests added).
- [x] Live Bedrock smoke (`--max-steps 1500`, 8 agents):
      8 of 8 agents emitted `llm_dispatched` → `llm_decision`
      pairs, p50 latency 9.2 s, max 10.3 s. **3-4× faster than
      Sprint 1's serial dispatch.** No retries triggered (clean
      Bedrock run); no stale responses; no `llm_error` events.

---

## Sprint 5 — Iterate on quality

Goal: once the infrastructure is in place, actually make the bot a
better player. Everything in this sprint depends on Sprint 1's
observability, Sprint 2's inputs, and Sprint 3's tests.

**Status:** ✅ Landed 2026-04-30. 5.2's empirical persuasion A/B
campaign is explicitly deferred (infrastructure ready; needs ~40
live games to be conclusive).

### 5.1 Prompt-eval harness

- [x] `tools/llm_prompt_eval.py` ships. Walks a captured trace
      tree for `llm_contexts/ctx_*.json` files (only emitted when
      `MODTALKS_LLM_CAPTURE=1` is set, so prod traces stay light)
      and replays each context against either:
      - The live provider (default; uses the same
        `_AnthropicController` mod_talks runs in production), or
      - A scripted JSONL fixture (`--mock`) for offline / CI use.
- [x] Five mechanical scoring checks per response:
      `valid_json`, `living_player_target`,
      `respects_safe_colors`, `chat_within_max_len`,
      `no_ai_reveal`. Output is a CSV row per (capture, response)
      plus a stdout summary table grouped by call kind.
- [x] Capture pipeline wired through Nim:
      `Trace.captureLlmContexts` (gated by env var),
      `emitLlmContextCapture` proc writes
      `<round>/llm_contexts/ctx_<seq>_<kind>_t<tick>.json` from
      `dispatchCall`.
- [x] Verified end-to-end: a live Bedrock run with
      `MODTALKS_LLM_CAPTURE=1` produced 8 captures; harness
      replayed them against the basic mock fixture and produced
      a per-kind summary table.

### 5.2 Persuasion A/B — infrastructure shipped, campaign deferred

- [x] Converted `LlmPersuadeEnabled` from a compile-time `when`
      block to a runtime check. New env var `MODTALKS_PERSUADE`
      (1/0/true/false/yes/no) overrides the tuning default at
      process start. Builds no longer need recompilation to
      flip the switch.
- [x] Parity 500/500 verified with both
      `MODTALKS_PERSUADE` set and unset, confirming the runtime
      toggle is non-perturbing in the mock-mode path.
- [ ] **Empirical 40+ game A/B campaign** — DEFERRED. A single
      live game takes a few minutes wall-clock and burns
      ~$0.10-1 in Bedrock tokens; a statistically meaningful A/B
      across 20 persuade-on + 20 persuade-off would be a multi-
      hour, dollars-cost campaign that's better run as a CI job
      with real win-rate scoring. Plumbing in place; campaign
      itself is not on Sprint 5's critical path.

### 5.3 Multi-provider config

- [x] `_OpenAIController` class added to
      `cogames/amongthem_policy.py`. Mirrors the
      `_AnthropicController` interface (`enabled` property,
      `complete(role, kind, context_json, timeout_seconds)`).
      Uses OpenAI's chat-completion API with `tools` translated
      from the existing `_LLM_TOOL_DEFINITIONS` (Anthropic's
      `input_schema` becomes OpenAI's `function.parameters`).
- [x] `_build_llm_controller` selector picks the first available
      controller by preference: explicit `MODTALKS_PROVIDER_OPENAI=1`
      → OpenAI; otherwise Anthropic; otherwise OpenAI as a
      last-resort fallback.
- [x] `launch_mod_talks_llm_local.py` auto-stamps
      `manifest.harness_meta.llm_provider` /
      `manifest.harness_meta.llm_model` /
      `manifest.harness_meta.llm_persuade` /
      `manifest.harness_meta.llm_disabled` so the prompt-eval
      harness can group runs by configuration without parsing
      events. Verified in a final smoke run — manifest carries
      `harness_meta.llm_provider: "bedrock"`.
- [ ] **Live OpenAI verification** — DEFERRED until a tournament
      env actually has `OPENAI_API_KEY`. The translation logic
      compiles and the dispatcher selects correctly when forced;
      end-to-end provider behaviour is unverified.

### 5.4 Tuning-snapshot entries for LLM knobs

- [x] All 14 public constants in `tuning.nim` now appear in
      `tuning_snapshot.nim`: every `Memory*`, `Llm*` knob.
      Manifest lineage tracking is now exhaustive for tunables
      the harness might A/B.
- [x] `tools/trace_smoke.sh` step 7 implements the exhaustiveness
      check: `awk` extracts public consts from `tuning.nim`,
      grep checks each appears as a key in `tuning_snapshot.nim`.
      Soft warning (not a build failure) so layout-only constants
      can be skipped intentionally.
- [x] `trace_smoke.sh` also runs the new Sprint 3.3 unit tests
      (step 6) so the canonical local-CI command exercises the
      full new test surface.

### 5.5 Sprint 5 acceptance

- [x] All builds compile clean: non-LLM CLI, LLM CLI,
      `libmodulabot.dylib`, `parity`, `parity_llm`, `llm_unit`.
- [x] Self-consistency parity 500/500 across seeds {1, 42, 7777}
      in non-LLM, LLM, and mock-LLM matrices.
- [x] `llm_unit.nim` runs all 56 tests green.
- [x] Live Bedrock smoke (`--max-steps 800`): manifest carries
      provider/model/persuade/disabled lineage in
      `harness_meta`.
- [x] Capture-and-eval pipeline verified end-to-end: 8 captures
      → mock-mode replay → per-kind score summary.

---

## Sprint 6 — LLM as a first-class citizen of the CLI binary

Goal: the LLM voting layer should work everywhere the rest of
mod_talks works — `quick_player`, standalone CLI runs, remote
servers — without requiring the Python wrapper. The Python wrapper
stays the canonical cogames-tournament path; Sprint 6 makes it
optional for everything else.

**Status:** planned, not started. See the design report in chat
(2026-05-01) for the architectural background. Estimated effort:
~17 hours / 2 working days.

**Hard scope rule:** all new code lives under
`among_them/players/mod_talks/`. No edits to `src/bitworld/ais/`,
`common/`, `among_them/sim.nim`, or other shared repo files —
those belong to the bitworld team. We re-implement the small
slice of provider HTTP we need rather than extending shared
modules.

### Why this is a sprint

The current `mod_talks_llm` CLI binary accepts `-d:modTalksLlm`
and connects to any server via `--address:HOST --port:N`, but
`llmEnable(bot)` is never called and `tickLlmVoting` no-ops. The
LLM dispatch loop only exists in the Python wrapper at
`cogames/amongthem_policy.py`. That makes the LLM unreachable
from `quick_player`, from any non-cogames runner, and from any
remote-server scenario. Sprint 6 closes that gap by porting the
HTTP dispatch + worker thread to Nim, gated behind the existing
`-d:modTalksLlm` flag.

### 6.1 Nim-side LLM provider module (`llm_provider.nim`)

- [x] New file `among_them/players/mod_talks/llm_provider.nim`.
      Self-contained — does NOT import or extend
      `src/bitworld/ais/claude.nim`.
- [x] Dependencies: **`std/httpclient` + `std/json` only.** The
      original plan called for `curly` + `jsony`, but `curly`
      isn't in `nimby.lock` and adding it would touch
      `bitworld.nimble`, breaking the scope rule. `std/httpclient`
      is in the stdlib (zero new package surface) and works fine
      against api.anthropic.com / api.openai.com when the binary
      is built with `-d:ssl`. The build script
      (`build_modulabot.py`) adds `-d:ssl` automatically when
      `MODULABOT_LLM=1` is set; a static `{.error.}` in
      `llm_provider.nim` catches accidental hand-builds that
      forget the flag.
- [x] Provider abstraction: `LlmProvider` ref-object with
      `kind` ∈ {`lpkDisabled`, `lpkAnthropicDirect`,
      `lpkOpenAIDirect`}, `apiKey` (private), `model`. `complete`
      proc takes `(role: BotRole, kind: LlmCallKind, contextJson)`
      and returns `LlmCompletion{responseJson, errored, latencyMs}`.
- [x] `newLlmProvider` env-var resolution:
  - [x] `MODTALKS_LLM_DISABLE=1` → `lpkDisabled`.
  - [x] `MODTALKS_PROVIDER_OPENAI=1` + `OPENAI_API_KEY` → OpenAI.
  - [x] `ANTHROPIC_API_KEY` → Anthropic direct (preferred).
  - [x] `OPENAI_API_KEY` (no Anthropic) → OpenAI fallback.
  - [x] Else → `lpkDisabled` (caller logs the warning).
- [x] Tool-use schema construction. `toolSchemaFor(kind)` returns
      the per-`LlmCallKind` Anthropic schema (verbatim from
      `_LLM_TOOL_DEFINITIONS` in the Python wrapper). The OpenAI
      body builder translates the Anthropic shape to OpenAI
      `function.parameters` 1:1.
- [x] Per-call-kind timeouts in `tuning.nim` as
      `LlmTimeout{Hypothesis,Strategize,React,ImposterReact,Accuse,Persuade}Sec`
      + `LlmTimeoutDefaultSec`. `timeoutSecFor(kind)` reads them.
      Mirrors `PER_KIND_TIMEOUT_SECONDS` in the Python wrapper.
- [x] Retry/backoff in `tuning.nim` as `LlmRetryMaxAttempts = 3`
      (1 initial + 2 retries) and `LlmRetryBackoffSecs = [0.5, 1.5]`.
      Retry on 5xx, 429, connection errors, timeouts. Abandon if
      next backoff would push past per-call deadline. Matches
      Sprint 4.4 Python policy.
- [x] Response parsing: `anthropicExtractToolUse` walks the
      Anthropic content array for the first `tool_use` block,
      re-serializes its `input` field as JSON. `openAIExtractToolUse`
      walks `choices[0].message.tool_calls[0].function.arguments`.
- [x] Unit tests in `test/llm_provider_unit.nim` — 28 tests:
      provider resolution across all env-var combinations and CLI
      overrides, model resolution priority, prompt content checks
      (including the §5.3 "no literal 'imposter' in imposter
      prompt" rule), per-kind timeout values match the Python
      wrapper, disabled-provider short-circuits without HTTP.

### 6.2 Worker thread / dispatch (`llm_dispatch.nim`)

- [x] New file `among_them/players/mod_talks/llm_dispatch.nim`.
- [x] Single-agent dispatcher: `LlmDispatcher` ref-object owning a
      `Thread[ptr WorkerCtx]` + two `Channel`s + an `Atomic[bool]`
      shutdown flag. The worker context is heap-allocated via
      `create()` so the Nim ref doesn't have to cross the thread
      boundary (which under ORC requires care that's not worth the
      complexity).
- [x] Lifecycle:
  - [x] `initLlmDispatcher(provider)` allocates context, opens
        channels, spawns the worker.
  - [x] `submit(d, request)` — non-blocking; returns `false` if
        a call is already in flight (single-slot rule
        belt-and-suspenders).
  - [x] `tryGather(d): Option[LlmDispatchResult]` — non-blocking
        poll using `Channel.tryRecv`; clears the in-flight flag
        on success.
  - [x] `closeLlmDispatcher(d)` flips shutdown, sends a sentinel
        request to unblock the worker's `recv`, joins the thread,
        closes channels, frees the context. Idempotent.
- [x] Worker loop body: read request → call
      `provider.complete(...)` (which already does timeout +
      retry from 6.1) → send result. Exits cleanly on shutdown.
- [x] Disabled-provider short-circuit: `submit` against a disabled
      provider immediately enqueues an errored result so
      `tryGather` next tick fires the rule-based fallback. Avoids
      the worker pulling against a no-op `complete`.

### 6.3 `runner.nim` integration + new CLI flags

- [x] In `viewer/runner.nim:runBot` (under
      `when defined(modTalksLlm)`):
  - [x] Constructs `LlmProvider` at startup. If
        `lpkDisabled`, logs `"no llm credentials detected
        (set ANTHROPIC_API_KEY or OPENAI_API_KEY); running
        rule-based"` and skips dispatcher setup. Bot stays in
        rule-based mode (`tickLlmVoting` no-ops because
        `llmEnable` was never called).
  - [x] Constructs `LlmDispatcher` from the provider when enabled
        and calls `llmEnable(bot)`.
  - [x] Per-frame loop after `decideNextMask`:
        drain-first via `tryGather` →  `onLlmResponse`,
        then submit any newly-pending request via
        `llmTakePendingRequest` → `submit`. Drain-first matters
        because applying a result often dispatches a follow-up
        call (hypothesis → accuse) that should fire on the same
        frame.
  - [x] `defer: closeLlmDispatcher(d)` so the worker thread is
        joined cleanly on normal exit and on exception unwind.
  - [x] Logs `"modulabot: llm provider=anthropic_direct
        model=claude-sonnet-4-5"` (or equivalent) at startup so
        operators can confirm the dispatch path before the first
        meeting.
- [x] New CLI flags (in `modulabot.nim`):
  - [x] `--llm-provider:anthropic|openai|disabled` —
        passes through to `newLlmProvider(forceProvider=...)`.
  - [x] `--llm-model:NAME` — passes through to
        `newLlmProvider(modelOverride=...)`. Respects
        `MODTALKS_LLM_MODEL` env var when no flag is supplied,
        same as the Python wrapper.

### 6.4 Bedrock support — DEFERRED until needed

- [ ] **Decision deferred.** Three options when this becomes
      blocking:
  - [ ] **A. Pure-Nim SigV4** (~12 hours). Self-contained but
        duplicates what AWS SDK does. Crypto: HMAC-SHA256 +
        canonical request construction. Doable but tedious.
  - [ ] **B. `aws bedrock-runtime invoke-model` subprocess**
        (~6 hours). Adds AWS CLI as runtime dep. Surprisingly
        clean — call `subprocess.run([aws, ...])` from a worker
        thread, capture stdout JSON.
  - [ ] **C. Skip Nim Bedrock**, leave the Python wrapper as
        the only Bedrock path. Document that direct Anthropic /
        OpenAI work in CLI; Bedrock requires the Python launcher
        / cogames runner.
- [ ] Recommendation: **C until A or B is actually needed.**
      Tournament path is via `cogames/amongthem_policy.py` which
      already does Bedrock. The CLI Sprint-6 path covers
      direct-API providers, which is the more common dev case
      anyway (no AWS SSO refresh, no boto3, no IAM roles).

### 6.5 `quick_player` integration

The current `tools/quick_player.nim` always runs `nim c <file>`
without `-d` defines and only forwards `--address`/`--port`/
`--name`/`--gui`/`--map` to the spawned binary. To make it work
with the LLM build, we have three options:

- [ ] **A. Add `--define:KEY[=VAL]` passthrough to
      `quick_player`.** Most surgical — extends `compilePlayer`
      to accept extra `nim c` args. Caveat: this *does* edit
      `tools/quick_player.nim`, which is outside the
      `among_them/players/mod_talks/` scope rule. Unclear
      whether the user's "don't mess with bitworld outside the
      players directory" includes `tools/`; flag for review.
- [ ] **B. New mod_talks-specific runner script.**
      `among_them/players/mod_talks/scripts/quick_player_llm.sh`
      that wraps the standard build + N-process spawn:
      ```sh
      #!/usr/bin/env bash
      # Builds mod_talks_llm once, then spawns N copies against
      # an existing server. Drop-in alternative to quick_player
      # for the LLM build path.
      ```
      Stays inside the players directory. Slightly less
      idiomatic but respects the scope rule.
- [ ] **C. Don't extend either.** User builds the LLM binary
      manually (`nim c -d:modTalksLlm ...`) and uses bash
      one-liners (`for i in {1..8}; do mod_talks_llm
      --address:... --port:... --name:llm$i & done`) for
      multi-process runs.
- [ ] **Decision pending user input.** Default: ship B (script
      under `mod_talks/scripts/`); defer A unless the user
      explicitly approves a `tools/` edit.

### 6.6 Sprint 6 acceptance

- [ ] Both builds compile clean: rule-based and `-d:modTalksLlm`.
- [ ] Self-consistency parity 500/500 across seeds
      {1, 42, 100, 7777} preserved in non-LLM, LLM (no creds set
      → falls back to disabled), and mock matrices.
- [ ] `llm_unit.nim` continues passing all 56 tests.
      `llm_provider_unit.nim` adds new coverage (target ~15
      tests).
- [ ] **End-to-end remote-server smoke** (the headline test):
      ```sh
      ANTHROPIC_API_KEY=sk-ant-... \
      ./mod_talks_llm \
        --address:my.server.com --port:2000 \
        --name:test --trace-dir:/tmp/run
      ```
      manifest carries `trace_settings.llm_layer_active: true`,
      `events.jsonl` has matching
      `llm_dispatched` / `llm_decision` pairs from the Nim-side
      dispatcher.
- [ ] **`quick_player`-equivalent multi-bot smoke.** Either via
      6.5 option A, B, or C — 4-8 LLM bots running against the
      same server, all dispatching independently, no shared
      thread contention (each is its own process).
- [ ] Documentation:
  - [ ] `README.md` adds the new commands to the runbook.
  - [ ] `DESIGN.md §12` env-var matrix gets the new flags.
  - [ ] `LLM_VOTING.md` Q-LLM2 / §6 amendment notes that the
        Nim-side dispatcher is a parallel implementation of
        Option B's Python concurrency for the CLI path.

### Notes on dependencies and the scope rule

- **Stays inside `players/mod_talks/`:** `llm_provider.nim`,
  `llm_dispatch.nim`, new tests, scripts, doc updates,
  `runner.nim` (already in `players/mod_talks/viewer/`),
  `tuning.nim`, `modulabot.nim` (CLI flag plumbing).
- **Touches outside the scope rule (flag for review before
  landing):** `tools/quick_player.nim` if option 6.5-A is
  chosen. Default: don't.
- **Never touched:** `src/bitworld/ais/*`, `common/`,
  `among_them/sim.nim`. The fact that `claude.nim` exists in
  the shared repo is irrelevant — we re-implement the small
  slice we need.

### Out of scope for Sprint 6 (explicitly)

- Bedrock support in Nim (deferred to a follow-up sprint when
  there's a concrete ask).
- Async/non-blocking HTTP. The single-worker-thread design is
  adequate for one-agent-per-process; if `quick_player` ever
  starts running multiple agents in one process, this might
  need revisiting.
- Provider-side prompt caching (Anthropic's `cache_control`).
  Worth measuring once the eval harness has enough data to
  estimate cost-per-game, but not a Sprint 6 goal.

---

## Parking lot (explicitly out of scope for these sprints)

Items from the report and from inherited modulabot TODOs that
intentionally aren't on this plan yet. Revisit after Sprint 5.

- `_session.json` cross-round lineage file (`TRACING.md §5`).
- `self_color_changed` event round-trip (`TRACING.md §14.9`).
- Reporter detection (who pressed the meeting button).
- Pre-meeting chat capture — depends on whether BitWorld exposes it.
- Counterfactual annotations in trace (which `nearestTaskGoal` tier
  won) — useful but orthogonal to LLM quality.
- Streaming trace (WebSocket proxy) — wait for a real-time harness
  to exist.
- Sprite atlas dedup across batched bots — memory concern, not LLM
  correctness.
- LLM-generated end-of-game `summary.md` — harness-side feature.
- Patching v2 to accept `--seed` for full imposter-path parity —
  only needed if Phase 3 divergences land.

---

## Working notes / updates

Append dated notes as sprints proceed. Keep them short; use a separate
PR for detailed design discussions.

- **2026-04-30** — Plan written. Sprint 1 starting.
- **2026-04-30** — Sprint 1 landed: trace observability (schema v3
  `llm_dispatched` / `llm_decision` / `llm_error` / `llm_layer_active`
  events), manifest flags (`llm_compiled_in`, `llm_layer_active`),
  `LlmState` session counters under `summary_counters.llm`, doc
  sweep across `DESIGN.md`, `LLM_VOTING.md`, `TODO.md`. Parity
  500/500 across seeds {1, 42, 100, 7777} in both `-d:modTalksLlm`
  and non-LLM builds; `validate_trace` passes on captured round
  directories.
- **2026-04-30** — Live Bedrock run (`claude-sonnet-4-5`,
  `us-east-1`, `AWS_PROFILE=softmax`, 8 agents, 2500 ticks)
  successfully emitted `llm_dispatched` + `llm_decision` events
  for every agent. Two follow-ups opened during verification:
  added `MODULABOT_TRACE_DIR` plumbing to the Python wrapper's FFI
  path (it was previously CLI-only), and added
  `LlmRequestSlot.contextBytes` so the decision event records
  dispatch-time size instead of reading the cleared request slot.
  Two pre-existing limitations noted for later: stale manifest on
  truncated runs, and `validate_trace` not tolerating truncated
  rounds.
- **2026-04-30** — Sprint 2 landed: speaker attribution via pip
  detection, self-location keyframes, alibi log wiring, ejection
  detection. Latent bug caught while wiring 2.4: the pre-existing
  MeetingEvent-append path at `bot.nim:425` was unreachable in
  practice because the result frame is interstitial and
  `parseVotingScreen` clears `voting.active` before control
  exits the interstitial branch. Fix extracted `finalizeMeeting`
  proc, moved the primary append site into the interstitial
  branch on the voting-active true→false transition, kept the
  original block as a belt-and-suspenders path. Parity 500/500
  across seeds {1, 42, 100, 7777} in both builds. Live Bedrock
  smoke confirmed schema-v3 manifest carries
  `speaker_attribution: "color_pip"`.
- **2026-04-30** — Sprint 3 landed: mock-LLM harness wired into
  `tickLlmVoting` + parity harness, `llm_unit.nim` with 51 tests
  covering pure helpers + mock loader + trim helper, context
  builders refactored to return `JsonNode` so a 7-tier trim
  policy can apply before serialization. Parity 500/500 across
  seeds {1, 42, 100, 7777} × matrices {non-LLM, LLM, mock-basic,
  mock-errored}. Two reference fixtures shipped at
  `test/fixtures/`. Design choice: mock pump runs in Nim rather
  than Python — keeps `parity.nim` self-contained and exercises
  the same code path as live runs minus the HTTP round-trip.
- **2026-04-30** — Sprint 4 landed (4.6 explicitly deferred):
  removed `_AnthropicController._lock` and added a per-policy
  `ThreadPoolExecutor` with dispatch / gather phases.
  Per-call-kind timeouts in Python; stale-response detection in
  Nim drops responses that arrive after the relevant stage has
  moved on. Anthropic tool-use with one tool per
  `LlmCallKind` eliminates schema-in-prompt parse drift. Retry
  policy with exponential backoff (max 2 retries) for 5xx /
  429 / connection errors only. UTF-8 transliteration in
  `clampChat` maps smart quotes / em-dash / ellipsis / common
  punctuation to ASCII so the BitWorld PixelFont renders chat
  cleanly. Live Bedrock smoke: p50 latency 9.2 s with 8
  concurrent agents — **3-4× faster than the Sprint 1 serial
  baseline (~33 s)**, validating the concurrency goal.
- **2026-04-30** — Sprint 5 landed (5.2 empirical campaign and
  5.3 OpenAI live verification both deferred). Prompt-eval
  harness ships at `tools/llm_prompt_eval.py` with a complete
  capture-→-replay-→-score pipeline; verified end-to-end against
  a live Bedrock capture (8 contexts) replayed through the basic
  mock fixture. `LlmPersuadeEnabled` runtime-toggleable via
  `MODTALKS_PERSUADE`. `_OpenAIController` added as an
  isomorphic sibling to `_AnthropicController` with provider
  selector `_build_llm_controller`. Manifest lineage extended:
  `harness_meta.llm_provider`, `.llm_model`, `.llm_persuade`,
  `.llm_disabled` auto-populated by the launcher. All 14
  `tuning.nim` public constants now mirrored into
  `tuning_snapshot.nim`; `trace_smoke.sh` grep step warns on
  drift. Final parity: 500/500 across seeds {1, 42, 7777} in
  non-LLM, LLM, and mock-LLM matrices.
- **2026-05-01** — Sprint 6 planned (not started). Triggered by
  the realisation that the LLM voting layer doesn't work with
  remote servers or `quick_player`: the dispatch loop only
  exists in the Python wrapper. Sprint 6 ports HTTP dispatch +
  worker thread to Nim under
  `among_them/players/mod_talks/llm_provider.nim` /
  `llm_dispatch.nim`, gated behind `-d:modTalksLlm`. Scope rule
  for the sprint: no edits to shared bitworld files
  (`src/bitworld/ais/*`, `common/`, `among_them/sim.nim`).
  Direct Anthropic + OpenAI providers in scope; Bedrock
  deferred (Python wrapper still owns Bedrock). Tournament
  path via `cogames/amongthem_policy.py` is unchanged. Effort
  estimate: ~17 hours / 2 days.
- **2026-05-01** — Sprint 6.1 + 6.2 + 6.3 landed.
  `llm_provider.nim` (~570 LOC) implements direct Anthropic +
  OpenAI HTTP dispatch with tool-use forced via `tool_choice`,
  per-call-kind timeouts, retry/backoff. Switched to
  `std/httpclient` (stdlib) instead of `curly` so no edits to
  shared `nimby.lock` / `bitworld.nimble` were needed — `-d:ssl`
  is wired into `build_modulabot.py` automatically when
  `MODULABOT_LLM=1` is set, with a static `{.error.}` guard for
  hand-builds that forget the flag. `llm_dispatch.nim` (~190
  LOC) wraps it with a single worker thread + two `Channel`s,
  one-agent-per-process. `viewer/runner.nim` constructs both at
  startup, calls `llmEnable(bot)`, runs a drain-first
  per-frame poll loop, joins the worker on exit. New CLI flags
  `--llm-provider` / `--llm-model`. Both builds compile clean.
  Parity 500/500 across {non-LLM, LLM-no-creds, mock-LLM} ×
  seeds {1, 42, 7777}. 28 new unit tests in
  `test/llm_provider_unit.nim` plus existing 56 still pass.
  CLI smoke confirms `mod_talks_llm` boots, detects creds,
  prints `modulabot: llm provider=anthropic_direct
  model=claude-sonnet-4-5`. End-to-end live verification (Sprint
  6.6) deferred to the user's first non-local run with real
  credentials.

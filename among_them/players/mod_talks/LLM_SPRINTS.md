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

### 5.1 Prompt-eval harness

- [ ] Build `tools/llm_prompt_eval.py` that:
  - [ ] Replays captured `llm_dispatched` event contexts (from Sprint
        1) against a candidate prompt.
  - [ ] Scores each response on mechanical checks: valid JSON, color
        in `living_players`, `best_target` not in `safe_colors`, chat
        length within `LlmMaxChatLen`, mention count of AI-revealing
        phrases (`"as an AI"`, `"I'm a language model"`, etc.).
  - [ ] Emits a summary CSV plus per-sample diff.
- [ ] Capture ~200 context examples across multiple games as the
      eval set. Version the set so prompt changes can be compared.
- [ ] Separate sets per `LlmCallKind`.

### 5.2 Enable persuasion, measure

- [ ] Flip `LlmPersuadeEnabled = true` in `tuning.nim`.
- [ ] Run 20+ games with and without persuasion; compare win rate
      (crewmate) and chat-sent volume.
- [ ] If persuasion raises win rate, leave on. If it lowers win rate
      or has no effect, leave off and document why.

### 5.3 Multi-provider config

- [ ] Add `LlmState.config: LlmConfig` with fields per
      `LLM_VOTING.md §7.6`.
- [ ] Populate from env vars at Python-side init; plumb model name
      into the context (already done indirectly via `MODTALKS_LLM_MODEL`)
      and into `tuning_snapshot.nim` for manifest lineage.
- [ ] Test a second provider end-to-end (OpenAI or Gemini via the
      `src/bitworld/ais/` wrappers).

### 5.4 Tuning-snapshot entries for LLM knobs

- [ ] Add `LlmAccuseThreshold`, `LlmVoteThreshold`,
      `LlmChatReactionCooldownTicks`, `LlmMaxChatLen`,
      `LlmMaxContextLen`, `LlmPersuadeEnabled` to
      `tuning_snapshot.nim` so they appear in every trace manifest.
- [ ] Verify with a lineage-tracking grep: every policy-module
      `const` cross-checks against the snapshot.
- [ ] Add the missing grep step to `tools/trace_smoke.sh` — this
      closes the open TODO from `TRACING.md §10.3` /
      `TODO.md "tuning_snapshot exhaustiveness check"`.

### 5.5 Sprint 5 acceptance

- [ ] Prompt-eval harness runs against a captured fixture and reports
      a pass/fail rate per `LlmCallKind`.
- [ ] At least one prompt change has been A/B tested with
      quantitative results recorded in a sprint note.
- [ ] Multi-provider path has been demonstrated (one run per
      provider archived).
- [ ] Every LLM tuning const appears in `manifest.tuning_snapshot`.

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

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

### 2.1 Speaker attribution (Q-LLM9 prerequisite)

- [ ] Implement speaker-pip detection at `x < VoteChatTextX = 21` for
      each chat line parsed in `voting.nim`.
- [ ] Return speaker color index (or -1 if detection failed) alongside
      each line in `voting.chatLines` — needs a shape change from
      `seq[string]` to `seq[tuple[speaker: int, text: string]]` or a
      parallel `seq[int]`.
- [ ] Thread through `llm.nim:ingestChatLines` so
      `LlmChatEntry.speakerColor` is populated.
- [ ] Flip `trace_settings.speaker_attribution` from `"none"` to
      `"color_pip"` in the manifest.
- [ ] `chat_observed` events gain a real `speaker` field instead of
      `null`.
- [ ] Own-chat dedup in `llm.nim:ingestChatLines` (lines 121–131)
      switches from substring matching to `speakerColor == selfColor`.
      Keep the substring check as a fallback when detection fails.
- [ ] Unit test: capture a voting-screen frame with multiple known
      speakers and verify the detector attributes each line correctly.

### 2.2 Self-position keyframes → `my_location_history`

- [ ] Add `Memory.selfKeyframes: seq[tuple[tick: int, roomId: int]]`
      (size cap ~64, ring-buffer trim).
- [ ] Append in `bot.nim` or `actors.nim` on room transitions
      (`roomIdAt(playerWorldX, playerWorldY) != last room`).
- [ ] Round reset clears it; meeting boundary does NOT trim — the
      imposter needs the full pre-meeting history to fabricate alibis.
- [ ] Replace the hardcoded empty arrays at `llm.nim:389` and `:431`
      with a serializer that emits
      `[{"room": "<name>", "tick_relative": <int>}, ...]` sorted
      newest→oldest, capped at the last 20 entries.
- [ ] Unit test covering the serializer + the keyframe logger.

### 2.3 Alibi log wiring

- [ ] Wire `memory.appendAlibi` from `tasks.nim` at the co-visibility
      edge: a task-completion icon flashes in the same frame (or
      within N ticks) as a specific crewmate being visible to us.
- [ ] Matches `DESIGN.md §13.1` semantics.
- [ ] Verify dedup rules in `memory.nim` fire correctly (no duplicate
      alibis within `MemoryAlibiDedupTicks`).
- [ ] Parity: self-consistency stays 100% after wiring.
- [ ] Resulting `alibis` array in `llm.nim:buildHypothesisContext`
      should be non-empty in any round where the bot saw a crewmate
      finish a task.

### 2.4 Ejection detection → `MeetingEvent.ejected`

- [ ] Perception pass during the post-vote cutscene to read the
      ejected player's name (or detect "skipped" if nobody ejected).
- [ ] Populate `MeetingEvent.ejected` at `bot.nim:437` instead of the
      hardcoded `-1`.
- [ ] Downstream: `llm.nim:235–238` already serializes this; no LLM-side
      change needed once the field is populated.
- [ ] Reporter detection (who called the meeting) is **deferred** —
      lower leverage than ejection outcome, separate perception work.
      Track in TODO.md, not this sprint.

### 2.5 Sprint 2 acceptance

- [ ] `trace_settings.speaker_attribution == "color_pip"` in manifests.
- [ ] A live game produces non-empty `my_location_history` in imposter
      contexts (verify in captured `llm_dispatched` event context).
- [ ] A live game produces non-empty `alibis` in at least one
      hypothesis call context when the bot observed a task-completion.
- [ ] `prior_meetings[].ejected` is a color name (not null) for every
      past meeting whose ejection was visible to the bot.
- [ ] Self-consistency parity still 100%.

---

## Sprint 3 — Make it regression-safe

Goal: refactoring `llm.nim` is currently high-risk because nothing
tests it. Fix that before any prompt engineering sprint or provider
swap.

### 3.1 Mock LLM mode — CLI flag + FFI hook

- [ ] Add `--llm-mock:PATH` to `modulabot.nim` CLI parser.
- [ ] When set, the Nim side reads responses from a JSONL file in
      order. Each line: `{"kind": "hypothesis"|..., "response": {...},
      "errored": bool}`. Nim consumes the next matching entry when
      Python calls `modulabot_take_llm_request` OR when a stubbed
      internal dispatcher fires.
- [ ] Preferred implementation: add a `modulabot_set_llm_mock_path`
      FFI entry point; Python reads the file and feeds responses via
      the existing `modulabot_set_llm_response` path. Keeps the mock
      logic on the Python side where JSON file handling is trivial.
- [ ] Document the mock JSONL schema in `LLM_VOTING.md §11`.

### 3.2 Parity harness `--mode:llm-mock`

- [ ] Add a mode to `test/parity.nim` that runs two bot instances with
      the same seed and the same mock JSONL, asserting mask equality.
- [ ] Acceptance: 100% self-consistency on a 500-frame replay with
      5+ meetings.
- [ ] Also add a degraded-mock test: every response errored → mask
      sequence must equal the non-LLM baseline (fallback correctness).

### 3.3 Unit tests for `llm.nim`

- [ ] New file: `test/llm_unit.nim`.
- [ ] Fixtures: canned JSON responses for each `LlmCallKind`
      (well-formed, missing fields, extra fields, wrong types,
      malformed JSON, empty string).
- [ ] Tests:
  - [ ] `parseSuspects` sorts and filters correctly.
  - [ ] `applyHypothesisResponse` transitions stage correctly by
        confidence and by presence of safe-color suspects.
  - [ ] `applyStrategizeResponse` rejects a `best_target` in
        `safe_colors`.
  - [ ] `clampChat` truncates at word boundary and strips control
        characters (verify current behavior, decide if non-ASCII
        handling needs changing — see Sprint 4 §4.4).
  - [ ] `colorIndexByName` is case-insensitive and whitespace-tolerant.
  - [ ] `onMeetingEnd` resets state without clobbering `enabled`.
- [ ] Build and run via `tools/trace_smoke.sh` or a new
      `tools/llm_unit.sh`; add to CI loop.

### 3.4 Context-size enforcement

- [ ] In `dispatchCall`, after building `contextJson`, check against
      `LlmMaxContextLen` and `_LLM_CONTEXT_BUFFER_SIZE`
      (16384 in Python).
- [ ] If over budget, trim in order: oldest sightings → older chat
      lines → prior meeting chat summaries. Re-measure after each
      trim pass.
- [ ] If still over budget, emit an `llm_error` (from 1.2) with
      `reason: "context_overflow"` and fall back immediately (no
      dispatch).
- [ ] Regression test: generate a synthetic memory log with 1000+
      sightings and verify dispatch succeeds (trimmed) rather than
      blowing past the FFI buffer.

### 3.5 Sprint 3 acceptance

- [ ] `nim r test/parity.nim --mode:llm-mock --replay:<capture>
      --llm-mock:<fixture>` passes with 100% mask agreement.
- [ ] `nim r test/parity.nim --mode:llm-mock --replay:<capture>
      --llm-mock:<all-errored-fixture>` produces masks identical to
      the non-LLM baseline.
- [ ] `nim r test/llm_unit.nim` passes all subtests.
- [ ] `tools/trace_smoke.sh` (or equivalent) runs the full new suite.

---

## Sprint 4 — Make it fast and robust

Goal: the current Python dispatch path serializes every agent's LLM
call behind a single lock. An 8-agent batch with 2 s provider latency
wastes 14 s of wall time per frame. Also: retries, schema enforcement,
prefix rename.

### 4.1 Concurrent provider dispatch

- [ ] Replace the single-lock `_AnthropicController.complete` with a
      concurrent dispatcher: thread pool (e.g. `concurrent.futures.
      ThreadPoolExecutor` with `max_workers = num_agents`) or an
      asyncio event loop.
- [ ] `_service_llm` submits a future per pending request; gathers
      results before returning from `step_batch`.
- [ ] Preserve the "one request in flight per agent" guarantee via
      the Nim-side slot semantics — Python just parallelizes the
      per-agent HTTP calls.
- [ ] Measure: p50 / p99 `step_batch` latency with 8 agents before
      and after. Record in a benchmark note.

### 4.2 Per-call-kind timeouts + stale-response drop

- [ ] Move timeout config into `tuning.nim` as a table keyed by
      `LlmCallKind`: hypothesis/strategy=2000 ms, react/imposter_react=
      1500 ms, accuse/persuade=1000 ms. Match `LLM_VOTING.md §9`.
- [ ] Plumb the per-kind timeout to Python through a new FFI entry
      point (or bake into the request slot payload as a field).
- [ ] In `onLlmResponse`, if `stage` has moved on from the one
      recorded in `request.stage` at dispatch time, treat as stale:
      emit `llm_error{reason:"stale"}` and do not apply. This lets
      Sprint 1's `llm_decision` event accurately measure the cost of
      slow calls.

### 4.3 Anthropic tool-use / structured output

- [ ] Replace the schema-in-prompt pattern with Anthropic
      `tools=[...]` + `tool_choice={"type":"tool","name":"<kind>"}`.
- [ ] One tool definition per `LlmCallKind`. Translate the JSON
      Schema fragments already documented in `LLM_VOTING.md §5.4`.
- [ ] `_strip_markdown_code_fence` becomes unnecessary for the happy
      path — keep as a fallback when the model returns text (rare with
      tool-use, but seen in practice).
- [ ] Measure malformed-response rate before/after in
      `llm_error.reason:"parse"` counts.

### 4.4 Retry + exponential backoff

- [ ] Distinguish retryable errors (429, 5xx, timeout) from fatal
      (4xx auth, malformed request).
- [ ] Retry policy: max 2 retries, backoff 500 ms → 1500 ms. Do NOT
      retry past the stage timeout.
- [ ] `llm_error` emitted per final failure (not per retry).

### 4.5 Non-ASCII chat handling

- [ ] Decision: transliterate (smart quotes → ASCII) or widen to UTF-8?
      Depends on what the BitWorld chat renderer accepts. Investigate
      first; then implement.
- [ ] Update `llm.nim:clampChat` accordingly.
- [ ] Unit test coverage: smart quote, em-dash, ellipsis, emoji.

### 4.6 FFI / binary prefix rename

- [ ] Rename `modulabot_*` exports to `mod_talks_*` (new symbols;
      old symbols kept as deprecated aliases for one release cycle
      if needed).
- [ ] Rename binary: `mod_talks` (CLI), `libmod_talks.{dylib,so,dll}`
      (library).
- [ ] Update `cogames/amongthem_policy.py` call sites and
      `_library_name()`.
- [ ] Update `DESIGN.md §1, §6, §6 note` to reflect the rename.

### 4.7 Sprint 4 acceptance

- [ ] Benchmark: 8-agent `step_batch` p99 latency improves by ≥ Nx
      (record actual factor; realistic target 4–6x at ~2 s provider
      median).
- [ ] Manifest records `context_bytes` and `response_bytes` per
      `llm_decision` (from Sprint 1) so we can see
      prompt/response distribution across a run.
- [ ] `llm_error.reason:"parse"` events drop to near zero after
      tool-use rollout.
- [ ] All references to `modulabot_` in source and docs are
      updated or explicitly marked as legacy aliases.

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

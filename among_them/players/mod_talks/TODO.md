# mod_talks — TODO

mod_talks is a fork of modulabot that adds LLM-powered chatting and
reasoning during the voting phase. This file tracks work that's
*not yet done*: items inherited from modulabot at fork time that
remain open, plus inherited TODOs that survived the LLM sprints.

For LLM-layer work, see `LLM_SPRINTS.md` — the source of truth for
what shipped, what's deferred, and what's cancelled across Sprints 1-5.

Last audit: 2026-05-01.

---

## LLM voting integration

**Shipped through Sprint 5.** Tracked sprint-by-sprint with checkboxes
in `LLM_SPRINTS.md`. Two follow-ups remain deferred (need access /
budget, not code):

- **40+ game persuasion A/B campaign** (Sprint 5.2) — infrastructure
  ready (`MODTALKS_PERSUADE` runtime toggle); needs token budget and
  manual win-rate analysis.
- **Live OpenAI verification** (Sprint 5.3) —
  `_OpenAIController` skeleton ships + provider selector wired;
  needs `OPENAI_API_KEY` for end-to-end smoke.

Cancelled:

- **Sprint 4.6 FFI prefix rename** — high-churn refactor across
  Python wrapper / build script / tests for no behaviour change.
  See `DESIGN.md §1.5` for full rationale. Revisit only when a
  real name collision appears.

Add new LLM-adjacent TODOs to `LLM_SPRINTS.md`, not here, unless
they are cross-cutting with inherited modulabot work.

---

## v1.1 Deferred (near-term)

These survived Sprint 1-5. The trace schema, types, and
surrounding infrastructure are in place; the missing piece is the
caller / writer in each entry.

### `MeetingEvent.reporter` always -1

The meeting-event struct now populates `ejected` correctly via
`voting.detectResultEjection` (Sprint 2.4 shipped), but `reporter`
remains hardcoded to -1 in `bot.finalizeMeeting`. Filling it in
requires a perception pass during the meeting-call intro animation
to identify who pressed the button (or who found the body).

Ref: `bot.nim:finalizeMeeting`, `types.nim:MeetingEvent`

### Frames-dump rotation / retention policy

The trace writer keeps all frames dumps forever — roughly
117 MB/game uncompressed (~5–10 MB gzipped). There is no sweep.
A long training run (e.g. 50 games) accumulates ~6 GB raw /
~250 MB gzipped before any pruning. The design specifies a
cron-style sweeper that keeps the last K=10 games, with a
`RETAIN` sentinel file to pin specific runs. Nothing in
`trace_smoke.sh` or elsewhere implements this today.

Ref: `TRACING.md §14.6`

### `_session.json` cross-game lineage file

The design calls for an optional `_session.json` at
`<trace-root>/<bot-name>/<session-id>/` containing rolled-up
counters and a list of round IDs for the session. Not written
anywhere today. Useful once the harness starts training across
many games and needs a session-level index without parsing every
individual round file.

Ref: `TRACING.md §5`

### `self_color_changed` trace event

If `identity.selfColor` can change mid-session (e.g. after a
reconnect into a new lobby), the trace has no event for it. A
`self_color_changed` event was noted as a v1.1 addition. Until
this is added, any harness that caches `self_color` from the
manifest may silently use a stale value.

Ref: `TRACING.md §14.9`

---

## Stale manifest on truncated runs (Sprint 1 limitation)

Manifest is rewritten only at `endRound`. In the FFI path,
`modulabot_enable_llm` fires on the first frame (after the
initial manifest is already on disk), so until the round closes
with a `game_over` text the on-disk manifest shows
`trace_settings.llm_layer_active: false` and zero
`summary_counters.llm`. Emitted events are correct; only the
snapshot is stale.

Fix options:

- Add a `modulabot_close_trace` FFI entry Python calls on
  shutdown.
- Periodic manifest rewrite every N ticks.
- Include `summary_counters` in every N-th snapshot file.

Revisit when a harness consumer is actually blocked by this.

Ref: `LLM_SPRINTS.md §1` working notes

---

## `validate_trace` rejects truncated rounds

The "unclosed meetings at end of round" rule fails whenever a
game is cut short with `--max-steps` mid-meeting. Not a Sprint 1
regression — pre-existing behaviour. Consider a
`--allow-truncated` validator flag, or a separate
`round_truncated` event emitted by a process-exit hook.

Ref: `test/validate_trace.nim`, `LLM_SPRINTS.md §1` working notes

---

## Open questions / potential bugs

These are correctness concerns that were flagged but not resolved.

### Scan-ordering parity risk on teleport

`DESIGN.md §4` has a flagged open question (marked ⚠):

> "Does the v2 ordering actually matter? The current flow is 'score with
> last-frame's sprite matches → re-localize → re-scan with new camera'.
> Inverting could degrade scan quality on teleport. We may need a two-pass:
> cheap re-scan on new camera, then localize again."

Never empirically resolved. Parity was declared sufficient at
87% (deterministic up to frame ~2508) without specifically
exercising teleport-heavy replays. If scan quality regresses
after a vent or telepad transition, this is the first place to
look.

Ref: `DESIGN.md §4`

### `TeleportThresholdPx` was never empirically validated

`DESIGN.md §5` says this constant "should be set during the
parity bake — too tight wastes scans every frame, too loose lets
stale matches poison post-vote frames." The parity bake was
completed and declared sufficient, but there is no record that
this knob was actually tuned. The current value may be the
initial guess rather than an empirically chosen one.

Ref: `DESIGN.md §5`

---

## Phase 3 — Divergence (inherited from modulabot, partly subsumed by Sprints 2-5)

`DESIGN.md §11 Phase 3` originally listed five priority directions.
After the LLM sprints landed, here's the updated status:

### 1. Better evidence model

Replace the current binary suspicion tiers (`witnessed_kill` vs
`near_body`) with quantitative suspicion scores.

**Current status:** Likely subsumed by the LLM hypothesis path
(Sprint 1-2). The crewmate's `hypothesis` call already returns
continuous likelihoods 0..1 from the model. A separate rule-based
quantitative suspicion score may not be worth doing as a separate
pass — its job is now done by the LLM with `Memory` access.

### 2. Smarter imposter chat

**During voting:** addressed by Sprint 1-4's `imposter_react` LLM
path. Tool-use eliminates parse drift; `full_chat_log` context
prevents contradicting prior claims.

**Pre-meeting (gameplay-phase) chat:** still rule-based. Things
like "fake-task callouts" timed to task animations remain future
work. Lower priority than voting-phase quality.

### 3. Real ghost behavior

Ghosts still just continue doing tasks. Independent of LLM work.
Real options:

- Vent-watching: observe imposter vent usage and record it
  (useful for post-game trace analysis even if the ghost can't
  vote).
- Escorting suspects: shadow a suspected imposter to generate
  alibi-disproving sightings.
- Emergency-button awareness: move to visible locations when a
  meeting is expected.

### 4. Vote bandwagon detection

**Reactive bandwagon participation:** the imposter LLM
`strategize` path supports `strategy: "bandwagon"`. The crewmate
side does not (intentionally — preserves the evidence-only voting
rule). Logging the pattern in trace events for post-hoc analysis
remains untracked.

### 5. `--seed` flag for v2

Patch `evidencebot_v2` to accept a `--seed` flag. Currently v2
seeds its RNG from clock+pid, so parity tests can only exercise
the crewmate code path. With a fixed seed, imposter-path parity
becomes testable. Useful only if a non-LLM strategy change ever
lands.

Ref: `DESIGN.md §11 Phase 3`, `test/parity.nim --vs:v2`

---

## Future / v2 (longer horizon)

Items from `TRACING.md §15` and the decisions log that are further
out.

### Counterfactual annotations in trace

Record which tier of `nearestTaskGoal` was considered but
rejected at each decision point. The goal struct already carries
enough state for offline reconstruction; the trace just doesn't
surface it. Would make the trace much more useful for post-hoc
policy analysis and debugging.

Ref: `TRACING.md §15`

### Streaming trace (WebSocket proxy)

A WebSocket proxy that tails the JSONL trace in real time for
live harness dashboards. Not needed until a real-time training
loop exists.

Ref: `TRACING.md §15`

### Sprite atlas dedup across bots in batch training

Each `Bot` instance in a batch training run holds its own full
copy of the sprite atlas. For large batches this is a meaningful
memory cost. The Q10 decision was "one `Sprites` per `Bot` for
v0, revisit after parity if memory is an issue." Parity was
declared but memory was never measured under batch load.

Ref: `DESIGN.md §10 Q10`

### LLM-targeted `summary.md` per game

An end-of-game summary in natural language, auto-generated from
the trace, for feeding into an LLM training or eval loop.
Harness-level work; nothing in-bot is needed first.

Ref: `TRACING.md §15`

---

## Blocked on external dependencies

### CoGames tournament submission

The submission infrastructure (`cogames/`) is ready and the
pre-flight checklist in `cogames/README.md` passes. The only
blocker is that no `among-them` season exists in
`cogames season list` yet — only `beta-cvc` and
`beta-teams-tiny-fixed` are live. Watch the CoGames season list;
submit as soon as an AmongThem season appears.

Ref: `cogames/README.md` (pre-flight checklist)

---

## Recently shipped (audit history)

Sprint sequence highlights, in case you're searching for an old
TODO that's now done:

- **Sprint 1** — LLM trace observability, FFI trace plumbing.
- **Sprint 2.1** — Speaker pip detection. (Was: "Chat speaker
  attribution `speaker: null` hardcoded".)
- **Sprint 2.2** — Self-position keyframes for
  `my_location_history`.
- **Sprint 2.3** — Alibi log wired from `tasks.nim`. (Was:
  "Alibi log wiring (`memory.appendAlibi` has no callers)".)
- **Sprint 2.4** — `MeetingEvent.ejected` populated via
  `detectResultEjection`. (Was: "MeetingEvent.ejected always
  -1".)
- **Sprint 3** — Mock LLM harness, `llm_unit.nim` (56 tests),
  context-trim policy.
- **Sprint 4** — Concurrent dispatch (3-4× speedup), per-call
  timeouts, tool-use, retries, UTF-8 transliteration.
- **Sprint 5** — Prompt-eval harness, persuasion runtime toggle,
  OpenAI controller skeleton, manifest provider lineage,
  `tuning_snapshot` exhaustiveness check in `trace_smoke.sh`.
  (Resolved: "tuning_snapshot exhaustiveness check is manual /
  absent".)
- **Doc sweep (2026-05-01)** — `viewer/runner.nim` header
  comment now reflects shipped GUI; phase numbering in
  `DESIGN.md §11` reconciled. Stale
  `bot.interstitial.voting_screen` branch-id reference removed
  from `TRACING.md §8.2` and `validate_trace.nim` (the path
  delegates to `decideVotingMask` which fires its own
  `voting.*` ids).

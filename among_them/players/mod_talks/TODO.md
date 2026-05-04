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

### Live-game smoke surfaced two real bugs (2026-05-01)

First end-to-end smoke run with 8 `mod_talks_llm` bots vs. a
local `among_them` server (Bedrock provider, `voteTimerTicks=600`).
Trace evidence preserved at `/tmp/mod_talks_live/traces/` from
session `2026-05-01T19-04-29Z`. Both bugs predate Sprint 6 and
were merely surfaced by the live LLM dispatch path.

#### Bug 1 — `parseVotingScreen` fails 2 ticks after meeting opens

Symptom: at meeting open, every bot fires one decision at branch
`voting.cursor.move` (mask=left, "voting cursor to unknown"),
then on the next frame falls to `bot.interstitial.role_reveal`
with garbled OCR text (e.g. `.,~//j.//~.j/]`) and stays there
for the entire meeting + post-meeting period. `mask=idle` for
60+ seconds.

The user's earlier observation of bots "all moving left, then
left/still/right after the meeting" is consistent with: the
voting screen briefly registers (one-tick mask=left for the
cursor), then `parseVotingScreen` returns false, the
interstitial detector keeps firing on the discussion-table
backdrop, and `decideNextMaskCore` returns 0 every frame. Any
on-screen drift the user sees post-meeting is residual server-
side physics, not bot input.

Critical downstream effect: because `tickLlmVoting` is gated on
`bot.voting.active`, a failed `parseVotingScreen` means the LLM
state machine never advances past `lvsFormingHypothesis`. The
hypothesis call still completes (~9 s on Bedrock) and
`onLlmResponse` runs, but the bot is stuck on the wrong branch
so no chat ever gets routed to `pendingChat`.

Likely culprits, in order of suspicion:
1. **Voting-grid pixel layout drift.** `voting.nim`'s grid
   constants (`VoteCellW=16`, `VoteCellH=17`, `VoteStartY=2`,
   `VoteSkipW=28`) may not match the current `among_them/sim.nim`
   render. Validate by capturing a frame at meeting tick and
   running it through `parseVotingScreen` in isolation.
2. **Interstitial detector false-positive on the discussion-
   table backdrop.** `isInterstitialScreen` uses a black-pixel
   ratio threshold; the discussion table render may push that
   ratio above the gate even though the voting grid is the
   actual content.
3. **Frame channel desync.** Less likely given the bots all
   parsed pre-meeting frames correctly, but worth checking with
   `MODULABOT_TRACE_LEVEL=frame` to dump every frame.

Reproduction recipe (`among_them/players/mod_talks/scripts/quick_player_llm.sh`
+ server with `voteTimerTicks:600`, `MODULABOT_TRACE_DIR` set,
Bedrock creds available, body manually triggered).

#### Bug 2 — medium-confidence hypothesis produces no chat

By design, `applyHypothesisResponse` (`llm.nim:818`)
transitions to `lvsListening` on medium/low confidence with no
chat queued. Reactions only fire when other players speak
(`hasUnreadChat` gate at `llm.nim:1170`). With 8 mod_talks
bots all forming medium-confidence hypotheses, no one breaks
the silence: 4/8 stayed silent the entire meeting in the
2026-05-01 smoke. The two crewmates with high-confidence
hypotheses and the two imposters (preemptive strategize)
chatted; everyone else was mute.

Combined with the body-discovery template firing identically
for all 8 bots at meeting open, the bot population reads as
"all preprogrammed" even though half the participants did
produce LLM-generated chat.

This is partly a tuning issue (`VoteListenTicks=100`, ~4.2 s
@ 24 fps, is shorter than Bedrock P50 latency ~9 s — by the
time the hypothesis returns, the bot has already committed
to a vote) and partly a design choice (hypothesis schema in
`LLM_VOTING.md §307` has no `chat` field). Both knobs are
worth reconsidering. Candidate fixes:

- Add `opening_statement` (string, optional) to the
  hypothesis tool-use schema; queue it via `queueOurChat` in
  `applyHypothesisResponse` for medium/low confidence.
- OR: dispatch a `react` call once on the
  `lvsFormingHypothesis → lvsListening` transition, bypassing
  the `hasUnreadChat` gate so the first speaker is bootstrapped.
- OR: bump `VoteListenTicks` to ≥ Bedrock P95 latency and rely
  on the existing react loop to keep the meeting alive
  (assumes Bug 1 is fixed first — without working
  parseVotingScreen, more listen time doesn't help).

Briefly experimented with the `VoteListenTicks: 100→250` bump
during the smoke; reverted because it was speculative pre-
investigation. Mention it in the final fix design.

Ref: `llm.nim:818`, `voting.nim:30`, trace session
`/tmp/mod_talks_live/traces/2026-05-01T19-04-29Z`

---

## Sprint 7 — remaining work (2026-05-01)

### LLM dispatch blocks the websocket (discovered during Sprint 7)

Bedrock calls via `startProcess("aws", ...)` take 5-9s. Blocking
the frame loop for that long overflows the server's websocket
send buffer (~170 frames × 8KB > OS buffer). The server drops the
player, and `receiveMessage(-1)` hangs forever.

Three approaches tried:

1. **Synchronous dispatch** (italkalot pattern): blocks inside
   `decideNextMask`. LLM response IS delivered but the websocket
   dies. italkalot survives because its OpenAI/curly calls are
   ~1-3s (in-process HTTP, no `fork()`).
2. **Threaded Channel dispatch**: `Channel.tryRecv` under
   `--mm:orc` never delivers results in the bot binary (despite
   working in a standalone test). Multiple configurations tried:
   `create()`-allocated struct, module-level globals,
   `{.threadvar.}` (wrong — per-thread copies), atomic flag +
   blocking `recv`. None worked.
3. **Subprocess polling**: `startProcess` + `process.running()`
   polled each frame. Frame loop stays alive (1970+ frames at
   22fps). Most promising but needs live verification with a
   meeting.

Current implementation: subprocess polling (#3) in
`llm_dispatch.nim`. Next step: run a longer test (5+ min) that
triggers a meeting to confirm `tryGather` returns the result.

Ref: `llm_dispatch.nim`, `LLM_SPRINTS.md §7`

### Orphan bot processes survive kill

When `quick_player_llm.sh`'s trap fires or when `pkill` targets
bot processes, some mod_talks_llm processes survive and continue
occupying server player slots. This makes subsequent test runs
join servers with stale bots. Workaround: `pkill -9 -f
mod_talks_llm` before each run. Root cause likely the shell
trap not reaching all child PIDs, or the `aws` subprocess
surviving the parent's death.

Ref: `scripts/quick_player_llm.sh`

### `parseVotingCandidate` join-order bug also affects other bots

The `slots[i].colorIndex != i` assumption that was fixed in
mod_talks also exists in `italkalot.nim:1944` and
`nottoodumb.nim` (same line). Those bots will fail to parse the
voting screen on non-fresh servers. Out of scope for mod_talks
but worth noting.

Ref: `italkalot.nim:1944`, `nottoodumb.nim`

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

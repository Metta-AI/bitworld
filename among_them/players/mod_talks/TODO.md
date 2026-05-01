# mod_talks — TODO

mod_talks is a fork of modulabot that will add LLM-powered chatting and
reasoning during the voting phase. This file tracks work inherited from
modulabot at fork time, plus new work specific to the LLM integration.

Deferred work, open questions, and future directions gathered from DESIGN.md,
TRACING.md, and a doc/code scan on 2026-04-30. Items are grouped by theme and
roughly ordered by priority within each section.

---

## LLM voting integration (in progress)

Tracked as a sprint plan with individual checkboxes in
`LLM_SPRINTS.md`. High-level status:

- **Shipped** (Phase 4 initial integration): Nim state machine,
  `LlmVotingState` + `LlmState` types, FFI surface, Python wrapper
  around Anthropic Bedrock / direct API, trace observability
  (schema v3 with `llm_dispatched` / `llm_decision` / `llm_error`
  events and session counters), compile-time gate `-d:modTalksLlm`
  with non-LLM parity preserved.
- **In progress** (Sprint 1): observability landed — continue with
  Sprint 2 (speaker attribution, self-location history, alibi log,
  ejection detection) then Sprint 3 (tests), Sprint 4 (concurrency +
  tool-use), Sprint 5 (prompt eval + multi-provider).

Add new LLM-adjacent TODOs to `LLM_SPRINTS.md`, not here, unless
they are cross-cutting with inherited modulabot work.

---

## v1.1 Deferred (near-term, inherited from modulabot)

These were explicitly punted during v1 development. The schema, types, and
surrounding infrastructure are already in place; the missing piece is called
out in each entry.

### Alibi log wiring (`memory.appendAlibi` has no callers)

`memory.appendAlibi()` exists and is fully implemented — dedup logic, trim
rules, schema — but nothing ever calls it. The intended caller is `tasks.nim`,
which should invoke it when a crewmate is seen co-visible with a task terminal
at the moment of a task-completion icon flash (the "alibi" signal).

Ref: `DESIGN.md §13.9`, `memory.nim:228`

### `MeetingEvent.reporter` and `.ejected` always -1

The meeting-event struct has `reporter` and `ejected` fields (colour index),
but both are hardcoded to -1 at `bot.nim:412–413`. Filling them in requires
two new perception passes:

- **reporter**: sample the nametag highlight in the meeting-call intro
  animation to identify who pressed the button (or found the body).
- **ejected**: parse the post-vote cutscene to read the ejected player's name.

Ref: `bot.nim:412–413`, `types.nim:233–238`, `TRACING.md §14`

### Chat speaker attribution (`speaker: null` hardcoded)

Every `chat_observed` trace event emits `"speaker": null`. The design calls
for sampling speaker-pip pixels immediately left of `VoteChatTextX = 21` to
identify the speaker's colour. When implemented, `manifest.trace_settings
.speaker_attribution` should change from `"none"` to `"color_pip"`. The
schema field is already reserved; adding attribution won't break existing
trace consumers.

**Note:** also tracked as Sprint 2.1 in `LLM_SPRINTS.md` — the LLM layer
treats speaker attribution as a hard prerequisite for reaction-quality
improvements. Any implementation should satisfy both consumers at once.

Ref: `trace.nim:670`, `TRACING.md §15`, `types.nim:239`, `LLM_SPRINTS.md §2.1`

### Frames-dump rotation / retention policy

The trace writer keeps all frames dumps forever — roughly 117 MB/game
uncompressed (~5–10 MB gzipped). There is no sweep. A long training run (e.g.
50 games) accumulates ~6 GB raw / ~250 MB gzipped before any pruning. The
design specifies a cron-style sweeper that keeps the last K=10 games, with a
`RETAIN` sentinel file to pin specific runs. Nothing in `trace_smoke.sh` or
elsewhere implements this today.

Ref: `TRACING.md §14.6`, `DESIGN.md §854–856`

### `_session.json` cross-game lineage file

The design calls for an optional `_session.json` at
`<trace-root>/<bot-name>/<session-id>/` containing rolled-up counters and a
list of round IDs for the session. Not written anywhere today. Useful once the
harness starts training across many games and needs a session-level index
without parsing every individual round file.

Ref: `TRACING.md §5`

### `self_color_changed` trace event

If `identity.selfColor` can change mid-session (e.g. after a reconnect into a
new lobby), the trace has no event for it. A `self_color_changed` event was
noted as a v1.1 addition. Until this is added, any harness that caches
`self_color` from the manifest may silently use a stale value.

Ref: `TRACING.md §14.9`

---

## Open questions / potential bugs

These are correctness concerns that were flagged but not resolved.

### `bot.interstitial.voting_screen` branch ID — missing from source

`TRACING.md §8.2` lists `bot.interstitial.voting_screen` as a canonical branch
ID (attributed to `bot.nim:368`), and `test/validate_trace.nim` includes it in
the allowed-IDs list. However:

- It does **not** appear in `BRANCH_IDS.md` (which lists 31 IDs; this would
  be the 32nd).
- There is no `bot.fired("bot.interstitial.voting_screen", ...)` call anywhere
  in source.

Either (a) the voting-screen interstitial early-return path was supposed to
fire this branch ID but the call was never added — making it a genuine missing
`bot.fired(...)` — or (b) TRACING.md and `validate_trace.nim` have stale
entries from an earlier design that changed. The `warnEmptyBranchOnce`
mechanism in `trace.nim:910–920` should surface this at runtime if (a), but
only if tracing is enabled when the voting screen is hit.

Action: run a traced game to the voting screen and check whether a
`trace_warning` event fires; then either add the `bot.fired(...)` call or
remove the stale entries from the docs and validator.

Ref: `TRACING.md §8.2`, `BRANCH_IDS.md`, `test/validate_trace.nim:32`,
`trace.nim:910–920`

### Scan-ordering parity risk on teleport

`DESIGN.md §4` has a flagged open question (marked ⚠):

> "Does the v2 ordering actually matter? The current flow is 'score with
> last-frame's sprite matches → re-localize → re-scan with new camera'.
> Inverting could degrade scan quality on teleport. We may need a two-pass:
> cheap re-scan on new camera, then localize again."

This was never empirically resolved during the parity bake — parity was
declared sufficient at 87% (deterministic up to frame ~2508) without
specifically exercising teleport-heavy replays. If scan quality regresses after
a vent or telepad transition, this is the first place to look.

Ref: `DESIGN.md §4`

### `tuning_snapshot` exhaustiveness check is manual / absent

`TRACING.md §10.3` says CI should run a grep that warns when a `const` is
added to a policy module without a corresponding key in `tuning_snapshot.nim`.
`tools/trace_smoke.sh` runs parity + smoke + branch-ID drift checks but does
**not** include this grep. As new tuning knobs are added, they can silently
go missing from the manifest's `tuning_snapshot` object.

Action: add a grep step to `trace_smoke.sh` (or a separate `make lint`
target) that cross-checks policy-module `const` declarations against
`tuning_snapshot.nim`.

Ref: `TRACING.md §10.3`, `tools/trace_smoke.sh`

### `TeleportThresholdPx` was never empirically validated

`DESIGN.md §5` says this constant "should be set during the parity bake — too
tight wastes scans every frame, too loose lets stale matches poison post-vote
frames." The parity bake was completed and declared sufficient, but there is no
record that this knob was actually tuned. The current value may be the initial
guess rather than an empirically chosen one.

Ref: `DESIGN.md §5`

---

## Stale documentation

Minor doc rot to clean up when passing through affected files.

### Stale comment in `viewer/runner.nim:4–6`

The header comment says the viewer (`--gui`) is "not yet implemented
(phase 2 deliverable)." The viewer has been complete since Phase 2 shipped.
The comment should be updated to reflect that `--gui` is fully functional.

Ref: `viewer/runner.nim:4–6`

### Phase numbering gap in `DESIGN.md §8` / `§11`

The original plan defined Phases 0–4. The status log shows 0, 1, 2, 3
(open), then jumps to "Phase 5 — tracing." Phase 4 vanished. The
introduction of tracing as Phase 5 was an in-flight renaming that was never
reconciled in the phase table. Not a correctness issue, but makes the status
section confusing to read.

Ref: `DESIGN.md §8`, `§11`

---

## Phase 3 — Divergence (inherited from modulabot, lower priority for mod_talks)

`DESIGN.md §11 Phase 3` lists these directions in priority order. None have
been started. These represent the main body of remaining strategic work.

### 1. Better evidence model

Replace the current binary suspicion tiers (`witnessed_kill` vs `near_body`)
with quantitative suspicion scores. A continuous score would let the bot
combine weak signals (proximity, timing, task-skip patterns) that the current
model discards. This is the highest-leverage Phase 3 item since it affects
every accusation and vote.

### 2. Smarter imposter chat

Current imposter chat is minimal and pattern-fixed. Improvements:
- Vary message timing so it doesn't look like a bot reacting on a fixed delay.
- Add fake-task callouts ("just did electrical") timed to task animations.
- Parse and react to chat content beyond the simple "did anyone say sus" check.

### 3. Real ghost behavior

Ghosts currently just continue doing tasks. Real options:
- Vent-watching: observe imposter vent usage and record it (useful for
  post-game trace analysis even if the ghost can't vote).
- Escorting suspects: shadow a suspected imposter to generate alibi-disproving
  sightings.
- Emergency-button awareness: move to visible locations when a meeting is
  expected.

### 4. Vote bandwagon detection

Log when the crewmate vote pattern looks like a bandwagon (several votes
arriving in rapid succession on the same target after a leader vote). Don't
act on it yet — preserve the evidence-only voting rule — but capturing the
pattern in traces will let us decide later whether to exploit or counter it.

### 5. `--seed` flag for v2

Patch `evidencebot_v2` to accept a `--seed` flag. Currently v2 seeds its RNG
from clock+pid, so parity tests can only exercise the crewmate code path (the
deterministic prefix before the first imposter RNG branch). With a fixed seed,
imposter-path parity becomes testable, which is important if Phase 3 changes
touch imposter policy.

---

## Future / v2 (longer horizon)

Items from `TRACING.md §15` and the decisions log that are further out.

### Counterfactual annotations in trace

Record which tier of `nearestTaskGoal` was considered but rejected at each
decision point. The goal struct already carries enough state for offline
reconstruction; the trace just doesn't surface it. Would make the trace much
more useful for post-hoc policy analysis and debugging.

Ref: `TRACING.md §15`

### Streaming trace (WebSocket proxy)

A WebSocket proxy that tails the JSONL trace in real time for live harness
dashboards. Not needed until a real-time training loop exists.

Ref: `TRACING.md §15`

### Sprite atlas dedup across bots in batch training

Each `Bot` instance in a batch training run holds its own full copy of the
sprite atlas (`types.nim:373`). For large batches this is a meaningful memory
cost. The Q10 decision was "one `Sprites` per `Bot` for v0, revisit after
parity if memory is an issue." Parity was declared but memory was never
measured under batch load.

Ref: `types.nim:373`, `DESIGN.md §10 Q10`

### LLM-targeted `summary.md` per game

An end-of-game summary in natural language, auto-generated from the trace, for
feeding into an LLM training or eval loop. Harness-level work; nothing in-bot
is needed first.

Ref: `TRACING.md §15`

---

## Blocked on external dependencies

### CoGames tournament submission

The submission infrastructure (`cogames/`) is ready and the pre-flight
checklist in `cogames/README.md` passes. The only blocker is that no
`among-them` season exists in `cogames season list` yet — only `beta-cvc` and
`beta-teams-tiny-fixed` are live. Watch the CoGames season list; submit as
soon as an AmongThem season appears.

Ref: `cogames/README.md` (pre-flight checklist)

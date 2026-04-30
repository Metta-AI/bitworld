# modulabot — TODO

Deferred work, open questions, and future directions gathered from DESIGN.md,
TRACING.md, and a doc/code scan on 2026-04-30. Items are grouped by theme and
roughly ordered by priority within each section.

---

## v1.1 Deferred (near-term, already designed)

These were explicitly punted during v1 development. The schema, types, and
surrounding infrastructure are already in place; the missing piece is called
out in each entry.

### Alibi log wiring (`memory.appendAlibi` has no callers)

~~Resolved 2026-04-30.~~ `memory.appendAlibi()` is now called from
`tasks.recordTaskAlibis`, invoked once per frame after
`updateTaskIcons` in `bot.nim:477`. The proc iterates
`bot.percep.visibleCrewmates` × `bot.sim.tasks` and appends one
`AlibiEvent` for each co-visibility within
`MemoryAlibiTaskRadiusPx` (Manhattan, new tuning knob, default
12 px). Self, known imposter teammates, and unknown-colour
matches are filtered out — same filter `scanCrewmates` uses for
sighting attribution. Per-(colour, task) dedup inside
`memory.appendAlibi` (existing `MemoryAlibiCooldownTicks = 20`)
keeps the raw log from ballooning while a crewmate lingers on
one terminal.

Also wired:

- `alibi_observed` trace event (new), emitted via a
  `prevAlibisCount` shadow on `TraceWriter` (mirror of the
  `prevBodiesCount` pattern from §13.6). Payload carries the
  colour name, task index, and task name. Added to
  `test/validate_trace.nim` known-event list.
- `MemoryAlibiCooldownTicks`, `MemoryAlibiTaskRadiusPx`, and the
  other three memory knobs (`MemorySightingDedupTicks`,
  `MemorySightingDedupPixels`, `MemoryBodyDedupPx`) added to
  `tuning_snapshot.nim` so harness lineage tracking sees them.
- Parity unchanged: black-mode 500/5000-frame seeds 42 remain
  100% match both with and without `--trace-dir`.

Ref: `tasks.nim:283`, `bot.nim:477`, `trace.nim:561`,
`tuning.nim:39–49`.

### `MeetingEvent.reporter` and `.ejected` always -1

The meeting-event struct has `reporter` and `ejected` fields (colour index),
but both are hardcoded to -1 at `bot.nim:412–413`. Filling them in requires
two new perception passes:

- **reporter**: sample the nametag highlight in the meeting-call intro
  animation to identify who pressed the button (or found the body).
- **ejected**: parse the post-vote cutscene to read the ejected player's name.

Ref: `bot.nim:412–413`, `types.nim:233–238`, `TRACING.md §14`

### Chat speaker attribution (`speaker: null` hardcoded)

~~Resolved 2026-04-30.~~ `chat_observed` events now carry the
speaker colour, sampled from the per-message pip rendered at
`VoteChatIconX = 1` (sim constant) immediately left of the chat
text column. `manifest.trace_settings.speaker_attribution` changed
from `"none"` to `"color_pip"`. Implementation spans
`voting.readVoteChatSpeakers` + `voting.voteChatSpeakerForLine`
(prefer-above tie-break handles wrapped multi-line messages),
`VotingState.chatLines` / `MeetingEvent.chatLines` are now
`seq[VoteChatLine]` (speaker + text + y), and `trace.emitEvent`
emits the colour name in `chat_observed.speaker`.

While fixing this:

- Ported modulabot's OCR to the shared `among_them/texts.nim`
  engine (variable-width tiny5; two-sided miss/extra scoring). The
  previous fixed-7-px stride in `ascii.nim` / `voting.readAsciiRun`
  silently mis-read every chat line after the font migration.
- `VoteChatTextX` and `VoteChatChars` in `voting.nim` now source
  from `sim` (`VoteChatTextX`, `VoteChatCharsPerLine`) so the next
  font / layout retune does not need a modulabot-side patch.
- The chat-panel scan window moved from `chatY + 2` to `chatY + 1`
  — the sim draws the first message at `rowY = chatY + 1`, so the
  previous window dropped the oldest visible message by one pixel.
- Added `test/speaker_attribution.nim` (4 scenarios:
  all-colours-in-order, interleaved non-palette-order speakers,
  wrapped 3-line message, empty chat). Wired into
  `tools/trace_smoke.sh` step `[5/6]`.

Ref: `voting.nim`, `trace.nim:226`, `trace.nim:671`,
`test/speaker_attribution.nim`, `TRACING.md §15`.

### Frames-dump rotation / retention policy

~~Resolved 2026-04-30.~~ Shipped as a standalone tool,
`tools/frames_sweep.nim`, per `TRACING.md §14.6`. The tool walks
`<trace-root>/<bot>/<session>/round-*`, orders rounds newest-first
by `manifest.started_unix_ms` (falling back to round-dir mtime),
keeps the last K (default 10) plus any pinned with a `RETAIN`
sentinel, and deletes the external file pointed at by each pruned
round's `manifest.config.frames_dump_path`. Manifests, events,
decisions, and snapshots are preserved — only the large frames
dump is swept. `--dry-run` for inspection, `--verbose` for
per-entry logging. Exit non-zero on delete failure. Not wired
into `trace_smoke.sh` because sweep is a harness/cron concern,
not a build gate.

### `_session.json` cross-game lineage file

~~Resolved 2026-04-30.~~ The trace writer now writes
`<trace-root>/<bot-name>/<session-id>/_session.json` at every
round close (and on `closeTrace` even when no round completed,
leaving a skeleton file for offline tooling). Schema v1 carries
rolled-up `summary_counters` summed across all rounds in the
session, the ordered `round_ids` and parallel `round_results`
lists (close order, each entry `"crew_wins"` / `"imps_win"` /
`"unknown"`), the `master_seed`, and wall-clock start / last-
update timestamps. Rewritten in full at every close so a process
crash between rounds still leaves a usable index. Implementation
lives in `trace.writeSessionIndex` (`trace.nim:307`) with new
`TraceWriter.sessionCounters` / `sessionRoundIds` /
`sessionResults` fields. `TRACING.md §5` updated with the schema.

### `self_color_changed` trace event

~~Resolved 2026-04-30.~~ The trace writer already emits
`self_color_changed` on any `identity.selfColor` transition where
the previous value was also non-negative (`trace.nim:436–442`). The
TODO entry was stale documentation residue from the original
trace-writer plan; the event has shipped since the first trace
commit (`86ba8d3`). `TRACING.md §14.9` has been updated to
reflect the shipped behaviour.

---

## Open questions / potential bugs

These are correctness concerns that were flagged but not resolved.

### `bot.interstitial.voting_screen` branch ID — missing from source

~~Resolved 2026-04-30.~~ The voting-screen branch ID was stale doc
residue, not a missing `bot.fired(...)` call. When the interstitial
gate fires during an active meeting (`bot.nim:388`), the frame is
dispatched to `decideVotingMask` which always fires a `voting.*`
branch ID before returning, so the `voting.*` family fully covers
that path. Stale entries removed from `TRACING.md §8.2` and
`test/validate_trace.nim`; `BRANCH_IDS.md` was already correct.

While fixing this, also synced the other stale `policy_crew.task.*`
entries in `validate_trace.nim` (`holding`, `mandatory_*`, `checkout_*`,
`radar_*`, `home_fallback`) and added missing real IDs
(`policy_imp.body.vent_escape`, `policy_imp.body.vent_approach`) that
would have caused valid runs to fail validation.

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

~~Resolved 2026-04-30.~~ Shipped as a new Nim tool,
`tools/check_tuning_snapshot.nim`, wired into
`tools/trace_smoke.sh` as step `[7/7]`. The tool scans every
policy module in `PolicyModules` for `  Name* = value`
declarations and verifies each name is either registered in
`tuning_snapshot.nim` or listed in the `SnapshotExempt`
whitelist (with a one-line reason per exempt entry). The five
memory / alibi knobs and the v2 teleport threshold are now all
registered; eleven constants are exempt (`PlayerColorNames`,
the `Patch*` hash / derived-geometry constants, `KillIconY`,
and the five voting-screen layout constants). A negative test
(delete an entry from `tuning_snapshot.nim`) was confirmed to
fail the check during development. Replaces the grep approach
described in §10.3 with an identifier-parsing Nim tool for
cross-platform CI portability.

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

~~Resolved 2026-04-30.~~ Header comment updated to reflect that
`--gui` is fully wired via `viewer/viewer.nim`.

### Phase numbering gap in `DESIGN.md §8` / `§11`

~~Resolved 2026-04-30.~~ Added a lead-in note to §11 explaining the
phase numbering drift from §8 during execution, and renumbered
"Phase 5 — tracing" to "Phase 4 — tracing" so the status log reads
0, 1, 2, 3, 4 consecutively.

---

## Phase 3 — Divergence (future development, not yet started)

`DESIGN.md §11 Phase 3` lists these directions in priority order. None have
been started. These represent the main body of remaining strategic work.

### 1. Better evidence model

Replace the current binary suspicion tiers (`witnessed_kill` vs `near_body`)
with quantitative suspicion scores. A continuous score would let the bot
combine weak signals (proximity, timing, task-skip patterns) that the current
model discards. This is the highest-leverage Phase 3 item since it affects
every accusation and vote.

**Unblocked 2026-04-30 by speaker attribution.** With
`chat_observed.speaker` now populated, the evidence model can now
include chat-derived signals — "who accused whom", "who typed
first", "who stayed silent" — that previously had no colour anchor.
Start by adding `chat_accusation` and `chat_silence` features to
the suspect scorer.

### 2. Smarter imposter chat

Current imposter chat is minimal and pattern-fixed. Improvements:
- Vary message timing so it doesn't look like a bot reacting on a fixed delay.
- Add fake-task callouts ("just did electrical") timed to task animations.
- Parse and react to chat content beyond the simple "did anyone say sus" check.

**Unblocked 2026-04-30 by speaker attribution.** The "parse and
react to chat content" bullet now has everything it needs:
`chat_observed` events carry both the text (OCR) and the speaker
colour, so an imposter can now deflect away from a crewmate who
accused the imposter's teammate, or chain-pile-on a victim that
another live crewmate already called out.

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

**Meaningfully unblocked 2026-04-30 by speaker attribution.**
Bandwagon detection is much more informative now that chat events
carry the speaker: a "leader vote" can be correlated with "the
colour who posted `sus X` a moment earlier". Before, the chat
trigger and the vote cast were separate anonymous signals.

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

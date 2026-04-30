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

# lively_lecun roadmap

A Go player agent for `among_them`. Goal: complete crewmate tasks reliably.

## Decisions

- **Cadence**: one milestone per session.
- **Perception**: re-derived in idiomatic Go; `among_them/players/nottoodumb.nim` is a behavioral reference only, not a source to port.
- **Role scope**: crewmate only. If assigned imposter we walk around without crashing; no kill / sabotage logic on this track.
- **Robustness over precision**: prefer structural cues (region pixel counts, color-class ratios, blob detection) over exact-template or per-pixel comparisons. OCR is overkill for the time being. Thresholds should have wide margins against measured data so cosmetic rendering changes don't break the agent.

## Test fixtures

`testdata/phase_*.bin` are real 8192-byte frames captured from the sim at each phase. Regenerate with `nim c -r capture_fixtures.nim` (requires the repo's nim toolchain). Go tests load them via `os.ReadFile`. Keep these committed — they ground-truth the perception code.

## Key sim facts (verified)

- Wire protocol is bitscreen-only: 8192-byte 4-bit packed frame in, 2-byte button-mask packet out. See `docs/bitscreen_protocol.md` and `common/protocol.nim`.
- Task completion is just "stand on the task station with no direction inputs for `taskCompleteTicks` ticks" — `among_them/sim.nim:1139-1162`. No minigame.
- The map is not preloaded by `nottoodumb.nim`; wall knowledge is built lazily from observation (`nottoodumb.nim:3112`). We can do the same and avoid an asset-extraction side-quest.

## Milestones

### M0 — Smoke test (DONE)

Connect, decode frames, exchange button packets, clean shutdown. Eleven unit tests covering protocol constants, packet build/parse, frame nibble order. Landed in commit `80bba76`.

### M1 — Phase detection + reactive movement (DONE)

Three macro-phase classifier + behavior switch in `main.go`:

- `phase.go` — `Classify(pixels)` returns `PhaseIdle` / `PhaseActive` / `PhaseVoting` from structural cues against the `testdata/phase_*.bin` fixtures.
- `steer.go` — `Steer(pixels)` returns a button mask toward the centroid of yellow pixels (palette 10), with an exclusion box around the player's on-screen position and a deadband near center.
- `vote.go` — `SkipController` alternates press/release frames to navigate to the SKIP cell and cast `ButtonA`. Detects "cursor on SKIP" via the palette-2 highlight top edge at y=19 (1-row layout) or y=36 (2-row).
- `main.go` — phase-aware loop, send-on-change cache; resets `SkipController` on each entry to Voting.

Verified live (commits `360b486`, `11158a4`, `98e2431`, `54ba4c2`): three agents against the Nim server with `maxTicks=200` observed `phase: idle (frame 1) → active (frame 121) → idle (frame 321)` — exactly matching `RoleRevealTicks=120` and `maxTicks=200` boundaries.

Voting transitions are not reachable in a self-play smoke test (no body to report, no map-located call button) and remain covered by `vote_test.go` only.

### M2 — Wall-aware steering

Read walkable vs wall from local screen tiles; back off / turn when blocked. Removes the "stuck against a wall" failure mode.
- Tests: canned frames with walls in each direction, assert steering avoids them.
- Done when: agent free-roams without getting pinned on geometry.

### M3 — Task pickup loop

When a task icon is near screen center, release directions and hold for `taskCompleteTicks`, then resume. Combined with M1+M2 this should already complete real tasks "by accident."
- Tests: canned "near task" frame yields empty-mask sustained; canned "moving" frame yields direction mask.
- Done when: agent completes >0 tasks per game on average.

### M4 — Camera localization + persistent map

Frame-fit the current screen against an accumulated wall grid (analogous to `nottoodumb.nim`'s `LocalFrameMapLock` / `FrameMapLock`, re-derived). Now we have stable world coordinates.
- Tests: synthetic frame at a known offset locks correctly; lock survives a movement step.
- Done when: world position log tracks reality across a full game.

### M5 — A\* to remembered tasks

Remember world coordinates of tasks we've seen. A\* across the learned wall grid replaces M1's reactive steering with deliberate routing.
- Tests: A\* unit tests on tiny synthetic grids; "remembered task at (x,y)" → first move correct.
- Done when: agent reliably reaches any task it has previously seen.

### M6 — Task list awareness

Parse the on-screen task list / radar to know which tasks are *mine*, not just any task seen. Drives end-to-end "complete all my tasks → win as crewmate."
- Tests: canned task-list overlay → parsed task set.
- Done when: agent wins the majority of crewmate-role games it plays solo against bots.

## Out of scope (this track)

- Imposter behavior beyond "don't crash."
- Voting beyond `skip`.
- Chat parsing or generation.
- Sprite recognition for other players (only needed for imposter / accusation logic).

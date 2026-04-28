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

### M2 — Wall-aware steering (DONE)

The map's wall layer (`wallMask` in `among_them/sim.nim:2513-2517`) lives only on the server, so per-pixel "is this a wall" decisions on the client would require pre-extracting `skeld2.aseprite` layer 2 — too much yak-shaving for M2. Instead, `bump.go` watches frame-to-frame pixel motion: free movement scrolls the camera and changes thousands of pixels per frame, while being pinned only differs in tens of pixels (sprite animations). When motion stays low for `bumperStuckStreak` consecutive frames the `Bumper` substitutes a perpendicular cardinal direction for `bumperPerturbTicks`, then resumes the steering layer's preferred mask.

`main.go`'s Active branch becomes `bumper.Adjust(pixels, Steer(pixels))`. Each perturb event also bumps `bumper.Perturbs` and emits a one-line log entry so live runs can see how often the agent is unsticking.

Verified live: three agents observed `idle (frame 1) → active (frame 121) → idle (frame 1121)` against a `maxTicks=1000` server, with one perturb event fired on agent Y at frame 128 — exactly the early-game "Steer wants vertical, but the camera hasn't started moving yet" case the layer is meant to catch.

### M3 — Task pickup loop (PARTIALLY DONE)

`task.go` adds:
- `OnTask(pixels)` — detects palette-9 (orange task icon) overlap in a 28×28 region above the player center. Verified by `playing_on_task` fixture: 17 hits vs 0 in regular `playing` and every other phase.
- `TaskHolder` — state machine that releases direction inputs (mask=0) for `taskHoldTicks=80` once OnTask fires, matching `sim.nim:39`'s `TaskCompleteTicks=72` plus a small slack.

`main.go` now layers behavior `TaskHolder → Bumper → Steer`. M3 also fixed a target-color bug discovered while building it: Steer was chasing palette 10 (yellow), which is map decoration. The actual task-direction signals are palette 8 (off-screen radar arrows, `radarColor` in `sim.nim:2337`) and palette 9 (on-screen task icons). `steer.go` now targets both.

**Live limitation:** with reactive radar-arrow steering, agents walk into walls trying to reach off-screen tasks and spend most of their time in the Bumper's perturb cycle (52+ perturbs in 30 s in the live test). They don't actually reach tasks, so `OnTask` never fires in practice. The infrastructure is correct but task completion needs deliberate navigation — that's M4 (camera localization) + M5 (A\* to remembered task locations).

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

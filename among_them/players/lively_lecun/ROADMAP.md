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

### M4 — Camera localization + persistent map (DONE)

Static asset, not lazy build. `capture_fixtures.nim` dumps `testdata/skeld_map.bin` (508 368 unpacked palette indices) and `testdata/fixtures.tsv` with ground-truth `(cameraX, cameraY, playerX, playerY)` for the playing fixtures. The Go binary embeds the map via `//go:embed`, growing 8.6 → 9.2 MB.

`locate.go` brute-forces the camera position from scratch via 252 sparse samples on an 8×8 screen grid (skipping a 16×16 box around the player center). Per-candidate inner loop has an early exit once mismatches exceed the running best. Brute force runs in ~10–170 ms; with `hint != nil` the search is constrained to 33×33 around the previous lock and runs in ~1 ms.

`tracker.go` keeps a running lock by preferring the hinted call and falling back to brute force only when the incremental fit fails. `PlayerPosition()` adds `(ScreenWidth/2, ScreenHeight/2)` to the camera; on the playing fixture it lands at (568, 118) vs the recorded (564, 120) — the 4 px gap is the offset between `player.x` (collision corner) and the sprite's visual center.

Verified live: the tracker locks the moment Active starts (`miss=5/252` at the canonical spawn), follows the agent through the first second of movement, falls back to brute force on agents that get stuck and lose lock, and re-locks. **Caveat noted in code:** in cluttered mid-game frames (other players, shadow overlay) the miss count climbs to 50–90 vs ~5 on the clean fixture, occasionally producing a slightly-drifted lock that still passes the 100-miss threshold. Tighter thresholds for hinted vs brute-force calls is a future tuning pass.

### M5 — A\* to remembered tasks (PARTIALLY DONE)

Static walkMask asset, A\* over pixel cells, Navigator → Bumper layering. The infrastructure all works; the live result is "deliberate navigation, but no task completions yet."

`capture_fixtures.nim` dumps `testdata/walks.bin` (bit-packed walkMask, 63 546 bytes) plus `walks_probe.tsv` ground-truth points. CollisionW=H=1 in `sim.nim:20-21`, so walkMask IS the player passability grid -- no footprint inflation needed. `walks.go` loads + unpacks; tests reproduce the probe ground truth.

`astar.go` implements 4-connected A\* with Manhattan heuristic and a `container/heap`-backed open set. Unit tests on synthetic ASCII grids cover the standard cases (start==goal, straight, around walls, unreachable, OOB endpoints, shortest preference). On the real map: 443 cells in 6.7 ms between the two recorded fixture player positions, just 12% over Manhattan -- close to optimal and well inside the per-frame budget.

`navigator.go` wraps the WalkMask + AStar pair in a per-frame interface: `SetGoal(p)` rejects unwalkable goals; `Next(player)` returns `(mask, arrived)` with replan when the player drifts >20 cells off the path or the path is exhausted. A `navLookahead=8` cell read smooths over corner oscillation. Simulated walk from playing fixture (564, 120) to playing_on_task fixture (876, 204): arrives in 384 single-cell moves, vs Manhattan distance 396.

`task_seen.go` flood-fills palette-9 (taskIconColor) blobs in the screen frame, drops blobs <3 px or touching the edge, then unions blobs within 12 px (the sprite size) -- the 12×12 task icon mixes palettes, so flood-fill alone produces fragments. `IconScreenToTaskWorld` adds the camera offset and the SpriteSize/2 + 2 px geometry from `sim.nim:2316-2319` to land on the task body. `task_memory.go`: a small dedup'd set of remembered task locations.

`main.go` now embeds both assets, runs Tracker → DetectTaskIcons → TaskMemory.Add (rejecting unwalkable goals) on every locked Active frame, and layers TaskHolder → Navigator → Bumper → Steer-fallback. A 120-frame "arrived but no TaskHolder" timeout drops false-positive task targets so the agent keeps trying.

**Live result, three agents, 75 s game (`tasksPerPlayer=2`, `maxTicks=2000`):**

| | tasks seen | nav targets | arrived | gave up | completed |
|---|---|---|---|---|---|
| X | 18 | 15 | 16 | 14 | 0 |
| Y | 4 | 2 | 1 | 1 | 0 |
| Z | 4 | 1 | 0 | 0 | 0 |

Agents do successfully navigate to remembered "tasks" -- X arrived at and abandoned 14 spots in 75 s. But zero task completions, zero TaskHolder activations. The cause is `blitSpriteOutlined` (sim.nim:909-915): it tints player sprites by replacing wildcard pixels with the player's color, so any other player whose color happens to be 9 produces orange pixels we read as a task icon. The walkability filter doesn't help because other players also stand on walkable floor.

What the M5 ladder actually proves end-to-end: the agent picks a goal, plans an A\* route, follows it to within ±4 px, then gives up cleanly when the goal turns out to be bogus. M6 must distinguish task icons from orange-tinted players -- candidate signals: bobbing (real icons bob ±1 px every 3 ticks, sim.nim:2312, 2347), multi-frame world-position stability (real icons don't drift; players do), or a sprite-template correlation against the known taskIconSprite shape.

### M6 — Task identification (queued)

Replace M5.6's palette-9-cluster heuristic with a check that distinguishes the real task icon from orange-tinted player sprites. Probable winner: multi-frame world-position stability over 4-6 frames.
- Tests: synthetic frames with task vs. player at the same screen pos -> only the task is detected.
- Done when: live agents complete their assigned tasks reliably.

### M7 — Task list awareness

Parse the on-screen task list / radar to know which tasks are *mine*, not just any task seen. Drives end-to-end "complete all my tasks → win as crewmate."
- Tests: canned task-list overlay → parsed task set.
- Done when: agent wins the majority of crewmate-role games it plays solo against bots.

## Out of scope (this track)

- Imposter behavior beyond "don't crash."
- Voting beyond `skip`.
- Chat parsing or generation.
- Sprite recognition for other players (only needed for imposter / accusation logic).

# lively_lecun roadmap

A Go player agent for `among_them`. Goal: complete crewmate tasks reliably.

## Decisions

- **Cadence**: one milestone per session.
- **Perception**: re-derived in idiomatic Go; `among_them/players/nottoodumb.nim` is a behavioral reference only, not a source to port.
- **Role scope**: crewmate only. If assigned imposter we walk around without crashing; no kill / sabotage logic on this track.

## Key sim facts (verified)

- Wire protocol is bitscreen-only: 8192-byte 4-bit packed frame in, 2-byte button-mask packet out. See `docs/bitscreen_protocol.md` and `common/protocol.nim`.
- Task completion is just "stand on the task station with no direction inputs for `taskCompleteTicks` ticks" — `among_them/sim.nim:1139-1162`. No minigame.
- The map is not preloaded by `nottoodumb.nim`; wall knowledge is built lazily from observation (`nottoodumb.nim:3112`). We can do the same and avoid an asset-extraction side-quest.

## Milestones

### M0 — Smoke test (DONE)

Connect, decode frames, exchange button packets, clean shutdown. Eleven unit tests covering protocol constants, packet build/parse, frame nibble order. Landed in commit `80bba76`.

### M1 — Phase detection + reactive movement

Detect lobby / playing / voting / game-over from frame pixels. While playing, steer toward the strongest yellow radar marker on screen. While voting, vote skip.
- `phase.go` — phase classifier from a `[16384]uint8` frame.
- `steer.go` — find dominant on-screen yellow signal, return a button mask.
- `main.go` — switch behavior by phase.
- Tests: canned frames per phase; canned frames with markers on each edge.
- Done when: agent stays in a game from start to finish, votes skip, never wedges.

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

# 4-State Task Memory — Design

## Problem

The crewmate agent currently keeps a flat list of remembered task locations (`TaskMemory.Known`). Two failure modes follow from that:

1. **It starts empty.** With nothing memorized, the agent falls back to wandering or radar-bearing guesses, often looping around ballrooms while an assigned task sits a corridor away.
2. **Radar "misses" are lost.** The radar emits exactly one pixel per (assigned ∧ incomplete ∧ icon-off-screen) task (`sim.nim:2609-2659`). If a station is not along any current arrow's bearing while the player is far from it, that is strong evidence it is not assigned. Today we throw that evidence away — the only way a station gets pruned is if we nav to it and the A\* search blows up, or we reach it without TaskHolder firing.

## Design

### States

Each `TaskStation` (the 40 static stations in `task_stations.go`) carries one of four states:

| State             | Meaning                                                                  |
| ----------------- | ------------------------------------------------------------------------ |
| `maybe`           | Default. We have no signal either way.                                   |
| `known`           | An icon was detected near the station (it IS assigned).                  |
| `radar_excluded`  | Station is out-of-viewport and no arrow has pointed at it for K frames.  |
| `seen_no`         | Station center was in viewport for K frames with no icon near it.        |

Priority for goal selection: **`known` > `maybe` > `radar_excluded` > `seen_no`.**

`radar_excluded` and `seen_no` are **deprioritizations, not bans.** The agent will still visit them once higher-priority candidates are exhausted. This matters because:
- Radar arrows have a ~8 px dead-band at the viewport edge (`sim.nim:2629-2631`) where neither arrow nor icon fires.
- Detection has noise; we must not permanently remove a station on one missed read.

### State transitions

Per active frame, with the player located at world position `P` and camera at `cam`:

**Icon evidence (strongest):**
- For each `IconMatch` returned by `FindTaskIcons`, compute its world position and snap via `SnapToStation`. The snapped station → `known`. This fires immediately (no K-frame debounce).

**Radar evidence:**
- For each station `i`:
  - Is `i`'s center off-screen right now? (`cam.X <= center.X < cam.X+ScreenWidth` etc.)
  - If off-screen, does any current radar arrow resolve to `i` via `NearestStationAlongBearing`? This is the *aggregate* check — per station per frame, not per arrow.
- Per-station counter `noArrowStreak`:
  - Off-screen + no arrow points at it → increment.
  - Any other condition (on-screen, or an arrow resolves to it) → reset to 0.
- When `noArrowStreak >= K` and the station is not already `known`/`seen_no`, set state to `radar_excluded`.
- Arrow resolving to a `radar_excluded` station → demote back to `maybe` (reset streak).

**On-screen absence (weakest, needs strongest debounce):**
- Per-station counter `onScreenNoIconStreak`:
  - Station center is on-screen AND no icon was detected within `taskMemoryMergeRadius` of it → increment.
  - Station is off-screen OR we saw an icon near it → reset to 0.
- When `onScreenNoIconStreak >= K` and state is not `known`, set state to `seen_no`.
- Icon evidence demotes `seen_no` → `known`.

**Task completion:**
- When `TaskHolder.Completes` increments, set the currently-nav'd station (the one goal selection picked) to `seen_no` and clear the goal. This replaces the current `memory.Forget` on completion.

### K frames

`K = 6` (~0.25 s at 24 fps). Short enough that one full lap around the ship convincingly flips a station, long enough to tolerate one or two noisy arrow-detector frames.

### Goal selection (agent.go)

Replace the current two-step (memory → radar) selection with a single pass over all 40 stations:

```
best := -1
bestTier, bestDist := int max, int max
for i := range TaskStations:
    tier := priority[state[i]]   // 0 known, 1 maybe, 2 radar_excluded, 3 seen_no
    d := manhattan(P, TaskStations[i].Center)
    if tier < bestTier || (tier == bestTier && d < bestDist):
        best, bestTier, bestDist = i, tier, d
```

Within a priority tier, pick the nearest station. This naturally handles:
- Empty memory at spawn → `maybe` tier has 40 candidates, pick nearest.
- Radar narrows → unassigned stations drop to `radar_excluded`, `maybe` tier thins.
- Icons seen → `known` tier fills; goal selection prefers those.

The radar-bearing guess (`RadarGoal`) and `radarBlack` list go away — they were workarounds for the old "memory is empty, chase the arrow tip" mode, which this design replaces.

### Goal re-evaluation

Today the agent picks a goal once (`!a.nav.HasGoal()`) and sticks with it until A\* fails / arrival / completion. With per-frame state updates, a better goal can appear mid-nav (e.g. passing near a `maybe` station, seeing its icon, demoting it to `known` while the current goal is `radar_excluded`).

**Rule:** if the current goal's priority tier drops *below* the best available tier, re-pick. Otherwise stick. This preserves commitment to reachable goals while not ignoring new `known` evidence. The existing `radarGoal` → `memory` preemption becomes a special case of this rule.

### Unreachable handling

When A\* returns `Unreachable`:
- `known`: demote to `seen_no`. (Likely A\* noise or a wall we can't path around; don't keep banging.)
- `maybe`: demote to `seen_no`.
- `radar_excluded` / `seen_no`: leave as is (they're already deprioritized).

Clear the goal in all cases.

### Arrival timeout

The existing `agentNavArrivedTimeout` (120 frames / ~5 s without TaskHolder firing) still applies. On timeout, set the arrived station to `seen_no` and clear the goal. Same as completion handling.

### Idle reset

`Agent.Step` already clears role state on sustained idle. It should also reset all 40 station states to `maybe` — a new game has a new task assignment.

## Components

### `task_memory.go` — rewrite

Replace with a station-indexed state table:

```go
type TaskState uint8
const (
    TaskMaybe TaskState = iota  // zero value: default on Reset/construction
    TaskKnown
    TaskRadarExcluded
    TaskSeenNo
)

// Length-matched to TaskStations at runtime (slice, not array — TaskStations
// is a []TaskStation so its length isn't a compile-time constant).
type TaskMemory struct {
    state                []TaskState
    noArrowStreak        []uint8
    onScreenNoIconStreak []uint8
}

func NewTaskMemory() *TaskMemory {
    return &TaskMemory{
        state:                make([]TaskState, len(TaskStations)),
        noArrowStreak:        make([]uint8, len(TaskStations)),
        onScreenNoIconStreak: make([]uint8, len(TaskStations)),
    }
}

func (m *TaskMemory) Update(player Point, cam Camera, icons []IconMatch, arrows []RadarArrow)
func (m *TaskMemory) Mark(i int, s TaskState)  // manual transitions (completion, timeout, unreachable)
func (m *TaskMemory) BestGoal(player Point, reject func(int) bool) (idx int, ok bool)
func (m *TaskMemory) State(i int) TaskState
func (m *TaskMemory) Reset()  // idle handler calls this
```

`Update` does the per-frame work: runs icon → `known` promotions, increments/resets both streaks, and flips state at the K threshold. Keeping it one call keeps `agent.go`'s stepActive tidy.

`BestGoal` does the priority scan described above.

### `agent.go` — adjust

- Delete `radarBlack`, `radarBlackFrom`, `radarReject`, `radarStationGoal`, `radarGoal`. Their jobs move into `TaskMemory`.
- Replace the `memory.Closest(player)` / `RadarGoal(...)` fork with a single `memory.BestGoal(player, ...)` call.
- Feed icons + arrows to `memory.Update` each locked frame (before goal selection).
- On completion / arrival-timeout / unreachable, call `memory.Mark(idx, TaskSeenNo)`.

`agent.go` likely shrinks by ~40 lines.

### Tests

`task_memory_test.go` (new) covers:
1. Icon → `known` is immediate.
2. K consecutive off-screen + no-arrow frames → `radar_excluded`; one arrow-resolved frame in between resets the streak.
3. K consecutive on-screen + no-icon frames → `seen_no`; one nearby-icon frame resets.
4. Priority order in `BestGoal`: `known` beats `maybe` beats `radar_excluded` beats `seen_no` even when the deprioritized one is closer.
5. `Mark(i, TaskSeenNo)` forces the state change immediately.
6. `Reset` clears everything to `maybe`.

An integration test in `agent_test.go`-style (`agent.go` via `Step`) verifies that a fixture frame with both an icon (for station A) and an arrow pointing at station B produces a goal at A.

## Non-goals

- Persisting state across games (a reset wipes it).
- Distinguishing task types. A "2-step" task still counts as one assignment from our perspective; TaskHolder handles multi-step UI already.
- Tracking *other* players' tasks (we only care about our own — radar only shows our assigned tasks anyway, per `sim.nim:2611`).

## Risks

- **Arrow detection noise.** Current `FindRadarArrows` may occasionally miss a real arrow. K=6 debounce absorbs 1-2 dropped frames, and `radar_excluded` is not a ban — worst case is "visit last" rather than "never visit."
- **Station on-screen but occluded.** The player sprite overlaps ~8 px around screen center; an icon for a station coincident with the player's position won't show. `onScreenNoIconStreak` could fire a false `seen_no`. Mitigation: the 16×16 player exclusion zone is small relative to the 128×128 viewport, and with 41 stations this rarely coincides for K frames. Acceptable.
- **`radarGoal` preemption semantics.** Current code has a specific "memorized preempts radar" rule tied to `radarGoal`. The new rule ("higher-priority tier preempts") is strictly more general and handles the same case.

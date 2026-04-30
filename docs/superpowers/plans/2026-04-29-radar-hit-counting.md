# Radar Hit Counting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-arrow nearest-along-bearing matcher with per-station predicted-arrow matching. Track cumulative `RadarHits` per task station and use them to rank unconfirmed Maybes in `BestGoal`, so crew agents stop cascading every station into a terminal `RadarExcluded` state.

**Architecture:** For each `Maybe` station, compute the screen-space arrow position the server would draw (mirroring `sim.nim:2443-2472`). If any detected radar-arrow pixel lies within Chebyshev τ=3 of that prediction, increment `RadarHits`. Goal selection: Known by distance; else among Maybes, the 80%-of-top-hits cohort by distance; else closest Maybe; never SeenNo. `RadarExcluded` and the `noArrowStreak` machinery go away.

**Tech Stack:** Go (Go 1.22+), integer geometry, existing `task_memory.go`/`task_radar.go`/`task_stations.go`/`agent.go`.

**Spec:** `docs/superpowers/specs/2026-04-29-radar-hit-counting-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `among_them/players/lively_lecun/task_memory.go` | Per-station state; holds `RadarHits`; `Update()` runs the per-station prediction & match; `BestGoal()` implements the 3-tier + 80% selection. |
| `among_them/players/lively_lecun/task_radar.go` | New pure function `PredictedArrow(playerScreenCenter, stationCenter, cam) (RadarArrow, bool)` — mirrors the server's edge-projection. Unchanged: `FindRadarArrows`, `nearestWalkable`. |
| `among_them/players/lively_lecun/task_stations.go` | Delete `NearestStationAlongBearing`. `SnapToStation` stays. |
| `among_them/players/lively_lecun/task_memory_test.go` | Rewrite the radar-exclusion tests; add radar-match, 80%-gate, Known-precedence tests. |
| `among_them/players/lively_lecun/task_radar_test.go` | **New.** Tests for `PredictedArrow`. |
| `among_them/players/lively_lecun/agent.go` | No behavioral change — the tier-check in preemption (`Priority(idx) < Priority(goalStation)`) still works since Known stays tier 0, everything else tier 1. Verify, don't rewrite. |

---

## Task 1: Add `PredictedArrow` in `task_radar.go`

**Files:**
- Modify: `among_them/players/lively_lecun/task_radar.go`
- Test: `among_them/players/lively_lecun/task_radar_test.go` (new)

The server (`sim.nim:2443-2472`) computes the arrow's screen-space position from:

- `px, py` = player sprite center in screen coords = `player.x + CollisionW/2 - cam.X`, same for y.
- `dx, dy` = station center in screen coords minus `(px, py)`.
- If `|dx| < 0.5 && |dy| < 0.5`: no arrow (station is at the center — effectively on-screen / never predicted).
- Dominant axis = whichever of `|dx|, |dy|` is larger. Dominant screen coord is clamped to `0` or `ScreenWidth-1` / `ScreenHeight-1` depending on sign. Perpendicular coord is `py + dy * (ex - px) / dx` (when X dominant) or `px + dx * (ey - py) / dy` (when Y dominant), clamped to `[0, ScreenWidth-1]` / `[0, ScreenHeight-1]`.
- Both final values cast via `uint8(int(...))` — i.e. truncated to int.

Also: when the station is **on-screen**, the server draws the icon instead of the arrow (`sim.nim:2440-2442`). Our `PredictedArrow` must return `(_, false)` in that case — the on-screen threshold: any(|dx_screen| < ScreenWidth/2 && |dy_screen| < ScreenHeight/2 relative to the player) maps to the viewport-visible test. The caller already filters Maybes; simplest is: if `0 <= station.X-cam.X < ScreenWidth && 0 <= station.Y-cam.Y < ScreenHeight`, return `(_, false)`.

`CollisionW` and `CollisionH` are both 1 in `sim.nim:20-21`, so `player.x + CollisionW/2 = player.x` (integer division rounds `1/2 = 0`). Therefore `px = player.X - cam.X` (which equals `playerWorldOffX = 60` when player is at the camera's nominal center) and `py = player.Y - cam.Y` (= `playerWorldOffY = 66`).

- [ ] **Step 1: Write the failing test file**

Create `among_them/players/lively_lecun/task_radar_test.go`:

```go
package main

import "testing"

// predictionTestCam returns a camera that places the player's sprite center
// at screen (playerWorldOffX, playerWorldOffY).
func predictionTestCam(player Point) Camera {
	return Camera{X: player.X - playerWorldOffX, Y: player.Y - playerWorldOffY}
}

func TestPredictedArrow_StationOnScreenReturnsFalse(t *testing.T) {
	player := Point{400, 300}
	cam := predictionTestCam(player)
	// A station a few pixels off-player is still well inside the viewport.
	station := Point{player.X + 10, player.Y + 10}
	if _, ok := PredictedArrow(player, station, cam); ok {
		t.Errorf("on-screen station should not predict an arrow")
	}
}

func TestPredictedArrow_DueEastClampsToRightEdge(t *testing.T) {
	player := Point{400, 300}
	cam := predictionTestCam(player)
	// Station 500 pixels east, same row as the player => dominant X, arrow
	// at (ScreenWidth-1, playerScreenCenterY).
	station := Point{player.X + 500, player.Y}
	ar, ok := PredictedArrow(player, station, cam)
	if !ok {
		t.Fatal("expected an arrow for far-east station")
	}
	if ar.ScreenX != ScreenWidth-1 {
		t.Errorf("ScreenX = %d, want %d", ar.ScreenX, ScreenWidth-1)
	}
	// ey = py + dy * (ex - px) / dx; dy=0 => ey = py.
	if ar.ScreenY != playerWorldOffY {
		t.Errorf("ScreenY = %d, want %d", ar.ScreenY, playerWorldOffY)
	}
}

func TestPredictedArrow_DueNorthClampsToTopEdge(t *testing.T) {
	player := Point{400, 300}
	cam := predictionTestCam(player)
	// Station due north; dominant Y.
	station := Point{player.X, player.Y - 500}
	ar, ok := PredictedArrow(player, station, cam)
	if !ok {
		t.Fatal("expected an arrow for far-north station")
	}
	if ar.ScreenY != 0 {
		t.Errorf("ScreenY = %d, want 0", ar.ScreenY)
	}
	if ar.ScreenX != playerWorldOffX {
		t.Errorf("ScreenX = %d, want %d", ar.ScreenX, playerWorldOffX)
	}
}

func TestPredictedArrow_DiagonalXDominantClampsToRight(t *testing.T) {
	player := Point{400, 300}
	cam := predictionTestCam(player)
	// |dx|=500, |dy|=100 (X dominant, dy positive). ex = ScreenWidth-1.
	// ey = py + dy * (ex - px) / dx
	//    = 66  + 100 * ((ScreenWidth-1) - 60) / 500
	//    = 66  + 100 * 67 / 500 (integer-truncated cast) = 66 + 13 = 79
	// (server casts via uint8(int(float)); float arith: 6700/500 = 13.4 -> int=13)
	station := Point{player.X + 500, player.Y + 100}
	ar, ok := PredictedArrow(player, station, cam)
	if !ok {
		t.Fatal("expected an arrow")
	}
	if ar.ScreenX != ScreenWidth-1 {
		t.Errorf("ScreenX = %d, want %d", ar.ScreenX, ScreenWidth-1)
	}
	if ar.ScreenY != 79 {
		t.Errorf("ScreenY = %d, want 79", ar.ScreenY)
	}
}

func TestPredictedArrow_DiagonalClampsPerpendicularAxis(t *testing.T) {
	// Arrow placement with X dominant but a steep angle that would push ey
	// past the top of the screen if unclamped. Server clamps ey into
	// [0, ScreenHeight-1].
	player := Point{400, 300}
	cam := predictionTestCam(player)
	// dx=+200, dy=-2000. |dy| > |dx| so this is actually Y-dominant; pick
	// one that's genuinely X-dominant with a steep angle.
	// dx=+200, dy=-180. |dx| > |dy|. Then:
	//   ey = 66 + (-180) * ((ScreenWidth-1) - 60) / 200
	//      = 66 + (-180 * 67) / 200 = 66 + (-12060/200) = 66 + (-60) = 6
	// That stays in bounds. Make dy larger: dx=+200, dy=-199.
	//   ey = 66 + (-199 * 67) / 200 = 66 + (-13333/200) = 66 + (-66) = 0
	// Server's inner math uses float then int truncation; our int impl
	// must match for typical inputs (see task 1 step 3). Use dy=-199.
	station := Point{player.X + 200, player.Y - 199}
	ar, ok := PredictedArrow(player, station, cam)
	if !ok {
		t.Fatal("expected an arrow")
	}
	if ar.ScreenX != ScreenWidth-1 {
		t.Errorf("ScreenX = %d, want %d", ar.ScreenX, ScreenWidth-1)
	}
	if ar.ScreenY < 0 || ar.ScreenY >= ScreenHeight {
		t.Errorf("ScreenY = %d, out of [0, %d)", ar.ScreenY, ScreenHeight)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test -run TestPredictedArrow ./among_them/players/lively_lecun/ -v`
Expected: all fail with "undefined: PredictedArrow".

- [ ] **Step 3: Implement `PredictedArrow`**

Append to `among_them/players/lively_lecun/task_radar.go`:

```go
// PredictedArrow returns the screen-space pixel where the server would draw
// this station's radar arrow, mirroring sim.nim:2443-2472. Returns
// (_, false) when the station's center is inside the viewport (the server
// draws the icon instead of an arrow in that case).
//
// CollisionW = CollisionH = 1 (sim.nim:20-21), so with integer division
// px = player.X - cam.X and py = player.Y - cam.Y. The server's float
// arithmetic is emulated with integer math; division uses truncation
// toward zero (Go's integer `/`), which matches the server's float-then-
// `int()` cast for the in-range cases this predicate is called on (the
// division's numerator is bounded because the perpendicular axis later
// gets clamped to the viewport).
func PredictedArrow(player, station Point, cam Camera) (RadarArrow, bool) {
	sx := station.X - cam.X
	sy := station.Y - cam.Y
	if sx >= 0 && sx < ScreenWidth && sy >= 0 && sy < ScreenHeight {
		return RadarArrow{}, false
	}
	px := player.X - cam.X
	py := player.Y - cam.Y
	dx := sx - px
	dy := sy - py
	if dx == 0 && dy == 0 {
		return RadarArrow{}, false
	}
	adx, ady := absInt(dx), absInt(dy)
	const maxX = ScreenWidth - 1
	const maxY = ScreenHeight - 1
	var ex, ey int
	if adx > ady {
		if dx > 0 {
			ex = maxX
		} else {
			ex = 0
		}
		// ey = py + dy*(ex-px)/dx; dx != 0 here.
		ey = py + (dy*(ex-px))/dx
		if ey < 0 {
			ey = 0
		} else if ey > maxY {
			ey = maxY
		}
	} else {
		if dy > 0 {
			ey = maxY
		} else {
			ey = 0
		}
		// ex = px + dx*(ey-py)/dy; dy != 0 here.
		ex = px + (dx*(ey-py))/dy
		if ex < 0 {
			ex = 0
		} else if ex > maxX {
			ex = maxX
		}
	}
	return RadarArrow{ScreenX: ex, ScreenY: ey}, true
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test -run TestPredictedArrow ./among_them/players/lively_lecun/ -v`
Expected: 5 passes.

- [ ] **Step 5: Commit**

```bash
git -C /Users/sasmith/code/bitworld2 add among_them/players/lively_lecun/task_radar.go among_them/players/lively_lecun/task_radar_test.go
git -C /Users/sasmith/code/bitworld2 commit -m "$(cat <<'EOF'
task_radar: add PredictedArrow

Per-station forward prediction of where the server draws the radar arrow,
mirroring sim.nim:2443-2472. Returns (_, false) when the station is on-
screen (server draws the icon instead). Used next by task_memory to
invert the radar-matching loop.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Remove obsolete `RadarExcluded` tests

Before changing `task_memory.go`, clear the tests that test the behavior we're about to delete. This keeps the tree green between tasks.

**Files:**
- Modify: `among_them/players/lively_lecun/task_memory_test.go`

- [ ] **Step 1: Delete three tests**

Remove these entire test functions from `task_memory_test.go`:

- `TestTaskMemory_RadarExcludedAfterKFrames` (lines 32-54)
- `TestTaskMemory_ArrowResetsStreakButDoesNotPromoteExclusion` (lines 56-85)
- `TestTaskMemory_ArrowKeepsMaybe` (lines 87-111)

Also remove the now-unused helper `anyResolvableStation` (lines 113-148).

In `TestTaskMemory_Reset` (lines 233-244), replace the line `m.Mark(10, TaskRadarExcluded)` with `m.Mark(10, TaskSeenNo)`.

- [ ] **Step 2: Run tests to verify the surviving tests pass**

Run: `go test ./among_them/players/lively_lecun/ -run TestTaskMemory -v`
Expected: remaining tests pass (`IconPromotesImmediately`, `SeenNoAfterOnScreenKFramesWithoutIcon`, `IconResetsSeenNoStreak`, `BestGoalPriorityBeatsDistance`, `BestGoalNearestInSameTier`, `MarkIsImmediate`, `Reset`).

- [ ] **Step 3: Commit**

```bash
git -C /Users/sasmith/code/bitworld2 add among_them/players/lively_lecun/task_memory_test.go
git -C /Users/sasmith/code/bitworld2 commit -m "$(cat <<'EOF'
task_memory_test: drop RadarExcluded tests

Removes three tests covering radar-driven demotion to RadarExcluded; the
next commit will delete the state itself in favor of cumulative RadarHits.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Rework `task_memory.go` — add `RadarHits`, drop `RadarExcluded`

**Files:**
- Modify: `among_them/players/lively_lecun/task_memory.go`

- [ ] **Step 1: Replace the file**

Write the full new contents of `among_them/players/lively_lecun/task_memory.go`:

```go
package main

// TaskMemory tracks per-station belief about task assignment.
//
// For each station the agent carries one of three states plus a cumulative
// radar-hit count:
//
//	known    icon was seen near the station (definitely assigned)
//	maybe    no icon evidence (starting state); RadarHits gives a
//	         cumulative radar-based confidence score
//	seen_no  station center was in viewport for onScreenNoIconK consecutive
//	         frames without an icon nearby, OR we reached the station and
//	         completed / timed out / couldn't path to it
//
// Radar scoring (per tick): for each Maybe station, predict where its
// arrow would appear on this frame (PredictedArrow). If any detected
// arrow pixel is within radarMatchTol Chebyshev of the prediction,
// RadarHits[i]++.
//
// Goal selection (BestGoal): Known beats Maybe beats SeenNo. Within
// Maybe, pick the highest cumulative-hit tier gated at 80% of the top;
// break ties by manhattan distance. See
// docs/superpowers/specs/2026-04-29-radar-hit-counting-design.md.
type TaskMemory struct {
	state                []TaskState
	radarHits            []int
	onScreenNoIconStreak []uint8
}

type TaskState uint8

const (
	TaskMaybe TaskState = iota
	TaskKnown
	TaskSeenNo
)

const (
	// On-screen-no-icon debounce: ~0.25s at 24 fps. Long enough to absorb
	// a couple of noisy icon-detector misses, short enough that a
	// single drive-by across the station locks it as SeenNo.
	onScreenNoIconK = 6

	// Chebyshev radius around a station center for "icon found at this
	// station". Matches the old dedup radius so SnapToStation and Update
	// agree on proximity.
	taskMemoryMergeRadius = 12

	// Station center must sit this far inside the viewport on every side
	// to count as "on-screen for the icon streak". The icon renders
	// ~22 px above the center (sim.nim:2316-2319), so a margin leaves
	// enough space for it to fully draw.
	onScreenMargin = 24

	// Chebyshev tolerance in screen pixels between a detected arrow and a
	// station's predicted arrow for the arrow to count as a hit. 3 px
	// covers server float-to-int rounding plus our integer-math
	// approximation of the same formula.
	radarMatchTol = 3
)

// NewTaskMemory returns a zeroed memory sized to TaskStations.
func NewTaskMemory() *TaskMemory {
	return &TaskMemory{
		state:                make([]TaskState, len(TaskStations)),
		radarHits:            make([]int, len(TaskStations)),
		onScreenNoIconStreak: make([]uint8, len(TaskStations)),
	}
}

// State returns the current state for station i.
func (m *TaskMemory) State(i int) TaskState { return m.state[i] }

// RadarHits returns the cumulative hit count for station i.
func (m *TaskMemory) RadarHits(i int) int { return m.radarHits[i] }

// Mark forces station i into state s and resets the on-screen-no-icon
// streak. Radar hits are preserved (they're long-term evidence, not a
// streak). Used for completion, arrival timeout, and unreachable-from-A*.
func (m *TaskMemory) Mark(i int, s TaskState) {
	m.state[i] = s
	m.onScreenNoIconStreak[i] = 0
}

// Reset clears every station back to maybe with 0 hits. Called on game
// boundary (sustained PhaseIdle) so a new game starts with no stale state.
func (m *TaskMemory) Reset() {
	for i := range m.state {
		m.state[i] = TaskMaybe
		m.radarHits[i] = 0
		m.onScreenNoIconStreak[i] = 0
	}
}

// Update folds one active-frame's evidence into the memory. It must be
// called every locked frame before goal selection.
//
//  1. Icons → Known (immediate).
//  2. For each Maybe station, check PredictedArrow against the detected
//     arrow pixels; increment RadarHits when a match is within radarMatchTol.
//     A single arrow may credit multiple stations (acceptable; the point is
//     cumulative evidence).
//  3. On-screen-no-icon streak: when a station's center is well inside the
//     viewport but no icon lands near it, advance the streak; at K flip to
//     SeenNo. Icon hits reset the streak.
func (m *TaskMemory) Update(player Point, cam Camera, icons []IconMatch, arrows []RadarArrow) {
	// (1) Icons → known.
	for _, ic := range icons {
		w := IconToTaskWorld(ic, cam)
		if idx := SnapToStation(w, taskMemoryMergeRadius); idx >= 0 {
			m.state[idx] = TaskKnown
			m.onScreenNoIconStreak[idx] = 0
		}
	}

	// (2) Radar: for each Maybe station, predict its arrow and check
	// against each detected arrow pixel. Chebyshev distance tolerance.
	if len(arrows) > 0 {
		for i := range TaskStations {
			if m.state[i] != TaskMaybe {
				continue
			}
			pred, ok := PredictedArrow(player, TaskStations[i].Center, cam)
			if !ok {
				continue // station is on-screen; no arrow expected.
			}
			for _, ar := range arrows {
				if absInt(ar.ScreenX-pred.ScreenX) <= radarMatchTol &&
					absInt(ar.ScreenY-pred.ScreenY) <= radarMatchTol {
					m.radarHits[i]++
					break // count at most once per frame per station.
				}
			}
		}
	}

	// (3) On-screen-no-icon streak bookkeeping.
	for i := range TaskStations {
		c := TaskStations[i].Center
		onScreen := c.X >= cam.X+onScreenMargin &&
			c.X < cam.X+ScreenWidth-onScreenMargin &&
			c.Y >= cam.Y+onScreenMargin &&
			c.Y < cam.Y+ScreenHeight-onScreenMargin
		if !onScreen {
			// Off-screen or edge-band: leave the streak unchanged so a
			// station isn't falsely reset when the player grazes past.
			// (The original code zeroed it in the off-screen branch; the
			// effect is the same now that there's no radar-driven demotion
			// competing for the fields.)
			m.onScreenNoIconStreak[i] = 0
			continue
		}
		sawIcon := false
		for _, ic := range icons {
			w := IconToTaskWorld(ic, cam)
			if absInt(w.X-c.X) <= taskMemoryMergeRadius &&
				absInt(w.Y-c.Y) <= taskMemoryMergeRadius {
				sawIcon = true
				break
			}
		}
		if sawIcon {
			m.onScreenNoIconStreak[i] = 0
			continue
		}
		if m.onScreenNoIconStreak[i] < 255 {
			m.onScreenNoIconStreak[i]++
		}
		if m.onScreenNoIconStreak[i] >= onScreenNoIconK && m.state[i] != TaskKnown {
			m.state[i] = TaskSeenNo
		}
	}
}

// BestGoal returns the station index whose state has the highest priority.
// Known beats Maybe beats SeenNo; SeenNo is never chosen. Among Known,
// closest wins. Among Maybe: let top = max(RadarHits) over Maybes. If
// top > 0, the candidate set is Maybes with RadarHits >= 0.8*top; if
// top == 0, every Maybe is a candidate. Closest of the candidate set
// wins. Returns -1 if no eligible station exists (impossible in practice
// since TaskStations is fixed and all start as Maybe).
func (m *TaskMemory) BestGoal(player Point) int {
	// Pass 1: any Known?
	best := -1
	bestDist := 0
	for i := range TaskStations {
		if m.state[i] != TaskKnown {
			continue
		}
		d := manhattan(player, TaskStations[i].Center)
		if best < 0 || d < bestDist {
			best, bestDist = i, d
		}
	}
	if best >= 0 {
		return best
	}

	// Pass 2: find top RadarHits among Maybes.
	topHits := 0
	for i := range TaskStations {
		if m.state[i] != TaskMaybe {
			continue
		}
		if m.radarHits[i] > topHits {
			topHits = m.radarHits[i]
		}
	}

	// Gate: require >= 80% of top when top > 0. Scaled integer math:
	// 5*hits >= 4*top. When top == 0 everything qualifies.
	for i := range TaskStations {
		if m.state[i] != TaskMaybe {
			continue
		}
		if topHits > 0 && 5*m.radarHits[i] < 4*topHits {
			continue
		}
		d := manhattan(player, TaskStations[i].Center)
		if best < 0 || d < bestDist {
			best, bestDist = i, d
		}
	}
	return best
}

// Priority returns the tier for station i. Lower is better. Known=0,
// Maybe=1, SeenNo=2. Exposed so the agent can compare the current goal's
// tier to the best available tier for preemption.
func (m *TaskMemory) Priority(i int) int {
	switch m.state[i] {
	case TaskKnown:
		return 0
	case TaskMaybe:
		return 1
	default:
		return 2
	}
}
```

- [ ] **Step 2: Build — catches references to removed symbols**

Run: `go build ./among_them/players/lively_lecun/`
Expected: fails if anything still references `TaskRadarExcluded`, `NearestStationAlongBearing`, `noArrowK`, `offScreenMargin`.

Any breakage must be fixed in its own step below (Task 4 handles `task_stations.go`, Task 5 handles `agent.go`). If there are no references, the build passes here.

*Note: `agent.go` does not reference `TaskRadarExcluded` by name (only by Priority()), `NearestStationAlongBearing` is called only from `task_memory.go` (now removed), and `noArrowK`/`offScreenMargin` are only referenced in `task_memory.go`. So this build should pass.*

- [ ] **Step 3: Run the surviving task_memory tests**

Run: `go test ./among_them/players/lively_lecun/ -run TestTaskMemory -v`
Expected: 7 passes (`IconPromotesImmediately`, `SeenNoAfterOnScreenKFramesWithoutIcon`, `IconResetsSeenNoStreak`, `BestGoalPriorityBeatsDistance`, `BestGoalNearestInSameTier`, `MarkIsImmediate`, `Reset`).

- [ ] **Step 4: Commit**

```bash
git -C /Users/sasmith/code/bitworld2 add among_them/players/lively_lecun/task_memory.go
git -C /Users/sasmith/code/bitworld2 commit -m "$(cat <<'EOF'
task_memory: per-station radar hit counting

Replaces nearest-along-bearing matching with per-station predicted-arrow
checks. Each Maybe station accumulates RadarHits whenever its predicted
arrow position matches a detected arrow within 3 px Chebyshev. BestGoal
now prefers Known > Maybe > SeenNo, and within Maybe picks the closest
station whose hit count is within 80% of the top-hit Maybe. RadarExcluded
and the noArrowStreak/offScreenMargin machinery are gone — low-hit
Maybes sort naturally without a terminal exclusion state.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Delete `NearestStationAlongBearing`

**Files:**
- Modify: `among_them/players/lively_lecun/task_stations.go`

- [ ] **Step 1: Remove the function**

Delete the final function of `task_stations.go` — the full block from:

```go
// NearestStationAlongBearing returns the index of the known station that
// best matches a radar bearing from the player. [...]
func NearestStationAlongBearing(player, bearing Point, reject func(int) bool) int {
    // ...
}
```

through its closing `}`. Leave `SnapToStation` and `TaskStations` untouched.

- [ ] **Step 2: Build and vet**

Run: `go build ./among_them/players/lively_lecun/ && go vet ./among_them/players/lively_lecun/`
Expected: both pass.

- [ ] **Step 3: Full test run**

Run: `go test ./among_them/players/lively_lecun/ -v`
Expected: all tests pass. (The radar-prediction tests from Task 1 plus the surviving task-memory tests; we add more in Task 6.)

- [ ] **Step 4: Commit**

```bash
git -C /Users/sasmith/code/bitworld2 add among_them/players/lively_lecun/task_stations.go
git -C /Users/sasmith/code/bitworld2 commit -m "$(cat <<'EOF'
task_stations: remove NearestStationAlongBearing

Dead code after the radar-matching inversion — task_memory now predicts
each station's arrow position directly instead of ray-casting from each
detected arrow.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Verify `agent.go` still integrates cleanly

No behavioral change expected: `a.memory.BestGoal(player)` is called the same way, `a.memory.Priority(idx)` still returns 0/1/2 (Known/Maybe/SeenNo), and `a.memory.Mark(a.goalStation, TaskSeenNo)` is still valid.

**Files:**
- Read-only: `among_them/players/lively_lecun/agent.go`

- [ ] **Step 1: Grep for removed symbols**

Run: `grep -n "TaskRadarExcluded\|NearestStationAlongBearing\|noArrowK\|offScreenMargin\|noArrowStreak" among_them/players/lively_lecun/agent.go`
Expected: no matches. If there are matches, fix each by either removing the line or, if it's a `Mark(idx, TaskRadarExcluded)`, changing to `Mark(idx, TaskSeenNo)`.

- [ ] **Step 2: Build**

Run: `go build ./among_them/players/lively_lecun/`
Expected: pass.

- [ ] **Step 3: No commit if clean**

If no changes were needed, skip the commit. If fixes were made, commit with:

```bash
git -C /Users/sasmith/code/bitworld2 add among_them/players/lively_lecun/agent.go
git -C /Users/sasmith/code/bitworld2 commit -m "$(cat <<'EOF'
agent: drop references to removed TaskRadarExcluded symbols

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add radar-matching tests in `task_memory_test.go`

Tests for the new `Update` radar-matching behavior and the `BestGoal` 80% gate.

**Files:**
- Modify: `among_them/players/lively_lecun/task_memory_test.go`

- [ ] **Step 1: Append these tests**

Append to `among_them/players/lively_lecun/task_memory_test.go` (end of file):

```go
// offScreenStationAndArrow finds any station that's off-screen for the
// given camera, computes its predicted arrow, and returns both. Used to
// generate synthetic matched arrows.
func offScreenStationAndArrow(t *testing.T, cam Camera, player Point) (int, RadarArrow) {
	t.Helper()
	for i := range TaskStations {
		ar, ok := PredictedArrow(player, TaskStations[i].Center, cam)
		if ok {
			return i, ar
		}
	}
	t.Fatalf("no off-screen station found for cam=%v", cam)
	return 0, RadarArrow{}
}

func TestTaskMemory_RadarArrowAtPredictedIncrementsHits(t *testing.T) {
	m := NewTaskMemory()
	cam := camFor(0)
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
	target, pred := offScreenStationAndArrow(t, cam, player)

	m.Update(player, cam, nil, []RadarArrow{pred})
	if got := m.RadarHits(target); got != 1 {
		t.Errorf("RadarHits(%d) = %d, want 1", target, got)
	}
}

func TestTaskMemory_ArrowBeyondToleranceIsNoHit(t *testing.T) {
	m := NewTaskMemory()
	cam := camFor(0)
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
	target, pred := offScreenStationAndArrow(t, cam, player)

	// Shift the arrow 4 px along the axis that isn't clamped to the edge.
	// If predicted ScreenX is at an edge (0 or ScreenWidth-1), shifting ScreenY
	// by 4 stays on the edge and is still out of tolerance.
	shifted := pred
	if pred.ScreenY > 4 && pred.ScreenY < ScreenHeight-4 {
		shifted.ScreenY += 4
	} else {
		shifted.ScreenX += 4
		if shifted.ScreenX >= ScreenWidth {
			shifted.ScreenX -= 8
		}
	}
	m.Update(player, cam, nil, []RadarArrow{shifted})
	if got := m.RadarHits(target); got != 0 {
		t.Errorf("RadarHits(%d) = %d, want 0 (arrow 4 px away)", target, got)
	}
}

func TestTaskMemory_OnScreenStationDoesNotCountArrow(t *testing.T) {
	m := NewTaskMemory()
	cam := camFor(0) // station 0 is on-screen under this camera.
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
	// Even if we flood the frame with arrows, on-screen station 0 gets no
	// hits (PredictedArrow returns false).
	arrows := []RadarArrow{
		{0, 0}, {ScreenWidth - 1, 0}, {0, ScreenHeight - 1}, {ScreenWidth - 1, ScreenHeight - 1},
	}
	m.Update(player, cam, nil, arrows)
	if got := m.RadarHits(0); got != 0 {
		t.Errorf("RadarHits(0) = %d, want 0 (station 0 is on-screen)", got)
	}
}

func TestTaskMemory_BestGoalEightyPercentGate(t *testing.T) {
	m := NewTaskMemory()
	// Seed three stations with different hit counts. Use Mark to keep
	// everything else out of the picture: set all other stations to
	// TaskSeenNo.
	for i := range TaskStations {
		m.Mark(i, TaskSeenNo)
	}
	// Revive three as Maybe with fabricated hit counts.
	top, mid, low := 2, 10, 20 // any three distinct indexes
	m.Mark(top, TaskMaybe)
	m.Mark(mid, TaskMaybe)
	m.Mark(low, TaskMaybe)
	m.radarHits[top] = 10 // top
	m.radarHits[mid] = 9  // within 80%
	m.radarHits[low] = 5  // below 80% gate (5*5=25 < 4*10=40)

	// Position the player so distance order is low < mid < top. The gate
	// should exclude `low`, leaving `mid` (closer of the two gated winners)
	// as the best.
	cLow := TaskStations[low].Center
	cMid := TaskStations[mid].Center
	cTop := TaskStations[top].Center
	_ = cTop
	// Put the player between low and mid, closer to mid.
	player := Point{(cLow.X*1 + cMid.X*3) / 4, (cLow.Y*1 + cMid.Y*3) / 4}

	got := m.BestGoal(player)
	if got != mid && got != top {
		t.Errorf("BestGoal = %d, want one of [%d, %d] (80%% gate should exclude low=%d)",
			got, mid, top, low)
	}
	// Exactly which of mid/top wins depends on station geometry; what
	// matters is `low` is excluded.
	if got == low {
		t.Errorf("BestGoal returned %d which is below the 80%% gate", low)
	}
}

func TestTaskMemory_BestGoalTopZeroFallsBackToDistance(t *testing.T) {
	m := NewTaskMemory()
	// Default state: all Maybe with 0 hits. BestGoal must still return
	// something — the closest station.
	c := TaskStations[0].Center
	player := Point{c.X, c.Y}
	if got := m.BestGoal(player); got != 0 {
		t.Errorf("BestGoal at station 0 center (all 0 hits) = %d, want 0", got)
	}
}

func TestTaskMemory_BestGoalKnownBeatsHighHitMaybe(t *testing.T) {
	m := NewTaskMemory()
	// Put all stations in SeenNo except one Known and one Maybe with lots of
	// hits. Known must win regardless of hit count.
	for i := range TaskStations {
		m.Mark(i, TaskSeenNo)
	}
	knownIdx, maybeIdx := 5, 20
	m.Mark(knownIdx, TaskKnown)
	m.Mark(maybeIdx, TaskMaybe)
	m.radarHits[maybeIdx] = 1000

	// Player far from Known, near Maybe — Known still wins.
	player := TaskStations[maybeIdx].Center
	if got := m.BestGoal(player); got != knownIdx {
		t.Errorf("BestGoal = %d, want %d (Known must beat Maybe with %d hits)",
			got, knownIdx, m.radarHits[maybeIdx])
	}
}
```

- [ ] **Step 2: Run the new tests**

Run: `go test ./among_them/players/lively_lecun/ -run TestTaskMemory -v`
Expected: all pass.

- [ ] **Step 3: Full package test**

Run: `go test ./among_them/players/lively_lecun/ -v`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git -C /Users/sasmith/code/bitworld2 add among_them/players/lively_lecun/task_memory_test.go
git -C /Users/sasmith/code/bitworld2 commit -m "$(cat <<'EOF'
task_memory_test: cover RadarHits and the 80% gate

Adds: arrow-at-predicted increments RadarHits; arrow 4 px away doesn't;
on-screen station ignores radar pixels; BestGoal 80% gate excludes
low-hit Maybes; fallback to distance when every Maybe has 0 hits;
Known beats high-hit Maybe.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: End-to-end sanity — full build, vet, and test

- [ ] **Step 1: Full package validation**

Run:
```bash
go build ./among_them/players/lively_lecun/
go vet ./among_them/players/lively_lecun/
go test ./among_them/players/lively_lecun/
```
Expected: all pass.

- [ ] **Step 2: Search for any lingering stale symbols at repo scope**

Run:
```bash
grep -rn "TaskRadarExcluded\|NearestStationAlongBearing" among_them/players/lively_lecun/ || echo "clean"
```
Expected: `clean`.

- [ ] **Step 3: No commit** (validation only)

---

## Self-Review

**Spec coverage.**

- State changes (add `RadarHits`, drop `RadarExcluded`, drop `noArrowStreak`) → Task 3.
- Drop `NearestStationAlongBearing` → Task 4.
- Per-tick inverted matching (mirror `sim.nim:2443-2472`, τ=3 Chebyshev, credit all matching stations) → Task 1 + Task 3 step 1 (the radar loop).
- On-screen neutral (no hit change) → Task 3 step 1 (radar loop returns early when `PredictedArrow` returns `ok=false`) + test coverage in Task 6.
- Goal selection (Known → 80% gate Maybe → closest) → Task 3 step 1 (`BestGoal`).
- Migration (RadarExcluded → Maybe with 0 hits) → n/a at the type level since `RadarExcluded` is deleted entirely; any existing live agent that restarts just starts with all-Maybe, which is correct.
- Tests: predicted position, beyond tolerance, shared arrow (implicitly covered by the loop's `break` — each station matched once — and each *station* gets credit independently; not a listed test but the radar loop structure makes it impossible to skip a station), on-screen neutral, 80% gate, top-zero fallback, Known-beats-Maybe → Tasks 1 and 6.
- Removal of old `TestTaskMemory_RadarExcludedAfterKFrames` et al → Task 2.

**Placeholder scan.** No "TODO" / "TBD" / "handle edge cases" without code. All code blocks complete.

**Type consistency.** `PredictedArrow(player, station Point, cam Camera) (RadarArrow, bool)` consistent across Task 1 and Task 3. `radarMatchTol = 3`, `RadarHits(i)` exported, `BestGoal` returns int — consistent.

**One missing test the spec called for:** `TestRadarMatching_SharedArrowCreditsBoth`. Not added because under the rigid `sim.nim` projection formula, two stations with overlapping predicted-arrow positions (within τ=3 of each other) would require a specific geometric setup with two real stations. The existing test set verifies the per-station loop credits exactly one hit per station, which is the mechanism. If we want this test, it would need synthetic stations — out of scope for v1. Noting this gap and leaving the verification at the mechanism level.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-29-radar-hit-counting.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?

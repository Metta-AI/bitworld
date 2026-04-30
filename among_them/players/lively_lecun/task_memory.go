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

package main

// TaskMemory tracks per-station belief about task assignment.
//
// Goal selection works over the full TaskStations list (sim.nim's fixed spawn
// set). For each station the agent carries one of four states. During goal
// selection the agent prefers higher-priority states, breaking ties by
// manhattan distance. Deprioritized states are still visited once better
// candidates are exhausted -- nothing is permanently banned.
//
//	known           icon was seen near the station (definitely assigned)
//	maybe           no evidence either way (starting state)
//	radar_excluded  station is off-screen and no arrow has pointed at it for
//	                noArrowK consecutive frames
//	seen_no         station center was in viewport for onScreenNoIconK
//	                consecutive frames without an icon nearby, OR we reached
//	                it and completed / timed out / couldn't path to it
//
// Streak counters are clamped so a sustained absence keeps the state flipped
// without overflowing. See 2026-04-29-task-memory-4state-design.md.
type TaskMemory struct {
	state                []TaskState
	noArrowStreak        []uint8
	onScreenNoIconStreak []uint8
}

type TaskState uint8

const (
	TaskMaybe TaskState = iota
	TaskKnown
	TaskRadarExcluded
	TaskSeenNo
)

const (
	// K-frame debounce thresholds. ~0.25s at 24 fps: long enough to absorb
	// one or two noisy detector frames, short enough that the player's
	// first lap around the ship narrows the candidate set.
	noArrowK         = 6
	onScreenNoIconK  = 6

	// Chebyshev radius around a station center for "icon found at this
	// station". Matches the old dedup radius so SnapToStation and Update
	// agree on proximity.
	taskMemoryMergeRadius = 12

	// When computing "station on-screen for the icon streak", require the
	// station center to sit this many world-pixels inside the viewport on
	// every side. The icon draws ~22 px above the center (sim.nim:2316-
	// 2319); a margin leaves enough space for it to fully render.
	onScreenMargin = 24

	// "Station off-screen for the radar streak": station center is at
	// least this far outside the viewport. The small outer buffer avoids
	// the edge band where neither radar nor icon reliably fires
	// (sim.nim:2629-2631).
	offScreenMargin = 4
)

// NewTaskMemory returns a zeroed memory sized to TaskStations.
func NewTaskMemory() *TaskMemory {
	return &TaskMemory{
		state:                make([]TaskState, len(TaskStations)),
		noArrowStreak:        make([]uint8, len(TaskStations)),
		onScreenNoIconStreak: make([]uint8, len(TaskStations)),
	}
}

// State returns the current state for station i.
func (m *TaskMemory) State(i int) TaskState { return m.state[i] }

// Mark forces station i into state s and resets both streaks. Used for
// completion, arrival timeout, and unreachable-from-A*.
func (m *TaskMemory) Mark(i int, s TaskState) {
	m.state[i] = s
	m.noArrowStreak[i] = 0
	m.onScreenNoIconStreak[i] = 0
}

// Reset clears every station back to maybe. Called on game boundary (sustained
// PhaseIdle) so a new game starts with no stale state.
func (m *TaskMemory) Reset() {
	for i := range m.state {
		m.state[i] = TaskMaybe
		m.noArrowStreak[i] = 0
		m.onScreenNoIconStreak[i] = 0
	}
}

// Update folds one active-frame's evidence into the memory. It must be called
// every locked frame before goal selection. Order of operations:
//
//  1. Icon evidence promotes matched stations to known immediately.
//  2. Radar arrows that resolve to a station reset that station's no-arrow
//     streak (evidence of assignment) and demote radar_excluded → maybe.
//  3. For each station, advance or reset the off-screen-no-arrow streak and
//     the on-screen-no-icon streak based on viewport position. When either
//     streak crosses its K threshold, demote state (never over known).
func (m *TaskMemory) Update(player Point, cam Camera, icons []IconMatch, arrows []RadarArrow) {
	// (1) Icons → known.
	for _, ic := range icons {
		w := IconToTaskWorld(ic, cam)
		if idx := SnapToStation(w, taskMemoryMergeRadius); idx >= 0 {
			m.state[idx] = TaskKnown
			m.noArrowStreak[idx] = 0
			m.onScreenNoIconStreak[idx] = 0
		}
	}

	// (2) Arrows → reset per-station no-arrow streak. Aggregate which
	// stations are along current arrows so a station is counted at most
	// once per frame even when several arrows cluster.
	//
	// An arrow only *prevents* demotion to RadarExcluded on a station
	// that's still Maybe; it does NOT promote an already-excluded station
	// back to Maybe. Promotion to Maybe was creating a tier-1 tie between
	// every arrow-resolved station and every other Maybe, which made
	// BestGoal pick by distance alone -- the agent would wander between
	// nearby Maybes while its assigned (arrowed) stations stayed tied
	// and never preferred. Now RadarExcluded is a terminal decision
	// (modulo Mark/Reset), so the tier-1 pool shrinks to just the
	// stations where arrow evidence landed early enough to keep them.
	arrowed := make(map[int]struct{}, len(arrows))
	for _, ar := range arrows {
		bearing := Point{cam.X + ar.ScreenX, cam.Y + ar.ScreenY}
		if idx := NearestStationAlongBearing(player, bearing, nil); idx >= 0 {
			arrowed[idx] = struct{}{}
		}
	}
	for idx := range arrowed {
		m.noArrowStreak[idx] = 0
	}

	// (3) Per-station streak bookkeeping.
	for i := range TaskStations {
		c := TaskStations[i].Center

		offScreen := c.X < cam.X-offScreenMargin ||
			c.X >= cam.X+ScreenWidth+offScreenMargin ||
			c.Y < cam.Y-offScreenMargin ||
			c.Y >= cam.Y+ScreenHeight+offScreenMargin

		onScreen := c.X >= cam.X+onScreenMargin &&
			c.X < cam.X+ScreenWidth-onScreenMargin &&
			c.Y >= cam.Y+onScreenMargin &&
			c.Y < cam.Y+ScreenHeight-onScreenMargin

		// Radar streak.
		if offScreen {
			if _, hit := arrowed[i]; !hit {
				if m.noArrowStreak[i] < 255 {
					m.noArrowStreak[i]++
				}
				if m.noArrowStreak[i] >= noArrowK &&
					m.state[i] != TaskKnown && m.state[i] != TaskSeenNo {
					m.state[i] = TaskRadarExcluded
				}
			}
			// Off-screen can't contribute to the on-screen streak.
			m.onScreenNoIconStreak[i] = 0
			continue
		}

		// Not off-screen: any no-arrow inference must not continue.
		m.noArrowStreak[i] = 0

		if onScreen {
			// Icon streak. An icon within taskMemoryMergeRadius of the
			// center was already promoted to known above; when that
			// happens state[i] == TaskKnown and we reset the streak.
			// Otherwise on-screen frames with no icon accumulate.
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
			if m.onScreenNoIconStreak[i] >= onScreenNoIconK &&
				m.state[i] != TaskKnown {
				m.state[i] = TaskSeenNo
			}
		} else {
			// Edge band: neither off-screen nor clearly on-screen. Leave
			// streaks unchanged so a station isn't falsely reset when the
			// player is grazing past.
		}
	}
}

// BestGoal returns the station index whose state has the highest priority,
// breaking ties by shortest manhattan distance from player. Returns -1 if
// no stations exist (impossible in practice since TaskStations is fixed).
func (m *TaskMemory) BestGoal(player Point) int {
	best := -1
	bestTier, bestDist := 0, 0
	for i := range TaskStations {
		t := statePriority(m.state[i])
		d := manhattan(player, TaskStations[i].Center)
		if best < 0 || t < bestTier || (t == bestTier && d < bestDist) {
			best, bestTier, bestDist = i, t, d
		}
	}
	return best
}

// Priority returns the tier for station i. Lower is better. Exposed so the
// agent can compare the current goal's tier to the best available tier.
func (m *TaskMemory) Priority(i int) int { return statePriority(m.state[i]) }

func statePriority(s TaskState) int {
	switch s {
	case TaskKnown:
		return 0
	case TaskMaybe:
		return 1
	case TaskRadarExcluded:
		return 2
	default: // TaskSeenNo or unexpected
		return 3
	}
}

package main

const (
	// TaskCompleteTicks in sim.nim:39 is 72 by default. Hold a few extra
	// ticks of slack to cover round-trip latency between our release and
	// the server applying it.
	taskHoldTicks = 80

	// World-space half-side of the task box. Every in-game task rect is
	// 16x16 (IconToTaskWorld derivation), so the player must be within 8
	// world pixels of the task center on both axes to stand on it. Be
	// slightly tighter than 8 to avoid firing at the edge.
	onTaskRadius = 6
)

// OnTask reports whether an exact 12×12 task-icon template matches a task
// that the player is standing on. Comparison is done in world space: the
// icon implies a task-box center (IconToTaskWorld), and the player must be
// within onTaskRadius of that center. Screen-space comparison is too loose
// because the icon is drawn ~16 px above the task box, so a radius wide
// enough to cover Y also wraps in nearby tasks on X.
func OnTask(matches []IconMatch, player Point, cam Camera) bool {
	for _, m := range matches {
		w := IconToTaskWorld(m, cam)
		if absInt(w.X-player.X) <= onTaskRadius && absInt(w.Y-player.Y) <= onTaskRadius {
			return true
		}
	}
	return false
}

// TaskHolder turns "I see a task icon at my position" into "release direction
// inputs and stand still long enough to complete the task." The sim completes
// a task when a crewmate stands on the station with no direction inputs for
// taskCompleteTicks ticks (sim.nim:1247-1253).
//
// The zero value is the initial state.
type TaskHolder struct {
	holding   int
	Completes int // total holds that ran to completion (for logging)
}

// Adjust returns (mask, handled). When handled is true the caller should
// send the returned mask (ButtonA only, no directions -- the sim requires
// attack pressed and inputX/inputY both zero to advance taskProgress, per
// sim.nim:1135-1152). When false, the caller falls through to Bumper+Steer.
func (h *TaskHolder) Adjust(matches []IconMatch, player Point, cam Camera) (uint8, bool) {
	if h.holding > 0 {
		h.holding--
		if h.holding == 0 {
			h.Completes++
		}
		return ButtonA, true
	}
	if OnTask(matches, player, cam) {
		// Trigger call returns ButtonA itself, so the remaining decrement-only
		// handled returns is one fewer than the total hold.
		h.holding = taskHoldTicks - 1
		return ButtonA, true
	}
	return 0, false
}

// IsHolding reports whether we're currently in the middle of a task hold.
func (h *TaskHolder) IsHolding() bool { return h.holding > 0 }

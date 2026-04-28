package main

const (
	// Region centered above the player's on-screen position where a task
	// icon overlay would land when the player is standing on a task. The
	// icon sprite (12x12) is drawn ~14 px above the task's tile per
	// sim.nim:2318-2319, and the player is at screen center (64,64).
	taskRegionX0    = 50
	taskRegionY0    = 36
	taskRegionW     = 28
	taskRegionH     = 28
	taskOnThreshold = 8 // measured: 17 in playing_on_task, 0 in regular playing

	// TaskCompleteTicks in sim.nim:39 is 72 by default. Hold a few extra
	// ticks of slack to cover round-trip latency between our release and
	// the server applying it.
	taskHoldTicks = 80
)

// OnTask reports whether a task-icon sprite is overlapping the player's
// on-screen position. The icon is palette 9 (the on-screen task indicator
// color, distinct from palette 8's off-screen radar arrows).
func OnTask(pixels []uint8) bool {
	if len(pixels) != ScreenWidth*ScreenHeight {
		return false
	}
	var count int
	for y := taskRegionY0; y < taskRegionY0+taskRegionH; y++ {
		row := pixels[y*ScreenWidth : (y+1)*ScreenWidth]
		for x := taskRegionX0; x < taskRegionX0+taskRegionW; x++ {
			if row[x] == taskIconColor {
				count++
			}
		}
	}
	return count >= taskOnThreshold
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
func (h *TaskHolder) Adjust(pixels []uint8) (uint8, bool) {
	if h.holding > 0 {
		h.holding--
		if h.holding == 0 {
			h.Completes++
		}
		return ButtonA, true
	}
	if OnTask(pixels) {
		// Trigger call returns ButtonA itself, so the remaining decrement-only
		// handled returns is one fewer than the total hold.
		h.holding = taskHoldTicks - 1
		return ButtonA, true
	}
	return 0, false
}

// IsHolding reports whether we're currently in the middle of a task hold.
func (h *TaskHolder) IsHolding() bool { return h.holding > 0 }

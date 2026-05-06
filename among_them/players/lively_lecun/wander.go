package main

// Wanderer emits a cardinal direction when no other layer (Steer, Navigator)
// has a preference. It rotates through the four cardinals, holding each for
// wanderHoldFrames, so the agent drifts around the map to bring task icons
// or radar arrows into view rather than stalling at a blank spot.
//
// The zero value is the initial state.
type Wanderer struct {
	held int // frames remaining on the current direction
	idx  int // index into wanderDirs
}

const wanderHoldFrames = 36 // ~1.5 s at 24 fps

var wanderDirs = [4]uint8{ButtonRight, ButtonDown, ButtonLeft, ButtonUp}

// Next returns a cardinal direction for this frame. Each direction is held
// for wanderHoldFrames frames before rotating to the next.
func (w *Wanderer) Next() uint8 {
	if w.held <= 0 {
		w.held = wanderHoldFrames
		w.idx = (w.idx + 1) & 3
	}
	w.held--
	return wanderDirs[w.idx]
}

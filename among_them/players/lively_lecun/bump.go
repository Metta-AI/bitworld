package main

// Bumper wraps a desired button mask with a "stuck against geometry" guard.
// We can't read the map's wall layer from the client, so instead we watch
// frame-to-frame pixel motion: free movement scrolls the camera and changes
// thousands of pixels per frame, while being pinned against a wall only
// shows tens of pixels of animation. When motion stays low for several
// consecutive frames we substitute a perpendicular direction for a short
// burst, then resume the desired mask.
//
// The zero value is the initial state.
type Bumper struct {
	prev            []uint8
	lowMotionStreak int
	perturbing      int
	perturbMask     uint8
	tick            int
	Perturbs        int // total number of perturb events triggered (for logging)
}

const (
	bumperMotionThreshold = 400 // per-frame pixel-diff floor for "moving"
	bumperStuckStreak     = 4   // consecutive low-motion frames before perturb
	bumperPerturbTicks    = 8   // how long the perturbation lasts
)

// Adjust returns the mask to actually send. `want` is the steering layer's
// preferred direction; pixels is the current frame.
func (b *Bumper) Adjust(pixels []uint8, want uint8) uint8 {
	b.tick++

	diff := -1
	if len(pixels) == ScreenWidth*ScreenHeight {
		if b.prev != nil {
			diff = pixelDiff(pixels, b.prev)
		} else {
			b.prev = make([]uint8, len(pixels))
		}
		copy(b.prev, pixels)
	}

	if b.perturbing > 0 {
		b.perturbing--
		return b.perturbMask
	}

	if diff >= 0 && diff < bumperMotionThreshold {
		b.lowMotionStreak++
	} else {
		b.lowMotionStreak = 0
	}

	if want != 0 && b.lowMotionStreak >= bumperStuckStreak {
		b.perturbMask = perpendicular(want, b.tick)
		// Trigger call returns the perturb mask itself, so the remaining
		// perturb-returning calls is one fewer.
		b.perturbing = bumperPerturbTicks - 1
		b.lowMotionStreak = 0
		b.Perturbs++
		return b.perturbMask
	}

	return want
}

// pixelDiff counts the positions where two frames differ.
func pixelDiff(a, b []uint8) int {
	if len(a) != len(b) {
		return len(a) + len(b)
	}
	var n int
	for i, v := range a {
		if v != b[i] {
			n++
		}
	}
	return n
}

// perpendicular picks a 90°-rotated cardinal direction. If `want` has a
// horizontal component (with or without a vertical one) we return Up or
// Down; if it's purely vertical we return Left or Right. The seed picks
// between the two so we don't always escape the same way.
func perpendicular(want uint8, seed int) uint8 {
	if want&(ButtonLeft|ButtonRight) != 0 {
		if seed&1 == 0 {
			return ButtonUp
		}
		return ButtonDown
	}
	if want&(ButtonUp|ButtonDown) != 0 {
		if seed&1 == 0 {
			return ButtonLeft
		}
		return ButtonRight
	}
	return 0
}

package main

// Tracker maintains a running lock on the camera position by preferring
// cheap incremental fits (a 33x33 search window around the previous lock)
// and falling back to brute force only when that fails. The zero value is
// not usable; call NewTracker.
type Tracker struct {
	Map    *Map
	Last   Camera
	Locked bool
	Brutes int // count of brute-force locks (logging)
}

func NewTracker(m *Map) *Tracker {
	return &Tracker{Map: m}
}

// Update inspects the current frame and returns (cam, ok). When ok is
// false, no confident lock could be obtained from this frame and the
// caller should treat position as unknown.
func (t *Tracker) Update(frame []uint8) (Camera, bool) {
	if t.Map == nil {
		return Camera{}, false
	}
	if t.Locked {
		if cam, ok := Localize(frame, t.Map, &t.Last); ok {
			t.Last = cam
			return cam, true
		}
		t.Locked = false
	}
	if cam, ok := Localize(frame, t.Map, nil); ok {
		t.Last = cam
		t.Locked = true
		t.Brutes++
		return cam, true
	}
	return Camera{}, false
}

// PlayerPosition returns the player's approximate world coordinates,
// derived from the camera lock. The player's visible sprite is centered
// at (ScreenWidth/2, ScreenHeight/2) in screen space (sim.nim:1302-1303),
// so adding that offset to the camera's top-left gives the player's
// world position to within a few pixels.
func (t *Tracker) PlayerPosition() (int, int, bool) {
	if !t.Locked {
		return 0, 0, false
	}
	return t.Last.X + ScreenWidth/2, t.Last.Y + ScreenHeight/2, true
}

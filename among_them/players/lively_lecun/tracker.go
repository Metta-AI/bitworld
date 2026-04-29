package main

// Tracker maintains a running lock on the camera position by preferring
// cheap incremental fits (a 33x33 search window around the previous lock)
// and falling back to brute force only when that fails. The zero value is
// not usable; call NewTracker.
type Tracker struct {
	Map      *Map
	Last     Camera
	Locked   bool
	Brutes   int // count of brute-force locks (logging)
	LastMiss int // best Mismatches seen in the most recent Update call
}

func NewTracker(m *Map) *Tracker {
	return &Tracker{Map: m}
}

// Update inspects the current frame and returns (cam, ok). When ok is
// false, no confident lock could be obtained from this frame and the
// caller should treat position as unknown. LastMiss holds the best
// Mismatches seen on the most recent Update (whether locked or not),
// useful for diagnostics when lock is lost.
func (t *Tracker) Update(frame []uint8) (Camera, bool) {
	if t.Map == nil {
		return Camera{}, false
	}
	if t.Locked {
		if cam, ok := Localize(frame, t.Map, &t.Last); ok {
			t.Last = cam
			t.LastMiss = cam.Mismatches
			return cam, true
		}
		t.Locked = false
	}
	cam, ok := Localize(frame, t.Map, nil)
	t.LastMiss = cam.Mismatches
	if ok {
		t.Last = cam
		t.Locked = true
		t.Brutes++
		return cam, true
	}
	return Camera{}, false
}

// PlayerPosition returns the player's world coordinates (exact, modulo
// any sub-pixel lock error) derived from the camera. Inverting sim.nim's
// cameraFor (sim.nim:1298-1303):
//
//	cameraX = (player.x - SpriteDrawOffX) + SpriteSize/2 - ScreenWidth/2
//	        = player.x - 2 + 6 - 64 = player.x - 60
//	cameraY = (player.y - SpriteDrawOffY) + SpriteSize/2 - ScreenHeight/2
//	        = player.y - 8 + 6 - 64 = player.y - 66
//
// so player.x = cam.X + 60 and player.y = cam.Y + 66. This matches
// sim.nim's task-hitbox check (sim.nim:1144), so using these coords with
// onTaskRadius lands inside the real 16x16 task rect.
const (
	playerWorldOffX = 60
	playerWorldOffY = 66
)

func (t *Tracker) PlayerPosition() (int, int, bool) {
	if !t.Locked {
		return 0, 0, false
	}
	return t.Last.X + playerWorldOffX, t.Last.Y + playerWorldOffY, true
}

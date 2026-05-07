package main

// Camera is a candidate top-left position of the screen window in world
// coordinates, plus a Mismatches score (lower = better fit).
type Camera struct {
	X, Y       int
	Mismatches int
}

// localizeMaxMiss is the largest mismatch count Localize will still accept
// as a confident lock. Out of localizeSamples (~252), a correct lock
// typically misses 30-60 points (player sprite, other actors, shadow
// overlay), while a wrong lock misses ~94% (≈237) since palette agreement
// at random offsets is ~1/16 per pixel.
//
// Live play shows transient bursts of ~100 mismatches when multiple
// off-screen task radar arrows land on sample pixels at once; 100 was
// just low enough to drop lock during those bursts. 140 still leaves a
// >90-sample gap to wrong-lock territory.
const localizeMaxMiss = 140

// mapVoidColor mirrors sim.nim:33 `MapVoidColor = 12`. When the server's
// camera extends past the map edge, sim.nim:2509 clears those off-map
// pixels to MapVoidColor and then only overwrites the in-bounds ones
// (sim.nim:2520-2526). For the tracker to lock at the east / south map
// edge, samples that fall outside MapWidth/MapHeight must check against
// this color rather than count as unconditional mismatches.
const mapVoidColor uint8 = 12

// The server doesn't clamp the camera to the map rect -- sim.nim:1571-1572
// sets cameraX = player.x - 60 / cameraY = player.y - 66 without any
// clamping, while player.x/y are bounded only by [0, MapWidth-CollisionW]
// / [0, MapHeight-CollisionH]. So the camera can range:
//
//	cameraX in [-playerWorldOffX, MapWidth-CollisionW-playerWorldOffX]
//	cameraY in [-playerWorldOffY, MapHeight-CollisionH-playerWorldOffY]
//
// The previous bounds [0, MapWidth-ScreenWidth] / [0, MapHeight-ScreenHeight]
// excluded ~60 columns of valid camera positions on each side, which is
// exactly where agents ended up stuck against walls: the server painted the
// real camera past our search range, so brute-force returned a best-case
// miss around 140-150 at the boundary of our range and the tracker never
// relocked.
const (
	minCameraX = -playerWorldOffX
	minCameraY = -playerWorldOffY
	maxCameraX = MapWidth - 1 - playerWorldOffX  // CollisionW = 1
	maxCameraY = MapHeight - 1 - playerWorldOffY // CollisionH = 1
)

// localizeSamples is a precomputed grid of (sx, sy) screen positions where
// Localize compares the frame to candidate map pixels. An 8x8 stride from
// (4,4) yields 16x16 = 256 candidates; we drop those inside a 16x16 box
// around the player center because the player sprite always occludes the
// map there, leaving 252 useful samples.
var localizeSamples = func() [][2]int {
	var pts [][2]int
	for y := 4; y < ScreenHeight; y += 8 {
		for x := 4; x < ScreenWidth; x += 8 {
			if absInt(x-playerScreenCenterX) < playerExclusionRadius &&
				absInt(y-playerScreenCenterY) < playerExclusionRadius {
				continue
			}
			pts = append(pts, [2]int{x, y})
		}
	}
	return pts
}()

// Localize finds the camera position whose corresponding map window best
// matches the frame. If hint != nil, the search is constrained to a 33×33
// window around the hint (cheap incremental track); otherwise it brute-
// forces the full ~336K candidate space (slow, but only needed for the
// first lock per game).
//
// Returns (cam, true) when Mismatches < localizeMaxMiss; otherwise the
// best-found candidate is returned with ok=false.
func Localize(frame []uint8, m *Map, hint *Camera) (Camera, bool) {
	if len(frame) != ScreenWidth*ScreenHeight || m == nil {
		return Camera{}, false
	}
	const trackRadius = 16
	minCX, maxCX := minCameraX, maxCameraX
	minCY, maxCY := minCameraY, maxCameraY
	if hint != nil {
		minCX = clamp(hint.X-trackRadius, minCameraX, maxCameraX)
		maxCX = clamp(hint.X+trackRadius, minCameraX, maxCameraX)
		minCY = clamp(hint.Y-trackRadius, minCameraY, maxCameraY)
		maxCY = clamp(hint.Y+trackRadius, minCameraY, maxCameraY)
	}

	// Precompute the frame's sample values so the inner loop only touches
	// the map.
	type sample struct {
		sx, sy int
		v      uint8
	}
	samples := make([]sample, len(localizeSamples))
	for i, p := range localizeSamples {
		samples[i] = sample{p[0], p[1], frame[p[1]*ScreenWidth+p[0]]}
	}

	bestCX, bestCY := minCX, minCY
	bestMiss := len(samples) + 1

	for cy := minCY; cy <= maxCY; cy++ {
		for cx := minCX; cx <= maxCX; cx++ {
			miss := 0
			for _, s := range samples {
				mx, my := cx+s.sx, cy+s.sy
				if mx >= 0 && mx < MapWidth && my >= 0 && my < MapHeight {
					if s.v != m.Pixels[my*MapWidth+mx] {
						miss++
					}
				} else if s.v != mapVoidColor {
					// Off-map: server paints MapVoidColor there
					// (sim.nim:2509). Anything else is a real miss.
					miss++
				}
				if miss >= bestMiss {
					break // early-out: this candidate is already worse
				}
			}
			if miss < bestMiss {
				bestMiss = miss
				bestCX, bestCY = cx, cy
			}
		}
	}

	cam := Camera{X: bestCX, Y: bestCY, Mismatches: bestMiss}
	return cam, bestMiss < localizeMaxMiss
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

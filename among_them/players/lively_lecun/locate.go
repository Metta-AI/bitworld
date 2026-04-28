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
const localizeMaxMiss = 100

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
	minCX, maxCX := 0, MapWidth-ScreenWidth
	minCY, maxCY := 0, MapHeight-ScreenHeight
	if hint != nil {
		minCX = clamp(hint.X-trackRadius, 0, MapWidth-ScreenWidth)
		maxCX = clamp(hint.X+trackRadius, 0, MapWidth-ScreenWidth)
		minCY = clamp(hint.Y-trackRadius, 0, MapHeight-ScreenHeight)
		maxCY = clamp(hint.Y+trackRadius, 0, MapHeight-ScreenHeight)
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
				} else {
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

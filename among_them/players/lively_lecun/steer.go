package main

const (
	// Task markers from sim.nim's renderer. Palette 8 is the off-screen
	// radar arrow color (radarColor in sim.nim:2337); palette 9 is the
	// on-screen task icon sprite color, observed by inspecting the
	// playing_on_task fixture (125 px of palette 9, none in regular
	// playing). Palette 10 (yellow) is map decoration, not task-related.
	taskRadarColor = 8
	taskIconColor  = 9

	playerScreenCenterX   = ScreenWidth / 2
	playerScreenCenterY   = ScreenHeight / 2
	playerExclusionRadius = 8 // half-side of a 16x16 box covering own sprite
	steerDeadband         = 4 // ignore tiny centroid offsets
)

// Steer returns a button mask that walks the agent toward the centroid of
// task-marker pixels (palettes 8 and 9: off-screen radar arrows + on-screen
// task icons). Pulling the agent toward task indicators is a cheap reactive
// behavior that biases movement toward task stations.
//
// A small box around the player's on-screen position is excluded so the
// agent isn't attracted to its own sprite if it has yellow accents.
//
// Returns 0 when there are no yellow pixels outside the exclusion zone or
// when the centroid is within the deadband, so the caller can fall back
// to other behavior (e.g., wandering).
//
// pixels must be ScreenWidth*ScreenHeight long; otherwise returns 0.
func Steer(pixels []uint8) uint8 {
	if len(pixels) != ScreenWidth*ScreenHeight {
		return 0
	}
	var sumX, sumY, count int
	for y := 0; y < ScreenHeight; y++ {
		dy := y - playerScreenCenterY
		row := pixels[y*ScreenWidth : (y+1)*ScreenWidth]
		for x, v := range row {
			if v != taskRadarColor && v != taskIconColor {
				continue
			}
			dx := x - playerScreenCenterX
			if absInt(dx) < playerExclusionRadius && absInt(dy) < playerExclusionRadius {
				continue
			}
			sumX += dx
			sumY += dy
			count++
		}
	}
	if count == 0 {
		return 0
	}
	cx := sumX / count
	cy := sumY / count
	var mask uint8
	if cx > steerDeadband {
		mask |= ButtonRight
	} else if cx < -steerDeadband {
		mask |= ButtonLeft
	}
	if cy > steerDeadband {
		mask |= ButtonDown
	} else if cy < -steerDeadband {
		mask |= ButtonUp
	}
	return mask
}

func absInt(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

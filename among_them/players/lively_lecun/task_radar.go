package main

// RadarArrow is a single palette-8 pixel on the screen border. sim.nim:2336-
// 2386 draws one arrow per incomplete task we own whose icon isn't on
// screen; the border pixel sits where the ray from the player center
// through the task crosses the viewport edge (margin=0, so arrows live at
// x ∈ {0, ScreenWidth-1} or y ∈ {0, ScreenHeight-1}).
type RadarArrow struct {
	ScreenX, ScreenY int
}

// FindRadarArrows scans the four screen borders for palette-8 pixels and
// returns each hit as a RadarArrow. pa8 is only used by the arrow renderer
// (sim.nim:2337), so border pa8 pixels are one-for-one arrow indicators.
func FindRadarArrows(pixels []uint8) []RadarArrow {
	if len(pixels) != ScreenWidth*ScreenHeight {
		return nil
	}
	var out []RadarArrow
	top := 0
	bot := (ScreenHeight - 1) * ScreenWidth
	for x := 0; x < ScreenWidth; x++ {
		if pixels[top+x] == taskRadarColor {
			out = append(out, RadarArrow{x, 0})
		}
		if pixels[bot+x] == taskRadarColor {
			out = append(out, RadarArrow{x, ScreenHeight - 1})
		}
	}
	// Skip the corners on the side borders; they've already been tested.
	for y := 1; y < ScreenHeight-1; y++ {
		if pixels[y*ScreenWidth] == taskRadarColor {
			out = append(out, RadarArrow{0, y})
		}
		if pixels[y*ScreenWidth+ScreenWidth-1] == taskRadarColor {
			out = append(out, RadarArrow{ScreenWidth - 1, y})
		}
	}
	return out
}

// nearestWalkable spiral-searches outward from p up to maxRadius for a
// walkable cell. Returns (p, true) when p itself is walkable.
func nearestWalkable(w *WalkMask, p Point, maxRadius int) (Point, bool) {
	if w.Walkable(p.X, p.Y) {
		return p, true
	}
	for r := 1; r <= maxRadius; r++ {
		for dy := -r; dy <= r; dy++ {
			for dx := -r; dx <= r; dx++ {
				if absInt(dx) != r && absInt(dy) != r {
					continue // interior already checked at smaller r
				}
				q := Point{p.X + dx, p.Y + dy}
				if w.Walkable(q.X, q.Y) {
					return q, true
				}
			}
		}
	}
	return Point{}, false
}

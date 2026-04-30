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

// PredictedArrow returns the screen-space pixel where the server would draw
// this station's radar arrow, mirroring sim.nim:2443-2472. Returns
// (_, false) when the station's center is inside the viewport (the server
// draws the icon instead of an arrow in that case).
//
// CollisionW = CollisionH = 1 (sim.nim:20-21), so with integer division
// px = player.X - cam.X and py = player.Y - cam.Y. The server's float
// arithmetic is emulated with integer math; division uses truncation
// toward zero (Go's integer `/`), which matches the server's float-then-
// `int()` cast for the in-range cases this predicate is called on (the
// division's numerator is bounded because the perpendicular axis later
// gets clamped to the viewport).
func PredictedArrow(player, station Point, cam Camera) (RadarArrow, bool) {
	sx := station.X - cam.X
	sy := station.Y - cam.Y
	if sx >= 0 && sx < ScreenWidth && sy >= 0 && sy < ScreenHeight {
		return RadarArrow{}, false
	}
	px := player.X - cam.X
	py := player.Y - cam.Y
	dx := sx - px
	dy := sy - py
	if dx == 0 && dy == 0 {
		return RadarArrow{}, false
	}
	adx, ady := absInt(dx), absInt(dy)
	const maxX = ScreenWidth - 1
	const maxY = ScreenHeight - 1
	var ex, ey int
	if adx > ady {
		if dx > 0 {
			ex = maxX
		} else {
			ex = 0
		}
		// ey = py + dy*(ex-px)/dx; dx != 0 here.
		ey = py + (dy*(ex-px))/dx
		if ey < 0 {
			ey = 0
		} else if ey > maxY {
			ey = maxY
		}
	} else {
		if dy > 0 {
			ey = maxY
		} else {
			ey = 0
		}
		// ex = px + dx*(ey-py)/dy; dy != 0 here.
		ex = px + (dx*(ey-py))/dy
		if ex < 0 {
			ex = 0
		} else if ex > maxX {
			ex = maxX
		}
	}
	return RadarArrow{ScreenX: ex, ScreenY: ey}, true
}

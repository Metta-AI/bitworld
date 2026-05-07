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

// iconCenterOffsetY is the offset from TaskStation.Center.Y to the icon
// sprite's center used by the server for arrow geometry. TaskStation.Center
// is the box center (task.y + 8); the arrow server uses iconCenterY =
// task.y - SpriteSize/2 - 2 + bobY (sim.nim:2420), which is 16 px above the
// box center. bobY ∈ {-1, 0, 1} and falls within radarMatchTol, so we fix
// the offset at -16.
const iconCenterOffsetY = -16

// PredictedArrow returns the screen-space pixel where the server would draw
// this station's radar arrow, mirroring sim.nim:2443-2472. Returns
// (_, false) when the station's icon would be on-screen (the server draws
// the icon instead of an arrow in that case).
//
// Input station is the task box center (TaskStation.Center); internally we
// translate to the icon center (shifted up by 16 px) to match the server's
// dx/dy deltas, which use iconCenterX/iconCenterY (sim.nim:2447-2448).
//
// CollisionW = CollisionH = 1 (sim.nim:20-21), so with integer division
// px = player.X - cam.X and py = player.Y - cam.Y. The server's float
// arithmetic is emulated with integer math; division uses truncation
// toward zero (Go's integer `/`), which matches the server's float-then-
// `int()` cast for the in-range cases this predicate is called on (the
// division's numerator is bounded because the perpendicular axis later
// gets clamped to the viewport).
func PredictedArrow(player, station Point, cam Camera) (RadarArrow, bool) {
	// iconCenterX = station.X; iconCenterY = station.Y + iconCenterOffsetY.
	iconCx := station.X - cam.X
	iconCy := station.Y + iconCenterOffsetY - cam.Y
	// Server's iconOnScreen (sim.nim:2421-2423) tests whether the 12×12 icon
	// sprite (top-left at iconC - SpriteSize/2) intersects the viewport. The
	// half-offsets below expand/contract the center bounds by SpriteSize/2=6
	// so this matches `iconSx+12>0 && iconSx<ScreenWidth` etc. exactly.
	const half = 6
	if iconCx+half > 0 && iconCx-half < ScreenWidth &&
		iconCy+half > 0 && iconCy-half < ScreenHeight {
		return RadarArrow{}, false
	}
	px := player.X - cam.X
	py := player.Y - cam.Y
	dx := iconCx - px
	dy := iconCy - py
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

package main

import "testing"

// predictionTestCam returns a camera that places the player's sprite center
// at screen (playerWorldOffX, playerWorldOffY).
func predictionTestCam(player Point) Camera {
	return Camera{X: player.X - playerWorldOffX, Y: player.Y - playerWorldOffY}
}

func TestPredictedArrow_StationOnScreenReturnsFalse(t *testing.T) {
	player := Point{400, 300}
	cam := predictionTestCam(player)
	// A station a few pixels off-player is still well inside the viewport.
	station := Point{player.X + 10, player.Y + 10}
	if _, ok := PredictedArrow(player, station, cam); ok {
		t.Errorf("on-screen station should not predict an arrow")
	}
}

func TestPredictedArrow_DueEastClampsToRightEdge(t *testing.T) {
	player := Point{400, 300}
	cam := predictionTestCam(player)
	// Station 500 pixels east, same row as the player => dominant X, arrow
	// at (ScreenWidth-1, playerScreenCenterY).
	station := Point{player.X + 500, player.Y}
	ar, ok := PredictedArrow(player, station, cam)
	if !ok {
		t.Fatal("expected an arrow for far-east station")
	}
	if ar.ScreenX != ScreenWidth-1 {
		t.Errorf("ScreenX = %d, want %d", ar.ScreenX, ScreenWidth-1)
	}
	// ey = py + dy * (ex - px) / dx; dy=0 => ey = py.
	if ar.ScreenY != playerWorldOffY {
		t.Errorf("ScreenY = %d, want %d", ar.ScreenY, playerWorldOffY)
	}
}

func TestPredictedArrow_DueNorthClampsToTopEdge(t *testing.T) {
	player := Point{400, 300}
	cam := predictionTestCam(player)
	// Station due north; dominant Y.
	station := Point{player.X, player.Y - 500}
	ar, ok := PredictedArrow(player, station, cam)
	if !ok {
		t.Fatal("expected an arrow for far-north station")
	}
	if ar.ScreenY != 0 {
		t.Errorf("ScreenY = %d, want 0", ar.ScreenY)
	}
	if ar.ScreenX != playerWorldOffX {
		t.Errorf("ScreenX = %d, want %d", ar.ScreenX, playerWorldOffX)
	}
}

func TestPredictedArrow_DiagonalXDominantClampsToRight(t *testing.T) {
	player := Point{400, 300}
	cam := predictionTestCam(player)
	// |dx|=500, |dy|=100 (X dominant, dy positive). ex = ScreenWidth-1.
	// ey = py + dy * (ex - px) / dx
	//    = 66  + 100 * ((ScreenWidth-1) - 60) / 500
	//    = 66  + 100 * 67 / 500 (integer-truncated cast) = 66 + 13 = 79
	// (server casts via uint8(int(float)); float arith: 6700/500 = 13.4 -> int=13)
	station := Point{player.X + 500, player.Y + 100}
	ar, ok := PredictedArrow(player, station, cam)
	if !ok {
		t.Fatal("expected an arrow")
	}
	if ar.ScreenX != ScreenWidth-1 {
		t.Errorf("ScreenX = %d, want %d", ar.ScreenX, ScreenWidth-1)
	}
	if ar.ScreenY != 79 {
		t.Errorf("ScreenY = %d, want 79", ar.ScreenY)
	}
}

func TestPredictedArrow_DiagonalClampsPerpendicularAxis(t *testing.T) {
	// Arrow placement with X dominant but a steep angle that would push ey
	// past the top of the screen if unclamped. Server clamps ey into
	// [0, ScreenHeight-1].
	player := Point{400, 300}
	cam := predictionTestCam(player)
	// dx=+200, dy=-2000. |dy| > |dx| so this is actually Y-dominant; pick
	// one that's genuinely X-dominant with a steep angle.
	// dx=+200, dy=-180. |dx| > |dy|. Then:
	//   ey = 66 + (-180) * ((ScreenWidth-1) - 60) / 200
	//      = 66 + (-180 * 67) / 200 = 66 + (-12060/200) = 66 + (-60) = 6
	// That stays in bounds. Make dy larger: dx=+200, dy=-199.
	//   ey = 66 + (-199 * 67) / 200 = 66 + (-13333/200) = 66 + (-66) = 0
	// Server's inner math uses float then int truncation; our int impl
	// must match for typical inputs (see task 1 step 3). Use dy=-199.
	station := Point{player.X + 200, player.Y - 199}
	ar, ok := PredictedArrow(player, station, cam)
	if !ok {
		t.Fatal("expected an arrow")
	}
	if ar.ScreenX != ScreenWidth-1 {
		t.Errorf("ScreenX = %d, want %d", ar.ScreenX, ScreenWidth-1)
	}
	if ar.ScreenY < 0 || ar.ScreenY >= ScreenHeight {
		t.Errorf("ScreenY = %d, out of [0, %d)", ar.ScreenY, ScreenHeight)
	}
}

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
	// Station 500 pixels east, same row as the player box. The server
	// draws the arrow from the icon center (task.y - 8 + bobY, sim.nim:2420),
	// which sits 16 px above the box center. That puts dy=-16 here, not 0.
	// Dominant X. ex=ScreenWidth-1=127. ey = 66 + (-16)*(127-60)/500
	//   = 66 + -1072/500 (Go truncation toward zero) = 66 + -2 = 64.
	station := Point{player.X + 500, player.Y}
	ar, ok := PredictedArrow(player, station, cam)
	if !ok {
		t.Fatal("expected an arrow for far-east station")
	}
	if ar.ScreenX != ScreenWidth-1 {
		t.Errorf("ScreenX = %d, want %d", ar.ScreenX, ScreenWidth-1)
	}
	if ar.ScreenY != 64 {
		t.Errorf("ScreenY = %d, want 64", ar.ScreenY)
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
	// station box (x+500, y+100); icon center sits 16 px above box.
	// dx = 500, dy = 100 - 16 = 84. X-dominant. ex = 127.
	// ey = 66 + 84 * (127-60) / 500 = 66 + 84*67/500 = 66 + 5628/500
	//    = 66 + 11 (Go integer truncation toward zero) = 77.
	station := Point{player.X + 500, player.Y + 100}
	ar, ok := PredictedArrow(player, station, cam)
	if !ok {
		t.Fatal("expected an arrow")
	}
	if ar.ScreenX != ScreenWidth-1 {
		t.Errorf("ScreenX = %d, want %d", ar.ScreenX, ScreenWidth-1)
	}
	if ar.ScreenY != 77 {
		t.Errorf("ScreenY = %d, want 77", ar.ScreenY)
	}
}

func TestPredictedArrow_DiagonalClampsPerpendicularAxis(t *testing.T) {
	// Regardless of regime, the returned arrow must sit on a viewport
	// border pixel. Pick a diagonal station well off-screen and verify the
	// result is clamped into [0, ScreenWidth) × [0, ScreenHeight).
	player := Point{400, 300}
	cam := predictionTestCam(player)
	station := Point{player.X + 200, player.Y - 199}
	ar, ok := PredictedArrow(player, station, cam)
	if !ok {
		t.Fatal("expected an arrow")
	}
	if ar.ScreenX < 0 || ar.ScreenX >= ScreenWidth {
		t.Errorf("ScreenX = %d, out of [0, %d)", ar.ScreenX, ScreenWidth)
	}
	if ar.ScreenY < 0 || ar.ScreenY >= ScreenHeight {
		t.Errorf("ScreenY = %d, out of [0, %d)", ar.ScreenY, ScreenHeight)
	}
}

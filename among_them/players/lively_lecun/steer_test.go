package main

import "testing"

func paintBlob(p []uint8, x0, y0, w, h int, color uint8) {
	for y := y0; y < y0+h; y++ {
		for x := x0; x < x0+w; x++ {
			if x >= 0 && x < ScreenWidth && y >= 0 && y < ScreenHeight {
				p[y*ScreenWidth+x] = color
			}
		}
	}
}

func TestSteerYellowAbove(t *testing.T) {
	p := make([]uint8, ScreenWidth*ScreenHeight)
	// Yellow blob centered at (64, 16) — far above the player center (64, 64).
	paintBlob(p, 60, 12, 8, 8, taskRadarColor)
	if got := Steer(p); got != ButtonUp {
		t.Errorf("got %#x, want ButtonUp (%#x)", got, ButtonUp)
	}
}

func TestSteerYellowBelow(t *testing.T) {
	p := make([]uint8, ScreenWidth*ScreenHeight)
	paintBlob(p, 60, 108, 8, 8, taskRadarColor)
	if got := Steer(p); got != ButtonDown {
		t.Errorf("got %#x, want ButtonDown (%#x)", got, ButtonDown)
	}
}

func TestSteerYellowLeft(t *testing.T) {
	p := make([]uint8, ScreenWidth*ScreenHeight)
	paintBlob(p, 12, 60, 8, 8, taskRadarColor)
	if got := Steer(p); got != ButtonLeft {
		t.Errorf("got %#x, want ButtonLeft (%#x)", got, ButtonLeft)
	}
}

func TestSteerYellowRight(t *testing.T) {
	p := make([]uint8, ScreenWidth*ScreenHeight)
	paintBlob(p, 108, 60, 8, 8, taskRadarColor)
	if got := Steer(p); got != ButtonRight {
		t.Errorf("got %#x, want ButtonRight (%#x)", got, ButtonRight)
	}
}

func TestSteerDiagonal(t *testing.T) {
	p := make([]uint8, ScreenWidth*ScreenHeight)
	// Upper-right corner — should set both Up and Right.
	paintBlob(p, 108, 12, 8, 8, taskRadarColor)
	got := Steer(p)
	if got&ButtonUp == 0 || got&ButtonRight == 0 {
		t.Errorf("got %#x, want Up|Right (%#x)", got, ButtonUp|ButtonRight)
	}
	if got&(ButtonDown|ButtonLeft) != 0 {
		t.Errorf("got %#x; should not include Down or Left", got)
	}
}

func TestSteerNoYellow(t *testing.T) {
	p := make([]uint8, ScreenWidth*ScreenHeight)
	if got := Steer(p); got != 0 {
		t.Errorf("empty frame should yield 0, got %#x", got)
	}
}

func TestSteerExclusionZone(t *testing.T) {
	p := make([]uint8, ScreenWidth*ScreenHeight)
	// Yellow only inside the player exclusion box (16x16 centered at 64,64).
	paintBlob(p, 60, 60, 6, 6, taskRadarColor)
	if got := Steer(p); got != 0 {
		t.Errorf("yellow inside exclusion zone should be ignored, got %#x", got)
	}
}

func TestSteerDeadband(t *testing.T) {
	p := make([]uint8, ScreenWidth*ScreenHeight)
	// Yellow just outside the exclusion zone but inside the deadband:
	// place it near (64, 56) which is dy=-8, |dy|<deadband(4)? no, 8>4.
	// Use (64, 60) which is in exclusion. Try (78, 64) — dx=14, outside exclusion (8),
	// well outside deadband (4) -> would set Right.
	// To exercise deadband: paint a balanced pair so centroid lands near 0.
	paintBlob(p, 50, 30, 4, 4, taskRadarColor) // dx ≈ -12, dy ≈ -32
	paintBlob(p, 74, 96, 4, 4, taskRadarColor) // dx ≈ +12, dy ≈ +32
	got := Steer(p)
	// Centroids cancel on x (≈ 0), so no Left/Right; y still pulls down (positive avg).
	if got&(ButtonLeft|ButtonRight) != 0 {
		t.Errorf("balanced x should not set Left/Right, got %#x", got)
	}
}

func TestSteerWrongSize(t *testing.T) {
	if got := Steer(make([]uint8, 100)); got != 0 {
		t.Errorf("wrong-size input should yield 0, got %#x", got)
	}
	if got := Steer(nil); got != 0 {
		t.Errorf("nil should yield 0, got %#x", got)
	}
}

// Smoke test against the real playing fixture: 41 palette-8 radar arrows in
// the upper-left half of the screen yield a centroid offset of roughly
// (-41, -23) from the player center, so Steer should set at least Up|Left.
func TestSteerRealPlayingFixture(t *testing.T) {
	pixels := loadPhaseFixture(t, "playing")
	got := Steer(pixels)
	if got&ButtonUp == 0 || got&ButtonLeft == 0 {
		t.Errorf("Steer(playing) = %#x, want at least Up|Left set", got)
	}
	t.Logf("Steer(playing fixture) = %#x", got)
}

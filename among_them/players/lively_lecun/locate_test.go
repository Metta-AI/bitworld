package main

import "testing"

func TestLocalize_PlayingFixture(t *testing.T) {
	m := loadMapForTest(t)
	pixels := loadPhaseFixture(t, "playing")
	meta := loadFixtureMeta(t)
	want := meta["playing"]

	cam, ok := Localize(pixels, m, nil)
	if !ok {
		t.Fatalf("expected confident lock; got %v ok=false", cam)
	}
	if cam.X != want.CameraX || cam.Y != want.CameraY {
		t.Errorf("Localize(playing) = (%d, %d), want (%d, %d) — miss=%d",
			cam.X, cam.Y, want.CameraX, want.CameraY, cam.Mismatches)
	}
	t.Logf("playing: locked at (%d, %d) miss=%d/%d", cam.X, cam.Y, cam.Mismatches, len(localizeSamples))
}

func TestLocalize_OnTaskFixture(t *testing.T) {
	m := loadMapForTest(t)
	pixels := loadPhaseFixture(t, "playing_on_task")
	meta := loadFixtureMeta(t)
	want := meta["playing_on_task"]

	cam, ok := Localize(pixels, m, nil)
	if !ok {
		t.Fatalf("expected confident lock; got %v ok=false", cam)
	}
	if cam.X != want.CameraX || cam.Y != want.CameraY {
		t.Errorf("Localize(playing_on_task) = (%d, %d), want (%d, %d) — miss=%d",
			cam.X, cam.Y, want.CameraX, want.CameraY, cam.Mismatches)
	}
	t.Logf("playing_on_task: locked at (%d, %d) miss=%d/%d", cam.X, cam.Y, cam.Mismatches, len(localizeSamples))
}

func TestLocalize_HintNarrowsSearch(t *testing.T) {
	m := loadMapForTest(t)
	pixels := loadPhaseFixture(t, "playing")
	want := loadFixtureMeta(t)["playing"]
	hint := &Camera{X: want.CameraX, Y: want.CameraY}
	cam, ok := Localize(pixels, m, hint)
	if !ok {
		t.Fatalf("hinted localize failed: %v", cam)
	}
	if cam.X != want.CameraX || cam.Y != want.CameraY {
		t.Errorf("hinted Localize = (%d, %d), want (%d, %d)", cam.X, cam.Y, want.CameraX, want.CameraY)
	}
}

func TestLocalize_NonPlayingFrameIsRejected(t *testing.T) {
	m := loadMapForTest(t)
	pixels := loadPhaseFixture(t, "lobby_ready")
	cam, ok := Localize(pixels, m, nil)
	if ok {
		t.Errorf("lobby frame should not yield a confident lock; got %v", cam)
	}
}

func TestLocalize_WrongSize(t *testing.T) {
	m := loadMapForTest(t)
	if _, ok := Localize(make([]uint8, 100), m, nil); ok {
		t.Error("wrong-size frame should yield ok=false")
	}
	if _, ok := Localize(nil, m, nil); ok {
		t.Error("nil frame should yield ok=false")
	}
	if _, ok := Localize(make([]uint8, ScreenWidth*ScreenHeight), nil, nil); ok {
		t.Error("nil map should yield ok=false")
	}
}

// TestLocalize_EastEdgeWithVoid: at the map's east edge, the server paints
// off-map pixels with MapVoidColor (sim.nim:2509). The tracker's off-map
// samples must check against that color rather than count as unconditional
// misses; otherwise lock silently fails when the camera reaches MapWidth -
// ScreenWidth, which is exactly where several right-side task stations
// live. Synthetic test: craft a frame where the leftmost ScreenWidth-K
// columns mirror the map at (MapWidth-ScreenWidth, 0) and the rightmost
// K columns are MapVoidColor.
func TestLocalize_EastEdgeWithVoid(t *testing.T) {
	m := loadMapForTest(t)
	camX := MapWidth - ScreenWidth
	// Pick a y-band that cuts through ship interior (Vents[3-7] live
	// between y=70 and y=262, so the ship extends east to ~x=886 here),
	// so east-edge void covers only the last ~66 columns. That leaves
	// structured map content in the left two-thirds of the viewport to
	// disambiguate the x offset. y=0 would be uniform space with many
	// matching offsets.
	camY := 150
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	for y := 0; y < ScreenHeight; y++ {
		for x := 0; x < ScreenWidth; x++ {
			mx := camX + x
			my := camY + y
			if mx >= 0 && mx < MapWidth && my >= 0 && my < MapHeight {
				pixels[y*ScreenWidth+x] = m.Pixels[my*MapWidth+mx]
			} else {
				pixels[y*ScreenWidth+x] = mapVoidColor
			}
		}
	}
	// Blot out the player-center 16x16 box so we don't accidentally
	// match a map pixel there (the real game shows the player sprite
	// overlay; localizeSamples already excludes this region, but be
	// explicit in case the exclusion changes).
	for dy := -8; dy < 8; dy++ {
		for dx := -8; dx < 8; dx++ {
			px := playerScreenCenterX + dx
			py := playerScreenCenterY + dy
			if px >= 0 && px < ScreenWidth && py >= 0 && py < ScreenHeight {
				pixels[py*ScreenWidth+px] = 0
			}
		}
	}
	cam, ok := Localize(pixels, m, nil)
	if !ok {
		t.Fatalf("east-edge lock failed: cam=%v miss=%d", cam, cam.Mismatches)
	}
	if cam.X != camX || cam.Y != camY {
		t.Errorf("east-edge: got (%d, %d), want (%d, %d)", cam.X, cam.Y, camX, camY)
	}
}

func TestClamp(t *testing.T) {
	cases := []struct{ v, lo, hi, want int }{
		{5, 0, 10, 5},
		{-5, 0, 10, 0},
		{15, 0, 10, 10},
		{0, 0, 10, 0},
		{10, 0, 10, 10},
	}
	for _, c := range cases {
		if got := clamp(c.v, c.lo, c.hi); got != c.want {
			t.Errorf("clamp(%d, %d, %d) = %d, want %d", c.v, c.lo, c.hi, got, c.want)
		}
	}
}

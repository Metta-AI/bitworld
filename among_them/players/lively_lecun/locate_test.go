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

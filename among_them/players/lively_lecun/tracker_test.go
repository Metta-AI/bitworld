package main

import "testing"

func TestTracker_FirstCallBruteForces(t *testing.T) {
	tr := NewTracker(loadMapForTest(t))
	pixels := loadPhaseFixture(t, "playing")
	cam, ok := tr.Update(pixels)
	if !ok {
		t.Fatalf("first Update should lock; got %v", cam)
	}
	want := loadFixtureMeta(t)["playing"]
	if cam.X != want.CameraX || cam.Y != want.CameraY {
		t.Errorf("locked at (%d, %d), want (%d, %d)", cam.X, cam.Y, want.CameraX, want.CameraY)
	}
	if tr.Brutes != 1 {
		t.Errorf("Brutes = %d, want 1 after first call", tr.Brutes)
	}
}

func TestTracker_RetainsLockWithoutBruting(t *testing.T) {
	tr := NewTracker(loadMapForTest(t))
	pixels := loadPhaseFixture(t, "playing")
	tr.Update(pixels) // first lock (brute)
	for i := 0; i < 5; i++ {
		_, ok := tr.Update(pixels)
		if !ok {
			t.Fatalf("step %d: expected continued lock", i)
		}
	}
	if tr.Brutes != 1 {
		t.Errorf("Brutes = %d after repeated identical frames, want 1", tr.Brutes)
	}
}

func TestTracker_FallsBackToBruteOnTeleport(t *testing.T) {
	tr := NewTracker(loadMapForTest(t))
	tr.Update(loadPhaseFixture(t, "playing")) // lock at (504, 54)
	if tr.Brutes != 1 {
		t.Fatalf("setup: Brutes=%d, want 1", tr.Brutes)
	}
	// Now feed a frame from a far-away position; (816, 138) is well
	// outside the 33x33 hint window, so the incremental fit should fail
	// and Update should brute-force again.
	cam, ok := tr.Update(loadPhaseFixture(t, "playing_on_task"))
	if !ok {
		t.Fatalf("expected brute-force lock on teleport; got %v", cam)
	}
	want := loadFixtureMeta(t)["playing_on_task"]
	if cam.X != want.CameraX || cam.Y != want.CameraY {
		t.Errorf("re-locked at (%d, %d), want (%d, %d)", cam.X, cam.Y, want.CameraX, want.CameraY)
	}
	if tr.Brutes != 2 {
		t.Errorf("Brutes = %d, want 2 (one per frame after teleport)", tr.Brutes)
	}
}

func TestTracker_NoLockOnNonPlayingFrame(t *testing.T) {
	tr := NewTracker(loadMapForTest(t))
	for _, name := range []string{"lobby_ready", "voting", "vote_result", "game_over"} {
		_, ok := tr.Update(loadPhaseFixture(t, name))
		if ok {
			t.Errorf("Update on %s should not lock", name)
		}
	}
	if tr.Locked {
		t.Error("Tracker should not be Locked after non-playing frames")
	}
}

func TestTracker_PlayerPosition(t *testing.T) {
	tr := NewTracker(loadMapForTest(t))
	if _, _, ok := tr.PlayerPosition(); ok {
		t.Error("PlayerPosition should be invalid before any lock")
	}
	tr.Update(loadPhaseFixture(t, "playing"))
	x, y, ok := tr.PlayerPosition()
	if !ok {
		t.Fatal("PlayerPosition should be valid after lock")
	}
	want := loadFixtureMeta(t)["playing"]
	// With the sprite-offset inversion, PlayerPosition should match the
	// server's recorded player position exactly (modulo any lock error).
	if x != want.PlayerX || y != want.PlayerY {
		t.Errorf("PlayerPosition() = (%d, %d), want (%d, %d)", x, y, want.PlayerX, want.PlayerY)
	}
}

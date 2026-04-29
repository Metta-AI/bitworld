package main

import "testing"

func TestSuspectTracker_EmptyPick(t *testing.T) {
	var s SuspectTracker
	if c, ok := s.Pick(); ok {
		t.Fatalf("empty Pick returned (%d, true); want (_, false)", c)
	}
}

func TestSuspectTracker_RecordAndPick(t *testing.T) {
	var s SuspectTracker
	s.Record(3, 10)
	s.Record(7, 20)
	s.Record(11, 15)
	c, ok := s.Pick()
	if !ok {
		t.Fatalf("Pick returned ok=false with recorded entries")
	}
	if c != 7 {
		t.Fatalf("Pick: got color %d, want 7 (most recent)", c)
	}
}

func TestSuspectTracker_RecordMonotonic(t *testing.T) {
	// Earlier frames must not overwrite later frames.
	var s SuspectTracker
	s.Record(3, 100)
	s.Record(3, 50)
	// Now record 7 at frame 80 — still older than 3's 100.
	s.Record(7, 80)
	c, ok := s.Pick()
	if !ok || c != 3 {
		t.Fatalf("Pick: got (%d, %v), want (3, true)", c, ok)
	}
}

func TestSuspectTracker_ExcludesSelf(t *testing.T) {
	var s SuspectTracker
	s.SetSelf(7)
	s.Record(3, 10)
	s.Record(7, 20) // self; should be ignored in Pick
	c, ok := s.Pick()
	if !ok || c != 3 {
		t.Fatalf("Pick: got (%d, %v), want (3, true) — self=7 excluded", c, ok)
	}
}

func TestSuspectTracker_OnlySelfSeen(t *testing.T) {
	var s SuspectTracker
	s.SetSelf(7)
	s.Record(7, 20)
	if c, ok := s.Pick(); ok {
		t.Fatalf("Pick returned (%d, true) when only self was seen; want (_, false)", c)
	}
}

func TestSuspectTracker_BadColorIgnored(t *testing.T) {
	var s SuspectTracker
	s.Record(255, 10) // clipped sprite; must be a no-op
	s.Record(16, 20)  // out of palette range
	if c, ok := s.Pick(); ok {
		t.Fatalf("Pick returned (%d, true) after only bad colors; want (_, false)", c)
	}
}

func TestSelfColorFromScreen_DetectsPaintedSelf(t *testing.T) {
	// Paint the player sprite at the known self position with color=7.
	pixels := paintCrewmate(playerScreenX, playerScreenY, 7, false)
	if c := selfColorFromScreen(pixels); c != 7 {
		t.Fatalf("selfColorFromScreen: got %d, want 7", c)
	}
}

func TestSelfColorFromScreen_EmptyFrameReturns255(t *testing.T) {
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	if c := selfColorFromScreen(pixels); c != 255 {
		t.Fatalf("selfColorFromScreen on empty frame: got %d, want 255", c)
	}
}

func TestSelfColorFromScreen_WrongSize(t *testing.T) {
	if c := selfColorFromScreen(make([]uint8, 100)); c != 255 {
		t.Fatalf("wrong-size frame: got %d, want 255", c)
	}
	if c := selfColorFromScreen(nil); c != 255 {
		t.Fatalf("nil frame: got %d, want 255", c)
	}
}

func TestSelfColorFromScreen_RealFixture(t *testing.T) {
	// The captured `playing` fixture has the local player rendered at
	// (58, 58). The replayed color is 3 (red) — an incidental but stable
	// fact of the fixture. Guards against regressions in the sprite
	// anchor or the majority-vote logic.
	pixels := loadPhaseFixture(t, "playing")
	if c := selfColorFromScreen(pixels); c != 3 {
		t.Fatalf("self color from playing fixture: got %d, want 3", c)
	}
}

func TestSuspectTracker_SetSelfClear(t *testing.T) {
	var s SuspectTracker
	s.SetSelf(3)
	if s.Self() != 3 {
		t.Fatalf("Self: got %d, want 3", s.Self())
	}
	s.SetSelf(255)
	if s.Self() != 255 {
		t.Fatalf("Self after clear: got %d, want 255", s.Self())
	}
}

package main

import "testing"

// paintRow paints a horizontal run of `color` at row y from x0 (inclusive)
// for w pixels.
func paintRow(p []uint8, x0, y, w int, color uint8) {
	for x := x0; x < x0+w; x++ {
		p[y*ScreenWidth+x] = color
	}
}

func TestCursorOnSkip_VotingFixture(t *testing.T) {
	// Real voting fixture: cursor is on player cell 0, not SKIP.
	pixels := loadPhaseFixture(t, "voting")
	if cursorOnSkip(pixels) {
		t.Error("cursorOnSkip returned true for fixture where cursor is on cell 0")
	}
}

func TestCursorOnSkip_SynthesizedHighlight(t *testing.T) {
	// Paint just the top edge of the SKIP highlight rectangle (1-row layout).
	p := make([]uint8, ScreenWidth*ScreenHeight)
	paintRow(p, 50, 19, 28, 2)
	if !cursorOnSkip(p) {
		t.Error("cursorOnSkip should detect highlight at y=19, x=50..77")
	}
}

func TestCursorOnSkip_SynthesizedHighlight2Row(t *testing.T) {
	// 2-row layout: highlight top at y=36.
	p := make([]uint8, ScreenWidth*ScreenHeight)
	paintRow(p, 50, 36, 28, 2)
	if !cursorOnSkip(p) {
		t.Error("cursorOnSkip should detect highlight at y=36 for 2-row layout")
	}
}

func TestCursorOnSkip_TextOnly(t *testing.T) {
	// Paint palette-2 only at the SKIP text glyph rows (y=20..26): no highlight.
	p := make([]uint8, ScreenWidth*ScreenHeight)
	for y := 20; y <= 26; y++ {
		paintRow(p, 50, y, 28, 2)
	}
	if cursorOnSkip(p) {
		t.Error("cursorOnSkip should not trigger on text-glyph rows alone")
	}
}

func TestCursorOnSkip_WrongSize(t *testing.T) {
	if cursorOnSkip(make([]uint8, 100)) {
		t.Error("wrong-size input should yield false")
	}
	if cursorOnSkip(nil) {
		t.Error("nil should yield false")
	}
}

func TestSkipController_FirstCallReleases(t *testing.T) {
	var sc SkipController
	pixels := loadPhaseFixture(t, "voting")
	if got := sc.Next(pixels); got != 0 {
		t.Errorf("first call should release (return 0), got %#x", got)
	}
}

func TestSkipController_AdvancesWhenNotOnSkip(t *testing.T) {
	var sc SkipController
	pixels := loadPhaseFixture(t, "voting") // cursor on cell 0
	sc.Next(pixels)                          // release
	if got := sc.Next(pixels); got != ButtonRight {
		t.Errorf("call 2 should advance with ButtonRight, got %#x", got)
	}
	if got := sc.Next(pixels); got != 0 {
		t.Errorf("call 3 should release, got %#x", got)
	}
	if got := sc.Next(pixels); got != ButtonRight {
		t.Errorf("call 4 should advance again, got %#x", got)
	}
}

func TestSkipController_CastsAtSkip(t *testing.T) {
	p := make([]uint8, ScreenWidth*ScreenHeight)
	paintRow(p, 50, 19, 28, 2) // synthesize "cursor on SKIP" highlight
	var sc SkipController
	sc.Next(p) // release
	if got := sc.Next(p); got != ButtonA {
		t.Errorf("on SKIP highlight, expected ButtonA, got %#x", got)
	}
	if got := sc.Next(p); got != 0 {
		t.Errorf("after A, expected release (0), got %#x", got)
	}
}

func TestSkipController_PressReleaseCadence(t *testing.T) {
	// Cadence sanity: every other call should be 0, regardless of frame content.
	var sc SkipController
	p := make([]uint8, ScreenWidth*ScreenHeight)
	masks := make([]uint8, 8)
	for i := range masks {
		masks[i] = sc.Next(p)
	}
	// Expected: 0 (release), then strict alternation pressed/0/pressed/0/...
	if masks[0] != 0 {
		t.Errorf("call 0 = %#x, want 0", masks[0])
	}
	for i := 1; i < len(masks); i++ {
		want0 := i%2 == 0
		got0 := masks[i] == 0
		if got0 != want0 {
			t.Errorf("call %d = %#x, want %s", i, masks[i], map[bool]string{true: "0", false: "non-zero"}[want0])
		}
	}
}

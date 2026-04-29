package main

import "testing"

// paintStatusIcon draws a 12×12 palette-indexed template at the status-icon
// slot, optionally through shadowMap. Returns a fresh black screen with the
// icon blitted in place. Used to synthesize fixtures without having to
// capture real frames.
func paintStatusIcon(tpl []byte, shadow bool) []uint8 {
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	for dy := 0; dy < statusIconSize; dy++ {
		for dx := 0; dx < statusIconSize; dx++ {
			t := tpl[dy*statusIconSize+dx]
			if t == 255 {
				continue
			}
			v := t
			if shadow {
				v = shadowMap[t&0x0f]
			}
			pixels[(statusIconY+dy)*ScreenWidth+(statusIconX+dx)] = v
		}
	}
	return pixels
}

func TestStatusDetector_NoIcon(t *testing.T) {
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	var det StatusDetector
	got := det.Next(pixels)
	if got != StatusCrewmate {
		t.Fatalf("empty frame: got %v, want StatusCrewmate", got)
	}
	if det.IsGhost() || det.IsImposter() || det.KillReady() {
		t.Fatalf("empty frame: no latches expected, got ghost=%v imp=%v ready=%v",
			det.IsGhost(), det.IsImposter(), det.KillReady())
	}
}

func TestStatusDetector_GhostLatches(t *testing.T) {
	pixels := paintStatusIcon(ghostIconTemplate, false)
	var det StatusDetector

	// First ghost frame: detector sees the match but shouldn't latch yet.
	if got := det.Next(pixels); got != StatusUnknown {
		t.Fatalf("ghost frame 1: got %v, want StatusUnknown (pre-latch)", got)
	}
	if det.IsGhost() {
		t.Fatalf("ghost frame 1: latched too early")
	}

	// Second ghost frame: latch.
	if got := det.Next(pixels); got != StatusGhost {
		t.Fatalf("ghost frame 2: got %v, want StatusGhost", got)
	}
	if !det.IsGhost() {
		t.Fatalf("ghost frame 2: expected IsGhost=true")
	}

	// Once latched, stays latched even on a blank frame.
	blank := make([]uint8, ScreenWidth*ScreenHeight)
	if got := det.Next(blank); got != StatusGhost {
		t.Fatalf("blank frame post-latch: got %v, want sticky StatusGhost", got)
	}
}

func TestStatusDetector_ImposterReady(t *testing.T) {
	pixels := paintStatusIcon(killIconTemplate, false)
	var det StatusDetector
	got := det.Next(pixels)
	if got != StatusImposterReady {
		t.Fatalf("kill-raw frame: got %v, want StatusImposterReady", got)
	}
	if !det.IsImposter() || !det.KillReady() {
		t.Fatalf("kill-raw: want imp=ready=true, got imp=%v ready=%v",
			det.IsImposter(), det.KillReady())
	}
}

func TestStatusDetector_ImposterCooldown(t *testing.T) {
	pixels := paintStatusIcon(killIconTemplate, true) // shadowed
	var det StatusDetector
	got := det.Next(pixels)
	if got != StatusImposterCooldown {
		t.Fatalf("kill-shadow frame: got %v, want StatusImposterCooldown", got)
	}
	if !det.IsImposter() {
		t.Fatalf("kill-shadow: want IsImposter=true")
	}
	if det.KillReady() {
		t.Fatalf("kill-shadow: KillReady should be false during cooldown")
	}
}

// Once imposter role is latched, a momentarily empty slot (e.g. if
// classifier misfires) should not downgrade us to crewmate. Mid-round role
// changes are impossible in sim.nim.
func TestStatusDetector_ImposterSticks(t *testing.T) {
	pixels := paintStatusIcon(killIconTemplate, true) // cooldown
	var det StatusDetector
	_ = det.Next(pixels)
	blank := make([]uint8, ScreenWidth*ScreenHeight)
	got := det.Next(blank)
	if got != StatusImposterCooldown {
		t.Fatalf("blank frame post-imposter-latch: got %v, want sticky cooldown", got)
	}
	if det.KillReady() {
		t.Fatalf("blank frame: KillReady should be false (no raw icon seen)")
	}
}

// The kill-raw frame transitions to cooldown after the imposter attacks.
// Latching should hold IsImposter across both variants.
func TestStatusDetector_ReadyThenCooldown(t *testing.T) {
	raw := paintStatusIcon(killIconTemplate, false)
	cd := paintStatusIcon(killIconTemplate, true)
	var det StatusDetector
	if got := det.Next(raw); got != StatusImposterReady {
		t.Fatalf("ready frame: got %v", got)
	}
	if !det.KillReady() {
		t.Fatalf("ready frame: want KillReady true")
	}
	if got := det.Next(cd); got != StatusImposterCooldown {
		t.Fatalf("cooldown frame: got %v", got)
	}
	if det.KillReady() {
		t.Fatalf("cooldown frame: KillReady should be false")
	}
}

// Defensive: slightly corrupted icons (1-2 wrong pixels) still match.
// Miss budget is 5 for kill, 3 for ghost, so flipping 2 pixels keeps both
// in range.
func TestStatusDetector_ToleratesNoise(t *testing.T) {
	pixels := paintStatusIcon(killIconTemplate, false)
	// Corrupt 2 opaque pixels at known positions inside the template.
	for y := 0; y < 2; y++ {
		pixels[(statusIconY+y)*ScreenWidth+statusIconX+4] ^= 0x0f
	}
	var det StatusDetector
	got := det.Next(pixels)
	if got != StatusImposterReady {
		t.Fatalf("noisy ready frame: got %v, want StatusImposterReady", got)
	}
}

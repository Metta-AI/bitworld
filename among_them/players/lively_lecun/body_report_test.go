package main

import (
	"os"
	"path/filepath"
	"testing"
)

// loadFrame returns the unpacked pixels from a captured .bin in testdata.
func loadFrame(t *testing.T, name string) []uint8 {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("open %s: %v", name, err)
	}
	if len(raw) != ProtocolBytes {
		t.Fatalf("%s: got %d bytes, want %d", name, len(raw), ProtocolBytes)
	}
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	if err := UnpackFrame(raw, pixels); err != nil {
		t.Fatalf("unpack %s: %v", name, err)
	}
	return pixels
}

// overlayBody paints the body sprite at (tlx, tly) with the given color
// over an existing frame. Matches paintBody but does not zero the frame.
func overlayBody(pixels []uint8, tlx, tly int, color uint8) {
	for dy := 0; dy < bodySpriteH; dy++ {
		for dx := 0; dx < bodySpriteW; dx++ {
			p := bodySpriteTemplate[dy*bodySpriteW+dx]
			if p == 255 {
				continue
			}
			fx, fy := tlx+dx, tly+dy
			if fx < 0 || fy < 0 || fx >= ScreenWidth || fy >= ScreenHeight {
				continue
			}
			v := p
			switch p {
			case bodyTint:
				v = color
			case bodyTintShadow:
				v = shadowMap[color&0x0f]
			}
			pixels[fy*ScreenWidth+fx] = v
		}
	}
}

// TestAgent_BodyReport: when a body is drawn within report range of the
// player, the agent presses ButtonA and queues a pending chat message.
// Uses the real playing-phase fixture so the tracker locks and the
// PhaseActive branch runs.
func TestAgent_BodyReport(t *testing.T) {
	pixels := loadFrame(t, "phase_playing.bin")
	// fixtures.tsv: playing camera=(504,54), player world=(564,120).
	// Place the body sprite near player-screen-center (64,64) so its
	// world coord lands close to the player.
	// sx = playerScreenX - SpriteDrawOffX = 64 - 2 = 62
	// sy = playerScreenY - SpriteDrawOffY = 64 - 8 = 56
	// Shift +5 in X to avoid overwriting the player's own sprite details
	// but keep well inside report range (distSq ≤ 400 world, and 5 world
	// pixels^2 = 25 << 400).
	overlayBody(pixels, 67, 56, 7) // orange body

	a := NewAgent()
	a.currentPhase = PhaseActive
	a.havePhase = true

	mask := a.Step(pixels)
	if mask&ButtonA == 0 {
		t.Fatalf("expected ButtonA in mask, got %#x", mask)
	}
	msg, ok := a.TakePendingChat()
	if !ok {
		t.Fatalf("expected pending chat after body report")
	}
	if msg == "" {
		t.Fatalf("pending chat is empty")
	}
	// A second drain must return false.
	if _, ok := a.TakePendingChat(); ok {
		t.Fatalf("second TakePendingChat should return false")
	}
}

// TestAgent_BodyNavGoal: a body far from the player but in view should
// set the nav goal, not fire ButtonA.
func TestAgent_BodyNavGoal(t *testing.T) {
	pixels := loadFrame(t, "phase_playing.bin")
	// Place the body at the far corner of the frame — world-distance
	// from player (564,120) will be large.
	overlayBody(pixels, 110, 110, 11) // lime body at screen corner
	a := NewAgent()
	a.currentPhase = PhaseActive
	a.havePhase = true

	_ = a.Step(pixels)
	if !a.bodyGoal {
		t.Fatalf("expected bodyGoal=true, got false")
	}
	if !a.nav.HasGoal() {
		t.Fatalf("expected nav goal after spotting distant body")
	}
	if _, ok := a.TakePendingChat(); ok {
		t.Fatalf("pending chat should not be queued for out-of-range body")
	}
}

// TestAgent_GhostNoReport: dead crewmates cannot report (sim.nim:1302
// requires p.alive), so once the ghost icon has latched, subsequent
// frames where a body appears must not fire ButtonA or queue chat.
func TestAgent_GhostNoReport(t *testing.T) {
	a := NewAgent()
	a.currentPhase = PhaseActive
	a.havePhase = true

	// Pre-latch the ghost detector so our "body-visible" frame is already
	// recognized as a ghost. Two frames of the ghost icon alone is enough.
	ghostOnly := paintStatusIcon(ghostIconTemplate, false)
	for i := 0; i < 64*128; i++ {
		ghostOnly[i] = 3 // red fill in upper half so Classify picks PhaseActive
	}
	_ = a.Step(ghostOnly)
	_ = a.Step(ghostOnly)
	if !a.status.IsGhost() {
		t.Fatalf("precondition: expected ghost latch after 2 frames")
	}
	// Drain any chat leftover from pre-latch frames (shouldn't be any,
	// but keep the assertion focused on the body-visible frame below).
	_, _ = a.TakePendingChat()

	// Now present a frame where a body is clearly visible in-range.
	pixels := loadFrame(t, "phase_playing.bin")
	overlayBody(pixels, 67, 56, 7)
	// Keep the ghost icon painted so the latch stays true.
	for dy := 0; dy < statusIconSize; dy++ {
		for dx := 0; dx < statusIconSize; dx++ {
			p := ghostIconTemplate[dy*statusIconSize+dx]
			if p == 255 {
				continue
			}
			pixels[(statusIconY+dy)*ScreenWidth+(statusIconX+dx)] = p
		}
	}

	mask := a.Step(pixels)
	if !a.status.IsGhost() {
		t.Fatalf("ghost latch should persist")
	}
	if mask&ButtonA != 0 {
		t.Fatalf("ghost pressed ButtonA on body frame (mask=%#x)", mask)
	}
	if _, ok := a.TakePendingChat(); ok {
		t.Fatalf("ghost must not queue body-report chat")
	}
}

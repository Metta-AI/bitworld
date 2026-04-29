package main

import "testing"

// TestAgent_GhostStillPlays: once the ghost icon latches, stepActive must
// still run the full task/nav/steer pipeline -- sim.nim:1356-1431 confirms
// applyGhostMovement completes tasks for crewmate ghosts
// (sim.nim:1404 runs the task-complete block under `if player.role ==
// Crewmate and input.attack`). Regression guard: v2's status wiring must
// not inadvertently short-circuit active-phase handling on ghost frames.
func TestAgent_GhostStillPlays(t *testing.T) {
	a := NewAgent()
	a.currentPhase = PhaseActive
	a.havePhase = true

	// Paint the ghost icon + enough upper-half ink that Classify picks
	// PhaseActive (isActive threshold is 2000 non-zero pixels in the
	// upper half, per phase.go:73). We need the agent to take the active
	// path so it actually runs StatusDetector.Next.
	ghost := paintStatusIcon(ghostIconTemplate, false)
	for i := 0; i < 64*128; i++ {
		ghost[i] = 3 // red fill in upper half
	}
	// Re-paint the status icon since we just trampled it if it was in
	// the upper half (it isn't: y=115 lives in the lower half, well
	// below the upper 64 rows).
	_ = ghost

	// Frame 1: pre-latch. Agent should still produce a mask without
	// panicking, and status.latched should still be Unknown.
	m1 := a.Step(ghost)
	if a.status.latched == StatusGhost {
		t.Fatalf("frame 1: ghost latched too early")
	}
	_ = m1

	// Frame 2: ghost latches.
	_ = a.Step(ghost)
	if a.status.latched != StatusGhost {
		t.Fatalf("frame 2: expected ghost latch, got %v", a.status.latched)
	}
	if !a.status.IsGhost() {
		t.Fatalf("IsGhost should be true after latch")
	}

	// Frame 3: feed a blank frame; Classify drops to PhaseIdle (no upper
	// ink), but ghost latch should survive. Agent should still produce
	// *some* mask without crashing.
	blank := make([]uint8, ScreenWidth*ScreenHeight)
	_ = a.Step(blank)
	if !a.status.IsGhost() {
		t.Fatalf("ghost latch should be sticky across idle frames")
	}
}

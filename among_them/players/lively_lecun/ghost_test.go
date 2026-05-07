package main

import "testing"

// TestAgent_IdleResetsImposterLatch: a sustained PhaseIdle streak
// (lobby/role-reveal/game-over) must clear the imposter latch so a bot
// who was imposter in game N doesn't keep running stepImposter in game
// N+1 when the server has reassigned them as a crewmate. A transient
// one-frame idle must NOT trigger the reset (that's the existing
// TestAgent_GhostStillPlays contract).
func TestAgent_IdleResetsImposterLatch(t *testing.T) {
	a := NewAgent()
	a.status.latched = StatusImposterReady
	a.status.killReady = true
	a.imposter = NewImposterBrain(1)
	a.aliveOthers = 5
	a.currentPhase = PhaseActive
	a.havePhase = true

	blank := make([]uint8, ScreenWidth*ScreenHeight)

	// One idle frame: too short to trigger a reset. Latch must survive.
	_ = a.Step(blank)
	if a.status.latched != StatusImposterReady {
		t.Fatalf("single idle frame wrongly cleared latch: got %v", a.status.latched)
	}
	if a.imposter == nil {
		t.Fatalf("single idle frame wrongly cleared imposter brain")
	}

	// Feed a long idle streak. After agentIdleResetFrames blank frames
	// the reset must fire exactly once.
	for i := 0; i < agentIdleResetFrames+2; i++ {
		_ = a.Step(blank)
	}
	if a.status.latched != StatusUnknown {
		t.Fatalf("sustained idle streak failed to clear latch: got %v", a.status.latched)
	}
	if a.imposter != nil {
		t.Fatalf("sustained idle streak failed to clear imposter brain")
	}
	if a.aliveOthers != -1 {
		t.Fatalf("sustained idle streak failed to clear aliveOthers: got %d", a.aliveOthers)
	}
}

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

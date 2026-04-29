package main

import "testing"

// imposterSetup returns a fresh Agent with the status detector latched
// as a kill-ready imposter, plus an empty frame and a camera/player pair
// aligned so the player sprite sits at the canonical on-screen position
// (playerScreenX, playerScreenY). Callers paint bodies and crewmates into
// the returned pixels buffer to drive each branch of stepImposter.
//
// Camera (504, 54) + player world (564, 120) are the known-walkable
// coordinates from the phase_playing fixture (see fixtures.tsv), so
// SetGoal's nearestWalkable snap never disqualifies a goal we pick.
func imposterSetup() (*Agent, []uint8, Camera, Point) {
	a := NewAgent()
	a.status.latched = StatusImposterReady
	a.status.killReady = true
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	cam := Camera{X: 504, Y: 54}
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
	return a, pixels, cam, player
}

// TestImposter_FleeBody: a visible body triggers the flee branch. The nav
// goal must be the TaskStation farthest from the body (Manhattan), and the
// returned mask must not include ButtonA -- pressing A on a body would be
// a self-report.
func TestImposter_FleeBody(t *testing.T) {
	a, pixels, cam, player := imposterSetup()

	overlayBody(pixels, 60, 50, 7) // orange body near screen center
	bodies := FindBodies(pixels)
	if len(bodies) == 0 {
		t.Fatalf("precondition: FindBodies returned nothing")
	}

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled {
		t.Fatalf("expected handled=true in flee branch")
	}
	if mask&ButtonA != 0 {
		t.Fatalf("flee branch must not press ButtonA (self-report): mask=%#x", mask)
	}
	if !a.nav.HasGoal() {
		t.Fatalf("expected nav goal set for flee")
	}

	bodyW := BodyWorld(bodies[0], cam)
	bestIdx, bestDist := 0, -1
	for i, ts := range TaskStations {
		d := manhattan(ts.Center, bodyW)
		if d > bestDist {
			bestIdx, bestDist = i, d
		}
	}
	want := TaskStations[bestIdx].Center
	if a.nav.Goal() != want {
		t.Fatalf("flee goal: got %v, want %v (farthest from body %v)",
			a.nav.Goal(), want, bodyW)
	}
}

// TestImposter_KillInRange: kill-ready + exactly one non-self crewmate
// within kill range -> press ButtonA.
func TestImposter_KillInRange(t *testing.T) {
	a, pixels, cam, player := imposterSetup()

	// Crewmate screen (68, 58) with cam (504, 54) produces world
	// (68+2+504, 58+8+54) = (574, 120). Player world (564, 120).
	// dx=10, dy=0 -> distSq=100, well inside killRangeSq=400.
	// Clear of the 8-px self-reject box around (playerScreenX=58, 58).
	overlayCrewmate(pixels, 68, 58, 3, false)
	if n := len(FindCrewmates(pixels)); n != 1 {
		t.Fatalf("precondition: want 1 crewmate, got %d", n)
	}

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled {
		t.Fatalf("expected handled=true in kill branch")
	}
	if mask&ButtonA == 0 {
		t.Fatalf("expected ButtonA on in-range lone crewmate, got mask=%#x", mask)
	}
}

// TestImposter_KillChase: kill-ready + lone crewmate but out of range ->
// no ButtonA. A nav goal is set toward the chase target.
func TestImposter_KillChase(t *testing.T) {
	a, pixels, cam, player := imposterSetup()

	// Crewmate at (110, 110) -> world (616, 172). dx=52 dy=52 -> distSq=5408,
	// well outside kill range. Still inside the 128x128 viewport.
	overlayCrewmate(pixels, 110, 110, 3, false)
	if n := len(FindCrewmates(pixels)); n != 1 {
		t.Fatalf("precondition: want 1 crewmate, got %d", n)
	}

	mask, _ := a.stepImposter(pixels, cam, player)
	if mask&ButtonA != 0 {
		t.Fatalf("out-of-range chase must not press ButtonA, got mask=%#x", mask)
	}
}

// TestImposter_NoKillWhenOnCooldown: imposter latched as cooldown
// (killReady=false) must never press A even on a lone in-range crewmate.
// The agent should fall through to the fake-task branch.
func TestImposter_NoKillWhenOnCooldown(t *testing.T) {
	a, pixels, cam, player := imposterSetup()
	a.status.latched = StatusImposterCooldown
	a.status.killReady = false

	overlayCrewmate(pixels, 68, 58, 3, false)

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled {
		t.Fatalf("expected handled=true (fake-task branch)")
	}
	if mask&ButtonA != 0 {
		t.Fatalf("cooldown must not produce ButtonA, got mask=%#x", mask)
	}
	if !a.nav.HasGoal() {
		t.Fatalf("fake-task branch must set a nav goal")
	}
	if !goalIsTaskStation(a.nav.Goal()) {
		t.Fatalf("fake goal %v is not a TaskStation center", a.nav.Goal())
	}
}

// TestImposter_NoKillWithWitnesses: kill-ready + >1 crewmate visible means
// the kill would have a witness; imposter must not press A and should fall
// through to fake-task.
func TestImposter_NoKillWithWitnesses(t *testing.T) {
	a, pixels, cam, player := imposterSetup()

	overlayCrewmate(pixels, 68, 58, 3, false)    // in range
	overlayCrewmate(pixels, 100, 100, 11, false) // witness, out of range
	if n := len(FindCrewmates(pixels)); n != 2 {
		t.Fatalf("precondition: want 2 crewmates, got %d", n)
	}

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled {
		t.Fatalf("expected handled=true")
	}
	if mask&ButtonA != 0 {
		t.Fatalf("kill with witness present must not press A, got mask=%#x", mask)
	}
}

// TestImposter_FakeTaskPicksStation: empty scene (no bodies, no visible
// crewmates) -> fake-task branch picks a TaskStation and navs there.
func TestImposter_FakeTaskPicksStation(t *testing.T) {
	a, pixels, cam, player := imposterSetup()
	a.status.killReady = false // ensure we skip kill-check

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled {
		t.Fatalf("expected handled=true")
	}
	if mask&ButtonA != 0 {
		t.Fatalf("fake-task first frame must not press A, got mask=%#x", mask)
	}
	if !a.nav.HasGoal() {
		t.Fatalf("fake-task must set a nav goal")
	}
	if !goalIsTaskStation(a.nav.Goal()) {
		t.Fatalf("fake goal %v is not a TaskStation center", a.nav.Goal())
	}
	if a.imposter == nil {
		t.Fatalf("imposter brain should be lazily initialized on first step")
	}
}

// TestImposter_FleeBeatsKill: a body and a lone in-range crewmate in the
// same frame — flee branch wins; no ButtonA even though kill conditions
// look satisfied. Mirrors sim.nim's self-report trap: an imposter who
// presses A next to a body reports it.
func TestImposter_FleeBeatsKill(t *testing.T) {
	a, pixels, cam, player := imposterSetup()

	overlayBody(pixels, 80, 80, 7)
	overlayCrewmate(pixels, 68, 58, 3, false)
	if len(FindBodies(pixels)) == 0 {
		t.Fatalf("precondition: body not detected")
	}

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled {
		t.Fatalf("expected handled=true")
	}
	if mask&ButtonA != 0 {
		t.Fatalf("flee must preempt kill, got mask=%#x (would self-report)", mask)
	}
}

func goalIsTaskStation(p Point) bool {
	for _, ts := range TaskStations {
		if ts.Center == p {
			return true
		}
	}
	return false
}

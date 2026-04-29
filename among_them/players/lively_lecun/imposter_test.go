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

// TestImposter_NoKillWithNearbyWitness: the kill target has a second
// crewmate within witness range (Manhattan <= imposterWitnessRange world
// px) of its world position. Imposter must not press A — that kill
// would have a nearby witness.
func TestImposter_NoKillWithNearbyWitness(t *testing.T) {
	a, pixels, cam, player := imposterSetup()

	// Primary target in kill range: screen (68, 58) -> world (574, 120).
	overlayCrewmate(pixels, 68, 58, 3, false)
	// Witness close to target in world coords: screen (80, 58) -> world
	// (586, 120). Manhattan distance to target = 12 world px, well within
	// imposterWitnessRange = 48.
	overlayCrewmate(pixels, 80, 58, 11, false)
	if n := len(FindCrewmates(pixels)); n != 2 {
		t.Fatalf("precondition: want 2 crewmates, got %d", n)
	}

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled {
		t.Fatalf("expected handled=true")
	}
	if mask&ButtonA != 0 {
		t.Fatalf("kill with nearby witness must not press A, got mask=%#x", mask)
	}
}

// TestImposter_KillWithFarWitness: a second crewmate visible but far
// from the kill target (> imposterWitnessRange) should not block the
// kill. This is the behavioral change from the old strict len==1 rule.
func TestImposter_KillWithFarWitness(t *testing.T) {
	a, pixels, cam, player := imposterSetup()

	// Primary target: screen (68, 58) -> world (574, 120).
	overlayCrewmate(pixels, 68, 58, 3, false)
	// Far crewmate: screen (110, 110) -> world (616, 172). Manhattan to
	// target = 42 + 52 = 94, > imposterWitnessRange.
	overlayCrewmate(pixels, 110, 110, 11, false)
	if n := len(FindCrewmates(pixels)); n != 2 {
		t.Fatalf("precondition: want 2 crewmates, got %d", n)
	}

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled {
		t.Fatalf("expected handled=true")
	}
	if mask&ButtonA == 0 {
		t.Fatalf("far witness should not block kill, got mask=%#x", mask)
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

// TestImposter_KillForgetsVictim: after the kill-branch fires ButtonA,
// the victim's color must be dropped from SuspectTracker so the next
// Pick() returns a still-alive crewmate. Without this, the imposter's
// subsequent vote falls through to SKIP (dead slots are excluded by
// findColor), which is worse than an accusation.
func TestImposter_KillForgetsVictim(t *testing.T) {
	a, pixels, cam, player := imposterSetup()

	// Record a prior sighting of color 11 at an older frame. After the
	// kill forgets color 3, Pick should return 11.
	a.suspect.Record(11, 5)
	// Same kill-in-range setup as TestImposter_KillInRange: crewmate
	// color 3 at screen (68, 58).
	overlayCrewmate(pixels, 68, 58, 3, false)
	// The Step pipeline would have recorded color 3 before calling
	// stepImposter; emulate that so we can confirm it's the one that
	// gets cleared (not just "never recorded").
	a.suspect.Record(3, 100)
	if c, ok := a.suspect.Pick(); !ok || c != 3 {
		t.Fatalf("precondition: Pick = (%d, %v), want (3, true)", c, ok)
	}

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled || mask&ButtonA == 0 {
		t.Fatalf("kill precondition failed: mask=%#x handled=%v", mask, handled)
	}

	c, ok := a.suspect.Pick()
	if !ok {
		t.Fatalf("Pick after kill: got (_, false); want alive crewmate")
	}
	if c == 3 {
		t.Fatalf("Pick still returns dead victim color 3; Forget failed")
	}
	if c != 11 {
		t.Fatalf("Pick: got %d, want 11 (the remaining recorded color)", c)
	}
}

// TestImposter_PostKillVentsWhenNearVent: a fresh kill flag plus an
// in-range vent in the same frame must produce a ButtonB press,
// preempting the body-flee branch (we haven't walked anywhere yet so
// the body we just made would be in view next tick).
func TestImposter_PostKillVentsWhenNearVent(t *testing.T) {
	a := NewAgent()
	a.status.latched = StatusImposterReady
	a.status.killReady = true
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	// Use vent 0 at world (606, 339) as our anchor. Place the camera
	// so the player lands exactly on it.
	target := Vents[0].Center
	cam := Camera{X: target.X - playerWorldOffX, Y: target.Y - playerWorldOffY}
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
	if player != target {
		t.Fatalf("setup error: player %v != vent %v", player, target)
	}
	// Mark a kill 1 frame ago so the post-kill window is active.
	a.imposter = NewImposterBrain(1)
	a.frames = 10
	a.imposter.lastKillF = 9

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled {
		t.Fatalf("expected handled=true on vent branch")
	}
	if mask != ButtonB {
		t.Fatalf("expected ButtonB only, got mask=%#x", mask)
	}
}

// TestImposter_NoVentWhenFarFromVent: recent kill but player is not
// standing on a vent — the vent branch must not fire and we fall
// through to normal imposter logic.
func TestImposter_NoVentWhenFarFromVent(t *testing.T) {
	a, pixels, cam, player := imposterSetup()
	a.imposter = NewImposterBrain(1)
	a.frames = 10
	a.imposter.lastKillF = 9

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled {
		t.Fatalf("expected handled=true")
	}
	if mask&ButtonB != 0 {
		t.Fatalf("must not press B when no vent in range, got mask=%#x", mask)
	}
}

// TestImposter_NoVentOutsidePostKillWindow: player is on a vent but the
// last kill was long ago — the vent branch is gated on the post-kill
// window, so no ButtonB.
func TestImposter_NoVentOutsidePostKillWindow(t *testing.T) {
	a := NewAgent()
	a.status.latched = StatusImposterReady
	a.status.killReady = true
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	target := Vents[0].Center
	cam := Camera{X: target.X - playerWorldOffX, Y: target.Y - playerWorldOffY}
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
	a.imposter = NewImposterBrain(1)
	a.frames = 1000
	a.imposter.lastKillF = 10 // 990 frames ago, well outside window

	mask, _ := a.stepImposter(pixels, cam, player)
	if mask&ButtonB != 0 {
		t.Fatalf("must not vent outside post-kill window, got mask=%#x", mask)
	}
}

// TestImposter_VentClientCooldown: after the vent branch fires, a
// second stepImposter call on the very next frame must not press B
// again — the server's 30-tick cooldown would drop it, and sending B
// every frame crowds out other inputs. The client should self-gate
// via lastVentF.
func TestImposter_VentClientCooldown(t *testing.T) {
	a := NewAgent()
	a.status.latched = StatusImposterReady
	a.status.killReady = true
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	target := Vents[0].Center
	cam := Camera{X: target.X - playerWorldOffX, Y: target.Y - playerWorldOffY}
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
	a.imposter = NewImposterBrain(1)
	a.frames = 10
	a.imposter.lastKillF = 9

	mask1, _ := a.stepImposter(pixels, cam, player)
	if mask1 != ButtonB {
		t.Fatalf("first vent frame: got mask=%#x, want ButtonB", mask1)
	}
	// Advance 1 frame. Still in post-kill window. Still on the vent.
	// Client should refuse to press B again.
	a.frames = 11
	mask2, _ := a.stepImposter(pixels, cam, player)
	if mask2&ButtonB != 0 {
		t.Fatalf("client cooldown failed: second vent frame pressed B (mask=%#x)", mask2)
	}
}

// TestImposter_EndgameKillIgnoresWitness: aliveOthers=2 (us + 2
// others; killing one leaves us tied, imposter wins). A nearby
// witness normally blocks the kill; endgame overrides.
func TestImposter_EndgameKillIgnoresWitness(t *testing.T) {
	a, pixels, cam, player := imposterSetup()
	a.aliveOthers = 2 // endgame: this kill wins

	// Same layout as TestImposter_NoKillWithNearbyWitness: target +
	// witness at Manhattan 12 world-px.
	overlayCrewmate(pixels, 68, 58, 3, false)
	overlayCrewmate(pixels, 80, 58, 11, false)
	if n := len(FindCrewmates(pixels)); n != 2 {
		t.Fatalf("precondition: want 2 crewmates, got %d", n)
	}

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled {
		t.Fatalf("expected handled=true")
	}
	if mask&ButtonA == 0 {
		t.Fatalf("endgame must fire ButtonA, got mask=%#x", mask)
	}
}

// TestImposter_EndgameDoesNotKillOutOfRange: endgame override only
// fires when the target is actually in kill range. An out-of-range
// target falls through to normal chase logic.
func TestImposter_EndgameDoesNotKillOutOfRange(t *testing.T) {
	a, pixels, cam, player := imposterSetup()
	a.aliveOthers = 2

	// Far target: screen (110, 110) → world Manhattan ~104 from player
	// (out of kill range; killRangeSq=400).
	overlayCrewmate(pixels, 110, 110, 3, false)

	mask, _ := a.stepImposter(pixels, cam, player)
	if mask&ButtonA != 0 {
		t.Fatalf("endgame must not kill out-of-range target, got mask=%#x", mask)
	}
}

// TestImposter_CrowdKillIgnoresWitness: target surrounded by 2+
// other crewmates → crowd cover kicks in, the kill fires even
// though there'd normally be witnesses.
func TestImposter_CrowdKillIgnoresWitness(t *testing.T) {
	a, pixels, cam, player := imposterSetup()
	// aliveOthers unset (-1) so the endgame rule is inert; only the
	// crowd rule should trigger.
	if a.aliveOthers != -1 {
		t.Fatalf("precondition: aliveOthers should default to -1, got %d", a.aliveOthers)
	}

	// Target at screen (68, 58), crowd neighbors at (80, 58) and (68, 68).
	// World Manhattans to target: 12 and 10 world-px respectively, both
	// ≤ imposterWitnessRange=48.
	overlayCrewmate(pixels, 68, 58, 3, false)
	overlayCrewmate(pixels, 80, 58, 11, false)
	overlayCrewmate(pixels, 68, 68, 13, false)
	if n := len(FindCrewmates(pixels)); n != 3 {
		t.Fatalf("precondition: want 3 crewmates, got %d", n)
	}

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled {
		t.Fatalf("expected handled=true")
	}
	if mask&ButtonA == 0 {
		t.Fatalf("crowd must fire ButtonA, got mask=%#x", mask)
	}
}

// TestImposter_NoAggressiveKillWithSingleWitness: a single nearby
// witness doesn't satisfy the crowd rule (need ≥2), and if aliveOthers
// isn't an endgame number, the override must not fire. The existing
// witness-safe path then blocks the kill.
func TestImposter_NoAggressiveKillWithSingleWitness(t *testing.T) {
	a, pixels, cam, player := imposterSetup()
	a.aliveOthers = 5 // not endgame

	overlayCrewmate(pixels, 68, 58, 3, false)
	overlayCrewmate(pixels, 80, 58, 11, false)

	mask, handled := a.stepImposter(pixels, cam, player)
	if !handled {
		t.Fatalf("expected handled=true")
	}
	if mask&ButtonA != 0 {
		t.Fatalf("single witness must still block kill, got mask=%#x", mask)
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

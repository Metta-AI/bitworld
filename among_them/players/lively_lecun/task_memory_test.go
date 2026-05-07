package main

import "testing"

// iconAtStation fabricates an IconMatch that decodes via IconToTaskWorld
// back onto station i's center for the given camera.
func iconAtStation(i int, cam Camera) IconMatch {
	c := TaskStations[i].Center
	// IconToTaskWorld returns (m.ScreenX+cam.X+6, m.ScreenY+cam.Y+22). We
	// want that to equal c, so solve:
	return IconMatch{ScreenX: c.X - cam.X - 6, ScreenY: c.Y - cam.Y - 22}
}

// camFor returns a camera that centers the viewport on station i, so i is
// on-screen and far-away stations are off-screen.
func camFor(i int) Camera {
	c := TaskStations[i].Center
	return Camera{X: c.X - ScreenWidth/2, Y: c.Y - ScreenHeight/2}
}

func TestTaskMemory_IconPromotesImmediately(t *testing.T) {
	m := NewTaskMemory()
	// Camera centered on station 0; icon for station 0 visible.
	cam := camFor(0)
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
	m.Update(player, cam, []IconMatch{iconAtStation(0, cam)}, nil)
	if got := m.State(0); got != TaskKnown {
		t.Fatalf("icon frame: state(0) = %v, want TaskKnown", got)
	}
}

func TestTaskMemory_SeenNoAfterOnScreenKFramesWithoutIcon(t *testing.T) {
	m := NewTaskMemory()
	// Put camera on station 0 so station 0 is well inside on-screen.
	cam := camFor(0)
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}

	for i := 0; i < onScreenNoIconK-1; i++ {
		m.Update(player, cam, nil, nil)
	}
	if got := m.State(0); got != TaskMaybe {
		t.Fatalf("after %d on-screen frames: state(0) = %v, want TaskMaybe",
			onScreenNoIconK-1, got)
	}
	m.Update(player, cam, nil, nil)
	if got := m.State(0); got != TaskSeenNo {
		t.Fatalf("after %d on-screen frames: state(0) = %v, want TaskSeenNo",
			onScreenNoIconK, got)
	}
}

func TestTaskMemory_IconResetsSeenNoStreak(t *testing.T) {
	m := NewTaskMemory()
	cam := camFor(0)
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}

	for i := 0; i < onScreenNoIconK-1; i++ {
		m.Update(player, cam, nil, nil)
	}
	// Inject an icon on this frame: promotes to known, resets streak.
	m.Update(player, cam, []IconMatch{iconAtStation(0, cam)}, nil)
	if got := m.State(0); got != TaskKnown {
		t.Fatalf("icon injection: state(0) = %v, want TaskKnown", got)
	}
	// Subsequent on-screen-no-icon frames must not demote known.
	for i := 0; i < onScreenNoIconK+2; i++ {
		m.Update(player, cam, nil, nil)
	}
	if got := m.State(0); got != TaskKnown {
		t.Fatalf("known should resist on-screen-no-icon streak: state(0) = %v", got)
	}
}

func TestTaskMemory_BestGoalPriorityBeatsDistance(t *testing.T) {
	m := NewTaskMemory()
	// Place the player somewhere; pick two stations.
	closeIdx, farIdx := 0, 10
	cam := camFor(closeIdx)
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}

	// Mark the near station as seen_no (lowest priority) and the far
	// station as known (highest priority). BestGoal should pick far.
	m.Mark(closeIdx, TaskSeenNo)
	m.Mark(farIdx, TaskKnown)

	if got := m.BestGoal(player); got != farIdx {
		t.Fatalf("BestGoal = %d, want %d (known beats seen_no regardless of distance)",
			got, farIdx)
	}
}

func TestTaskMemory_BestGoalNearestInSameTier(t *testing.T) {
	m := NewTaskMemory()
	// All stations default to TaskMaybe. BestGoal picks the closest to the
	// player. Place the player at station 0's center.
	c := TaskStations[0].Center
	player := Point{c.X, c.Y}
	if got := m.BestGoal(player); got != 0 {
		t.Fatalf("BestGoal at station 0 center = %d, want 0", got)
	}
}

func TestTaskMemory_MarkIsImmediate(t *testing.T) {
	m := NewTaskMemory()
	m.Mark(3, TaskSeenNo)
	if got := m.State(3); got != TaskSeenNo {
		t.Fatalf("Mark: state(3) = %v, want TaskSeenNo", got)
	}
	m.Mark(3, TaskKnown)
	if got := m.State(3); got != TaskKnown {
		t.Fatalf("Mark re-assignment: state(3) = %v, want TaskKnown", got)
	}
}

func TestTaskMemory_Reset(t *testing.T) {
	m := NewTaskMemory()
	m.Mark(0, TaskKnown)
	m.Mark(5, TaskSeenNo)
	m.Mark(10, TaskSeenNo)
	m.Reset()
	for i := range TaskStations {
		if got := m.State(i); got != TaskMaybe {
			t.Fatalf("Reset: state(%d) = %v, want TaskMaybe", i, got)
		}
	}
}

// offScreenStationAndArrow finds any station that's off-screen for the
// given camera, computes its predicted arrow, and returns both. Used to
// generate synthetic matched arrows.
func offScreenStationAndArrow(t *testing.T, cam Camera, player Point) (int, RadarArrow) {
	t.Helper()
	for i := range TaskStations {
		ar, ok := PredictedArrow(player, TaskStations[i].Center, cam)
		if ok {
			return i, ar
		}
	}
	t.Fatalf("no off-screen station found for cam=%v", cam)
	return 0, RadarArrow{}
}

func TestTaskMemory_RadarArrowAtPredictedIncrementsHits(t *testing.T) {
	m := NewTaskMemory()
	cam := camFor(0)
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
	target, pred := offScreenStationAndArrow(t, cam, player)

	m.Update(player, cam, nil, []RadarArrow{pred})
	if got := m.RadarHits(target); got != 1 {
		t.Errorf("RadarHits(%d) = %d, want 1", target, got)
	}
}

func TestTaskMemory_ArrowBeyondToleranceIsNoHit(t *testing.T) {
	m := NewTaskMemory()
	cam := camFor(0)
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
	target, pred := offScreenStationAndArrow(t, cam, player)

	// Shift the arrow 4 px along the axis that isn't clamped to the edge.
	// If predicted ScreenX is at an edge (0 or ScreenWidth-1), shifting ScreenY
	// by 4 stays on the edge and is still out of tolerance.
	shifted := pred
	if pred.ScreenY > 4 && pred.ScreenY < ScreenHeight-4 {
		shifted.ScreenY += 4
	} else {
		shifted.ScreenX += 4
		if shifted.ScreenX >= ScreenWidth {
			shifted.ScreenX -= 8
		}
	}
	m.Update(player, cam, nil, []RadarArrow{shifted})
	if got := m.RadarHits(target); got != 0 {
		t.Errorf("RadarHits(%d) = %d, want 0 (arrow 4 px away)", target, got)
	}
}

func TestTaskMemory_OnScreenStationDoesNotCountArrow(t *testing.T) {
	m := NewTaskMemory()
	cam := camFor(0) // station 0 is on-screen under this camera.
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
	// Even if we flood the frame with arrows, on-screen station 0 gets no
	// hits (PredictedArrow returns false).
	arrows := []RadarArrow{
		{0, 0}, {ScreenWidth - 1, 0}, {0, ScreenHeight - 1}, {ScreenWidth - 1, ScreenHeight - 1},
	}
	m.Update(player, cam, nil, arrows)
	if got := m.RadarHits(0); got != 0 {
		t.Errorf("RadarHits(0) = %d, want 0 (station 0 is on-screen)", got)
	}
}

func TestTaskMemory_BestGoalEightyPercentGate(t *testing.T) {
	m := NewTaskMemory()
	// Seed three stations with different hit counts. Use Mark to keep
	// everything else out of the picture: set all other stations to
	// TaskSeenNo.
	for i := range TaskStations {
		m.Mark(i, TaskSeenNo)
	}
	// Revive three as Maybe with fabricated hit counts.
	top, mid, low := 2, 10, 20 // any three distinct indexes
	m.Mark(top, TaskMaybe)
	m.Mark(mid, TaskMaybe)
	m.Mark(low, TaskMaybe)
	m.radarHits[top] = 10 // top
	m.radarHits[mid] = 9  // within 80%
	m.radarHits[low] = 5  // below 80% gate (5*5=25 < 4*10=40)

	// Position the player so distance order is low < mid < top. The gate
	// should exclude `low`, leaving `mid` (closer of the two gated winners)
	// as the best.
	cLow := TaskStations[low].Center
	cMid := TaskStations[mid].Center
	cTop := TaskStations[top].Center
	_ = cTop
	// Put the player between low and mid, closer to mid.
	player := Point{(cLow.X*1 + cMid.X*3) / 4, (cLow.Y*1 + cMid.Y*3) / 4}

	got := m.BestGoal(player)
	if got != mid && got != top {
		t.Errorf("BestGoal = %d, want one of [%d, %d] (80%% gate should exclude low=%d)",
			got, mid, top, low)
	}
	// Exactly which of mid/top wins depends on station geometry; what
	// matters is `low` is excluded.
	if got == low {
		t.Errorf("BestGoal returned %d which is below the 80%% gate", low)
	}
}

func TestTaskMemory_BestGoalTopZeroFallsBackToDistance(t *testing.T) {
	m := NewTaskMemory()
	// Default state: all Maybe with 0 hits. BestGoal must still return
	// something — the closest station.
	c := TaskStations[0].Center
	player := Point{c.X, c.Y}
	if got := m.BestGoal(player); got != 0 {
		t.Errorf("BestGoal at station 0 center (all 0 hits) = %d, want 0", got)
	}
}

func TestTaskMemory_BestGoalKnownBeatsHighHitMaybe(t *testing.T) {
	m := NewTaskMemory()
	// Put all stations in SeenNo except one Known and one Maybe with lots of
	// hits. Known must win regardless of hit count.
	for i := range TaskStations {
		m.Mark(i, TaskSeenNo)
	}
	knownIdx, maybeIdx := 5, 20
	m.Mark(knownIdx, TaskKnown)
	m.Mark(maybeIdx, TaskMaybe)
	m.radarHits[maybeIdx] = 1000

	// Player far from Known, near Maybe — Known still wins.
	player := TaskStations[maybeIdx].Center
	if got := m.BestGoal(player); got != knownIdx {
		t.Errorf("BestGoal = %d, want %d (Known must beat Maybe with %d hits)",
			got, knownIdx, m.radarHits[maybeIdx])
	}
}

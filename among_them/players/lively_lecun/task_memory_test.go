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

func TestTaskMemory_RadarExcludedAfterKFrames(t *testing.T) {
	m := NewTaskMemory()
	// Put camera on station 0; station 5 is far off-screen.
	cam := camFor(0)
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
	target := 5 // arbitrary station not near station 0

	// K-1 frames with no arrow: stay TaskMaybe.
	for i := 0; i < noArrowK-1; i++ {
		m.Update(player, cam, nil, nil)
	}
	if got := m.State(target); got != TaskMaybe {
		t.Fatalf("after %d no-arrow frames: state(%d) = %v, want TaskMaybe",
			noArrowK-1, target, got)
	}

	// Kth frame: flip to TaskRadarExcluded.
	m.Update(player, cam, nil, nil)
	if got := m.State(target); got != TaskRadarExcluded {
		t.Fatalf("after %d no-arrow frames: state(%d) = %v, want TaskRadarExcluded",
			noArrowK, target, got)
	}
}

func TestTaskMemory_ArrowResetsStreakAndDemotesExclusion(t *testing.T) {
	m := NewTaskMemory()
	cam := camFor(0)
	player := Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}

	// Pick any station the resolver can return from this camera. Not all
	// stations sit on a viewport-edge bearing that NearestStationAlongBearing
	// accepts (many are occluded by closer stations along the same ray) --
	// just use whatever the border scan actually picks.
	target, arr, ok := anyResolvableStation(cam, player)
	if !ok {
		t.Fatalf("setup: no border-pixel bearing resolves to any station")
	}

	// Force into TaskRadarExcluded.
	for i := 0; i < noArrowK; i++ {
		m.Update(player, cam, nil, nil)
	}
	if got := m.State(target); got != TaskRadarExcluded {
		t.Fatalf("setup: expected TaskRadarExcluded, got %v", got)
	}

	// One frame with an arrow toward the target: back to TaskMaybe.
	m.Update(player, cam, nil, []RadarArrow{arr})
	if got := m.State(target); got != TaskMaybe {
		t.Fatalf("arrow frame: state(%d) = %v, want TaskMaybe", target, got)
	}
}

// anyResolvableStation returns (station, arrow, true) for any station that
// the border-scan heuristic picks for some edge pixel. Used to keep the test
// robust against the specific geometry of TaskStations.
func anyResolvableStation(cam Camera, player Point) (int, RadarArrow, bool) {
	try := func(sx, sy int) (int, RadarArrow, bool) {
		bearing := Point{cam.X + sx, cam.Y + sy}
		if idx := NearestStationAlongBearing(player, bearing, nil); idx >= 0 {
			c := TaskStations[idx].Center
			offScreen := c.X < cam.X-offScreenMargin ||
				c.X >= cam.X+ScreenWidth+offScreenMargin ||
				c.Y < cam.Y-offScreenMargin ||
				c.Y >= cam.Y+ScreenHeight+offScreenMargin
			if offScreen {
				return idx, RadarArrow{sx, sy}, true
			}
		}
		return -1, RadarArrow{}, false
	}
	for x := 0; x < ScreenWidth; x++ {
		if i, a, ok := try(x, 0); ok {
			return i, a, true
		}
		if i, a, ok := try(x, ScreenHeight-1); ok {
			return i, a, true
		}
	}
	for y := 1; y < ScreenHeight-1; y++ {
		if i, a, ok := try(0, y); ok {
			return i, a, true
		}
		if i, a, ok := try(ScreenWidth-1, y); ok {
			return i, a, true
		}
	}
	return -1, RadarArrow{}, false
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
	m.Mark(10, TaskRadarExcluded)
	m.Reset()
	for i := range TaskStations {
		if got := m.State(i); got != TaskMaybe {
			t.Fatalf("Reset: state(%d) = %v, want TaskMaybe", i, got)
		}
	}
}

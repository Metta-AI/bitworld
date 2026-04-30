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

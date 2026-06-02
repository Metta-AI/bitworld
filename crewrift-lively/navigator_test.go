package main

import "testing"

// makeWalkMap constructs a WalkMap from a predicate function.
func makeWalkMap(w, h int, walkable func(x, y int) bool) *WalkMap {
	bits := make([]byte, (w*h+7)/8)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if walkable(x, y) {
				i := y*w + x
				bits[i>>3] |= 1 << (i & 7)
			}
		}
	}
	return &WalkMap{Width: w, Height: h, bits: bits}
}

func TestAStar_BasicPath(t *testing.T) {
	// Fully walkable 10x10 grid
	wm := makeWalkMap(10, 10, func(x, y int) bool { return true })
	path := AStar(Point{0, 0}, Point{9, 9}, wm.Walkable, wm.Width, wm.Height)
	if path == nil {
		t.Fatal("expected a path, got nil")
	}
	if path[0] != (Point{0, 0}) {
		t.Errorf("path should start at (0,0), got %v", path[0])
	}
	if path[len(path)-1] != (Point{9, 9}) {
		t.Errorf("path should end at (9,9), got %v", path[len(path)-1])
	}
}

func TestAStar_SameStartGoal(t *testing.T) {
	wm := makeWalkMap(5, 5, func(x, y int) bool { return true })
	path := AStar(Point{2, 2}, Point{2, 2}, wm.Walkable, wm.Width, wm.Height)
	if len(path) != 1 || path[0] != (Point{2, 2}) {
		t.Errorf("same start/goal should return single-element path, got %v", path)
	}
}

func TestAStar_Unreachable(t *testing.T) {
	// Wall splits map vertically at x=5
	wm := makeWalkMap(10, 10, func(x, y int) bool { return x != 5 })
	path := AStar(Point{0, 0}, Point{9, 9}, wm.Walkable, wm.Width, wm.Height)
	if path != nil {
		t.Errorf("expected nil path for unreachable goal, got length %d", len(path))
	}
}

func TestAStar_UnwalkableStart(t *testing.T) {
	wm := makeWalkMap(10, 10, func(x, y int) bool { return x != 0 || y != 0 })
	path := AStar(Point{0, 0}, Point{5, 5}, wm.Walkable, wm.Width, wm.Height)
	if path != nil {
		t.Errorf("expected nil for unwalkable start, got %v", path)
	}
}

func TestAStar_UnwalkableGoal(t *testing.T) {
	wm := makeWalkMap(10, 10, func(x, y int) bool { return x != 9 || y != 9 })
	path := AStar(Point{0, 0}, Point{9, 9}, wm.Walkable, wm.Width, wm.Height)
	if path != nil {
		t.Errorf("expected nil for unwalkable goal, got %v", path)
	}
}

func TestAStar_NoCornercutting(t *testing.T) {
	// Only allow (0,0), (1,0), (1,1) — (0,1) is blocked
	// Diagonal from (0,0) to (1,1) should still work because both (1,0) and (0,1)... wait (0,1) is blocked.
	// So diagonal (0,0)->(1,1) should NOT be allowed.
	wm := makeWalkMap(3, 3, func(x, y int) bool {
		if x == 0 && y == 0 {
			return true
		}
		if x == 1 && y == 0 {
			return true
		}
		if x == 1 && y == 1 {
			return true
		}
		return false
	})
	path := AStar(Point{0, 0}, Point{1, 1}, wm.Walkable, wm.Width, wm.Height)
	if path == nil {
		t.Fatal("expected a path, got nil")
	}
	// Should go (0,0) -> (1,0) -> (1,1) since direct diagonal is blocked
	if len(path) != 3 {
		t.Errorf("expected path of length 3, got %d: %v", len(path), path)
	}
}

func TestNavigator_BasicPath(t *testing.T) {
	wm := makeWalkMap(10, 10, func(x, y int) bool { return true })
	nav := NewNavigator(wm)

	ok := nav.SetGoal(Point{8, 8})
	if !ok {
		t.Fatal("SetGoal should succeed on walkable map")
	}

	mask, arrived := nav.Next(Point{1, 1})
	if arrived {
		t.Error("should not have arrived yet")
	}
	if mask == 0 {
		t.Error("expected non-zero movement mask")
	}
	// Should want to move right and down
	if mask&ButtonRight == 0 {
		t.Error("expected ButtonRight in mask")
	}
	if mask&ButtonDown == 0 {
		t.Error("expected ButtonDown in mask")
	}
}

func TestNavigator_Arrival(t *testing.T) {
	wm := makeWalkMap(10, 10, func(x, y int) bool { return true })
	nav := NewNavigator(wm)
	nav.SetGoal(Point{5, 5})

	// Player at goal
	mask, arrived := nav.Next(Point{5, 5})
	if !arrived {
		t.Error("expected arrived=true when player is at goal")
	}
	if mask != 0 {
		t.Errorf("expected mask=0 on arrival, got %d", mask)
	}
}

func TestNavigator_ArrivalWithinRadius(t *testing.T) {
	wm := makeWalkMap(20, 20, func(x, y int) bool { return true })
	nav := NewNavigator(wm)
	nav.SetGoal(Point{10, 10})

	// Player within navArrivedRadius (manhattan distance <= 4)
	mask, arrived := nav.Next(Point{10, 12})
	if !arrived {
		t.Error("expected arrived=true within radius")
	}
	if mask != 0 {
		t.Errorf("expected mask=0 on arrival, got %d", mask)
	}
}

func TestNavigator_Unreachable(t *testing.T) {
	// Wall splits map
	wm := makeWalkMap(10, 10, func(x, y int) bool { return x != 5 })
	nav := NewNavigator(wm)

	ok := nav.SetGoal(Point{9, 5})
	if !ok {
		t.Fatal("SetGoal should succeed since (9,5) is walkable")
	}

	mask, arrived := nav.Next(Point{0, 5})
	if arrived {
		t.Error("should not arrive at unreachable goal")
	}
	if mask != Unreachable {
		t.Errorf("expected Unreachable mask, got %d", mask)
	}
}

func TestNavigator_NearestWalkable(t *testing.T) {
	// Only cells with x >= 3 are walkable
	wm := makeWalkMap(10, 10, func(x, y int) bool { return x >= 3 })
	p, ok := nearestWalkable(wm, Point{1, 5}, navGoalSnapRadius)
	if !ok {
		t.Fatal("expected to find a walkable cell")
	}
	if !wm.Walkable(p.X, p.Y) {
		t.Errorf("returned point (%d,%d) is not walkable", p.X, p.Y)
	}
	// Should snap to (3, 5) which is distance 2
	if p.X != 3 || p.Y != 5 {
		t.Errorf("expected (3,5), got (%d,%d)", p.X, p.Y)
	}
}

func TestNavigator_Clear(t *testing.T) {
	wm := makeWalkMap(10, 10, func(x, y int) bool { return true })
	nav := NewNavigator(wm)
	nav.SetGoal(Point{5, 5})

	if !nav.HasGoal() {
		t.Error("should have goal after SetGoal")
	}

	nav.Clear()
	if nav.HasGoal() {
		t.Error("should not have goal after Clear")
	}

	mask, arrived := nav.Next(Point{0, 0})
	if mask != 0 || arrived {
		t.Error("Next should return (0, false) after Clear")
	}
}

func TestNavigator_SetGoalUnwalkableArea(t *testing.T) {
	// Entire map is unwalkable
	wm := makeWalkMap(10, 10, func(x, y int) bool { return false })
	nav := NewNavigator(wm)

	ok := nav.SetGoal(Point{5, 5})
	if ok {
		t.Error("SetGoal should return false for completely unwalkable area")
	}
}

func TestNavigator_NoGoal(t *testing.T) {
	wm := makeWalkMap(10, 10, func(x, y int) bool { return true })
	nav := NewNavigator(wm)

	mask, arrived := nav.Next(Point{3, 3})
	if mask != 0 || arrived {
		t.Error("Next with no goal should return (0, false)")
	}
}

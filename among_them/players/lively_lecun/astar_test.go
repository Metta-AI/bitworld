package main

import "testing"

// gridFromASCII turns a slice of equal-length strings into a Walkable
// closure. '.' is walkable, anything else is blocked.
func gridFromASCII(rows []string) (Walkable, int, int) {
	if len(rows) == 0 {
		return func(int, int) bool { return false }, 0, 0
	}
	w, h := len(rows[0]), len(rows)
	for _, r := range rows {
		if len(r) != w {
			panic("ragged grid")
		}
	}
	return func(x, y int) bool {
		if x < 0 || y < 0 || x >= w || y >= h {
			return false
		}
		return rows[y][x] == '.'
	}, w, h
}

func TestAStar_StartEqualsGoal(t *testing.T) {
	walkable, w, h := gridFromASCII([]string{"..."})
	got := AStar(Point{0, 0}, Point{0, 0}, walkable, w, h)
	if len(got) != 1 || got[0] != (Point{0, 0}) {
		t.Errorf("path = %v, want [(0,0)]", got)
	}
}

func TestAStar_StraightLine(t *testing.T) {
	walkable, w, h := gridFromASCII([]string{"....."})
	got := AStar(Point{0, 0}, Point{4, 0}, walkable, w, h)
	if len(got) != 5 {
		t.Fatalf("path length = %d, want 5: %v", len(got), got)
	}
	for i, p := range got {
		want := Point{i, 0}
		if p != want {
			t.Errorf("path[%d] = %v, want %v", i, p, want)
		}
	}
}

func TestAStar_AroundWall(t *testing.T) {
	// 5x3 grid with a vertical wall at x=2 except for row y=0 (the only
	// way through). Expected path length: start (0,2) -> goes up along
	// x=0 to (0,0), across to (4,0), down to (4,2). Manhattan distance is
	// 6, but the wall forces a longer route.
	walkable, w, h := gridFromASCII([]string{
		".....",
		"..#..",
		"..#..",
	})
	got := AStar(Point{0, 2}, Point{4, 2}, walkable, w, h)
	if got == nil {
		t.Fatal("expected a path")
	}
	if got[0] != (Point{0, 2}) || got[len(got)-1] != (Point{4, 2}) {
		t.Errorf("endpoints = %v..%v, want (0,2)..(4,2)", got[0], got[len(got)-1])
	}
	// 8 hops minimum: go up 2, right 4, down 2 = 8 steps + start = 9 cells.
	if len(got) != 9 {
		t.Errorf("path length = %d, want 9 (got %v)", len(got), got)
	}
	// Sanity: no cell sits in a wall.
	for _, p := range got {
		if !walkable(p.X, p.Y) {
			t.Errorf("path crosses wall at %v", p)
		}
	}
	// Each step is exactly 1 Manhattan unit.
	for i := 1; i < len(got); i++ {
		if manhattan(got[i-1], got[i]) != 1 {
			t.Errorf("non-unit step %v -> %v", got[i-1], got[i])
		}
	}
}

func TestAStar_Unreachable(t *testing.T) {
	walkable, w, h := gridFromASCII([]string{
		"..#..",
		"..#..",
		"..#..",
	})
	if got := AStar(Point{0, 1}, Point{4, 1}, walkable, w, h); got != nil {
		t.Errorf("path = %v, want nil (wall is impassable)", got)
	}
}

func TestAStar_NonWalkableEndpoints(t *testing.T) {
	walkable, w, h := gridFromASCII([]string{
		".#.",
		".#.",
		".#.",
	})
	if got := AStar(Point{1, 0}, Point{0, 0}, walkable, w, h); got != nil {
		t.Errorf("non-walkable start should fail; got %v", got)
	}
	if got := AStar(Point{0, 0}, Point{1, 0}, walkable, w, h); got != nil {
		t.Errorf("non-walkable goal should fail; got %v", got)
	}
}

func TestAStar_OutOfBounds(t *testing.T) {
	walkable, w, h := gridFromASCII([]string{"...", "...", "..."})
	if got := AStar(Point{-1, 0}, Point{0, 0}, walkable, w, h); got != nil {
		t.Errorf("OOB start should fail; got %v", got)
	}
	if got := AStar(Point{0, 0}, Point{w, 0}, walkable, w, h); got != nil {
		t.Errorf("OOB goal should fail; got %v", got)
	}
}

func TestAStar_PrefersShortest(t *testing.T) {
	// 5x5 with two routes, one obviously longer due to a tight detour.
	// Start (0,0) -> Goal (4,4). Shortest path has length 9 (8 steps).
	walkable, w, h := gridFromASCII([]string{
		".....",
		".....",
		".....",
		".....",
		".....",
	})
	got := AStar(Point{0, 0}, Point{4, 4}, walkable, w, h)
	if len(got) != 9 {
		t.Errorf("shortest path = %d cells, want 9: %v", len(got), got)
	}
}

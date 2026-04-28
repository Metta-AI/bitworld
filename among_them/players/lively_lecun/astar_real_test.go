package main

import (
	"testing"
	"time"
)

// TestAStar_OnRealMap plans a path between the two known fixture positions
// using the loaded walkMask. This is the first end-to-end check that the
// loader, walkability semantics, and A* agree on real game data.
func TestAStar_OnRealMap(t *testing.T) {
	w := loadWalkMaskForTest(t)
	meta := loadFixtureMeta(t)
	start := Point{meta["playing"].PlayerX, meta["playing"].PlayerY}
	goal := Point{meta["playing_on_task"].PlayerX, meta["playing_on_task"].PlayerY}

	t0 := time.Now()
	path := AStar(start, goal, w.Walkable, MapWidth, MapHeight)
	dur := time.Since(t0)
	if path == nil {
		t.Fatalf("expected path from %v to %v", start, goal)
	}
	t.Logf("path %v -> %v: %d cells in %v", start, goal, len(path), dur)

	// Endpoints.
	if path[0] != start {
		t.Errorf("path[0] = %v, want %v", path[0], start)
	}
	if path[len(path)-1] != goal {
		t.Errorf("path[end] = %v, want %v", path[len(path)-1], goal)
	}
	// Sanity: every step is a unit Manhattan move and every cell walkable.
	for i, p := range path {
		if !w.Walkable(p.X, p.Y) {
			t.Errorf("path[%d]=%v not walkable", i, p)
		}
		if i > 0 && manhattan(path[i-1], p) != 1 {
			t.Errorf("path[%d-1] -> path[%d]: %v -> %v not a unit move", i, i, path[i-1], p)
		}
	}
	// Length lower bound is Manhattan distance + 1 (cells, not steps).
	mh := manhattan(start, goal)
	if len(path) < mh+1 {
		t.Errorf("path length %d shorter than Manhattan+1 = %d (impossible)", len(path), mh+1)
	}
	// Upper bound: 4x Manhattan as a sanity ceiling. The skeld map is open
	// enough that real paths are well under this.
	if len(path) > 4*(mh+1) {
		t.Errorf("path length %d unreasonably long (4x Manhattan = %d)", len(path), 4*(mh+1))
	}
	// First move should head in the goal's general direction. Since
	// goal.X > start.X and goal.Y > start.Y, the first step should be
	// either +x or +y.
	first := path[1]
	if !(first.X > start.X || first.Y > start.Y) {
		t.Errorf("first move %v doesn't head toward goal %v", first, goal)
	}

	// Soft latency budget. A* on the full 952x534 grid should land well
	// under 100ms even for adversarial paths; flag if anything exceeds.
	if dur > 200*time.Millisecond {
		t.Errorf("A* too slow: %v > 200ms", dur)
	}
}

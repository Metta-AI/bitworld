package main

import "testing"

func TestDetectTaskIcons_PlayingFixtureIsEmpty(t *testing.T) {
	got := DetectTaskIcons(loadPhaseFixture(t, "playing"))
	if len(got) != 0 {
		t.Errorf("expected no icons in playing fixture, got %v", got)
	}
}

func TestDetectTaskIcons_OnTaskFixtureFindsAtLeastOneIcon(t *testing.T) {
	got := DetectTaskIcons(loadPhaseFixture(t, "playing_on_task"))
	if len(got) == 0 {
		t.Fatal("expected at least one icon centroid in playing_on_task fixture")
	}
	t.Logf("playing_on_task: %d icon centroids: %v", len(got), got)
	// At least one centroid should be near the player's on-screen center
	// (64, ~58 -- icon center sits SpriteSize/2 + 2 = 8 px above the player
	// box's top edge per sim.nim:2316-2319).
	const wantNearX, wantNearY = 64, 58
	const tol = 14
	found := false
	for _, c := range got {
		if absInt(c.X-wantNearX) <= tol && absInt(c.Y-wantNearY) <= tol {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("no centroid near (%d, %d) within ±%d; got %v",
			wantNearX, wantNearY, tol, got)
	}
}

func TestIconScreenToTaskWorld_ReproducesFixtureTaskPosition(t *testing.T) {
	// playing_on_task fixture: player teleported to its task's center, so
	// the task center ~ player coords. Camera is also recorded. Detect the
	// on-task icon, convert to world, expect a position close to the
	// recorded player coords.
	pixels := loadPhaseFixture(t, "playing_on_task")
	meta := loadFixtureMeta(t)["playing_on_task"]
	cam := Camera{X: meta.CameraX, Y: meta.CameraY}

	icons := DetectTaskIcons(pixels)
	if len(icons) == 0 {
		t.Fatal("expected at least one icon centroid")
	}
	want := Point{meta.PlayerX, meta.PlayerY}
	bestDist := -1
	var best Point
	for _, c := range icons {
		w := IconScreenToTaskWorld(c, cam)
		d := manhattan(w, want)
		if bestDist == -1 || d < bestDist {
			bestDist, best = d, w
		}
	}
	if bestDist > 12 {
		t.Errorf("nearest icon-derived world pos %v is %d from recorded %v; want <=12",
			best, bestDist, want)
	}
	t.Logf("nearest icon -> %v vs recorded %v (Manhattan %d)", best, want, bestDist)
}

func TestTaskMemory_AddDedups(t *testing.T) {
	var m TaskMemory
	if !m.Add(Point{100, 100}) {
		t.Error("first Add should succeed")
	}
	if m.Add(Point{105, 102}) {
		t.Error("close-by Add should be deduped (within mergeRadius=12)")
	}
	if !m.Add(Point{200, 200}) {
		t.Error("distant Add should succeed")
	}
	if m.Len() != 2 {
		t.Errorf("Len = %d, want 2", m.Len())
	}
}

func TestTaskMemory_Closest(t *testing.T) {
	var m TaskMemory
	if _, _, ok := m.Closest(Point{0, 0}); ok {
		t.Error("Closest on empty memory should return ok=false")
	}
	m.Add(Point{100, 100})
	m.Add(Point{200, 200})
	m.Add(Point{50, 50})
	got, i, ok := m.Closest(Point{55, 60})
	if !ok {
		t.Fatal("Closest should succeed with non-empty memory")
	}
	if got != (Point{50, 50}) {
		t.Errorf("Closest = %v (idx %d), want (50, 50)", got, i)
	}
}

func TestTaskMemory_Forget(t *testing.T) {
	var m TaskMemory
	m.Add(Point{100, 100})
	m.Add(Point{200, 200})
	m.Add(Point{300, 300})
	m.Forget(1)
	if m.Len() != 2 {
		t.Errorf("Len after Forget = %d, want 2", m.Len())
	}
	for _, p := range m.Known {
		if p == (Point{200, 200}) {
			t.Errorf("Forget(1) didn't remove the middle entry: %v", m.Known)
		}
	}
}

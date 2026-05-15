package main

import "testing"

func TestImposter_HuntingModeActivates(t *testing.T) {
	brain := NewImposterBrain(42)
	brain.roleDetectedF = 100

	// Well before hunting window: 100 frames into a 1200-frame cooldown.
	if brain.isHunting(200) {
		t.Fatal("should not be hunting at frame 200 (900 frames remaining)")
	}

	// Right at the hunting window boundary: 1200 - (1060-100) = 240.
	if !brain.isHunting(1060) {
		t.Fatal("should be hunting at frame 1060 (240 frames remaining)")
	}

	// Inside hunting window: 1200 - (1200-100) = 100.
	if !brain.isHunting(1200) {
		t.Fatal("should be hunting at frame 1200 (100 frames remaining)")
	}

	// Cooldown expired: 1200 - (1400-100) = -100 → 0.
	if brain.isHunting(1400) {
		t.Fatal("should not be hunting when cooldown is expired")
	}
}

func TestImposter_HuntingAfterKill(t *testing.T) {
	brain := NewImposterBrain(42)
	brain.lastKillF = 500

	// Well before window.
	if brain.isHunting(600) {
		t.Fatal("should not be hunting 100 frames after kill")
	}

	// At window: 1200 - (1460-500) = 240.
	if !brain.isHunting(1460) {
		t.Fatal("should be hunting at frame 1460")
	}
}

func TestImposter_RecentSighting(t *testing.T) {
	brain := NewImposterBrain(42)
	brain.recordSighting(3, Point{100, 200}, 50)
	brain.recordSighting(7, Point{300, 400}, 80)

	// Both are recent at frame 100.
	pos, ok := brain.recentSighting(100, 255)
	if !ok {
		t.Fatal("expected a recent sighting")
	}
	if pos != (Point{300, 400}) {
		t.Fatalf("expected most recent sighting (color 7), got %v", pos)
	}

	// Only color 7 is still recent at frame 280 (80+240=320 > 280).
	pos, ok = brain.recentSighting(280, 255)
	if !ok {
		t.Fatal("expected color 7 still recent")
	}
	if pos != (Point{300, 400}) {
		t.Fatalf("got %v", pos)
	}

	// Neither is recent at frame 400.
	_, ok = brain.recentSighting(400, 255)
	if ok {
		t.Fatal("no sightings should be recent at frame 400")
	}
}

func TestImposter_RecentSightingExcludesSelf(t *testing.T) {
	brain := NewImposterBrain(42)
	brain.recordSighting(5, Point{100, 100}, 50)

	// Self color 5 should be excluded.
	_, ok := brain.recentSighting(60, 5)
	if ok {
		t.Fatal("self color should be excluded from sightings")
	}
}

func TestImposter_PickHuntingTargetUsesSighting(t *testing.T) {
	brain := NewImposterBrain(42)
	brain.recordSighting(3, Point{130, 250}, 90)

	idx, ok := brain.pickHuntingTarget(100, 255, Point{500, 100})
	if !ok {
		t.Fatal("expected a hunting target")
	}
	// Should pick the station closest to (130, 250).
	station := TaskStations[idx]
	for i, ts := range TaskStations {
		if i == idx {
			continue
		}
		if manhattan(ts.Center, Point{130, 250}) < manhattan(station.Center, Point{130, 250}) {
			t.Fatalf("station %d (%s) at %v is closer to sighting than picked %d (%s) at %v",
				i, ts.Name, ts.Center, idx, station.Name, station.Center)
		}
	}
}

func TestImposter_PickHuntingTargetFallsBackToIsolated(t *testing.T) {
	brain := NewImposterBrain(42)
	// No sightings recorded.

	idx, ok := brain.pickHuntingTarget(100, 255, Point{500, 100})
	if !ok {
		t.Fatal("expected isolated station fallback")
	}
	// Should pick the most isolated (farthest from cafeteria).
	for i := range TaskStations {
		if stationIsolation[i] > stationIsolation[idx] {
			t.Fatalf("station %d has isolation %d > picked %d with %d",
				i, stationIsolation[i], idx, stationIsolation[idx])
		}
	}
}

func TestImposter_OrbitStation(t *testing.T) {
	// A point near a known station should find it.
	near := TaskStations[17].Center // Start Reactor at (131, 252)
	idx, ok := pickOrbitStation(near)
	if !ok {
		t.Fatal("expected an orbit station near Start Reactor")
	}
	d := manhattan(TaskStations[idx].Center, near)
	if d > huntingOrbitRadius {
		t.Fatalf("orbit station %d is %d px away, want <= %d", idx, d, huntingOrbitRadius)
	}
}

func TestImposter_CooldownResetOnVoting(t *testing.T) {
	brain := NewImposterBrain(42)
	brain.lastKillF = 100

	// Simulate voting reset at frame 500.
	brain.lastKillF = 500
	brain.killsThisRound = 0

	// 240 frames before new cooldown expires: 500 + 1200 - 240 = 1460.
	if !brain.isHunting(1460) {
		t.Fatal("should be hunting after vote-reset cooldown")
	}
	// Just after reset — far from hunting window.
	if brain.isHunting(600) {
		t.Fatal("should not be hunting 100 frames after vote")
	}
}

package main

import "testing"

func TestFindTaskIcons_PlayingFixtureIsEmpty(t *testing.T) {
	got := FindTaskIcons(loadPhaseFixture(t, "playing"))
	if len(got) != 0 {
		t.Errorf("playing fixture should match no icons; got %v", got)
	}
}

func TestFindTaskIcons_OnTaskFixtureMatchesOneIcon(t *testing.T) {
	pixels := loadPhaseFixture(t, "playing_on_task")
	got := FindTaskIcons(pixels)
	if len(got) == 0 {
		t.Fatal("playing_on_task should match at least one icon; got none")
	}
	// Icon should land near screen center-top (the player is standing on
	// the task, so the icon hovers just above them).
	// From task_seen_test: the sprite top-left lies around (58, 45).
	const wantX, wantY = 58, 45
	const tol = 4
	found := false
	for _, m := range got {
		if absInt(m.ScreenX-wantX) <= tol && absInt(m.ScreenY-wantY) <= tol {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("no match near (%d, %d) ±%d; got %v", wantX, wantY, tol, got)
	}
	t.Logf("on_task matches: %v", got)
}

func TestIconToTaskWorld_FixtureConvergesOnPlayer(t *testing.T) {
	// playing_on_task: the recorded player stands inside the task box, so
	// converting the on-screen icon to world should give a point close to
	// the recorded player (manhattan <= task box diagonal ~16).
	pixels := loadPhaseFixture(t, "playing_on_task")
	meta := loadFixtureMeta(t)["playing_on_task"]
	cam := Camera{X: meta.CameraX, Y: meta.CameraY}

	matches := FindTaskIcons(pixels)
	if len(matches) == 0 {
		t.Fatal("expected at least one match")
	}
	want := Point{meta.PlayerX, meta.PlayerY}
	bestDist := -1
	var best Point
	for _, m := range matches {
		w := IconToTaskWorld(m, cam)
		d := manhattan(w, want)
		if bestDist == -1 || d < bestDist {
			bestDist, best = d, w
		}
	}
	if bestDist > 16 {
		t.Errorf("nearest world position %v is %d from recorded %v; want <=16",
			best, bestDist, want)
	}
	t.Logf("nearest %v -> recorded %v (manhattan %d)", best, want, bestDist)
}

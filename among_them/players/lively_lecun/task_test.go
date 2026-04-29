package main

import "testing"

// fixtureContext returns the (matches, player, cam) triple for a fixture so
// tests can exercise world-space task detection.
func fixtureContext(t *testing.T, name string) ([]IconMatch, Point, Camera) {
	t.Helper()
	pixels := loadPhaseFixture(t, name)
	meta := loadFixtureMeta(t)[name]
	cam := Camera{X: meta.CameraX, Y: meta.CameraY}
	return FindTaskIcons(pixels), Point{meta.PlayerX, meta.PlayerY}, cam
}

func TestOnTask_PlayingFixture_NotOnTask(t *testing.T) {
	matches, player, cam := fixtureContext(t, "playing")
	if OnTask(matches, player, cam) {
		t.Error("OnTask returned true for plain playing fixture (no task overlay)")
	}
}

func TestOnTask_PlayingOnTaskFixture_True(t *testing.T) {
	matches, player, cam := fixtureContext(t, "playing_on_task")
	if !OnTask(matches, player, cam) {
		t.Error("OnTask should detect the task icon overlay in playing_on_task fixture")
	}
}

func TestOnTask_OtherPhases_False(t *testing.T) {
	for _, name := range []string{"lobby_waiting", "lobby_ready", "voting", "vote_result", "game_over"} {
		matches, player, cam := fixtureContext(t, name)
		if OnTask(matches, player, cam) {
			t.Errorf("OnTask returned true for %s fixture; should be false", name)
		}
	}
}

func TestOnTask_EmptyMatches(t *testing.T) {
	player := Point{100, 100}
	cam := Camera{X: 50, Y: 50}
	if OnTask(nil, player, cam) {
		t.Error("nil matches should yield false")
	}
	if OnTask([]IconMatch{}, player, cam) {
		t.Error("empty matches should yield false")
	}
}

func TestOnTask_PlayerOffByOneAgent(t *testing.T) {
	// Regression: earlier screen-space OnTask fired when the player stood
	// one agent-width (~13 world px) to the right of the task, causing the
	// TaskHolder to lock in ButtonA while never actually being on the task.
	// With world-space comparison that match should be rejected.
	matches, player, cam := fixtureContext(t, "playing_on_task")
	// Shove the player 13 px east: same frame, but report the player
	// standing one tile over. OnTask must return false.
	player.X += 13
	if OnTask(matches, player, cam) {
		t.Error("OnTask should reject a match 13 px east of the player (off-task)")
	}
}

func TestTaskHolder_NotHandledWhenIdle(t *testing.T) {
	var h TaskHolder
	matches, player, cam := fixtureContext(t, "playing") // no task overlay
	for i := 0; i < 5; i++ {
		mask, handled := h.Adjust(matches, player, cam)
		if handled {
			t.Errorf("step %d: should not be handled when no task in view, got mask=%#x", i, mask)
		}
	}
}

func TestTaskHolder_HoldsForTaskCompleteTicks(t *testing.T) {
	var h TaskHolder
	matches, player, cam := fixtureContext(t, "playing_on_task")
	for i := 0; i < taskHoldTicks; i++ {
		mask, handled := h.Adjust(matches, player, cam)
		if !handled {
			t.Fatalf("step %d: expected handled=true while holding, got mask=%#x handled=false", i, mask)
		}
		if mask != ButtonA {
			t.Errorf("step %d: expected mask=ButtonA while holding, got %#x", i, mask)
		}
	}
	if h.Completes != 1 {
		t.Errorf("after one full hold, Completes = %d, want 1", h.Completes)
	}
	// After the hold completes, if we somehow stayed on the task, a new
	// hold would start. To prove the hold is finite, feed a no-task frame.
	emptyMatches, eplayer, ecam := fixtureContext(t, "playing")
	if _, handled := h.Adjust(emptyMatches, eplayer, ecam); handled {
		t.Error("after hold completion on a no-task frame, should fall through")
	}
}

func TestTaskHolder_IsHolding(t *testing.T) {
	var h TaskHolder
	if h.IsHolding() {
		t.Error("zero-value TaskHolder should not be holding")
	}
	matches, player, cam := fixtureContext(t, "playing_on_task")
	h.Adjust(matches, player, cam)
	if !h.IsHolding() {
		t.Error("after triggering on a task fixture, should be holding")
	}
}

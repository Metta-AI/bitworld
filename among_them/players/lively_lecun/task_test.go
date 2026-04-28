package main

import "testing"

func TestOnTask_PlayingFixture_NotOnTask(t *testing.T) {
	// In the regular playing fixture nothing is centered; expect false.
	if OnTask(loadPhaseFixture(t, "playing")) {
		t.Error("OnTask returned true for plain playing fixture (no task overlay)")
	}
}

func TestOnTask_PlayingOnTaskFixture_True(t *testing.T) {
	if !OnTask(loadPhaseFixture(t, "playing_on_task")) {
		t.Error("OnTask should detect the task icon overlay in playing_on_task fixture")
	}
}

func TestOnTask_OtherPhases_False(t *testing.T) {
	for _, name := range []string{"lobby_waiting", "lobby_ready", "voting", "vote_result", "game_over"} {
		if OnTask(loadPhaseFixture(t, name)) {
			t.Errorf("OnTask returned true for %s fixture; should be false", name)
		}
	}
}

func TestOnTask_SynthesizedIcon(t *testing.T) {
	p := make([]uint8, ScreenWidth*ScreenHeight)
	// Paint a small palette-9 blob in the task region.
	for y := 44; y < 56; y++ {
		for x := 58; x < 70; x++ {
			p[y*ScreenWidth+x] = taskIconColor
		}
	}
	if !OnTask(p) {
		t.Error("OnTask should detect a synthesized 12x12 blob in the task region")
	}
}

func TestOnTask_WrongSize(t *testing.T) {
	if OnTask(make([]uint8, 100)) {
		t.Error("wrong-size input should yield false")
	}
	if OnTask(nil) {
		t.Error("nil should yield false")
	}
}

func TestTaskHolder_NotHandledWhenIdle(t *testing.T) {
	var h TaskHolder
	pixels := loadPhaseFixture(t, "playing") // no task overlay
	for i := 0; i < 5; i++ {
		mask, handled := h.Adjust(pixels)
		if handled {
			t.Errorf("step %d: should not be handled when no task in view, got mask=%#x", i, mask)
		}
	}
}

func TestTaskHolder_HoldsForTaskCompleteTicks(t *testing.T) {
	var h TaskHolder
	pixels := loadPhaseFixture(t, "playing_on_task")
	for i := 0; i < taskHoldTicks; i++ {
		mask, handled := h.Adjust(pixels)
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
	emptyFrame := loadPhaseFixture(t, "playing")
	if _, handled := h.Adjust(emptyFrame); handled {
		t.Error("after hold completion on a no-task frame, should fall through")
	}
}

func TestTaskHolder_IsHolding(t *testing.T) {
	var h TaskHolder
	if h.IsHolding() {
		t.Error("zero-value TaskHolder should not be holding")
	}
	h.Adjust(loadPhaseFixture(t, "playing_on_task"))
	if !h.IsHolding() {
		t.Error("after triggering on a task fixture, should be holding")
	}
}

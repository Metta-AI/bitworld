package main

import "testing"

func TestStabilityFilter_ConfirmsAfterN(t *testing.T) {
	sf := &StabilityFilter{}
	taskPos := Point{100, 200}

	for i := 0; i < stabilityRequired-1; i++ {
		confirmed := sf.Update([]Point{taskPos})
		if len(confirmed) != 0 {
			t.Fatalf("frame %d: got confirmation too early", i)
		}
	}
	confirmed := sf.Update([]Point{taskPos})
	if len(confirmed) != 1 {
		t.Fatalf("expected 1 confirmed, got %d", len(confirmed))
	}
	if confirmed[0] != taskPos {
		t.Fatalf("confirmed pos = %v, want %v", confirmed[0], taskPos)
	}
}

func TestStabilityFilter_RejectsMovingBlob(t *testing.T) {
	sf := &StabilityFilter{}

	// Simulate a player moving: position changes each frame beyond radius.
	for i := 0; i < stabilityRequired+5; i++ {
		pos := Point{100 + i*10, 200}
		confirmed := sf.Update([]Point{pos})
		if len(confirmed) != 0 {
			t.Fatalf("frame %d: moving blob should not confirm", i)
		}
	}
}

func TestStabilityFilter_ToleratesSmallDrift(t *testing.T) {
	sf := &StabilityFilter{}
	base := Point{100, 200}

	// Drift within stabilityRadius each frame; cycle through offsets.
	offsets := [][2]int{{0, 0}, {1, 0}, {0, 1}, {-1, 0}, {0, -1}}
	var confirmed []Point
	for i := 0; i < stabilityRequired; i++ {
		o := offsets[i%len(offsets)]
		confirmed = sf.Update([]Point{{base.X + o[0], base.Y + o[1]}})
	}
	if len(confirmed) != 1 {
		t.Fatalf("expected confirmation with small drift, got %d", len(confirmed))
	}
}

func TestStabilityFilter_EvictsAfterMaxAge(t *testing.T) {
	sf := &StabilityFilter{}
	taskPos := Point{100, 200}

	// See it for 2 frames, then it disappears.
	sf.Update([]Point{taskPos})
	sf.Update([]Point{taskPos})

	// Gone for stabilityMaxAge+1 frames.
	for i := 0; i <= stabilityMaxAge; i++ {
		sf.Update(nil)
	}

	// Reappear -- should start fresh, not carry over old count.
	for i := 0; i < stabilityRequired-1; i++ {
		confirmed := sf.Update([]Point{taskPos})
		if len(confirmed) != 0 {
			t.Fatalf("should not confirm from stale candidate")
		}
	}
	confirmed := sf.Update([]Point{taskPos})
	if len(confirmed) != 1 {
		t.Fatalf("expected fresh confirmation after eviction+re-observation")
	}
}

func TestStabilityFilter_MultipleTasksIndependent(t *testing.T) {
	sf := &StabilityFilter{}
	task1 := Point{100, 200}
	task2 := Point{500, 300}

	const gap = 2
	// task1 appears first; task2 joins `gap` frames later.
	for i := 0; i < gap; i++ {
		sf.Update([]Point{task1})
	}
	// Advance both until task1 is one frame away from confirmation.
	for i := 0; i < stabilityRequired-gap-1; i++ {
		if got := sf.Update([]Point{task1, task2}); len(got) != 0 {
			t.Fatalf("premature confirmation at %d: %v", i, got)
		}
	}
	// Next frame: task1 confirms, task2 still needs `gap` more.
	confirmed := sf.Update([]Point{task1, task2})
	if len(confirmed) != 1 || confirmed[0] != task1 {
		t.Fatalf("expected only task1 confirmed, got %v", confirmed)
	}

	// task2 needs `gap` more observations to reach stabilityRequired.
	for i := 0; i < gap-1; i++ {
		if got := sf.Update([]Point{task2}); len(got) != 0 {
			t.Fatalf("task2 premature at %d: %v", i, got)
		}
	}
	confirmed = sf.Update([]Point{task2})
	if len(confirmed) != 1 || confirmed[0] != task2 {
		t.Fatalf("expected task2 confirmed, got %v", confirmed)
	}
}

func TestStabilityFilter_TaskVsPlayer(t *testing.T) {
	sf := &StabilityFilter{}
	taskPos := Point{200, 150}

	// Both appear on screen together: task is static, player moves.
	for i := 0; i < stabilityRequired+2; i++ {
		playerPos := Point{200 + i*8, 150} // moves 8px/frame
		confirmed := sf.Update([]Point{taskPos, playerPos})
		if i == stabilityRequired-1 {
			if len(confirmed) != 1 || confirmed[0] != taskPos {
				t.Fatalf("frame %d: expected task confirmed, got %v", i, confirmed)
			}
		} else if i < stabilityRequired-1 {
			if len(confirmed) != 0 {
				t.Fatalf("frame %d: premature confirmation %v", i, confirmed)
			}
		}
	}
}

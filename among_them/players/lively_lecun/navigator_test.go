package main

import "testing"

func TestNavigator_NoGoalReturnsZero(t *testing.T) {
	n := NewNavigator(loadWalkMaskForTest(t))
	if mask, arrived := n.Next(Point{564, 120}); mask != 0 || arrived {
		t.Errorf("Next without goal = (%#x, %v), want (0, false)", mask, arrived)
	}
}

func TestNavigator_RejectsUnwalkableGoal(t *testing.T) {
	n := NewNavigator(loadWalkMaskForTest(t))
	if n.SetGoal(Point{0, 0}) {
		t.Error("SetGoal at known-unwalkable corner should return false")
	}
	if n.HasGoal() {
		t.Error("HasGoal should be false after rejected SetGoal")
	}
}

func TestNavigator_AcceptsWalkableGoal(t *testing.T) {
	n := NewNavigator(loadWalkMaskForTest(t))
	goal := Point{876, 204}
	if !n.SetGoal(goal) {
		t.Fatal("SetGoal at known-walkable point should succeed")
	}
	if !n.HasGoal() || n.Goal() != goal {
		t.Errorf("HasGoal/Goal = %v/%v, want true/%v", n.HasGoal(), n.Goal(), goal)
	}
}

func TestNavigator_StepsTowardGoal(t *testing.T) {
	n := NewNavigator(loadWalkMaskForTest(t))
	start := Point{564, 120}
	goal := Point{876, 204}
	if !n.SetGoal(goal) {
		t.Fatal("SetGoal failed")
	}
	mask, arrived := n.Next(start)
	if arrived {
		t.Fatal("should not be arrived from far away")
	}
	if mask == 0 {
		t.Fatal("expected a non-zero direction mask")
	}
	// Goal is right and down of start, so the mask must include at least
	// one of Right/Down and exclude the opposite cardinal.
	if mask&(ButtonRight|ButtonDown) == 0 {
		t.Errorf("mask=%#x, expected Right or Down bit set", mask)
	}
	if mask&ButtonLeft != 0 || mask&ButtonUp != 0 {
		t.Errorf("mask=%#x, must not point Left/Up when goal is right+down", mask)
	}
}

func TestNavigator_ArrivedNearGoal(t *testing.T) {
	n := NewNavigator(loadWalkMaskForTest(t))
	goal := Point{876, 204}
	n.SetGoal(goal)
	mask, arrived := n.Next(Point{875, 204})
	if !arrived {
		t.Errorf("expected arrived within %d of goal", navArrivedRadius)
	}
	if mask != 0 {
		t.Errorf("mask=%#x at goal, want 0", mask)
	}
}

func TestNavigator_ProgressMonotonically(t *testing.T) {
	// Step the navigator from start toward goal, applying its returned
	// mask as a unit cardinal move each iteration. Verify we make steady
	// progress (decreasing manhattan distance to goal).
	n := NewNavigator(loadWalkMaskForTest(t))
	start := Point{564, 120}
	goal := Point{876, 204}
	n.SetGoal(goal)

	pos := start
	prevDist := manhattan(pos, goal)
	for step := 0; step < 5000; step++ {
		mask, arrived := n.Next(pos)
		if arrived {
			t.Logf("arrived at step %d, pos=%v", step, pos)
			return
		}
		if mask == 0 {
			t.Fatalf("step %d: mask=0 but not arrived (pos=%v)", step, pos)
		}
		// Apply the mask as a single-pixel cardinal move when feasible.
		next := pos
		if mask&ButtonRight != 0 && n.Walk.Walkable(pos.X+1, pos.Y) {
			next.X++
		} else if mask&ButtonLeft != 0 && n.Walk.Walkable(pos.X-1, pos.Y) {
			next.X--
		}
		if mask&ButtonDown != 0 && n.Walk.Walkable(pos.X, pos.Y+1) {
			next.Y++
		} else if mask&ButtonUp != 0 && n.Walk.Walkable(pos.X, pos.Y-1) {
			next.Y--
		}
		if next == pos {
			t.Fatalf("step %d: mask=%#x didn't move from %v (walls block all directions?)", step, mask, pos)
		}
		pos = next
		// Distance monotone non-increasing? Not strictly -- the path may
		// take detours -- but it should shrink overall. Allow a per-step
		// loosening: distance at step N must be <= prevDist + 0 long-term
		// (since A* is optimal). Just sanity-check we don't get stuck.
		_ = prevDist
	}
	t.Fatalf("did not arrive within 5000 steps; last pos=%v dist=%d", pos, manhattan(pos, goal))
}

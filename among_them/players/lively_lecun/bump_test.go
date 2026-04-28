package main

import "testing"

// scrambleFrame paints distinct content into a frame so two scrambles with
// different seeds differ in many pixels (simulating camera motion).
func scrambleFrame(seed uint8) []uint8 {
	p := make([]uint8, ScreenWidth*ScreenHeight)
	for i := range p {
		p[i] = uint8(i+int(seed)) & 0x0F
	}
	return p
}

func TestBumper_FirstFrameNeverPerturbs(t *testing.T) {
	var b Bumper
	frame := scrambleFrame(0)
	if got := b.Adjust(frame, ButtonLeft); got != ButtonLeft {
		t.Errorf("first frame should pass through, got %#x", got)
	}
}

func TestBumper_PassesThroughWhenMoving(t *testing.T) {
	var b Bumper
	for seed := 0; seed < 20; seed++ {
		frame := scrambleFrame(uint8(seed))
		got := b.Adjust(frame, ButtonLeft)
		if got != ButtonLeft {
			t.Fatalf("step %d: high-motion frame should pass through, got %#x", seed, got)
		}
	}
}

func TestBumper_PerturbsWhenStuck(t *testing.T) {
	var b Bumper
	frame := scrambleFrame(0)
	// Several identical frames with the same desired direction.
	// First call primes prev; subsequent calls see diff=0 (low motion).
	for i := 0; i < bumperStuckStreak+1; i++ {
		got := b.Adjust(frame, ButtonLeft)
		if i < bumperStuckStreak {
			if got != ButtonLeft {
				t.Errorf("step %d should still pass through, got %#x", i, got)
			}
		} else {
			// On step bumperStuckStreak, perturbation should kick in.
			if got&(ButtonUp|ButtonDown) == 0 {
				t.Errorf("step %d should perturb to Up or Down, got %#x", i, got)
			}
		}
	}
}

func TestBumper_PerturbDurationIsFinite(t *testing.T) {
	var b Bumper
	frame := scrambleFrame(0)
	// Drive into perturbation.
	for i := 0; i <= bumperStuckStreak; i++ {
		b.Adjust(frame, ButtonLeft)
	}
	// Continue feeding low-motion frames; for the next bumperPerturbTicks-1
	// calls we should keep getting the perturb mask. After that we should
	// resume passing through `want` (until streak rebuilds).
	for i := 0; i < bumperPerturbTicks-1; i++ {
		got := b.Adjust(frame, ButtonLeft)
		if got&(ButtonUp|ButtonDown) == 0 {
			t.Errorf("during perturb step %d, expected Up/Down, got %#x", i, got)
		}
	}
	// Next call: perturb counter exhausted; lowMotionStreak was reset, so
	// we should pass through `want` again.
	if got := b.Adjust(frame, ButtonLeft); got != ButtonLeft {
		t.Errorf("after perturb, expected ButtonLeft, got %#x", got)
	}
}

func TestBumper_ZeroWantNeverPerturbs(t *testing.T) {
	var b Bumper
	frame := scrambleFrame(0)
	for i := 0; i < bumperStuckStreak+5; i++ {
		if got := b.Adjust(frame, 0); got != 0 {
			t.Errorf("step %d: want=0 should always return 0, got %#x", i, got)
		}
	}
}

func TestPerpendicular(t *testing.T) {
	cases := []struct {
		want    uint8
		evenOK  uint8 // expected when seed&1==0
		oddOK   uint8 // expected when seed&1==1
	}{
		{ButtonLeft, ButtonUp, ButtonDown},
		{ButtonRight, ButtonUp, ButtonDown},
		{ButtonUp, ButtonLeft, ButtonRight},
		{ButtonDown, ButtonLeft, ButtonRight},
		// Diagonals: horizontal component dominates the choice.
		{ButtonLeft | ButtonUp, ButtonUp, ButtonDown},
		{ButtonRight | ButtonDown, ButtonUp, ButtonDown},
	}
	for _, c := range cases {
		if got := perpendicular(c.want, 0); got != c.evenOK {
			t.Errorf("perpendicular(%#x, 0) = %#x, want %#x", c.want, got, c.evenOK)
		}
		if got := perpendicular(c.want, 1); got != c.oddOK {
			t.Errorf("perpendicular(%#x, 1) = %#x, want %#x", c.want, got, c.oddOK)
		}
	}
	if got := perpendicular(0, 0); got != 0 {
		t.Errorf("perpendicular(0, _) = %#x, want 0", got)
	}
}

func TestPixelDiff(t *testing.T) {
	a := []uint8{1, 2, 3, 4, 5}
	b := []uint8{1, 9, 3, 9, 5}
	if got := pixelDiff(a, b); got != 2 {
		t.Errorf("pixelDiff = %d, want 2", got)
	}
	if got := pixelDiff(a, a); got != 0 {
		t.Errorf("pixelDiff(a,a) = %d, want 0", got)
	}
	// Mismatched lengths fall back to a deliberately large value.
	if got := pixelDiff(a, []uint8{1, 2}); got <= 0 {
		t.Errorf("mismatched lengths should be positive, got %d", got)
	}
}

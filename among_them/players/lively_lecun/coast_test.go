package main

import "testing"

func TestShouldCoast(t *testing.T) {
	goal := Point{100, 100}

	cases := []struct {
		name   string
		player Point
		speed  int
		want   bool
	}{
		// Outside the coast radius: never coast, regardless of speed.
		{"far-slow", Point{200, 200}, 0, false},
		{"far-fast", Point{200, 200}, 10, false},

		// Inside radius but below speed threshold: steer normally so we
		// can converge onto the center from a near-stop.
		{"close-stopped", Point{105, 105}, 0, false},
		{"close-creeping", Point{105, 105}, 2, false}, // under threshold

		// Inside radius and fast: brake regardless of direction so a
		// head-on approach doesn't overshoot and an orbiting agent's
		// tangential velocity decays.
		{"close-fast-on-axis", Point{112, 100}, 3, true},
		{"close-orbit-tangential", Point{100, 108}, 5, true},
		{"at-goal-fast", Point{100, 100}, 4, true},

		// Right at the radius boundary counts as "inside" (agentCoastRadius
		// is an inclusive Chebyshev bound) so a fast agent clipping the
		// edge still brakes.
		{"edge-fast", Point{112, 112}, 3, true},
		{"just-outside-fast", Point{113, 100}, 5, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := shouldCoast(tc.player, goal, tc.speed)
			if got != tc.want {
				t.Fatalf("shouldCoast(player=%v goal=%v speed=%d) = %v, want %v",
					tc.player, goal, tc.speed, got, tc.want)
			}
		})
	}
}

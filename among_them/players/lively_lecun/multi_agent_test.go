package main

import "testing"

// TestMultiAgent_Determinism: LivelyPolicy spawns one Go subprocess per
// batch row today (lively_policy.py), but cogames may change that and
// our websocket path runs multiple Agents in the same process anyway.
// Confirm no package-level state leaks between Agents: N agents
// stepped through the same frame stream in interleaved order must
// each produce the same mask sequence as a single agent stepped solo
// through it.
//
// This guards the lazy-initialized sprite caches (crewmateStable,
// bodyStable, etc.) and any future globals added during v2 work.
func TestMultiAgent_Determinism(t *testing.T) {
	// Two-frame alternating stream: playing → playing_on_task → ...
	// The first fixture exercises tracking + task memory + nav;
	// the second exercises TaskHolder, which has different mask
	// output, so we see meaningful variation across frames.
	a := loadPhaseFixture(t, "playing")
	b := loadPhaseFixture(t, "playing_on_task")
	const steps = 20
	stream := make([][]uint8, steps)
	for i := 0; i < steps; i++ {
		if i%2 == 0 {
			stream[i] = append([]uint8(nil), a...)
		} else {
			stream[i] = append([]uint8(nil), b...)
		}
	}

	// Solo run establishes the ground truth.
	solo := NewAgent()
	want := make([]uint8, steps)
	for i, f := range stream {
		want[i] = solo.Step(f)
	}

	// Interleaved run: 4 agents, round-robin, same stream per agent.
	// Each agent's i-th Step happens after all other agents have done
	// their i-th Step, so any shared state would show up as a divergence.
	const n = 4
	agents := make([]*Agent, n)
	for i := range agents {
		agents[i] = NewAgent()
	}
	got := make([][]uint8, n)
	for i := range got {
		got[i] = make([]uint8, steps)
	}
	for i, f := range stream {
		for k, ag := range agents {
			// Each agent gets its own copy of the frame to rule out
			// accidental buffer sharing through Step.
			frame := append([]uint8(nil), f...)
			got[k][i] = ag.Step(frame)
		}
	}

	for k := range agents {
		for i := range stream {
			if got[k][i] != want[i] {
				t.Fatalf("agent %d frame %d: mask %#x diverged from solo %#x",
					k, i, got[k][i], want[i])
			}
		}
	}
}

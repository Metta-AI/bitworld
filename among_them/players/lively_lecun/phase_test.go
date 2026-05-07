package main

import (
	"os"
	"path/filepath"
	"testing"
)

func loadPhaseFixture(t *testing.T, name string) []uint8 {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "phase_"+name+".bin"))
	if err != nil {
		t.Fatalf("read fixture %q: %v", name, err)
	}
	if len(raw) != ProtocolBytes {
		t.Fatalf("fixture %q: got %d bytes, want %d", name, len(raw), ProtocolBytes)
	}
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	if err := UnpackFrame(raw, pixels); err != nil {
		t.Fatalf("unpack %q: %v", name, err)
	}
	return pixels
}

func TestClassifyFixtures(t *testing.T) {
	cases := []struct {
		fixture string
		want    Phase
	}{
		{"lobby_waiting", PhaseIdle},
		{"lobby_ready", PhaseIdle},
		{"role_reveal", PhaseIdle},
		{"playing", PhaseActive},
		{"voting", PhaseVoting},
		{"vote_result", PhaseIdle},
		{"game_over", PhaseIdle},
	}
	for _, c := range cases {
		t.Run(c.fixture, func(t *testing.T) {
			got := Classify(loadPhaseFixture(t, c.fixture))
			if got != c.want {
				t.Errorf("Classify(%s) = %v, want %v", c.fixture, got, c.want)
			}
		})
	}
}

func TestClassifyWrongSize(t *testing.T) {
	if got := Classify(make([]uint8, 100)); got != PhaseIdle {
		t.Errorf("wrong-size input → %v, want PhaseIdle", got)
	}
	if got := Classify(nil); got != PhaseIdle {
		t.Errorf("nil input → %v, want PhaseIdle", got)
	}
}

func TestPhaseString(t *testing.T) {
	cases := map[Phase]string{
		PhaseIdle:   "idle",
		PhaseActive: "active",
		PhaseVoting: "voting",
		Phase(99):   "unknown",
	}
	for p, want := range cases {
		if got := p.String(); got != want {
			t.Errorf("Phase(%d).String() = %q, want %q", p, got, want)
		}
	}
}

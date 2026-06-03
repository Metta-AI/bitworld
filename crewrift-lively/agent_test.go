package main

import (
	"testing"

	"github.com/golang/snappy"
)

func TestAgentBasicStep(t *testing.T) {
	agent := NewAgent()

	// Create a small all-walkable map (8x8, all pixels have alpha > 0)
	w, h := 8, 8
	pixels := make([]byte, w*h*4)
	for i := 0; i < w*h; i++ {
		pixels[i*4+0] = 0xFF // R
		pixels[i*4+1] = 0xFF // G
		pixels[i*4+2] = 0xFF // B
		pixels[i*4+3] = 0xFF // A (walkable)
	}
	compressed := snappy.Encode(nil, pixels)

	// Process DefineSprite with walkability map
	agent.ProcessMessage(&DefineSprite{
		SpriteID: 1,
		Width:    uint16(w),
		Height:   uint16(h),
		Pixels:   pixels,
		Label:    "walkability map",
	})
	_ = compressed // compressed was for the wire format, here we pass decoded pixels directly

	if agent.walkMap == nil {
		t.Fatal("walkMap should be set after processing walkability map sprite")
	}
	if agent.nav == nil {
		t.Fatal("navigator should be created after walkability map")
	}

	// Set viewport so the center (4,4) matches the player position
	agent.ProcessMessage(&SetViewport{Layer: 0, Width: 8, Height: 8})

	// Define a player sprite and object at viewport center
	agent.ProcessMessage(&DefineSprite{
		SpriteID: 2,
		Width:    1,
		Height:   1,
		Pixels:   []byte{0, 0, 0, 255},
		Label:    "player red right",
	})
	agent.ProcessMessage(&DefineObject{
		ObjectID: 1,
		X:        4,
		Y:        4,
		Z:        0,
		Layer:    0,
		SpriteID: 2,
	})

	// Call Step - should return a non-zero mask (wander or navigation)
	mask := agent.Step()
	if mask == 0 {
		t.Errorf("expected non-zero mask from Step(), got 0")
	}

	// Verify the agent detected self color
	if agent.selfColor != "red" {
		t.Errorf("expected selfColor='red', got %q", agent.selfColor)
	}
}

func TestAgentPhaseTransition(t *testing.T) {
	agent := NewAgent()

	// Start in idle - no objects
	mask := agent.Step()
	if mask == 0 {
		t.Errorf("idle phase should produce non-zero wander mask")
	}
	if agent.phase != PhaseIdle {
		t.Errorf("expected PhaseIdle, got %d", agent.phase)
	}

	// Add a vote-related object to trigger voting phase
	agent.ProcessMessage(&DefineSprite{
		SpriteID: 10,
		Width:    1,
		Height:   1,
		Pixels:   []byte{0, 0, 0, 255},
		Label:    "vote panel",
	})
	agent.ProcessMessage(&DefineObject{
		ObjectID: 10,
		X:        0,
		Y:        0,
		Z:        0,
		Layer:    0,
		SpriteID: 10,
	})

	// Step should detect voting phase
	agent.Step()
	if agent.phase != PhaseVoting {
		t.Errorf("expected PhaseVoting, got %d", agent.phase)
	}
	if agent.voter == nil {
		t.Error("voter should be created on entering voting phase")
	}
}

func TestSuspectTracker(t *testing.T) {
	st := NewSuspectTracker()
	st.SetSelf("red")

	// Record some sightings
	st.Record("blue", 10)
	st.Record("green", 20)
	st.Record("red", 30) // should be skipped (self)

	pick, ok := st.Pick()
	if !ok {
		t.Fatal("expected Pick() to return a result")
	}
	if pick != "green" {
		t.Errorf("expected 'green' (most recent), got %q", pick)
	}

	// Forget green
	st.Forget("green")
	pick, ok = st.Pick()
	if !ok {
		t.Fatal("expected Pick() to return a result after forget")
	}
	if pick != "blue" {
		t.Errorf("expected 'blue', got %q", pick)
	}
}

func TestWanderer(t *testing.T) {
	w := &Wanderer{}
	expected := []uint8{ButtonUp, ButtonRight, ButtonDown, ButtonLeft, ButtonUp}
	for i, exp := range expected {
		got := w.Next()
		if got != exp {
			t.Errorf("step %d: expected 0x%02x, got 0x%02x", i, exp, got)
		}
	}
}

func TestVoteControllerSkip(t *testing.T) {
	vc := NewVoteController("")

	// First call primes (returns 0)
	mask := vc.Next(NewPerception(NewWorld()))
	if mask != 0 {
		t.Errorf("expected 0 (prime), got 0x%02x", mask)
	}

	// Next calls should navigate toward skip
	mask = vc.Next(NewPerception(NewWorld()))
	if mask != ButtonRight {
		t.Errorf("expected ButtonRight for empty target, got 0x%02x", mask)
	}
}

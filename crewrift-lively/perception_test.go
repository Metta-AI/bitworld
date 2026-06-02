package main

import "testing"

// helper to build a world with sprites and objects for testing.
func buildTestWorld(entries []struct {
	objID    uint16
	spriteID uint16
	label    string
	x, y     int16
}) *World {
	w := NewWorld()
	for _, e := range entries {
		w.Apply(&DefineSprite{
			SpriteID: e.spriteID,
			Width:    1,
			Height:   1,
			Pixels:   []byte{0, 0, 0, 0},
			Label:    e.label,
		})
		w.Apply(&DefineObject{
			ObjectID: e.objID,
			X:        e.x,
			Y:        e.y,
			Z:        0,
			Layer:    0,
			SpriteID: e.spriteID,
		})
	}
	return w
}

func TestDetectPhaseActive(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "player red", 10, 20},
		{2, 101, "task Fix Wires", 30, 40},
	})
	p := NewPerception(w)
	if got := p.Phase(); got != PhaseActive {
		t.Fatalf("expected PhaseActive, got %d", got)
	}
}

func TestDetectPhaseVoting(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "player red", 10, 20},
		{2, 101, "Vote timer", 50, 60},
	})
	p := NewPerception(w)
	if got := p.Phase(); got != PhaseVoting {
		t.Fatalf("expected PhaseVoting, got %d", got)
	}
}

func TestDetectPhaseIdle(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "lobby background", 0, 0},
	})
	p := NewPerception(w)
	if got := p.Phase(); got != PhaseIdle {
		t.Fatalf("expected PhaseIdle, got %d", got)
	}
}

func TestDetectPhaseIdleEmpty(t *testing.T) {
	w := NewWorld()
	p := NewPerception(w)
	if got := p.Phase(); got != PhaseIdle {
		t.Fatalf("expected PhaseIdle for empty world, got %d", got)
	}
}

func TestFindPlayers(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "player red", 10, 20},
		{2, 101, "player blue", 30, 40},
		{3, 102, "task Fix Wires", 50, 60},
	})
	p := NewPerception(w)
	players := p.Players()
	if len(players) != 2 {
		t.Fatalf("expected 2 players, got %d", len(players))
	}
	colors := map[string]bool{}
	for _, pl := range players {
		colors[pl.Color] = true
	}
	if !colors["red"] || !colors["blue"] {
		t.Fatalf("expected red and blue players, got %v", colors)
	}
}

func TestFindBodies(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "body red", 15, 25},
	})
	p := NewPerception(w)
	bodies := p.Bodies()
	if len(bodies) != 1 {
		t.Fatalf("expected 1 body, got %d", len(bodies))
	}
	if bodies[0].Color != "red" {
		t.Fatalf("expected color red, got %s", bodies[0].Color)
	}
	if bodies[0].Pos.X != 15 || bodies[0].Pos.Y != 25 {
		t.Fatalf("expected pos (15,25), got (%d,%d)", bodies[0].Pos.X, bodies[0].Pos.Y)
	}
}

func TestPerceptionSelfPosition(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "self", 42, 84},
	})
	p := NewPerception(w)
	pos, ok := p.SelfPosition()
	if !ok {
		t.Fatal("expected to find self position")
	}
	if pos.X != 42 || pos.Y != 84 {
		t.Fatalf("expected (42,84), got (%d,%d)", pos.X, pos.Y)
	}
}

func TestPerceptionSelfColor(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "self red", 10, 20},
	})
	p := NewPerception(w)
	color := p.SelfColor()
	if color != "red" {
		t.Fatalf("expected 'red', got '%s'", color)
	}
}

func TestPerceptionSelfColorEmpty(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "self", 10, 20},
	})
	p := NewPerception(w)
	color := p.SelfColor()
	if color != "" {
		t.Fatalf("expected empty string for 'self' without color, got '%s'", color)
	}
}

func TestPerceptionIsImposter(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "kill cooldown", 0, 0},
	})
	p := NewPerception(w)
	if !p.IsImposter() {
		t.Fatal("expected IsImposter() == true")
	}
}

func TestPerceptionIsImposterFalse(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "player red", 0, 0},
	})
	p := NewPerception(w)
	if p.IsImposter() {
		t.Fatal("expected IsImposter() == false")
	}
}

func TestPerceptionKillReady(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "kill ready", 0, 0},
	})
	p := NewPerception(w)
	if !p.KillReady() {
		t.Fatal("expected KillReady() == true")
	}
}

func TestPerceptionKillReadyFalseOnCooldown(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "kill cooldown", 0, 0},
	})
	p := NewPerception(w)
	if p.KillReady() {
		t.Fatal("expected KillReady() == false when on cooldown")
	}
}

func TestFindTasks(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "task Fix Wires", 100, 200},
		{2, 101, "task Upload Data", 150, 250},
	})
	p := NewPerception(w)
	tasks := p.Tasks()
	if len(tasks) != 2 {
		t.Fatalf("expected 2 tasks, got %d", len(tasks))
	}
	names := map[string]bool{}
	for _, tk := range tasks {
		names[tk.Name] = true
	}
	if !names["Fix Wires"] || !names["Upload Data"] {
		t.Fatalf("expected Fix Wires and Upload Data, got %v", names)
	}
}

func TestFindVents(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "vent", 60, 70},
		{2, 101, "Vent North", 80, 90},
		{3, 102, "player red", 10, 20},
	})
	p := NewPerception(w)
	vents := p.Vents()
	if len(vents) != 2 {
		t.Fatalf("expected 2 vents, got %d", len(vents))
	}
}

func TestPerceptionCursorOnPlayer(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "cursor red", 0, 0},
	})
	p := NewPerception(w)
	if !p.CursorOnPlayer("red") {
		t.Fatal("expected CursorOnPlayer('red') == true")
	}
	if p.CursorOnPlayer("blue") {
		t.Fatal("expected CursorOnPlayer('blue') == false")
	}
}

func TestPerceptionCursorOnSkip(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "cursor skip", 0, 0},
	})
	p := NewPerception(w)
	if !p.CursorOnSkip() {
		t.Fatal("expected CursorOnSkip() == true")
	}
}

func TestPerceptionCursorOnSkipFalse(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "cursor red", 0, 0},
	})
	p := NewPerception(w)
	if p.CursorOnSkip() {
		t.Fatal("expected CursorOnSkip() == false when cursor is on a player")
	}
}

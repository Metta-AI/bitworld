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
		{1, 100, "player red right", 10, 20},
		{2, 101, "task bubble", 30, 40},
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
		{1, 100, "player red right", 10, 20},
		{2, 101, "vote cursor", 50, 60},
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
		{1, 100, "player red right", 10, 20},
		{2, 101, "player blue left", 30, 40},
		{3, 102, "task bubble", 50, 60},
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

func TestFindPlayersMultiWordColor(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "player light blue right", 10, 20},
		{2, 101, "player dark brown left", 30, 40},
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
	if !colors["light blue"] || !colors["dark brown"] {
		t.Fatalf("expected 'light blue' and 'dark brown', got %v", colors)
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
		{1, 100, "player red right", 200, 150},
		{2, 101, "player blue left", 500, 400},
	})
	// Set viewport so center is near player red
	w.Apply(&SetViewport{Layer: 0, Width: 400, Height: 300})
	p := NewPerception(w)
	pos, ok := p.SelfPosition()
	if !ok {
		t.Fatal("expected to find self position")
	}
	if pos.X != 200 || pos.Y != 150 {
		t.Fatalf("expected (200,150) nearest viewport center, got (%d,%d)", pos.X, pos.Y)
	}
}

func TestPerceptionSelfColor(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "vote self marker red", 10, 20},
	})
	p := NewPerception(w)
	color := p.SelfColor()
	if color != "red" {
		t.Fatalf("expected 'red', got '%s'", color)
	}
}

func TestPerceptionSelfColorFromViewport(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "player red right", 200, 150},
		{2, 101, "player blue left", 500, 400},
	})
	w.Apply(&SetViewport{Layer: 0, Width: 400, Height: 300})
	p := NewPerception(w)
	color := p.SelfColor()
	if color != "red" {
		t.Fatalf("expected 'red' from viewport center proximity, got '%s'", color)
	}
}

func TestPerceptionIsImposter(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "imposter icon", 0, 0},
	})
	p := NewPerception(w)
	if !p.IsImposter() {
		t.Fatal("expected IsImposter() == true")
	}
}

func TestPerceptionIsImposterCooldown(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "imposter icon cooldown", 0, 0},
	})
	p := NewPerception(w)
	if !p.IsImposter() {
		t.Fatal("expected IsImposter() == true for cooldown too")
	}
}

func TestPerceptionIsImposterFalse(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "player red right", 0, 0},
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
		{1, 100, "imposter icon", 0, 0},
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
		{1, 100, "imposter icon cooldown", 0, 0},
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
		{1, 100, "task bubble", 100, 200},
		{2, 101, "task arrow", 150, 250},
		{3, 102, "player red right", 50, 60},
	})
	p := NewPerception(w)
	tasks := p.Tasks()
	if len(tasks) != 2 {
		t.Fatalf("expected 2 tasks, got %d", len(tasks))
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
		{3, 102, "player red right", 10, 20},
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
		{1, 100, "vote cursor", 50, 30},
		{2, 101, "vote self marker red", 10, 30},
		{3, 102, "vote dot blue", 10, 60},
	})
	p := NewPerception(w)
	if !p.CursorOnPlayer("red") {
		t.Fatal("expected CursorOnPlayer('red') == true")
	}
	if p.CursorOnPlayer("blue") {
		t.Fatal("expected CursorOnPlayer('blue') == false (different Y)")
	}
}

func TestPerceptionCursorOnSkip(t *testing.T) {
	w := buildTestWorld([]struct {
		objID    uint16
		spriteID uint16
		label    string
		x, y     int16
	}{
		{1, 100, "vote skip cursor", 0, 0},
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
		{1, 100, "vote cursor", 0, 0},
	})
	p := NewPerception(w)
	if p.CursorOnSkip() {
		t.Fatal("expected CursorOnSkip() == false when only vote cursor is present")
	}
}

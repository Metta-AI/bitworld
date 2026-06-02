package main

import "strings"

// Phase represents the current game phase.
type Phase uint8

const (
	PhaseIdle   Phase = iota
	PhaseActive
	PhaseVoting
)

// PlayerInfo describes a visible player in the game.
type PlayerInfo struct {
	ObjectID uint16
	Color    string
	Pos      Point
	IsSelf   bool
}

// BodyInfo describes a dead body visible in the game.
type BodyInfo struct {
	ObjectID uint16
	Color    string
	Pos      Point
}

// TaskInfo describes a task location visible in the game.
type TaskInfo struct {
	ObjectID uint16
	Name     string
	Pos      Point
}

// VentInfo describes a vent location visible in the game.
type VentInfo struct {
	ObjectID uint16
	Pos      Point
}

// Perception extracts high-level game state from the World's sprite labels.
type Perception struct {
	world *World
}

// NewPerception creates a Perception that reads from the given World.
func NewPerception(w *World) *Perception {
	return &Perception{world: w}
}

// Phase detects the current game phase from object labels.
func (p *Perception) Phase() Phase {
	objects := p.world.AllObjects()
	for _, obj := range objects {
		label := strings.ToLower(p.world.SpriteLabel(obj.SpriteID))
		if strings.Contains(label, "vote") {
			return PhaseVoting
		}
		if strings.Contains(label, "lobby") || strings.Contains(label, "game over") {
			return PhaseIdle
		}
	}
	if len(objects) > 0 {
		return PhaseActive
	}
	return PhaseIdle
}

// Players returns all visible players extracted from "player <color>" labels.
func (p *Perception) Players() []PlayerInfo {
	var result []PlayerInfo
	for _, obj := range p.world.AllObjects() {
		label := p.world.SpriteLabel(obj.SpriteID)
		if color, ok := strings.CutPrefix(label, "player "); ok {
			result = append(result, PlayerInfo{
				ObjectID: obj.ID,
				Color:    color,
				Pos:      Point{int(obj.X), int(obj.Y)},
				IsSelf:   false,
			})
		}
	}
	return result
}

// SelfPosition returns the position of the "self" object if present.
func (p *Perception) SelfPosition() (Point, bool) {
	for _, obj := range p.world.AllObjects() {
		label := p.world.SpriteLabel(obj.SpriteID)
		if label == "self" || strings.HasPrefix(label, "self ") {
			return Point{int(obj.X), int(obj.Y)}, true
		}
	}
	return Point{}, false
}

// SelfColor returns the color from a "self <color>" label, or "".
func (p *Perception) SelfColor() string {
	for _, obj := range p.world.AllObjects() {
		label := p.world.SpriteLabel(obj.SpriteID)
		if color, ok := strings.CutPrefix(label, "self "); ok {
			return color
		}
	}
	return ""
}

// Bodies returns all visible dead bodies extracted from "body <color>" labels.
func (p *Perception) Bodies() []BodyInfo {
	var result []BodyInfo
	for _, obj := range p.world.AllObjects() {
		label := p.world.SpriteLabel(obj.SpriteID)
		if color, ok := strings.CutPrefix(label, "body "); ok {
			result = append(result, BodyInfo{
				ObjectID: obj.ID,
				Color:    color,
				Pos:      Point{int(obj.X), int(obj.Y)},
			})
		}
	}
	return result
}

// Tasks returns all visible task objects extracted from "task <name>" labels.
func (p *Perception) Tasks() []TaskInfo {
	var result []TaskInfo
	for _, obj := range p.world.AllObjects() {
		label := p.world.SpriteLabel(obj.SpriteID)
		if name, ok := strings.CutPrefix(label, "task "); ok {
			result = append(result, TaskInfo{
				ObjectID: obj.ID,
				Name:     name,
				Pos:      Point{int(obj.X), int(obj.Y)},
			})
		}
	}
	return result
}

// Vents returns all visible vent objects (labels containing "vent", case-insensitive).
func (p *Perception) Vents() []VentInfo {
	var result []VentInfo
	for _, obj := range p.world.AllObjects() {
		label := strings.ToLower(p.world.SpriteLabel(obj.SpriteID))
		if strings.Contains(label, "vent") {
			result = append(result, VentInfo{
				ObjectID: obj.ID,
				Pos:      Point{int(obj.X), int(obj.Y)},
			})
		}
	}
	return result
}

// IsImposter returns true if any label suggests we have the kill ability.
func (p *Perception) IsImposter() bool {
	for _, obj := range p.world.AllObjects() {
		label := strings.ToLower(p.world.SpriteLabel(obj.SpriteID))
		if strings.Contains(label, "kill") && (strings.Contains(label, "cooldown") || strings.Contains(label, "ready")) {
			return true
		}
	}
	return false
}

// KillReady returns true if the kill ability is ready (not on cooldown).
func (p *Perception) KillReady() bool {
	for _, obj := range p.world.AllObjects() {
		label := strings.ToLower(p.world.SpriteLabel(obj.SpriteID))
		if strings.Contains(label, "kill") && strings.Contains(label, "ready") {
			return true
		}
	}
	return false
}

// CursorOnPlayer returns true if any label suggests the cursor is on a player of the given color.
func (p *Perception) CursorOnPlayer(color string) bool {
	colorLower := strings.ToLower(color)
	for _, obj := range p.world.AllObjects() {
		label := strings.ToLower(p.world.SpriteLabel(obj.SpriteID))
		if strings.Contains(label, "cursor") && strings.Contains(label, colorLower) {
			return true
		}
	}
	return false
}

// CursorOnSkip returns true if any label suggests the cursor is on the skip button.
func (p *Perception) CursorOnSkip() bool {
	for _, obj := range p.world.AllObjects() {
		label := strings.ToLower(p.world.SpriteLabel(obj.SpriteID))
		if strings.Contains(label, "cursor") && strings.Contains(label, "skip") {
			return true
		}
	}
	return false
}

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

// Players returns all visible players extracted from "player <color> <direction>" labels.
// Direction suffixes ("right", "left") are stripped to produce the color.
func (p *Perception) Players() []PlayerInfo {
	var result []PlayerInfo
	for _, obj := range p.world.AllObjects() {
		label := p.world.SpriteLabel(obj.SpriteID)
		rest, ok := strings.CutPrefix(label, "player ")
		if !ok {
			continue
		}
		color := stripDirection(rest)
		if color == "" {
			continue
		}
		result = append(result, PlayerInfo{
			ObjectID: obj.ID,
			Color:    color,
			Pos:      Point{int(obj.X), int(obj.Y)},
			IsSelf:   false,
		})
	}
	return result
}

// stripDirection removes a trailing " right" or " left" from a color+direction string.
// "red right" -> "red", "light blue left" -> "light blue", "red" -> "red"
func stripDirection(s string) string {
	if after, ok := strings.CutSuffix(s, " right"); ok {
		return after
	}
	if after, ok := strings.CutSuffix(s, " left"); ok {
		return after
	}
	return s
}

// SelfPosition returns the position of the player nearest to viewport center.
// This works because the camera follows the local player.
func (p *Perception) SelfPosition() (Point, bool) {
	players := p.Players()
	if len(players) == 0 {
		return Point{}, false
	}

	cx, cy := p.viewportCenter()
	if cx == 0 && cy == 0 {
		// No viewport info; return first player as fallback
		return players[0].Pos, true
	}

	best := players[0]
	bestDist := manhattan(best.Pos, Point{cx, cy})
	for _, pl := range players[1:] {
		d := manhattan(pl.Pos, Point{cx, cy})
		if d < bestDist {
			best = pl
			bestDist = d
		}
	}
	return best.Pos, true
}

// SelfColor returns our player's color.
// During voting: detected from "vote self marker <color>" objects.
// During gameplay: the color of the player nearest viewport center.
func (p *Perception) SelfColor() string {
	// Check for vote self marker objects (most reliable)
	for _, obj := range p.world.AllObjects() {
		label := p.world.SpriteLabel(obj.SpriteID)
		if color, ok := strings.CutPrefix(label, "vote self marker "); ok {
			return color
		}
	}

	// Fallback: player nearest viewport center
	players := p.Players()
	if len(players) == 0 {
		return ""
	}
	cx, cy := p.viewportCenter()
	if cx == 0 && cy == 0 {
		return ""
	}
	best := players[0]
	bestDist := manhattan(best.Pos, Point{cx, cy})
	for _, pl := range players[1:] {
		d := manhattan(pl.Pos, Point{cx, cy})
		if d < bestDist {
			best = pl
			bestDist = d
		}
	}
	return best.Color
}

// viewportCenter returns the center of layer 0's viewport.
func (p *Perception) viewportCenter() (int, int) {
	layer, ok := p.world.layers[0]
	if !ok || layer.Width == 0 || layer.Height == 0 {
		return 0, 0
	}
	return int(layer.Width) / 2, int(layer.Height) / 2
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

// Tasks returns all visible task objects ("task bubble" or "task arrow" labels).
func (p *Perception) Tasks() []TaskInfo {
	var result []TaskInfo
	for _, obj := range p.world.AllObjects() {
		label := p.world.SpriteLabel(obj.SpriteID)
		if label == "task bubble" || label == "task arrow" {
			result = append(result, TaskInfo{
				ObjectID: obj.ID,
				Name:     label,
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

// IsImposter returns true if the "imposter icon" or "imposter icon cooldown" object is present.
func (p *Perception) IsImposter() bool {
	for _, obj := range p.world.AllObjects() {
		label := p.world.SpriteLabel(obj.SpriteID)
		if label == "imposter icon" || label == "imposter icon cooldown" {
			return true
		}
	}
	return false
}

// KillReady returns true if "imposter icon" (not cooldown) is present.
func (p *Perception) KillReady() bool {
	for _, obj := range p.world.AllObjects() {
		label := p.world.SpriteLabel(obj.SpriteID)
		if label == "imposter icon" {
			return true
		}
	}
	return false
}

// CursorOnPlayer returns true if the vote cursor position overlaps with a player of the given color.
// Currently uses Y-coordinate proximity between "vote cursor" and player vote panels.
func (p *Perception) CursorOnPlayer(color string) bool {
	var cursorObj *ObjectState
	for _, obj := range p.world.AllObjects() {
		label := p.world.SpriteLabel(obj.SpriteID)
		if label == "vote cursor" {
			o := obj
			cursorObj = &o
			break
		}
	}
	if cursorObj == nil {
		return false
	}

	// Find the vote self marker or vote dot for the target color
	targetLabel := "vote self marker " + color
	dotLabel := "vote dot " + color
	for _, obj := range p.world.AllObjects() {
		label := p.world.SpriteLabel(obj.SpriteID)
		if label == targetLabel || label == dotLabel {
			dy := absInt(int(cursorObj.Y) - int(obj.Y))
			if dy <= 10 {
				return true
			}
		}
	}
	return false
}

// CursorOnSkip returns true if the "vote skip cursor" object is present.
func (p *Perception) CursorOnSkip() bool {
	for _, obj := range p.world.AllObjects() {
		label := p.world.SpriteLabel(obj.SpriteID)
		if label == "vote skip cursor" {
			return true
		}
	}
	return false
}

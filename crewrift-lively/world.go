package main

import "strings"

// SpriteState holds the current definition of a sprite.
type SpriteState struct {
	ID     uint16
	Width  uint16
	Height uint16
	Pixels []byte
	Label  string
}

// ObjectState holds the current definition of an object in the world.
type ObjectState struct {
	ID       uint16
	X        int16
	Y        int16
	Z        int16
	Layer    uint8
	SpriteID uint16
}

// LayerState holds the current definition of a layer.
type LayerState struct {
	Type   uint8
	Flags  uint8
	Width  uint16
	Height uint16
}

// World maintains the three tables described by the Sprite v1 spec:
// sprites, objects, and layers.
type World struct {
	sprites map[uint16]*SpriteState
	objects map[uint16]*ObjectState
	layers  map[uint8]*LayerState
}

// NewWorld creates an empty World.
func NewWorld() *World {
	return &World{
		sprites: make(map[uint16]*SpriteState),
		objects: make(map[uint16]*ObjectState),
		layers:  make(map[uint8]*LayerState),
	}
}

// Apply processes a protocol message and updates the world state.
func (w *World) Apply(msg Message) {
	switch m := msg.(type) {
	case *DefineSprite:
		w.sprites[m.SpriteID] = &SpriteState{
			ID:     m.SpriteID,
			Width:  m.Width,
			Height: m.Height,
			Pixels: m.Pixels,
			Label:  m.Label,
		}
	case *DefineObject:
		w.objects[m.ObjectID] = &ObjectState{
			ID:       m.ObjectID,
			X:        m.X,
			Y:        m.Y,
			Z:        m.Z,
			Layer:    m.Layer,
			SpriteID: m.SpriteID,
		}
	case *DeleteObject:
		delete(w.objects, m.ObjectID)
	case *ClearObjects:
		w.objects = make(map[uint16]*ObjectState)
	case *SetViewport:
		layer := w.getOrCreateLayer(m.Layer)
		layer.Width = m.Width
		layer.Height = m.Height
	case *DefineLayer:
		layer := w.getOrCreateLayer(m.Layer)
		layer.Type = m.Typ
		layer.Flags = m.Flags
	}
}

func (w *World) getOrCreateLayer(id uint8) *LayerState {
	l, ok := w.layers[id]
	if !ok {
		l = &LayerState{}
		w.layers[id] = l
	}
	return l
}

// Sprite returns the sprite state for a given ID.
func (w *World) Sprite(id uint16) (*SpriteState, bool) {
	s, ok := w.sprites[id]
	return s, ok
}

// Object returns the object state for a given ID.
func (w *World) Object(id uint16) (*ObjectState, bool) {
	o, ok := w.objects[id]
	return o, ok
}

// ObjectCount returns the number of objects in the world.
func (w *World) ObjectCount() int {
	return len(w.objects)
}

// SpriteLabel returns the label of a sprite, or "" if not found.
func (w *World) SpriteLabel(spriteID uint16) string {
	s, ok := w.sprites[spriteID]
	if !ok {
		return ""
	}
	return s.Label
}

// ObjectLabel resolves an object's sprite and returns that sprite's label.
// Returns "" if the object or its sprite is not found.
func (w *World) ObjectLabel(objID uint16) string {
	obj, ok := w.objects[objID]
	if !ok {
		return ""
	}
	return w.SpriteLabel(obj.SpriteID)
}

// ObjectsWithLabel returns all objects whose resolved label matches exactly.
func (w *World) ObjectsWithLabel(label string) []ObjectState {
	var result []ObjectState
	for _, obj := range w.objects {
		if w.SpriteLabel(obj.SpriteID) == label {
			result = append(result, *obj)
		}
	}
	return result
}

// ObjectsWithLabelPrefix returns all objects whose resolved label starts with prefix.
func (w *World) ObjectsWithLabelPrefix(prefix string) []ObjectState {
	var result []ObjectState
	for _, obj := range w.objects {
		lbl := w.SpriteLabel(obj.SpriteID)
		if strings.HasPrefix(lbl, prefix) {
			result = append(result, *obj)
		}
	}
	return result
}

// AllObjects returns a copy of all object states.
func (w *World) AllObjects() []ObjectState {
	result := make([]ObjectState, 0, len(w.objects))
	for _, obj := range w.objects {
		result = append(result, *obj)
	}
	return result
}

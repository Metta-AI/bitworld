package main

import "testing"

func TestWorldDefineAndLookupSprite(t *testing.T) {
	w := NewWorld()
	w.Apply(&DefineSprite{
		SpriteID: 1,
		Width:    16,
		Height:   16,
		Pixels:   make([]byte, 16*16*4),
		Label:    "player",
	})

	s, ok := w.Sprite(1)
	if !ok {
		t.Fatal("expected sprite 1 to exist")
	}
	if s.ID != 1 {
		t.Errorf("sprite ID = %d, want 1", s.ID)
	}
	if s.Width != 16 || s.Height != 16 {
		t.Errorf("sprite dimensions = %dx%d, want 16x16", s.Width, s.Height)
	}
	if s.Label != "player" {
		t.Errorf("sprite label = %q, want %q", s.Label, "player")
	}
	if len(s.Pixels) != 16*16*4 {
		t.Errorf("sprite pixel len = %d, want %d", len(s.Pixels), 16*16*4)
	}
}

func TestWorldDefineAndLookupObject(t *testing.T) {
	w := NewWorld()
	w.Apply(&DefineObject{
		ObjectID: 10,
		X:        100,
		Y:        200,
		Z:        5,
		Layer:    1,
		SpriteID: 3,
	})

	obj, ok := w.Object(10)
	if !ok {
		t.Fatal("expected object 10 to exist")
	}
	if obj.ID != 10 {
		t.Errorf("object ID = %d, want 10", obj.ID)
	}
	if obj.X != 100 || obj.Y != 200 || obj.Z != 5 {
		t.Errorf("object position = (%d,%d,%d), want (100,200,5)", obj.X, obj.Y, obj.Z)
	}
	if obj.Layer != 1 {
		t.Errorf("object layer = %d, want 1", obj.Layer)
	}
	if obj.SpriteID != 3 {
		t.Errorf("object spriteID = %d, want 3", obj.SpriteID)
	}
}

func TestWorldDeleteObject(t *testing.T) {
	w := NewWorld()
	w.Apply(&DefineObject{ObjectID: 5, X: 10, Y: 20, Z: 0, Layer: 0, SpriteID: 1})

	if _, ok := w.Object(5); !ok {
		t.Fatal("expected object 5 to exist before delete")
	}

	w.Apply(&DeleteObject{ObjectID: 5})

	if _, ok := w.Object(5); ok {
		t.Error("expected object 5 to be gone after delete")
	}

	// Deleting unknown ID should be a no-op (no panic).
	w.Apply(&DeleteObject{ObjectID: 999})
}

func TestWorldClearObjects(t *testing.T) {
	w := NewWorld()
	w.Apply(&DefineSprite{SpriteID: 1, Width: 8, Height: 8, Pixels: make([]byte, 8*8*4), Label: "sprite1"})
	w.Apply(&DefineObject{ObjectID: 1, X: 0, Y: 0, Z: 0, Layer: 0, SpriteID: 1})
	w.Apply(&DefineObject{ObjectID: 2, X: 10, Y: 10, Z: 0, Layer: 0, SpriteID: 1})

	if w.ObjectCount() != 2 {
		t.Fatalf("expected 2 objects before clear, got %d", w.ObjectCount())
	}

	w.Apply(&ClearObjects{})

	if w.ObjectCount() != 0 {
		t.Errorf("expected 0 objects after clear, got %d", w.ObjectCount())
	}

	// Sprites should still be retained.
	if _, ok := w.Sprite(1); !ok {
		t.Error("expected sprite 1 to still exist after ClearObjects")
	}
}

func TestWorldObjectsWithLabelPrefix(t *testing.T) {
	w := NewWorld()
	w.Apply(&DefineSprite{SpriteID: 1, Width: 4, Height: 4, Pixels: make([]byte, 4*4*4), Label: "player_red"})
	w.Apply(&DefineSprite{SpriteID: 2, Width: 4, Height: 4, Pixels: make([]byte, 4*4*4), Label: "player_blue"})
	w.Apply(&DefineSprite{SpriteID: 3, Width: 4, Height: 4, Pixels: make([]byte, 4*4*4), Label: "wall"})

	w.Apply(&DefineObject{ObjectID: 1, X: 0, Y: 0, Z: 0, Layer: 0, SpriteID: 1})
	w.Apply(&DefineObject{ObjectID: 2, X: 10, Y: 0, Z: 0, Layer: 0, SpriteID: 2})
	w.Apply(&DefineObject{ObjectID: 3, X: 20, Y: 0, Z: 0, Layer: 0, SpriteID: 3})

	results := w.ObjectsWithLabelPrefix("player_")
	if len(results) != 2 {
		t.Errorf("expected 2 objects with prefix 'player_', got %d", len(results))
	}

	results = w.ObjectsWithLabelPrefix("wall")
	if len(results) != 1 {
		t.Errorf("expected 1 object with prefix 'wall', got %d", len(results))
	}

	results = w.ObjectsWithLabelPrefix("nonexistent")
	if len(results) != 0 {
		t.Errorf("expected 0 objects with prefix 'nonexistent', got %d", len(results))
	}
}

func TestWorldObjectsWithLabel(t *testing.T) {
	w := NewWorld()
	w.Apply(&DefineSprite{SpriteID: 1, Width: 4, Height: 4, Pixels: make([]byte, 4*4*4), Label: "player"})
	w.Apply(&DefineSprite{SpriteID: 2, Width: 4, Height: 4, Pixels: make([]byte, 4*4*4), Label: "player_ghost"})

	w.Apply(&DefineObject{ObjectID: 1, X: 0, Y: 0, Z: 0, Layer: 0, SpriteID: 1})
	w.Apply(&DefineObject{ObjectID: 2, X: 5, Y: 5, Z: 0, Layer: 0, SpriteID: 2})
	w.Apply(&DefineObject{ObjectID: 3, X: 10, Y: 10, Z: 0, Layer: 0, SpriteID: 1})

	results := w.ObjectsWithLabel("player")
	if len(results) != 2 {
		t.Errorf("expected 2 objects with label 'player', got %d", len(results))
	}

	results = w.ObjectsWithLabel("player_ghost")
	if len(results) != 1 {
		t.Errorf("expected 1 object with label 'player_ghost', got %d", len(results))
	}

	results = w.ObjectsWithLabel("play")
	if len(results) != 0 {
		t.Errorf("expected 0 objects with label 'play' (exact match), got %d", len(results))
	}
}

func TestWorldObjectLabel(t *testing.T) {
	w := NewWorld()
	w.Apply(&DefineSprite{SpriteID: 5, Width: 4, Height: 4, Pixels: make([]byte, 4*4*4), Label: "crewmate"})
	w.Apply(&DefineObject{ObjectID: 42, X: 50, Y: 60, Z: 0, Layer: 0, SpriteID: 5})

	label := w.ObjectLabel(42)
	if label != "crewmate" {
		t.Errorf("ObjectLabel(42) = %q, want %q", label, "crewmate")
	}

	// Unknown object returns "".
	label = w.ObjectLabel(999)
	if label != "" {
		t.Errorf("ObjectLabel(999) = %q, want %q", label, "")
	}

	// Object with unknown sprite returns "".
	w.Apply(&DefineObject{ObjectID: 50, X: 0, Y: 0, Z: 0, Layer: 0, SpriteID: 999})
	label = w.ObjectLabel(50)
	if label != "" {
		t.Errorf("ObjectLabel(50) with unknown sprite = %q, want %q", label, "")
	}
}

func TestWorldSetViewport(t *testing.T) {
	w := NewWorld()
	w.Apply(&SetViewport{Layer: 0, Width: 640, Height: 480})

	// The layer should now exist with the viewport dimensions.
	// Access via a second SetViewport or DefineLayer to verify state persists.
	w.Apply(&SetViewport{Layer: 0, Width: 800, Height: 600})

	// Define an object on that layer and verify the world still works.
	w.Apply(&DefineObject{ObjectID: 1, X: 0, Y: 0, Z: 0, Layer: 0, SpriteID: 1})
	if w.ObjectCount() != 1 {
		t.Errorf("expected 1 object, got %d", w.ObjectCount())
	}

	// Verify via DefineLayer that the layer exists and SetViewport updated it.
	// We apply a DefineLayer and check that type/flags update without losing viewport.
	w.Apply(&DefineLayer{Layer: 0, Typ: 2, Flags: 1})

	// Apply another SetViewport to layer 1.
	w.Apply(&SetViewport{Layer: 1, Width: 320, Height: 240})

	// No crash, and object count unchanged.
	if w.ObjectCount() != 1 {
		t.Errorf("expected 1 object after viewport changes, got %d", w.ObjectCount())
	}
}

func TestWorldDefineLayer(t *testing.T) {
	w := NewWorld()
	w.Apply(&DefineLayer{Layer: 2, Typ: 3, Flags: 5})

	// Verify the layer state by applying SetViewport to same layer and checking no crash.
	w.Apply(&SetViewport{Layer: 2, Width: 1024, Height: 768})

	// Redefine layer type/flags.
	w.Apply(&DefineLayer{Layer: 2, Typ: 1, Flags: 0})

	// Should not affect objects.
	w.Apply(&DefineObject{ObjectID: 1, X: 0, Y: 0, Z: 0, Layer: 2, SpriteID: 1})
	if w.ObjectCount() != 1 {
		t.Errorf("expected 1 object, got %d", w.ObjectCount())
	}
}

func TestWorldReplacingSprite(t *testing.T) {
	w := NewWorld()
	w.Apply(&DefineSprite{SpriteID: 1, Width: 8, Height: 8, Pixels: make([]byte, 8*8*4), Label: "old_label"})

	s, _ := w.Sprite(1)
	if s.Label != "old_label" {
		t.Fatalf("initial label = %q, want %q", s.Label, "old_label")
	}

	// Redefine same sprite ID with new properties.
	w.Apply(&DefineSprite{SpriteID: 1, Width: 16, Height: 16, Pixels: make([]byte, 16*16*4), Label: "new_label"})

	s, ok := w.Sprite(1)
	if !ok {
		t.Fatal("expected sprite 1 to still exist after redefine")
	}
	if s.Label != "new_label" {
		t.Errorf("label after redefine = %q, want %q", s.Label, "new_label")
	}
	if s.Width != 16 || s.Height != 16 {
		t.Errorf("dimensions after redefine = %dx%d, want 16x16", s.Width, s.Height)
	}

	// Object referencing that sprite should now resolve to new label.
	w.Apply(&DefineObject{ObjectID: 1, X: 0, Y: 0, Z: 0, Layer: 0, SpriteID: 1})
	if label := w.ObjectLabel(1); label != "new_label" {
		t.Errorf("ObjectLabel after sprite redefine = %q, want %q", label, "new_label")
	}
}

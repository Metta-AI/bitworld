package main

import (
	"encoding/binary"
	"testing"

	"github.com/golang/snappy"
)

// helper to build a DefineSprite message for testing.
func buildTestDefineSprite(spriteID, width, height uint16, pixels []byte, label string) []byte {
	compressed := snappy.Encode(nil, pixels)
	labelBytes := []byte(label)

	msg := make([]byte, 1+2+2+2+4+len(compressed)+2+len(labelBytes))
	msg[0] = TypeDefineSprite
	binary.LittleEndian.PutUint16(msg[1:3], spriteID)
	binary.LittleEndian.PutUint16(msg[3:5], width)
	binary.LittleEndian.PutUint16(msg[5:7], height)
	binary.LittleEndian.PutUint32(msg[7:11], uint32(len(compressed)))
	copy(msg[11:11+len(compressed)], compressed)
	off := 11 + len(compressed)
	binary.LittleEndian.PutUint16(msg[off:off+2], uint16(len(labelBytes)))
	copy(msg[off+2:], labelBytes)
	return msg
}

func TestParseDefineSprite(t *testing.T) {
	// 2x2 RGBA pixels = 16 bytes
	pixels := make([]byte, 16)
	for i := range pixels {
		pixels[i] = byte(i * 17) // some recognizable pattern
	}

	data := buildTestDefineSprite(7, 2, 2, pixels, "test")
	msgs, err := ParseMessages(data)
	if err != nil {
		t.Fatalf("ParseMessages error: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}

	sprite, ok := msgs[0].(*DefineSprite)
	if !ok {
		t.Fatalf("expected *DefineSprite, got %T", msgs[0])
	}
	if sprite.SpriteID != 7 {
		t.Errorf("SpriteID = %d, want 7", sprite.SpriteID)
	}
	if sprite.Width != 2 || sprite.Height != 2 {
		t.Errorf("dimensions = %dx%d, want 2x2", sprite.Width, sprite.Height)
	}
	if sprite.Label != "test" {
		t.Errorf("Label = %q, want %q", sprite.Label, "test")
	}
	if len(sprite.Pixels) != 16 {
		t.Errorf("Pixels length = %d, want 16", len(sprite.Pixels))
	}
	for i, b := range sprite.Pixels {
		if b != pixels[i] {
			t.Errorf("Pixels[%d] = %d, want %d", i, b, pixels[i])
		}
	}
}

func TestParseDefineObject(t *testing.T) {
	data := make([]byte, 12)
	data[0] = TypeDefineObject
	binary.LittleEndian.PutUint16(data[1:3], 3)    // object_id
	binary.LittleEndian.PutUint16(data[3:5], 10)   // x
	binary.LittleEndian.PutUint16(data[5:7], 20)   // y
	binary.LittleEndian.PutUint16(data[7:9], 0)    // z
	data[9] = 0                                     // layer
	binary.LittleEndian.PutUint16(data[10:12], 7)  // sprite_id

	msgs, err := ParseMessages(data)
	if err != nil {
		t.Fatalf("ParseMessages error: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}

	obj, ok := msgs[0].(*DefineObject)
	if !ok {
		t.Fatalf("expected *DefineObject, got %T", msgs[0])
	}
	if obj.ObjectID != 3 {
		t.Errorf("ObjectID = %d, want 3", obj.ObjectID)
	}
	if obj.X != 10 {
		t.Errorf("X = %d, want 10", obj.X)
	}
	if obj.Y != 20 {
		t.Errorf("Y = %d, want 20", obj.Y)
	}
	if obj.Z != 0 {
		t.Errorf("Z = %d, want 0", obj.Z)
	}
	if obj.Layer != 0 {
		t.Errorf("Layer = %d, want 0", obj.Layer)
	}
	if obj.SpriteID != 7 {
		t.Errorf("SpriteID = %d, want 7", obj.SpriteID)
	}
}

func TestParseDeleteObject(t *testing.T) {
	data := []byte{TypeDeleteObject, 0x05, 0x00}
	msgs, err := ParseMessages(data)
	if err != nil {
		t.Fatalf("ParseMessages error: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}

	del, ok := msgs[0].(*DeleteObject)
	if !ok {
		t.Fatalf("expected *DeleteObject, got %T", msgs[0])
	}
	if del.ObjectID != 5 {
		t.Errorf("ObjectID = %d, want 5", del.ObjectID)
	}
}

func TestParseClearObjects(t *testing.T) {
	data := []byte{TypeClearObjects}
	msgs, err := ParseMessages(data)
	if err != nil {
		t.Fatalf("ParseMessages error: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}

	_, ok := msgs[0].(*ClearObjects)
	if !ok {
		t.Fatalf("expected *ClearObjects, got %T", msgs[0])
	}
}

func TestParseSetViewport(t *testing.T) {
	data := []byte{TypeSetViewport, 0x01, 0x80, 0x02, 0xE0, 0x01}
	msgs, err := ParseMessages(data)
	if err != nil {
		t.Fatalf("ParseMessages error: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}

	vp, ok := msgs[0].(*SetViewport)
	if !ok {
		t.Fatalf("expected *SetViewport, got %T", msgs[0])
	}
	if vp.Layer != 1 {
		t.Errorf("Layer = %d, want 1", vp.Layer)
	}
	if vp.Width != 640 {
		t.Errorf("Width = %d, want 640", vp.Width)
	}
	if vp.Height != 480 {
		t.Errorf("Height = %d, want 480", vp.Height)
	}
}

func TestParseDefineLayer(t *testing.T) {
	data := []byte{TypeDefineLayer, 0x02, 0x01, 0x03}
	msgs, err := ParseMessages(data)
	if err != nil {
		t.Fatalf("ParseMessages error: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}

	layer, ok := msgs[0].(*DefineLayer)
	if !ok {
		t.Fatalf("expected *DefineLayer, got %T", msgs[0])
	}
	if layer.Layer != 2 {
		t.Errorf("Layer = %d, want 2", layer.Layer)
	}
	if layer.Typ != 1 {
		t.Errorf("Typ = %d, want 1", layer.Typ)
	}
	if layer.Flags != 3 {
		t.Errorf("Flags = %d, want 3", layer.Flags)
	}
}

func TestBuildPlayerInput(t *testing.T) {
	result := BuildPlayerInput(ButtonUp | ButtonA)
	expected := []byte{TypePlayerInput, ButtonUp | ButtonA}
	if len(result) != len(expected) {
		t.Fatalf("length = %d, want %d", len(result), len(expected))
	}
	for i := range expected {
		if result[i] != expected[i] {
			t.Errorf("byte[%d] = 0x%02x, want 0x%02x", i, result[i], expected[i])
		}
	}
}

func TestBuildInputText(t *testing.T) {
	result := BuildInputText("hello")
	// type(1) + length(2) + "hello"(5) = 8 bytes
	if len(result) != 8 {
		t.Fatalf("length = %d, want 8", len(result))
	}
	if result[0] != TypeInputText {
		t.Errorf("type byte = 0x%02x, want 0x%02x", result[0], TypeInputText)
	}
	textLen := binary.LittleEndian.Uint16(result[1:3])
	if textLen != 5 {
		t.Errorf("text length = %d, want 5", textLen)
	}
	if string(result[3:]) != "hello" {
		t.Errorf("text = %q, want %q", string(result[3:]), "hello")
	}
}

func TestParseMultipleMessages(t *testing.T) {
	// Concatenate: ClearObjects + DeleteObject(42) + DefineLayer(0,1,0)
	var data []byte
	data = append(data, TypeClearObjects)
	data = append(data, TypeDeleteObject, 0x2A, 0x00) // object 42
	data = append(data, TypeDefineLayer, 0x00, 0x01, 0x00)

	msgs, err := ParseMessages(data)
	if err != nil {
		t.Fatalf("ParseMessages error: %v", err)
	}
	if len(msgs) != 3 {
		t.Fatalf("expected 3 messages, got %d", len(msgs))
	}

	if _, ok := msgs[0].(*ClearObjects); !ok {
		t.Errorf("msg[0]: expected *ClearObjects, got %T", msgs[0])
	}

	del, ok := msgs[1].(*DeleteObject)
	if !ok {
		t.Errorf("msg[1]: expected *DeleteObject, got %T", msgs[1])
	} else if del.ObjectID != 42 {
		t.Errorf("msg[1]: ObjectID = %d, want 42", del.ObjectID)
	}

	layer, ok := msgs[2].(*DefineLayer)
	if !ok {
		t.Errorf("msg[2]: expected *DefineLayer, got %T", msgs[2])
	} else {
		if layer.Layer != 0 || layer.Typ != 1 || layer.Flags != 0 {
			t.Errorf("msg[2]: DefineLayer = {%d,%d,%d}, want {0,1,0}", layer.Layer, layer.Typ, layer.Flags)
		}
	}
}

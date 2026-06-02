package main

import (
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/golang/snappy"
)

// Button constants (bitmask).
const (
	ButtonUp     = 0x01
	ButtonDown   = 0x02
	ButtonLeft   = 0x04
	ButtonRight  = 0x08
	ButtonSelect = 0x10
	ButtonA      = 0x20
	ButtonB      = 0x40
)

// Message type bytes.
const (
	TypeDefineSprite = 0x01
	TypeDefineObject = 0x02
	TypeDeleteObject = 0x03
	TypeClearObjects = 0x04
	TypeSetViewport  = 0x05
	TypeDefineLayer  = 0x06

	TypeInputText   = 0x81
	TypePlayerInput = 0x84
)

// Message is the interface that all protocol messages implement.
type Message interface {
	Type() byte
}

// DefineSprite defines a sprite with pixel data.
type DefineSprite struct {
	SpriteID u16
	Width    uint16
	Height   uint16
	Pixels   []byte // Decompressed RGBA pixels
	Label    string
}

type u16 = uint16

func (m *DefineSprite) Type() byte { return TypeDefineSprite }

// DefineObject places an object in the world.
type DefineObject struct {
	ObjectID uint16
	X        int16
	Y        int16
	Z        int16
	Layer    uint8
	SpriteID uint16
}

func (m *DefineObject) Type() byte { return TypeDefineObject }

// DeleteObject removes an object.
type DeleteObject struct {
	ObjectID uint16
}

func (m *DeleteObject) Type() byte { return TypeDeleteObject }

// ClearObjects removes all objects.
type ClearObjects struct{}

func (m *ClearObjects) Type() byte { return TypeClearObjects }

// SetViewport sets the viewport dimensions for a layer.
type SetViewport struct {
	Layer  uint8
	Width  uint16
	Height uint16
}

func (m *SetViewport) Type() byte { return TypeSetViewport }

// DefineLayer defines a layer's properties.
type DefineLayer struct {
	Layer uint8
	Typ   uint8
	Flags uint8
}

func (m *DefineLayer) Type() byte { return TypeDefineLayer }

// InputText is a client→server text input message.
type InputText struct {
	Text string
}

func (m *InputText) Type() byte { return TypeInputText }

// PlayerInput is a client→server button input message.
type PlayerInput struct {
	Buttons uint8
}

func (m *PlayerInput) Type() byte { return TypePlayerInput }

// ParseMessages parses a full WebSocket binary message which may contain
// multiple concatenated Sprite v1 protocol messages.
func ParseMessages(data []byte) ([]Message, error) {
	var msgs []Message
	offset := 0

	for offset < len(data) {
		if offset >= len(data) {
			break
		}
		typeByte := data[offset]
		offset++

		switch typeByte {
		case TypeDefineSprite:
			msg, n, err := parseDefineSprite(data[offset:])
			if err != nil {
				return msgs, fmt.Errorf("DefineSprite at offset %d: %w", offset-1, err)
			}
			msgs = append(msgs, msg)
			offset += n

		case TypeDefineObject:
			msg, n, err := parseDefineObject(data[offset:])
			if err != nil {
				return msgs, fmt.Errorf("DefineObject at offset %d: %w", offset-1, err)
			}
			msgs = append(msgs, msg)
			offset += n

		case TypeDeleteObject:
			msg, n, err := parseDeleteObject(data[offset:])
			if err != nil {
				return msgs, fmt.Errorf("DeleteObject at offset %d: %w", offset-1, err)
			}
			msgs = append(msgs, msg)
			offset += n

		case TypeClearObjects:
			msgs = append(msgs, &ClearObjects{})

		case TypeSetViewport:
			msg, n, err := parseSetViewport(data[offset:])
			if err != nil {
				return msgs, fmt.Errorf("SetViewport at offset %d: %w", offset-1, err)
			}
			msgs = append(msgs, msg)
			offset += n

		case TypeDefineLayer:
			msg, n, err := parseDefineLayer(data[offset:])
			if err != nil {
				return msgs, fmt.Errorf("DefineLayer at offset %d: %w", offset-1, err)
			}
			msgs = append(msgs, msg)
			offset += n

		default:
			return msgs, fmt.Errorf("unknown message type 0x%02x at offset %d", typeByte, offset-1)
		}
	}

	return msgs, nil
}

func parseDefineSprite(data []byte) (*DefineSprite, int, error) {
	// sprite_id(u16) + width(u16) + height(u16) + compressed_len(u32) = 10 bytes minimum header
	if len(data) < 10 {
		return nil, 0, errors.New("insufficient data for DefineSprite header")
	}

	spriteID := binary.LittleEndian.Uint16(data[0:2])
	width := binary.LittleEndian.Uint16(data[2:4])
	height := binary.LittleEndian.Uint16(data[4:6])
	compressedLen := binary.LittleEndian.Uint32(data[6:10])

	offset := 10
	if len(data) < offset+int(compressedLen) {
		return nil, 0, errors.New("insufficient data for compressed pixels")
	}

	compressedPixels := data[offset : offset+int(compressedLen)]
	offset += int(compressedLen)

	// label_len(u16) + label(bytes)
	if len(data) < offset+2 {
		return nil, 0, errors.New("insufficient data for label length")
	}
	labelLen := binary.LittleEndian.Uint16(data[offset : offset+2])
	offset += 2

	if len(data) < offset+int(labelLen) {
		return nil, 0, errors.New("insufficient data for label")
	}
	label := string(data[offset : offset+int(labelLen)])
	offset += int(labelLen)

	// Decompress pixels
	pixels, err := snappy.Decode(nil, compressedPixels)
	if err != nil {
		return nil, 0, fmt.Errorf("snappy decode: %w", err)
	}

	expectedSize := int(width) * int(height) * 4
	if len(pixels) != expectedSize {
		return nil, 0, fmt.Errorf("decompressed pixel size %d != expected %d", len(pixels), expectedSize)
	}

	return &DefineSprite{
		SpriteID: spriteID,
		Width:    width,
		Height:   height,
		Pixels:   pixels,
		Label:    label,
	}, offset, nil
}

func parseDefineObject(data []byte) (*DefineObject, int, error) {
	// object_id(u16) + x(i16) + y(i16) + z(i16) + layer(u8) + sprite_id(u16) = 11 bytes
	if len(data) < 11 {
		return nil, 0, errors.New("insufficient data for DefineObject")
	}

	objectID := binary.LittleEndian.Uint16(data[0:2])
	x := int16(binary.LittleEndian.Uint16(data[2:4]))
	y := int16(binary.LittleEndian.Uint16(data[4:6]))
	z := int16(binary.LittleEndian.Uint16(data[6:8]))
	layer := data[8]
	spriteID := binary.LittleEndian.Uint16(data[9:11])

	return &DefineObject{
		ObjectID: objectID,
		X:        x,
		Y:        y,
		Z:        z,
		Layer:    layer,
		SpriteID: spriteID,
	}, 11, nil
}

func parseDeleteObject(data []byte) (*DeleteObject, int, error) {
	if len(data) < 2 {
		return nil, 0, errors.New("insufficient data for DeleteObject")
	}

	objectID := binary.LittleEndian.Uint16(data[0:2])
	return &DeleteObject{ObjectID: objectID}, 2, nil
}

func parseSetViewport(data []byte) (*SetViewport, int, error) {
	// layer(u8) + width(u16) + height(u16) = 5 bytes
	if len(data) < 5 {
		return nil, 0, errors.New("insufficient data for SetViewport")
	}

	layer := data[0]
	width := binary.LittleEndian.Uint16(data[1:3])
	height := binary.LittleEndian.Uint16(data[3:5])

	return &SetViewport{
		Layer:  layer,
		Width:  width,
		Height: height,
	}, 5, nil
}

func parseDefineLayer(data []byte) (*DefineLayer, int, error) {
	// layer(u8) + type(u8) + flags(u8) = 3 bytes
	if len(data) < 3 {
		return nil, 0, errors.New("insufficient data for DefineLayer")
	}

	return &DefineLayer{
		Layer: data[0],
		Typ:   data[1],
		Flags: data[2],
	}, 3, nil
}

// BuildPlayerInput constructs a client→server PlayerInput message.
func BuildPlayerInput(buttons uint8) []byte {
	return []byte{TypePlayerInput, buttons}
}

// BuildInputText constructs a client→server InputText message.
func BuildInputText(text string) []byte {
	textBytes := []byte(text)
	msg := make([]byte, 1+2+len(textBytes))
	msg[0] = TypeInputText
	binary.LittleEndian.PutUint16(msg[1:3], uint16(len(textBytes)))
	copy(msg[3:], textBytes)
	return msg
}

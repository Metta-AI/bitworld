package main

import "fmt"

const (
	ScreenWidth      = 128
	ScreenHeight     = 128
	ProtocolBytes    = ScreenWidth * ScreenHeight / 2
	InputPacketBytes = 2

	PacketInput uint8 = 0x00
	PacketChat  uint8 = 0x01

	ButtonUp     uint8 = 1 << 0
	ButtonDown   uint8 = 1 << 1
	ButtonLeft   uint8 = 1 << 2
	ButtonRight  uint8 = 1 << 3
	ButtonSelect uint8 = 1 << 4
	ButtonA      uint8 = 1 << 5
	ButtonB      uint8 = 1 << 6
)

type Input struct {
	Up, Down, Left, Right, Select, A, B bool
}

func (i Input) Mask() uint8 {
	var m uint8
	if i.Up {
		m |= ButtonUp
	}
	if i.Down {
		m |= ButtonDown
	}
	if i.Left {
		m |= ButtonLeft
	}
	if i.Right {
		m |= ButtonRight
	}
	if i.Select {
		m |= ButtonSelect
	}
	if i.A {
		m |= ButtonA
	}
	if i.B {
		m |= ButtonB
	}
	return m
}

func InputFromMask(m uint8) Input {
	return Input{
		Up:     m&ButtonUp != 0,
		Down:   m&ButtonDown != 0,
		Left:   m&ButtonLeft != 0,
		Right:  m&ButtonRight != 0,
		Select: m&ButtonSelect != 0,
		A:      m&ButtonA != 0,
		B:      m&ButtonB != 0,
	}
}

func BuildInputPacket(mask uint8) []byte {
	return []byte{PacketInput, mask}
}

func BuildChatPacket(text string) []byte {
	out := make([]byte, 1+len(text))
	out[0] = PacketChat
	copy(out[1:], text)
	return out
}

func ParseInputPacket(blob []byte) (uint8, bool) {
	if len(blob) != InputPacketBytes || blob[0] != PacketInput {
		return 0, false
	}
	return blob[1], true
}

func ParseChatPacket(blob []byte) (string, bool) {
	if len(blob) < 1 || blob[0] != PacketChat {
		return "", false
	}
	out := make([]byte, 0, len(blob)-1)
	for _, b := range blob[1:] {
		if b >= 0x20 && b < 0x7F {
			out = append(out, b)
		}
	}
	return string(out), true
}

func UnpackFrame(packed []byte, dst []uint8) error {
	if len(packed) != ProtocolBytes {
		return fmt.Errorf("packed frame: got %d bytes, want %d", len(packed), ProtocolBytes)
	}
	if len(dst) != ScreenWidth*ScreenHeight {
		return fmt.Errorf("dst buffer: got %d, want %d", len(dst), ScreenWidth*ScreenHeight)
	}
	for i, b := range packed {
		dst[2*i] = b & 0x0F
		dst[2*i+1] = b >> 4
	}
	return nil
}

package main

import (
	"bytes"
	"testing"
)

func TestButtonBitConstants(t *testing.T) {
	cases := []struct {
		name string
		got  uint8
		want uint8
	}{
		{"Up", ButtonUp, 1 << 0},
		{"Down", ButtonDown, 1 << 1},
		{"Left", ButtonLeft, 1 << 2},
		{"Right", ButtonRight, 1 << 3},
		{"Select", ButtonSelect, 1 << 4},
		{"A", ButtonA, 1 << 5},
		{"B", ButtonB, 1 << 6},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s = %#x, want %#x", c.name, c.got, c.want)
		}
	}
}

func TestInputMaskRoundTrip(t *testing.T) {
	// Reserved bit 7 must be sent as 0; only 0x00..0x7F is meaningful.
	for m := 0; m < 128; m++ {
		got := InputFromMask(uint8(m)).Mask()
		if got != uint8(m) {
			t.Errorf("mask %#x round-trip yielded %#x", m, got)
		}
	}
}

func TestInputFieldsMatchBits(t *testing.T) {
	full := Input{Up: true, Down: true, Left: true, Right: true, Select: true, A: true, B: true}
	if got := full.Mask(); got != 0x7F {
		t.Errorf("all-bits mask = %#x, want 0x7F", got)
	}
	zero := Input{}
	if got := zero.Mask(); got != 0 {
		t.Errorf("zero mask = %#x, want 0", got)
	}
}

func TestBuildInputPacket(t *testing.T) {
	pkt := BuildInputPacket(0x42)
	want := []byte{0x00, 0x42}
	if !bytes.Equal(pkt, want) {
		t.Fatalf("BuildInputPacket(0x42) = %v, want %v", pkt, want)
	}
	if len(pkt) != InputPacketBytes {
		t.Fatalf("len = %d, want %d", len(pkt), InputPacketBytes)
	}
}

func TestParseInputPacketRoundTrip(t *testing.T) {
	for _, m := range []uint8{0, 1, 0x42, 0x7F} {
		got, ok := ParseInputPacket(BuildInputPacket(m))
		if !ok || got != m {
			t.Errorf("round-trip %#x: got %#x ok=%v", m, got, ok)
		}
	}
}

func TestParseInputPacketRejects(t *testing.T) {
	if _, ok := ParseInputPacket([]byte{0x01, 0x00}); ok {
		t.Error("wrong leading byte should be rejected")
	}
	if _, ok := ParseInputPacket([]byte{0x00}); ok {
		t.Error("short packet should be rejected")
	}
	if _, ok := ParseInputPacket([]byte{0x00, 0x00, 0x00}); ok {
		t.Error("long packet should be rejected")
	}
	if _, ok := ParseInputPacket(nil); ok {
		t.Error("nil should be rejected")
	}
}

func TestBuildChatPacket(t *testing.T) {
	pkt := BuildChatPacket("hi")
	if pkt[0] != PacketChat {
		t.Fatalf("leading byte = %#x, want %#x", pkt[0], PacketChat)
	}
	if !bytes.Equal(pkt[1:], []byte("hi")) {
		t.Fatalf("body = %v, want %v", pkt[1:], []byte("hi"))
	}
}

func TestParseChatPacketFiltersNonPrintable(t *testing.T) {
	raw := []byte{PacketChat, 'h', '\n', 'i', 0x01, '!', 0x7F}
	got, ok := ParseChatPacket(raw)
	if !ok {
		t.Fatal("expected ok")
	}
	if got != "hi!" {
		t.Errorf("got %q, want %q", got, "hi!")
	}
}

func TestParseChatPacketRejects(t *testing.T) {
	if _, ok := ParseChatPacket([]byte{}); ok {
		t.Error("empty should be rejected")
	}
	if _, ok := ParseChatPacket([]byte{0x00, 'h'}); ok {
		t.Error("wrong leading byte should be rejected")
	}
	if _, ok := ParseChatPacket(nil); ok {
		t.Error("nil should be rejected")
	}
}

func TestUnpackFrameNibbleOrder(t *testing.T) {
	// Per bitscreen_protocol.md: bits 0..3 hold the LEFT pixel, bits 4..7 the RIGHT.
	packed := make([]byte, ProtocolBytes)
	packed[0] = 0x21 // left = 1, right = 2
	packed[ProtocolBytes-1] = 0xF0
	dst := make([]uint8, ScreenWidth*ScreenHeight)
	if err := UnpackFrame(packed, dst); err != nil {
		t.Fatal(err)
	}
	if dst[0] != 1 || dst[1] != 2 {
		t.Errorf("dst[0..1] = %d, %d; want 1, 2", dst[0], dst[1])
	}
	if dst[len(dst)-2] != 0 || dst[len(dst)-1] != 0xF {
		t.Errorf("dst[end-1..end] = %d, %d; want 0, 15", dst[len(dst)-2], dst[len(dst)-1])
	}
	for i := 2; i < len(dst)-2; i++ {
		if dst[i] != 0 {
			t.Fatalf("dst[%d] = %d, want 0", i, dst[i])
		}
	}
}

func TestUnpackFrameWrongSize(t *testing.T) {
	if err := UnpackFrame(make([]byte, 100), make([]uint8, ScreenWidth*ScreenHeight)); err == nil {
		t.Error("expected error for short packed input")
	}
	if err := UnpackFrame(make([]byte, ProtocolBytes), make([]uint8, 100)); err == nil {
		t.Error("expected error for wrong dst size")
	}
}

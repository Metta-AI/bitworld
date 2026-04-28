package main

import (
	"fmt"
	"os"
)

// WalkMask is the per-pixel passability grid the sim uses for player
// movement (sim.nim:701-704; CollisionW=H=1 means no footprint inflation).
// Stored bit-packed: bit i lives at byte i>>3, position i&7, where
// i = y*MapWidth + x. Pixels[i/8] >> (i%8) & 1 == 1 means walkable.
type WalkMask struct {
	Bits []uint8
}

// LoadWalkMask reads a bit-packed walkMask written by capture_fixtures.nim
// (testdata/walks.bin).
func LoadWalkMask(path string) (*WalkMask, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("load walks: %w", err)
	}
	want := (MapWidth*MapHeight + 7) / 8
	if len(raw) != want {
		return nil, fmt.Errorf("walks size: got %d, want %d", len(raw), want)
	}
	return &WalkMask{Bits: raw}, nil
}

// Walkable reports whether the pixel (x, y) is walkable. Out-of-bounds
// queries return false.
func (w *WalkMask) Walkable(x, y int) bool {
	if x < 0 || y < 0 || x >= MapWidth || y >= MapHeight {
		return false
	}
	i := y*MapWidth + x
	return w.Bits[i>>3]&(1<<(i&7)) != 0
}

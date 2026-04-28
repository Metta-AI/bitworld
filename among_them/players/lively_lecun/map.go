package main

import (
	"fmt"
	"os"
)

const (
	MapWidth  = 952
	MapHeight = 534
)

// Map is the rendered skeld map's palette-indexed pixel grid, the same
// data the server uses to draw playing-phase frames (sim.nim:2253). Pixels
// are stored row-major as uint8 palette indices in [0..15].
type Map struct {
	Pixels []uint8
}

// LoadMap reads a map asset previously emitted by capture_fixtures.nim
// (testdata/skeld_map.bin).
func LoadMap(path string) (*Map, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("load map: %w", err)
	}
	if len(raw) != MapWidth*MapHeight {
		return nil, fmt.Errorf("map size: got %d, want %d", len(raw), MapWidth*MapHeight)
	}
	return &Map{Pixels: raw}, nil
}

// At returns the map pixel at (x, y), or 0 for out-of-bounds queries.
func (m *Map) At(x, y int) uint8 {
	if x < 0 || y < 0 || x >= MapWidth || y >= MapHeight {
		return 0
	}
	return m.Pixels[y*MapWidth+x]
}

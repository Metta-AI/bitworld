package main

import "testing"

func TestWalkMap4x4(t *testing.T) {
	// 4x4 image: set specific pixels as walkable (alpha > 0)
	width, height := 4, 4
	rgba := make([]byte, width*height*4)

	// Make (0,0), (1,1), (2,2), (3,3) walkable (diagonal)
	setAlpha := func(x, y int, a byte) {
		idx := (y*width + x) * 4
		rgba[idx+3] = a
	}
	setAlpha(0, 0, 255)
	setAlpha(1, 1, 128)
	setAlpha(2, 2, 1)
	setAlpha(3, 3, 200)

	wm := ExtractWalkMap(rgba, width, height)
	if wm == nil {
		t.Fatal("ExtractWalkMap returned nil for valid input")
	}

	// Diagonal cells should be walkable
	for i := 0; i < 4; i++ {
		if !wm.Walkable(i, i) {
			t.Errorf("expected (%d,%d) to be walkable", i, i)
		}
	}

	// Off-diagonal cells should not be walkable
	if wm.Walkable(1, 0) {
		t.Error("expected (1,0) to be unwalkable")
	}
	if wm.Walkable(0, 1) {
		t.Error("expected (0,1) to be unwalkable")
	}
	if wm.Walkable(3, 0) {
		t.Error("expected (3,0) to be unwalkable")
	}
}

func TestWalkMapOutOfBounds(t *testing.T) {
	width, height := 2, 2
	rgba := make([]byte, width*height*4)
	// Make all walkable
	for i := 0; i < len(rgba); i += 4 {
		rgba[i+3] = 255
	}
	wm := ExtractWalkMap(rgba, width, height)
	if wm == nil {
		t.Fatal("ExtractWalkMap returned nil")
	}

	cases := [][2]int{
		{-1, 0}, {0, -1}, {2, 0}, {0, 2}, {-1, -1}, {100, 100},
	}
	for _, c := range cases {
		if wm.Walkable(c[0], c[1]) {
			t.Errorf("expected (%d,%d) out-of-bounds to return false", c[0], c[1])
		}
	}
}

func TestWalkMapWrongSize(t *testing.T) {
	// Wrong size buffer should return nil
	rgba := make([]byte, 10) // not width*height*4
	wm := ExtractWalkMap(rgba, 4, 4)
	if wm != nil {
		t.Error("expected nil for wrong-size input")
	}

	// Nil input
	wm = ExtractWalkMap(nil, 4, 4)
	if wm != nil {
		t.Error("expected nil for nil input")
	}
}

func TestWalkMapAllWalkable(t *testing.T) {
	width, height := 8, 8
	rgba := make([]byte, width*height*4)
	for i := 0; i < len(rgba); i += 4 {
		rgba[i+3] = 255
	}
	wm := ExtractWalkMap(rgba, width, height)
	if wm == nil {
		t.Fatal("ExtractWalkMap returned nil")
	}
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			if !wm.Walkable(x, y) {
				t.Errorf("expected (%d,%d) to be walkable in all-walkable map", x, y)
			}
		}
	}
}

func TestWalkMapAllUnwalkable(t *testing.T) {
	width, height := 8, 8
	rgba := make([]byte, width*height*4) // all zeros, alpha=0
	wm := ExtractWalkMap(rgba, width, height)
	if wm == nil {
		t.Fatal("ExtractWalkMap returned nil")
	}
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			if wm.Walkable(x, y) {
				t.Errorf("expected (%d,%d) to be unwalkable in all-unwalkable map", x, y)
			}
		}
	}
}

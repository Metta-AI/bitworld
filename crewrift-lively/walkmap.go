package main

// WalkMap is a grid of walkable/non-walkable cells.
type WalkMap struct {
	Width, Height int
	bits          []byte // bit-packed: bit i = pixel i walkable
}

// ExtractWalkMap reads decompressed RGBA pixel buffer and produces a WalkMap.
// Alpha > 0 means walkable.
func ExtractWalkMap(rgba []byte, width, height int) *WalkMap {
	if len(rgba) != width*height*4 {
		return nil
	}
	n := width * height
	bits := make([]byte, (n+7)/8)
	for i := 0; i < n; i++ {
		if rgba[i*4+3] > 0 {
			bits[i>>3] |= 1 << (i & 7)
		}
	}
	return &WalkMap{
		Width:  width,
		Height: height,
		bits:   bits,
	}
}

// Walkable reports whether (x,y) is passable. Out-of-bounds returns false.
func (wm *WalkMap) Walkable(x, y int) bool {
	if x < 0 || y < 0 || x >= wm.Width || y >= wm.Height {
		return false
	}
	i := y*wm.Width + x
	return wm.bits[i>>3]&(1<<(i&7)) != 0
}

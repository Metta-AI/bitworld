package main

// Wanderer provides idle movement behavior by cycling through directions.
type Wanderer struct{ step uint8 }

// Next returns the next button mask, rotating through Up, Right, Down, Left.
func (w *Wanderer) Next() uint8 {
	dirs := [4]uint8{ButtonUp, ButtonRight, ButtonDown, ButtonLeft}
	mask := dirs[w.step%4]
	w.step++
	return mask
}

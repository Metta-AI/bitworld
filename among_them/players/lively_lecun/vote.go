package main

// SkipController drives the voting screen toward casting a SKIP vote.
//
// Voting input from sim.nim:2569-2596 is edge-triggered: each fresh press
// of Right (or Down) advances the cursor by one alive slot, and a fresh A
// while the cursor is on SKIP casts a skip vote. To register fresh edges
// the client must release between presses, so this controller alternates
// "press" and "release" frames. The zero value is the initial state — the
// first call always returns 0 to release any input held over from the
// previous phase.
type SkipController struct {
	primed  bool // false on first call so we always release first
	pressed bool // true if last call returned a non-zero mask
}

// Next returns the next button mask given the current voting frame.
// pixels must be ScreenWidth*ScreenHeight long.
func (sc *SkipController) Next(pixels []uint8) uint8 {
	if !sc.primed {
		sc.primed = true
		sc.pressed = false
		return 0
	}
	if sc.pressed {
		sc.pressed = false
		return 0
	}
	var mask uint8
	if cursorOnSkip(pixels) {
		mask = ButtonA
	} else {
		mask = ButtonRight
	}
	sc.pressed = true
	return mask
}

// cursorOnSkip detects the palette-2 highlight rectangle around the SKIP
// cell. The cleanest signal is the top edge of that rectangle, at
// y = skipY - 1, x in [skipX .. skipX+skipW). The "SKIP" text glyphs
// themselves are painted at y in [skipY .. skipY+6], so the row directly
// above is otherwise empty and only carries palette-2 when the cursor is
// on SKIP.
//
// For 1..8 player layouts (rows = 1) skipY = 20, so the highlight top is
// at y = 19. For 9..16 player layouts (rows = 2) skipY = 37, so it's at
// y = 36. We check both.
func cursorOnSkip(pixels []uint8) bool {
	if len(pixels) != ScreenWidth*ScreenHeight {
		return false
	}
	const (
		skipX     = 50
		skipW     = 28
		threshold = skipW / 2 // half the row painted = clear positive signal
	)
	return countRow(pixels, 19, skipX, skipW, 2) >= threshold ||
		countRow(pixels, 36, skipX, skipW, 2) >= threshold
}

func countRow(pixels []uint8, y, x0, w int, color uint8) int {
	if y < 0 || y >= ScreenHeight {
		return 0
	}
	var c int
	row := pixels[y*ScreenWidth : (y+1)*ScreenWidth]
	for x := x0; x < x0+w && x < ScreenWidth; x++ {
		if row[x] == color {
			c++
		}
	}
	return c
}

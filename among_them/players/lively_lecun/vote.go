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

// --- M5: suspect voting ---------------------------------------------------
//
// VoteController casts a vote for a specific target player color when a
// suspect is known, falling back to SKIP otherwise. It layers over the
// same edge-triggered press/release cadence SkipController uses: each
// "press" frame moves the cursor one step, each "release" frame returns 0.
//
// Layout facts (ported from sim.nim:1820-1905 buildVoteFrame):
//
//   - cellW=16, cellH=17, cols=min(n,8), rows=ceil(n/cols), startY=2,
//     startX=(ScreenWidth-cols*cellW)/2. Cell i sits at
//     (cx=startX+(i%cols)*cellW, cy=startY+(i/cols)*cellH). Player sprite
//     is blitted at (cx+2, cy+1) with palette-3 tint swapped for the
//     player's color (sim.nim:1845-1850).
//   - Cursor highlight is a 1-pixel palette-2 rectangle around the current
//     cell; top edge at y=cy-1, bottom at y=cy+cellH-2, sides at x=cx and
//     x=cx+cellW-1. SKIP slot is index n, drawn as a separate 28-wide box
//     below the cell grid (detected by cursorOnSkip).
//   - Move cursor with fresh presses of Right / Left (sim.nim's moveCursor
//     wraps with delta=+1/-1 skipping dead slots). We'll use Right only
//     and accept up to n+1 presses in the worst case — still trivial
//     compared to the voting window.

const (
	voteCellW    = 16
	voteCellH    = 17
	voteCols     = 8  // max cols; actual is min(n, 8)
	voteStartY   = 2  // cy for row 0
	voteMaxSlots = 16 // sim.nim caps at 16 players
)

// VoteController navigates to a chosen palette color (suspect) and casts
// a vote. If the suspect isn't visible in the voting panel, it falls back
// to SKIP the same way SkipController would.
//
// Usage: construct with `VoteController{Target: color}` (or leave Target
// as 255 to go straight to SKIP). Call Next(pixels) once per voting
// frame; caller must reset the controller (assign a fresh zero value)
// each time the phase enters PhaseVoting, matching SkipController's
// contract.
type VoteController struct {
	Target    uint8 // palette color to vote for; 255 = skip
	primed    bool
	pressed   bool
	giveUp    bool // true once we've exhausted navigation budget; revert to SKIP
	moves     int  // total press frames issued (for the budget)
	maxMoves  int  // cap on how many Right-presses we'll try before giving up
	initMoves bool
}

const voteMaxMoves = voteMaxSlots + 2 // allow one full wraparound + SKIP trip

// Next returns the next button mask for the current voting frame. pixels
// must be ScreenWidth*ScreenHeight long. The caller should clear the
// controller on each new voting phase.
func (vc *VoteController) Next(pixels []uint8) uint8 {
	if !vc.initMoves {
		vc.maxMoves = voteMaxMoves
		vc.initMoves = true
	}
	if !vc.primed {
		vc.primed = true
		vc.pressed = false
		return 0
	}
	if vc.pressed {
		vc.pressed = false
		return 0
	}

	// Give-up path: behave exactly like SkipController.
	if vc.giveUp || vc.Target > 15 {
		return vc.stepTowardSkip(pixels)
	}

	layout := parseVoteLayout(pixels)
	if layout == nil {
		// Can't read the layout; fall back to skip-advance.
		return vc.stepTowardSkip(pixels)
	}

	targetSlot := layout.findColor(pixels, vc.Target)
	if targetSlot < 0 {
		// Suspect not on the voting panel (e.g. already ejected, or we
		// misread the color). Vote skip rather than vote blind.
		vc.giveUp = true
		return vc.stepTowardSkip(pixels)
	}
	cursorSlot := layout.findCursor(pixels)
	if cursorSlot < 0 {
		// Cursor indeterminate — advance once and hope the next frame
		// resolves. If we keep whiffing, the moves budget trips giveUp.
		return vc.advance(ButtonRight)
	}
	if cursorSlot == targetSlot {
		return vc.advance(ButtonA)
	}
	return vc.advance(ButtonRight)
}

func (vc *VoteController) stepTowardSkip(pixels []uint8) uint8 {
	if cursorOnSkip(pixels) {
		return vc.advance(ButtonA)
	}
	return vc.advance(ButtonRight)
}

func (vc *VoteController) advance(mask uint8) uint8 {
	vc.moves++
	if vc.moves > vc.maxMoves {
		vc.giveUp = true
	}
	vc.pressed = mask != 0
	return mask
}

// voteLayout describes where each slot's cell sits on screen for the
// current voting frame. Filled by parseVoteLayout.
type voteLayout struct {
	n          int
	cols, rows int
	startX     int
	// slotCells[i] = (cx, cy) for slot i.
	slotCells [voteMaxSlots]voteCell
}

type voteCell struct {
	cx, cy int
	alive  bool // only alive slots are focusable (sim.nim:1667 moveCursor skips dead)
}

// parseVoteLayout counts cells by scanning for filled sprite bodies at
// each possible (cols, row) position. Returns nil when the frame
// doesn't look like a voting panel (e.g. the caller confused the phase).
//
// The cols probe is stricter than a simple "non-zero pixel" count:
// neighboring sprites bleed across a naïve rectangle check at the wrong
// cols hypothesis, so we require an actual player-sprite match anchored
// at (cx+2, cy+1). Dead slots draw the body sprite, not the player
// sprite; we accept either as "filled" via cellFilled.
func parseVoteLayout(pixels []uint8) *voteLayout {
	if len(pixels) != ScreenWidth*ScreenHeight {
		return nil
	}
	for cols := 8; cols >= 1; cols-- {
		startX := (ScreenWidth - cols*voteCellW) / 2
		if startX < 0 || startX+cols*voteCellW > ScreenWidth {
			continue
		}
		// Row 0 must be fully populated for this cols hypothesis.
		filled := 0
		for col := 0; col < cols; col++ {
			cx := startX + col*voteCellW
			cy := voteStartY
			if cellFilled(pixels, cx, cy) {
				filled++
			}
		}
		if filled != cols {
			continue
		}
		// Check row 1 (n > cols).
		rows := 1
		if cols == 8 {
			for col := 0; col < cols; col++ {
				cx := startX + col*voteCellW
				cy := voteStartY + voteCellH
				if cellFilled(pixels, cx, cy) {
					rows = 2
					break
				}
			}
		}
		// Build layout.
		layout := &voteLayout{
			n:      0,
			cols:   cols,
			rows:   rows,
			startX: startX,
		}
		for row := 0; row < rows; row++ {
			for col := 0; col < cols; col++ {
				cx := startX + col*voteCellW
				cy := voteStartY + row*voteCellH
				if !cellFilled(pixels, cx, cy) {
					// Trailing empty cells on the last row mean we've
					// hit the end of the player list.
					if row == rows-1 {
						return layout
					}
					// An empty cell mid-grid means our cols guess was
					// wrong; abandon this hypothesis.
					return nil
				}
				layout.slotCells[layout.n] = voteCell{
					cx:    cx,
					cy:    cy,
					alive: slotAlive(pixels, cx, cy),
				}
				layout.n++
				if layout.n >= voteMaxSlots {
					return layout
				}
			}
		}
		return layout
	}
	return nil
}

// cellFilled reports whether a live player sprite (matchesCrewmate) is
// drawn anchored at (cx+2, cy+1). For dead slots the body sprite is
// drawn instead; we approximate that case by requiring enough stable
// non-zero pixels and a palette-0 outline near the center top — the
// body sprite has its 2-pixel vertical skull ~(5,3)..(6,6), which
// happens to sit right on top of a palette-0 neighbor. The aim is just
// to reject empty cells and neighboring-sprite bleed; dead-slot exact
// discrimination falls to slotAlive.
func cellFilled(pixels []uint8, cx, cy int) bool {
	const sprOffX, sprOffY = 2, 1
	tlx, tly := cx+sprOffX, cy+sprOffY
	// Alive slot: exact player-sprite template match (template-perfect).
	if matchesCrewmate(pixels, tlx, tly, false) {
		return true
	}
	// Dead slot: use the body detector's stable-pixel scorer.
	if bodyMatchAt(pixels, tlx, tly) {
		return true
	}
	return false
}

// slotAlive distinguishes an alive player's sprite from a dead player's
// body sprite. The player sprite has a visor (palette 14) + eye
// (palette 2) block in rows 3-5 of the sprite; the body sprite uses a
// palette-2 skull in rows 2-6 but no palette-14 pixels above it.
// Counting palette-14 within the sprite region is the cheapest
// discriminator.
func slotAlive(pixels []uint8, cx, cy int) bool {
	const sprOffX, sprOffY, sprSize = 2, 1, 12
	for dy := 0; dy < sprSize; dy++ {
		y := cy + sprOffY + dy
		if y < 0 || y >= ScreenHeight {
			continue
		}
		for dx := 0; dx < sprSize; dx++ {
			x := cx + sprOffX + dx
			if x < 0 || x >= ScreenWidth {
				continue
			}
			if pixels[y*ScreenWidth+x] == 14 {
				return true
			}
		}
	}
	return false
}

// findColor returns the slot index whose sprite is tinted with `want`,
// or -1 if no cell matches. The palette-3 tint positions on the 12×12
// player sprite are scattered; rather than embed the whole template
// here, we scan the full sprite region and vote.
func (lay *voteLayout) findColor(pixels []uint8, want uint8) int {
	if want > 15 {
		return -1
	}
	const sprOffX, sprOffY, sprSize = 2, 1, 12
	bestSlot := -1
	bestCount := 0
	for i := 0; i < lay.n; i++ {
		if !lay.slotCells[i].alive {
			continue
		}
		cx := lay.slotCells[i].cx
		cy := lay.slotCells[i].cy
		count := 0
		for dy := 0; dy < sprSize; dy++ {
			y := cy + sprOffY + dy
			if y < 0 || y >= ScreenHeight {
				continue
			}
			for dx := 0; dx < sprSize; dx++ {
				x := cx + sprOffX + dx
				if x < 0 || x >= ScreenWidth {
					continue
				}
				if pixels[y*ScreenWidth+x] == want {
					count++
				}
			}
		}
		// A real match has ~24 palette-tint pixels; require >=8 to
		// avoid false matches from background noise.
		if count > bestCount && count >= 8 {
			bestCount, bestSlot = count, i
		}
	}
	return bestSlot
}

// findCursor returns the slot index with the palette-2 highlight
// rectangle (cursor), or -1 for "cursor on SKIP" / not found. The
// highlight is a 1-pixel border; we detect it by counting palette-2
// pixels along the top edge (y = cy-1, x in [cx..cx+cellW)).
func (lay *voteLayout) findCursor(pixels []uint8) int {
	for i := 0; i < lay.n; i++ {
		cx := lay.slotCells[i].cx
		cy := lay.slotCells[i].cy
		// cy-1 must be in [0, ScreenHeight).
		y := cy - 1
		if y < 0 || y >= ScreenHeight {
			continue
		}
		// Top edge is cellW palette-2 pixels. Require >=12 to be safe
		// against 1-2 palette-2 pixels leaking from the sprite visor.
		count := 0
		row := pixels[y*ScreenWidth : (y+1)*ScreenWidth]
		for x := cx; x < cx+voteCellW && x < ScreenWidth; x++ {
			if row[x] == 2 {
				count++
			}
		}
		if count >= 12 {
			return i
		}
	}
	return -1
}

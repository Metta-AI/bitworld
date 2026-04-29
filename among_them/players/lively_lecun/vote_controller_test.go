package main

import "testing"

// paintVotePanel paints an n-player voting panel with the given slot
// colors (len(colors) == n), and puts the cursor highlight on slot
// `cursor` (use -1 to put the cursor on SKIP).
//
// Layout mirrors sim.nim:1820-1905 buildVoteFrame: cellW=16, cellH=17,
// cols=min(n,8), rows=ceil(n/cols), startX=(128-cols*16)/2, startY=2,
// sprite at (cx+2, cy+1). SKIP at y=startY+rows*cellH, x=skipX, 28 wide.
// Cursor is a palette-2 rectangle one pixel outside the cell.
func paintVotePanel(colors []uint8, cursor int) []uint8 {
	p := make([]uint8, ScreenWidth*ScreenHeight)
	n := len(colors)
	cols := n
	if cols > 8 {
		cols = 8
	}
	rows := (n + cols - 1) / cols
	startX := (ScreenWidth - cols*voteCellW) / 2
	for i, color := range colors {
		col := i % cols
		row := i / cols
		cx := startX + col*voteCellW
		cy := voteStartY + row*voteCellH
		overlayCrewmate(p, cx+2, cy+1, color, false)
		if i == cursor {
			paintCursor(p, cx, cy)
		}
	}
	// SKIP box below the grid.
	const skipX, skipW = 50, 28
	skipY := voteStartY + rows*voteCellH + 1 // sim.nim: skipY offset from cells
	// Paint a minimal SKIP text block so parseVoteLayout isn't fooled into
	// thinking there are more player cells.
	if cursor == -1 {
		// Highlight the row directly above SKIP.
		paintRow(p, skipX, skipY-1, skipW, 2)
	}
	_ = skipY
	return p
}

// paintCursor paints the palette-2 highlight border around a cell at
// (cx, cy). findCursor only inspects the top edge (y = cy-1), so that's
// all we need to paint.
func paintCursor(p []uint8, cx, cy int) {
	y := cy - 1
	if y < 0 || y >= ScreenHeight {
		return
	}
	for x := cx; x < cx+voteCellW && x < ScreenWidth; x++ {
		p[y*ScreenWidth+x] = 2
	}
}

// pumpVote drives the controller for up to maxFrames frames using the
// same pixel buffer and returns the sequence of masks. Useful for
// checking "did A eventually fire".
func pumpVote(vc *VoteController, pixels []uint8, maxFrames int) []uint8 {
	out := make([]uint8, 0, maxFrames)
	for i := 0; i < maxFrames; i++ {
		out = append(out, vc.Next(pixels))
	}
	return out
}

func TestVoteController_FirstCallReleases(t *testing.T) {
	vc := VoteController{Target: 3}
	p := make([]uint8, ScreenWidth*ScreenHeight)
	if got := vc.Next(p); got != 0 {
		t.Fatalf("first call = %#x, want 0 (release)", got)
	}
}

func TestVoteController_PressReleaseCadence(t *testing.T) {
	// Every other call must be 0 regardless of frame content.
	vc := VoteController{Target: 255} // skip
	p := make([]uint8, ScreenWidth*ScreenHeight)
	masks := pumpVote(&vc, p, 8)
	if masks[0] != 0 {
		t.Fatalf("call 0 = %#x, want 0", masks[0])
	}
	for i := 1; i < len(masks); i++ {
		want0 := i%2 == 0
		got0 := masks[i] == 0
		if got0 != want0 {
			t.Errorf("call %d = %#x, want %s", i, masks[i],
				map[bool]string{true: "0", false: "non-zero"}[want0])
		}
	}
}

func TestVoteController_Target255FallsBackToSkip(t *testing.T) {
	vc := VoteController{Target: 255}
	// Cursor on cell 0; needs Right to advance off the grid toward SKIP.
	p := paintVotePanel([]uint8{3, 7, 8}, 0)
	vc.Next(p) // release
	if got := vc.Next(p); got != ButtonRight {
		t.Errorf("Target=255 with cursor off skip: got %#x, want ButtonRight", got)
	}
}

func TestVoteController_CastsOnSkipWhenOnSkip(t *testing.T) {
	vc := VoteController{Target: 255}
	// Cursor directly on SKIP (cursor=-1 paints skip highlight).
	p := paintVotePanel([]uint8{3, 7, 8}, -1)
	vc.Next(p) // release
	if got := vc.Next(p); got != ButtonA {
		t.Fatalf("on SKIP, Target=255: got %#x, want ButtonA", got)
	}
}

func TestVoteController_SuspectNotVisibleGivesUp(t *testing.T) {
	// Target=11 but no slot has that color — fallback to SKIP navigation.
	vc := VoteController{Target: 11}
	p := paintVotePanel([]uint8{3, 7, 8}, 0)
	vc.Next(p) // release
	mask := vc.Next(p)
	if mask != ButtonRight {
		t.Fatalf("suspect-not-visible: got %#x, want ButtonRight (skip path)", mask)
	}
	if !vc.giveUp {
		t.Fatalf("expected giveUp=true after suspect-not-visible decision")
	}
}

func TestVoteController_PressesAWhenOnTarget(t *testing.T) {
	vc := VoteController{Target: 7}
	// Cursor on slot 1 (color=7), matching Target.
	p := paintVotePanel([]uint8{3, 7, 8}, 1)
	vc.Next(p) // release
	if got := vc.Next(p); got != ButtonA {
		t.Fatalf("cursor on target slot: got %#x, want ButtonA", got)
	}
}

func TestVoteController_AdvancesTowardTarget(t *testing.T) {
	// Cursor on slot 0; target color at slot 2. Must emit Right (not A).
	vc := VoteController{Target: 8}
	p := paintVotePanel([]uint8{3, 7, 8}, 0)
	vc.Next(p) // release
	if got := vc.Next(p); got != ButtonRight {
		t.Fatalf("cursor ahead of target: got %#x, want ButtonRight", got)
	}
}

func TestVoteController_ReachesTargetThroughAdvances(t *testing.T) {
	// Simulate real input: every Right press advances the cursor by one
	// slot, and the next frame reflects the move. Target is slot 2; start
	// at slot 0. Expect A to fire after the cursor reaches slot 2.
	colors := []uint8{3, 7, 8}
	vc := VoteController{Target: 8}
	cursor := 0
	var lastMask uint8
	sawA := false
	for i := 0; i < 20 && !sawA; i++ {
		p := paintVotePanel(colors, cursor)
		lastMask = vc.Next(p)
		if lastMask == ButtonA {
			sawA = true
			break
		}
		if lastMask == ButtonRight {
			cursor = (cursor + 1) % len(colors)
		}
	}
	if !sawA {
		t.Fatalf("cursor advanced to target but A never fired; last mask=%#x cursor=%d", lastMask, cursor)
	}
	if cursor != 2 {
		t.Fatalf("A fired at cursor=%d, want 2", cursor)
	}
}

func TestVoteController_ExhaustsBudgetAndGivesUp(t *testing.T) {
	// Cursor stuck on slot 0 forever. After voteMaxMoves Right-presses the
	// controller should flip giveUp=true. Then it switches to the skip
	// path, which (still with a static frame) keeps emitting Right.
	vc := VoteController{Target: 8}
	p := paintVotePanel([]uint8{3, 7, 8}, 0)
	for i := 0; i < 2*(voteMaxMoves+2); i++ {
		vc.Next(p)
	}
	if !vc.giveUp {
		t.Fatalf("expected giveUp=true after exhausting %d moves", voteMaxMoves)
	}
}

func TestParseVoteLayout_ThreePlayers(t *testing.T) {
	p := paintVotePanel([]uint8{3, 7, 8}, 0)
	lay := parseVoteLayout(p)
	if lay == nil {
		t.Fatal("parseVoteLayout returned nil on 3-player panel")
	}
	if lay.n != 3 {
		t.Errorf("n = %d, want 3", lay.n)
	}
	if lay.cols != 3 || lay.rows != 1 {
		t.Errorf("cols/rows = %d/%d, want 3/1", lay.cols, lay.rows)
	}
}

func TestVoteLayout_FindCursor(t *testing.T) {
	p := paintVotePanel([]uint8{3, 7, 8}, 1)
	lay := parseVoteLayout(p)
	if lay == nil {
		t.Fatal("parseVoteLayout returned nil")
	}
	got := lay.findCursor(p)
	if got != 1 {
		t.Fatalf("findCursor: got %d, want 1", got)
	}
}

func TestParseVoteLayout_RealFixture(t *testing.T) {
	// Guardrail: the captured phase_voting fixture has n=3 alive and the
	// cursor on cell 0. Regressions in cellFilled / cols-probing tend to
	// misread this frame first.
	p := loadPhaseFixture(t, "voting")
	lay := parseVoteLayout(p)
	if lay == nil {
		t.Fatalf("parseVoteLayout returned nil on real phase_voting fixture")
	}
	if lay.n != 3 {
		t.Fatalf("n = %d, want 3", lay.n)
	}
	if got := lay.findCursor(p); got != 0 {
		t.Fatalf("findCursor: got %d, want 0", got)
	}
}

func TestVoteLayout_FindColor(t *testing.T) {
	p := paintVotePanel([]uint8{3, 7, 8}, 0)
	lay := parseVoteLayout(p)
	if lay == nil {
		t.Fatal("parseVoteLayout returned nil")
	}
	cases := []struct {
		color uint8
		want  int
	}{
		{3, 0},
		{7, 1},
		{8, 2},
		{11, -1},
	}
	for _, c := range cases {
		if got := lay.findColor(p, c.color); got != c.want {
			t.Errorf("findColor(%d): got %d, want %d", c.color, got, c.want)
		}
	}
}

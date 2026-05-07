package main

import _ "embed"

// StatusIconKind classifies what the sim drew at the fixed status-icon slot
// in the bottom-left of the active HUD (sim.nim:2661-2673).
type StatusIconKind uint8

func (k StatusIconKind) String() string {
	switch k {
	case StatusUnknown:
		return "unknown"
	case StatusCrewmate:
		return "crewmate"
	case StatusGhost:
		return "ghost"
	case StatusImposterReady:
		return "imposter-ready"
	case StatusImposterCooldown:
		return "imposter-cooldown"
	default:
		return "invalid"
	}
}

const (
	StatusUnknown StatusIconKind = iota
	// StatusCrewmate means the slot is empty. Sim draws no icon for alive
	// crewmates (only ghost+imposter branches paint there), so "no match"
	// is the signal. We don't *directly* confirm crewmate -- it's the
	// default once we've ruled out ghost and imposter.
	StatusCrewmate
	// StatusGhost: ghost icon blitted raw (player.alive == false).
	StatusGhost
	// StatusImposterReady: kill-button sprite blitted raw (killCooldown == 0).
	StatusImposterReady
	// StatusImposterCooldown: kill-button sprite blitted shadowed
	// (killCooldown > 0) -- the same template drawn through ShadowMap.
	StatusImposterCooldown
)

// statusIcon templates, baked from spritesheet.aseprite by
// cmd/extract_sprites/main.go. 12×12 palette indices (0..15); 255 marks
// transparent pixels we skip. Matching code lives in this file.
//
//go:embed testdata/kill_icon.bin
var killIconTemplate []byte

//go:embed testdata/ghost_icon.bin
var ghostIconTemplate []byte

const (
	// Slot where sim.nim:2663-2664 blits the status icon every active frame.
	statusIconX = 1
	statusIconY = ScreenHeight - statusIconSize - 1 // 128 - 12 - 1 = 115
	statusIconSize = 12

	// Miss budgets ported from nottoodumb.nim:1310, 1322: the ghost icon
	// is the stricter check so fewer misses are tolerated. Numbers are
	// absolute miss counts across opaque template pixels.
	statusGhostMaxMisses = 3
	statusKillMaxMisses  = 5

	// Ghost state latches after this many consecutive ghost-icon frames
	// (nottoodumb.nim:78). Tight enough that one noisy frame can't kick
	// us out of ghost-tasking mode; loose enough that a real death is
	// reflected in <0.1 s @ 24 fps.
	statusGhostFrameThreshold = 2
)

// shadowMap is the sim's palette-index → shadow-palette-index table
// (sim.nim:106-123). A shaded sprite paints its opaque pixels through this
// lookup; we check both raw and shaded variants of the kill-button sprite
// to distinguish ImposterReady from ImposterCooldown.
var shadowMap = [16]uint8{
	0,  // 0 black       -> black
	12, // 1 gray         -> dark navy
	9,  // 2 white        -> dark teal
	5,  // 3 red          -> dark brown
	5,  // 4 pink         -> dark brown
	0,  // 5 dark brown   -> black
	5,  // 6 brown        -> dark brown
	5,  // 7 orange       -> dark brown
	5,  // 8 yellow       -> dark brown
	12, // 9 dark teal    -> dark navy
	9,  // 10 green       -> dark teal
	9,  // 11 lime        -> dark teal
	0,  // 12 dark navy   -> black
	12, // 13 blue        -> dark navy
	12, // 14 light blue  -> dark navy
	9,  // 15 pale blue   -> dark teal
}

// spriteMisses returns (misses, opaque) for a 12×12 palette-indexed
// template laid at (x, y). `shadow` chooses between a raw match (template
// pixel must equal frame pixel) and a shadowed match (frame pixel must
// equal shadowMap[templatePixel & 0x0f]). Pixels whose target coord falls
// outside the viewport count as a miss -- sim.nim:2663 paints inside the
// screen, so any out-of-bounds pixel is a real divergence, not clipping.
func spriteMisses(pixels, template []byte, x, y int, shadow bool) (misses, opaque int) {
	for dy := 0; dy < statusIconSize; dy++ {
		for dx := 0; dx < statusIconSize; dx++ {
			t := template[dy*statusIconSize+dx]
			if t == 255 {
				continue
			}
			opaque++
			fx := x + dx
			fy := y + dy
			if fx < 0 || fy < 0 || fx >= ScreenWidth || fy >= ScreenHeight {
				misses++
				continue
			}
			want := t
			if shadow {
				want = shadowMap[t&0x0f]
			}
			if pixels[fy*ScreenWidth+fx] != want {
				misses++
			}
		}
	}
	return misses, opaque
}

// StatusDetector runs the 3-pass icon check each active frame. Latching
// rules mirror nottoodumb.nim:1314-1349: ghost requires
// statusGhostFrameThreshold consecutive matches; once latched, ghost stays
// latched (the sim never revives). Imposter role stays latched once set,
// but killReady is per-frame -- we never act on a stale "ready" signal.
type StatusDetector struct {
	ghostFrames int
	latched     StatusIconKind // sticky: Ghost or Imposter* once observed
	killReady   bool           // true iff the *current* frame saw kill-raw
}

// Next inspects one frame and returns the current classification. Callers
// should cache the returned role on the Agent; mutation-free wrappers
// (IsGhost, Role, KillReady) follow.
func (s *StatusDetector) Next(pixels []uint8) StatusIconKind {
	s.killReady = false
	if len(pixels) != ScreenWidth*ScreenHeight {
		return StatusUnknown
	}

	// Ghost check first: if the agent is dead, the imposter kill button is
	// never drawn, so any ghost-icon match wins.
	gMiss, gOpaque := spriteMisses(pixels, ghostIconTemplate, statusIconX, statusIconY, false)
	if gOpaque > 0 && gMiss <= statusGhostMaxMisses {
		s.ghostFrames++
		if s.ghostFrames >= statusGhostFrameThreshold {
			s.latched = StatusGhost
			return StatusGhost
		}
		// Not yet latched -- keep reporting prior state.
		if s.latched != StatusUnknown {
			return s.latched
		}
		return StatusUnknown
	}
	// Only reset the counter when we're not already a ghost. Once latched
	// we stay latched -- a momentary occlusion shouldn't flip us back to
	// crewmate behavior mid-round.
	if s.latched != StatusGhost {
		s.ghostFrames = 0
	} else {
		return StatusGhost
	}

	// Kill-button raw = imposter, cooldown clear.
	kMiss, kOpaque := spriteMisses(pixels, killIconTemplate, statusIconX, statusIconY, false)
	if kOpaque > 0 && kMiss <= statusKillMaxMisses {
		s.latched = StatusImposterReady
		s.killReady = true
		return StatusImposterReady
	}
	// Kill-button shadowed = imposter, cooldown > 0.
	sMiss, sOpaque := spriteMisses(pixels, killIconTemplate, statusIconX, statusIconY, true)
	if sOpaque > 0 && sMiss <= statusKillMaxMisses {
		s.latched = StatusImposterCooldown
		return StatusImposterCooldown
	}

	// No icon matched. If we've previously latched Imposter, keep it (role
	// doesn't change mid-game; we just aren't confident about the
	// cooldown state this frame).
	if s.latched == StatusImposterReady || s.latched == StatusImposterCooldown {
		return s.latched
	}
	return StatusCrewmate
}

// IsGhost reports whether the ghost icon has latched.
func (s *StatusDetector) IsGhost() bool { return s.latched == StatusGhost }

// IsImposter reports whether either imposter variant has ever latched.
func (s *StatusDetector) IsImposter() bool {
	return s.latched == StatusImposterReady || s.latched == StatusImposterCooldown
}

// KillReady returns true when the most recent Next() saw the raw kill icon.
// It is *not* sticky -- callers should use this to decide whether to press
// ButtonA on the current frame.
func (s *StatusDetector) KillReady() bool {
	return s.killReady
}

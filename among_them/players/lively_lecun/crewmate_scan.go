package main

import _ "embed"

// playerSpriteTemplate is the 12×12 palette-indexed crewmate sprite, baked
// by cmd/extract_sprites/main.go from spritesheet.aseprite tile 0.
//
// The sim blits this via blitSpriteOutlined (sim.nim:2575), substituting
// palette 3 (TintColor) with the player's color and palette 9
// (ShadeTintColor) with ShadowMap[color & 0x0f]. Outline (0), visor (14),
// and eye (2) pixels are stable across all player colors; tint pixels
// identify which color is wearing the suit.
//
//go:embed testdata/player_sprite.bin
var playerSpriteTemplate []byte

const (
	playerSpriteW = 12
	playerSpriteH = 12

	playerTint       = 3 // TintColor in sim.nim:34
	playerTintShadow = 9 // ShadeTintColor in sim.nim:35

	// Ported from nottoodumb.nim:71-73. 8 misses across 78 stable pixels
	// is ~10%, and we require at least 8 stable pixels to match (so tiny
	// clipped sprites don't false-positive).
	crewmateMaxMisses       = 8
	crewmateMinStablePixels = 8
	crewmateMinBodyPixels   = 8

	// Dedup radius (screen-px): two scan hits closer than this collapse
	// into one. nottoodumb.nim:70 uses CrewmateSearchRadius=1 for the
	// seed phase; we widen slightly for the post-scan dedup pass.
	crewmateDedupRadius = 6

	// Seed color: palette-0 outline. Every crewmate sprite has 60 pa0
	// pixels; the outline is topologically complex enough that false
	// seeds from random black pixels fail scoreCrewmate almost always.
	// We dedup seeds by top-left so even an all-black region only costs
	// one full match attempt per screen position.
	crewmateSeedColor = 0

	// Self-sprite exclusion: the player's own sprite always sits at the
	// camera center (sim.nim:2569-2570). Reject any crewmate match whose
	// top-left is within this many pixels of (playerScreenX, playerScreenY).
	crewmateSelfRejectRadius = 8
)

// CrewmateMatch is a crewmate-sprite hit in screen space.
type CrewmateMatch struct {
	ScreenX, ScreenY int
	Color            uint8 // best-guess player color via tint pixels; 255 if unknown
	FlipH            bool  // sim's sprite flip (walking left)
}

// cached palette-3/9 template offsets, populated on first use.
var crewmateStable []crewmateStablePx // palette != 3, 9, 255
var crewmateBody []crewmateBodyPx     // palette 3 or 9 (tint wildcards)

type crewmateStablePx struct {
	dx, dy int
	pal    uint8
}
type crewmateBodyPx struct {
	dx, dy int
	shadow bool
}

func ensureCrewmateTables() {
	if crewmateStable != nil {
		return
	}
	if len(playerSpriteTemplate) != playerSpriteW*playerSpriteH {
		return
	}
	stable := make([]crewmateStablePx, 0, 80)
	body := make([]crewmateBodyPx, 0, 50)
	for dy := 0; dy < playerSpriteH; dy++ {
		for dx := 0; dx < playerSpriteW; dx++ {
			p := playerSpriteTemplate[dy*playerSpriteW+dx]
			switch p {
			case 255:
				continue
			case playerTint:
				body = append(body, crewmateBodyPx{dx, dy, false})
			case playerTintShadow:
				body = append(body, crewmateBodyPx{dx, dy, true})
			default:
				stable = append(stable, crewmateStablePx{dx, dy, p})
			}
		}
	}
	crewmateStable = stable
	crewmateBody = body
}

// playerBodyColor: does a frame pixel look like a player's body could be
// painted that color? Ports nottoodumb.nim:1364-1370. PlayerColors list
// is sim.nim:88-105; the shadow of any player color also counts.
func playerBodyColor(c uint8) bool {
	for _, pc := range playerColors {
		if c == pc || c == shadowMap[pc&0x0f] {
			return true
		}
	}
	return false
}

// playerColors mirrors sim.nim:88-105. Each 8-player game uses the first
// 8 entries, but we accept any of the 16 here for generality.
var playerColors = [16]uint8{3, 7, 8, 14, 4, 11, 13, 15, 1, 2, 5, 6, 9, 10, 12, 0}

// FindCrewmates scans the frame for every visible non-self crewmate
// sprite. Both flipH=false and flipH=true orientations are tried at each
// seed. Matches are deduped within crewmateDedupRadius.
//
// The player's own sprite (always centered at playerScreen{X,Y}) is
// rejected via crewmateSelfRejectRadius. This is critical: the self
// sprite always matches, and if we didn't reject it we'd always think a
// crewmate is at distance 0.
func FindCrewmates(pixels []uint8) []CrewmateMatch {
	if len(pixels) != ScreenWidth*ScreenHeight {
		return nil
	}
	ensureCrewmateTables()
	if len(crewmateStable) == 0 {
		return nil
	}
	// Seed offsets: the template's palette-0 (outline) positions. Every
	// on-screen pa0 pixel acts as a candidate seed.
	tried := make(map[int]struct{}, 256)
	var out []CrewmateMatch

	// Pre-split stable into seed-worthy outline offsets to avoid trying
	// eye (pa2) or visor (pa14) pixels as seeds — their colors overlap
	// with random scene colors more than pa0 does.
	var seedOffs []struct{ dx, dy int }
	for _, sp := range crewmateStable {
		if sp.pal == crewmateSeedColor {
			seedOffs = append(seedOffs, struct{ dx, dy int }{sp.dx, sp.dy})
		}
	}

	for sy := 0; sy < ScreenHeight; sy++ {
		for sx := 0; sx < ScreenWidth; sx++ {
			if pixels[sy*ScreenWidth+sx] != crewmateSeedColor {
				continue
			}
			for _, off := range seedOffs {
				tlx, tly := sx-off.dx, sy-off.dy
				if tlx <= -playerSpriteW || tly <= -playerSpriteH ||
					tlx >= ScreenWidth || tly >= ScreenHeight {
					continue
				}
				// Self-reject: the player's own sprite blits at
				// (playerScreenX, playerScreenY) = (60, 58) with
				// SpriteDrawOff already applied (sim.nim:2569).
				if absInt(tlx-playerScreenX) < crewmateSelfRejectRadius &&
					absInt(tly-playerScreenY) < crewmateSelfRejectRadius {
					continue
				}
				for _, flipH := range [2]bool{false, true} {
					flipKey := 0
					if flipH {
						flipKey = 1
					}
					key := 2*((tly+playerSpriteH)*ScreenWidth+(tlx+playerSpriteW)) + flipKey
					if _, ok := tried[key]; ok {
						continue
					}
					tried[key] = struct{}{}
					if !matchesCrewmate(pixels, tlx, tly, flipH) {
						continue
					}
					out = append(out, CrewmateMatch{
						ScreenX: tlx,
						ScreenY: tly,
						Color:   crewmateTintColor(pixels, tlx, tly, flipH),
						FlipH:   flipH,
					})
				}
			}
		}
	}

	// Dedup.
	deduped := out[:0]
	for _, m := range out {
		keep := true
		for i, k := range deduped {
			if absInt(m.ScreenX-k.ScreenX) < crewmateDedupRadius &&
				absInt(m.ScreenY-k.ScreenY) < crewmateDedupRadius {
				// Prefer the match that has a known color.
				if k.Color == 255 && m.Color != 255 {
					deduped[i] = m
				}
				keep = false
				break
			}
		}
		if keep {
			deduped = append(deduped, m)
		}
	}
	return deduped
}

// playerScreenX/Y is where the player's *own* sprite top-left sits on
// screen, matching the camera anchor (sim.nim:2569-2570 with
// cameraFor centering). Derived from playerWorldOffX/Y in tracker.go:
//
//	cam.X = player.x - playerWorldOffX
//	sprite.x = player.x - SpriteDrawOffX - cam.X
//	        = player.x - 2 - (player.x - 60) = 58
//
// Wait — playerWorldOffX = 60, so sprite.x = 58. Similarly sprite.y = 58.
const (
	playerScreenX = 58
	playerScreenY = 58
)

// matchesCrewmate ports nottoodumb.nim:1415-1461. Stable pixels must match
// exactly; tint/shade pixels must match *some* player color.
func matchesCrewmate(pixels []uint8, tlx, tly int, flipH bool) bool {
	var (
		stable, stableOk int
		body, bodyOk     int
		misses           int
	)
	for dy := 0; dy < playerSpriteH; dy++ {
		for dx := 0; dx < playerSpriteW; dx++ {
			srcX := dx
			if flipH {
				srcX = playerSpriteW - 1 - dx
			}
			tp := playerSpriteTemplate[dy*playerSpriteW+srcX]
			if tp == 255 {
				continue
			}
			isTint := tp == playerTint || tp == playerTintShadow
			if isTint {
				body++
			} else {
				stable++
			}
			fx, fy := tlx+dx, tly+dy
			if fx < 0 || fy < 0 || fx >= ScreenWidth || fy >= ScreenHeight {
				misses++
				if misses > crewmateMaxMisses {
					return false
				}
				continue
			}
			fc := pixels[fy*ScreenWidth+fx]
			var ok bool
			if isTint {
				ok = playerBodyColor(fc)
			} else {
				ok = fc == tp
			}
			if ok {
				if isTint {
					bodyOk++
				} else {
					stableOk++
				}
			} else {
				misses++
				if misses > crewmateMaxMisses {
					return false
				}
			}
		}
	}
	return stable >= crewmateMinStablePixels &&
		stableOk >= crewmateMinStablePixels &&
		body >= crewmateMinBodyPixels &&
		bodyOk >= crewmateMinBodyPixels
}

// crewmateTintColor inspects the tint pixels at the matched location
// and returns the palette index that occurs most often. 255 if none are
// visible (fully clipped sprite).
func crewmateTintColor(pixels []uint8, tlx, tly int, flipH bool) uint8 {
	var counts [16]int
	seen := false
	for _, tp := range crewmateBody {
		if tp.shadow {
			continue
		}
		dx := tp.dx
		if flipH {
			dx = playerSpriteW - 1 - tp.dx
		}
		fx, fy := tlx+dx, tly+tp.dy
		if fx < 0 || fy < 0 || fx >= ScreenWidth || fy >= ScreenHeight {
			continue
		}
		c := pixels[fy*ScreenWidth+fx]
		if c > 15 {
			continue
		}
		counts[c]++
		seen = true
	}
	if !seen {
		return 255
	}
	best, bestN := uint8(0), -1
	for i, n := range counts {
		if n > bestN {
			bestN = n
			best = uint8(i)
		}
	}
	return best
}

// CrewmateWorld returns the world-space center of a crewmate match's
// collision box (x+CollisionW/2, y+CollisionH/2), derived by inverting
// sim.nim:2569-2570 the same way BodyWorld does.
func CrewmateWorld(m CrewmateMatch, cam Camera) Point {
	return Point{
		X: m.ScreenX + bodySpriteDrawOffX + cam.X,
		Y: m.ScreenY + bodySpriteDrawOffY + cam.Y,
	}
}

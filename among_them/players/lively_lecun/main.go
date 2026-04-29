package main

import (
	"context"
	_ "embed"
	"flag"
	"fmt"
	"log"
	"net/url"
	"os/signal"
	"syscall"

	"nhooyr.io/websocket"
)

//go:embed testdata/skeld_map.bin
var skeldMapData []byte

//go:embed testdata/walks.bin
var walksData []byte

func main() {
	addr := flag.String("address", "localhost", "server address")
	port := flag.Int("port", 8080, "server port")
	name := flag.String("name", "lively_lecun", "player name")
	flag.Parse()

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	u := url.URL{
		Scheme:   "ws",
		Host:     fmt.Sprintf("%s:%d", *addr, *port),
		Path:     "/player",
		RawQuery: url.Values{"name": []string{*name}}.Encode(),
	}

	log.Printf("connecting to %s", u.String())
	conn, _, err := websocket.Dial(ctx, u.String(), nil)
	if err != nil {
		log.Fatalf("dial: %v", err)
	}
	defer conn.Close(websocket.StatusInternalError, "client error")
	conn.SetReadLimit(1 << 20)

	if err := conn.Write(ctx, websocket.MessageBinary, BuildInputPacket(0)); err != nil {
		log.Fatalf("initial write: %v", err)
	}

	if len(skeldMapData) != MapWidth*MapHeight {
		log.Fatalf("embedded map size = %d, want %d", len(skeldMapData), MapWidth*MapHeight)
	}
	wantWalks := (MapWidth*MapHeight + 7) / 8
	if len(walksData) != wantWalks {
		log.Fatalf("embedded walks size = %d, want %d", len(walksData), wantWalks)
	}
	tracker := NewTracker(&Map{Pixels: skeldMapData})
	walks := &WalkMask{Bits: walksData}
	nav := NewNavigator(walks)
	var memory TaskMemory

	var (
		pixels       = make([]uint8, ScreenWidth*ScreenHeight)
		sentMask     uint8 // server already has 0 from the initial packet above
		currentPhase Phase
		havePhase    bool
		skipper      SkipController
		bumper       Bumper
		holder       TaskHolder
		wanderer     Wanderer
		frames       uint64
		lastPosLog   uint64
		lastBranch   string // most recent PhaseActive branch; logged on change
		arrivedAt    uint64 // frame at which navigator first reported "arrived"; 0 means not currently arrived
		lastPlayer   Point  // player world pos last seen while nav-stuck tracking; Point{} until initialized
		lastPlayerF  uint64 // frame when lastPlayer was last updated
		stuckPerturb uint8  // non-zero while we're force-nudging through a pinned corner
		stuckLeft    int    // frames remaining of the current stuck perturb
		radarGoal       bool    // true when nav's current goal came from radar (guess), not memory (confirmed)
		radarBlack      []Point // radar-chosen targets A* couldn't reach from here; skip near these
		radarBlackFrom  Point   // player pos when radarBlack was last populated; cleared once we move away
	)
	const (
		radarBlackRadius  = 24 // world px; any candidate within this of a blacklisted point is rejected
		// Expiry must be larger than the distance between neighboring task
		// stations, or visiting station A (empty), then station B (empty),
		// resets the blacklist as soon as we reach B -- and we head back to
		// A on the next radar frame. 120 px covers typical adjacent-station
		// spacing on skeld while still clearing when the agent legitimately
		// leaves the room.
		radarBlackExpirePx = 120
	)
	radarReject := func(p Point) bool {
		for _, q := range radarBlack {
			if absInt(p.X-q.X) <= radarBlackRadius && absInt(p.Y-q.Y) <= radarBlackRadius {
				return true
			}
		}
		return false
	}
	// radarStationGoal picks the best known TaskStation that lies along
	// one of the radar arrows' bearings and isn't in the radar blacklist,
	// memorized set, or completed set. Returns (center, true) on success.
	radarStationGoal := func(arrows []RadarArrow, cam Camera, player Point, reject func(Point) bool) (Point, bool) {
		stationReject := func(i int) bool {
			c := TaskStations[i].Center
			if reject != nil && reject(c) {
				return true
			}
			// Also skip stations in memory (we already have a direct goal
			// for them) and in the memory blacklist (previously failed).
			for _, q := range memory.Known {
				if manhattan(c, q) <= taskMemoryMergeRadius {
					return true
				}
			}
			for _, q := range memory.Blacklisted {
				if manhattan(c, q) <= taskMemoryMergeRadius {
					return true
				}
			}
			return false
		}
		best := -1
		bestDist := -1
		for _, a := range arrows {
			// Bearing: extend a point past the arrow along the player->arrow
			// ray. The ray direction is (arrow - player); NearestStationAlongBearing
			// uses the vector (bearing - player).
			bearing := Point{cam.X + a.ScreenX, cam.Y + a.ScreenY}
			idx := NearestStationAlongBearing(player, bearing, stationReject)
			if idx < 0 {
				continue
			}
			d := manhattan(TaskStations[idx].Center, player)
			if best < 0 || d < bestDist {
				best, bestDist = idx, d
			}
		}
		if best < 0 {
			return Point{}, false
		}
		return TaskStations[best].Center, true
	}
	logBranch := func(name string) {
		if name != lastBranch {
			log.Printf("branch: %s (frame %d)", name, frames)
			lastBranch = name
		}
	}
	const navArrivedTimeoutFrames uint64 = 120 // ~5 s @ 24 fps -- give up on bogus task targets
	// How long the player's world position must be unchanged (while nav
	// wants them to move) before we force a perpendicular nudge. Camera-
	// based: far cleaner signal than pixelDiff because idle sprite/icon
	// animation keeps pixelDiff above its threshold even when pinned.
	const stuckFrames = 12
	const stuckBurst = 8 // how long to force the perpendicular nudge

	sendMask := func(m uint8) error {
		if m == sentMask {
			return nil
		}
		if err := conn.Write(ctx, websocket.MessageBinary, BuildInputPacket(m)); err != nil {
			return err
		}
		sentMask = m
		return nil
	}

	for {
		kind, data, err := conn.Read(ctx)
		if err != nil {
			if ctx.Err() != nil {
				log.Printf("shutdown: %v", ctx.Err())
				conn.Close(websocket.StatusNormalClosure, "bye")
				return
			}
			log.Fatalf("read: %v", err)
		}
		if kind != websocket.MessageBinary {
			log.Printf("ignoring non-binary message of type %v", kind)
			continue
		}
		if len(data) != ProtocolBytes {
			log.Printf("unexpected payload of %d bytes", len(data))
			continue
		}
		if err := UnpackFrame(data, pixels); err != nil {
			log.Printf("unpack: %v", err)
			continue
		}
		frames++

		phase := Classify(pixels)
		if !havePhase || phase != currentPhase {
			log.Printf("phase: %s (frame %d)", phase, frames)
			currentPhase = phase
			havePhase = true
			if phase == PhaseVoting {
				skipper = SkipController{}
			}
		}

		var mask uint8
		switch phase {
		case PhaseActive:
			cam, locked := tracker.Update(pixels)
			var player Point
			if !locked && frames-lastPosLog >= 24 {
				log.Printf("nolock: bestMiss=%d brutes=%d", tracker.LastMiss, tracker.Brutes)
				lastPosLog = frames
			}
			var matches []IconMatch
			if locked {
				player = Point{cam.X + playerWorldOffX, cam.Y + playerWorldOffY}
				// Exact-template match on the 12×12 task-icon sprite
				// (task_match.go). A match is strong evidence on its
				// own -- one frame is enough. A 0-match frame means
				// no task icon in view.
				matches = FindTaskIcons(pixels)
				for _, m := range matches {
					w := IconToTaskWorld(m, cam)
					// Snap noisy icon coords to the closest known station
					// (sim.nim:2440-2481 hard-codes 41 spawn positions, so
					// every real task lies within a few pixels of one of
					// them). This makes TaskMemory entries identical
					// across repeat sightings and matches A* goals exactly.
					const iconSnapDist = 24
					if idx := SnapToStation(w, iconSnapDist); idx >= 0 {
						w = TaskStations[idx].Center
					}
					if memory.Add(w) {
						log.Printf("task memorized: %v (total %d, icon@%d,%d)",
							w, memory.Len(), m.ScreenX, m.ScreenY)
					}
				}
				if frames-lastPosLog >= 24 {
					log.Printf("pos: %v cam=(%d, %d) miss=%d brutes=%d tasks=%d matches=%d",
						player, cam.X, cam.Y, cam.Mismatches, tracker.Brutes, memory.Len(), len(matches))
					lastPosLog = frames
				}
				if !nav.HasGoal() {
					if goal, _, ok := memory.Closest(player); ok {
						if nav.SetGoal(goal) {
							radarGoal = false
							log.Printf("nav: target %v (player %v, dist %d)",
								goal, player, manhattan(goal, player))
						}
					} else if arrows := FindRadarArrows(pixels); len(arrows) > 0 {
						// Expire stale radar blacklist: once we've moved
						// far from where blacklisting started, the geometry
						// around those bearings is different and A* may
						// succeed.
						if len(radarBlack) > 0 &&
							(absInt(player.X-radarBlackFrom.X) > radarBlackExpirePx ||
								absInt(player.Y-radarBlackFrom.Y) > radarBlackExpirePx) {
							log.Printf("nav: radar blacklist expired after moving %v->%v",
								radarBlackFrom, player)
							radarBlack = radarBlack[:0]
						}
						// Try to identify a specific known station along
						// the arrow's bearing (task_stations.go). This
						// gives A* an exact goal instead of a projected
						// bearing estimate. If no station matches, fall
						// back to the projected target.
						if goal, ok := radarStationGoal(arrows, cam, player, radarReject); ok {
							if nav.SetGoal(goal) {
								radarGoal = true
								log.Printf("nav: radar station target %v (player %v, %d arrows)",
									goal, player, len(arrows))
							}
						} else if goal, ok := RadarGoal(arrows, cam, walks, radarReject); ok {
							if nav.SetGoal(goal) {
								radarGoal = true
								log.Printf("nav: radar target %v (player %v, %d arrows)",
									goal, player, len(arrows))
							}
						}
					}
				}
			}

			wasHolding := holder.IsHolding()
			beforeC := holder.Completes
			var desired uint8
			var stuckEligible bool // true when we expect the player to be moving
			if m, handled := holder.Adjust(matches, player, cam); handled {
				logBranch("holder")
				mask = m
				arrivedAt = 0
				if !wasHolding {
					log.Printf("task: holding (frame %d)", frames)
				}
				if holder.Completes != beforeC {
					log.Printf("task: completed #%d (frame %d)", holder.Completes, frames)
					if locked {
						if _, idx, ok := memory.Closest(player); ok {
							memory.Forget(idx)
						}
					}
					nav.Clear()
				}
			} else if locked && nav.HasGoal() {
				// A memorized task that's come into view preempts any radar
				// goal -- radar goals are rough estimates along a bearing,
				// memorized tasks are confirmed locations.
				if radarGoal {
					if goal, _, ok := memory.Closest(player); ok {
						if nav.SetGoal(goal) {
							radarGoal = false
							arrivedAt = 0
							log.Printf("nav: memorized target preempts radar: %v (player %v, dist %d)",
								goal, player, manhattan(goal, player))
						}
					}
				}
				logBranch("nav")
				navMask, arrived := nav.Next(player)
				if navMask == Unreachable {
					// A* found no path from our current cell to the goal.
					// Forget memorized goals so we stop re-selecting them;
					// clear radar so the next frame re-polls arrows.
					if radarGoal {
						log.Printf("nav: radar target %v unreachable; blacklisting", nav.Goal())
						if len(radarBlack) == 0 {
							radarBlackFrom = player
						}
						radarBlack = append(radarBlack, nav.Goal())
					} else {
						log.Printf("nav: memorized target %v unreachable; blacklisting", nav.Goal())
						if task, idx, ok := memory.Closest(player); ok {
							memory.Forget(idx)
							// Blacklist the task coord (not the snapped
							// nav.Goal()) so future icon matches at the
							// same world location stay rejected.
							memory.Blacklist(task)
						}
					}
					nav.Clear()
					radarGoal = false
					arrivedAt = 0
					mask = 0
					break
				}
				if arrived {
					if radarGoal {
						// Radar goal is a guess; arriving doesn't mean a
						// task is here. Blacklist this target so we don't
						// immediately reselect it from the same bearing
						// next frame, then re-poll.
						log.Printf("nav: reached radar target %v; re-polling", nav.Goal())
						if len(radarBlack) == 0 {
							radarBlackFrom = player
						}
						radarBlack = append(radarBlack, nav.Goal())
						nav.Clear()
						radarGoal = false
						arrivedAt = 0
						mask = 0
					} else {
						if arrivedAt == 0 {
							arrivedAt = frames
							log.Printf("nav: arrived at %v (waiting for TaskHolder)", nav.Goal())
						}
						if frames-arrivedAt > navArrivedTimeoutFrames {
							log.Printf("nav: gave up on %v (no task fired in %d frames); blacklisting",
								nav.Goal(), navArrivedTimeoutFrames)
							if task, idx, ok := memory.Closest(player); ok {
								memory.Forget(idx)
								memory.Blacklist(task)
							}
							nav.Clear()
							arrivedAt = 0
							mask = 0
						} else {
							// Nav's snapped goal may sit a few world pixels
							// off the true task center (furniture/walls
							// block the exact center, so SetGoal snaps to
							// the nearest walkable cell). Once arrived,
							// push cardinally toward the memorized task
							// coord so OnTask's tight 6-px radius fires.
							if task, _, ok := memory.Closest(player); ok {
								desired = maskTowards(player, task)
								stuckEligible = desired != 0
							} else {
								mask = 0
							}
						}
					}
				} else {
					arrivedAt = 0
					desired = navMask
					stuckEligible = true
				}
			} else {
				arrivedAt = 0
				desired = Steer(pixels)
				if desired == 0 {
					// Steer sees no radar arrows (or they cancel out).
					// Without a default direction we pin in place forever,
					// since stuckEligible=false means no bumper/perturb.
					// Wander cardinally so tasks eventually come into view.
					desired = wanderer.Next()
					if !locked {
						logBranch("wander-nolock")
					} else {
						logBranch("wander-nogoal")
					}
				} else if !locked {
					logBranch("steer-nolock")
				} else {
					logBranch("steer-nogoal")
				}
				stuckEligible = locked && desired != 0
			}

			// Unified stuck detection: any branch that asks the player to
			// move and has a locked tracker is eligible. Camera position
			// is a cleaner stuck signal than pixel-diff because palette
			// animation (idle sprites, icon blinks) keeps pixel-diff
			// above its threshold even when the player is pinned.
			if stuckEligible {
				// Tracker jitters by a pixel or two per frame even when the
				// player is pinned, so require > stuckJitter world-pixel
				// movement to count as "moving."
				const stuckJitter = 2
				moved := lastPlayerF == 0 ||
					absInt(player.X-lastPlayer.X) > stuckJitter ||
					absInt(player.Y-lastPlayer.Y) > stuckJitter
				if moved {
					lastPlayer = player
					lastPlayerF = frames
				} else if stuckLeft == 0 && frames-lastPlayerF >= stuckFrames {
					// perpendicular returns 0 when desired has no axis
					// (e.g. navMask briefly empty). A zero nudge would
					// send mask 0, the player wouldn't move, and we'd
					// re-enter this branch forever. Skip and wait for
					// desired to take a direction.
					nudge := perpendicular(desired, int(frames))
					if nudge != 0 {
						stuckPerturb = nudge
						stuckLeft = stuckBurst
						lastPlayerF = frames
						log.Printf("stuck: %v for %d frames; nudge=%#x (frame %d)",
							player, stuckFrames, stuckPerturb, frames)
					}
				}
				applied := desired
				if stuckLeft > 0 {
					applied = stuckPerturb
					stuckLeft--
				}
				beforeP := bumper.Perturbs
				mask = bumper.Adjust(pixels, applied)
				if bumper.Perturbs != beforeP {
					log.Printf("bumper: perturb #%d (frame %d, mask %#x)", bumper.Perturbs, frames, mask)
				}
			}
		case PhaseVoting:
			mask = skipper.Next(pixels)
		default:
			mask = 0
		}

		if mask != sentMask && frames > 100 {
			log.Printf("mask: %#x -> %#x (frame %d)", sentMask, mask, frames)
		}
		if err := sendMask(mask); err != nil {
			log.Printf("send mask=%#x: %v", mask, err)
			return
		}
	}
}

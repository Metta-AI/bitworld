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
		frames       uint64
		lastPosLog   uint64
		arrivedAt    uint64 // frame at which navigator first reported "arrived"; 0 means not currently arrived
	)
	const navArrivedTimeoutFrames uint64 = 120 // ~5 s @ 24 fps -- give up on bogus task targets

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
			if locked {
				player = Point{cam.X + ScreenWidth/2, cam.Y + ScreenHeight/2}
				// Memorize on-screen task icons (drops candidates whose
				// world position isn't walkable -- e.g., orange-tinted
				// player sprites that look like task icons).
				for _, ic := range DetectTaskIcons(pixels) {
					w := IconScreenToTaskWorld(ic, cam)
					if walks.Walkable(w.X, w.Y) && memory.Add(w) {
						log.Printf("task seen: %v (total %d)", w, memory.Len())
					}
				}
				if frames-lastPosLog >= 24 {
					log.Printf("pos: %v cam=(%d, %d) miss=%d brutes=%d tasks=%d",
						player, cam.X, cam.Y, cam.Mismatches, tracker.Brutes, memory.Len())
					lastPosLog = frames
				}
				if !nav.HasGoal() {
					if goal, _, ok := memory.Closest(player); ok {
						if nav.SetGoal(goal) {
							log.Printf("nav: target %v (player %v, dist %d)",
								goal, player, manhattan(goal, player))
						}
					}
				}
			}

			wasHolding := holder.IsHolding()
			beforeC := holder.Completes
			if m, handled := holder.Adjust(pixels); handled {
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
				navMask, arrived := nav.Next(player)
				if arrived {
					if arrivedAt == 0 {
						arrivedAt = frames
						log.Printf("nav: arrived at %v (waiting for TaskHolder)", nav.Goal())
					}
					if frames-arrivedAt > navArrivedTimeoutFrames {
						log.Printf("nav: gave up on %v (no task fired in %d frames)",
							nav.Goal(), navArrivedTimeoutFrames)
						if _, idx, ok := memory.Closest(player); ok {
							memory.Forget(idx)
						}
						nav.Clear()
						arrivedAt = 0
					}
					mask = 0
				} else {
					arrivedAt = 0
					beforeP := bumper.Perturbs
					mask = bumper.Adjust(pixels, navMask)
					if bumper.Perturbs != beforeP {
						log.Printf("bumper: perturb #%d (frame %d, mask %#x)", bumper.Perturbs, frames, mask)
					}
				}
			} else {
				arrivedAt = 0
				beforeP := bumper.Perturbs
				mask = bumper.Adjust(pixels, Steer(pixels))
				if bumper.Perturbs != beforeP {
					log.Printf("bumper: perturb #%d (frame %d, mask %#x)", bumper.Perturbs, frames, mask)
				}
			}
		case PhaseVoting:
			mask = skipper.Next(pixels)
		default:
			mask = 0
		}

		if err := sendMask(mask); err != nil {
			log.Printf("send mask=%#x: %v", mask, err)
			return
		}
	}
}

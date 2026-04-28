package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/url"
	"os/signal"
	"syscall"

	"nhooyr.io/websocket"
)

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

	var (
		pixels       = make([]uint8, ScreenWidth*ScreenHeight)
		sentMask     uint8 // server already has 0 from the initial packet above
		currentPhase Phase
		havePhase    bool
		skipper      SkipController
		bumper       Bumper
		frames       uint64
	)

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
			beforeP := bumper.Perturbs
			mask = bumper.Adjust(pixels, Steer(pixels))
			if bumper.Perturbs != beforeP {
				log.Printf("bumper: perturb #%d (frame %d, mask %#x)", bumper.Perturbs, frames, mask)
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

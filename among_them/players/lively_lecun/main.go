package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/url"
	"os/signal"
	"syscall"
	"time"

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

	go keepAlive(ctx, conn)

	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	var frames uint64
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
		if frames%24 == 1 {
			var hist [16]int
			for _, p := range pixels {
				hist[p]++
			}
			log.Printf("frame %d palette=%v", frames, hist)
		}
	}
}

func keepAlive(ctx context.Context, conn *websocket.Conn) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := conn.Write(ctx, websocket.MessageBinary, BuildInputPacket(0)); err != nil {
				log.Printf("keep-alive: %v", err)
				return
			}
		}
	}
}

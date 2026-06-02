package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"nhooyr.io/websocket"
)

const (
	dialRetryDelay  = 250 * time.Millisecond
	dialLogInterval = 5 * time.Second
	summaryInterval = 5 * time.Second
)

type wsMessage struct {
	data     []byte
	received time.Time
}

func main() {
	urlFlag := flag.String("url", "", "full websocket URL to connect to")
	flag.Parse()

	// URL resolution priority: --url flag > COWORLD_PLAYER_WS_URL env > COGAMES_ENGINE_WS_URL env
	wsURL := *urlFlag
	if wsURL == "" {
		wsURL = os.Getenv("COWORLD_PLAYER_WS_URL")
	}
	if wsURL == "" {
		wsURL = os.Getenv("COGAMES_ENGINE_WS_URL")
	}
	if wsURL == "" {
		log.Fatal("no websocket URL: set --url flag, COWORLD_PLAYER_WS_URL, or COGAMES_ENGINE_WS_URL")
	}

	// Set up signal context
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Connect with retry
	conn := dialWebsocket(ctx, wsURL)
	defer conn.CloseNow()

	// Set read limit to 4MB (sprite definitions can be large)
	conn.SetReadLimit(4 * 1024 * 1024)

	// Send initial PlayerInput(0)
	err := conn.Write(ctx, websocket.MessageBinary, BuildPlayerInput(0))
	if err != nil {
		log.Fatalf("failed to send initial input: %v", err)
	}

	// Start reader goroutine
	var msgCount atomic.Uint64
	ch := make(chan wsMessage, 64)

	go func() {
		defer close(ch)
		for {
			typ, data, err := conn.Read(ctx)
			if err != nil {
				// Connection closed or context cancelled
				return
			}
			if typ != websocket.MessageBinary {
				continue
			}
			msgCount.Add(1)
			select {
			case ch <- wsMessage{data: data, received: time.Now()}:
			case <-ctx.Done():
				return
			}
		}
	}()

	// Main loop
	agent := NewAgent()
	var lastMask uint8
	var frameCount uint64
	lastSummary := time.Now()

	for msg := range ch {
		msgs, err := ParseMessages(msg.data)
		if err != nil {
			log.Printf("parse error: %v", err)
			continue
		}

		for _, m := range msgs {
			agent.ProcessMessage(m)
		}

		mask := agent.Step()
		frameCount++

		// Dedup: only send if mask changed
		if mask != lastMask {
			err = conn.Write(ctx, websocket.MessageBinary, BuildPlayerInput(mask))
			if err != nil {
				log.Printf("write error: %v", err)
				break
			}
			lastMask = mask
		}

		// Drain pending chat
		for {
			text, ok := agent.TakePendingChat()
			if !ok {
				break
			}
			err = conn.Write(ctx, websocket.MessageBinary, BuildInputText(text))
			if err != nil {
				log.Printf("write chat error: %v", err)
				break
			}
		}

		// Periodic performance summary
		if time.Since(lastSummary) >= summaryInterval {
			mc := msgCount.Load()
			log.Printf("perf: %d messages received, %d frames processed in last %.1fs",
				mc, frameCount, time.Since(lastSummary).Seconds())
			msgCount.Store(0)
			frameCount = 0
			lastSummary = time.Now()
		}
	}

	// Clean shutdown
	conn.Close(websocket.StatusNormalClosure, "shutdown")
	log.Println("shutdown complete")
}

func dialWebsocket(ctx context.Context, url string) *websocket.Conn {
	lastLog := time.Now().Add(-dialLogInterval) // log immediately on first attempt

	for {
		if time.Since(lastLog) >= dialLogInterval {
			log.Printf("connecting to %s ...", url)
			lastLog = time.Now()
		}

		conn, _, err := websocket.Dial(ctx, url, nil)
		if err == nil {
			log.Printf("connected to %s", url)
			return conn
		}

		select {
		case <-ctx.Done():
			log.Fatalf("connection cancelled: %v", ctx.Err())
		case <-time.After(dialRetryDelay):
		}
	}
}

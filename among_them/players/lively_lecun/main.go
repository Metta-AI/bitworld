package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"nhooyr.io/websocket"
)

const (
	dialRetryDelay  = 250 * time.Millisecond
	dialLogInterval = 5 * time.Second
)

func main() {
	mode := flag.String("mode", "ws", "I/O mode: 'ws' (websocket) or 'stdio' (8192-byte frames in, 1-byte masks out)")
	addr := flag.String("address", "localhost", "server address (ws mode)")
	port := flag.Int("port", 8080, "server port (ws mode)")
	name := flag.String("name", "lively_lecun", "player name (ws mode)")
	rawURL := flag.String("url", "", "full websocket URL (ws mode)")
	slot := flag.Int("slot", -1, "player slot index (ws mode)")
	token := flag.String("token", "", "player join token (ws mode)")
	if err := flag.CommandLine.Parse(normalizeArgs(os.Args[1:])); err != nil {
		log.Fatalf("parse flags: %v", err)
	}

	switch *mode {
	case "ws":
		if *rawURL == "" {
			*rawURL = strings.TrimSpace(os.Getenv("COGAMES_ENGINE_WS_URL"))
		}
		if *rawURL != "" {
			runWebsocketURL(playerURLWithQuery(*rawURL, "", *slot, *token))
		} else {
			runWebsocket(*addr, *port, *name, *slot, *token)
		}
	case "stdio":
		runStdio()
	default:
		log.Fatalf("unknown -mode=%q (want ws or stdio)", *mode)
	}
}

func normalizeArgs(args []string) []string {
	out := make([]string, 0, len(args))
	for _, arg := range args {
		if strings.HasPrefix(arg, "--") {
			if i := strings.IndexByte(arg, ':'); i > len("--") {
				arg = arg[:i] + "=" + arg[i+1:]
			}
		}
		out = append(out, arg)
	}
	return out
}

func runWebsocket(addr string, port int, name string, slot int, token string) {
	u := url.URL{
		Scheme: "ws",
		Host:   fmt.Sprintf("%s:%d", addr, port),
		Path:   "/player",
	}
	runWebsocketURL(playerURLWithQuery(u.String(), name, slot, token))
}

func playerURLWithQuery(
	rawURL string,
	name string,
	slot int,
	token string,
) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		log.Fatalf("parse websocket url: %v", err)
	}
	if u.Path == "" {
		u.Path = "/player"
	}
	values := u.Query()
	if name != "" {
		values.Set("name", name)
	}
	if slot >= 0 {
		values.Set("slot", strconv.Itoa(slot))
	}
	if token != "" {
		values.Set("token", token)
	}
	u.RawQuery = values.Encode()
	return u.String()
}

type receivedFrame struct {
	data     []byte
	received time.Time
}

const frameQueueSize = 64

func runWebsocketURL(rawURL string) {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	log.Printf("connecting to %s", rawURL)
	conn := dialWebsocket(ctx, rawURL)
	conn.SetReadLimit(1 << 20)

	if err := conn.Write(ctx, websocket.MessageBinary, BuildInputPacket(0)); err != nil {
		log.Fatalf("initial write: %v", err)
	}

	frames := make(chan receivedFrame, frameQueueSize)
	var framesReceived atomic.Int64

	// Reader goroutine: pulls from websocket as fast as possible.
	go func() {
		defer close(frames)
		for {
			kind, data, err := conn.Read(ctx)
			if err != nil {
				if ctx.Err() != nil {
					return
				}
				log.Printf("reader: %v", err)
				return
			}
			if kind != websocket.MessageBinary {
				continue
			}
			if len(data) != ProtocolBytes {
				continue
			}
			framesReceived.Add(1)
			frames <- receivedFrame{data: data, received: time.Now()}
		}
	}()

	agent := NewAgent()
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	var sentMask uint8
	framesSeen := 0
	closeStatus := websocket.StatusInternalError
	closeReason := "client error"
	defer func() {
		_ = conn.Close(closeStatus, closeReason)
	}()

	// Stats for periodic summary.
	var maxQueue int
	var maxStepDur time.Duration
	var maxLag time.Duration
	lastSummary := time.Now()
	lastRecv := framesReceived.Load()
	lastProcessed := 0
	const summaryInterval = 5 * time.Second

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

	for f := range frames {
		queued := len(frames)
		lag := time.Since(f.received)

		if err := UnpackFrame(f.data, pixels); err != nil {
			log.Printf("unpack: %v", err)
			continue
		}
		framesSeen++

		stepStart := time.Now()
		mask := agent.Step(pixels)
		stepDur := time.Since(stepStart)

		if err := sendMask(mask); err != nil {
			log.Printf("send mask=%#x: %v", mask, err)
			return
		}
		if msg, ok := agent.TakePendingChat(); ok {
			if err := conn.Write(ctx, websocket.MessageBinary, BuildChatPacket(msg)); err != nil {
				log.Printf("send chat %q: %v", msg, err)
				return
			}
			log.Printf("chat: %q", msg)
		}

		// Track peaks.
		if queued > maxQueue {
			maxQueue = queued
		}
		if stepDur > maxStepDur {
			maxStepDur = stepDur
		}
		if lag > maxLag {
			maxLag = lag
		}

		// Periodic summary.
		if time.Since(lastSummary) >= summaryInterval {
			now := time.Now()
			elapsed := now.Sub(lastSummary).Seconds()
			curRecv := framesReceived.Load()
			recvRate := float64(curRecv-lastRecv) / elapsed
			procRate := float64(framesSeen-lastProcessed) / elapsed
			log.Printf("perf: recv=%.1f/s proc=%.1f/s queue_max=%d step_max=%v lag_max=%v",
				recvRate, procRate, maxQueue, maxStepDur, maxLag)
			maxQueue = 0
			maxStepDur = 0
			maxLag = 0
			lastRecv = curRecv
			lastProcessed = framesSeen
			lastSummary = now
		}
	}

	if ctx.Err() != nil {
		log.Printf("shutdown: %v", ctx.Err())
		closeStatus = websocket.StatusNormalClosure
		closeReason = "bye"
	} else {
		log.Printf("connection closed (frames=%d)", framesSeen)
		closeStatus = websocket.StatusNormalClosure
		closeReason = "server closed"
	}
}

func dialWebsocket(ctx context.Context, rawURL string) *websocket.Conn {
	nextLog := time.Now()
	attempts := 0
	for {
		attempts++
		conn, _, err := websocket.Dial(ctx, rawURL, nil)
		if err == nil {
			if attempts > 1 {
				log.Printf("connected after %d attempts", attempts)
			}
			return conn
		}
		if ctx.Err() != nil {
			log.Fatalf("dial canceled: %v", ctx.Err())
		}
		now := time.Now()
		if attempts == 1 || now.After(nextLog) {
			log.Printf("waiting for websocket: %v", err)
			nextLog = now.Add(dialLogInterval)
		}
		timer := time.NewTimer(dialRetryDelay)
		select {
		case <-ctx.Done():
			timer.Stop()
			log.Fatalf("dial canceled: %v", ctx.Err())
		case <-timer.C:
		}
	}
}

// runStdio is the subprocess entry point used by the Python tournament
// wrapper. Protocol: read ProtocolBytes (8192) packed frame bytes from
// stdin, write one raw mask byte to stdout. Logs go to stderr.
//
// We don't dedupe masks here (unlike the websocket path): the Python
// wrapper needs a mask byte for every frame it sends so its
// request/response cycle stays lock-stepped.
func runStdio() {
	agent := NewAgent()
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	packed := make([]byte, ProtocolBytes)
	out := make([]byte, 1)

	stdin := os.Stdin
	stdout := os.Stdout
	log.SetOutput(os.Stderr)

	for {
		// io.ReadFull semantics: read exactly ProtocolBytes bytes, or
		// return on EOF/short-read. We do it inline to avoid pulling in
		// another package and because Read on stdin may return partial
		// reads under pressure.
		n := 0
		for n < len(packed) {
			r, err := stdin.Read(packed[n:])
			if r > 0 {
				n += r
			}
			if err != nil {
				if n == 0 {
					return // clean shutdown: parent closed stdin at EOF
				}
				log.Fatalf("stdio read: %v (got %d/%d)", err, n, len(packed))
			}
		}
		if err := UnpackFrame(packed, pixels); err != nil {
			log.Fatalf("stdio unpack: %v", err)
		}
		out[0] = agent.Step(pixels)
		if _, err := stdout.Write(out); err != nil {
			log.Fatalf("stdio write: %v", err)
		}
		// os.Stdout is unbuffered but the OS pipe still benefits from a
		// flush on some platforms; Sync is a no-op on pipes.
	}
}

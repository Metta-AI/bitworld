package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/url"
	"os"
	"os/signal"
	"syscall"

	"nhooyr.io/websocket"
)

func main() {
	mode := flag.String("mode", "ws", "I/O mode: 'ws' (websocket) or 'stdio' (8192-byte frames in, 1-byte masks out)")
	addr := flag.String("address", "localhost", "server address (ws mode)")
	port := flag.Int("port", 8080, "server port (ws mode)")
	name := flag.String("name", "lively_lecun", "player name (ws mode)")
	flag.Parse()

	switch *mode {
	case "ws":
		runWebsocket(*addr, *port, *name)
	case "stdio":
		runStdio()
	default:
		log.Fatalf("unknown -mode=%q (want ws or stdio)", *mode)
	}
}

func runWebsocket(addr string, port int, name string) {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	u := url.URL{
		Scheme:   "ws",
		Host:     fmt.Sprintf("%s:%d", addr, port),
		Path:     "/player",
		RawQuery: url.Values{"name": []string{name}}.Encode(),
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

	agent := NewAgent()
	pixels := make([]uint8, ScreenWidth*ScreenHeight)
	var sentMask uint8 // server already has 0 from the initial packet above

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
		mask := agent.Step(pixels)
		if err := sendMask(mask); err != nil {
			log.Printf("send mask=%#x: %v", mask, err)
			return
		}
		// Drain any pending chat (body reports, etc). Websocket-only:
		// the stdio protocol sends exactly one mask byte per input
		// frame, so chat goes out-of-band here.
		if msg, ok := agent.TakePendingChat(); ok {
			if err := conn.Write(ctx, websocket.MessageBinary, BuildChatPacket(msg)); err != nil {
				log.Printf("send chat %q: %v", msg, err)
				return
			}
			log.Printf("chat: %q", msg)
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

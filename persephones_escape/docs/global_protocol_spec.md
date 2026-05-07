# Global Protocol

The global websocket is served at `/global`.

The server sends binary global viewer frames using the same packed 4-bit framebuffer
format as player frames. A viewer may connect before or during an episode; it receives
an immediate frame on connect and then receives subsequent frames as the simulation
ticks.

The global websocket is read-only. Messages from viewers are ignored.

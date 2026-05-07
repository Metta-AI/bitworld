# Player Protocol

The tournament player websocket is served at `/player?slot=<slot>&token=<token>&...`.
`slot` is zero-based and `token` must match the runner-supplied token for that slot.
Invalid slot or token values are rejected during the websocket handshake.

The server sends binary player frames using the Bitworld packed framebuffer format:
128 by 128 pixels, two 4-bit palette indices per byte.

The player sends binary input packets:

- byte 0: packet type `0`
- byte 1: button bitmask

Button bits are:

- `1`: up
- `2`: down
- `4`: left
- `8`: right
- `16`: select
- `32`: A
- `64`: B

The player may also send chat packets:

- byte 0: packet type `1`
- remaining bytes: printable ASCII text

Tournament slots may reconnect with the same `slot` and `token`. While disconnected,
that slot advances with no-op input.

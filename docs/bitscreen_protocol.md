# Bitscreen Protocol

Bitscreen Protocol is a small websocket protocol for streaming a tiny indexed
color screen and receiving simple controller input.

The client connects to a websocket endpoint. The usual path is:

```text
/bitscreen
```

Game servers that expose player sessions usually use:

```text
/player
```

The player endpoint may accept a `name` query parameter:

```text
/player?name=player1
```

`name` is an optional player identity. Servers that support rewards or global
display should use this value instead of the network address when naming the
player. The value is URL decoded by the server. It must not contain spaces after
server normalization.

The protocol uses binary websocket messages.

## Screen

The server may send a complete screen frame to the client.

| Field | Type | Notes |
| --- | --- | --- |
| Pixels | `u8[]` | `128 * 128 / 2` bytes |

The screen is always `128x128` pixels. Each pixel is a 4 bit color index into
the Pico-8 palette, so each byte stores two pixels:

| Bits | Pixel |
| --- | --- |
| `0 .. 3` | Left pixel |
| `4 .. 7` | Right pixel |

Pixels are stored left to right, then top to bottom. A complete frame is `8192`
bytes.

The server usually sends frames at `24hz`, but the protocol does not require a
fixed frame rate. The server may send frames faster, slower, irregularly, or
only when the screen changes.

## Palette

Color indices `0 .. 15` use the Pico-8 palette:

| Index | Hex |
| ---: | --- |
| `0` | `#000000` |
| `1` | `#1d2b53` |
| `2` | `#7e2553` |
| `3` | `#008751` |
| `4` | `#ab5236` |
| `5` | `#5f574f` |
| `6` | `#c2c3c7` |
| `7` | `#fff1e8` |
| `8` | `#ff004d` |
| `9` | `#ffa300` |
| `10` | `#ffec27` |
| `11` | `#00e436` |
| `12` | `#29adff` |
| `13` | `#83769c` |
| `14` | `#ff77a8` |
| `15` | `#ffccaa` |

## Client Packets

The client may send binary packets. The first byte is the packet kind.

| Kind | Name | Notes |
| ---: | --- | --- |
| `0` | Buttons | Current controller state |
| `1` | Chat | ASCII chat message |

Unknown packet kinds should be ignored.

## Button Packet

The client may send a button packet containing the current controller state.

| Field | Type | Notes |
| --- | --- | --- |
| Packet | `u8` | Always `0` |
| Buttons | `u8` | One bit per button |

Each bit is `0` when the button is up and `1` when the button is down.

| Bit | Mask | Button |
| ---: | ---: | --- |
| `0` | `0x01` | Up |
| `1` | `0x02` | Down |
| `2` | `0x04` | Left |
| `3` | `0x08` | Right |
| `4` | `0x10` | Select |
| `5` | `0x20` | A |
| `6` | `0x40` | B |
| `7` | `0x80` | Reserved |

The reserved bit must be sent as `0`. A receiver should ignore the reserved bit
if it is set.

The client may send input whenever the state changes. The client may also resend
the latest state at any interval.

## Chat Packet

The client may send a chat packet containing an ASCII string.

| Field | Type | Notes |
| --- | --- | --- |
| Packet | `u8` | Always `1` |
| Text | `u8[]` | ASCII bytes |

Text should use printable ASCII bytes from `0x20` through `0x7e`. Empty chat
packets may be ignored. Games that do not support chat should ignore this
packet.

## Message Rules

A server-to-client binary message with length `8192` is a screen frame.

A client-to-server binary message with length `2` and first byte `0` is a
button packet.

A client-to-server binary message with first byte `1` is a chat packet.

Other binary messages should be ignored. Text websocket messages are not used by
this protocol.

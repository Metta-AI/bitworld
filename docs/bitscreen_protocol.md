# Bitscreen Protocol

Bitscreen Protocol is a small websocket protocol for streaming a tiny indexed
color screen and receiving simple controller input.

The client connects to a websocket endpoint. The usual path is:

```text
/bitscreen
```

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

## Input

The client may send a single byte containing the current controller state.

| Field | Type | Notes |
| --- | --- | --- |
| Buttons | `u8` | One bit per button |

Each bit is `0` when the button is up and `1` when the button is down.

| Bit | Mask | Button |
| ---: | ---: | --- |
| `0` | `0x01` | Up |
| `1` | `0x02` | Down |
| `2` | `0x04` | Left |
| `3` | `0x08` | Right |
| `4` | `0x10` | A |
| `5` | `0x20` | B |
| `6` | `0x40` | Select |
| `7` | `0x80` | Reserved |

The reserved bit must be sent as `0`. A receiver should ignore the reserved bit
if it is set.

The client may send input whenever the state changes. The client may also resend
the latest state at any interval.

## Message Rules

A server-to-client binary message with length `8192` is a screen frame.

A client-to-server binary message with length `1` is an input state.

Other binary message lengths are invalid in this version. Text websocket
messages are not used by this protocol.

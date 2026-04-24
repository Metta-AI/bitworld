# Sprite Protocol

Sprite Protocol is a small binary protocol for sprite based displays. The
server sends sprite definitions and object placements. The client sends keyboard
and mouse input.

Sprite Protocol connects over WebSocket. The endpoint usually lives at
`ws://address:port/sprite`.

The protocol is designed to be simple to parse. Every message starts with a
single message type byte, followed by a fixed set of little endian fields. Any
payload with variable length has its length encoded before the payload bytes.

## Integer Encoding

All integer fields are unsigned unless stated otherwise.

| Type | Size | Encoding |
| --- | ---: | --- |
| `u8` | 1 byte | Raw byte |
| `u16` | 2 bytes | Little endian |
| `i16` | 2 bytes | Little endian twos complement |
| `u32` | 4 bytes | Little endian |

Coordinates use `i16` so objects and pointer positions can be placed outside
the visible viewport.

## Server to Client Messages

### Define Sprite

Defines or replaces a sprite.

| Field | Type | Notes |
| --- | --- | --- |
| Message type | `u8` | `0x01` |
| Sprite id | `u16` | Id of the sprite to define |
| Width | `u16` | Sprite width in pixels |
| Height | `u16` | Sprite height in pixels |
| Pixels | `u8[]` | `Width * Height` bytes |

Each pixel is an 8 bit color index. The color palette is outside this version
of the protocol.

If a sprite id already exists, the client must replace the old sprite data with
the new definition. A sprite with width `0` or height `0` is invalid.

### Define Object

Defines or replaces an object instance.

| Field | Type | Notes |
| --- | --- | --- |
| Message type | `u8` | `0x02` |
| Object id | `u16` | Id of the object to define |
| X | `i16` | Object x position |
| Y | `i16` | Object y position |
| Z | `i16` | Object draw order |
| Sprite id | `u16` | Sprite used by the object |

If an object id already exists, the client must replace the old object state
with the new state. If the sprite id has not been defined yet, the client should
keep the object but draw nothing until the sprite is defined.

### Delete Object

Removes an object instance.

| Field | Type | Notes |
| --- | --- | --- |
| Message type | `u8` | `0x03` |
| Object id | `u16` | Id of the object to delete |

Deleting an unknown object id is a no-op.

### Clear Objects

Removes all object instances.

| Field | Type | Notes |
| --- | --- | --- |
| Message type | `u8` | `0x04` |

Sprite definitions remain loaded.

### Set Viewport

Sets the viewport size.

| Field | Type | Notes |
| --- | --- | --- |
| Message type | `u8` | `0x05` |
| Width | `u16` | Viewport width in pixels |
| Height | `u16` | Viewport height in pixels |

The viewport starts at `(0, 0)` and ends before `(Width, Height)`. A viewport
with width `0` or height `0` is invalid.

## Client to Server Messages

### Input Text

Sends one or more ASCII input bytes from the client.

| Field | Type | Notes |
| --- | --- | --- |
| Message type | `u8` | `0x81` |
| Length | `u16` | Number of ASCII bytes |
| Bytes | `u8[]` | ASCII bytes |

The client may send as many ASCII letters as it wants by using multiple input
text messages. Bytes in the printable ASCII range `0x20 .. 0x7e` represent typed
characters.

Bytes in the lower ASCII range `0x00 .. 0x1f` are reserved for control input.
The current control codes are:

| Code | Meaning |
| ---: | --- |
| `0x08` | Backspace |
| `0x09` | Tab |
| `0x0a` | Enter |
| `0x1b` | Escape |

Other lower ASCII codes are reserved for future keyboard, modifier, and mouse
button meanings.

### Mouse Position

Sends the current mouse position.

| Field | Type | Notes |
| --- | --- | --- |
| Message type | `u8` | `0x82` |
| X | `i16` | Mouse x position |
| Y | `i16` | Mouse y position |

The coordinate system is the same as object coordinates.

### Mouse Button

Sends a mouse button event using a lower ASCII control code.

| Field | Type | Notes |
| --- | --- | --- |
| Message type | `u8` | `0x83` |
| Code | `u8` | Lower ASCII control code |
| Down | `u8` | `0` for up, `1` for down |

Suggested mouse button control codes:

| Code | Meaning |
| ---: | --- |
| `0x01` | Left mouse button |
| `0x02` | Right mouse button |
| `0x03` | Middle mouse button |

## Message Type Summary

| Value | Direction | Message |
| ---: | --- | --- |
| `0x01` | Server to client | Define sprite |
| `0x02` | Server to client | Define object |
| `0x03` | Server to client | Delete object |
| `0x04` | Server to client | Clear objects |
| `0x05` | Server to client | Set viewport |
| `0x81` | Client to server | Input text |
| `0x82` | Client to server | Mouse position |
| `0x83` | Client to server | Mouse button |

Message values `0x00`, `0x06 .. 0x7f`, and `0x84 .. 0xff` are reserved.

## Rendering Model

The client keeps one viewport and two tables:

| State | Key | Value |
| --- | --- | --- |
| Viewport | None | Width and height |
| Sprites | `u16 sprite id` | Width, height, and 8 bit pixel buffer |
| Objects | `u16 object id` | X, y, z, and sprite id |

The client draws all objects using their current sprite. Objects with lower `z`
values are drawn first. If two objects have the same `z`, the object with the
lower `y` value is drawn first. If two objects have the same `z` and `y`, the
object with the lower object id is drawn first.

Objects outside the viewport are clipped. Pixels with screen coordinates less
than `0`, greater than or equal to the viewport width, or greater than or equal
to the viewport height are not drawn.

Pixel value `0` should be treated as transparent. Pixel values `1 .. 255` are
opaque palette indices.

## Error Handling

A receiver should close the connection on malformed messages, including:

- Unknown message types.
- Truncated messages.
- Sprite pixel payloads that do not match `Width * Height`.
- Sprite dimensions whose product cannot fit in local memory.
- Viewports with width `0` or height `0`.
- Boolean fields with values other than `0` or `1`.

Unknown object ids in delete messages are not errors.

## Example

This byte sequence defines sprite `7` as a `2x2` sprite with four palette
indices:

```text
01 07 00 02 00 02 00 01 02 03 04
```

Decoded fields:

| Bytes | Meaning |
| --- | --- |
| `01` | Define sprite |
| `07 00` | Sprite id `7` |
| `02 00` | Width `2` |
| `02 00` | Height `2` |
| `01 02 03 04` | Pixel data |

This byte sequence places object `3` at `x = 10`, `y = 20`, `z = 0`, using
sprite `7`:

```text
02 03 00 0a 00 14 00 00 00 07 00
```

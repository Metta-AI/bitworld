# Proposal: Define Encoded Sprite (0x08) for Sprite v1

To: Andre (treeform)
From: Alessandro Solbiati, with the prototype on branch `compressed-sprites`
of `SolbiatiAlessandro/bitworld`

## The problem, with numbers

Define Sprite (0x01) carries every sprite as raw RGBA, 4 bytes per pixel,
compressed with Snappy. Snappy is fast, but on flat pixel art it does not
remove much: it finds repeated 4-byte colors, not the structure of the image.

Heartleaf's director view sends 313 sprites in its init packet. The source art
for the whole game is about 600 KB of aseprite files (`map.aseprite` is
289 KB). The init packet was 7,487,421 bytes. The top of the table, measured
with `tools/init_packet_report.nim` in the heartleaf repo:

| id | label | size | wire bytes | raw RGBA | colors |
| ---: | --- | --- | ---: | ---: | ---: |
| 30 | forest underlay | 1708x1901 | 1,698,908 | 12,987,632 | 1629 |
| 1 | heartleaf bottom | 748x941 | 685,138 | 2,815,472 | 16 |
| 10..14 | heartleaf bottom tint 0..4 | 748x941 | 5 x ~680,000 | 2,815,472 each | 16 |
| 2 | heartleaf overhang | 748x941 | 164,407 | 2,815,472 | 17 |
| 15..19 | heartleaf overhang tint 0..4 | 748x941 | 5 x ~164,000 | 2,815,472 each | 17 |
| 4, 20..24 | home bottom and 5 tints | 251x247 | 6 x ~53,000 | 247,988 each | 16 |
| 8700 | chat banner | 318x60 | 29,353 | 76,320 | 1806 |
| 31..35 | forest dusk veil 0..4 | 512x256 | 5 x 24,650 | 524,288 each | 1 |

Three things stand out. First, a 16-color map costs 685 KB because Snappy sees
RGBA, not indices. Second, the game pre-composites five dusk tints of each
map, and each tint is a full copy, although a tint of 16 colors is just 16
different palette entries over the same index plane. All twenty tinted copies
(main bottom, main overhang, home bottom, home overhang, five stages each) are
per-color remaps of their four base sprites, and they cannot be replaced by a
flat overlay: the early stages rotate hue (grass stays green while paths warm),
so only the darkest stage approximates a veil. Third, Snappy has a floor on
constant-color sprites: a solid 748x941 overlay costs 132,208 bytes, and each
512x256 dusk veil above costs 24,650, so shaped or solid overlay sprites are
not cheap under the current codec either. The same solid 748x941 sprite is 725
bytes indexed and 2,772 bytes as deflated RGBA.

## The change

One new server-to-client message. The fields are Define Sprite's fields plus
one encoding byte in front of the payload length:

| Field | Type |
| --- | --- |
| Message type | `u8` = `0x08` |
| Sprite id | `u16` |
| Width | `u16` |
| Height | `u16` |
| Encoding | `u8` |
| Payload length | `u32` |
| Payload | `u8[]` |
| Label length | `u16` |
| Label | `u8[]` |

Encodings:

| Value | Payload |
| ---: | --- |
| `0x00` rgba-snappy | Snappy stream of raw RGBA. Identical to the 0x01 payload. |
| `0x01` rgba-deflate | zlib stream of raw RGBA. |
| `0x02` indexed | `u8` palette count minus one, `count * 4` RGBA palette bytes, then a zlib stream of one index byte per pixel. At most 256 colors. |
| `0x03` palette-swap | `u16` source sprite id, `u8` palette count minus one, `count * 4` RGBA palette bytes. The client reuses the index plane of the indexed sprite it already holds under the source id. |

A payload length of 0 is a pixel-free definition, same as 0x01. Every other
payload must decode to exactly `width * height * 4` bytes of straight RGBA.
The full text is in `docs/sprite_v1.md` on the branch.

0x07 was skipped because stag_hunt already sends 0x07 as a private identity
packet and both browser clients skip its two bytes. The spec now says so.

## Why this encoding and not PNG

I measured PNG (pixie's encoder, RGBA, no palette), zlib over raw RGBA,
palette plus run-length, and palette plus zlib on all 313 sprites:

| Encoding | Total bytes for the 313 sprites |
| --- | ---: |
| Snappy over RGBA (today) | 7,487,381 |
| PNG, RGBA color type | 3,765,210 |
| zlib over RGBA | 2,866,942 |
| palette + PackBits, PNG for >256 colors | 3,731,903 |
| palette + zlib, PNG for >256 colors | 2,195,573 |
| palette + zlib, zlib RGBA for >256 colors, palette swap for tints | 1,083,130 |

Indexed PNG (color type 3) would give the same bytes as "palette + zlib" and is
a standard container, but it costs the same decoder work in JavaScript (an
inflater plus PNG chunk and filter parsing on top), it cannot express the
palette swap, and the browser's native PNG decode is asynchronous and does not
return exact bytes for translucent pixels (canvas premultiplies alpha). The
custom payloads are two short reads on top of inflate, decode synchronously
inside the existing packet parser, and are pixel-exact in every client.

Snappy stays available as encoding 0x00 so a server can send the old payload
through the new message if it wants one code path.

## Results on the Heartleaf director view

Same 313 sprites, same pixels in every client:

| | Bytes |
| --- | ---: |
| Init packet, Define Sprite | 7,487,421 |
| Init packet, Define Encoded Sprite | 1,083,170 |

Per sprite, the big ones:

| id | label | encoding | before | after |
| ---: | --- | --- | ---: | ---: |
| 30 | forest underlay | rgba-deflate | 1,698,908 | 766,928 |
| 1 | heartleaf bottom | indexed | 685,138 | 189,608 |
| 10..14 | heartleaf bottom tint 0..4 | palette-swap | 5 x ~680,000 | 5 x 81 |
| 2 | heartleaf overhang | indexed | 164,407 | 13,918 |
| 15..19 | heartleaf overhang tint 0..4 | palette-swap | 5 x ~164,000 | 5 x 85 |
| 4 | heartleaf home bottom | indexed | 53,032 | 14,448 |
| 20..24 | home bottom tint 0..4 | palette-swap | 5 x ~53,000 | 5 x 81 |
| 8700 | chat banner | rgba-deflate | 29,353 | 17,435 |
| 31..35 | forest dusk veil 0..4 | indexed | 5 x 24,650 | 5 x 41 |

The twenty tints together went from about 4.5 MB to 1,660 bytes, with the
base sprites carrying the index planes once. The palette swap is exact: the
test suite decodes the encoded packet next to the legacy one and compares
every sprite byte for byte. Opening the director page in a browser against
this packet renders the map, forest, and clock through `spritecodec.js` with
no console errors.

The forest underlay is now 71% of the packet. It is generated at half
resolution and upscaled 2x on the server, has 1629 colors, and does not index.
Quantizing it to 4 bits per channel (123 colors) would bring it to 306 KB; that
is a Heartleaf art decision, not a protocol one. A protocol-level fix would be
an object or sprite scale factor so the server can send it at half size; that
is a separate proposal.

## Compatibility

- Define Sprite (0x01) is unchanged and still tested. A server that never sends
  0x08 is unaffected.
- A client that predates this change closes the connection on 0x08, which is
  the existing rule for unknown message types. A server should only send 0x08
  to clients it ships itself (the embedded browser clients, the native and
  wasm global client) or to clients that are known to be updated. Heartleaf
  serves its own copy of the bitworld browser client, so it upgrades both
  sides in one deploy.
- `parseSpritePacket` returns 0x08 messages as `spkSprite`, with `encoding`
  and the payload in `compressedPixels`. A legacy 0x01 message parses with
  `encoding = SpriteEncodingRgbaSnappy`, so code that switches on encoding
  handles both.
- Sprites Off clients get pixel-free definitions through either message.
- No change to the client-to-server direction, replays, or certification.

## What is on the branch

- `src/bitworld/spriteprotocol.nim`: constants, `encoding` on
  `SpritePacketSpriteDef`, `DecodedSprite`, `indexPixels`, the four payload
  encoders, `addEncodedSpritePayload`, `addEncodedSprite` (auto-picks indexed
  or rgba-deflate), `addPaletteSwapSprite` (falls back to a normal sprite when
  the recoloring is not consistent), `paletteSwapSourceId`, `decodeSprite`,
  parser and `spriteMessageBytes` cases for 0x08. zippy is already a
  dependency (pixie needs it); the module now imports it directly.
- `client/spritecodec.js`: an RFC 1950/1951 inflater (stored, fixed, and
  dynamic blocks, decoded against the known output length) plus
  `decodeSprite` and `readEncodedSprite`. About 250 lines, no dependencies.
- `client/global_client.html`, `client/player_client.html`: load
  `spritecodec.js` next to `snappyjs.min.js` and parse `0x08` next to `0x01`.
  Sprites keep `indices` and `palette` so a palette swap can find them.
- `client/global_client.nim`: the native and wasm renderer decodes 0x08 with
  `decodeSprite` and keeps the index plane on `GlobalSprite`.
- `src/bitworld/client.nim`: `/spritecodec.js`, `/client/spritecodec.js`, and
  `/clients/spritecodec.js` routes, embedded like the Snappy script.
- `docs/sprite_v1.md`: the message, encodings, error cases, and the 0x07 note.
- Tests: `tests/test_spriteencoding.nim` (round trips for every encoding,
  chained swaps, swap fallback, sizes, malformed payloads),
  `tests/test_spritecodec_js.nim` with `tests/spritecodec_check.js` (node
  decodes 11 sprites the Nim encoder wrote, including a legacy 0x01 message,
  and compares every byte; skipped when node is not installed),
  `tests/test_client.nim` (routes and parser cases).

## Server-side use

```nim
packet.addEncodedSprite(id, w, h, pixels, label)          # indexed or deflate
packet.addPaletteSwapSprite(tintId, id, w, h, pixels, tinted, label)
```

Heartleaf's branch `compressed-sprites` on `SolbiatiAlessandro/coworld-heartleaf`
switches its `addRgbaSprite` to `addEncodedSprite` and its map tints to
`addPaletteSwapSprite`, and adds a test that the encoded init packet decodes
pixel-identical to the legacy one. Dynamic sprites (name tags, speech bubbles,
cards) go through the same call and shrink too.

## Open points for you

1. Message value: 0x08 with 0x07 documented as taken by stag_hunt, or reclaim
   0x07 and move stag_hunt's identity packet.
2. Whether `SpriteEncodingRgbaSnappy` (0x00) is worth keeping in the new
   message or whether 0x08 should carry only the new payloads.
3. The inflater is hand-written in `spritecodec.js`. `DecompressionStream`
   exists in current browsers but is asynchronous, which would move sprite
   definitions out of the synchronous parse loop; I kept it synchronous.
4. Whether to add a scale factor to sprites or objects, which is what the
   forest underlay needs next.

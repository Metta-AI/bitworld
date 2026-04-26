# Bitreplay Spec

Bitreplay is a small binary replay format for deterministic lockstep Bitworld
games. A replay records the game identity, the expected hash for every
simulation tick, and the player inputs that happened since the start of the
game.

The format is designed to fail early when the replay does not belong to the
loaded game, and to fail exactly at the first tick where deterministic replay
diverges.

## Integer Encoding

All integer fields are unsigned unless stated otherwise.

| Type | Size | Encoding |
| --- | ---: | --- |
| `u8` | 1 byte | Raw byte |
| `u16` | 2 bytes | Little endian |
| `u32` | 4 bytes | Little endian |
| `u64` | 8 bytes | Little endian |

Strings are stored as UTF-8 bytes. Each string is encoded as a `u16` byte
length followed by that many bytes. Strings are not null terminated.

## File Layout

| Field | Type | Notes |
| --- | --- | --- |
| Header | `Header` | Replay identity and format data |
| Initial config | `string` | JSON object used to create game config |
| Records | `Record[]` | Tick hash and input records |

All records start with a single record type byte. Unknown record types are
invalid in this version.

## Header

The header must be the first bytes in the file.

| Field | Type | Notes |
| --- | --- | --- |
| Magic | `u8[8]` | ASCII `BITWORLD` |
| Format version | `u16` | Must be `2` |
| Game name | `string` | Name of the game |
| Game version | `string` | Version of the game |
| Start time | `u64` | Milliseconds since Unix epoch, or `0` |

The loader must compare `Game name` and `Game version` with the running game.
If either value does not match exactly, the game must not load the replay.

`Start time` is informational. The simulation must use input timestamps relative
to the start of the game, not wall clock time.

## Initial Config

The initial config must appear immediately after the header and before the
first record. It is encoded as a `string` containing a UTF-8 JSON object.

The config JSON must describe the game configuration used to create the replay.
A writer should store the complete effective config after applying defaults,
config files, and command line config values.

A loader must create the simulation config from the replay config JSON before
starting replay. Live config arguments must not change replay simulation
behavior. A game with no configurable gameplay state should write `{}`.

## Records

Records may appear in any order that keeps timestamps and ticks nondecreasing.
A writer should emit records in the order they happened.

| Value | Record |
| ---: | --- |
| `0x01` | Tick hash |
| `0x02` | Player input |
| `0x03` | Player join |
| `0x04` | Player leave |

### Tick Hash

Records the expected deterministic hash after a simulation tick has completed.

| Field | Type | Notes |
| --- | --- | --- |
| Record type | `u8` | `0x01` |
| Tick | `u32` | Tick index since the start of the game |
| Hash | `u64` | Game state hash after this tick |

The first tick is `0`. The hash must be calculated from deterministic game
state only. It must not include wall clock time, renderer state, socket state,
allocation addresses, or other process-local data.

During replay, the simulation must compute its own hash after each tick. If the
computed hash does not exactly match the recorded hash for that tick, replay
must stop with an error.

Tick hash records must be strictly increasing by tick. Missing ticks are
invalid because the replay cannot prove that the simulation stayed
deterministic for those ticks.

### Player Input

Records the complete input byte for one player at one time.

| Field | Type | Notes |
| --- | --- | --- |
| Record type | `u8` | `0x02` |
| Time | `u32` | Milliseconds since the start of the game |
| Player | `u8` | Player index |
| Keys | `u8` | One bit per key |

`Time` is an integer timestamp in milliseconds since the start of the game. A
replay player must deliver the input to the simulation at the same simulation
time. If several input records have the same timestamp, they must be applied in
file order.

`Keys` is the current complete key state for that player, not only the changed
bits. Each bit is `0` when the key is up and `1` when the key is down.

| Bit | Mask | Key |
| ---: | ---: | --- |
| `0` | `0x01` | Up |
| `1` | `0x02` | Down |
| `2` | `0x04` | Left |
| `3` | `0x08` | Right |
| `4` | `0x10` | A |
| `5` | `0x20` | B |
| `6` | `0x40` | Select |
| `7` | `0x80` | Reserved |

The reserved bit should be written as `0`. A loader should ignore the reserved
bit if it is set.

### Player Join

Records that a player joined the game.

| Field | Type | Notes |
| --- | --- | --- |
| Record type | `u8` | `0x03` |
| Time | `u32` | Milliseconds since the start of the game |
| Player | `u8` | Player index |
| Address | `string` | Player address or display name |

Player join records preserve player count, player order, and spawn order. A
loader must create the player before applying input for that player.

`Address` is informational. A game may use it for replay labels in the global
view.

### Player Leave

Records that a player left the game.

| Field | Type | Notes |
| --- | --- | --- |
| Record type | `u8` | `0x04` |
| Time | `u32` | Milliseconds since the start of the game |
| Player | `u8` | Player index |

A loader must remove the player before applying input for the same timestamp.
Removing a player shifts later player indices in the same way as the live game.

## Game Flags

Bitworld games should implement these command line flags:

| Flag | Meaning |
| --- | --- |
| `--save-replay:"filename"` | Save the current game as a replay file |
| `--load-replay:"filename"` | Load and play a replay file |

When `--save-replay` is set, the game should write a Bitreplay file while the
normal game is running. The replay should contain all player inputs and one hash
record for every simulation tick.

When `--load-replay` is set, the game should run from the replay file instead
of live player input. Connected player views should not do much during replay.
They may show a simple waiting, disabled, or replay message, but they should not
control the simulation.

The global view should display the full game as it happened. Games should
provide controls to scrub, stop, play, and change replay speed. The exact UI and
control scheme are game specific.

## Replay Rules

A loader must reject a replay when:

- The magic bytes are not `BITWORLD`.
- The format version is not supported.
- The game name does not match the running game.
- The game version does not match the running game.
- The initial config JSON is truncated or invalid for the game.
- A record is truncated.
- A record type is unknown.
- Tick hash records are missing or not strictly increasing.
- Player join records move backward in time.
- Player leave records move backward in time.
- Player input appears for a player before that player joins.
- Input timestamps move backward.
- The computed game hash does not match the recorded tick hash.

A replay should be deterministic across machines and builds that report the
same game name and game version. If deterministic behavior changes, the game
version must change too.

## Writer Rules

A writer should record:

- One header at the start of the file.
- One initial config JSON string after the header.
- One player join record whenever a player joins.
- One player leave record whenever a player leaves.
- One tick hash record for every simulation tick.
- One player input record whenever a player's key state changes.

A writer may also record repeated player input states. Repeated input states are
valid and should be treated the same as state changes.

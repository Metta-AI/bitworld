# Tools

Bitworld has a few small tools and clients around the game servers. The main
idea is that every game is still just a websocket server, but a server can now
be started with JSON config, recorded as a replay, viewed globally, and watched
through the reward stream.

## Game Servers

Each game server is a Nim executable in its game folder. Most player-facing
games listen on the player websocket path:

```text
/player
```

The player protocol sends a 128x128 indexed color screen from the server and
receives one byte of controller input from the client. See
[`bitscreen_protocol.md`](bitscreen_protocol.md) for the packet layout.

Many newer games also expose a global view:

```text
/global
```

The global protocol is used by map viewers, replay controls, and other full
game views. See [`global_protocol.md`](global_protocol.md) for the binary
message format.

Games that expose training rewards also listen on:

```text
/reward
```

The reward protocol streams text reward packets, one packet per simulation
tick. See [`reward_spec.md`](reward_spec.md) for the text format.

## JSON Config

Games can accept JSON at startup. The usual command line options are:

```text
--config:'{"port":8080}'
--config-file:config.json
```

The JSON must be an object. Fields override the game's default config. Unknown
fields are ignored by the current games, and fields with the wrong type raise a
game-specific error.

The common top-level server fields are:

| Field | Type | Meaning |
| --- | --- | --- |
| `address` | string | Host address to bind |
| `port` | integer | Port to listen on |
| `saveReplay` | string | Replay file to write |
| `loadReplay` | string | Replay file to load |
| `saveReplayPath` | string | Replay file to write |
| `loadReplayPath` | string | Replay file to load |

Individual games may add their own gameplay fields. For example, `among_them`
accepts values such as `motionScale`, `maxSpeed`, `killRange`,
`killCooldownTicks`, `minPlayers`, `tasksPerPlayer`, `showTaskArrows`, and
`showTaskBubbles`.

## Replays

Bitworld games can save and load deterministic replay files.

```text
--save-replay:run.bitreplay
--load-replay:run.bitreplay
```

Saving a replay records player joins, leaves, input changes, and one hash for
each simulation tick. Loading a replay runs the game from the replay file
instead of live player input.

Replay viewers should connect through `/global`. Games can expose replay
controls there for play, pause, seek, loop, and speed changes. See
[`bitreplay_spec.md`](bitreplay_spec.md) for the file format and replay rules.

## Quick Run

`quick_run` is the main local development launcher. It compiles the selected
game server, compiles the native player client, starts the server, waits for it
to listen, and then starts one or more clients.

```powershell
.\tools\quick_run.exe fancy_cookout
.\tools\quick_run.exe fancy_cookout 8080
.\tools\quick_run.exe free_chat --players:2
.\tools\quick_run.exe fancy_cookout 8080 --players:4
```

Useful options:

| Option | Meaning |
| --- | --- |
| `--players:N` | Launch `N` local player clients |
| `--address:ADDR` | Bind the game server to an address |
| `--save-replay:PATH` | Save a replay while running |

When multiple players are requested, `quick_run` opens screen-only clients in a
simple desktop layout and assigns joystick numbers in player order. See
[`quick_run.md`](quick_run.md) for details.

## Player Clients

There are two simple player clients.

The native client lives at:

```text
clients/player_client.nim
```

It connects to the player protocol and is what `quick_run` launches. It is best
for normal local development and gamepad testing.

Pass `--reconnect:5` to make it reconnect every five seconds after a disconnect.
Reconnect is off by default.

The HTML player client lives at:

```text
clients/player_client.html
```

It is a tiny browser client for the same `/player` protocol. It accepts an
`address` query parameter:

```text
clients/player_client.html?address=ws://localhost:8080/player
```

Add `reconnect=5` to make it reconnect every five seconds after a disconnect.
Reconnect is off by default.

This is useful when testing the protocol from a browser or sharing a minimal
client with another tool.

## Global Client

The HTML global client lives at:

```text
clients/global_client.html
```

It connects to `/global` and renders the global protocol. It also sends mouse
and keyboard input back to the server, which lets games implement global UI and
replay transport controls.

```text
clients/global_client.html?address=ws://localhost:8080/global
```

Add `reconnect=5` to make it reconnect every five seconds after a disconnect.
Reconnect is off by default.

## Reward Client

The HTML reward client lives at:

```text
clients/reward_client.html
```

It connects to `/reward` and shows the latest reward packet as text.

```text
clients/reward_client.html?address=ws://localhost:8080/reward
```

Add `reconnect=5` to make it reconnect every five seconds after a disconnect.
Reconnect is off by default.

This client is intentionally small. It is mainly for checking that a game is
emitting reward data in the format expected by training tools.

## Client Assets

Shared client art and UI assets live at:

```text
clients/data
```

The native player client writes its generated atlas here:

```text
clients/dist/atlas.png
```

## Other Tools

`ptswap` is a palette utility in `tools/ptswap.nim`. It converts image colors
through the Bitworld palette workflow used by some art assets.

The `overworld` executable can scan the game folders and provide a simple entry
point for launching or browsing the available games.

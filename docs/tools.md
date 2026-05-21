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

The bitscreen protocol sends a 128x128 indexed color screen from the server and
receives one byte of controller input from the client. See
[`bitscreen_v1.md`](bitscreen_v1.md) for the packet layout.

Many newer games also expose a global view:

```text
/global
```

The sprite protocol is used by map viewers, replay controls, and other full
game views. See [`sprite_v1.md`](sprite_v1.md) for the
binary message format.

Replay mode exposes:

```text
/replay
```

Games that expose training rewards also listen on:

```text
/reward
```

Reward v1 streams text reward packets, one packet per simulation
tick. See [`reward_v1.md`](reward_v1.md) for the text format.

## JSON Config

Games can accept JSON at startup. The usual command line options are:

```text
--config:'{"port":8080}'
--config-file:config.json
```

The JSON must be an object. Fields override the game's default config. Unknown
fields are ignored by the current games, and fields with the wrong type raise a
game-specific error.

Game runners may also set:

| Environment variable | Meaning |
| --- | --- |
| `COGAME_CONFIG_URI` | URI for the config JSON file |
| `COGAME_RESULTS_URI` | URI where the game writes final results |
| `COGAME_SAVE_REPLAY_URI` | Optional URI where the game writes a replay |
| `COGAME_LOAD_REPLAY_URI` | Optional URI for a replay artifact to load |

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

### Persephone's Escape (TypeScript)

Persephone's Escape is a TypeScript game run with `tsx` and uses a different
CLI convention from the Nim games.  Flags use `--key=value` syntax (not
`--key:value`), and config is split into two mutually exclusive options:

```text
--config=NAME          Select a built-in config preset by name
--config-file=PATH     Load a GameConfig from a JSON file
```

Available presets are defined in `persephones_escape/game/config_presets.ts`
(e.g. `default`, `fast`, `tiny`, `short`, `empty`, `simple`, `empty3`,
`medium`).  JSON config files use the same `GameConfig` shape; role and team
values may be strings (`"Hades"`, `"TeamA"`) or numeric enum ordinals.

Other server flags: `--address=HOST`, `--port=PORT`, `--seed=N`,
`--replay=PATH`.  See the doc comment at the top of
`persephones_escape/server.ts` for full usage details.

## Replays

Bitworld games can save and load deterministic replay files.

```text
--save-replay:run.bitreplay
--load-replay:run.bitreplay
```

Saving a replay records player joins, leaves, input changes, and one hash for
each simulation tick. Loading a replay runs the game from the replay file
instead of live player input.

Replay viewers should connect through `/replay`. Games can expose replay
controls there for play, pause, seek, loop, and speed changes. See
[`bitreplay_spec.md`](bitreplay_spec.md) for the file format and replay rules.

## Quick Run

`quick_run` is the main local development launcher. It can compile and start a
game server, open local human clients, open a global viewer, and launch Nim bot
players.

```powershell
.\tools\quick_run.exe fancy_cookout
.\tools\quick_run.exe free_chat --players:2
.\tools\quick_run.exe among_them --players:2 --bots:nottoodumb:6
.\tools\quick_run.exe planet_wars --bots:skurge:4 --global --html
.\tools\quick_run.exe among_them --connect --port:2000 --bots:nottoodumb:8
```

Useful options:

| Option | Meaning |
| --- | --- |
| `--players:N` | Launch `N` local human clients |
| `--bots:BOT:N` | Launch `N` bots from the selected game's players folder |
| `--global` | Open the global viewer and default humans to zero |
| `--html` | Use the browser global viewer with `--global` |
| `--connect` | Connect to an existing server instead of starting one |
| `--address:ADDR` | Bind address in start mode, host in connect mode |
| `--port:N` | Server port |
| `--bot-gui` | Pass `--gui` to launched bots |
| `--bot-name-prefix:NAME` | Name bots `NAME1`, `NAME2`, and so on |
| `--bot-map:PATH` | Pass `--map:PATH` to launched bots |
| `--save-replay:PATH` | Save a replay from the started server |

Unknown options are passed to the game server when `quick_run` starts it. When
multiple human players are requested, `quick_run` opens screen-only clients in
a simple desktop layout and assigns joystick numbers in player order. See
[`quick_run.md`](quick_run.md) for details.

## Player Clients

There are two simple player clients.

The native client lives at:

```text
clients/player_client.nim
```

It connects to the bitscreen protocol and is what `quick_run` launches. It is
best for normal local development and gamepad testing.

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

The native global client lives at:

```text
clients/global_client.nim
```

It opens a resizable Silky window, connects to `/global`, renders the global
protocol, and sends mouse and keyboard input back to the server. It uses the
same shared atlas as the other native clients.

The HTML global client lives at:

```text
clients/global_client.html
```

It connects to `/global`, or to `/replay` when served from the replay route,
and is useful when testing the protocol from a browser.

```text
clients/global_client.html?address=ws://localhost:8080/global
```

Add `reconnect=5` to make it reconnect every five seconds after a disconnect.
Reconnect is off by default.

## Reward Client

The native reward client lives at:

```text
clients/reward_client.nim
```

It opens a small Silky window and connects to `/reward` to show the latest
reward packet as text.

The HTML reward client lives at:

```text
clients/reward_client.html
```

It connects to the same `/reward` endpoint and shows the latest reward packet
as text.

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

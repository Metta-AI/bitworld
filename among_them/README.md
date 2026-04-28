# Among Them

Among Them is a Bit World social deduction game set on the Skeld. Crewmates
complete tasks, report bodies, chat during meetings, and vote out suspects.
Imposters try to blend in, use cooldown-limited kills, and survive the vote.

The server hosts the player client, global viewer, and rewards viewer as static
pages.

## Run The Server

From the game folder:

```sh
cd /Users/me/p/bitworld/among_them
nim r among_them.nim --address:0.0.0.0 --port:2000 --config:'{"minPlayers":8,"imposterCount":2,"tasksPerPlayer":6,"imposterCooldownTicks":1200,"voteTimerTicks":360}'
```

Useful config fields:

- `minPlayers`: Number of players required before the game starts.
- `imposterCount`: Number of imposters.
- `tasksPerPlayer`: Number of tasks assigned to each crewmate.
- `imposterCooldownTicks`: Kill cooldown. This is the same as `killCooldownTicks`.
- `voteTimerTicks`: Voting duration in ticks. At 24 FPS, 360 ticks is 15 seconds.
- `buttonCalls`: Emergency button calls allowed per player.

You can also load config from a file:

```sh
nim r among_them.nim --address:0.0.0.0 --port:2000 --config-file:config.json
```

For the first test, it is useful to run one player with one task and no
imposters. With no imposters, the crewmate only needs to complete all tasks to
win.

```sh
nim r among_them.nim --address:0.0.0.0 --port:2000 --config:'{"minPlayers":1,"imposterCount":0,"tasksPerPlayer":1}'
```

## Browser Clients

The server serves these pages:

- Player: `http://localhost:2000/client/player.html`
- Global viewer: `http://localhost:2000/client/global.html`
- Rewards: `http://localhost:2000/client/rewards.html`

These routes are served from:

- `clients/player_client.html`
- `clients/global_client.html`
- `clients/reward_client.html`

The player client connects to `/player`, the global viewer connects to
`/global`, and the rewards viewer connects to `/reward` on the same host as
the page.

## Run AI Players

Run tool commands from the repo root:

```sh
cd /Users/me/p/bitworld
```

Start one AI player first. This is useful with `minPlayers:1`,
`imposterCount:0`, and `tasksPerPlayer:1` while testing.

```sh
nim r tools/quick_player nottoodumb --players:1 --address:localhost --port:2000
```

Then start several AI players at once:

```sh
nim r tools/quick_player nottoodumb --players:8 --address:localhost --port:2000
```

Useful `quick_player` options:

- `--players:N`: Number of bots to start.
- `--gui`: Open the bot debug viewer windows.
- `--name-prefix:NAME`: Name bots `NAME1`, `NAME2`, and so on.

Example with debug windows:

```sh
nim r tools/quick_player nottoodumb --players:2 --address:localhost --port:2000 --gui
```

## Quick Local Run

Use `quick_run` to launch the server and native local clients together. This is
best for fast manual testing with human-controlled windows.
Run it from the repo root:

```sh
cd /Users/me/p/bitworld
nim r tools/quick_run among_them --address:0.0.0.0 --port:2000 --players:4
```

Use `--port` for the server port and `--address` for the server bind address.

```sh
nim r tools/quick_run among_them --address:0.0.0.0 --port:2000 --players:2
```

You can save a replay while using `quick_run`:

```sh
nim r tools/quick_run among_them --address:0.0.0.0 --port:2000 --players:2 --save-replay:among_them.replay
```

## Common Setup

Start an 8-player game with two imposters:

```sh
cd /Users/me/p/bitworld/among_them
nim r among_them.nim --address:0.0.0.0 --port:2000 --config:'{"minPlayers":8,"imposterCount":2,"tasksPerPlayer":6,"imposterCooldownTicks":1200,"voteTimerTicks":360}'
```

In another terminal, start 8 AI players:

```sh
cd /Users/me/p/bitworld
nim r tools/quick_player nottoodumb --players:8 --address:localhost --port:2000
```

Then open the global viewer:

```text
http://localhost:2000/client/global.html
```

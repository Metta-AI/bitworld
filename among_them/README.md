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
- `mapPath`: Map JSON file to load. The default is `map.json`.

You can also load config from a file:

```sh
nim r among_them.nim --address:0.0.0.0 --port:2000 --config-file:config.json
```

The same config file can be provided through the environment:

```sh
COGAME_CONFIG_PATH=config.json nim r among_them.nim --address:0.0.0.0 --port:2000
```

For the first test, it is useful to run one player with one task and no
imposters. With no imposters, the crewmate only needs to complete all tasks to
win.

```sh
nim r among_them.nim --address:0.0.0.0 --port:2000 --config:'{"minPlayers":1,"imposterCount":0,"tasksPerPlayer":1}'
```

You can also build and run docker images for the game and the player:

Game: `docker run --rm --name among_them -p 2000:2000 $(docker load -q -i $(nix build .#dockerImageAmongThem --print-out-paths --quiet --no-link --out-link dockerImageAmongThem.tar.gz) | sed -n 's/^Loaded image: //p') among_them --address:0.0.0.0 --port:2000 --config:'{"minPlayers":1,"imposterCount":0,"tasksPerPlayer":1}'`

Player: `docker run --rm --name nottoodumb --network=host $(docker load -q -i $(nix build .#dockerImageNottoodumb --print-out-paths --quiet --no-link --out-link dockerImageNottoodumb.tar.gz) | sed -n 's/^Loaded image: //p') nottoodumb --url:ws://localhost:2000 --name:player1`

## Runner Environment

Tournament and Cogame runners can configure file paths with environment
variables. Command line flags override these values when both are set.

| Variable | Meaning |
| --- | --- |
| `COGAME_CONFIG_PATH` | Path to the config JSON file |
| `COGAME_SAVE_RESULTS_PATH` | Path where final scores are written |
| `COGAME_SAVE_REPLAY_PATH` | Optional path where a replay is written |

Results are written when `maxGames` is set to 1 or higher.

```sh
COGAME_CONFIG_PATH=config.json \
COGAME_SAVE_RESULTS_PATH=scores.json \
COGAME_SAVE_REPLAY_PATH=run.bitreplay \
nim r among_them.nim --address:0.0.0.0 --port:2000
```

## Map Files

The default map is `map.json`. It controls the Skeld image, Aseprite layer
indices, task stations, vents, emergency button rectangle, meeting home point,
and room names used by the bots.
Map images currently need to be `952x534`.

Use a different map with `--map`:

```sh
nim r among_them.nim --address:0.0.0.0 --port:2000 --map:map.json
```

Or set it in config:

```sh
nim r among_them.nim --address:0.0.0.0 --port:2000 --config:'{"mapPath":"map.json","minPlayers":8}'
```

## Browser Clients

The server serves these pages:

- Player: `http://localhost:2000/client/player.html`
- Global viewer: `http://localhost:2000/client/global.html`
- Rewards: `http://localhost:2000/client/rewards.html`
- Stats and join QR: `http://localhost:2000/client/stats.html`

These routes are served from:

- `player_client/index.html`
- `global_client/index.html`
- `reward_client/index.html`

The player client connects to `/player`, the global viewer connects to
`/global`, and the rewards viewer connects to `/reward` on the same host as
the page.

The stats page also exposes live match controls. Use `Restart match` to queue a
new match with the current connected players, or the `X` beside a connected
player to kick that player from the game.

## Run AI Players

Run tool commands from the repo root:

```sh
cd /Users/me/p/bitworld
```

The default starter policy for `quick_player` is **`evidencebot_v2`**
(`among_them/players/evidencebot_v2.nim`): same perception stack as the older
bots, with evidence-grounded voting and improved crewmate task throughput. For a
smaller baseline implementation, use **`nottoodumb`**.

Start one AI player first. This is useful with `minPlayers:1`,
`imposterCount:0`, and `tasksPerPlayer:1` while testing.

```sh
nim r tools/quick_player evidencebot_v2 --players:1 --address:localhost --port:2000
```

Then start several AI players at once:

```sh
nim r tools/quick_player evidencebot_v2 --players:8 --address:localhost --port:2000
```

Useful `quick_player` options:

- `--players:N`: Number of bots to start.
- `--gui`: Open the bot debug viewer windows.
- `--name-prefix:NAME`: Name bots `NAME1`, `NAME2`, and so on.
- `--map:PATH`: Load the same map JSON as the server.

Example with debug windows:

```sh
nim r tools/quick_player evidencebot_v2 --players:2 --address:localhost --port:2000 --gui
```

When testing a custom map, pass the same map to the bots:

```sh
nim r tools/quick_player evidencebot_v2 --players:8 --address:localhost --port:2000 --map:among_them/map.json
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

You can also set `COGAME_SAVE_REPLAY_PATH` before running the server.

## Common Setup

Start an 8-player game with two imposters:

```sh
cd /Users/me/p/bitworld/among_them
nim r among_them.nim --address:0.0.0.0 --port:2000 --config:'{"minPlayers":8,"imposterCount":2,"tasksPerPlayer":6,"imposterCooldownTicks":1200,"voteTimerTicks":360}'
```

In another terminal, start 8 AI players:

```sh
cd /Users/me/p/bitworld
nim r tools/quick_player evidencebot_v2 --players:8 --address:localhost --port:2000
```

Then open the global viewer:

```text
http://localhost:2000/client/global.html
```

## Slots setup for tournament runner.

Names and tokens are not optional, but role and color are game specific.
The `tokens` array matches `slots` by index, so `tokens[0]` belongs to
`slots[0]`.

Example config.json:

```json
{
  "maxGames":1,
  "imposterCooldownTicks":100,
  "tokens":[
    "0xBADA55_0",
    "0xBADA55_1",
    "0xBADA55_2",
    "0xBADA55_3",
    "0xBADA55_4",
    "0xBADA55_5",
    "0xBADA55_6",
    "0xBADA55_7"
  ],
  "slots":[
    {"name":"player1","role":"crewmate","color":"red"},
    {"name":"player2","role":"crewmate","color":"blue"},
    {"name":"player3","role":"crewmate","color":"green"},
    {"name":"player4","role":"crewmate","color":"yellow"},
    {"name":"player5","role":"crewmate","color":"lime"},
    {"name":"player6","role":"crewmate","color":"cyan"},
    {"name":"player7","role":"imposter","color":"pink"},
    {"name":"player8","role":"imposter","color":"orange"}
  ]
}
```

```sh
nim r among_them.nim --address:0.0.0.0 --port:2000 --save-scores:scores.json --config-file:config.json
```

If the game has a slots config, then the player *MUST* use the slot count.
They *MAY* use the name and token.

http://localhost:2000/client/player.html?name=player1&token=0xBADA55_0&slot=0
http://localhost:2000/client/player.html?name=player2&token=0xBADA55_1&slot=1
http://localhost:2000/client/player.html?name=player3&token=0xBADA55_2&slot=2
http://localhost:2000/client/player.html?name=player4&token=0xBADA55_3&slot=3
http://localhost:2000/client/player.html?name=player5&token=0xBADA55_4&slot=4
http://localhost:2000/client/player.html?name=player6&token=0xBADA55_5&slot=5
http://localhost:2000/client/player.html?name=player7&token=0xBADA55_6&slot=6
http://localhost:2000/client/player.html?name=player8&token=0xBADA55_7&slot=7

When a game finishes with `maxGames` set to 1 or higher, `--save-scores` saves
the scores to a file. `COGAME_SAVE_RESULTS_PATH` can be used instead.

The file uses JSON format and must be an array of objects with `reward` as a
required field. The game can include `name`, `win`, `tasks`, `kills`, and other
fields.

```json
[
  {"name": "player1", "reward": 8, "win": false, "tasks": 8, "kills": 0},
  {"name": "player2", "reward": 8, "win": false, "tasks": 8, "kills": 0},
  {"name": "player3", "reward": 7, "win": false, "tasks": 7, "kills": 0},
  {"name": "player4", "reward": 6, "win": false, "tasks": 6, "kills": 0},
  {"name": "player5", "reward": 8, "win": false, "tasks": 8, "kills": 0},
  {"name": "player6", "reward": 8, "win": false, "tasks": 8, "kills": 0},
  {"name": "player7", "reward": 160, "win": true, "tasks": 0, "kills": 6},
  {"name": "player8", "reward": 130, "win": true, "tasks": 0, "kills": 3}
]
```


## Note for usability

Don't run things from the executable like `./among_them ...`. Run the `nim r among_them.nim ...` always.

# Among Them

Among Them is an uploaded Coworld social deduction game. Crewmates complete
tasks, report bodies, chat during meetings, and vote out suspects. Imposters
blend in, use cooldown-limited kills, and survive the vote.

Most players do not need this repository. The public path is:

1. write a player process that connects to `COGAMES_ENGINE_WS_URL`;
2. package it as a Linux Docker image;
3. upload it with `coworld upload-policy`;
4. submit it with `coworld submit`.

The game source in this directory is useful when developing the game container,
debugging the protocol, or studying the reference bots. Treat it as a source
reference, not as a prerequisite for competing.

## Coworld Contract

Among Them follows the Coworld package contract defined by Metta's `coworld`
package:

- Coworld spec:
  <https://github.com/Metta-AI/metta/blob/main/packages/coworld/src/coworld/COWORLD_README.md>
- Cogame runtime spec:
  <https://github.com/Metta-AI/metta/blob/main/packages/coworld/src/coworld/COGAME_README.md>
- Runner contract:
  <https://github.com/Metta-AI/metta/blob/main/packages/coworld/src/coworld/runner/RUNNER_README.md>

The uploaded Coworld manifest is `among_them/coworld_manifest.json`. It defines
the game image, the default eight-player, two-imposter tournament variant with
eight tasks per crewmate, the certification fixture, public protocol docs, and
the public pages that Observatory renders for the uploaded Coworld.

Coworld uploads store documentation as public URLs. They do not bundle local
Markdown files into the uploaded manifest, so keep the manifest docs links
pointing at public pages that policy authors and coding agents can read without
a BitWorld checkout.

## Player Runtime

In hosted Coworld episodes, Softmax runs the game container and each policy
container separately. Each policy container receives:

```text
COGAMES_ENGINE_WS_URL=ws://<game-service>:8080/player?slot=<slot>&token=<token>
```

Connect to that URL exactly as supplied. The runner owns slot assignment and
token generation. Do not hardcode a slot, guess a token, or connect to a local
BitWorld server in hosted play.

The player websocket uses Bitscreen v1:

- Player protocol:
  <https://github.com/Metta-AI/bitworld/blob/master/docs/bitscreen_v1.md>
- Global/replay viewer protocol:
  <https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md>

A player can be written in any language as long as its container starts the
player process, connects to `COGAMES_ENGINE_WS_URL`, reads frames, and sends
valid button or chat packets.

## Playing And Submitting

Use the public play prompt for the current CLI install and submit flow:

```text
https://softmax.com/play_amongthem.md
```

The durable command shape is:

```sh
softmax login
docker buildx build --platform linux/amd64 -t my-among-them-policy:latest --load .
coworld upload-policy my-among-them-policy:latest --name my-policy
coworld submit my-policy:v1 --league <among-them-league-id>
```

If a policy needs API keys or other credentials at runtime, attach them to the
policy version with `coworld upload-policy --secret-env KEY=VALUE`. Do not bake
secrets into the image.

For policy design and packaging details, see:

- `players/how_to_make_a_bot.md`
- `players/how_to_submit_coworld_policy.md`
- `players/SMART_BOT_GUIDE.md`

These same pages are exposed from the Coworld manifest as `player.md`,
`submit.md`, and `optimizer.md`.

## Source Development

The remaining sections are for BitWorld source development. They are useful for
running the game locally, changing game mechanics, or debugging the reference
players, but they are not required for uploaded Coworld play.

### Run The Server

From the game folder:

```sh
cd /path/to/bitworld/among_them
nim r among_them.nim --address:0.0.0.0 --port:2000 --config:'{"minPlayers":8,"imposterCount":2,"tasksPerPlayer":8,"killCooldownTicks":900,"voteTimerTicks":6000}'
```

Useful config fields:

- `minPlayers`: number of players required before the game starts.
- `imposterCount`: number of imposters.
- `tasksPerPlayer`: number of tasks assigned to each crewmate.
- `killCooldownTicks`: kill cooldown.
- `voteTimerTicks`: voting duration in ticks. At 24 FPS, 6000 ticks is 250 seconds.
- `buttonCalls`: emergency button calls allowed per player.
- `mapPath`: map JSON file to load. The default is `map.json`.

You can also load config from a file:

```sh
nim r among_them.nim --address:0.0.0.0 --port:2000 --config-file:config.json
```

The same config file can be provided through the Coworld runner environment:

```sh
COGAME_CONFIG_URI=file://$PWD/config.json nim r among_them.nim --address:0.0.0.0 --port:2000
```

For the first source-level test, it is useful to run one player with one task
and no imposters:

```sh
nim r among_them.nim --address:0.0.0.0 --port:2000 --config:'{"minPlayers":1,"imposterCount":0,"tasksPerPlayer":1}'
```

### Runner Environment

Coworld runners configure file URIs with environment variables. Command-line
flags override these values when both are set.

| Variable | Meaning |
| --- | --- |
| `COGAME_CONFIG_URI` | URI for the config JSON file |
| `COGAME_RESULTS_URI` | URI where final scores are written |
| `COGAME_SAVE_REPLAY_URI` | Optional URI where a replay is written |
| `COGAME_LOAD_REPLAY_URI` | Optional URI for a replay to load |

Results are written when `maxGames` is set to 1 or higher.

```sh
COGAME_CONFIG_URI=file://$PWD/config.json \
COGAME_RESULTS_URI=file://$PWD/scores.json \
COGAME_SAVE_REPLAY_URI=file://$PWD/run.bitreplay \
nim r among_them.nim --address:0.0.0.0 --port:2000
```

### Coworld Certification

Certification is for Coworld authors changing the game package. From the
repository root, build the local game and baseline player images before running
the certifier:

```sh
docker build \
  --platform=linux/amd64 \
  -f among_them/Dockerfile \
  -t ghcr.io/treeform/bitworld-among-them-runner:latest \
  .
docker build \
  --platform=linux/amd64 \
  -f among_them/players/nottoodumb/Dockerfile \
  -t ghcr.io/treeform/bitworld-nottoodumb:latest \
  .
coworld certify among_them/coworld_manifest.json
```

Upload the certified Coworld with:

```sh
coworld upload-coworld among_them/coworld_manifest.json
```

For the full production release flow from BitWorld `master`, including GHCR
image pushes, Coworld certification/upload, and hosted replay viewer upload,
run:

```sh
among_them/upload.sh 0.1.24
```

### Browser Clients

The game container serves these routes:

- Player: `http://localhost:2000/clients/player?slot=0&token=...`
- Global viewer: `http://localhost:2000/clients/global`
- Replay viewer: `http://localhost:2000/clients/replay`
- Admin panel: `http://localhost:2000/clients/admin`
- Rewards: `http://localhost:2000/clients/rewards`

The clients connect to the game-owned websocket routes on the same host:
`/player`, `/global`, `/replay`, `/admin`, and `/reward`.

### Run Local AI Players

Run tool commands from the repo root:

```sh
cd /path/to/bitworld
```

The default source-level starter policy is `evidencebot_v2`
(`among_them/players/evidencebot_v2.nim`). For a smaller baseline, use
`nottoodumb`.

Start one AI player:

```sh
nim r tools/quick_run among_them --connect --bots:evidencebot_v2:1 --address:localhost --port:2000
```

Start several AI players:

```sh
nim r tools/quick_run among_them --connect --bots:evidencebot_v2:8 --address:localhost --port:2000
```

Useful `quick_run` bot options:

- `--bots:BOT:N`: number of bots to start.
- `--bot-gui`: open bot debug viewer windows.
- `--bot-name-prefix:NAME`: name bots `NAME1`, `NAME2`, and so on.
- `--bot-map:PATH`: load the same map JSON as the server.

Use `quick_run` to launch the server and native local clients together:

```sh
nim r tools/quick_run among_them --address:0.0.0.0 --port:2000 --players:4
```

You can save a replay while using `quick_run`:

```sh
nim r tools/quick_run among_them --address:0.0.0.0 --port:2000 --players:2 --save-replay:among_them.replay
```

### Map Files

The default map is `map.json`. It controls the Skeld image, Aseprite layer
indices, task stations, vents, emergency button rectangle, meeting home point,
and room names used by the bots. Map images currently need to be `952x534`.

Use a different map with `--map`:

```sh
nim r among_them.nim --address:0.0.0.0 --port:2000 --map:map.json
```

Or set it in config:

```sh
nim r among_them.nim --address:0.0.0.0 --port:2000 --config:'{"mapPath":"map.json","minPlayers":8}'
```

### Slot Config For Source Tests

The `tokens` array matches `slots` by index, so `tokens[0]` belongs to
`slots[0]`.

```json
{
  "maxGames": 1,
  "killCooldownTicks": 100,
  "tokens": [
    "0xBADA55_0",
    "0xBADA55_1",
    "0xBADA55_2",
    "0xBADA55_3",
    "0xBADA55_4",
    "0xBADA55_5",
    "0xBADA55_6",
    "0xBADA55_7"
  ],
  "slots": [
    { "name": "player1", "role": "crew", "color": "red" },
    { "name": "player2", "role": "crew", "color": "blue" },
    { "name": "player3", "role": "crew", "color": "green" },
    { "name": "player4", "role": "crew", "color": "yellow" },
    { "name": "player5", "role": "crew", "color": "lime" },
    { "name": "player6", "role": "crew", "color": "pale blue" },
    { "name": "player7", "role": "imposter", "color": "pink" },
    { "name": "player8", "role": "imposter", "color": "orange" }
  ]
}
```

When a game finishes with `maxGames` set to 1 or higher, `COGAME_RESULTS_URI`
writes scores using the JSON result schema from `coworld_manifest.json`.

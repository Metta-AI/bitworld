# BitWorld

## Bot Players — Tournament Compatibility

Bot players must be compatible with the Coworld tournament runner. The full spec
lives in the metta repo at:

    metta/packages/coworld/src/coworld/GAME_RUNTIME_README.md

The key requirements for bot containers:

1. Read `COGAMES_ENGINE_WS_URL` env var — the runner passes the full websocket
   URL (including slot and token query params) via this variable.

2. Accept CLI args `--name`, `--token`, and `--slot` as fallbacks for local
   testing.

3. Connect to the game's `/player` websocket endpoint with `slot`, `token`, and
   `name` as query params.

See `planet_wars/players/skurge/skurge.nim` for a reference implementation.

`tools/docker_build.nim` validates these requirements before building images.

## Building and Deploying

```sh
nim r tools/docker_build.nim --push stag_hunt --bots
```

See README.md for full deploy workflow.

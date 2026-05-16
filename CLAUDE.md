# BitWorld

## Bot Players

Bot players must accept these CLI arguments to work in tournaments:

- `--name` — player display name
- `--token` — authentication token for the game server
- `--slot` — assigned player slot (integer, -1 means unassigned)

These are passed as query params in the websocket connect URL. See `planet_wars/players/skurge/skurge.nim` for a reference implementation.

`tools/docker_build.nim` will fail the build if a bot source file parses CLI args but doesn't handle all three.

## Building and Deploying

```sh
nim r tools/docker_build.nim --push stag_hunt --bots
```

See README.md for full deploy workflow.

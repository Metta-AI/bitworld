# Coworld Container Environment Variables

Environment variables used by Coworld game and player containers. The local Docker runner
(`coworld run-episode` / `coworld play`), Antfarm, and games_server all inject these into
containers automatically.

## Game Container

Injected by the runner into the game container at startup.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `COGAME_CONFIG_URI` | yes | — | URI to game config JSON (`file://` or `http(s)://`) |
| `COGAME_RESULTS_URI` | yes | — | URI where the game writes results JSON (`file://` or `http(s)://` PUT) |
| `COGAME_SAVE_REPLAY_URI` | no | — | URI where the game writes the replay artifact (`file://` or `http(s)://` PUT) |
| `COGAME_HOST` | no | `0.0.0.0` | Server bind address |
| `COGAME_PORT` | no | `8080` | Server bind port |
| `COGAME_LOAD_REPLAY_URI` | no | — | URI to load a replay from (replay playback mode) |
| `COGAME_REPLAY_SERVER` | no | — | Set to `1` to start in replay-viewing mode only |
| `COWORLD_POLICY_NAMES` | no | — | JSON array of player display names, one per slot |
| `REPLAY_DOWNLOAD_URL` | no | — | HTTP URL to download a replay at startup (crewrift) |

All `*_URI` variables support both `file://` paths (local/mounted) and `http://`/`https://`
URLs. When an HTTP URI is provided, the game writes data via PUT to that URL. games_server
generates one-time auth tokens embedded in the URI query string (`?token=...`).

### Cogs vs Clips extras

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `COGAME_RESULTS_METHOD` | no | `PUT` | HTTP method for results upload |
| `COGAME_SAVE_REPLAY_METHOD` | no | `PUT` | HTTP method for replay upload |
| `COGAME_INITIAL_POLICY_ACTION_TIMEOUT_SECONDS` | no | `120` | Timeout for first player action |
| `METTASCOPE_DIST_DIR` | no | `./mettascope` | Path to MettaScope static assets |

## Player Container

Injected by the runner into each player/bot container.

| Variable | Required | Description |
|----------|----------|-------------|
| `COWORLD_PLAYER_WS_URL` | yes | WebSocket URL to connect to the game (includes slot and token query params) |
| `COGAMES_ENGINE_WS_URL` | yes | Same value as above (legacy alias) |

## How the runner wires things up

1. Game container starts with `COGAME_CONFIG_URI`, `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`.
   - Local Docker: `file://` paths with a bind mount
   - ECS / games_server: `http://` URLs pointing to the upload endpoint with auth token
2. Runner waits for `/healthz` on the game container to return 200.
3. Player containers start with `COWORLD_PLAYER_WS_URL=ws://<game-container>:8080/player?slot=N&token=TOKEN`.
4. Game runs until completion, writes results and replay to the URIs provided (file or HTTP PUT).

## games_server upload endpoint

When games_server launches game containers, it generates a one-time token and passes HTTP
URIs as `COGAME_SAVE_REPLAY_URI` and `COGAME_RESULTS_URI`:

```
PUT /api/replay/upload/<filename>?token=<hex-token>
```

- Token is valid for 600 seconds and shared across all uploads from one game launch.
- The game writes replay, results, and config to these URIs via HTTP PUT.
- games_server stores uploaded files in its replay directory.
- Falls back to `file://` with volume mounts only if the server URL cannot be determined.

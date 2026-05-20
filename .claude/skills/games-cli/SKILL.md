---
name: games-cli
description: Launch, list, stop, and inspect games on bitworld's local games_server without using the web UI. Use whenever the user asks to start/create/launch a game, stop/kill/cleanup a game, check what's running, tail container logs, or hit /healthz on a game container. Common manifests include cogs_vs_clips (v2 Coworld) and among_them (v1 bitworld).
---

# games-cli

CLI wrapper around bitworld's games_server HTTP form endpoints, so this skill can drive the same flows as the web UI. Source: `tools/games_cli.nim`.

## Prerequisites

- A local games_server running on `http://127.0.0.1:2080` (override with `GAMES_SERVER_URL`).
- Docker (the CLI shells out to it for `list`, `logs`, `health` lookups).
- Run all commands from the bitworld repo root: `cd ~/Documents/Projects/Softmax/bitworld`.

If the user reports games_server isn't running, suggest they start it in another terminal (the launch command is theirs to choose — typically `nim r games_server/games_server.nim`).

## Commands

Always invoke as `nim r tools/games_cli.nim <subcommand> [args]`. First call recompiles (~2s); subsequent calls reuse the cache.

### `launch <manifest> [--bot NAME=N]... [--bots N] [--json]`

Starts a new game container plus its bot containers. The game-then-bots ordering and health wait are handled server-side (see games_server.nim's `createGame`).

- `<manifest>` — directory name under `games_server/games/` (e.g. `cogs_vs_clips`) OR the full key `cogs_vs_clips/coworld_manifest.json`.
- `--bot NAME=N` — set a bot count for one player id (repeatable). Use `--bot all=N` or `--bot *=N` as shorthand for every declared player id.
- `--bots N` — equivalent to `--bot all=N`. Convenient default for single-bot manifests like cogs_vs_clips.
- `--json` — emit `{"name": ..., "port": ...}` instead of human text.

```bash
nim r tools/games_cli.nim launch cogs_vs_clips --bots 4 --json
# {"name":"cogs_vs_clips_game_38153_...","port":38153}
```

The game becomes healthy ~1–5s *after* this command returns. Follow with `health` if you need to confirm.

### `list [--json]`

Lists managed game containers (running and stopped) with port and status.

```bash
nim r tools/games_cli.nim list --json
# [{"name":"...","port":38153,"status":"running","manifest":"cogs_vs_clips/coworld_manifest.json"}]
```

### `stop <game-name>`

Stops a game (and its bots — server cleans them up).

### `logs <container-name> [--tail N]`

Shells out to `docker logs`. Pass a game or bot container name. `--tail N` is convenient for spot checks.

### `health <game-name> [--json]`

Probes `/healthz` on the game container. With `--json` returns `{ok, body, ...}`; without, prints one line or exits 1.

### `manifests [--json]` / `bots <manifest> [--json]`

List available manifests and the player ids declared by one manifest. Use `bots` to discover which `--bot NAME=N` values `launch` will accept.

## Common workflows

**Smoke-test the v2 integration end-to-end:**

```bash
nim r tools/games_cli.nim launch cogs_vs_clips --bots 4 --json
# parse "name" out of the response
sleep 3
nim r tools/games_cli.nim health <name> --json
nim r tools/games_cli.nim logs <name> --tail 20
nim r tools/games_cli.nim stop <name>
```

**Browser viewer URL for a running game** (the `launch` command prints this in human mode):

```
http://127.0.0.1:<port>/clients/global
```

The plural `/clients/` path works for both v1 and v2 games.

## Notes for the model

- Always pass `--json` if you'll parse the output. The human-mode text format is for the user, not for the LLM.
- Don't assume manifest names — call `manifests` if you're unsure.
- A failed `health` exits 1 (use `--json` if you want to inspect without crashing).
- This tool does not start the games_server itself. If `launch` fails with a connection error, the server isn't running — tell the user, don't try to start it for them.
- Bot containers are managed automatically by the server when you `launch` or `stop`. Don't `docker rm` them directly unless explicitly asked.

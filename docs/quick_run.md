# Quick Run

`quick_run` is the local launcher for Bitworld games. It can start a game
server, open local human clients, open a global viewer, and launch Nim bot
players from the same command. When manifests are present, it discovers game
protocols from `coworld_manifest.json`.

## Basic Usage

Run from the Bitworld repo root:

```powershell
.\tools\quick_run.exe fancy_cookout
```

By default this starts the selected game on `0.0.0.0:8080` and opens one human
client.

Use `--connect` to attach clients and bots to an existing server instead of
starting one:

```powershell
.\tools\quick_run.exe among_them --connect --port:2000 --bots:nottoodumb:8
```

In connect mode the default address is `localhost`.

## Humans

`--players:N` controls how many local human clients are launched.

```powershell
.\tools\quick_run.exe free_chat --players:2
.\tools\quick_run.exe among_them --players:0 --bots:evidencebot_v2:8
```

If `--players` is omitted, the default is:

- `1` when no bots are requested.
- `0` when one or more bot groups are requested.

Multiple human clients are opened as screen-only windows in a centered grid.
Each client is assigned a matching joystick number.

## Global Viewer

Use `--global` to open the game's global viewer. This changes the default human
player count to `0`, so bot-only watch commands do not also open a player
client. An explicit `--players:N` still wins when you want both.

By default `--global` launches the native global client. Add `--html` to open
the served browser global viewer instead.

```powershell
nim r tools/quick_run planet_wars/ --bots:skurge:4 --global --html
```

## Bots

Use `--bots:BOT:N` to launch bot players. The option may be repeated.

```powershell
.\tools\quick_run.exe among_them --bots:nottoodumb:6
.\tools\quick_run.exe among_them --players:2 --bots:evidencebot_v2:6
.\tools\quick_run.exe planet_wars --bots:skurge:3
```

Bot names are generated from the bot file label, such as `nottoodumb1` and
`nottoodumb2`.

Bot lookup checks the selected game folder:

```text
<game>/players/<bot>/<bot>.nim
<game>/players/<bot>.nim
```

You can also pass a repository-relative bot path:

```powershell
.\tools\quick_run.exe among_them --bots:among_them/players/modulabot/modulabot.nim:3
```

Useful bot options:

| Option | Meaning |
| --- | --- |
| `--bot-gui` | Pass `--gui` to every launched bot |
| `--bot-name-prefix:NAME` | Name bots `NAME1`, `NAME2`, and so on |
| `--bot-map:PATH` | Pass `--map:PATH` to every launched bot |

## Server Options

Known launcher options are handled by `quick_run`. Any unknown long or short
option is forwarded to the game server when `quick_run` starts it.

```powershell
.\tools\quick_run.exe among_them --players:2 --map:among_them/map.json
.\tools\quick_run.exe among_them --config:'{"minPlayers":8}' --bots:nottoodumb:8
```

Common options:

| Option | Meaning |
| --- | --- |
| `--address:ADDR` | Bind address in start mode, host in connect mode |
| `--port:N` | Server port |
| `--global` | Open the global viewer and default humans to zero |
| `--html` | Use the browser global viewer with `--global` |
| `--config:JSON` | Forward JSON config to the started server |
| `--config-file:PATH` | Forward a config file to the started server |
| `--save-replay:PATH` | Save a replay from the started server |

`--reconnect:N` is a launcher option. It is passed to browser clients and the
native global client, not to the server.

## Failure Behavior

When `quick_run` starts the server, it compiles the server before compiling and
launching clients or bots. If the server compile fails, nothing is launched.

If a managed server, native global client, or bot exits, `quick_run` stops the
other managed processes and exits with the first observed exit code.

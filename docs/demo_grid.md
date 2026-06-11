# BitWorld Demo Grid

The demo grid starts six local BitWorld games, opens a six-panel global-viewer
grid in Chrome, and prints the refreshable grid URL.

## Start

```bash
cd /path/to/bitworld
git pull
tools/start_demo_grid.sh
```

The start script performs a clean restart: it removes existing containers
labeled `bitworld.games_server`, starts a local `games_server`, launches the
six games below, then opens the grid URL in Chrome when available.

The default six games are:

- `jumper`
- `crewrift`
- `planet_wars`
- `infinite_blocks`
- `heartleaf`
- `asteroid_arena`

The generated URL is printed and saved to:

```bash
tmp/demo_grid/bitworld-demo-grid.url
```

## Stop

```bash
tools/stop_demo_grid.sh
```

The stop script removes containers labeled `bitworld.games_server` and stops
the local grid server on port `2080`.

## Options

Override the grid server address, port, or run directory with environment
variables:

```bash
BITWORLD_DEMO_GRID_ADDRESS=0.0.0.0 tools/start_demo_grid.sh
BITWORLD_DEMO_GRID_PORT=2081 tools/start_demo_grid.sh
BITWORLD_DEMO_GRID_RUN_DIR=/tmp/bitworld-demo tools/start_demo_grid.sh
```

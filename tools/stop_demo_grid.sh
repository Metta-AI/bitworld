#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT="${BITWORLD_DEMO_GRID_PORT:-2080}"
SESSION="${BITWORLD_DEMO_GRID_SESSION:-bitworld-demo-grid}"
RUN_DIR="${BITWORLD_DEMO_GRID_RUN_DIR:-tmp/demo_grid}"
SERVER_PID="$RUN_DIR/games_server.pid"
LABEL="bitworld.games_server"

if command -v docker >/dev/null 2>&1; then
  ids="$(docker ps -aq --filter "label=$LABEL")"
  if [[ -n "$ids" ]]; then
    echo "Removing BitWorld games-server containers..."
    printf '%s\n' "$ids" | xargs -r -n 10 docker rm -f >/dev/null
  else
    echo "No BitWorld games-server containers found."
  fi
else
  echo "docker is not installed; skipping container cleanup." >&2
fi

if command -v tmux >/dev/null 2>&1; then
  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
  tmux kill-session -t bitworld-tv >/dev/null 2>&1 || true
fi

if [[ -f "$SERVER_PID" ]]; then
  pid="$(cat "$SERVER_PID")"
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    echo "Stopping games_server pid $pid..."
    kill "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$SERVER_PID"
fi

if command -v lsof >/dev/null 2>&1 &&
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Warning: something is still listening on TCP port $PORT:" >&2
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2
  exit 1
fi

echo "BitWorld demo grid stopped."

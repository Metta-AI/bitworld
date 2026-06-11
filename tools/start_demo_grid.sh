#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ADDRESS="${BITWORLD_DEMO_GRID_ADDRESS:-127.0.0.1}"
PORT="${BITWORLD_DEMO_GRID_PORT:-2080}"
SESSION="${BITWORLD_DEMO_GRID_SESSION:-bitworld-demo-grid}"
RUN_DIR="${BITWORLD_DEMO_GRID_RUN_DIR:-tmp/demo_grid}"
SERVER_BIN="$RUN_DIR/games_server"
SERVER_LOG="$RUN_DIR/games_server.log"
SERVER_PID="$RUN_DIR/games_server.pid"
GRID_URL_FILE="$RUN_DIR/bitworld-demo-grid.url"
LABEL="bitworld.games_server"

GAMES=(
  jumper
  crewrift
  planet_wars
  infinite_blocks
  heartleaf
  asteroid_arena
)

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required command: $command_name" >&2
    exit 1
  fi
}

cleanup_on_error() {
  set +e
  echo "Demo grid start failed; cleaning up partial launch..." >&2
  remove_demo_containers
  stop_demo_server
}

remove_demo_containers() {
  local ids
  ids="$(docker ps -aq --filter "label=$LABEL")"
  if [[ -n "$ids" ]]; then
    echo "Removing existing BitWorld games-server containers..."
    printf '%s\n' "$ids" | xargs -r -n 10 docker rm -f >/dev/null
  fi
}

stop_demo_server() {
  if command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
    tmux kill-session -t bitworld-tv >/dev/null 2>&1 || true
  fi
  if [[ -f "$SERVER_PID" ]]; then
    local pid
    pid="$(cat "$SERVER_PID")"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$SERVER_PID"
  fi
}

wait_for_port() {
  for _ in $(seq 1 40); do
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "games_server did not start on $ADDRESS:$PORT" >&2
  exit 1
}

start_demo_server() {
  echo "Compiling games_server..."
  nim c -o:"$SERVER_BIN" games_server/games_server.nim

  echo "Starting games_server on http://$ADDRESS:$PORT ..."
  if command -v tmux >/dev/null 2>&1; then
    tmux new-session -d -s "$SESSION" \
      "cd '$ROOT' && './$SERVER_BIN' --address:'$ADDRESS' --port:'$PORT' 2>&1 | tee -a '$SERVER_LOG'"
  else
    nohup "./$SERVER_BIN" --address:"$ADDRESS" --port:"$PORT" >>"$SERVER_LOG" 2>&1 &
    echo "$!" > "$SERVER_PID"
  fi
  wait_for_port
}

start_game() {
  local game="$1"
  local log="$RUN_DIR/start-${game}.log"
  echo "Starting $game ..." >&2
  nim r tools/start_all_games --skip-pull --game:"$game" 2>&1 | tee "$log" >&2
  awk '/^Started / {print $2}' "$log" | tail -n 1
}

open_grid() {
  local url="$1"
  if command -v open >/dev/null 2>&1; then
    open -a "Google Chrome" "$url" >/dev/null 2>&1 || open "$url" >/dev/null 2>&1 || true
  fi
}

require_command docker
require_command nim
require_command lsof
docker info >/dev/null

trap cleanup_on_error ERR

mkdir -p "$RUN_DIR"
remove_demo_containers
stop_demo_server
start_demo_server

names=()
for game in "${GAMES[@]}"; do
  name="$(start_game "$game")"
  if [[ -z "$name" ]]; then
    echo "could not find started container name for $game" >&2
    exit 1
  fi
  names+=("$name")
done

url="http://$ADDRESS:$PORT/containers/grid?name=${names[0]}"
for name in "${names[@]:1}"; do
  url="${url}&name=${name}"
done

printf '%s\n' "$url" > "$GRID_URL_FILE"
open_grid "$url"
trap - ERR

echo
echo "BitWorld demo grid is running:"
echo "$url"
echo
echo "URL saved to $GRID_URL_FILE"
echo "Stop it with: tools/stop_demo_grid.sh"

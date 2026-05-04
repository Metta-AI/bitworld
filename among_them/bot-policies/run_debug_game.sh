#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
HOST="${HOST:-localhost}"
PORT="${PORT:-8080}"
NIM_BOTS="${NIM_BOTS:-4}"
MIN_PLAYERS="${MIN_PLAYERS:-5}"
IMPOSTERS="${IMPOSTERS:-1}"
TASKS="${TASKS:-4}"
VOTE_TIMER="${VOTE_TIMER:-720}"
BOT_NAME="${BOT_NAME:-smartbot}"
PROVIDER="${PROVIDER:-bedrock}"
MODEL="${MODEL:-}"
DEBUG_PORT="${DEBUG_PORT:-9090}"
OPEN_BROWSER="${OPEN_BROWSER:-1}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIDECAR_DIR="$REPO_ROOT/among_them/bot-policies"
HTTP_PORT=$((DEBUG_PORT + 1))

pids=()

cleanup() {
  echo ""
  echo "Shutting down..."
  for pid in "${pids[@]+"${pids[@]}"}"; do
    kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null || true
  done
  echo "All processes stopped."
}
trap cleanup EXIT INT TERM

# ── Kill stale processes on our ports ──────────────────────────────────────────
free_port() {
  local p=$1
  local stale
  stale=$(lsof -ti "tcp:$p" 2>/dev/null || true)
  if [ -n "$stale" ]; then
    echo "Killing stale process on port $p (PID $stale)..."
    echo "$stale" | xargs kill -9 2>/dev/null || true
    sleep 0.5
  fi
}

free_port "$PORT"
free_port "$DEBUG_PORT"
free_port "$HTTP_PORT"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║            Among Them — Smart Bot Debug Game               ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Server       : $HOST:$PORT"
echo "║  Nim bots     : $NIM_BOTS"
echo "║  Smart bot    : $BOT_NAME ($PROVIDER)"
echo "║  Debugger     : http://$HOST:$HTTP_PORT"
echo "║  Player view  : http://$HOST:$PORT/client/player.html"
echo "║  Global view  : http://$HOST:$PORT/client/global.html"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Compile + start the game server ────────────────────────────────────
echo "[1/3] Starting game server..."
cd "$REPO_ROOT/among_them"
CONFIG="{\"minPlayers\":$MIN_PLAYERS,\"imposterCount\":$IMPOSTERS,\"tasksPerPlayer\":$TASKS,\"voteTimerTicks\":$VOTE_TIMER}"
nim r among_them.nim \
  --address:"$HOST" \
  --port:"$PORT" \
  --config:"$CONFIG" &
SERVER_PID=$!
pids+=($SERVER_PID)

sleep 3
if kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "      Game server PID $SERVER_PID  ✓"
else
  echo "      Game server failed to start!"
  exit 1
fi

# ── Step 2: Launch Nim AI opponents ────────────────────────────────────────────
echo "[2/3] Launching $NIM_BOTS Nim bots..."
cd "$REPO_ROOT"
nim r tools/quick_player nottoodumb \
  --players:"$NIM_BOTS" \
  --address:"$HOST" \
  --port:"$PORT" &
NIMBOTS_PID=$!
pids+=($NIMBOTS_PID)

sleep 3
echo "      Nim bots PID $NIMBOTS_PID  ✓"

# ── Step 3: Launch Python smart bot with debugger ──────────────────────────────
echo "[3/3] Launching Python smart bot with debugger..."
cd "$SIDECAR_DIR"

BOT_ARGS="-m sidecar.bot --host $HOST --port $PORT --name $BOT_NAME --brain --provider $PROVIDER --debug --debug-port $DEBUG_PORT"
if [ -n "$MODEL" ]; then
  BOT_ARGS="$BOT_ARGS --model $MODEL"
fi

python3 $BOT_ARGS &
SMARTBOT_PID=$!
pids+=($SMARTBOT_PID)

sleep 3
if kill -0 "$SMARTBOT_PID" 2>/dev/null; then
  echo "      Smart bot PID $SMARTBOT_PID  ✓"
else
  echo "      Smart bot failed to start!"
  exit 1
fi

# ── Open browser tabs ──────────────────────────────────────────────────────────
if [ "$OPEN_BROWSER" = "1" ] && command -v open &>/dev/null; then
  echo ""
  echo "Opening browser..."
  open "http://$HOST:$HTTP_PORT"
  open "http://$HOST:$PORT/client/global.html"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo " All running. Press Ctrl+C to stop everything."
echo ""
echo " Debugger GUI:  http://$HOST:$HTTP_PORT"
echo " Global view:   http://$HOST:$PORT/client/global.html"
echo " Player view:   http://$HOST:$PORT/client/player.html?name=human"
echo "════════════════════════════════════════════════════════════════"

wait

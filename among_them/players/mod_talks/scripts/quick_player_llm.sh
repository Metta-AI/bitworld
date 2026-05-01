#!/usr/bin/env bash
# Sprint 6.5 — quick_player-equivalent wrapper for the LLM-enabled
# mod_talks build.
#
# `tools/quick_player` always recompiles its target without `-d`
# defines and only forwards `--address` / `--port` / `--name`
# to the spawned binary, so it can't drive the LLM build path.
# Per the Sprint 6 scope rule, we shouldn't extend
# `tools/quick_player.nim` (it's outside `among_them/players/mod_talks/`).
# This script is the in-scope alternative: builds the LLM binary
# once, then spawns N copies of it pointed at an existing server.
#
# Usage:
#   among_them/players/mod_talks/scripts/quick_player_llm.sh \
#       [-n COUNT] [-a HOST] [-p PORT] [--name-prefix PREFIX] \
#       [--llm-provider NAME] [--llm-model NAME] [--rebuild]
#
# Defaults:
#   COUNT   = 8
#   HOST    = localhost
#   PORT    = 2000
#   PREFIX  = mt
#
# Provider selection follows the same env-var rules as
# `mod_talks_llm` itself: ANTHROPIC_API_KEY, AWS creds, etc.
# `--llm-provider`/`--llm-model` are passed through to each spawned
# bot.
#
# This script does NOT spawn its own server. Pre-flight a server
# on the requested HOST:PORT before running.
#
# Cleanup: traps SIGINT/SIGTERM and kills all spawned bot processes
# before exiting. Without this, Ctrl-C only kills bash and leaves
# orphaned bots running against the server.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MOD_TALKS_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
REPO_ROOT="$( cd "$MOD_TALKS_DIR/../../.." && pwd )"

# Defaults
count=8
host="localhost"
port=2000
name_prefix="mt"
llm_provider=""
llm_model=""
rebuild=0
extra_args=()

usage() {
  sed -n '2,33p' "$0" | sed 's/^# \?//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--count)         count="$2"; shift 2 ;;
    -a|--address|--host) host="$2"; shift 2 ;;
    -p|--port)          port="$2"; shift 2 ;;
    --name-prefix)      name_prefix="$2"; shift 2 ;;
    --llm-provider)     llm_provider="$2"; shift 2 ;;
    --llm-model)        llm_model="$2"; shift 2 ;;
    --rebuild)          rebuild=1; shift ;;
    -h|--help)          usage ;;
    --)                 shift; extra_args+=("$@"); break ;;
    *)                  extra_args+=("$1"); shift ;;
  esac
done

binary="$MOD_TALKS_DIR/mod_talks_llm"

# Build (or rebuild) the LLM binary.
if [[ "$rebuild" -eq 1 || ! -x "$binary" ]]; then
  echo "[quick_player_llm] building $binary ..."
  (
    cd "$REPO_ROOT"
    nim c -d:release -d:modTalksLlm -d:ssl \
      -o:"$binary" \
      "$MOD_TALKS_DIR/modulabot.nim"
  )
fi

# Pre-flight: warn (don't fail) if no provider creds are obviously
# present. The bot will fall back to rule-based mode but the user
# probably intended LLM behaviour given this script's name.
if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && \
   [[ -z "${OPENAI_API_KEY:-}" ]] && \
   [[ -z "${AWS_PROFILE:-}" ]] && \
   [[ -z "${AWS_ACCESS_KEY_ID:-}" ]] && \
   [[ "${MODTALKS_LLM_DISABLE:-}" != "1" ]]; then
  echo "[quick_player_llm] WARNING: no LLM credentials detected."
  echo "[quick_player_llm] Set one of ANTHROPIC_API_KEY,"
  echo "[quick_player_llm] OPENAI_API_KEY, AWS_PROFILE, or"
  echo "[quick_player_llm] AWS_ACCESS_KEY_ID. Bots will run rule-based."
fi

# Build the per-bot arg list once. We pass --address, --port, and
# --name to each spawn; LLM flags are passed through if supplied.
common_args=(--address:"$host" --port:"$port")
if [[ -n "$llm_provider" ]]; then
  common_args+=(--llm-provider:"$llm_provider")
fi
if [[ -n "$llm_model" ]]; then
  common_args+=(--llm-model:"$llm_model")
fi
if [[ ${#extra_args[@]} -gt 0 ]]; then
  common_args+=("${extra_args[@]}")
fi

# Spawn N processes, one per agent. Stash PIDs for cleanup.
pids=()

cleanup() {
  echo ""
  echo "[quick_player_llm] stopping ${#pids[@]} bot(s) ..."
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  # Give them 2 s to exit cleanly, then SIGKILL stragglers.
  sleep 2
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup INT TERM EXIT

echo "[quick_player_llm] spawning $count bots → $host:$port"
for i in $(seq 1 "$count"); do
  name="${name_prefix}${i}"
  "$binary" --name:"$name" "${common_args[@]}" &
  pids+=($!)
  echo "[quick_player_llm]   spawned $name (pid=$!)"
done

# Wait for all bots. If any exits, we keep going — same semantics
# as `tools/quick_player` (which terminates the group when one
# child exits). Override that behaviour by removing the wait loop
# and using `wait` directly if you want all-or-nothing.
wait

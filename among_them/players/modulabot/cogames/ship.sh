#!/usr/bin/env bash
#
# Convenience wrapper for validating and shipping modulabot to a CoGames
# AmongThem season. Reads SEASON and POLICY_NAME from the environment.
#
# Usage:
#   SEASON=among-them POLICY_NAME=$USER-modulabot ./ship.sh dry-run
#   SEASON=among-them POLICY_NAME=$USER-modulabot ./ship.sh ship
#
# Always runs from the bitworld repo root so relative -f paths resolve.

set -euo pipefail

CMD="${1:-dry-run}"
SEASON="${SEASON:-}"
POLICY_NAME="${POLICY_NAME:-$USER-modulabot-$(date +%Y%m%d-%H%M%S)}"

if [[ -z "$SEASON" ]]; then
    echo "ERROR: SEASON is required. Run 'cogames season list' to find an active AmongThem season." >&2
    exit 1
fi

# Resolve repo root relative to this script: cogames/ -> modulabot/ -> players/ -> among_them/ -> root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

if [[ ! -f "$REPO_ROOT/nimby.lock" ]]; then
    echo "ERROR: Could not locate nimby.lock at $REPO_ROOT/nimby.lock" >&2
    exit 1
fi

cd "$REPO_ROOT"

INCLUDES=(
    -f among_them/players/modulabot/cogames/amongthem_policy.py
    -f among_them/players/modulabot
    # Transitive Nim source dependencies of modulabot.nim:
    #   among_them/sim.nim         -- imported as `../../sim`
    #   common/{protocol,server}.nim
    #   src/bitworld/aseprite.nim  -- imported by among_them/sim.nim
    -f among_them/sim.nim
    -f common
    -f src/bitworld
    -f nimby.lock
)

case "$CMD" in
    dry-run)
        exec cogames upload \
            -p class=amongthem_policy.AmongThemPolicy \
            "${INCLUDES[@]}" \
            -n "$POLICY_NAME" \
            --season "$SEASON" \
            --dry-run
        ;;
    upload)
        exec cogames upload \
            -p class=amongthem_policy.AmongThemPolicy \
            "${INCLUDES[@]}" \
            -n "$POLICY_NAME" \
            --season "$SEASON"
        ;;
    ship)
        exec cogames ship \
            -p class=amongthem_policy.AmongThemPolicy \
            "${INCLUDES[@]}" \
            -n "$POLICY_NAME" \
            --season "$SEASON"
        ;;
    ship-skip-validation)
        # Use this when the 10-step Docker validation can't run the bot
        # long enough to emit a non-noop action (modulabot needs many
        # frames to localize before it acts). The tournament workers
        # run full-length games where localization succeeds.
        exec cogames ship \
            -p class=amongthem_policy.AmongThemPolicy \
            "${INCLUDES[@]}" \
            -n "$POLICY_NAME" \
            --season "$SEASON" \
            --skip-validation
        ;;
    *)
        echo "Usage: $0 {dry-run|upload|ship|ship-skip-validation}" >&2
        exit 2
        ;;
esac

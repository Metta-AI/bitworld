#!/usr/bin/env bash
# trace_smoke.sh — build and exercise the modulabot trace pipeline.
# Used as the local sanity check during trace development. Mirrors the
# CI flow described in TRACING.md §13.
#
# Steps:
#   1. Compile parity.nim, trace_smoke.nim, validate_trace.nim,
#      speaker_attribution.nim, vote_bandwagon.nim.
#   2. Run parity (no trace) — black-mode 500 frames, must be 100%.
#   3. Run parity (with trace) — black-mode 500 frames, must be 100%
#      and the trace must validate.
#   4. Run trace_smoke (covers manifest / events / decisions / snapshots).
#   5. Run speaker_attribution (4 scenarios, all must pass).
#   6. Run vote_bandwagon (5 scenarios, all must pass).
#   7. Run gen_branch_ids; ensure no diff vs. checked-in BRANCH_IDS.md.
#   8. Run check_tuning_snapshot; every public `const NAME*` in a policy
#      module must be registered in tuning_snapshot.nim or whitelisted.
#
# Exit non-zero on first failure. Quiet on success.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT=$(mktemp -d)
trap "rm -rf $OUT" EXIT

echo "[1/8] compiling..."
nim c --hints:off -d:release -o:"$OUT/parity"        test/parity.nim         > /dev/null
nim c --hints:off -d:release -o:"$OUT/trace_smoke"   test/trace_smoke.nim    > /dev/null
nim c --hints:off -d:release -o:"$OUT/validate"      test/validate_trace.nim > /dev/null
nim c --hints:off -d:release -o:"$OUT/speaker"       test/speaker_attribution.nim > /dev/null
nim c --hints:off -d:release -o:"$OUT/bandwagon"     test/vote_bandwagon.nim > /dev/null

echo "[2/8] parity (no trace)..."
"$OUT/parity" --frames:500 --seed:42 --mode:black | tail -1

echo "[3/8] parity (with trace)..."
TRACE_OUT="$OUT/parity-trace"
"$OUT/parity" --frames:500 --seed:42 --mode:black --trace-dir:"$TRACE_OUT" | tail -1
"$OUT/validate" --root:"$TRACE_OUT" | tail -1

echo "[4/8] trace_smoke..."
"$OUT/trace_smoke" | tail -3

echo "[5/8] speaker_attribution..."
"$OUT/speaker" | tail -1

echo "[6/8] vote_bandwagon..."
"$OUT/bandwagon" | tail -1

echo "[7/8] branch IDs..."
nim r --hints:off tools/gen_branch_ids.nim > /dev/null
if ! git diff --quiet -- BRANCH_IDS.md; then
  echo "FAIL: BRANCH_IDS.md is stale; check the diff and commit."
  git diff -- BRANCH_IDS.md | head -40
  exit 1
fi

echo "[8/8] tuning_snapshot exhaustiveness..."
nim r --hints:off tools/check_tuning_snapshot.nim | tail -1

echo "trace smoke: OK"

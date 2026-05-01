#!/usr/bin/env bash
# trace_smoke.sh — build and exercise the modulabot trace pipeline.
# Used as the local sanity check during trace development. Mirrors the
# CI flow described in TRACING.md §13.
#
# Steps:
#   1. Compile parity.nim, trace_smoke.nim, validate_trace.nim, llm_unit.nim.
#   2. Run parity (no trace) — black-mode 500 frames, must be 100%.
#   3. Run parity (with trace) — black-mode 500 frames, must be 100%
#      and the trace must validate.
#   4. Run trace_smoke (covers manifest / events / decisions / snapshots).
#   5. Run gen_branch_ids; ensure no diff vs. checked-in BRANCH_IDS.md.
#   6. Run llm.nim unit tests (Sprint 3.3) when -d:modTalksLlm is requested.
#   7. tuning_snapshot exhaustiveness check (Sprint 5.4): every public
#      `const X*` in policy modules should appear in tuning_snapshot.nim.
#      Soft warning, not a hard failure (some constants are layout-only).
#
# Exit non-zero on first failure. Quiet on success.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT=$(mktemp -d)
trap "rm -rf $OUT" EXIT

echo "[1/7] compiling..."
nim c --hints:off -d:release -o:"$OUT/parity"        test/parity.nim         > /dev/null
nim c --hints:off -d:release -o:"$OUT/trace_smoke"   test/trace_smoke.nim    > /dev/null
nim c --hints:off -d:release -o:"$OUT/validate"      test/validate_trace.nim > /dev/null
nim c --hints:off -d:release -d:modTalksLlm \
  -o:"$OUT/llm_unit"     test/llm_unit.nim                                  > /dev/null

echo "[2/7] parity (no trace)..."
"$OUT/parity" --frames:500 --seed:42 --mode:black | tail -1

echo "[3/7] parity (with trace)..."
TRACE_OUT="$OUT/parity-trace"
"$OUT/parity" --frames:500 --seed:42 --mode:black --trace-dir:"$TRACE_OUT" | tail -1
"$OUT/validate" --root:"$TRACE_OUT" | tail -1

echo "[4/7] trace_smoke..."
"$OUT/trace_smoke" | tail -3

echo "[5/7] branch IDs..."
nim r --hints:off tools/gen_branch_ids.nim > /dev/null
if ! git diff --quiet -- BRANCH_IDS.md; then
  echo "FAIL: BRANCH_IDS.md is stale; check the diff and commit."
  git diff -- BRANCH_IDS.md | head -40
  exit 1
fi

echo "[6/7] llm.nim unit tests..."
"$OUT/llm_unit" | tail -3

echo "[7/7] tuning_snapshot exhaustiveness..."
# Sprint 5.4 — list public `const X*` in tuning.nim and grep for X in
# tuning_snapshot.nim. Misses (constants present in tuning.nim but not
# in the snapshot) print a soft warning. We don't fail the build —
# some constants like `LlmMaxContextBytes` arguably *should* appear
# but reasonable people might disagree about pure-layout vs. tunable.
missing=0
while IFS= read -r name; do
  if ! grep -qF "\"$name\":" tuning_snapshot.nim; then
    echo "  WARN: tuning.$name not in tuning_snapshot.nim"
    missing=$((missing + 1))
  fi
done < <(awk '/^  [A-Z][A-Za-z0-9]*\*/ { gsub(/\*.*/, "", $1); print $1 }' tuning.nim)
if [ "$missing" -eq 0 ]; then
  echo "  all tuning.nim constants reflected in tuning_snapshot.nim"
fi

echo "trace smoke: OK"

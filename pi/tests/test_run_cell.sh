#!/usr/bin/env bash
# Model-free integration test for pi/run_cell.sh's control flow: the
# heartbeat, the --max-problems watchdog stop, and process-group cleanup.
# Drives pi/tests/fake_pi.sh (PI_BIN override -- no network, no real model)
# against the TRACKED, REDACTED private dataset (never the real one, and
# never requires it) -- submissions all come back WRONG ANSWER, which is
# fine; this test only cares that problems get fetched/finalized and that
# run_cell.sh's own control flow behaves correctly.
#
# Deliberately runs against the "befunge-98" cell, NOT "brainfuck" -- so it
# never touches the brainfuck cell's real, live-smoke-tested
# pi/artifacts/brainfuck_export.json.
set -uo pipefail

PI_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_DIR="$(cd "$PI_TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PI_DIR/.." && pwd)"

LANGUAGE="befunge-98"
CELL_DIR="$REPO_ROOT/experiments/01_main_experiments/pi/$LANGUAGE"
REDACTED_DATASET="$REPO_ROOT/benchmark_harness/private/esolang_full_private.json"
ARTIFACT="$PI_DIR/artifacts/${LANGUAGE}_export.json"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

cleanup_cell() {
  rm -f "$CELL_DIR"/harness_state.json "$CELL_DIR"/export.json "$CELL_DIR"/fake_*.bf "$CELL_DIR"/.run_cell.log
  rm -rf "$CELL_DIR"/.pi-sessions "$CELL_DIR"/logs
}

if [[ ! -d "$CELL_DIR" ]]; then
  fail "cell dir missing at $CELL_DIR -- run: python3 pi/setup_cells.py"
  echo "TEST_RUN_CELL: FAILURES ABOVE"; exit 1
fi
if [[ ! -f "$REDACTED_DATASET" ]]; then
  fail "redacted dataset missing at $REDACTED_DATASET"
  echo "TEST_RUN_CELL: FAILURES ABOVE"; exit 1
fi

cleanup_cell
rm -f "$ARTIFACT"

RUN_OUT="$(mktemp)"
PI_BIN="$PI_TESTS_DIR/fake_pi.sh" FAKE_PI_CYCLES=15 FAKE_PI_SLEEP=1 \
  "$PI_DIR/run_cell.sh" --model fake/fake --language "$LANGUAGE" \
    --max-problems 2 --heartbeat-interval 1 --stall-timeout 60 \
    --dataset-file "$REDACTED_DATASET" > "$RUN_OUT" 2>&1
RC=$?

if [[ "$RC" -eq 0 ]]; then
  pass "run_cell.sh exited 0"
else
  fail "run_cell.sh exited $RC"
  cat "$RUN_OUT"
fi

if grep -q '\[run_cell\] heartbeat' "$RUN_OUT"; then
  pass "at least one heartbeat line was printed"
else
  fail "no heartbeat line found"
  cat "$RUN_OUT"
fi

if grep -q 'reached --max-problems=2' "$RUN_OUT"; then
  pass "the run stopped via the --max-problems watchdog (not natural completion or a stall)"
else
  fail "expected a --max-problems stop message"
  cat "$RUN_OUT"
fi

if grep -q 'STALL DETECTED' "$RUN_OUT"; then
  fail "a spurious stall was detected during a healthy run"
else
  pass "no spurious stall detected"
fi

if [[ -f "$ARTIFACT" ]]; then
  if python3 - "$ARTIFACT" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
probs = d["problems"]
attempted = [pid for pid, p in probs.items() if p["submissions"] or p["status"] not in ("pending",)]
subs = sum(len(p["submissions"]) for p in probs.values())
assert len(attempted) >= 2, f"expected >=2 attempted, got {len(attempted)}: {attempted}"
assert subs >= 1, f"expected >=1 submission, got {subs}"
print(f"attempted={len(attempted)} submissions={subs}")
PYEOF
  then
    pass "artifact shows >=2 attempted problems with >=1 submission"
  else
    fail "artifact did not meet the >=2 attempted / >=1 submission bar"
  fi
else
  fail "artifact not found at $ARTIFACT"
fi

sleep 1
if ps -A -o command | grep -F "$PI_TESTS_DIR/fake_pi.sh" | grep -v grep > /dev/null; then
  fail "a fake_pi.sh process is still running after run_cell.sh exited (process-group leak)"
else
  pass "no orphaned fake_pi.sh process after run_cell.sh exited"
fi

cleanup_cell
rm -f "$ARTIFACT" "$RUN_OUT"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "TEST_RUN_CELL: ALL CHECKS PASSED"
  exit 0
else
  echo "TEST_RUN_CELL: FAILURES ABOVE"
  exit 1
fi

#!/usr/bin/env bash
# Deterministic audit for the pi-esolang-benchmark plan.
# NO network calls, NO live model invocation: it only inspects artifacts that
# were produced once by a prior real run (pi/load_dataset.py's output file,
# and the live pi smoke's export). Exit 0 iff every criterion passes.
set -uo pipefail

PI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PI_DIR/.." && pwd)"
cd "$REPO_ROOT"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

VENV_PY="$REPO_ROOT/.venv/bin/python3"
PY=python3
[[ -x "$VENV_PY" ]] && PY="$VENV_PY"

# ---------------------------------------------------------------------------
# 1. dataset-loader
# ---------------------------------------------------------------------------
LOCAL_DATASET="$REPO_ROOT/benchmark_harness/private/esolang_full_private.local.json"
if [[ ! -f "$LOCAL_DATASET" ]]; then
  fail "dataset-loader: $LOCAL_DATASET missing -- run: python3 pi/load_dataset.py"
else
  "$PY" - "$LOCAL_DATASET" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
problems = data.get("problems", [])
assert len(problems) == 80, f"expected 80 problems, got {len(problems)}"
for p in problems:
    tcs = p.get("test_cases", [])
    assert len(tcs) == 6, f"{p.get('id')}: expected 6 test_cases, got {len(tcs)}"
    for tc in tcs:
        assert "REDACTED" not in tc.get("output", ""), f"{p.get('id')}: still redacted"
print("schema-ok")
PYEOF
  if [[ $? -eq 0 ]]; then
    pass "dataset-loader: local dataset has 80 problems x 6 real test_cases"
  else
    fail "dataset-loader: schema validation failed on $LOCAL_DATASET"
  fi

  # Grade a known-correct brainfuck Hello World against E01 to prove submit
  # actually works end to end against the real data (local interpreter only,
  # no network).
  TMP_CELL="$(mktemp -d)"
  cp "$REPO_ROOT/benchmark_harness/harness.py" "$TMP_CELL/harness.py"
  cat > "$TMP_CELL/hello.bf" <<'BF'
++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>.>---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++.
BF
  (
    cd "$TMP_CELL"
    export HARNESS_INTERPRETER_DIR="$REPO_ROOT/benchmark_harness/interpreters"
    export HARNESS_PUBLIC_FILE="$REPO_ROOT/benchmark_harness/public/esolang_full_public.json"
    export HARNESS_PRIVATE_FILE="$LOCAL_DATASET"
    "$PY" harness.py init --language brainfuck >/dev/null
    "$PY" harness.py fetch >/dev/null
    "$PY" harness.py submit E01 hello.bf
  ) > "$TMP_CELL/submit.out" 2>&1
  if grep -q "Score: 6/6" "$TMP_CELL/submit.out"; then
    pass "dataset-loader: known-correct brainfuck program scores 6/6 on E01 via real dataset"
  else
    fail "dataset-loader: submit did not score 6/6 (see $TMP_CELL/submit.out)"
    cat "$TMP_CELL/submit.out"
  fi
  rm -rf "$TMP_CELL"
fi

# ---------------------------------------------------------------------------
# 2. cell-setup
# ---------------------------------------------------------------------------
BF_CELL="$REPO_ROOT/experiments/01_main_experiments/pi/brainfuck"
if [[ -L "$BF_CELL/harness.py" && -L "$BF_CELL/AGENTS.md" ]] \
   && [[ -e "$BF_CELL/harness.py" && -e "$BF_CELL/AGENTS.md" ]]; then
  pass "cell-setup: pi/brainfuck cell symlinks exist and resolve"
else
  fail "cell-setup: pi/brainfuck cell missing/broken symlinks -- run: python3 pi/setup_cells.py"
fi
for lang in brainfuck befunge-98 whitespace shakespeare; do
  [[ -d "$REPO_ROOT/experiments/01_main_experiments/pi/$lang" ]] \
    || fail "cell-setup: missing cell dir for $lang"
done

# ---------------------------------------------------------------------------
# 3. driver: required --model flag
# ---------------------------------------------------------------------------
DRIVER_OUT="$("$PI_DIR/run_cell.sh" --language brainfuck 2>&1)"
DRIVER_RC=$?
if [[ "$DRIVER_RC" -ne 0 ]] && echo "$DRIVER_OUT" | grep -q -- "--model"; then
  pass "driver: run_cell.sh without --model exits non-zero and names --model"
else
  fail "driver: expected non-zero exit + '--model' in error, got rc=$DRIVER_RC: $DRIVER_OUT"
fi

# ---------------------------------------------------------------------------
# 3b. driver-rebuild: the per-turn guillotine/turn-budget is GONE, the new
# continuous-run pieces are present, and a model-free integration test
# proves the control flow (heartbeat, --max-problems stop, process-group
# cleanup) without any network call or live model.
# ---------------------------------------------------------------------------
RUN_CELL="$PI_DIR/run_cell.sh"
# Check the FUNCTIONAL old mechanism is gone (a variable/flag-case pattern),
# not just that the string never appears anywhere -- the rewrite legitimately
# documents the old, wrong design in an explanatory comment, which a bare
# substring grep would false-positive on.
if grep -qE '^\s*MAX_TURNS=' "$RUN_CELL" || grep -qE -- '--max-turns\)' "$RUN_CELL" \
   || grep -qE 'timeout "\$\{PI_TURN_TIMEOUT' "$RUN_CELL"; then
  fail "driver-rebuild: the old per-turn timeout guillotine / --max-turns chunking is still functionally present in run_cell.sh"
else
  pass "driver-rebuild: per-turn timeout guillotine and --max-turns chunking are functionally gone"
fi
if grep -q 'HEARTBEAT_INTERVAL' "$RUN_CELL" && grep -q 'STALL_TIMEOUT' "$RUN_CELL" \
   && grep -q 'PI_BIN' "$RUN_CELL" && grep -qi 'process group' "$RUN_CELL"; then
  pass "driver-rebuild: heartbeat/stall-watchdog/PI_BIN/process-group-cleanup are present"
else
  fail "driver-rebuild: expected heartbeat/stall-timeout/PI_BIN/process-group pieces missing from run_cell.sh"
fi

TEST_RUN_CELL="$PI_DIR/tests/test_run_cell.sh"
if [[ ! -x "$TEST_RUN_CELL" ]]; then
  fail "driver-rebuild: $TEST_RUN_CELL missing or not executable"
else
  TEST_OUT="$(bash "$TEST_RUN_CELL" 2>&1)"
  TEST_RC=$?
  if [[ "$TEST_RC" -eq 0 ]] && echo "$TEST_OUT" | grep -q 'TEST_RUN_CELL: ALL CHECKS PASSED'; then
    pass "driver-rebuild: model-free integration test (heartbeat + max-problems stop + no orphaned process) passed"
  else
    fail "driver-rebuild: integration test failed (rc=$TEST_RC)"
    echo "$TEST_OUT"
  fi
fi

# ---------------------------------------------------------------------------
# 4. smoke: live pi run artifact
# ---------------------------------------------------------------------------
# run_cell.sh copies the cell's export.json to pi/artifacts/<language>_export.json
# after every run (any language qualifies as the smoke proof).
SMOKE_EXPORT="$(ls "$PI_DIR"/artifacts/*_export.json 2>/dev/null | head -1)"
if [[ -z "$SMOKE_EXPORT" || ! -f "$SMOKE_EXPORT" ]]; then
  fail "smoke: no pi/artifacts/<language>_export.json found -- run the live pi smoke test first (pi/run_cell.sh ...)"
else
  "$PY" - "$SMOKE_EXPORT" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
problems = data.get("problems", {})
attempted = [pid for pid, p in problems.items() if p.get("submissions") or p.get("status") not in ("pending", None)]
submissions = sum(len(p.get("submissions", [])) for p in problems.values())
assert len(attempted) >= 2, f"expected >=2 attempted problems, got {len(attempted)}"
assert submissions >= 1, f"expected >=1 recorded submission, got {submissions}"
print(f"attempted={len(attempted)} submissions={submissions}")
PYEOF
  if [[ $? -eq 0 ]]; then
    pass "smoke: $(basename "$SMOKE_EXPORT") shows >=2 attempted problems and >=1 real submission"
  else
    fail "smoke: $SMOKE_EXPORT did not meet the >=2 attempted / >=1 submission bar"
  fi
fi

# ---------------------------------------------------------------------------
# 5. docs
# ---------------------------------------------------------------------------
README="$PI_DIR/README.md"
if [[ -f "$README" ]] \
   && grep -q "load_dataset.py" "$README" \
   && grep -q "setup_cells.py" "$README" \
   && grep -q "run_cell.sh" "$README" \
   && grep -qi "model.*required\|required.*model" "$README" \
   && grep -qi "never commit" "$README"; then
  pass "docs: pi/README.md documents all 3 scripts + required-model + never-commit notes"
else
  fail "docs: pi/README.md missing or incomplete"
fi
if grep -q "pi/README.md" "$REPO_ROOT/HOWTO_RUN.md" 2>/dev/null; then
  pass "docs: HOWTO_RUN.md points to pi/README.md"
else
  fail "docs: HOWTO_RUN.md does not reference pi/README.md"
fi

# ---------------------------------------------------------------------------
# 6. hygiene
# ---------------------------------------------------------------------------
if git diff --quiet -- benchmark_harness/private/esolang_full_private.json \
   && git diff --cached --quiet -- benchmark_harness/private/esolang_full_private.json; then
  pass "hygiene: tracked redacted private JSON is unmodified"
else
  fail "hygiene: tracked redacted private JSON has local modifications"
fi

if git status --porcelain --ignored=matching -- \
     benchmark_harness/private/esolang_full_private.local.json pi/artifacts .pi-sessions \
   | grep -qE '^(!! |\?\? .*local\.json)'; then
  pass "hygiene: local dataset + pi/artifacts are git-ignored (not tracked/untracked-visible)"
elif ! git status --porcelain -- \
       benchmark_harness/private/esolang_full_private.local.json pi/artifacts .pi-sessions \
     | grep -qE '^\?\?|^A |^M '; then
  pass "hygiene: local dataset + pi/artifacts are not tracked or staged"
else
  fail "hygiene: local dataset or pi/artifacts appear tracked/staged in git status"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "AUDIT: ALL CHECKS PASSED"
  exit 0
else
  echo "AUDIT: FAILURES ABOVE"
  exit 1
fi

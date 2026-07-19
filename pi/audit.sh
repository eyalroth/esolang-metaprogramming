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
# 2. cell-setup: on-demand grid cells (harness x provider x model x thinking
# x language). Use a clearly-marked throwaway grid point so this never
# collides with a real result; clean it up afterward.
# ---------------------------------------------------------------------------
AUDIT_PROVIDER="_audit_provider"
AUDIT_MODEL="_audit_model"
SETUP_OUT="$("$PY" "$PI_DIR/setup_cells.py" --provider "$AUDIT_PROVIDER" --model "$AUDIT_MODEL" --thinking low --language brainfuck 2>&1)"
SETUP_RC=$?
AUDIT_CELL="$(sed -n 's/^CELL_DIR=//p' <<<"$SETUP_OUT" | tail -1)"
if [[ "$SETUP_RC" -eq 0 && -n "$AUDIT_CELL" \
      && -L "$AUDIT_CELL/harness.py" && -L "$AUDIT_CELL/AGENTS.md" \
      && -e "$AUDIT_CELL/harness.py" && -e "$AUDIT_CELL/AGENTS.md" \
      && "$AUDIT_CELL" == */"$AUDIT_PROVIDER"/"$AUDIT_MODEL"/*/brainfuck ]]; then
  pass "cell-setup: a grid cell (provider/model/thinking/language) builds on demand with resolving symlinks at the nested path"
else
  fail "cell-setup: grid cell build failed or symlinks broken (rc=$SETUP_RC, cell=$AUDIT_CELL)"
  echo "$SETUP_OUT"
fi
# Clean up the throwaway grid point.
rm -rf "$REPO_ROOT/experiments/01_main_experiments/pi/$AUDIT_PROVIDER"
rm -rf "$PI_DIR/artifacts/$AUDIT_PROVIDER"

# ---------------------------------------------------------------------------
# 3. driver: required --model and --provider flags
# ---------------------------------------------------------------------------
DRIVER_OUT="$("$PI_DIR/run_cell.sh" --language brainfuck 2>&1)"
DRIVER_RC=$?
if [[ "$DRIVER_RC" -ne 0 ]] && echo "$DRIVER_OUT" | grep -q -- "--model"; then
  pass "driver: run_cell.sh without --model exits non-zero and names --model"
else
  fail "driver: expected non-zero exit + '--model' in error, got rc=$DRIVER_RC: $DRIVER_OUT"
fi
DRIVER_OUT2="$("$PI_DIR/run_cell.sh" --model fake --language brainfuck 2>&1)"
DRIVER_RC2=$?
if [[ "$DRIVER_RC2" -ne 0 ]] && echo "$DRIVER_OUT2" | grep -q -- "--provider"; then
  pass "driver: run_cell.sh without --provider exits non-zero and names --provider"
else
  fail "driver: expected non-zero exit + '--provider' in error, got rc=$DRIVER_RC2: $DRIVER_OUT2"
fi
DRIVER_OUT3="$("$PI_DIR/run_cell.sh" --model fake --provider fake --language brainfuck 2>&1)"
DRIVER_RC3=$?
if [[ "$DRIVER_RC3" -ne 0 ]] && echo "$DRIVER_OUT3" | grep -q -- "--thinking"; then
  pass "driver: run_cell.sh without --thinking exits non-zero and names --thinking"
else
  fail "driver: expected non-zero exit + '--thinking' in error, got rc=$DRIVER_RC3: $DRIVER_OUT3"
fi
DRIVER_OUT4="$("$PI_DIR/run_cell.sh" --model fake --provider fake --thinking bogus-level --language brainfuck 2>&1)"
DRIVER_RC4=$?
if [[ "$DRIVER_RC4" -ne 0 ]] && echo "$DRIVER_OUT4" | grep -q "not a recognized level"; then
  pass "driver: run_cell.sh rejects an unrecognized --thinking value"
else
  fail "driver: expected non-zero exit + 'not a recognized level' in error, got rc=$DRIVER_RC4: $DRIVER_OUT4"
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

# grid-keying: --provider is required (not silently defaulted), --fresh
# exists, and the cell path is resolved via setup_cells.py (single source of
# truth), not recomputed independently.
if grep -q -- '--provider) PROVIDER=' "$RUN_CELL" && grep -q -- '--fresh) FRESH=' "$RUN_CELL" \
   && grep -q 'setup_cells.py' "$RUN_CELL" && grep -q 'CELL_DIR="\$(sed' "$RUN_CELL"; then
  pass "grid-keying: run_cell.sh requires --provider, supports --fresh, and resolves the cell via setup_cells.py"
else
  fail "grid-keying: expected --provider/--fresh/setup_cells.py-resolution wiring missing from run_cell.sh"
fi
if grep -q 'required=True' "$PI_DIR/setup_cells.py" && grep -q 'def slug' "$PI_DIR/setup_cells.py"; then
  pass "grid-keying: setup_cells.py requires provider/model and slugs the grid path"
else
  fail "grid-keying: setup_cells.py missing required-args/slugging for the grid path"
fi
# thinking is required with no assumed default (same treatment as model/provider).
if grep -q -- '--thinking) THINKING=' "$RUN_CELL" && grep -qi 'thinking is required' "$RUN_CELL" \
   && grep -q 'off|minimal|low|medium|high|xhigh' "$RUN_CELL" \
   && grep -q '"--thinking", required=True' "$PI_DIR/setup_cells.py"; then
  pass "grid-keying: --thinking is required (no default) and validated against pi's known levels"
else
  fail "grid-keying: --thinking is not fully required/validated across run_cell.sh + setup_cells.py"
fi
# model-existence pre-flight: refuse an unresolvable (provider, model) pair
# instead of letting pi silently fuzzy-match/fall back to a different model.
if grep -q -- '--list-models' "$RUN_CELL" && grep -qi 'refusing to run' "$RUN_CELL"; then
  pass "grid-keying: run_cell.sh pre-flights --provider/--model against '\$PI_BIN --list-models' and refuses an unresolvable pair"
else
  fail "grid-keying: expected a model-existence pre-flight (--list-models) missing from run_cell.sh"
fi

# session-id-grid-keying: the default child --session-id must encode the
# FULL grid coordinates (provider, model, thinking), not just the language --
# the fix for an observed real bug where a language-only session-id let one
# grid cell's sticky model entry leak onto a later run requesting a
# DIFFERENT model (an operator's pi config replayed the wrong model/thinking).
if grep -q 'def slug\|slug() {' "$RUN_CELL" \
   && grep -qE 'SESSION_ID="\$\{SESSION_ID_OVERRIDE:-pi-esolang-\$\(slug' "$RUN_CELL"; then
  pass "session-id-grid-keying: default child --session-id is built from the full grid coordinates (provider/model/thinking/language), not language alone"
else
  fail "session-id-grid-keying: expected a slug()-based, grid-coordinate default --session-id in run_cell.sh"
fi

# effective-model-assertion: after launching the child, run_cell.sh must
# read back what pi ACTUALLY booted (model_change/thinking_level_change) and
# kill+abort on any mismatch with what was requested -- never trusting that
# passing --model/--provider/--thinking means they were honored.
if grep -q 'read_effective_model_once' "$RUN_CELL" \
   && grep -q 'model_change' "$RUN_CELL" && grep -q 'thinking_level_change' "$RUN_CELL" \
   && grep -qi 'booted a DIFFERENT model than requested' "$RUN_CELL" \
   && grep -q 'EFFECTIVE_MODEL_WAIT' "$RUN_CELL"; then
  pass "effective-model-assertion: run_cell.sh verifies the effective model/provider/thinking and aborts on mismatch"
else
  fail "effective-model-assertion: expected effective-model verification wiring missing from run_cell.sh"
fi
# The verification must NOT be first-found-wins (that reads only the boot
# event and misses a later silent override) -- it must require the
# last-seen model/thinking to be STABLE for EFFECTIVE_MODEL_SETTLE seconds.
if grep -q 'EFFECTIVE_MODEL_SETTLE' "$RUN_CELL" && grep -q 'stable_since' "$RUN_CELL"; then
  pass "effective-model-assertion: verification requires the effective model to be STABLE (settle window), not just present on the first read"
else
  fail "effective-model-assertion: expected a settle-window (EFFECTIVE_MODEL_SETTLE/stable_since) guard against reading only the boot event, missing from run_cell.sh"
fi
# A mismatched/unverifiable run must never file a result artifact under the
# requested grid path.
if grep -q 'effective_model_mismatch|effective_model_unverifiable' "$RUN_CELL" \
   && grep -qi 'skipping artifact export' "$RUN_CELL"; then
  pass "effective-model-assertion: a mismatched/unverifiable run skips filing an artifact under the grid path"
else
  fail "effective-model-assertion: expected finalize_export to skip on an effective-model mismatch/unverifiable run"
fi

# child-compaction: run_cell.sh writes a cell-local .pi/settings.json so pi
# auto-compacts for the child (matching the paper's native-harness default),
# WITHOUT touching the operator's own global settings.json, with an
# on|off escape hatch.
if grep -q -- '--compaction) COMPACTION=' "$RUN_CELL" \
   && grep -q '\.pi/settings\.json' "$RUN_CELL" \
   && grep -q '"compaction":{"enabled":true}' "$RUN_CELL" \
   && grep -q '"compaction":{"enabled":false}' "$RUN_CELL"; then
  pass "child-compaction: run_cell.sh writes a cell-local .pi/settings.json enabling/disabling compaction per --compaction"
else
  fail "child-compaction: expected cell-local .pi/settings.json compaction wiring missing from run_cell.sh"
fi

# heartbeat-status-resilience: harness_status must retry + keep last-known
# ST_* values + suppress the subprocess traceback on a transient/garbled
# read (the observed race with the child's concurrent state-file write).
if grep -q 'harness_status()' "$RUN_CELL" \
   && grep -q '2>/dev/null' "$RUN_CELL" \
   && grep -qE 'for attempt in 1 2' "$RUN_CELL" \
   && grep -qi 'KEEPS the previous ST_\* values' "$RUN_CELL"; then
  pass "heartbeat-status-resilience: harness_status retries + keeps last-known values + suppresses the subprocess traceback"
else
  fail "heartbeat-status-resilience: expected retry/keep-last-known/stderr-suppression wiring missing from harness_status in run_cell.sh"
fi

TEST_RUN_CELL="$PI_DIR/tests/test_run_cell.sh"
if [[ ! -x "$TEST_RUN_CELL" ]]; then
  fail "driver-rebuild: $TEST_RUN_CELL missing or not executable"
else
  TEST_OUT="$(bash "$TEST_RUN_CELL" 2>&1)"
  TEST_RC=$?
  if [[ "$TEST_RC" -eq 0 ]] && echo "$TEST_OUT" | grep -q 'TEST_RUN_CELL: ALL CHECKS PASSED'; then
    pass "driver-rebuild: model-free integration test (heartbeat + max-problems stop + --fresh reset + no orphaned process) passed"
  else
    fail "driver-rebuild: integration test failed (rc=$TEST_RC)"
    echo "$TEST_OUT"
  fi
fi

# ---------------------------------------------------------------------------
# 4. smoke: live pi run artifact
# ---------------------------------------------------------------------------
# run_cell.sh copies the cell's export.json to
# pi/artifacts/<provider>/<model>/<thinking>/<language>_export.json after
# every run. Search recursively (not a flat glob) since the grid-keying
# change nests the artifact path -- any grid point's export qualifies as the
# smoke proof. NOTE: this deliberately does NOT require re-running a live
# model under the new --provider-required CLI: the underlying pi<->harness
# interaction the smoke proves (a real model issuing real harness commands
# and getting a real graded submission) is unchanged by relocating where the
# artifact is written; the model-free integration test above is what proves
# the NEW nested-path mechanics work.
SMOKE_EXPORT="$(find "$PI_DIR/artifacts" -name '*_export.json' 2>/dev/null | head -1)"
if [[ -z "$SMOKE_EXPORT" || ! -f "$SMOKE_EXPORT" ]]; then
  fail "smoke: no *_export.json found under pi/artifacts/ -- run the live pi smoke test first (pi/run_cell.sh ...)"
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
if grep -q -- "--provider" "$README" && grep -q -- "--thinking" "$README" \
   && grep -q -- "--fresh" "$README" && grep -qi "grid" "$README"; then
  pass "docs: pi/README.md documents --provider/--thinking/--fresh and the grid layout"
else
  fail "docs: pi/README.md missing --provider/--thinking/--fresh or grid-layout documentation"
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

# The on-demand grid-cell tree must not be tracked (it's regenerated locally
# per provider/model/thinking/language, never committed).
if git ls-files experiments/01_main_experiments/pi/ | grep -q .; then
  fail "hygiene: experiments/01_main_experiments/pi/ still has tracked files (should be git-ignored, built on demand)"
else
  pass "hygiene: experiments/01_main_experiments/pi/ (on-demand grid cells) has no tracked files"
fi
if grep -q 'experiments/01_main_experiments/pi/' "$REPO_ROOT/.gitignore"; then
  pass "hygiene: .gitignore covers the on-demand grid-cell tree"
else
  fail "hygiene: .gitignore does not cover experiments/01_main_experiments/pi/"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "AUDIT: ALL CHECKS PASSED"
  exit 0
else
  echo "AUDIT: FAILURES ABOVE"
  exit 1
fi

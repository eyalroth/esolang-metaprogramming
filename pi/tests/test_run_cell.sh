#!/usr/bin/env bash
# Model-free integration test for pi/run_cell.sh's control flow: the
# heartbeat, the --max-problems watchdog stop, --fresh state reset, and
# process-group cleanup. Drives pi/tests/fake_pi.sh (PI_BIN override -- no
# network, no real model) against the TRACKED, REDACTED private dataset
# (never the real one, and never requires it) -- submissions all come back
# WRONG ANSWER, which is fine; this test only cares that problems get
# fetched/finalized and that run_cell.sh's own control flow behaves
# correctly.
#
# Uses synthetic --provider/--model/--thinking grid coordinates ("test-*")
# so it never touches any real grid cell's live-smoke-tested export
# artifact, and deliberately runs against the "befunge-98" language so it
# never touches the "brainfuck" cell either.
set -uo pipefail

PI_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_DIR="$(cd "$PI_TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PI_DIR/.." && pwd)"

LANGUAGE="befunge-98"
REDACTED_DATASET="$REPO_ROOT/benchmark_harness/private/esolang_full_private.json"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

if [[ ! -f "$REDACTED_DATASET" ]]; then
  fail "redacted dataset missing at $REDACTED_DATASET"
  echo "TEST_RUN_CELL: FAILURES ABOVE"; exit 1
fi

# resolve_cell provider model thinking language -- calls setup_cells.py (the
# single source of truth run_cell.sh itself uses) and echoes "CELL_DIR ARTIFACT".
resolve_cell() {
  local provider="$1" model="$2" thinking="$3" language="$4"
  local out
  out="$(python3 "$PI_DIR/setup_cells.py" --provider "$provider" --model "$model" --thinking "$thinking" --language "$language")"
  local cell art
  cell="$(sed -n 's/^CELL_DIR=//p' <<<"$out" | tail -1)"
  art="$(sed -n 's/^ARTIFACT=//p' <<<"$out" | tail -1)"
  echo "$cell" "$art"
}

# ===========================================================================
# Scenario 1: continuous run, heartbeat, --max-problems watchdog stop.
# ===========================================================================
echo "--- scenario 1: heartbeat + --max-problems stop ---"

S1_PROVIDER="test-provider-s1"
S1_MODEL="fake-model"
S1_THINKING="low"

read -r S1_CELL_DIR S1_ARTIFACT < <(resolve_cell "$S1_PROVIDER" "$S1_MODEL" "$S1_THINKING" "$LANGUAGE")
rm -f "$S1_CELL_DIR"/harness_state.json "$S1_CELL_DIR"/export.json "$S1_CELL_DIR"/fake_*.bf "$S1_CELL_DIR"/.run_cell.log
rm -rf "$S1_CELL_DIR"/.pi-sessions
rm -f "$S1_ARTIFACT"

RUN_OUT="$(mktemp)"
PI_BIN="$PI_TESTS_DIR/fake_pi.sh" FAKE_PI_CYCLES=15 FAKE_PI_SLEEP=1 \
  FAKE_PI_MODELS="$S1_PROVIDER/$S1_MODEL" \
  "$PI_DIR/run_cell.sh" --model "$S1_MODEL" --provider "$S1_PROVIDER" --thinking "$S1_THINKING" \
    --language "$LANGUAGE" --max-problems 2 --heartbeat-interval 1 --stall-timeout 60 \
    --dataset-file "$REDACTED_DATASET" > "$RUN_OUT" 2>&1
RC=$?

[[ "$RC" -eq 0 ]] && pass "run_cell.sh exited 0" || { fail "run_cell.sh exited $RC"; cat "$RUN_OUT"; }

grep -q '\[run_cell\] heartbeat' "$RUN_OUT" \
  && pass "at least one heartbeat line was printed" \
  || { fail "no heartbeat line found"; cat "$RUN_OUT"; }

grep -q 'reached --max-problems=2' "$RUN_OUT" \
  && pass "the run stopped via the --max-problems watchdog (not natural completion or a stall)" \
  || { fail "expected a --max-problems stop message"; cat "$RUN_OUT"; }

grep -q 'STALL DETECTED' "$RUN_OUT" \
  && fail "a spurious stall was detected during a healthy run" \
  || pass "no spurious stall detected"

grep -q 'verified effective model matches request' "$RUN_OUT" \
  && pass "effective-model verification passed (fake_pi.sh's booted model matched the request)" \
  || { fail "expected an effective-model verification success line"; cat "$RUN_OUT"; }

# The default --session-id must encode the FULL grid coordinates (provider,
# model, thinking), not just the language -- the fix for the real bug where
# a language-only session-id let one grid cell's sticky model entry leak
# onto a later run requesting a DIFFERENT model.
if ls "$S1_CELL_DIR"/.pi-sessions/*"$S1_PROVIDER"*"$S1_MODEL"*"$S1_THINKING"* >/dev/null 2>&1; then
  pass "default --session-id encodes the full grid coordinates (provider/model/thinking found in the session file name)"
else
  fail "expected the default --session-id to include provider/model/thinking grid coordinates"
  ls -la "$S1_CELL_DIR"/.pi-sessions/ 2>&1
fi

# Default (no --compaction flag) must enable auto-compaction for the child
# via a cell-local .pi/settings.json, matching the paper's own harnesses.
if [[ -f "$S1_CELL_DIR/.pi/settings.json" ]] && grep -q '"enabled":true' "$S1_CELL_DIR/.pi/settings.json"; then
  pass "cell-local .pi/settings.json enables compaction by default"
else
  fail "expected $S1_CELL_DIR/.pi/settings.json to enable compaction by default"
  cat "$S1_CELL_DIR/.pi/settings.json" 2>&1
fi

if grep -q "ARTIFACT=$S1_ARTIFACT\|copied to $S1_ARTIFACT" "$RUN_OUT" || [[ -f "$S1_ARTIFACT" ]]; then
  pass "artifact landed at the nested grid path ($S1_ARTIFACT)"
else
  fail "artifact NOT found at the expected nested grid path $S1_ARTIFACT"
fi

if [[ -f "$S1_ARTIFACT" ]]; then
  python3 - "$S1_ARTIFACT" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
probs = d["problems"]
attempted = [pid for pid, p in probs.items() if p["submissions"] or p["status"] not in ("pending",)]
subs = sum(len(p["submissions"]) for p in probs.values())
assert len(attempted) >= 2, f"expected >=2 attempted, got {len(attempted)}: {attempted}"
assert subs >= 1, f"expected >=1 submission, got {subs}"
print(f"attempted={len(attempted)} submissions={subs}")
PYEOF
  [[ $? -eq 0 ]] \
    && pass "artifact shows >=2 attempted problems with >=1 submission" \
    || fail "artifact did not meet the >=2 attempted / >=1 submission bar"
fi

sleep 1
if ps -A -o command | grep -F "$PI_TESTS_DIR/fake_pi.sh" | grep -v grep > /dev/null; then
  fail "a fake_pi.sh process is still running after run_cell.sh exited (process-group leak)"
else
  pass "no orphaned fake_pi.sh process after run_cell.sh exited"
fi

rm -f "$S1_CELL_DIR"/harness_state.json "$S1_CELL_DIR"/export.json "$S1_CELL_DIR"/fake_*.bf "$S1_CELL_DIR"/.run_cell.log
rm -rf "$S1_CELL_DIR"/.pi-sessions
rm -f "$S1_ARTIFACT"
rm -rf "$REPO_ROOT/experiments/01_main_experiments/pi/$S1_PROVIDER"
rm -rf "$PI_DIR/artifacts/$S1_PROVIDER"
rm -f "$RUN_OUT"

# ===========================================================================
# Scenario 2: --fresh resets prior grid-cell state.
# ===========================================================================
echo
echo "--- scenario 2: --fresh flag resets prior state ---"

S2_PROVIDER="test-provider-s2"
S2_MODEL="fake-model"
S2_THINKING="low"

read -r S2_CELL_DIR S2_ARTIFACT < <(resolve_cell "$S2_PROVIDER" "$S2_MODEL" "$S2_THINKING" "$LANGUAGE")
rm -f "$S2_CELL_DIR"/harness_state.json "$S2_CELL_DIR"/export.json "$S2_CELL_DIR"/*.bf "$S2_CELL_DIR"/.run_cell.log
rm -rf "$S2_CELL_DIR"/.pi-sessions
rm -f "$S2_ARTIFACT"

# Seed prior state: init + fetch (activates E01) + one submission -- standing
# in for "a previous run already touched this exact grid cell".
(
  cd "$S2_CELL_DIR"
  export HARNESS_PRIVATE_FILE="$REDACTED_DATASET"
  python3 harness.py init --language "$LANGUAGE" > /dev/null
  python3 harness.py fetch > /dev/null
  printf '.' > seed.bf
  python3 harness.py submit E01 seed.bf > /dev/null
)
SEEDED_SUBS="$(python3 -c "
import json
d = json.load(open('$S2_CELL_DIR/harness_state.json'))
print(sum(len(p['submissions']) for p in d['problems'].values()))
")"
[[ "$SEEDED_SUBS" -ge 1 ]] \
  && pass "scenario 2 setup: seeded prior state has >=1 submission ($SEEDED_SUBS)" \
  || fail "scenario 2 setup: failed to seed prior state (got $SEEDED_SUBS submissions)"

FRESH_OUT="$(mktemp)"
PI_BIN="$PI_TESTS_DIR/fake_pi.sh" FAKE_PI_CYCLES=1 FAKE_PI_SLEEP=1 \
  FAKE_PI_MODELS="$S2_PROVIDER/$S2_MODEL" \
  "$PI_DIR/run_cell.sh" --model "$S2_MODEL" --provider "$S2_PROVIDER" --thinking "$S2_THINKING" \
    --language "$LANGUAGE" --fresh --max-continuations 0 --heartbeat-interval 1 --stall-timeout 60 \
    --dataset-file "$REDACTED_DATASET" > "$FRESH_OUT" 2>&1

grep -qi 'resetting.*cell.*state\|--fresh' "$FRESH_OUT" \
  && pass "scenario 2: run_cell.sh logged the --fresh reset" \
  || { fail "scenario 2: no --fresh reset log line found"; cat "$FRESH_OUT"; }

# NOTE: --fresh's contract only covers harness_state.json/export.json/
# .pi-sessions -- not arbitrary leftover code files like seed.bf (submitted
# code deliberately stays around for inspection). The real proof of a clean
# reset is the submission count below, not file presence.
RESET_SUBS="$(python3 -c "
import json
d = json.load(open('$S2_CELL_DIR/harness_state.json'))
print(sum(len(p['submissions']) for p in d['problems'].values()))
")"
# After --fresh + exactly one attempt (--max-continuations 0) of a 1-cycle
# fake_pi run: fetch activates E01 fresh, one submit records exactly 1
# submission. If --fresh had NOT cleared the prior state, this would instead
# show the pre-seeded submission plus more (or a different current problem).
if [[ "$RESET_SUBS" -eq 1 ]]; then
  pass "scenario 2: exactly 1 submission after --fresh + 1 cycle (prior seeded state was cleared, not accumulated)"
else
  fail "scenario 2: expected exactly 1 submission after --fresh, got $RESET_SUBS"
  cat "$FRESH_OUT"
fi

rm -f "$S2_CELL_DIR"/harness_state.json "$S2_CELL_DIR"/export.json "$S2_CELL_DIR"/*.bf "$S2_CELL_DIR"/.run_cell.log
rm -rf "$S2_CELL_DIR"/.pi-sessions
rm -f "$S2_ARTIFACT"
rm -rf "$REPO_ROOT/experiments/01_main_experiments/pi/$S2_PROVIDER"
rm -rf "$PI_DIR/artifacts/$S2_PROVIDER"
rm -f "$FRESH_OUT"

# ===========================================================================
# Scenario 3: a nonexistent model is REJECTED, not silently run.
# ===========================================================================
echo
echo "--- scenario 3: nonexistent model is rejected ---"

S3_PROVIDER="test-provider-s3"
S3_REAL_MODEL="fake-model"
S3_BOGUS_MODEL="this-model-does-not-exist-xyz"
S3_THINKING="low"

BOGUS_OUT="$(mktemp)"
# FAKE_PI_MODELS only advertises S3_REAL_MODEL -- S3_BOGUS_MODEL must NOT
# resolve, so run_cell.sh's pre-flight must refuse to run at all (no cell
# should even get built).
PI_BIN="$PI_TESTS_DIR/fake_pi.sh" FAKE_PI_MODELS="$S3_PROVIDER/$S3_REAL_MODEL" \
  "$PI_DIR/run_cell.sh" --model "$S3_BOGUS_MODEL" --provider "$S3_PROVIDER" --thinking "$S3_THINKING" \
    --language "$LANGUAGE" --dataset-file "$REDACTED_DATASET" > "$BOGUS_OUT" 2>&1
BOGUS_RC=$?

if [[ "$BOGUS_RC" -ne 0 ]] && grep -q "$S3_BOGUS_MODEL" "$BOGUS_OUT"; then
  pass "scenario 3: run_cell.sh rejects a nonexistent model (exit $BOGUS_RC, error names the bad model)"
else
  fail "scenario 3: expected non-zero exit + the bogus model named in the error, got rc=$BOGUS_RC"
  cat "$BOGUS_OUT"
fi

S3_CELL_DIR_IF_BUILT="$REPO_ROOT/experiments/01_main_experiments/pi/$S3_PROVIDER/$S3_BOGUS_MODEL/$S3_THINKING/$LANGUAGE"
if [[ -e "$S3_CELL_DIR_IF_BUILT" ]]; then
  fail "scenario 3: a cell was built for the rejected model at $S3_CELL_DIR_IF_BUILT -- the pre-flight must reject BEFORE building anything"
else
  pass "scenario 3: no cell was built for the rejected model (pre-flight ran before any cell/setup work)"
fi

rm -rf "$REPO_ROOT/experiments/01_main_experiments/pi/$S3_PROVIDER"
rm -rf "$PI_DIR/artifacts/$S3_PROVIDER"
rm -f "$BOGUS_OUT"

# ===========================================================================
# Scenario 4: the effective model pi ACTUALLY booted differs from what was
# requested (an operator's pi config silently overrode it, e.g. a sticky
# per-session model default) -- run_cell.sh must detect this and kill the
# run rather than file results under the wrong grid path.
# ===========================================================================
echo
echo "--- scenario 4: effective-model mismatch is detected and kills the run ---"

S4_PROVIDER="test-provider-s4"
S4_MODEL="fake-model"
S4_THINKING="low"
S4_WRONG_MODEL="sneaky-substituted-model"

read -r S4_CELL_DIR S4_ARTIFACT < <(resolve_cell "$S4_PROVIDER" "$S4_MODEL" "$S4_THINKING" "$LANGUAGE")
rm -f "$S4_CELL_DIR"/harness_state.json "$S4_CELL_DIR"/export.json "$S4_CELL_DIR"/fake_*.bf "$S4_CELL_DIR"/.run_cell.log
rm -rf "$S4_CELL_DIR"/.pi-sessions
rm -f "$S4_ARTIFACT"

# The override lands as a SEPARATE, LATER model_change (FAKE_PI_OVERRIDE_DELAY
# after the boot event, default 1s) -- proving run_cell.sh's settle-based
# check catches a late override, not just a mismatch present from the very
# first model_change it happens to see (a first-found-wins check would read
# the correct BOOT event and pass, missing the override entirely).
# The override delay MUST be well SHORTER than the settle window (the
# override needs to have already landed before run_cell.sh would otherwise
# have declared the boot value "stable") -- 0.5s delay vs. the default 2s
# settle leaves a comfortable margin either way.
MISMATCH_OUT="$(mktemp)"
PI_BIN="$PI_TESTS_DIR/fake_pi.sh" \
  FAKE_PI_MODELS="$S4_PROVIDER/$S4_MODEL" \
  FAKE_PI_EFFECTIVE_MODEL="$S4_WRONG_MODEL" \
  FAKE_PI_OVERRIDE_DELAY=0.5 FAKE_PI_OVERRIDE_IDLE=30 \
  "$PI_DIR/run_cell.sh" --model "$S4_MODEL" --provider "$S4_PROVIDER" --thinking "$S4_THINKING" \
    --language "$LANGUAGE" --heartbeat-interval 1 --stall-timeout 15 \
    --effective-model-wait 10 \
    --dataset-file "$REDACTED_DATASET" > "$MISMATCH_OUT" 2>&1
MISMATCH_RC=$?

if [[ "$MISMATCH_RC" -ne 0 ]] && grep -q "model=$S4_MODEL" "$MISMATCH_OUT" && grep -q "model=$S4_WRONG_MODEL" "$MISMATCH_OUT"; then
  pass "scenario 4: run_cell.sh detects the effective-model mismatch and exits non-zero, naming both requested ($S4_MODEL) and effective ($S4_WRONG_MODEL)"
else
  fail "scenario 4: expected non-zero exit + both model names in the error, got rc=$MISMATCH_RC"
  cat "$MISMATCH_OUT"
fi

if [[ -f "$S4_CELL_DIR/harness_state.json" ]]; then
  S4_SUBS="$(python3 -c "
import json
d = json.load(open('$S4_CELL_DIR/harness_state.json'))
print(sum(len(p['submissions']) for p in d['problems'].values()))
" 2>/dev/null || echo 0)"
else
  S4_SUBS=0
fi
if [[ "$S4_SUBS" -eq 0 ]]; then
  pass "scenario 4: no submissions were made -- the mismatch was caught before any problem work happened"
else
  fail "scenario 4: expected 0 submissions (killed before problem work), got $S4_SUBS"
fi

sleep 1
if ps -A -o command | grep -F "$PI_TESTS_DIR/fake_pi.sh" | grep -v grep > /dev/null; then
  fail "scenario 4: a fake_pi.sh process is still running after the mismatch kill (process-group leak)"
else
  pass "scenario 4: no orphaned fake_pi.sh process after the mismatch kill"
fi

rm -f "$S4_CELL_DIR"/harness_state.json "$S4_CELL_DIR"/export.json "$S4_CELL_DIR"/fake_*.bf "$S4_CELL_DIR"/.run_cell.log
rm -rf "$S4_CELL_DIR"/.pi-sessions
rm -f "$S4_ARTIFACT"
rm -rf "$REPO_ROOT/experiments/01_main_experiments/pi/$S4_PROVIDER"
rm -rf "$PI_DIR/artifacts/$S4_PROVIDER"
rm -f "$MISMATCH_OUT"

# ===========================================================================
# Scenario 5: --compaction off writes a cell-local .pi/settings.json that
# DISABLES compaction (the escape hatch -- default is ON, see scenario 1).
# ===========================================================================
echo
echo "--- scenario 5: --compaction off disables compaction in the cell-local settings ---"

S5_PROVIDER="test-provider-s5"
S5_MODEL="fake-model"
S5_THINKING="low"

read -r S5_CELL_DIR S5_ARTIFACT < <(resolve_cell "$S5_PROVIDER" "$S5_MODEL" "$S5_THINKING" "$LANGUAGE")
rm -f "$S5_CELL_DIR"/harness_state.json "$S5_CELL_DIR"/export.json "$S5_CELL_DIR"/fake_*.bf "$S5_CELL_DIR"/.run_cell.log
rm -rf "$S5_CELL_DIR"/.pi-sessions "$S5_CELL_DIR"/.pi
rm -f "$S5_ARTIFACT"

COMPACTION_OFF_OUT="$(mktemp)"
PI_BIN="$PI_TESTS_DIR/fake_pi.sh" FAKE_PI_CYCLES=1 FAKE_PI_SLEEP=1 \
  FAKE_PI_MODELS="$S5_PROVIDER/$S5_MODEL" \
  "$PI_DIR/run_cell.sh" --model "$S5_MODEL" --provider "$S5_PROVIDER" --thinking "$S5_THINKING" \
    --language "$LANGUAGE" --compaction off --max-continuations 0 --heartbeat-interval 1 --stall-timeout 60 \
    --dataset-file "$REDACTED_DATASET" > "$COMPACTION_OFF_OUT" 2>&1

if [[ -f "$S5_CELL_DIR/.pi/settings.json" ]] && grep -q '"enabled":false' "$S5_CELL_DIR/.pi/settings.json"; then
  pass "scenario 5: --compaction off writes a cell-local .pi/settings.json with compaction disabled"
else
  fail "scenario 5: expected $S5_CELL_DIR/.pi/settings.json to disable compaction"
  cat "$COMPACTION_OFF_OUT"
fi

rm -f "$S5_CELL_DIR"/harness_state.json "$S5_CELL_DIR"/export.json "$S5_CELL_DIR"/fake_*.bf "$S5_CELL_DIR"/.run_cell.log
rm -rf "$S5_CELL_DIR"/.pi-sessions "$S5_CELL_DIR"/.pi
rm -f "$S5_ARTIFACT"
rm -rf "$REPO_ROOT/experiments/01_main_experiments/pi/$S5_PROVIDER"
rm -rf "$PI_DIR/artifacts/$S5_PROVIDER"
rm -f "$COMPACTION_OFF_OUT"

# ===========================================================================
# Scenario 6: a corrupted/unreadable harness_state.json (the observed
# heartbeat-vs-child-write race) must NOT leak a Python traceback or an
# empty-metric heartbeat line, and run_cell.sh must still terminate cleanly
# (via the stall watchdog, since the corrupt-state child never progresses).
# ===========================================================================
echo
echo "--- scenario 6: a corrupted harness_state.json doesn't crash or leak a traceback ---"

S6_PROVIDER="test-provider-s6"
S6_MODEL="fake-model"
S6_THINKING="low"

read -r S6_CELL_DIR S6_ARTIFACT < <(resolve_cell "$S6_PROVIDER" "$S6_MODEL" "$S6_THINKING" "$LANGUAGE")
rm -f "$S6_CELL_DIR"/harness_state.json "$S6_CELL_DIR"/export.json "$S6_CELL_DIR"/fake_*.bf "$S6_CELL_DIR"/.run_cell.log
rm -rf "$S6_CELL_DIR"/.pi-sessions "$S6_CELL_DIR"/.pi
rm -f "$S6_ARTIFACT"

CORRUPT_OUT="$(mktemp)"
PI_BIN="$PI_TESTS_DIR/fake_pi.sh" \
  FAKE_PI_MODELS="$S6_PROVIDER/$S6_MODEL" \
  FAKE_PI_CORRUPT_STATE=1 FAKE_PI_CORRUPT_IDLE=30 \
  "$PI_DIR/run_cell.sh" --model "$S6_MODEL" --provider "$S6_PROVIDER" --thinking "$S6_THINKING" \
    --language "$LANGUAGE" --heartbeat-interval 1 --stall-timeout 8 \
    --dataset-file "$REDACTED_DATASET" > "$CORRUPT_OUT" 2>&1
CORRUPT_RC=$?

if grep -qi 'Traceback' "$CORRUPT_OUT"; then
  fail "scenario 6: a Python traceback leaked into run_cell.sh's own output"
  cat "$CORRUPT_OUT"
else
  pass "scenario 6: no Python traceback leaked despite a persistently corrupt harness_state.json"
fi

if grep -qE 'heartbeat -- solved=/80|solved= failed=' "$CORRUPT_OUT"; then
  fail "scenario 6: an empty/garbled-metric heartbeat line was printed"
else
  pass "scenario 6: heartbeat lines kept sane (last-known) metrics despite the corrupt state file"
fi

if grep -q '\[run_cell\] heartbeat' "$CORRUPT_OUT"; then
  pass "scenario 6: heartbeat kept running against the corrupt state file (didn't abort the loop)"
else
  fail "scenario 6: expected at least one heartbeat line"
  cat "$CORRUPT_OUT"
fi

if [[ "$CORRUPT_RC" -ne 0 ]] && grep -qi 'STALL DETECTED' "$CORRUPT_OUT"; then
  pass "scenario 6: run_cell.sh still terminated cleanly via the stall watchdog (rc=$CORRUPT_RC)"
else
  fail "scenario 6: expected a stall-watchdog termination, got rc=$CORRUPT_RC"
  cat "$CORRUPT_OUT"
fi

sleep 1
if ps -A -o command | grep -F "$PI_TESTS_DIR/fake_pi.sh" | grep -v grep > /dev/null; then
  fail "scenario 6: a fake_pi.sh process is still running after the stall kill (process-group leak)"
else
  pass "scenario 6: no orphaned fake_pi.sh process after the stall kill"
fi

rm -f "$S6_CELL_DIR"/harness_state.json "$S6_CELL_DIR"/export.json "$S6_CELL_DIR"/fake_*.bf "$S6_CELL_DIR"/.run_cell.log
rm -rf "$S6_CELL_DIR"/.pi-sessions "$S6_CELL_DIR"/.pi
rm -f "$S6_ARTIFACT"
rm -rf "$REPO_ROOT/experiments/01_main_experiments/pi/$S6_PROVIDER"
rm -rf "$PI_DIR/artifacts/$S6_PROVIDER"
rm -f "$CORRUPT_OUT"

# ===========================================================================
# Scenario 7: RESUMING a cell whose pre-existing session file carries an OLD
# mtime must NOT be insta-killed by the stall watchdog (the real bug: the
# watchdog used to trust the file's absolute mtime as the inactivity
# baseline, so a resume launched more than --stall-timeout after the prior
# run -- including across a machine suspend -- was killed on its very first
# heartbeat, before the new child ever wrote a byte).
# ===========================================================================
echo
echo "--- scenario 7: resuming a stale-mtime session is not insta-killed by the stall watchdog ---"

S7_PROVIDER="test-provider-s7"
S7_MODEL="fake-model"
S7_THINKING="low"

read -r S7_CELL_DIR S7_ARTIFACT < <(resolve_cell "$S7_PROVIDER" "$S7_MODEL" "$S7_THINKING" "$LANGUAGE")
rm -f "$S7_CELL_DIR"/harness_state.json "$S7_CELL_DIR"/export.json "$S7_CELL_DIR"/fake_*.bf "$S7_CELL_DIR"/.run_cell.log
rm -rf "$S7_CELL_DIR"/.pi-sessions "$S7_CELL_DIR"/.pi
rm -f "$S7_ARTIFACT"

# Pre-seed the DEFAULT session file (same naming run_cell.sh itself derives:
# pi-esolang-<provider>-<model>-<thinking>-<language>, no slugging needed --
# these test coordinates contain no characters that slug() would touch)
# with a boot event, then backdate its mtime by an hour -- simulating
# exactly what a real resumed cell's session file looks like: legitimate
# boot events already present from a PRIOR run, with an mtime far older
# than --stall-timeout.
S7_SESSION_DIR="$S7_CELL_DIR/.pi-sessions"
S7_SESSION_ID="pi-esolang-${S7_PROVIDER}-${S7_MODEL}-${S7_THINKING}-${LANGUAGE}"
mkdir -p "$S7_SESSION_DIR"
S7_SESSION_FILE="$S7_SESSION_DIR/${S7_SESSION_ID}.jsonl"
printf '%s\n' \
  "{\"type\":\"model_change\",\"provider\":\"$S7_PROVIDER\",\"modelId\":\"$S7_MODEL\"}" \
  "{\"type\":\"thinking_level_change\",\"thinkingLevel\":\"$S7_THINKING\"}" \
  > "$S7_SESSION_FILE"
python3 -c "import os,time; t=time.time()-3600; os.utime('$S7_SESSION_FILE', (t,t))"

RESUME_OUT="$(mktemp)"
PI_BIN="$PI_TESTS_DIR/fake_pi.sh" FAKE_PI_CYCLES=15 FAKE_PI_SLEEP=1 FAKE_PI_STARTUP_DELAY=4 \
  FAKE_PI_MODELS="$S7_PROVIDER/$S7_MODEL" \
  "$PI_DIR/run_cell.sh" --model "$S7_MODEL" --provider "$S7_PROVIDER" --thinking "$S7_THINKING" \
    --language "$LANGUAGE" --max-problems 2 --heartbeat-interval 1 --stall-timeout 10 \
    --dataset-file "$REDACTED_DATASET" > "$RESUME_OUT" 2>&1
RESUME_RC=$?

if grep -qi 'STALL DETECTED' "$RESUME_OUT"; then
  fail "scenario 7: the stall watchdog false-killed a resumed run over its pre-existing session file's old mtime"
  cat "$RESUME_OUT"
else
  pass "scenario 7: resuming a stale-mtime session file did not trigger a false STALL DETECTED"
fi

if grep -q 'verified effective model matches request' "$RESUME_OUT"; then
  pass "scenario 7: effective-model verification still passed on resume (reading the pre-seeded boot event)"
else
  fail "scenario 7: expected effective-model verification to pass on resume"
  cat "$RESUME_OUT"
fi

if [[ "$RESUME_RC" -eq 0 ]]; then
  pass "scenario 7: run_cell.sh exited 0 (reached --max-problems normally, not killed)"
else
  fail "scenario 7: expected run_cell.sh to exit 0, got rc=$RESUME_RC"
  cat "$RESUME_OUT"
fi

sleep 1
if ps -A -o command | grep -F "$PI_TESTS_DIR/fake_pi.sh" | grep -v grep > /dev/null; then
  fail "scenario 7: a fake_pi.sh process is still running after run_cell.sh exited (process-group leak)"
else
  pass "scenario 7: no orphaned fake_pi.sh process after run_cell.sh exited"
fi

rm -f "$S7_CELL_DIR"/harness_state.json "$S7_CELL_DIR"/export.json "$S7_CELL_DIR"/fake_*.bf "$S7_CELL_DIR"/.run_cell.log
rm -rf "$S7_CELL_DIR"/.pi-sessions "$S7_CELL_DIR"/.pi
rm -f "$S7_ARTIFACT"
rm -rf "$REPO_ROOT/experiments/01_main_experiments/pi/$S7_PROVIDER"
rm -rf "$PI_DIR/artifacts/$S7_PROVIDER"
rm -f "$RESUME_OUT"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "TEST_RUN_CELL: ALL CHECKS PASSED"
  exit 0
else
  echo "TEST_RUN_CELL: FAILURES ABOVE"
  exit 1
fi

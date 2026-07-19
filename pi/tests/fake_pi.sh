#!/usr/bin/env bash
# Deterministic stand-in for the real `pi` CLI, used by the model-free
# integration test (pi/tests/test_run_cell.sh) to exercise run_cell.sh's
# control flow -- heartbeat, stall watchdog, --max-problems stop, and
# process-group cleanup -- WITHOUT any network call or real model.
#
# It is invoked exactly like run_cell.sh invokes the real `pi -p ...`, from
# the cell directory, with HARNESS_PRIVATE_FILE already exported. It ignores
# every real pi flag except --session-dir/--session-id (used to write a
# growing "session .jsonl" so run_cell.sh's liveness check has something
# real to observe), and drives the harness itself through a number of
# fetch+submit cycles (submissions are garbage -- WRONG ANSWER is fine, the
# point is to finalize problems and generate real submissions, not to solve
# them).
#
# Also stands in for `pi --list-models`, since run_cell.sh's model-existence
# pre-flight calls `$PI_BIN --list-models` and requires an exact
# "provider/model" row -- set FAKE_PI_MODELS (space-separated
# "provider/model" pairs) to control which pairs this stub reports as
# existing; defaults to test-provider-s1/fake-model and
# test-provider-s2/fake-model (the pairs the test scenarios use).
#
# It also writes a model_change/thinking_level_change BOOT event immediately
# at startup (the CLI-resolved model -- what a real pi always writes first),
# mimicking what run_cell.sh's effective-model verification reads back. By
# default there is no further change (so a normal run's verification
# passes). Set FAKE_PI_EFFECTIVE_PROVIDER / FAKE_PI_EFFECTIVE_MODEL /
# FAKE_PI_EFFECTIVE_THINKING to simulate an operator's pi config silently
# OVERRIDING the request: this stub then sleeps FAKE_PI_OVERRIDE_DELAY
# seconds (default 1) and writes a SECOND, LATER model_change/
# thinking_level_change with the override values -- mirroring the real bug
# (two model_change events ~130ms apart, the second one wrong) -- then does
# NOT run any fetch/submit cycle (idles until killed), since the point of
# that path is purely to exercise run_cell.sh's detection+kill, not harness
# interaction.
#
# Set FAKE_PI_CORRUPT_STATE to simulate the observed harness_state.json
# read/write race: this stub corrupts the state file with invalid JSON, then
# idles (FAKE_PI_CORRUPT_IDLE, default 30s) -- exercising run_cell.sh's
# heartbeat resilience (retry + keep last-known ST_* values + no leaked
# Python traceback) against a state file that's persistently unreadable.
set -uo pipefail

SESSION_DIR=""
SESSION_ID=""
LIST_MODELS=""
MODEL=""
PROVIDER=""
THINKING=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list-models) LIST_MODELS=1; shift 1 ;;
    --session-dir) SESSION_DIR="${2:-}"; shift 2 ;;
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --provider) PROVIDER="${2:-}"; shift 2 ;;
    --thinking) THINKING="${2:-}"; shift 2 ;;
    --tools) shift 2 ;;
    -p|--print|-a) shift 1 ;;
    *) shift 1 ;;
  esac
done

if [[ -n "$LIST_MODELS" ]]; then
  echo "provider        model"
  for pair in ${FAKE_PI_MODELS:-test-provider-s1/fake-model test-provider-s2/fake-model}; do
    printf '%s\t%s\n' "${pair%%/*}" "${pair#*/}"
  done
  exit 0
fi

if [[ -z "$SESSION_DIR" || -z "$SESSION_ID" ]]; then
  echo "fake_pi.sh: missing --session-dir/--session-id" >&2
  exit 1
fi
mkdir -p "$SESSION_DIR"
SESSION_FILE="$SESSION_DIR/${SESSION_ID}.jsonl"

# BOOT event: always the CLI-resolved (requested) model -- exactly what a
# real pi writes first, before any override extension can act.
echo "{\"type\":\"model_change\",\"provider\":\"$PROVIDER\",\"modelId\":\"$MODEL\"}" >> "$SESSION_FILE"
echo "{\"type\":\"thinking_level_change\",\"thinkingLevel\":\"$THINKING\"}" >> "$SESSION_FILE"

EFF_PROVIDER="${FAKE_PI_EFFECTIVE_PROVIDER:-$PROVIDER}"
EFF_MODEL="${FAKE_PI_EFFECTIVE_MODEL:-$MODEL}"
EFF_THINKING="${FAKE_PI_EFFECTIVE_THINKING:-$THINKING}"
if [[ "$EFF_PROVIDER" != "$PROVIDER" || "$EFF_MODEL" != "$MODEL" || "$EFF_THINKING" != "$THINKING" ]]; then
  # Simulate a LATE silent override: a SEPARATE model_change/
  # thinking_level_change a short delay after boot, then no harness work --
  # idle until run_cell.sh's kill terminates this process (SIGTERM/SIGKILL).
  sleep "${FAKE_PI_OVERRIDE_DELAY:-1}"
  echo "{\"type\":\"model_change\",\"provider\":\"$EFF_PROVIDER\",\"modelId\":\"$EFF_MODEL\"}" >> "$SESSION_FILE"
  echo "{\"type\":\"thinking_level_change\",\"thinkingLevel\":\"$EFF_THINKING\"}" >> "$SESSION_FILE"
  sleep "${FAKE_PI_OVERRIDE_IDLE:-30}"
  exit 0
fi

# Simulate the observed harness_state.json read/write race: corrupt the
# state file (invalid JSON) and then idle -- exercising run_cell.sh's
# heartbeat resilience (retry + keep-last-known + no leaked traceback)
# against a state file that's PERSISTENTLY unreadable for a while, a
# superset of the real, transient race.
if [[ -n "${FAKE_PI_CORRUPT_STATE:-}" ]]; then
  printf '{not valid json' > harness_state.json
  sleep "${FAKE_PI_CORRUPT_IDLE:-30}"
  exit 0
fi

CYCLES="${FAKE_PI_CYCLES:-15}"
SLEEP_S="${FAKE_PI_SLEEP:-1}"

for ((i = 1; i <= CYCLES; i++)); do
  echo "{\"type\":\"fake_turn_start\",\"i\":$i}" >> "$SESSION_FILE"

  python3 harness.py fetch > /dev/null 2>&1
  pid="$(python3 -c "import json;print(json.load(open('harness_state.json'))['current_problem'])" 2>/dev/null)"
  if [[ -z "$pid" || "$pid" == "None" ]]; then
    echo "{\"type\":\"fake_turn_no_more_problems\",\"i\":$i}" >> "$SESSION_FILE"
    break
  fi

  printf '.' > "fake_${i}.bf"
  python3 harness.py submit "$pid" "fake_${i}.bf" > /dev/null 2>&1

  echo "{\"type\":\"fake_turn_end\",\"i\":$i,\"problem\":\"$pid\"}" >> "$SESSION_FILE"
  sleep "$SLEEP_S"
done

exit 0

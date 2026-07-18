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
set -uo pipefail

SESSION_DIR=""
SESSION_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-dir) SESSION_DIR="${2:-}"; shift 2 ;;
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --model|--tools) shift 2 ;;
    -p|--print|-a) shift 1 ;;
    *) shift 1 ;;
  esac
done

if [[ -z "$SESSION_DIR" || -z "$SESSION_ID" ]]; then
  echo "fake_pi.sh: missing --session-dir/--session-id" >&2
  exit 1
fi
mkdir -p "$SESSION_DIR"
SESSION_FILE="$SESSION_DIR/${SESSION_ID}.jsonl"

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

#!/usr/bin/env bash
# Drive a pi benchmark cell headlessly, using the operator's FULL personal pi
# config (global ~/.pi/agent/AGENTS.md, extensions, skills) as the agent
# wrapper -- that personal config is exactly what's under test here.
#
# METHODOLOGY: runs ONE continuous pi session through the cell, matching the
# paper's own harnesses (claude/codex/opencode each run a single unbroken
# session across all 80 problems). This driver does NOT chop the run into
# fixed-size time slices -- earlier revisions did (a `timeout 300` per turn +
# a `--max-turns` re-invocation loop), which both fragmented the agent's
# context mid-problem AND gave no real observability between the 5-minute
# guillotine prints. That was wrong on both counts; see pi/README.md.
#
# Observability instead comes from disk, not from chopping the run or from
# `pi --mode json`: harness_state.json is the authoritative benchmark
# progress (updated by the harness itself on every fetch/submit), and the
# child's own session .jsonl file growing is the liveness signal (it's
# written continuously as the model thinks/acts). A background heartbeat
# prints both every --heartbeat-interval seconds while the single pi session
# runs. A --stall-timeout watchdog kills the run only if the session file
# goes genuinely quiet for that long (a real hang), never on elapsed time.
#
# Usage:
#   pi/run_cell.sh --model <id> --provider <name> --language <lang> [options]
#
# --model and --provider are REQUIRED. There is no default for either -- pi
# itself silently defaults --provider to "google" if omitted, which is
# exactly the kind of silent-default footgun --model already guards against
# here, so --provider is gated the same way.
#
# RESULTS ARE KEYED ON THE FULL GRID: harness (this pi/ dir itself) x
# provider x model x thinking x language. Every combination gets its own cell
# + its own export artifact -- two different providers/models/thinking
# levels run against the same language never collide or overwrite each
# other's results (see pi/setup_cells.py, the single source of truth for the
# grid path). Cells are built ON DEMAND by this script (via setup_cells.py) --
# there's no separate pre-build step required.
#
# Requires: pi/load_dataset.py has been run (real dataset present, see --dataset-file).
#
# SAFETY (learned the hard way):
#   - The child `pi` is a SEPARATE process/session from whatever pi session
#     launched this script. If this repo is a `bench`-managed clone, the
#     bench-lock guard will BLOCK the child's bash/read/write entirely unless
#     it's given an authorized session id -- pass one via --session-id (mint
#     it with the `bench` tool's grant:true option in the LAUNCHING session
#     first). Prefer running this driver from a plain (non-bench) clone.
#   - By default the child's tool surface is restricted to read/bash/edit/write
#     only (--tools), NOT the full extension set -- an earlier run let a
#     blocked child discover and call craft_takeover on the launching
#     session's OWN live craft workflow, rebinding it out from under that
#     session. Override with --allowed-tools if you understand that risk.
#   - The child pi runs in its OWN process group (via `set -m`); on exit,
#     Ctrl-C, or a stall-kill, this script terminates that whole group so no
#     orphaned grandchild process (or further-nested tool subprocess) is left
#     running after this script exits.
set -uo pipefail
set -m  # job control: give the backgrounded pi its own process group

PI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PI_DIR/.." && pwd)"
PI_BIN="${PI_BIN:-pi}"  # override for testing: PI_BIN=/path/to/fake_pi.sh

MODEL=""
PROVIDER=""
LANGUAGE=""
THINKING=""
FRESH=""
MAX_PROBLEMS=""
MAX_CONTINUATIONS=3
HEARTBEAT_INTERVAL=15
STALL_TIMEOUT=600
MAX_SUSPEND_GAP=120
POLL_INTERVAL=2
EFFECTIVE_MODEL_WAIT=20
EFFECTIVE_MODEL_SETTLE=2
DATASET_FILE="$REPO_ROOT/benchmark_harness/private/esolang_full_private.local.json"
SESSION_ID_OVERRIDE=""
ALLOWED_TOOLS="read,bash,edit,write"
COMPACTION="on"

usage() {
  cat >&2 <<EOF
Usage: $0 --model <id> --provider <name> --language <brainfuck|befunge-98|whitespace|shakespeare> [options]

Required:
  --model <id>            Model id to pass to pi (e.g. claude-sonnet-4-6).
                           REQUIRED -- there is no default, this errors out if omitted.
  --provider <name>        pi provider name (e.g. anthropic, openai, google).
                           REQUIRED -- pi itself defaults this to "google" silently, which
                           this driver deliberately refuses to inherit; this errors out if
                           omitted, same as --model.
  --thinking <level>      pi thinking level: off, minimal, low, medium, high, xhigh.
                           REQUIRED -- thinking materially changes behavior/cost, so like
                           --model/--provider it is never silently assumed; this errors out
                           if omitted or set to an unrecognized level.
  --language <lang>       One of: brainfuck, befunge-98, whitespace, shakespeare

Options:
  --fresh                 Reset THIS grid cell's state (harness_state.json, export.json,
                           .pi-sessions) before running -- use to cleanly re-run the same
                           (provider, model, thinking, language) point instead of resuming
                           a prior run's leftover state.
  --max-problems N        Stop once N problems have been finalized (solved/failed/skipped)
                           -- an explicit bounded-test stop; default: unset = run to all 80.
  --max-continuations N   Cap on early-yield re-nudges: if the single pi session ends
                           naturally with problems still unattempted, re-prompt it to
                           continue, up to N times (default: $MAX_CONTINUATIONS). This is
                           NOT periodic chunking -- it only fires if the session actually
                           stops talking on its own while unfinished.
  --heartbeat-interval S  Seconds between progress heartbeat lines (default: $HEARTBEAT_INTERVAL).
  --stall-timeout S       Seconds of NO session-file growth before treating the run as
                           hung and killing it (default: $STALL_TIMEOUT). This is a liveness
                           check, not a fixed run-length cap -- a slow but active run never
                           trips it. IMPORTANT: pi only writes a session-file record when a
                           turn COMPLETES (nothing streams to stdout mid-turn in `-p` mode),
                           so a long single high-thinking turn produces ZERO growth and looks
                           identical to a hang. The default must comfortably clear the
                           model's longest legitimate single thinking turn -- 600s was chosen
                           after observing a real sonnet-5/high run with a 191.7s legitimate
                           thinking turn (recovered fine) get false-killed on a HARDER problem
                           at the old 240s default. Raise this further for a very strong model
                           at high/xhigh thinking on the Hard/Extra-hard tiers if you see
                           another false stall; lower it only for a fast/no-thinking model
                           where you want quicker true-hang detection. RESUMING an existing
                           cell (no --fresh) is safe across an arbitrary gap between runs
                           (including a laptop suspend): the liveness clock is baselined from
                           when THIS run started watching, never from the session file's own
                           (possibly old) mtime -- see --max-suspend-gap below for what
                           happens if the MACHINE itself sleeps DURING an active run.
  --max-suspend-gap S     If a monitor-loop iteration gap far exceeds its own
                           ~$POLL_INTERVAL(2)s poll cadence (default: $MAX_SUSPEND_GAP), THIS
                           PROCESS -- and therefore the child -- was almost certainly frozen by
                           a machine suspend, not genuinely idle that long. run_cell.sh does NOT
                           try to ride this out: it KILLS the child and STOPS the run (reason
                           "interrupted", non-zero exit) rather than resuming into a
                           post-sleep child, because a long-enough suspend kills the in-flight
                           API call, and continuing produced empty, budget-wasting turns in
                           practice. Re-run (with or without --fresh) after a suspend rather
                           than relying on this to paper over it -- it deliberately does not.
  --dataset-file PATH     Private JSON to use as HARNESS_PRIVATE_FILE
                           (default: benchmark_harness/private/esolang_full_private.local.json)
  --session-id ID         pi session id for the child (default:
                           pi-esolang-<provider>-<model>-<thinking>-<language>, each
                           component slugged -- see "Effective-model verification" below
                           for why this default is grid-specific, not language-only). If
                           this repo is a bench-managed clone, pass a grant token here (see
                           the SAFETY note above) or the child's bash/read/write will be
                           blocked by the bench-lock guard.
  --allowed-tools LIST    Comma-separated pi --tools allowlist for the child
                           (default: $ALLOWED_TOOLS -- deliberately excludes
                           craft_*/initiative_*/bench/ask_user_question/mcp).
  --effective-model-wait S Seconds to wait for the child to report the model/provider/
                           thinking it ACTUALLY booted, before giving up and aborting
                           (default: $EFFECTIVE_MODEL_WAIT). See "Effective-model
                           verification" below.
  --effective-model-settle S  Seconds the last-seen effective model/thinking must stay
                           UNCHANGED before it's trusted (default: $EFFECTIVE_MODEL_SETTLE) --
                           guards against reading only the FIRST (boot) model_change and
                           missing a later silent override a few hundred ms after boot.
  --compaction on|off     Whether the CHILD auto-compacts its context when full (default:
                           $COMPACTION). Written to a cell-local .pi/settings.json that pi
                           merges OVER your global setting for this child only (your own
                           global default is never touched) -- ON matches the paper's own
                           harnesses (e.g. Claude Code auto-compacts by default), which is
                           how a single session survives all 80 problems instead of
                           collapsing (fetch-spamming the rest into skips) once context
                           fills. Turn it off only if you specifically want to observe/study
                           that collapse.

Result keying: state + the export artifact are keyed on the FULL grid --
harness (this pi/ dir) x provider x model x thinking x language -- at
experiments/01_main_experiments/pi/<provider>/<model>/<thinking>/<language>/
and pi/artifacts/<provider>/<model>/<thinking>/<language>_export.json. See
pi/setup_cells.py.

Effective-model verification: pi's own model-selection layer (extensions,
sticky per-session-id defaults, etc.) can silently override an explicit
--model/--provider/--thinking with something else entirely -- this has been
observed in practice: a fixed, language-only session-id let a stale sticky
model entry from one grid cell get replayed onto a LATER run requesting a
DIFFERENT model, and the wrong model ran while results were filed under the
requested grid path. Two defenses: (1) the default --session-id above is
derived from the FULL grid coordinates, so distinct (provider, model,
thinking) points never share one sticky per-session entry; (2) after
launching the child, this script reads back the model_change/
thinking_level_change events the child ACTUALLY wrote to its session file
and ABORTS (non-zero, naming both what was requested and what was
effective) if they don't match what was requested -- never trusting that
CLI flags were silently honored just because they were passed.
EOF

  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="${2:-}"; shift 2 ;;
    --provider) PROVIDER="${2:-}"; shift 2 ;;
    --language) LANGUAGE="${2:-}"; shift 2 ;;
    --thinking) THINKING="${2:-}"; shift 2 ;;
    --fresh) FRESH=1; shift 1 ;;
    --max-problems) MAX_PROBLEMS="${2:-}"; shift 2 ;;
    --max-continuations) MAX_CONTINUATIONS="${2:-}"; shift 2 ;;
    --heartbeat-interval) HEARTBEAT_INTERVAL="${2:-}"; shift 2 ;;
    --stall-timeout) STALL_TIMEOUT="${2:-}"; shift 2 ;;
    --max-suspend-gap) MAX_SUSPEND_GAP="${2:-}"; shift 2 ;;
    --dataset-file) DATASET_FILE="${2:-}"; shift 2 ;;
    --session-id) SESSION_ID_OVERRIDE="${2:-}"; shift 2 ;;
    --allowed-tools) ALLOWED_TOOLS="${2:-}"; shift 2 ;;
    --effective-model-wait) EFFECTIVE_MODEL_WAIT="${2:-}"; shift 2 ;;
    --effective-model-settle) EFFECTIVE_MODEL_SETTLE="${2:-}"; shift 2 ;;
    --compaction) COMPACTION="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage ;;
  esac
done

if [[ -z "$MODEL" ]]; then
  echo "ERROR: --model is required (no default is provided by design)." >&2
  exit 1
fi
if [[ -z "$PROVIDER" ]]; then
  echo "ERROR: --provider is required (pi silently defaults this to 'google' -- this driver refuses to inherit that; no default is provided by design)." >&2
  exit 1
fi
if [[ -z "$THINKING" ]]; then
  echo "ERROR: --thinking is required (thinking materially changes behavior/cost, so like --model/--provider it is never silently assumed; no default is provided by design)." >&2
  exit 1
fi
case "$THINKING" in
  off|minimal|low|medium|high|xhigh) ;;
  *)
    echo "ERROR: --thinking '$THINKING' is not a recognized level. Must be one of: off, minimal, low, medium, high, xhigh." >&2
    exit 1
    ;;
esac
case "$COMPACTION" in
  on|off) ;;
  *)
    echo "ERROR: --compaction '$COMPACTION' is not recognized. Must be 'on' or 'off'." >&2
    exit 1
    ;;
esac
if [[ -z "$LANGUAGE" ]]; then
  echo "ERROR: --language is required." >&2
  exit 1
fi
if [[ ! -f "$DATASET_FILE" ]]; then
  echo "ERROR: dataset file not found at $DATASET_FILE -- run: python3 pi/load_dataset.py" >&2
  exit 1
fi

# Pre-flight: refuse an unresolvable (provider, model) pair rather than
# letting pi silently fuzzy-match/fall back to some other model. `pi
# --list-models` prints an exact "provider  model  ..." table; require an
# EXACT "$PROVIDER/$MODEL" row in it (works against the real pi CLI and
# against a PI_BIN stub that implements --list-models for testing).
MODEL_LIST="$("$PI_BIN" --list-models 2>&1)"
MODEL_LIST_RC=$?
if [[ "$MODEL_LIST_RC" -ne 0 ]]; then
  echo "ERROR: '$PI_BIN --list-models' failed (rc=$MODEL_LIST_RC) -- cannot verify --provider/--model exist:" >&2
  echo "$MODEL_LIST" >&2
  exit 1
fi
if ! awk -v want="$PROVIDER/$MODEL" 'NF>=2 && ($1"/"$2)==want{found=1} END{exit !found}' <<<"$MODEL_LIST"; then
  echo "ERROR: no model '$MODEL' under provider '$PROVIDER' found in '$PI_BIN --list-models' -- refusing to run (a typo would otherwise silently fall back to some other model). Run '$PI_BIN --list-models' to see valid provider/model pairs." >&2
  exit 1
fi

# Resolve (and build, on demand) the grid cell via setup_cells.py -- the
# single source of truth for the path, so run_cell.sh never recomputes it
# independently and risks drifting from what setup_cells.py itself builds.
SETUP_ARGS=(--provider "$PROVIDER" --model "$MODEL" --thinking "$THINKING" --language "$LANGUAGE")
if ! SETUP_OUT="$(python3 "$PI_DIR/setup_cells.py" "${SETUP_ARGS[@]}")"; then
  echo "$SETUP_OUT" >&2
  exit 1
fi
CELL_DIR="$(sed -n 's/^CELL_DIR=//p' <<<"$SETUP_OUT")"
ARTIFACT_PATH="$(sed -n 's/^ARTIFACT=//p' <<<"$SETUP_OUT")"
if [[ -z "$CELL_DIR" || -z "$ARTIFACT_PATH" ]]; then
  echo "ERROR: failed to resolve the grid cell path via setup_cells.py:" >&2
  echo "$SETUP_OUT" >&2
  exit 1
fi

cd "$CELL_DIR"
export HARNESS_PRIVATE_FILE="$DATASET_FILE"

if [[ -n "$FRESH" ]]; then
  echo "[run_cell] --fresh: resetting this grid cell's state ($CELL_DIR)"
  rm -f harness_state.json export.json
  rm -rf .pi-sessions
fi

if [[ ! -f harness_state.json ]]; then
  echo "[run_cell] initializing harness session for $LANGUAGE"
  python3 harness.py init --language "$LANGUAGE"
fi

# Cell-local pi project settings: pi merges a trusted project's
# .pi/settings.json OVER the operator's global settings.json for THIS
# child only (the operator's own global default is never touched). The
# child is already trusted (run_cell.sh passes -a below), so this takes
# effect. Written on every run (idempotent) so a stale file never lingers
# if --compaction is flipped between runs of the same cell.
mkdir -p "$CELL_DIR/.pi"
if [[ "$COMPACTION" == "on" ]]; then
  printf '{"compaction":{"enabled":true}}\n' > "$CELL_DIR/.pi/settings.json"
else
  printf '{"compaction":{"enabled":false}}\n' > "$CELL_DIR/.pi/settings.json"
fi

SESSION_DIR="$CELL_DIR/.pi-sessions"
mkdir -p "$SESSION_DIR"
# Sanitize a grid-dimension value into a session-id-safe token, mirroring
# setup_cells.py's slug() (same [^A-Za-z0-9._-] -> '_' rule). The DEFAULT
# session-id below encodes the FULL grid coordinates -- not just the
# language -- so distinct (provider, model, thinking) points never share one
# sticky per-session-id model entry (see "Effective-model verification" in
# --help; this was an observed real bug, not a hypothetical).
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
SESSION_ID="${SESSION_ID_OVERRIDE:-pi-esolang-$(slug "$PROVIDER")-$(slug "$MODEL")-$(slug "$THINKING")-$(slug "$LANGUAGE")}"
RUN_LOG="$CELL_DIR/.run_cell.log"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# ST_* globals, seeded with safe defaults so a transient harness_status
# failure (see below) always has something sane to fall back to, even on
# the very first call.
ST_SOLVED=0; ST_FAILED=0; ST_SKIPPED=0; ST_ACTIVE=0; ST_REMAINING=0
ST_TESTS="0/0"; ST_CURRENT=""; ST_FINALIZED=0

# Parses `harness.py status` into ST_* globals. RESILIENT to a transient
# failure or garbled read -- the heartbeat's `status` READ can race the
# child's `submit`/`fetch`/`skip` WRITE of harness_state.json (observed in
# practice: a one-off Python JSONDecodeError traceback + an empty-metric
# heartbeat line). Retries once after a short pause; if it still fails,
# KEEPS the previous ST_* values and returns non-zero -- callers never see a
# traceback leak into run_cell.sh's own output or a blank/garbled heartbeat.
# The shared benchmark_harness/harness.py itself is NOT modified (it's the
# paper's code, out of scope) -- this is purely a resilient READ here.
harness_status() {
  local out rc attempt
  for attempt in 1 2; do
    out="$(python3 harness.py status 2>/dev/null)"
    rc=$?
    if [[ "$rc" -eq 0 ]] && grep -q '^Solved:' <<<"$out"; then
      # "Solved:" prints as "N/80" -- take just N (used in arithmetic below).
      ST_SOLVED=$(awk '/^Solved:/{split($2,a,"/"); print a[1]}' <<<"$out")
      ST_FAILED=$(awk '/^Failed:/{print $2}' <<<"$out")
      ST_SKIPPED=$(awk '/^Skipped:/{print $2}' <<<"$out")
      ST_ACTIVE=$(awk '/^Active:/{print $2}' <<<"$out")
      ST_REMAINING=$(awk '/^Remaining:/{print $2}' <<<"$out")
      ST_TESTS=$(awk '/^Test cases passed:/{print $4}' <<<"$out")
      ST_CURRENT=$(awk -F': ' '/^Current problem:/{print $2}' <<<"$out")
      ST_FINALIZED=$(( ST_SOLVED + ST_FAILED + ST_SKIPPED ))
      return 0
    fi
    [[ "$attempt" -eq 1 ]] && sleep 0.3
  done
  return 1
}

# Prints "<mtime_epoch> <size_bytes>" for the most recently modified .jsonl
# under SESSION_DIR, or "0 0" if none exist yet. Uses python3 (already a hard
# dependency of the harness) instead of `stat`, whose flags differ between
# macOS/BSD and GNU/Linux.
session_liveness() {
  python3 - "$SESSION_DIR" <<'PYEOF'
import glob, os, sys
files = glob.glob(os.path.join(sys.argv[1], "**", "*.jsonl"), recursive=True)
if not files:
    print("0 0")
else:
    f = max(files, key=os.path.getmtime)
    print(int(os.path.getmtime(f)), os.path.getsize(f))
PYEOF
}

# Reads whichever .jsonl under SESSION_DIR was most recently modified and
# returns the LAST model_change (provider+modelId) and thinking_level_change
# (thinkingLevel) it contains, as "FOUND <provider> <modelId> <thinkingLevel>"
# -- or "PENDING" if no session file exists yet, or either event hasn't been
# written yet. A single pass (no internal sleep/wait -- the caller polls).
read_effective_model_once() {
  python3 - "$SESSION_DIR" <<'PYEOF'
import glob, json, os, sys

session_dir = sys.argv[1]
files = glob.glob(os.path.join(session_dir, "**", "*.jsonl"), recursive=True)
if not files:
    print("PENDING")
    sys.exit(0)
f = max(files, key=os.path.getmtime)
provider = model = thinking = None
try:
    with open(f) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("type") == "model_change":
                provider = o.get("provider")
                model = o.get("modelId")
            elif o.get("type") == "thinking_level_change":
                thinking = o.get("thinkingLevel")
except OSError:
    pass
if provider is not None and model is not None and thinking is not None:
    print(f"FOUND {provider} {model} {thinking}")
else:
    print("PENDING")
PYEOF
}

PI_PID=""
PI_PGID=""
EXPORTED=0

kill_child_group() {
  [[ -z "$PI_PGID" ]] && return 0
  if kill -0 "-$PI_PGID" 2>/dev/null; then
    kill -TERM "-$PI_PGID" 2>/dev/null
    sleep 2
    kill -0 "-$PI_PGID" 2>/dev/null && kill -KILL "-$PI_PGID" 2>/dev/null
  fi
}

finalize_export() {
  [[ "$EXPORTED" -eq 1 ]] && return 0
  EXPORTED=1
  # Never file an artifact for a run we couldn't trust the model on -- an
  # effective-model mismatch/unverifiable run may have done SOME (wrong- or
  # unknown-model) harness work before detection; exporting it under the
  # requested grid path would be exactly the silent mislabel this guard
  # exists to prevent. The cell's own harness_state.json/export.json are
  # left on disk for inspection; only the copy into pi/artifacts/ is skipped.
  case "${STOP_REASON:-}" in
    effective_model_mismatch|effective_model_unverifiable)
      echo "[run_cell] skipping artifact export -- STOP_REASON=$STOP_REASON (the effective model could not be trusted, so no result is filed under $ARTIFACT_PATH)"
      return 0
      ;;
  esac
  # Suppress stderr only (not stdout -- "Exported session data to ..." is a
  # useful confirmation line): a corrupt/unreadable state file at export
  # time must not leak a Python traceback into run_cell.sh's own output
  # either (same race as harness_status above). export.json is simply not
  # written in that case -- the `cp` below is a no-op, and finalize_export's
  # STOP_REASON guard already skips the artifact copy for an untrusted run.
  python3 harness.py export 2>/dev/null || true
  mkdir -p "$(dirname "$ARTIFACT_PATH")"
  [[ -f "$CELL_DIR/export.json" ]] && cp "$CELL_DIR/export.json" "$ARTIFACT_PATH"
}

cleanup() {
  kill_child_group
  finalize_export
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

INITIAL_PROMPT='Read AGENTS.md and follow it exactly. This session is initialized. Begin with: python3 harness.py fetch. Solve problems in order. Use python3 harness.py run <file> --input "..." to test. Then python3 harness.py submit <id> <file>. Max 3 submissions per problem. Work through ALL problems in this SAME session, one after another -- do not stop until every problem has been attempted (solved or all 3 submissions used) or the run is deliberately halted for you.'

continuation_prompt() {
  harness_status
  echo "You stopped, but problems remain unattempted (current: ${ST_CURRENT:-none}, remaining: ${ST_REMAINING:-?}, active: ${ST_ACTIVE:-?}). Continue immediately: run python3 harness.py status if unsure where you left off, then proceed to fetch/solve/submit the current or next problem exactly per AGENTS.md. Do not stop again until all problems are attempted."
}

# ---------------------------------------------------------------------------
# Main run loop: ONE continuous session per attempt; re-launch (a bounded
# number of times) ONLY if the session ends naturally with work remaining.
# ---------------------------------------------------------------------------

STOP_REASON=""
attempt=1
max_attempts=$(( MAX_CONTINUATIONS + 1 ))

while (( attempt <= max_attempts )); do
  if [[ "$attempt" -eq 1 ]]; then
    PROMPT="$INITIAL_PROMPT"
    echo "[run_cell] starting continuous pi session (attempt $attempt/$max_attempts)"
  else
    PROMPT="$(continuation_prompt)"
    echo "[run_cell] early-yield re-nudge (attempt $attempt/$max_attempts)"
  fi

  PI_ARGS=(-p --model "$MODEL" --provider "$PROVIDER" --thinking "$THINKING" --session-dir "$SESSION_DIR" \
            --session-id "$SESSION_ID" --tools "$ALLOWED_TOOLS" -a "$PROMPT")
  "$PI_BIN" "${PI_ARGS[@]}" > "$RUN_LOG" 2>&1 &
  PI_PID=$!
  PI_PGID="$(ps -o pgid= -p "$PI_PID" 2>/dev/null | tr -d ' ')"

  # Effective-model verification: read back what pi ACTUALLY booted (never
  # trust that passing --model/--provider/--thinking means they were
  # honored -- an operator's own pi config can silently override them, e.g.
  # a sticky per-session-id default; this happened in practice). NOTE: this
  # must NOT break on the FIRST model_change/thinking_level_change seen --
  # that's just the boot event, which pi always writes as the CLI-resolved
  # (correct) model; a silent override lands as a SEPARATE, LATER
  # model_change moments afterward (observed in practice: two model_change
  # events ~130ms apart, the second one wrong). So this polls until the
  # LAST-seen (provider, model, thinking) triple has been STABLE for
  # EFFECTIVE_MODEL_SETTLE seconds -- i.e. it waits out the whole
  # model-selection burst, not just its first event -- or the wait bound
  # elapses, or the child exits.
  emw_deadline=$(( $(date +%s) + EFFECTIVE_MODEL_WAIT ))
  EFF_STATUS="PENDING"
  last_sig=""
  stable_since=""
  while (( $(date +%s) < emw_deadline )); do
    EFF_LINE="$(read_effective_model_once)"
    now=$(date +%s)
    if [[ "$EFF_LINE" == FOUND* ]]; then
      if [[ "$EFF_LINE" != "$last_sig" ]]; then
        last_sig="$EFF_LINE"
        stable_since=$now
      elif (( now - stable_since >= EFFECTIVE_MODEL_SETTLE )); then
        EFF_STATUS="FOUND"
        read -r _ EFF_PROVIDER EFF_MODEL EFF_THINKING <<<"$EFF_LINE"
        break
      fi
    fi
    kill -0 "$PI_PID" 2>/dev/null || break
    sleep 0.3
  done
  # Child exited (or the wait bound elapsed) before the signature ever
  # settled for the full window, but SOMETHING was seen -- use the last
  # value observed rather than declaring it fully unverifiable, since a
  # quick-exiting child (e.g. a short fake/test run) legitimately never
  # reaches a full settle window.
  if [[ "$EFF_STATUS" != "FOUND" && -n "$last_sig" ]]; then
    EFF_STATUS="FOUND"
    read -r _ EFF_PROVIDER EFF_MODEL EFF_THINKING <<<"$last_sig"
  fi

  killed_this_attempt=""
  if [[ "$EFF_STATUS" != "FOUND" ]]; then
    echo "ERROR: could not verify the effective model/provider/thinking pi actually booted within ${EFFECTIVE_MODEL_WAIT}s (no model_change/thinking_level_change event seen in the session file) -- aborting rather than risk mislabeling results under provider=$PROVIDER model=$MODEL thinking=$THINKING." >&2
    kill_child_group
    STOP_REASON="effective_model_unverifiable"
    killed_this_attempt=1
  elif [[ "$EFF_PROVIDER" != "$PROVIDER" || "$EFF_MODEL" != "$MODEL" || "$EFF_THINKING" != "$THINKING" ]]; then
    echo "ERROR: pi booted a DIFFERENT model than requested -- requested provider=$PROVIDER model=$MODEL thinking=$THINKING but EFFECTIVE was provider=$EFF_PROVIDER model=$EFF_MODEL thinking=$EFF_THINKING. Your pi config silently overrode the CLI flags (e.g. a sticky model-selection default/session entry). Killing the run to avoid filing results under the wrong grid path." >&2
    kill_child_group
    STOP_REASON="effective_model_mismatch"
    killed_this_attempt=1
  else
    echo "[run_cell] verified effective model matches request: provider=$PROVIDER model=$MODEL thinking=$THINKING"
  fi

  if [[ -n "$killed_this_attempt" ]]; then
    wait "$PI_PID" 2>/dev/null
    PI_PID=""
    PI_PGID=""
    break
  fi

  last_heartbeat=0
  # Liveness baseline: we track "seconds since we last OBSERVED the session
  # file change" -- never the file's own absolute mtime. A RESUME's file
  # already carries the PRIOR run's mtime (legitimately old), so trusting it
  # directly would insta-kill a freshly-launched child before it writes a
  # byte (real bug, hit in practice: a resumed run was killed on its very
  # first heartbeat with "last activity 6543s ago" because the machine had
  # slept between runs -- the file was just old, the child hadn't even
  # booted yet). prev_mtime/prev_size start empty so the FIRST observation
  # always counts as "just changed", seeding last_activity_ts=now and
  # giving the child a full, fresh --stall-timeout window regardless of how
  # old the pre-existing file is.
  last_activity_ts=$(date +%s)
  prev_loop_ts=$last_activity_ts
  prev_mtime=""
  prev_size=""

  while kill -0 "$PI_PID" 2>/dev/null; do
    now=$(date +%s)
    loop_gap=$(( now - prev_loop_ts ))
    prev_loop_ts=$now
    if (( loop_gap >= MAX_SUSPEND_GAP )); then
      # This monitor-loop iteration took far longer than its ~$POLL_INTERVAL(2)s
      # cadence -- THIS PROCESS (and therefore the child) was almost certainly
      # frozen by a machine suspend, not genuinely idle that long. We do NOT try
      # to ride this out (round 8 used to reset the liveness clock and let the
      # run continue): a long-enough suspend kills the in-flight API call, and
      # in practice the model came back with empty, budget-wasting turns that
      # burned the continuation cap for nothing. Stop cleanly instead -- the
      # operator re-runs (with or without --fresh) rather than this papering
      # over a dead post-sleep child.
      echo "[run_cell] detected a ${loop_gap}s gap since the last liveness check (>= --max-suspend-gap ${MAX_SUSPEND_GAP}s) -- this machine was almost certainly suspended. Not attempting to resume the in-flight session across the sleep (a long suspend kills the child's in-flight API call) -- stopping this run. Re-run to continue."
      kill_child_group
      STOP_REASON="interrupted"
      killed_this_attempt=1
      break
    fi

    read -r live_mtime live_size < <(session_liveness)
    if [[ "$live_mtime" != "$prev_mtime" || "$live_size" != "$prev_size" ]]; then
      last_activity_ts=$now
      prev_mtime="$live_mtime"
      prev_size="$live_size"
    fi
    idle=$(( now - last_activity_ts ))

    if (( now - last_heartbeat >= HEARTBEAT_INTERVAL )); then
      harness_status
      echo "[run_cell] heartbeat -- solved=${ST_SOLVED}/80 failed=${ST_FAILED} skipped=${ST_SKIPPED} active=${ST_ACTIVE} remaining=${ST_REMAINING} current=${ST_CURRENT:-none} tests=${ST_TESTS:-0/0} | session size=${live_size}B, last activity ${idle}s ago"
      last_heartbeat=$now
    fi

    if (( idle >= STALL_TIMEOUT )); then
      echo "[run_cell] STALL DETECTED -- no session activity for ${idle}s (>= --stall-timeout ${STALL_TIMEOUT}s). Killing the child process group."
      kill_child_group
      STOP_REASON="stalled"
      killed_this_attempt=1
      break
    fi

    if [[ -n "$MAX_PROBLEMS" ]]; then
      harness_status
      if (( ST_FINALIZED >= MAX_PROBLEMS )); then
        echo "[run_cell] reached --max-problems=$MAX_PROBLEMS finalized problems. Stopping the run."
        kill_child_group
        STOP_REASON="max_problems"
        killed_this_attempt=1
        break
      fi
    fi

    sleep "$POLL_INTERVAL"
  done

  wait "$PI_PID" 2>/dev/null
  PI_PID=""
  PI_PGID=""

  if [[ -n "$killed_this_attempt" ]]; then
    break
  fi

  # The session ended on its own (no kill from us). Check whether it
  # actually finished the benchmark.
  harness_status
  if (( ST_REMAINING == 0 && ST_ACTIVE == 0 )); then
    echo "[run_cell] session ended naturally -- all problems finalized."
    STOP_REASON="completed"
    break
  fi

  echo "[run_cell] session ended naturally but work remains (remaining=${ST_REMAINING}, active=${ST_ACTIVE})."
  attempt=$(( attempt + 1 ))
  if (( attempt > max_attempts )); then
    STOP_REASON="continuation_cap"
    echo "[run_cell] --max-continuations=$MAX_CONTINUATIONS reached with work still remaining. Stopping."
  fi
done

harness_status
echo "[run_cell] done (reason: ${STOP_REASON:-unknown}) -- solved=${ST_SOLVED}/80 failed=${ST_FAILED} skipped=${ST_SKIPPED} active=${ST_ACTIVE} remaining=${ST_REMAINING}"
# `finalize_export` + `kill_child_group` also run via the EXIT trap, but call
# explicitly here too so the printed path is accurate before the trap fires.
finalize_export
echo "[run_cell] export written to $CELL_DIR/export.json (and copied to $ARTIFACT_PATH)"

case "$STOP_REASON" in
  completed|max_problems) exit 0 ;;
  *) exit 1 ;;
esac

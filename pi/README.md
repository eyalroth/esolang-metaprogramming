# Running EsoLang-Bench with `pi`

This adds `pi` (https://github.com/earendil-works/pi-mono, the `pi` CLI coding
agent) as a benchmark wrapper alongside the paper's `claude`/`codex`/`opencode`.

**What this measures is deliberately not "just a model."** `pi` is launched
with normal discovery on (no `--no-extensions`/`--no-skills`/`--no-context-files`),
so it loads the operator's *personal* setup — global `~/.pi/agent/AGENTS.md`
conventions, installed extensions, skills — in addition to the cell's own
`AGENTS.md` benchmark prompt (pi discovers and concatenates every `AGENTS.md`
found walking up from the working directory). The point of this toolkit is to
see how *that whole personal configuration*, not a bare model, performs on the
benchmark.

## Contents

| File | Purpose |
|---|---|
| `load_dataset.py` | Pulls the **real, unredacted** hidden tests from the `Lossfunk/Esolang-Bench` HuggingFace dataset and writes them to a git-ignored local file. **Never commit this file's output** — see Dataset below. |
| `setup_cells.py` | Builds ONE grid cell on demand — `experiments/01_main_experiments/pi/<provider>/<model>/<thinking>/<language>/` (harness + `AGENTS.md` symlinks) — keyed on the **full experimental grid**. Single source of truth for that path; `run_cell.sh` calls it, you normally never need to. |
| `run_cell.sh` | Headless driver: runs **one continuous `pi` session** through a cell to completion (methodology-faithful — no chunking). **`--model` and `--provider` are required flags — omitting either is an error, by design**, so every run's grid coordinates are a deliberate choice, never a silent default. |
| `audit.sh` | Deterministic, no-network, no-live-model-call check that everything above is wired correctly (used by the craft workflow that built this). |
| `tests/` | Model-free integration test (`test_run_cell.sh` + a `fake_pi.sh` stand-in for the real `pi` CLI) exercising the driver's heartbeat/stall-watchdog/cleanup control flow with no network or model call. |
| `artifacts/` | Git-ignored scratch space for run exports (e.g. smoke-test output). |

## 1. Environment setup

Same as the repo root (`HOWTO_RUN.md`), plus two extra packages this toolkit
needs for the dataset pull:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
pip install datasets huggingface_hub
```

## 2. Get the real dataset (never committed)

```bash
python3 pi/load_dataset.py
```

This tries an **anonymous** pull of `Lossfunk/Esolang-Bench` first. If it's
gated, the script exits non-zero with instructions (accept the dataset's
terms on HuggingFace while logged in, set `HF_TOKEN`, or run
`huggingface-cli login`, then re-run).

Output goes to `benchmark_harness/private/esolang_full_private.local.json` —
**a git-ignored file, distinct from the tracked, redacted
`esolang_full_private.json`.** The tracked file is never modified. **Never
commit the `.local.json` file or any other copy of the real hidden tests** —
that would compromise the benchmark for everyone else.

## 3. Cells are built for you, on demand

Unlike an earlier revision of this toolkit, you don't need a separate
cell-building step: `run_cell.sh` calls `pi/setup_cells.py` itself for the
exact grid point you're about to run. You can still pre-build one manually if
you want to inspect the symlinks first:

```bash
python3 pi/setup_cells.py --provider anthropic --model claude-sonnet-4-6 --thinking low --language brainfuck
```

## 4. Run a cell

```bash
pi/run_cell.sh --model <model-id> --provider <provider-name> --thinking <level> --language brainfuck
```

`--model`, `--provider`, and `--thinking` are **all three required** — there
is no default for any of them, and omitting one is a hard error
(`pi/run_cell.sh --language brainfuck` alone exits non-zero naming `--model`;
adding `--model` but not `--provider` exits non-zero naming `--provider`;
adding both but not `--thinking` exits non-zero naming `--thinking`). This is
intentional: pi itself silently defaults `--provider` to `google` if you
don't pass it (the same silent-default footgun `--model` already guarded
against), and thinking level materially changes both behavior and cost — so
none of a run's grid coordinates are ever assumed, only chosen deliberately.
`--thinking` must be one of pi's own recognized levels (`off`/`minimal`/
`low`/`medium`/`high`/`xhigh`) — an unrecognized value is also a hard error.

**`--model`/`--provider` are also verified to actually exist before anything
runs**: `run_cell.sh` checks `<provider>/<model>` against an exact row in `pi
--list-models` and refuses to start if it's not there. This exists because pi
itself fuzzy-matches `--model` and silently falls back to a different model
on a typo — exactly the kind of silent misattribution this toolkit is built
to avoid; a bad id is now a hard error naming the model, not a quietly wrong
result.

**Listing ≠ actually booting — the effective model is verified too.** A real
run surfaced that `--list-models` passing is NOT sufficient proof: an
operator's own pi config/extensions can still silently override an explicit
`--model`/`--provider`/`--thinking` after boot (observed cause: a sticky
per-session-id model default replaying a stale model onto a run that
requested a different one, because the child session-id was language-only
and collided across grid cells). Two defenses now in place:

1. The child's default `--session-id` is derived from the **full grid
   coordinates** (provider, model, thinking, language), not just the
   language, so distinct grid points never share one sticky per-session
   model entry.
2. After launching the child, `run_cell.sh` reads back the
   `model_change`/`thinking_level_change` events the child **actually**
   wrote to its own session file, and **kills the run + exits non-zero** if
   the effective provider/model/thinking don't match what was requested
   (naming both). Tune the wait bound with `--effective-model-wait S`
   (default 20s). This means a grid cell's result is never silently filed
   under the wrong model.

Optional flags:
- `--fresh` — reset **this specific grid cell's** state
  (`harness_state.json`, `export.json`, `.pi-sessions`) before running, so
  re-running the same (provider, model, thinking, language) point starts
  clean instead of resuming a prior run's leftover session/state. Without
  it, re-running the same grid point **resumes** rather than restarts.
- `--max-problems N` — an explicit **bounded-test stop**: terminate once N
  problems have been finalized (solved/failed/skipped). Useful for a quick
  smoke run instead of the full 80-problem grind. This is a deliberate,
  monitored stop, not periodic chunking (see Methodology below).
- `--max-continuations N` (default 3) — if the single pi session ends on its
  own with problems still unattempted, the driver re-prompts it to continue,
  up to N times. This only fires on a genuine early yield, never on a timer.
- `--heartbeat-interval S` (default 15) — seconds between progress heartbeat
  lines while the run is in flight.
- `--stall-timeout S` (default 600) — seconds of **zero session-file
  growth** (i.e. the model has produced no new output/tool activity at all)
  before the run is treated as hung and killed. This is a liveness check, not
  a run-length cap — a slow-but-active run (e.g. a big interpreter loop
  inside one `run` call) never trips it. **Caveat:** pi only writes a
  session-file record when a turn *completes* — nothing streams mid-turn in
  `-p` mode — so a long single high-thinking turn produces zero growth and
  looks identical to a hang. 600s was picked after a real sonnet-5/high run
  hit a legitimate 191.7s thinking turn (recovered fine) and was then
  false-killed by the old 240s default on a harder problem. If you see
  another false stall with a strong model at high/xhigh thinking on
  Hard/Extra-hard problems, raise this further. **Resuming an existing cell**
  (no `--fresh`) launched any gap after the prior run — even hours later — is
  safe: the liveness clock is baselined from when *this* run started
  watching, never from the session file's own (possibly-old) mtime. (A real
  bug, now fixed: a resumed run used to be killed on its very first
  heartbeat, because the pre-existing session file's mtime was from the
  prior run.) See `--max-suspend-gap` below for what happens if the machine
  sleeps *during* an active run instead.
- `--max-suspend-gap S` (default 120) — if a monitor-loop iteration gap far
  exceeds its own ~2s poll cadence, the machine was almost certainly
  suspended (this process, and therefore the child, was frozen — not
  genuinely idle that long). run_cell.sh does **not** try to ride this out:
  it kills the child and stops the run (`reason: interrupted`, non-zero
  exit) rather than resuming into a post-sleep child — a long-enough
  suspend kills the in-flight API call, and in practice the model came back
  with empty, continuation-budget-wasting turns instead of real work. Just
  re-run (with or without `--fresh`) afterward.
- `--dataset-file PATH` — override the private JSON (default: the
  `.local.json` from step 2).
- `--effective-model-wait S` (default 20) — seconds to wait for the child to
  report the model/provider/thinking it actually booted before giving up
  and aborting (see the effective-model verification note above).
- `--effective-model-settle S` (default 2) — seconds the last-seen effective
  model/thinking must stay unchanged before it's trusted. Guards against
  reading only the FIRST (boot) `model_change` event and missing a silent
  override that lands a moment later (the real bug: two `model_change`
  events ~130ms apart, the second one wrong).
- `--compaction on|off` (default **on**) — whether the child auto-compacts
  its context when full. `run_cell.sh` writes a cell-local `.pi/settings.json`
  that pi merges **over your global setting for this child only** (your own
  global default is never touched). ON matches the paper's own harnesses
  (e.g. Claude Code auto-compacts by default) — that's how a single session
  survives all 80 problems instead of collapsing (fetch-spamming the rest
  into skips, since `harness.py fetch` auto-marks an un-submitted active
  problem `skipped`) once context fills. Turn it off only to specifically
  observe/study that collapse.

### Result keying: the full experimental grid

Results (both the cell's `harness_state.json` and the exported artifact) are
keyed on **every** dimension, so different providers/models/thinking levels
run against the same language never collide or overwrite each other:

```
experiments/01_main_experiments/pi/<provider>/<model>/<thinking>/<language>/
    harness.py, AGENTS.md (symlinks), harness_state.json, export.json

pi/artifacts/<provider>/<model>/<thinking>/<language>_export.json
```

`pi` (the whole top-level dir) is the **harness** dimension — a sibling of
the paper's own `claude`/`codex`/`opencode` harness dirs. Provider, model,
and thinking all come from your (all-required) `--provider`/`--model`/
`--thinking` flags, sanitized into filesystem-safe path components. Two
models compared side by side, or the same model at two thinking levels, each
get their own cell and artifact — nothing is silently overwritten. This
whole tree is git-ignored and rebuilt locally (see `pi/setup_cells.py`).

### Methodology: one continuous session, not chunked turns

The driver launches **exactly one `pi -p` session** and lets it run to
completion — matching the paper's own harnesses (`claude`/`codex`/`opencode`
each drive a single unbroken session across all 80 problems, so the agent can
build and reuse helpers/generators across problems within that one context).
An earlier revision of this driver instead killed the session every 300s and
stitched it back together with "Continue." prompts; that both fragmented the
agent's context mid-problem and gave near-zero visibility between the
5-minute cuts. Neither is true anymore.

### Observability: from disk, not from chopping the run

While the single session runs, the driver polls **two things on disk** (no
`--mode json` event parsing, no coupling to pi's internal event schema):

- **`harness_state.json`** — the harness's own authoritative benchmark
  progress (updated on every `fetch`/`submit`). This drives the printed
  `solved=X/80 ... current=EnnN` heartbeat fields.
- **The child's own session `.jsonl`** (under `.pi-sessions/`) — it grows
  continuously as the model thinks/acts. Its size + last-modified time is the
  **liveness** signal: `+NKB, last activity Ns ago` in the heartbeat, and the
  input to the `--stall-timeout` watchdog.

Example heartbeat line:
```
[run_cell] heartbeat -- solved=3/80 failed=0 skipped=0 active=1 remaining=76 current=E04 tests=18/18 | session +214KB, last activity 4s ago
```

On exit (natural completion, a stall-kill, `--max-problems`, Ctrl-C, or a
crash), the driver terminates the child pi's **entire process group** — not
just its direct PID — so no grandchild process (e.g. one spawned by the
model's own bash tool calls) survives as an orphan, and always writes
`export.json` (+ the `pi/artifacts/<provider>/<model>/<thinking>/<language>_export.json` copy) with
whatever progress was made.

## Comparing to the paper

To make a run comparable to a specific paper row (e.g. `claude_code/sonnet_4_6`),
pass the matching `--model`/`--provider`/`--thinking`. The harness protocol (80 problems, max 3
submissions each, unlimited local `run`) is identical to every other wrapper
in the repo — only the agent driving it changes.

## Scope note

This toolkit ships the **tooling** to run pi against the benchmark, plus a
short smoke-tested proof that the wiring works end to end. It does **not**
ship a full scored 80-problem (or 4-language) run — that's a separate,
much longer job you launch yourself once you're ready to spend the tokens.

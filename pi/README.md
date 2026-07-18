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
| `setup_cells.py` | Builds `experiments/01_main_experiments/pi/<language>/` cells (harness + `AGENTS.md` symlinks), mirroring `scripts/setup_main_grid.py`'s pattern but without a fixed model subdirectory. |
| `run_cell.sh` | Headless driver: runs **one continuous `pi` session** through a cell to completion (methodology-faithful — no chunking). **`--model` is a required flag — omitting it is an error, by design**, so the model under test is always a deliberate choice, never a silent default. |
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

## 3. Build the pi cells

```bash
python3 pi/setup_cells.py
```

Builds one cell per language under
`experiments/01_main_experiments/pi/<brainfuck|befunge-98|whitespace|shakespeare>/`.
No per-model subdirectory — the model is a runtime flag to `run_cell.sh`, not
part of the cell's identity, since what's under test is "pi as configured for
this run," not one pinned checkpoint.

## 4. Run a cell

```bash
pi/run_cell.sh --model <provider/model-id> --language brainfuck
```

`--model` is **required** — there is no default, and omitting it is a hard
error (`pi/run_cell.sh --language brainfuck` alone exits non-zero naming
`--model`). This is intentional: you must pick a model deliberately for every
run, so the number you get is never accidentally attributed to the wrong
model.

Optional flags:
- `--max-problems N` — an explicit **bounded-test stop**: terminate once N
  problems have been finalized (solved/failed/skipped). Useful for a quick
  smoke run instead of the full 80-problem grind. This is a deliberate,
  monitored stop, not periodic chunking (see Methodology below).
- `--max-continuations N` (default 3) — if the single pi session ends on its
  own with problems still unattempted, the driver re-prompts it to continue,
  up to N times. This only fires on a genuine early yield, never on a timer.
- `--heartbeat-interval S` (default 15) — seconds between progress heartbeat
  lines while the run is in flight.
- `--stall-timeout S` (default 240) — seconds of **zero session-file
  growth** (i.e. the model has produced no new output/tool activity at all)
  before the run is treated as hung and killed. This is a liveness check, not
  a run-length cap — a slow-but-active run (e.g. a big interpreter loop
  inside one `run` call) never trips it.
- `--dataset-file PATH` — override the private JSON (default: the
  `.local.json` from step 2).

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
`export.json` (+ the `pi/artifacts/<language>_export.json` copy) with
whatever progress was made.

## Comparing to the paper

To make a run comparable to a specific paper row (e.g. `claude_code/sonnet_4_6`),
pass the matching `--model`. The harness protocol (80 problems, max 3
submissions each, unlimited local `run`) is identical to every other wrapper
in the repo — only the agent driving it changes.

## Scope note

This toolkit ships the **tooling** to run pi against the benchmark, plus a
short smoke-tested proof that the wiring works end to end. It does **not**
ship a full scored 80-problem (or 4-language) run — that's a separate,
much longer job you launch yourself once you're ready to spend the tokens.

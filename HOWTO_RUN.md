# How to run a cell with each provider

> **Running with `pi`?** See [`pi/README.md`](pi/README.md) for a wrapper that
> drives the harness with the `pi` CLI, including your own personal config
> (extensions/skills/AGENTS.md), plus the real-dataset loader and a headless
> driver script.

Every cell directory under `experiments/` has the same shape:

```
<cell_dir>/
  harness.py        # symlink to ../../../../benchmark_harness/harness.py
  CLAUDE.md         # for Claude Code (or AGENTS.md for Codex / OpenCode)
  AGENTS.md         # identical content; loaded by Codex / OpenCode
  harness_state.json   # auto-created by `python harness.py init`
```

The harness exposes the same five commands in every cell:

| Command | Effect | Limit |
|---|---|---|
| `python harness.py init --language <lang>` | Create the 80-problem session. | once per cell |
| `python harness.py fetch` | Reveal the next problem. | unlimited |
| `python harness.py run <file> --input "…"` | Execute a candidate locally. | **unlimited** local interpreter calls |
| `python harness.py submit <id> <file>` | Grade against 6 hidden tests. | **max 3 submissions per problem** (constant `MAX_SUBMISSIONS = 3` in `harness.py`) |
| `python harness.py status` | Show progress. | unlimited |
| `python harness.py skip` | Skip the current problem (only after attempting). | per skip policy |
| `python harness.py export` | Dump full per-cell JSON. | unlimited |

`<lang>` is one of: `brainfuck`, `befunge-98`, `whitespace`, `shakespeare`.
A problem is solved iff one submission returns 6/6 hidden-test passes.

The harness is deterministic given the agent's actions; nothing about it
needs an API key. The API key only matters for the wrapper that runs the
agent on top of the harness.

## Set the right environment up first (do this once)

You need:

- Python 3.10+ (for the harness; the Brainfuck, Befunge-98, and Whitespace
  interpreters use only the standard library; the Shakespeare interpreter
  wraps the third-party `shakespearelang` package, listed in
  `requirements.txt`).
- Whichever provider CLI/SDK you plan to drive the harness with.

```bash
# From the supplementary_code/ root:
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt   # see file in this directory
bash scripts/test_harness.sh      # confirm harness works without any API key
bash scripts/setup_all.sh         # build all 48 experiment cells
```

### Recommended: run inside a sandboxed environment

We recommend running submitted code inside a Docker container, a VM
(VirtualBox / VMware), or a network-isolated cloud instance. The harness
itself makes no network calls and
writes only inside its own cell directory, but the agent wrappers
(`claude`, `codex`, `opencode`) call provider APIs and may write files
under the cwd, so a sandbox is strongly recommended for end-to-end runs.
A minimal Docker recipe:

```bash
docker run --rm -it -v "$PWD:/work" -w /work python:3.11-slim bash -lc '
  pip install --no-cache-dir -r requirements.txt &&
  bash scripts/test_harness.sh
'
```

The sandbox is also useful for reproducibility: pinning Python 3.11
guarantees the interpreter behaviour matches the headline runs.

## A. Claude Code (Claude family)

### A.1 Claude Code CLI

The CLI is what the headline runs in the paper used. Install via:
```bash
# install via the official installer; documented at the Anthropic Claude Code page.
# The CLI binary is `claude`.
```

Set your provider key once:
```bash
export ANTHROPIC_API_KEY=sk-...
```

Run a cell:
```bash
cd experiments/01_main_experiments/claude_code/opus_4_6/brainfuck
python harness.py init --language brainfuck

claude --no-alt-screen \
  --model claude-opus-4-6 \
  "Read CLAUDE.md and follow it exactly. This session is initialized.
   Begin with: python harness.py fetch.
   Solve problems in order. Use python harness.py run <file> --input \"...\" to test.
   Then python harness.py submit <id> <file>. Max 3 submissions per problem."
```

For Sonnet 4.6 use `--model claude-sonnet-4-6`. For Haiku 4.5 use
`--model claude-haiku-4-5`.

### A.2 Claude Agent SDK (Python) — programmatic driver

If you prefer a programmatic driver instead of the CLI, you can use the
Claude Agent SDK. Install:
```bash
pip install claude-agent-sdk
```

Drive the cell with code like:
```python
import os
from pathlib import Path
import asyncio
from claude_agent_sdk import ClaudeSDKClient, ClaudeAgentOptions

CELL = Path("experiments/01_main_experiments/claude_code/opus_4_6/brainfuck")

async def run_cell():
    options = ClaudeAgentOptions(
        model="claude-opus-4-6",
        cwd=str(CELL.resolve()),
        # Allow the agent to use Bash, Read, Write, Edit, Grep — these are the
        # tools the harness expects. Restrict to the cell directory:
        permission_mode="acceptEdits",
    )
    instruction = (CELL / "CLAUDE.md").read_text() + (
        "\n\nThe session is initialized. Begin with `python harness.py fetch` "
        "and work through all 80 problems sequentially."
    )
    async with ClaudeSDKClient(options=options) as client:
        await client.query(instruction)
        async for message in client.receive_response():
            print(message)

asyncio.run(run_cell())
```

(You must call `python harness.py init --language brainfuck` once before
launching the SDK; the SDK does not need to manage that.)

## B. Codex (GPT-5.4 family)

### B.1 Codex CLI

Install via OpenAI's developer page; the CLI binary is `codex`.

Set your provider key once:
```bash
export OPENAI_API_KEY=sk-...
```

Run a cell:
```bash
cd experiments/01_main_experiments/codex/gpt_5_4_xhigh/brainfuck
python harness.py init --language brainfuck

codex --no-alt-screen \
  -m gpt-5.4 \
  -c model_reasoning_effort=xhigh \
  -a never \
  -s workspace-write \
  "Read AGENTS.md and follow it exactly. This session is initialized.
   Begin with: python harness.py fetch.
   Solve problems in order. Use python harness.py run <file> --input \"...\" to test.
   Then python harness.py submit <id> <file>. Max 3 submissions per problem."
```

For GPT-5.4 mini use `-m gpt-5.4-mini -c model_reasoning_effort=medium`.

`-a never` blocks autoapproval prompts; `-s workspace-write` scopes file
writes to the cwd, which is what we want for cell isolation.

### B.2 OpenAI SDK (Python) — programmatic driver

If you want to drive Codex programmatically instead of through the CLI:
```bash
pip install openai
```

```python
import os, subprocess
from pathlib import Path
from openai import OpenAI

CELL = Path("experiments/01_main_experiments/codex/gpt_5_4_xhigh/brainfuck")
os.chdir(CELL)
subprocess.run(["python", "harness.py", "init", "--language", "brainfuck"], check=True)

client = OpenAI()
agents_md = (CELL / "AGENTS.md").read_text()
# Use the Responses API with tool use; the AGENTS.md text is the system instruction.
# (Full driver loop reading the agent's tool calls and routing them through
# `python harness.py {fetch,run,submit,status}` is left to the user; see the
# OpenAI Responses + Computer Use cookbook for the canonical pattern.)
response = client.responses.create(
    model="gpt-5.4",
    reasoning={"effort": "high"},
    instructions=agents_md,
    input="Begin solving. python harness.py fetch.",
)
print(response.output_text)
```

## C. OpenCode (Kimi K2.5)

OpenCode is a third-party agentic wrapper that hosts Moonshot's Kimi K2.5
checkpoint. Install instructions live at the OpenCode project page; the CLI
binary is `opencode`.

```bash
export OPENCODE_API_KEY=...     # set per OpenCode docs
cd experiments/01_main_experiments/opencode/kimi_k2_5/brainfuck
python harness.py init --language brainfuck

opencode -m kimi-k2-5 \
  "Read AGENTS.md and follow it exactly. Begin with python harness.py fetch."
```

## D. OpenRouter — one key, every model in the paper

[OpenRouter](https://openrouter.ai) is a single, OpenAI-compatible gateway to
Claude, GPT, Kimi, Llama, and more. One `OPENROUTER_API_KEY` lets you reproduce
**every** cell in the paper without holding a separate plan per provider. The
benchmark cell is identical — only the wrapper's provider config changes.

```bash
export OPENROUTER_API_KEY=sk-or-...
# OpenRouter base URL (OpenAI-compatible):  https://openrouter.ai/api/v1
# Model ids are namespaced, e.g.:
#   anthropic/claude-opus-4   anthropic/claude-sonnet-4   anthropic/claude-haiku-4
#   openai/gpt-5   openai/gpt-5-mini   moonshotai/kimi-k2
# (use the current ids listed at https://openrouter.ai/models)
```

### D.1 OpenCode → OpenRouter (recommended, cleanest)

OpenCode supports OpenRouter as a first-class provider, so it is the simplest
way to run any model with one key:

```bash
cd experiments/01_main_experiments/opencode/kimi_k2_5/brainfuck
python harness.py init --language brainfuck

opencode -m openrouter/anthropic/claude-opus-4 \
  "Read AGENTS.md and follow it exactly. Begin with python harness.py fetch."
```

Swap the model id to evaluate any agent (e.g. `openrouter/openai/gpt-5`,
`openrouter/moonshotai/kimi-k2`). See the OpenCode docs for the exact
`provider/model` id format and any one-time `opencode auth`/config step.

### D.2 Codex → OpenRouter (OpenAI-compatible custom provider)

Because OpenRouter speaks the OpenAI API, Codex can target it with a custom
model provider. Add to `~/.codex/config.toml`:

```toml
[model_providers.openrouter]
name     = "OpenRouter"
base_url = "https://openrouter.ai/api/v1"
env_key  = "OPENROUTER_API_KEY"
```

Then run a cell against it:

```bash
cd experiments/01_main_experiments/codex/gpt_5_4_xhigh/brainfuck
python harness.py init --language brainfuck

codex -m "openai/gpt-5" -c model_provider=openrouter \
  -a never -s workspace-write \
  "Read AGENTS.md and follow it exactly. Begin with python harness.py fetch."
```

(Field names follow the Codex CLI config schema; check the Codex docs for the
exact keys your version expects.)

### D.3 Any OpenAI-compatible driver → OpenRouter

If you drive the harness from your own script, point the OpenAI SDK at
OpenRouter and route the model's tool calls through
`python harness.py {fetch,run,submit,status}`:

```python
from openai import OpenAI
client = OpenAI(base_url="https://openrouter.ai/api/v1",
                api_key=os.environ["OPENROUTER_API_KEY"])
# model="anthropic/claude-opus-4" | "openai/gpt-5" | "moonshotai/kimi-k2" | ...
```

> Note: Claude Code (`claude`) expects an Anthropic-shaped endpoint, so the
> clean OpenRouter paths are **OpenCode (D.1)** or **Codex (D.2)**. Use a native
> `ANTHROPIC_API_KEY` with Claude Code (Section A).

## What "max submissions = 3" means in the code

The harness enforces this in `benchmark_harness/harness.py`:

```python
MAX_SUBMISSIONS = 3
...
if len(prob_state["submissions"]) >= MAX_SUBMISSIONS:
    print(f"ERROR: Maximum {MAX_SUBMISSIONS} submissions reached for {pid}.")
    sys.exit(1)
```

The agent CANNOT bypass it from inside the wrapper, since the harness is
the only path to the hidden tests. Local interpreter calls
(`python harness.py run …`) are not counted; only `submit` consumes one of
the three budgeted slots.

## Run a full cell end-to-end (no API key required, smoke test)

This drives the harness as if you were the agent — useful to confirm
everything is wired before you spend tokens.

```bash
cd experiments/01_main_experiments/claude_code/opus_4_6/brainfuck
python harness.py init --language brainfuck
python harness.py fetch
echo ',[.,]' > tmp.bf            # echo input as BF
python harness.py run tmp.bf --input "hello"
python harness.py submit E01 tmp.bf
python harness.py status
```

Against the redacted private file shipped with this supplementary release,
the submission will return `WRONG ANSWER` — that is the expected behaviour
without the unredacted hidden tests. The smoke test in
`scripts/test_harness.sh` exercises the same path.

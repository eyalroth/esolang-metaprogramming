#!/usr/bin/env python3
"""Build ONE pi benchmark grid cell:

    experiments/01_main_experiments/pi/<provider>/<model>/<thinking>/<language>/
        harness.py   -> symlink to benchmark_harness/harness.py
        AGENTS.md    -> symlink to prompts/<language>/AGENTS.md

Cells are keyed on the FULL experimental grid: harness x provider x model x
thinking x language. This whole `pi/` dir under experiments/01_main_experiments/
IS the "harness" dimension (sibling to the paper's claude/codex/opencode) --
so provider, model, thinking, and language are the remaining axes, and every
combination gets its own cell + its own harness_state.json. Two different
providers, models, or thinking levels run against the same language NEVER
collide or overwrite each other's results.

This script is the SINGLE SOURCE OF TRUTH for that path: run_cell.sh calls it
(rather than recomputing the path itself) and parses its printed `CELL_DIR=`
/ `ARTIFACT=` lines. Idempotent -- safe to re-run (re-linking is a no-op if
already correct); cells are built on demand, not pre-baked into the repo.

Usage:
    python3 pi/setup_cells.py --provider <p> --model <m> [--thinking <t>] [--language <lang>]

If --language is omitted, builds all 4 language cells for that
provider/model/thinking triple (a convenience for pre-building a whole grid
point's languages at once; run_cell.sh itself always passes a single
--language).
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

PI_DIR = Path(__file__).resolve().parent
REPO_ROOT = PI_DIR.parent
EXPT_ROOT = REPO_ROOT / "experiments" / "01_main_experiments" / "pi"
HARNESS_PATH = (REPO_ROOT / "benchmark_harness" / "harness.py").resolve()
PROMPTS_DIR = REPO_ROOT / "prompts"
ARTIFACTS_ROOT = PI_DIR / "artifacts"

DEFAULT_THINKING_LABEL = "default"

# (cell_dirname, prompts_subdir) -- cell_dirname matches --language values
# used elsewhere in the repo; prompts_subdir matches the actual prompts/ tree
# (which drops the hyphen for befunge-98 -> befunge98).
LANGS = [
    ("brainfuck", "brainfuck"),
    ("befunge-98", "befunge98"),
    ("whitespace", "whitespace"),
    ("shakespeare", "shakespeare"),
]
LANG_DIRNAMES = [l[0] for l in LANGS]
PROMPTS_SUBDIR = dict(LANGS)


def slug(value: str) -> str:
    """Sanitize a grid-dimension value (provider/model/thinking) into a
    filesystem-safe path component: anything other than [A-Za-z0-9._-]
    becomes '_'."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", value)


def link(src: Path, dst: Path) -> None:
    if dst.exists() or dst.is_symlink():
        dst.unlink()
    rel = os.path.relpath(src, dst.parent)
    dst.symlink_to(rel)


def cell_path(provider: str, model: str, thinking: str, lang_dirname: str) -> Path:
    return EXPT_ROOT / slug(provider) / slug(model) / slug(thinking) / lang_dirname


def artifact_path(provider: str, model: str, thinking: str, lang_dirname: str) -> Path:
    return ARTIFACTS_ROOT / slug(provider) / slug(model) / slug(thinking) / f"{lang_dirname}_export.json"


def build_one(provider: str, model: str, thinking: str, lang_dirname: str) -> Path:
    prompts_subdir = PROMPTS_SUBDIR[lang_dirname]
    prompt_src = (PROMPTS_DIR / prompts_subdir / "AGENTS.md").resolve()
    if not prompt_src.exists():
        print(f"ERROR: prompt not found at {prompt_src}", file=sys.stderr)
        sys.exit(1)

    cell = cell_path(provider, model, thinking, lang_dirname)
    cell.mkdir(parents=True, exist_ok=True)
    link(HARNESS_PATH, cell / "harness.py")
    link(prompt_src, cell / "AGENTS.md")
    return cell


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--provider", required=True, help="pi provider name (e.g. anthropic) -- required, no default")
    ap.add_argument("--model", required=True, help="pi model id")
    ap.add_argument("--thinking", default=DEFAULT_THINKING_LABEL,
                     help=f"pi thinking level (off/minimal/low/medium/high/xhigh); "
                          f"omit to use the model's own default (labeled '{DEFAULT_THINKING_LABEL}' in the path)")
    ap.add_argument("--language", choices=LANG_DIRNAMES, help="omit to build all 4 languages")
    args = ap.parse_args()

    if not HARNESS_PATH.exists():
        print(f"ERROR: harness not found at {HARNESS_PATH}", file=sys.stderr)
        return 1

    langs = [args.language] if args.language else LANG_DIRNAMES
    for lang_dirname in langs:
        cell = build_one(args.provider, args.model, args.thinking, lang_dirname)
        art = artifact_path(args.provider, args.model, args.thinking, lang_dirname)
        print(f"  built  {cell.relative_to(REPO_ROOT)}")
        print(f"CELL_DIR={cell}")
        print(f"ARTIFACT={art}")

    return 0


if __name__ == "__main__":
    sys.exit(main())

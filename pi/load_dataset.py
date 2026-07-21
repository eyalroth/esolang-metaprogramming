#!/usr/bin/env python3
"""Pull the real (unredacted) EsoLang-Bench hidden tests from HuggingFace and
write them in the harness's private-file schema, WITHOUT ever touching the
tracked, redacted `benchmark_harness/private/esolang_full_private.json`.

Output goes to a git-ignored local file:
    benchmark_harness/private/esolang_full_private.local.json

Point the harness at it at runtime via:
    HARNESS_PRIVATE_FILE=<repo_root>/benchmark_harness/private/esolang_full_private.local.json \
        python harness.py submit ...

(pi/run_cell.sh does this automatically.)

Usage:
    python pi/load_dataset.py [--out PATH] [--dataset REPO_ID]

Exit codes:
    0  success, local file written
    1  dataset fetch failed (network / gating / missing deps) -- prints a
       clear message; does NOT silently fall back to the redacted file.
    2  fetched data failed schema validation
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PI_DIR = Path(__file__).resolve().parent
REPO_ROOT = PI_DIR.parent
DEFAULT_OUT = REPO_ROOT / "benchmark_harness" / "private" / "esolang_full_private.local.json"
DEFAULT_DATASET = "Lossfunk/Esolang-Bench"

EXPECTED_PROBLEM_COUNT = 80
EXPECTED_TESTS_PER_PROBLEM = 6


def fetch_rows(dataset_repo: str):
    try:
        from datasets import load_dataset
    except ImportError as e:
        print(
            "ERROR: the `datasets` package is not installed.\n"
            "  pip install datasets huggingface_hub\n"
            f"  (root cause: {e})",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        ds = load_dataset(dataset_repo)
    except Exception as e:  # noqa: BLE001 - report and exit, never guess
        msg = str(e)
        gated_hint = ""
        if "gated" in msg.lower() or "401" in msg or "access" in msg.lower():
            gated_hint = (
                "\nThis looks like a GATED dataset. You'll need to:\n"
                "  1. Accept the dataset's terms on the HuggingFace page while logged in.\n"
                "  2. Set HF_TOKEN in the environment (huggingface_hub will pick it up), or\n"
                "     run `huggingface-cli login`.\n"
                "  3. Re-run this script.\n"
            )
        print(
            f"ERROR: failed to fetch dataset '{dataset_repo}' from HuggingFace.\n"
            f"  {msg}{gated_hint}",
            file=sys.stderr,
        )
        sys.exit(1)

    # The dataset ships as a single split (observed: 'test'); take whichever
    # split(s) exist and concatenate rows, deduped by id (first-seen wins).
    rows = []
    seen_ids = set()
    for split_name in ds.keys():
        for row in ds[split_name]:
            if row["id"] in seen_ids:
                continue
            seen_ids.add(row["id"])
            rows.append(row)
    return rows


def to_private_schema(rows):
    problems = []
    for row in rows:
        test_cases = [
            {"input": tc["input"], "output": tc["output"]}
            for tc in row["test_cases"]
        ]
        problems.append(
            {
                "id": row["id"],
                "difficulty": row["difficulty"],
                "title": row["title"],
                "description": row["description"],
                "test_cases": test_cases,
            }
        )
    # Keep a stable, human-diffable order: E01..E20, M01..M20, H01..H20, X01..X20
    problems.sort(key=lambda p: p["id"])
    return {"metadata": {"source": "Lossfunk/Esolang-Bench (HuggingFace, unredacted)"}, "problems": problems}


def validate(data) -> list[str]:
    errors = []
    problems = data.get("problems", [])
    if len(problems) != EXPECTED_PROBLEM_COUNT:
        errors.append(
            f"expected {EXPECTED_PROBLEM_COUNT} problems, got {len(problems)}"
        )
    for p in problems:
        pid = p.get("id", "<missing id>")
        tcs = p.get("test_cases", [])
        if len(tcs) != EXPECTED_TESTS_PER_PROBLEM:
            errors.append(
                f"{pid}: expected {EXPECTED_TESTS_PER_PROBLEM} test_cases, got {len(tcs)}"
            )
        for i, tc in enumerate(tcs):
            out = tc.get("output", "")
            if "REDACTED" in out:
                errors.append(f"{pid}: test_case[{i}] still looks redacted")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(DEFAULT_OUT), help="Output path for the local private JSON")
    parser.add_argument("--dataset", default=DEFAULT_DATASET, help="HuggingFace dataset repo id")
    args = parser.parse_args()

    out_path = Path(args.out).resolve()

    # Hard safety check: never let --out point at the tracked redacted file.
    tracked_private = (REPO_ROOT / "benchmark_harness" / "private" / "esolang_full_private.json").resolve()
    if out_path == tracked_private:
        print(
            f"ERROR: refusing to write over the tracked redacted file: {tracked_private}\n"
            "Use a different --out (default is the .local.json variant).",
            file=sys.stderr,
        )
        return 1

    print(f"Fetching '{args.dataset}' from HuggingFace (anonymous)...")
    rows = fetch_rows(args.dataset)
    print(f"  fetched {len(rows)} rows")

    data = to_private_schema(rows)
    errors = validate(data)
    if errors:
        print("ERROR: fetched data failed schema validation:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 2

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(data, f, indent=2)

    print(f"Wrote {len(data['problems'])} problems -> {out_path}")
    print("Reminder: this file is git-ignored and must NEVER be committed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

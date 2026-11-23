#!/usr/bin/env python3
"""GDScript lint and format check with a baseline for the existing code.

Runs gdlint and gdformat (gdtoolkit) over the project's own scripts. Problems
that already exist in the code inherited from Cogito are recorded in
tools/lint_baseline.json; the check fails only when a file gets a problem it did
not have before (per file and rule, counted, so line shifts don't matter), when
a formatted file stops being formatted, or when a new file is not formatted.

    uvx --from gdtoolkit==4.5.0 python tools/lint.py            # check
    uvx --from gdtoolkit==4.5.0 python tools/lint.py --update   # rewrite the baseline
    uvx --from gdtoolkit==4.5.0 python tools/lint.py --format tests/foo.gd  # format files

Run --update only after fixing problems (to lower the baseline) or after an
upstream merge; never to hide problems in new code.
"""

import argparse
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path

from gdtoolkit.formatter import format_code
from gdtoolkit.linter import DEFAULT_CONFIG, lint_code

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "tools" / "lint_baseline.json"
CONFIG = ROOT / "gdlintrc"
# Third-party addons are linted by their own projects.
EXCLUDED = ("addons/gdUnit4/", "addons/godot_state_charts/", "addons/input_helper/")
LINE_LENGTH = 100


def load_config() -> dict:
    config = dict(DEFAULT_CONFIG)
    if CONFIG.exists():
        import yaml  # gdtoolkit depends on PyYAML

        config.update(yaml.safe_load(CONFIG.read_text()) or {})
    return config


def project_scripts() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.gd"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.split()
    return sorted(p for p in out if not p.startswith(EXCLUDED) and (ROOT / p).exists())


def check_file(path: str, config: dict) -> tuple[Counter, bool, list[str]]:
    """Returns (problem counts by rule, is formatted, human readable problems)."""
    code = (ROOT / path).read_text(encoding="utf-8-sig")
    try:
        problems = lint_code(code, config)
    except Exception as e:  # lark parse errors: gdtoolkit can't read this file
        first = str(e).strip().splitlines()[0] if str(e).strip() else type(e).__name__
        return Counter({"parse-error": 1}), False, [f"{path}: parse error: {first}"]
    counts = Counter(p.name for p in problems)
    lines = [f"{path}:{p.line}: {p.description} ({p.name})" for p in problems]
    try:
        formatted = format_code(code, LINE_LENGTH) == code
    except Exception:
        formatted = False
    return counts, formatted, lines


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--update", action="store_true", help="rewrite the baseline")
    parser.add_argument("--format", nargs="+", metavar="FILE", help="format files in place")
    args = parser.parse_args()

    if args.format:
        for f in args.format:
            p = Path(f)
            code = p.read_text(encoding="utf-8-sig")
            p.write_text(format_code(code, LINE_LENGTH), encoding="utf-8")
            print("formatted", f)
        return 0

    config = load_config()
    results = {path: check_file(path, config) for path in project_scripts()}

    if args.update:
        baseline = {
            "problems": {p: dict(sorted(c.items())) for p, (c, _, _) in results.items() if c},
            "unformatted": sorted(p for p, (_, ok, _) in results.items() if not ok),
        }
        BASELINE.write_text(json.dumps(baseline, indent=1, sort_keys=True) + "\n")
        total = sum(sum(c.values()) for c, _, _ in results.values())
        print(f"baseline updated: {total} problems, {len(baseline['unformatted'])} unformatted files")
        return 0

    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
    known = baseline.get("problems", {})
    unformatted = set(baseline.get("unformatted", []))
    failures: list[str] = []
    improved: list[str] = []

    for path, (counts, formatted, lines) in results.items():
        allowed = Counter(known.get(path, {}))
        for rule, n in counts.items():
            if n > allowed[rule]:
                failures.append(f"{path}: {rule} {allowed[rule]} -> {n}")
                failures += [f"    {l}" for l in lines if l.endswith(f"({rule})") or rule == "parse-error"]
        if any(counts[r] < n for r, n in allowed.items()):
            improved.append(path)
        if not formatted and path not in unformatted:
            failures.append(f"{path}: not gdformat-formatted (run tools/lint.py --format {path})")
        if formatted and path in unformatted:
            improved.append(path)

    for line in failures:
        print(line)
    if improved:
        print(f"note: {len(set(improved))} file(s) improved; run with --update to lower the baseline")
    total = sum(sum(c.values()) for c, _, _ in results.values())
    print(f"lint: {len(results)} files, {total} problems (baseline), {len(failures)} new")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

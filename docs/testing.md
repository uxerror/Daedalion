# Testing

Use Godot 4.7.2, Python 3 and gdtoolkit 4.5.0. If gdlint is on PATH, the check script runs the installed Python tools. Otherwise it uses uvx with gdtoolkit pinned to 4.5.0. For offline use, have the tools installed or cached before starting.

Run from the repository root. The first command runs every step. The second selects two steps.

```sh
GODOT_BIN=/usr/bin/godot tools/check.sh
GODOT_BIN=/usr/bin/godot tools/check.sh tests smoke
```

[tools/check.sh](../tools/check.sh) imports the project if the import cache is missing and runs Godot at lower CPU priority by default.

| Step | What it checks |
| --- | --- |
| lint | [lint.py](../tools/lint.py) runs gdlint and checks gdformat formatting against [lint_baseline.json](../tools/lint_baseline.json). New findings in a file fail the check. |
| warnings | [gd_warnings.py](../tools/gd_warnings.py) collects the Godot language server's diagnostics and compares them with [gd_warnings_baseline.json](../tools/gd_warnings_baseline.json). |
| tests | The bundled gdUnit4 runner discovers suites in [tests](../tests). They cover elements, saves, NPCs, items, quests, UI and objects. The wrapper creates a temporary user data directory and deletes it afterwards. |
| smoke | The main menu, Lobby and Laboratory run headless for 400 frames each. The wrapper checks their output for script, parse and engine errors, with exceptions for known shutdown leak messages. |

## Run gdUnit4 directly

The editor's gdUnit4 panel can run a suite or individual test. For a headless run, set a throwaway `XDG_DATA_HOME` on Linux. This keeps test saves separate from your playthrough. Run the following in one shell.

```sh
export GODOT_BIN=/usr/bin/godot
export XDG_DATA_HOME="$(mktemp -d)"
nice -n 19 "$GODOT_BIN" --headless --path . --import
nice -n 19 timeout 1500 bash addons/gdUnit4/runtest.sh --headless --ignoreHeadlessMode -a res://tests
```

Check the overall summary and the runner's exit code. The HTML reports go under `reports/`. After the run, the temporary data directory can be removed.

## Baselines and CI

After fixing existing findings, run `python3 tools/lint.py --update` or `nice -n 19 python3 tools/gd_warnings.py --update` with the same tool versions. Review the baseline diff to make sure it reflects the fixes. Format an individual script with `python3 tools/lint.py --format path/to/script.gd`.

The [Checks workflow](../.github/workflows/checks.yml) runs on pushes, pull requests and manual dispatch. It installs the pinned lint tools, imports the project with Godot 4.7.2, checks warnings, then runs tests and smoke. It uploads the gdUnit report when available.

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

## Prediction PR0

Run the same sample-to-render measurement in memory, across the socket-free file bus,
or across real ENet on a host with UDP loopback. The process scenario runs all twelve
action/profile combinations in a single session. The multiplayer step includes ENet
and the file latency scenario.

```sh
export GODOT_BIN=/usr/bin/godot XDG_DATA_HOME="$(mktemp -d)"
nice -n 19 bash addons/gdUnit4/runtest.sh --headless --ignoreHeadlessMode -a res://tests/net/net_latency_test.gd
python3 tools/check_multiplayer.py --file-transport --scenario latency
python3 tools/check_multiplayer.py --scenario latency
```

### Test transport settings

The memory and file peers both expose `configure(source, channel, options)` on the
**receiving** peer. To delay commands from peer 2, configure source 2, channel 1 on
the server. To delay the poses back, configure source 1, channel 1 on that client.
An empty configuration delivers packets immediately by default. File process launches
also accept these environment defaults for all inbound streams.

| Options key | File environment variable | Units and default |
|---|---|---|
| `delay_ms` | `COGITO_FILE_DELAY_MS` | One-way base delay, 0 ms |
| `jitter_ms` | `COGITO_FILE_JITTER_MS` | Uniform offset from −jitter to +jitter, 0 ms. The resulting delay has a floor of zero. |
| `loss` | `COGITO_FILE_LOSS` | Probability from 0 to 1 of dropping an unreliable packet, 0 |
| `dup` | `COGITO_FILE_DUP` | Probability from 0 to 1 of adding one copy of a surviving unreliable packet, 0 |
| `seed` | `COGITO_FILE_SEED` | Per-stream RNG seed input, 1. The latency profiles use 140. |

Reliable streams deliver every packet once in send order. Unreliable ordered streams
discard superseded packets and duplicates on delivery. Unordered duplicates have
independent deadlines. Each direction, channel and transfer mode has its own random
stream. Memory uses the engine physics frame counter, which stays constant through
the session fixture's twelve polls. File uses the receiver's monotonic microsecond clock.
The latency scenarios select one-way delays of 0, 8, 50 and 75 ms and add ±10 ms jitter
to the latter two. For ENet a test-only UDP relay applies the profile to loopback datagrams.

### Reading the phase stamps

The memory and process runs print one JSON row per trial. Use `seq` to match the first
command to the authority's `consume_tick`. On the same server clock, `effect_tick` is
the first changed transform and `capture_tick` is the first publication with that effect.
The owner records the actual accepted `pose_tick` and its `arrival_us` inside timeline
insertion. After normal `present()`, it records the first `render_frame` and `render_us`
with forward motion, upward motion or a lower head, respectively (threshold 0.1 mm).
`render_delta` records the movement during that render pass.
`screen_ms` compares `render_us` with `sample_us` on the owner. The client's `sample_tick`
and the server tick numbers use independent origins. `up_ms` and `down_ms` are mean
delivered scheduling delays, including poll quantization. The recorded results are in
[the prediction plan](dev/prediction-plan.md#measured-pr0).

The pending PR3 test holds both directions for 250 ms, samples one forward command
on a settled owner, then checks the transform at the end of that same physics tick.
PR0 requires zero displacement, an unchanged received pose tick and a command sequence
the server has yet to receive. It subsequently waits for visible movement backed by a pose.
PR3 will require more than 1 mm forward on the sampled tick.

### Offline movement goldens

The runner puts a local Advanced actor in a fresh current scene for each route. Use
`--fixed-fps 60` to advance physics, idle callbacks, timers, animation and tweens with
the same delta. The input source supplies tick-indexed axes, holds and edges. The
runner fixes head bob, crouch mode, seat exit and the RNG seed after actor setup.

```sh
nice -n 19 bash addons/gdUnit4/runtest.sh --headless --ignoreHeadlessMode -a res://tests/player/golden_movement_test.gd
nice -n 19 godot --headless --path . --fixed-fps 60 res://tests/player/golden_runner.tscn
nice -n 19 godot --headless --path . --fixed-fps 60 res://tests/player/golden_runner.tscn -- --regenerate
```

The last command rewrites the reference CSVs after two byte-identical laps. The gdUnit
test launches two fresh engine processes. Each compares two laps and the committed
references and reports a digest of all routes. A mismatch prints the first differing row.
The ten routes cover walk/sprint/stop and jump/landing, crouch hold/release under a roof
and toggle in the open, stair ascent/descent, slide-jump, ladder ascent/descent/jump-off,
surfacing/diving and climbing onto the pool bank, a dry ledge climb, hard landing through
roll completion, a moving platform ride and seat entry/exit through the chart delay.

Rows are sampled after physics, at the next `process_frame` signal, before the idle
callbacks for that frame. Each row stores position, velocity, main velocity, local head and eye positions
and stamina as integers scaled by 100,000. Comparison is exact after rounding to
0.00001. Moving and posture enums, active-state bitset (paths in the file header),
enabled shapes (standing bit 0, crouching bit 1), contact/stage flags and cumulative
effect counts compare exactly. The footstep detector counts footstep and landing
playback calls, the audio autoload supplies jump one-shot starts, and the slide counter
records the loop starting. All ten routes use the same comparison, including roll and
seat tweens. [Reference traces](../tests/player/golden/)

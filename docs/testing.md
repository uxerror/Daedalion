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

## Network ragdolls

`net_npc_corpse_test.gd` checks the authored solver, the 16-byte bone codec, presented
skeleton joints, the kinematic grip ray, interpolation, interest baselines and silence
after rest. `net_npc_test.gd` kills the arena guard and checks its pose on the original
clients and a late joiner. It exercises exclusive grabs on both grips. The restart suite
checks every bone after a save in motion and loads old prone-box records with and without
a scene path. The travel suite compares the sleeping pose after room re-entry and reconnect.

Run the separate-process checks from the project root after importing the project.

```sh
python3 tools/check_multiplayer.py --file-transport --scenario npc_dedicated
python3 tools/check_multiplayer.py --file-transport --scenario npc_listen
```

Each scenario compares all 40 positions and rotations at rest against the authority
(2 cm / 3°), counts received corpse-row bytes through the fall and checks another second
of silence. The drag must move the body on an observer. The dedicated scenario adds a
late joiner. Run the harness without the scenario selector for the full matrix and repeat
with `COGITO_AUTHORITY_MOVEMENT=1 COGITO_OWNER_PREDICTION=1`. Omit `--file-transport`
on a machine with loopback UDP to exercise ENet.

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

The same-tick gate delays both directions by 250 ms and samples a settled owner. With
prediction off it requires zero movement. With both movement switches enabled it requires
forward movement over 1 mm, upward travel on jump, a descending crouch eye and reduced
speed on stop. Each observation precedes authority receipt and any new pose.
A predicted `render_us` can precede `arrival_us`. The probe waits for both events
before emitting the row and records the initial visible displacement in `render_delta` on
this path.
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
The eighteen routes cover walk/sprint/stop and jump/landing, crouch hold/release under a roof
and toggle in the open, stair ascent/descent, slide-jump, ladder ascent/descent/jump-off,
surfacing/diving and climbing onto the pool bank, a dry ledge climb, hard landing through
roll completion, a moving platform ride and seat entry/exit through the chart delay.
They also exercise exhaustion, a drop, air steering, contact with a wall during sprint,
jump from crouch and the timing of slide expiry and takeoff.

Rows are sampled after physics, at the next `process_frame` signal, before the idle
callbacks for that frame. Each row stores position, velocity, main velocity, local head and eye positions
and stamina as integers scaled by 100,000. Comparison is exact after rounding to
0.00001. Moving and posture enums, active-state bitset (paths in the file header),
enabled shapes (standing bit 0, crouching bit 1), contact/stage flags and cumulative
effect counts compare exactly. The footstep detector counts footstep and landing
playback calls, the audio autoload supplies jump one-shot starts, and the slide counter
records the loop starting. All eighteen routes use the same comparison, including roll and
seat tweens. [Reference traces](../tests/player/golden/)


## Prediction PR1b authority gates

Run `net_authority_trace_test.gd` and `net_authority_movement_test.gd` under gdUnit.
The trace test runs the actual listen authority in two fresh, fixed-60-Hz processes.
SHA-256 digests pin all 1,442 legacy rows, including mode, shape, eye height, speed
and stamina. Each row counts real Advanced moves and kernel commits. A second test
compares 90 consecutive displacements on dedicated and listen authorities with a
1 mm maximum difference and checks the replicated stamina HUD. Handoff tests count
commits across ladder, water, seat, respawn, impulse, platform, ledge and roll boundaries.

The first forward sample moves 13.89 mm on the test floor. Jump displacement and
crouch eye motion also start on the sample tick. The table gives maximum allowed
3D position differences in metres. The second bound compares each sample to the
three legacy samples centred on that tick. This accounts for a tread or landing
crossed one tick earlier. The toggle-roof trace ends while walking, which limits
the reference window at its endpoint.

| Route | Same tick | Within one tick |
|---|---:|---:|
| Walk, sprint, stop, jump and land | .090 | .055 |
| Hold crouch and roof | .090 | .020 |
| Toggle crouch and roof | .090 | .085 |
| Stairs up and down | .240 | .015 |
| Slide and slide-jump | .160 | .035 |
| Exhaustion and regeneration | .120 | .001 |
| Slope | .070 | .003 |
| Diagonal wall slide | .070 | .003 |

The stair bound includes the 20 cm difference between adjacent treads. Mode,
posture, active hull and slide-jump latch must occur within two ticks of the
reference. In that window speed must agree within 0.14 m/s and head height within
5 mm. Slide-jump has bounds of 0.5 m/s and 0.12 m during takeoff and standing up.
Stamina must agree within 0.14 units on every sample. The runner also
checks actual playback and authoritative NPC noise counts per route. The offline
golden runner retains its exact CSV, motion and save-byte checks.

For process coverage run `python3 tools/check_multiplayer.py --file-transport`
with `COGITO_AUTHORITY_MOVEMENT=0` and again with `COGITO_AUTHORITY_MOVEMENT=1`.
The child processes inherit the switch. Compare the `PR0 file` rows using
`consume_tick`, `effect_tick` and `screen_ms`.


## Prediction PR2 owner checkpoint

Run the net gdUnit suites with the authority switch off and on. The codec tests enumerate
the stored movement fields independently of the wire schema. The authority trace runner
prints `PR2 TRACE` for seven checkpoints, each followed by 60 commands on a fresh collision
adapter and fixed-tick stepper. It compares contacts, timers, permissions, posture, hull,
stamina, position, velocity and simulation head height on every tick.

`net_owner_session_test.gd` checks dedicated and listen owner privacy on serialized RPCs,
reliable life renewal, takeover, explicit pose acceptance and rejection of a protocol 17 peer by a protocol 18 host.
The movement source test covers repeated, skipped, expired and wrapped sequences. The
authority and travel suites check mode generations across handoffs and room bindings.

The dedicated process scenario samples the same avatar's delivered Variant pose row
payload on its owner and observer for at least one second each. The two `PR2` lines
report bytes per simulated second, excluding the enclosing batch, RPC and transport
headers. Each process also records its local decoded mode in `NET POS`. Run
`nice -n 19 python3 tools/check_multiplayer.py --file-transport` for the socket-free
suite and repeat with `COGITO_AUTHORITY_MOVEMENT=1`.


## Prediction PR3

Run the full gdUnit and file-transport suites with both switches off, authority only,
and both `COGITO_AUTHORITY_MOVEMENT=1` and `COGITO_OWNER_PREDICTION=1`. The dedicated
prediction fixture opts into both switches locally for its lifecycle and correction
tests. The latency and normal session fixtures inherit the process settings.

`net_prediction_test.gd` prints the ack, replayed sequences and independent shadow
errors for a 0.30 m server push and a rejected jump. The fixture tracks weapon fire,
movement audio, live input samples and packets. An Area monitors the trigger layer in
the owner's room. Further cases exercise a lost tap, held and expired input, a sequence
gap, wrap, exhausted history, duplicate packets, clock limits, camera clearance and the
simulation ray. `PR3 LANE` reports p50, p95 and maximum matched-ack position error in
metres, maximum replay depth, suspended ticks and backwards camera steps after warm-up.

`python3 tools/check_multiplayer.py --file-transport --scenario prediction` drives a
dedicated server with two clients and a listen host with one client. The encoder drops
the datagram containing a jump tap. `PR3 PROCESS` reports the sample-to-send displacement
and whether the received pose tick stayed fixed. The crouch row includes the route's
correction statistics when prediction is active. Run the same command without
`--file-transport` for ENet. The `latency` scenario runs all four RTT profiles and prints
one `PR0` row per walk, jump and crouch trial. These timings end at headless presentation.

## Prediction PR4 boundaries

`tests/net/net_prediction_boundaries_test.gd` compares every replayed post to an independently
advanced reference in a memory session. It exercises static stairs in both directions, a slide
jump and slide expiry, a lost fallback pose, local dynamic support and ledge detection, stamina
exhaustion, an external spend, freeze/thaw and node reuse after death. The authority suite
prints `PR4 CROSS` displacements. Travel tests cover failed preparation, a source checkpoint
at the destination and a vehicle without a matching destination seat. The physics action
suite checks a single throw with duplicated inputs and two owners exchanging the driver grant.
The owner-session suite feeds accepted poses through the observer endpoint and checks its
100 ms presentation clock and 50 ms extrapolation limit across movement and seat changes.

Run the complete gdUnit and file-transport suites with both switches off, authority only and
both on. Give each run a fresh XDG_DATA_HOME. The focused process run is
`python3 tools/check_multiplayer.py --file-transport --scenario prediction_boundaries`.
Omit `--file-transport` for ENet. In each topology Ada drives the real input sampler over a
static test staircase in Lobby, slides, jumps, sits, stands and travels to Laboratory.
`PR4 PROCESS` reports the climb, the observed mode changes, suspension counts at the seat and
destination, and whether prediction resumed. The dedicated fixture includes a second client.
The listen host runs its authority controller.

For a GUI impairment check, start a server on port 7777 and run this in a separate terminal
at the repository root. Join the printed loopback port with the owning client. The relay
accepts one owner. Connect the observer directly to port 7777. Use `r.profile(100)` or
`r.profile(150)` at the prompt to switch RTT, and `r.close()` to finish.

```sh
python3 -i -c 'import sys; sys.path.insert(0,"tools"); from check_multiplayer import DelayRelay; r=DelayRelay(7777); r.profile(150); print(r.port)'
```


## Prediction PR6 ladders and swimming

The original ladder and swim routes contribute to the eighteen-route PR1a digest.
Run the additional offline routes separately with
`nice -n 19 godot --headless --path . --fixed-fps 60 res://tests/player/volume_golden_runner.tscn`.
The two digests include pitch-dependent ladder reversal, jump-off, dive, rise and exit.
The gdUnit volume fixture also runs both routes.

The legacy-chart comparison checks position and mode on all 80 ladder ticks up to
jump-off and all 188 swim-route ticks through the ledge exit. At jump-off the fixed
step applies the PR3 jump on the input tick.

The authority suite checks 60 successive ticks from a decoded mid-climb or mid-dive checkpoint.
It counts solves and prints displacements around ladder ends, seat entry
and release, swim ledge capture, clearance under a low bank and falling from water into
a roll. The prediction boundary suite measures climb and dive on the input tick and
compares pending commands after a 0.30 m authority push with an independent restore
from the decoded checkpoint. It also records audio and private attributes across replay.
The eight `PR6 LANE` rows report matched-ack p50, p95 and maximum error in metres,
maximum replay depth, inactive ticks and cumulative suspension reasons. Each lane checks
the change in suspension counts after warm-up. The profiles are 0, 16, 100 and 150 ms
RTT with every tenth command datagram dropped.

The `prediction_boundaries` process scenario continues in Laboratory after travel.
The ladder is at `NavigationRegion3D/MOVEMENT/Ladder`. The pool and a second ladder
are at `SwimmingTest/WaterPool` and `SwimmingTest/Ladder2`. Ada climbs, dives and
rises on live input. `PR6 PROCESS` prints displacement in metres for the authority,
owner and dedicated observer (authority and owner on listen). Use the relay procedure
above to repeat the route interactively at 100 and 150 ms, including a jump-off, a
walking exit and a ledge capture while another player observes.

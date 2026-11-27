# Daedalion 1.4 owner movement prediction and reconciliation

**Status — proposed before the 1.4 release.**

An owning client should move on the physics tick that samples its input. The server should
simulate the same command, send the resulting state with its acknowledgement, and correct
the client when their results differ. Other players continue to see interpolated avatars.

Implement a shared fixed-tick movement step for ordinary on-foot movement. Start with
walking, stopping, sprinting, crouching, jumping and landing against static geometry.
Include stairs and sliding in the release gate. Keep a server-driven path for movement
that depends on moving bodies, authored animations or asynchronous world events.

This revises the movement decision in `docs/dev/multiplayer-plan.md:9,131–137`.
The MP1a command contract and MP1b authority model already provide the starting point.
Independent travel between Lobby and Laboratory remains part of 1.4.
`docs/dev/multiplayer-plan.md:20,33–45,252–253,262–263`.

Paths beginning with `CogitoObjects/`, `Components/`, `Networking/`, `PackedScenes/`,
`SceneManagement/`, `Scripts/` or `Assets/` are relative to `addons/cogito/`.
Other paths are relative to the repository root.

## 1. Where the delay comes from

1. The local source applies mouse look on routed motion events. It collects ordered button
   edges between physics ticks and samples movement, held buttons, stick look and absolute
   aim once per physics tick. A menu taking input clears the pending edges and stick.
   `CogitoObjects/cogito_local_input_source.gd:14–46,54–93`, `docs/input-routing.md:25–33`.
2. Advanced accepts a fresh sequence and dispatches its edges. The network endpoint runs
   at physics priority 100, filters carry input, predicts wield feedback and sends one
   command datagram per living owner tick. At the default 60 Hz this is one opportunity
   every 16.67 ms. Each packet carries up to four commands, oldest first, on unreliable
   ordered channel 1. `CogitoObjects/cogito_player_advanced.gd:689–719`,
   `Networking/net_players.gd:113,600–613,655–666`, `Networking/net_command_channel.gd:4–12,22–39`,
   `docs/networking.md:444–453`.
3. The server accepts at most one **new** command per actor tick. It can simulate another
   tick with held input, skip an unrecovered sequence or expire to neutral. After movement,
   the endpoint captures poses at 25 Hz and sends one unreliable batch per ready observer.
   `Networking/net_input_source.gd:25–46,56–74`, `Networking/net_players.gd:631–652,669–683`.
4. The client disables the replica's StateChart and sets both collision layer and mask
   to zero. This includes the owning client. Its render callback follows the latest
   authoritative position and head height with `1 - exp(-22 * delta)`. Ordinary arrivals
   preserve local aim. Remote players use a different path with a 100 ms interpolation
   delay. `Networking/net_avatar.gd:88–102,113–137,141–174`,
   `Networking/net_players.gd:686–690`, `Networking/net_snapshot.gd:4–6,65–97`.

### Estimated input-to-screen time

The table estimates the **first render that contains some movement**. Assume 60 Hz physics,
60 Hz rendering, symmetric RTT, evenly distributed input and receive phases, and prompt
transport polling. The 16 ms LAN RTT is the maintainer's observation. These are calculated
timings, not camera or display measurements.

| RTT | Action changes server pose on its consumption tick, empty queue | Walk from settled idle, empty queue | Same walk with one extra queued tick |
|---:|---:|---:|---:|
| 0 ms | 38 ms | 54 ms | 71 ms |
| 16 ms | 54 ms | 70 ms | 87 ms |
| 100 ms | 138 ms | 154 ms | 171 ms |

The first column of estimates is `8.3 ms` to sample + `RTT` + `8.3 ms` to reach a server
physics opportunity + `12.5 ms` to publish + `8.3 ms` to render. The nominal snapshot
interval is 40 ms. At 60 physics ticks/s, publication falls two or three ticks apart.
Over 12 ideal physics ticks, five affected ticks publish immediately, five wait one tick
and two wait two ticks. This gives a mean post-simulation wait of 12.5 ms. A lost pose
adds another publication interval. `Networking/net_players.gd:633–652`.

The walk estimate includes one controller tick. From rest, the grounded callback integrates
using the stored `direction`, then computes direction from this tick's axes. Acknowledging
the command can therefore precede visible translation. Jump and posture transitions have
their own callback order. `CogitoObjects/cogito_player_advanced.gd:1057–1083,1143–1148,1209,1270–1283,2171–2189`.

The two-tick jitter setting arms on startup or after a stale gap. `sample()` increments its
clock before checking the deadline, so the first eligible command can wait one additional
sampling opportunity. Queue depth can also persist during steady play. Add 16.67 ms per
extra tick, plus any actual polling, rendering, display or scheduling delay. There is no
single fixed jitter surcharge. `Networking/net_input_source.gd:34–46,58–74`,
`tests/net/net_movement_test.gd:39–51`.

The first visible movement is small. At 60 fps the owner closes 30.7% of a fixed pose error
on one render, 50% in 31.5 ms and 90% in 104.7 ms. The time constant is 45.5 ms.
These describe settling after a target arrives. Walking supplies a succession of targets,
and crouching adds the server's head-height lerp before the client lerp.
`Networking/net_avatar.gd:130–145,158–167`, `CogitoObjects/cogito_player_advanced.gd:2140–2148,2171–2189`.

| Input | What the owner experiences today |
|---|---|
| Look and lean | Mouse aim changes on the event. Stick aim and free-look eye tilt update locally on a physics tick. The shipped actions include `FREE_LOOK` and have no separate left/right lean binding. `CogitoObjects/cogito_player_command.gd:6–60`, `CogitoObjects/cogito_local_input_source.gd:75–93,105–132`, `CogitoObjects/cogito_player_advanced.gd:477–501,719`, `project.godot:104–145`. |
| Walk, stop, sprint, jump, crouch | Axes, edges and the toggle latch are available locally. Displacement, take-off, speed change and crouch eye height wait for server simulation and pose delivery. `CogitoObjects/cogito_player_advanced.gd:729–754,1296–1318,2128–2155`, `Networking/net_avatar.gd:88–92,143–167`. |
| Fire, sights and reload | Eligible viewmodel, sound and tracer feedback start on the local sampled tick. The server decides fire acceptance, ammo, hits and damage. The owner cancels rejected feedback against the ack. `Networking/net_wield.gd:148–190,335–389`, `Networking/net_players.gd:603–606,647–650`. |
| Interact | Targeting and the input/hold interface are local. Doors, buttons, locks, private device views and their committed effects wait for a validated request and result on reliable channel 2. `Networking/net_interactions.gd:80–95,209–219,250–261,440–449,490–515`, `Networking/net_actions.gd:94–114`. |
| Inventory | Opening the inventory and dragging a preview are local. Stack changes, purchases, equip generation and container contents are confirmed by authority. `CogitoObjects/cogito_player_advanced.gd:739–751`, `docs/networking.md:594–610,677–686`. |
| Carry | The owner collects rotation input and can request a grab, drop or throw. The grant, wall-clamped anchor, impulse and visible body motion follow the server. Body playback has its own delayed timeline. `Networking/net_carry.gd:15–44,57–71,119–152,168–203`, `Networking/net_body_timeline.gd:32–47`. |

## 2. What a movement tick depends on

A rollback snapshot must let the **next** command produce the right step. The existing
pose includes tick, ack, revision, position, `velocity`, three look angles, head height,
moving/posture enums and seat data. Advanced also integrates `main_velocity` and retains
`last_velocity`. Restoring the published `velocity` alone loses the next acceleration,
stair and landing decisions. `Networking/net_snapshot.gd:13–34`,
`CogitoObjects/cogito_player.gd:47–68`, `CogitoObjects/cogito_player_advanced.gd:1057–1083`.

### Inventory of the live controller

| Dependency | State to restore, derive explicitly, or hand back to authority |
|---|---|
| Command and control | Sequence, immutable move/aim, held mask, ordered press/release edges, `has_control`, toggle preference, `try_crouch`, free-look state, input suppression, death and external input block. Opening a menu can replace `current_command` during edge dispatch. A network jump press also sets the held jump bit for a short tap. `CogitoObjects/cogito_player_command.gd:61–97,100–142`, `CogitoObjects/cogito_player_advanced.gd:331–354,689–754`. |
| Integration | Level-local transform and body orientation, `velocity`, `main_velocity`, `last_velocity`, `direction`, `input_direction`, `current_speed`, `current_lerp_speed`, gravity magnitude/direction and accumulated `gravity_vec`. Preserve the order of clamping, acceleration, stair checks and the velocity saved for the following tick. Gravity overrides can immediately move the body. `CogitoObjects/cogito_player_advanced.gd:149–186,671–679,1057–1083,1722–1745`. |
| Ground, jump and air | `is_jumping_started`, `is_in_air`, `was_in_air`, `jump_target_speed`, `was_jumping`, `was_sprinting`, `is_sprinting_in_airborne`, `was_standing`, `was_sliding`, `jumped_from_slide`, `jumped_from_crouch`, `bunny_hop_speed`, jump cooldown and wall normal. Landing reads previous vertical speed and can change posture, roll, play a landing or cause damage. `CogitoObjects/cogito_player_advanced.gd:807–819,962–1054,1127–1189,1213–1218,1331–1368,1758–1811`. |
| Ground contacts and steps | Previous floor/wall/ceiling status and normals, floor snap and slope settings, support identity, support velocity and platform-on-leave policy. A step uses two candidate heights, forward/down and wall-slide sweeps, air-step policy, `head_offset` and a speed clamp. `StepResult`, test-motion parameters and results are scratch for one solve. `CogitoObjects/cogito_player_advanced.gd:110–116,149–160,465–474,504–549,550–660,980–988,2205–2208`. |
| Posture and eye | Standing/crouching shape enable bits, crouch-cast enabled/clear, head position, stair offset, body yaw, neck yaw, head pitch, eyes position and roll, and the head-water cast origin. Standing re-enables the tall shape only after head height passes `CROUCHING_DEPTH / 4`. A posture enum cannot reconstruct that intermediate tick. `CogitoObjects/cogito_player_advanced.gd:196–210,278–299,482–501,1106–1111,2128–2189`. |
| Slide | Entry direction in `slide_vector`, slide active/remainder, entry from air, crouch/stand latch, current speed and jump-from-slide state. Remaining time directly scales speed. Standing stops the timer. `CogitoObjects/cogito_player_advanced.gd:1027–1054,1372–1421,2160–2168`. |
| Ladder | `on_ladder`, direction, cooldown and expiry, facing/readable aim, floor contact, swim history and sprint eligibility. Area signals initiate entry. Exit constructs and frees a shape cast to resolve a shape-change overlap. `Scripts/ladder_area.gd:7–34`, `CogitoObjects/cogito_player_advanced.gd:1815–1941`. |
| Water | Room-local body overlaps, head shape-cast result, pre-swim crouch, `was_in_swimming_state`, aim-relative direction, gravity coefficient, rise/dive input, water eye offset and exit clearance. Body and head tests have different meanings. `CogitoObjects/cogito_player_advanced.gd:1949–2009,2012–2051,2143–2155`. |
| Ledge | Cast shape/dimensions and initial transform, reach, clear space, surface normal and point, ledge position, collider, middle/final stage and crouch progress. A moving ledge advances its target using the collider's current physics velocity. `CogitoObjects/cogito_player_advanced.gd:127–133,852–959,2055–2124`. |
| Seat, vehicle and external motion | Seat identity, original transform/neck basis, displacement, look marker/limits, moving-seat, ejection and tween flags, collision mask and exit policy. Offline AUTO exit searches navigation with random candidates. Online seat entry/exit has its own synchronous placement and revision. External force can call `move_and_slide()` outside the ordinary movement step. `CogitoObjects/cogito_player_advanced.gd:1454–1498,1528–1572,1575–1688`, `CogitoObjects/cogito_player.gd:251–255`, `Networking/net_seats.gd:24–47,70–100`. |
| Stamina and elements | Sprint entry checks stamina `> 5`, sustained sprint has a low-stamina branch at `0.2`, and jump checks and spends `jump_exhaustion`. Regeneration and run exhaustion currently run in `_process`, using a Timer, floor normal, previous Y and slope/step tuning. Element speed, jump permission, lock and struggle are additional inputs. `CogitoObjects/cogito_player_advanced.gd:962–1008,1302–1304,1331–1338`, `Components/Attributes/cogito_stamina_attribute.gd:4–57,60–88`, `Components/Properties/cogito_actor_elements.gd:98–135`. |
| Presentation and public signals | Wiggle phase/vector/intensity, head-bob option, footstep/swim latches, landing pitch/volume, slide/underwater loops, animation playback and roll completion. Eyes and the animated camera also feed aim and water tests today. Preserve a simulation eye wherever a query needs it. Derive cosmetic motion separately. `CogitoObjects/cogito_player_advanced.gd:196–205,338–340,663–668,1091–1116,1192–1257,1692–1711,1997–2005`. |

Movement tuning, collider dimensions, radius, collision masks, safe margin and cast geometry
belong to the matched prefab or a versioned movement profile. Seed mutable overrides such
as gravity with the owner state. Keep node references, RIDs and scratch query results local
to their physics space. Use room-scoped entity IDs for references that cross the wire.
`CogitoObjects/cogito_player_advanced.gd:68–145,218–229,258–299`, `project.godot:279–288`.

### The chart and its clocks

The prefab runs three parallel branches. `Moving/Grounded` starts in `Idle` and includes
`Walking`, `Sprinting`, `Sliding`, `Sneaking`, `Sitting` and `Rolling`. `Airborne` starts
in `AirControl` and includes `Jumping` and `FreeFall`. `LadderClimb`, `Swim` and
`LedgeClimb` have active, pause and resume/history paths. `BodyPosture` has `Standing`,
`Crouching` and `Sitting`. `PushingObjects` consumes slide collisions independently.
`PackedScenes/cogito_player_advanced.tscn:17974–18047,18062–18175,18207–18243,18279–18301,18333–18423,18823–18878`.

The jump guard reads `not is_sitting and not on_ladder`. The stand-up guard reads
`not is_crouch_shapecast_colliding`. The authored transition delays are zero except
`Moving/Grounded/Sitting → Grounded` at 1.5 s. The separate one-shot sliding and jump
cooldown Timers are 1.5 s and 0.5 s. Ladder entry creates another 0.5 s timer.
There is no general coyote-time or jump-buffer timer in this controller. Jump edges latch
a between-tick tap, and held jump is tested against the cooldown.
`PackedScenes/cogito_player_advanced.tscn:84–88,17867–17885,18000–18005,18143–18147,18392–18397`,
`CogitoObjects/cogito_player_advanced.gd:119–125,752–754,1279–1283,1895–1909`.

State Charts advances pending transition delay in `_process`; physics processing emits
a different signal. Manual `step()` emits `state_stepped`. Calling it repeatedly does
not run the prefab's `state_physics_processing` connections. Roll completion comes from
`animation_finished`, and the dedicated avatar explicitly puts that animation on physics time.
`addons/godot_state_charts/state_chart_state.gd:208–243`, `addons/godot_state_charts/state_chart.gd:304–319`,
`PackedScenes/cogito_player_advanced.tscn:18819–18834`, `CogitoObjects/cogito_player_advanced.gd:249–250,667–668,1692–1711`.

The addon serializer captures active children, history, pending delay, expression values
and event/transition queues. Deserialization thaws the chart and runs queued work.
Advanced's save resource restores transforms, shapes and some velocities and defers element
restoration. These are good parity references. A per-tick checkpoint needs independent
values, an explicit tick boundary and silent restoration.
`addons/godot_state_charts/state_chart_serializer.gd:6–27,38–50,79–95`,
`SceneManagement/cogito_player_advanced_state.gd:40–66,69–105,119–157`.

**Effects execute once.** Replaying the existing callbacks would spend stamina, apply fall
damage or rigid-body impulses, submit NPC footstep noise, play randomized audio, fire chart
signals and start animations, timers or tweens. The controller itself has no movement
`await`; its interaction path reaches code that awaits completion. Replaying input dispatch
could also send a second interaction, throw or inventory action.
`CogitoObjects/cogito_player_advanced.gd:729–754,999–1024,1173–1185,1221–1257,1546–1572,2193–2199`,
`Components/PlayerInteractionComponent.gd:199–201,222–225,240–258`.

### Godot 4.7.2 replay probe

A read-only headless probe used the installed `4.7.2.stable.arch_linux.ed1daf0bf`, Jolt,
a capsule and a static box floor. In engine physics frame 5, at `delta = 1/60`, three
successive `move_and_slide()` calls with velocity `(6, -1, 0)` produced X positions
**0.10000001, 0.20000002 and 0.30000001 m**. All three reported floor contact.
Moving the capsule up 4 m immediately afterwards still returned `is_on_floor() == true`
until the next solve, which returned false. The project selects Jolt at `project.godot:286–288`.

Thus several movement solves can run during one engine physics frame. Moving the actor
back to its saved transform does not restore the previous solve's contacts. Other bodies,
Area overlap notifications, platform motion, animation clocks and Timers have not travelled
back in time. Every replayed tick also pays for its own sweeps, including the stair and
ledge queries when enabled. The probe measured feasibility and contact behaviour.
Full-controller replay CPU cost and LAN input-to-photon timing still need measurement.

## 3. Architecture and release scope

| Option | Benefit | Cost and release consequence |
|---|---|---|
| 1. Roll back the real Advanced controller | One authored controller and chart for every mode. Closest fit for games that extend the chart. | Must capture controller fields, chart history/queues/delays, engine contacts, timer and animation phases, and isolate every external effect. Restoring one actor cannot restore a moving platform. Highest regression risk if all modes must ship together. |
| 2. Shared fixed-tick movement kernel | Authority, live prediction and replay use the same movement rules, explicit state and collision contract. A test can advance a command stream without running a scene frame for each command. | Requires extracting the rules, making contact inputs explicit and handling the handoff to existing modes. Substantial pre-release work, especially stairs, shape changes and stamina. Coverage can expand one tested mode at a time. |
| 3. Predict a few transforms and decay server corrections | Smallest change. Start, jump and eye height can look responsive on a clean LAN. | A correction discards or distorts input entered since the server pose. A rejected jump or turn under loss exposes it. This option does not deliver the requested input replay. |

**Recommendation — option 2 with a bounded 1.4 scope.** Ship real rollback and replay
for grounded walking, stopping, sprinting, sneaking, hold/toggle crouch, static stairs,
ordinary jump/air control/landing, and slide including slide-jump on static geometry.
Run existing authority movement for ladders, swimming, ledge climbs, animation-driven
roll/free-fall consequences, moving supports, dynamic pushes, seats and vehicles.
These remain playable on both topologies. The owner sees server-driven movement during them.

Extract acceleration, posture, step candidates and jump/slide rules into callable code.
Keep offline callbacks, their order, time sources and save format intact. In online
predicted modes, derive `direction` from the current command **before** displacement.
Use the same order on the server. This deliberate online change is necessary for a walk
from settled idle to move on the input tick. Sample eligible jump and crouch before the
solve/eye update for the same reason.

Define the mathematical step over `(previous state, canonical command, fixed dt, contact
observations, authority modifiers)`. It produces next state and a list of effects.
The Godot adapter obtains observations in the actor's room. Split the step into requested
motion, collision queries and final state, so static geometry can be queried again from
a corrected origin. An old hit point from a different origin is invalid.

Use explicit shape sweeps/support probes for the supported static solver on both peers.
Reuse Advanced's step geometry, slope limits, margins and order. Give the solver the
previous contact summary explicitly. This avoids depending on a writable engine floor
cache. Update consumers of grounded state, including interaction-in-air checks and slope
exhaustion, through the online movement adapter. Keep the real authoritative actor at
the committed pose with its appropriate shape so areas, hazards and NPCs observe it.
`CogitoObjects/cogito_player_advanced.gd:504–536,539–660`, `Components/PlayerInteractionComponent.gd:233–237`,
`Components/Attributes/cogito_stamina_attribute.gd:60–76`.

On the client, use a query shape or query-only body in the bound `World3D`. Preserve the
authored query masks before replica spawn clears them. Keep the owner invisible to gameplay
Area monitors and exclude self and the held object's body where appropriate. Publish the
final predicted transform once after replay. Moving a live trigger-visible body through
every historical position could activate plates and pickups.
`PackedScenes/cogito_player_advanced.tscn:17753–17754,17841–17858`,
`Networking/net_avatar.gd:88–101`, `tests/net/net_session_test.gd:491–537`.

Give each authority tick one movement writer. In a supported mode the kernel owns
integration, timers and posture. A live adapter publishes Advanced's public state and
commits effects once. At entry to a legacy mode, transfer transform, momentum, posture,
timers and contact context to Advanced, synchronize the chart and start its callbacks at
the next tick boundary. If detection occurs before any movement, the legacy path may take
that whole tick. On exit, capture a complete supported state. Test both crossing directions
for a missed or doubled displacement. Custom movement rules default to server-driven
until their prefab supplies a matching movement profile.

On the client, encountering an unsupported contact or volume ends speculation at the
boundary. Keep sending input and display authoritative poses until a supported owner
baseline acknowledges the crossing command. The server can independently revoke prediction
on any tick. A versioned mode transition prevents loss of a single pose from stranding
the owner in the wrong movement path.

## 4. Command history, authority state and reconciliation

### Tick and acknowledgement contract

Keep one canonical command per local physics tick. Capture device events and UI actions
once. Apply router suppression, preserve ordered edges and the jump-tap rule, and freeze
the movement portion with the same float32 angles, clamping, mask and edge limit as the
wire codec. Keep the transport's four-frame send history separate from the prediction ring.
Do not retain an alias to mutable `current_command`.
`CogitoObjects/cogito_player_command.gd:100–142`, `Networking/net_command_channel.gd:22–39,60–82`,
`Networking/net_carry.gd:130–150`, `Networking/net_players.gd:600–612`.

Retain the authority's four-packet-per-tick limit, 24-command receive window, two-tick
startup/gap policy and 12-tick stale timeout. A repeated sample reuses held state without
dispatching fresh edges. A null sample releases controls without advancing the ack.
A forward skip makes lower missing commands obsolete. Four copies recover isolated loss;
a burst can erase every copy of a tap.
`Networking/net_input_source.gd:4–22,25–46,56–74`, `CogitoObjects/cogito_player_advanced.gd:697–719`,
`tests/net/net_movement_test.gd:39–62`.

Capture the private state **after simulation at server tick T**. `ack = A` means A is the
last new sequence consumed as of T. The state may already include subsequent held,
neutral or external-force ticks. Send the server tick of the last fresh consumption, the
current sample disposition, and a counter for gap/held/neutral discontinuities. These
allow a client to detect ambiguous alignment even when an intermediate pose was lost.

For example, the server can apply 40, hold 40, then skip missing 41 and apply 42.
A snapshot can have the same ack twice with different positions. On receiving the state
for 42, discard predictions through 42, including 41. Replay pending 43 onward. Never
reconstruct a missing edge from the difference between two ack numbers.

Send the authority physics rate in the spawn baseline. Use the same fixed `dt` on both
peers and enable prediction only for a supported rate/profile. Use `(server tick, ack)`
pairs to measure lead, queue depth and drift. Sequences are logical command numbers,
not synchronized wall clocks. Extend wire uint32 sequences around the expected value
using the existing half-range rule. A client clock, claimed position or client `delta`
has no authority over server time or movement. `Networking/net_input_source.gd:20–37`.

### Owner checkpoint

Include the following in the reliable owner spawn/reset baseline and in each eligible
unreliable owner pose. Reuse fields already present in the public row. Each eligible row
must be independently decodable after packet loss.

| Group | Required data |
|---|---|
| Scope and alignment | Room key/epoch or validated binding, avatar lifetime, pose revision, movement mode generation, tick, ack, last fresh tick, input disposition and gap counter. Include mode/eligibility on fallback rows too. |
| Motion | Level-local origin/basis as applicable, body/neck/head aim at the tick, solver and pre/post-slide velocities including `main_velocity` and `last_velocity`, direction, speed/lerp, gravity override and accumulator. |
| Contacts and posture | Ground/wall/ceiling flags and relevant normals, support classification, step offset/air-step state, moving and posture state, actual enabled shape, clearance, crouch latch, simulation head/eye offset. Stable static geometry and matching shape/profile data may be derived. |
| Mode memory | Jump target, jump/air/sprint/stand/slide history flags, bunny-hop speed, slide direction and remaining slide/jump cooldown ticks. Include any transition phase that can change the next supported tick. |
| Authority modifiers | Effective control block, element speed and jump/posture permissions, stamina presence/value and sufficient phase for the next eligibility decision. For online fixed-tick exhaustion/regen include regen delay/active state, previous Y and effective profile. External costs enter at a server tick. |
| Local history only | Canonical command, predicted post-state, scope/sequence, modifier generation, predicted presentation event IDs and render offset. Cosmetic bob/footstep phase can stay local once collision, aim and water queries have an independent simulation eye. |

Use a round-trip test that starts a fresh stepper from the decoded checkpoint and compares
the following commands with uninterrupted simulation. This catches an omitted latch or timer
even when position happened to match at the checkpoint. Do not serialize the live chart,
client HUD, raw node references, inventory or the player's disk save into pose packets.

### Client algorithm

1. Allocate a **128-tick ring** for the owning network client. At 60 Hz this covers 2.13 s.
   A 150 ms RTT accounts for about nine commands. Allow additional server queue time, up
   to three ticks between snapshots, jitter and several lost poses. Ring capacity and
   permissible work in one physics frame are independent limits.
2. Queue incoming owner frames. Before the next live movement step, select the newest
   valid frame for this room, binding, life and revision. Gate on monotonically increasing
   **server tick**. Reject stale frames before movement or wield reconciliation. Today
   `timeline.push()` returns `false` for both an ordinary accepted frame and an old one,
   while `_receive_pose()` still passes its ack to wield. Make acceptance explicit.
   `Networking/net_snapshot.gd:37–57`, `Networking/net_players.gd:669–683`.
3. Compare the authoritative state with the stored **post-state at A**, provided the
   command-to-tick alignment still matches. Default tolerances are 2 cm position,
   0.10 m/s velocity and 1 cm simulation eye height. Compare other continuous fields
   at codec precision or an explicitly tested epsilon. Compare mode, posture, contacts,
   shape, timers, permission bits and threshold crossings exactly. A new server tick
   with the same ack still requires examination.
4. On an aligned match, retire acknowledged commands and retain the current prediction.
   On mismatch, gap, newer repeated-ack state or modifier discontinuity, restore the
   complete authoritative state at T. Re-run every retained command `> A` in sequence
   at fixed `dt`, once per command. Replace each ring entry's post-state. The restored
   baseline already includes the server's held/neutral ticks. Replay never re-samples
   devices, issues RPCs, advances the live command sequence or calls weapon prediction.
5. Sample the new command once, step it immediately, save its post-state, and send it
   through the ordinary channel. The send policy may discard the datagram after
   encoding. Local movement and its history still advance. Keep current mouse/stick
   aim across ordinary corrections, including mouse motion received since the last sample.
6. Limit one reconciliation to **24 replay ticks** and coalesce superseded snapshots.
   On missing history, an impossible ack, unsupported geometry or a larger backlog,
   install a fresh authority baseline, clear visual error and suspend speculation.
   Keep sending valid inputs. Resume when the baseline and a contiguous pending tail fit
   the budget, or request a fresh scoped baseline if continuity cannot be established.
   Record the reason. Never stretch `dt` or simulate an unbounded backlog.

**Visual correction.** Correct the simulation root before the next live step. Preserve
the prior rendered eye position as an offset from the corrected eye and decay the offset
by `exp(-ln(2) * render_delta / 0.05)`, a 50 ms half-life. Clamp cosmetic displacement
to 0.25 m and shorten it at walls and ceilings. The viewmodel follows the rendered eye.
Gameplay rays, posture clearance, the carry solver and subsequent commands use the
simulation eye. `get_aim_transform()` currently returns the animated camera transform,
so separating these two origins is an implementation requirement.
`CogitoObjects/cogito_player_advanced.gd:196–204,338–340`, `Networking/net_wield.gd:355–375`.

Snap the visual offset to zero for errors over 1 m, forced look/teleport, life/room
change, seat attachment and unsafe camera clearance. A large ordinary correction can
still replay valid pending commands in its own revision. An explicit teleport invalidates
the old revision's commands. Existing replica playback also resets for a displacement
over 4 m, a sitting change or a revision change. `Networking/net_snapshot.gd:37–55`.

**Lifecycle.** Clear owner history, queued poses, provisional effects, contacts and render
offset on removal, disconnect, new binding/epoch, life change and forced revision.
Clear the four-command send history at revision/life boundaries. Preserve the sequence
watermark where the server's in-place actor preserves it. Never relabel old input with the
new revision. Accept the forced aim once and sample fresh input from it.
`Networking/net_input_source.gd:49–53`, `Networking/net_players.gd:446–474,477–514,536–543,693–713`.

## 5. Boundaries with other systems

| System | 1.4 behaviour |
|---|---|
| Weapons | Keep `net_wield.predict()` once per live owner command and `reconcile(ack, accepted_sequence)` on an accepted owner frame. Preserve equip generation and carry's trigger filter. Server aim, hits, ammo and damage stay authoritative. A movement replay emits zero shots, tracers or reloads. `Networking/net_players.gd:600–626,647–650`, `Networking/net_wield.gd:148–190,335–390`. |
| Interactions and inventory | Use the predicted simulation eye for local targeting. Show the existing prompt, input depression or hold progress immediately. The server validates reach/LOS, posture, revision and ownership at its own pose. Door motion, button activation, items and inventory changes occur on confirmation. In particular, exercise a use request that arrives before the corresponding movement on the other channel. `Networking/net_actions.gd:94–114`, `Networking/net_interactions.gd:209–219,250–261,348,490–515`, `docs/networking.md:594–610`. |
| Carry | Predict the walking owner's body where eligible. The **physical held object follows the server's anchor** and its existing body timeline. For 1.4, render that confirmed object even if it briefly trails the predicted camera. Defer a cosmetic grip mesh until playtesting justifies it. Never move the replica collider into the camera, throw on replay or use the rendered offset for a wall clamp. `Components/PlayerInteraction/CarryHandler.gd:26–46`, `Networking/net_carry.gd:57–86,119–150,168–203`. |
| Seats and vehicles | Suspend on confirmed seat, swap, ejection or driver attachment. Preserve immediate limited look and send driver axes. The server sets seat basis, validates occupancy and chooses exit pose. Resume from an unseated supported checkpoint after any delayed chart transition. `Networking/net_seats.gd:24–47,70–100,126`, `PackedScenes/cogito_player_advanced.tscn:18140–18147`. |
| Ladders, swimming, ledges and rolls | Hand off at a ladder/water query, ledge capture or hard landing into roll. Keep sending climb, rise, dive, release and look input. Authority owns the ladder timer, water/oxygen, ledge target and animation completion. Resume at a supported state with fresh contact/posture data. `CogitoObjects/cogito_player_advanced.gd:1692–1711,1788–1795,1895–1941,2030–2051,2087–2124`. |
| Platforms, doors, pushes, NPCs and explosions | Predict against verified stationary geometry. A body marked frozen on a replica may still move on the server. Detect dynamic supports/obstructions, including animated geometry on an otherwise static collision layer, and use the authoritative path. Unknown impulses enter through a corrected state. The server alone moves the other body, damages actors and emits NPC noise. `Networking/net_bodies.gd:51–63,98–139,178–201`, `Networking/net_door_motion.gd:53–85`, `CogitoObjects/cogito_player_advanced.gd:980–988,1221–1226,2193–2199`, `Assets/VFX/Explosion_01/explosion.gd:73`. |
| Elements, stamina and death | Apply confirmed movement permissions and speed to the prediction step. A freeze or takeover can invalidate a predicted jump. Keep the HUD on its private reliable attribute stream. Maintain a movement-only stamina value for replay and commit authoritative changes once. On death stop prediction immediately, clear held actions and reject stale poses. Respawn seeds the new life even when the actor node is reused. `Networking/net_avatar.gd:71–75,101–105`, `Networking/net_attributes.gd:4–45`, `Networking/net_elements.gd:113–141`, `Networking/net_death.gd:83–117,225–267`. |
| Menus and cutscenes | Keep the current InputRouter takeover, neutral commands and held-action release. A local menu suppresses new intent while existing momentum follows movement rules. An authority cutscene block overrides local intent. Closing UI never replays its interaction edge. `docs/input-routing.md:25–33`, `CogitoObjects/cogito_player_advanced.gd:343–354,689–718`, `tests/net/net_session_test.gd:803–836`. |
| Travel | Suspend on transfer or loading. Scope all pending work to the old room until retirement. Seed from the destination spawn after epoch/binding and readiness validation. A failed transfer resumes from a fresh source baseline. Default travel releases the carry grant and can preserve seated posture even without a matching seat in the destination. `Networking/net_travel.gd:217–224,393–449,452–487,592–603`, `Networking/cogito_travel_policy.gd:16–45`. |
| Remote, listen and offline roles | Remote avatars retain 100 ms interpolation and at most 50 ms extrapolation. A listen host simulates its own authority once, with local input and no prediction ring. Dedicated has no local presentation. Offline takes its existing path with zero added nodes, process callbacks or per-tick history allocation. Gate creation on the online role because offline also reports server authority. `Networking/net_avatar.gd:44–59,78–94,113–137`, `Networking/net_snapshot.gd:4–6,65–97`, `Networking/cogito_net.gd:290–316`, `tests/net/net_core_test.gd:8–19`. |

## 6. Rate, bandwidth and protocol

Keep **60 Hz input/physics and 25 Hz pose publication**. Prediction removes the publication
wait from normal owner movement. Increasing to 50 Hz would double pose publication and
reduce the time to discover an error, while leaving replay correctness unresolved.

Append a packed private movement block only to the owner's row in the existing per-peer
batch. Keep the owner weapon acceptance field distinct. Use the same private/public split
on reliable spawn and respawn. Build a private row per recipient without mutating the
shared public pose dictionary. Thus the extra block costs one copy per playing client
per snapshot, regardless of how many avatars that client sees.
`Networking/net_players.gd:446–453,639–652,726–753`.

**Measured serialization example.** In the installed engine, `var_to_bytes()` of a
one-row unseated batch with the current pose fields, a 32-character ID, life and weapon
acceptance used 368 B. Appending a 128, 160 or 192 B `PackedByteArray` produced 504,
536 or 568 B respectively. The incremental 136–200 B corresponds to **3.4–5.0 kB/s**
per owner at 25 Hz in this encoding. The private sizes are design estimates.
The measurement is generic Variant serialization, not a captured SceneMultiplayer or
ENet packet. Measure final RPC bytes, datagram size/fragmentation and replay CPU with
one and several same-room players. The file transport already counts received payload
bytes. `Networking/net_snapshot.gd:14–34`, `tests/net/file_transport.gd:76–86`,
`tests/net/process_arena.gd:187–191`, `docs/networking.md:827–832`.

Bump `NetConfig.PROTOCOL_VERSION` **14 → 15** with the first wire change. Reject mixed
versions at admission, keep the separate content-version check, and document the new owner
row and mode contract. Existing saves require no migration.
`Networking/net_config.gd:5–7,40–46`, `Networking/net_session.gd:94–109`,
`tests/net/net_core_test.gd:58–68`, `docs/networking.md:158`.

## 7. Verification and delivery order

### Automated release gates

- **Same-tick response.** Use a settled owner in its own `World3D`. Stop delivery of new
  poses, inject one forward command from zero, and observe at the end of that exact owner
  physics tick. Require horizontal displacement `> 1 mm`, the expected direction and
  unchanged last received server tick. Repeat for jump with positive Y displacement,
  crouch with a descending simulation eye, and stop with reduced speed. Confirm the
  authority has not yet received the command. A later endpoint comparison cannot pass
  this test accidentally. `tests/net/memory_session_suite.gd:39–60,78–98`,
  `tests/net/net_session_test.gd:174–202`.
- **Restore and replay.** While turning and jumping, displace the server actor sideways
  0.30 m on a known tick without marking a teleport. Separately reject a predicted jump
  with a server lock. Assert the restored baseline, exact list of sequences replayed,
  unchanged live sequence and corrected newest post-state against an independently
  advanced reference. At rest require position error ≤2 cm and velocity error ≤0.10 m/s
  within two successfully delivered poses. For the ordinary push, cap the render offset
  at 0.25 m and require it below 1 cm after 250 ms. Count one live jump/shot/footstep
  where expected and zero replay effects, impulses, spends or RPCs.
- **Loss and clocks.** Retain `drop_every_tenth_command`. Also drop all four copies of an
  edge, duplicate and reorder commands/poses, hold an ack across moving ticks, expire to
  neutral at 12 ticks, skip a sequence, wrap uint32 and exhaust history. Verify a tap is
  accepted at most once, a permanently lost tap is corrected, stale frames cannot cancel
  a newer weapon cue, and no server tick consumes two new commands.
  `tests/net/net_movement_test.gd:19–62,79–106`, `tests/net/memory_peer.gd:49–61`.
- **Impairment.** Add seeded per-direction delivery delay, jitter, loss and duplication
  to the memory peer and file transport. Advance the memory clock once per physics tick,
  independently of `_pump()`'s 12 polls. In the file peer, schedule delivery against a
  receiver-local monotonic clock and preserve channel, mode and reliable ordering.
  Exercise 0/16/100/150 ms RTT as 0/8/50/75 ms each way, then add bounded ±10 ms jitter
  to the WAN profiles. Report actual delivered delay, including tick quantization.
  `tests/net/memory_session_suite.gd:55–60,86–89`, `tests/net/memory_peer.gd:34–69`,
  `tests/net/file_transport.gd:39–85`.
- **Rubber-banding.** On a static straight lane with isolated tenth-packet loss and the
  seeded delay profiles, require zero hard resets after warm-up, no backwards rendered
  steps during sustained forward input, and p95 correction ≤2 cm. Compare moving states
  at matched command/tick boundaries. Compare peers at rest after pending input drains.
  Record maximum error and replay depth as well as percentiles. Test deliberate pushes
  and unrecoverable bursts separately so their expected corrections remain visible.
- **Normal entry points.** Extend the process arena's loss channel, which drops after
  encoding and places a jump tap on the dropped datagram. Add a `prediction` scenario to
  `tools/check_multiplayer.py`. Run dedicated + two clients and listen + one client,
  using ENet and the socket-free file bus. Keep existing checks for final displacement,
  jump peak, observers, private state and one batch per peer. Replace the owner eye-lag
  assertion with a predicted-eye assertion and retain coverage of fallback smoothing.
  `tests/net/process_arena.gd:29–42,55–85,123–145`, `tests/net/process_arena.tscn:262,378–394`,
  `tools/check_multiplayer.py:238–278,718–831,1124–1132`, `tests/net/net_session_test.gd:182–211,282–298`.
- **Offline parity.** Before extraction, capture fixed-input, fixed-delta traces on the
  pinned engine with controlled render stepping, initial state, options and RNG. Compare
  stable movement/shape/eye/transition fields and deterministic save payload bytes against
  that baseline. Count active callbacks and nodes before and after session teardown.
  Cover hold/toggle, roll completion, ladder, water, seats, menus and save restoration.
  `tests/player/player_command_test.gd:84–155,179–209,244–306`,
  `tests/net/offline_physics_test.gd:7–21`, `tests/net/offline_survival_test.gd:27–51`,
  `tests/net/net_core_test.gd:8–19`, `tests/saves/player_restore_test.gd:84–126`.

### Implementation stages

Every row must pass `tools/check.sh` for lint, warnings, gdUnit, demo smoke and multiplayer
before merge. Add file-transport impairment runs alongside the normal ENet gate. Sizes
include tests and are relative engineering estimates. The dependency order is top to bottom.
`tools/check.sh:14–20,49–81`, `docs/dev/multiplayer-plan.md:234–249`.

| Stage | Batches and principal files | Automated acceptance | Manual check |
|---|---|---|---|
| **PR0 — baseline and impairment · M** | `tests/player/player_command_test.gd`, `tests/net/{memory_peer,memory_session_suite,file_transport,process_arena}.gd`, `tools/check_multiplayer.py`. Add phase stamps, repeatable delay schedules and offline golden traces. | Existing endpoint/loss tests pass. An untouched owner stays still until a pose arrives. Report sample, consume, capture, arrival and first render timings separately. | Record the current walk/start/stop and crouch at LAN and 100 ms RTT. |
| **PR1a — offline-neutral extraction · L** | `CogitoObjects/cogito_player_advanced.gd`, `Components/Attributes/cogito_stamina_attribute.gd`, proposed `CogitoObjects/cogito_movement_step.gd`. Extract calculations with explicit inputs and results. Leave offline timing, chart callbacks, node tree and effects on their existing path. | Byte-equal controlled offline traces and saves, matching effect counts and zero extra processing. Existing multiplayer still runs Advanced. | Compare offline stairs, jump arc, head bob, crouch clearance, stamina and roll against PR0. |
| **PR1b — network fixed-tick simulation · XL** | Proposed movement state and room collision adapter, `CogitoObjects/cogito_player_advanced.gd`, `Networking/{net_avatar,net_players}.gd`, grounded-state consumers. Activate the shared step for online authority behind a test switch. Add mode handoff and fixed-tick movement stamina. | Static floor, slope, wall, ceiling and steps reproduce approved movement traces. First-tick forward motion works. Compare legacy handoffs and effects at each boundary. Verify exactly one solver per authority tick. | Listen host and dedicated-controlled actor walk the same route. Check blocked stand-up and stair descent. |
| **PR2 — owner baseline and protocol 15 · M** | `Networking/{net_config,net_snapshot,net_players,net_input_source,net_command_channel}.gd`, `tests/net/{net_core_test,net_movement_test,net_session_test}.gd`. Pack full supported state with tick/ack alignment. | Checkpoint round-trip reproduces subsequent ticks. Spawn and ordinary frames carry private data only to their owner. Old protocol is rejected. Same-ack, stale, skipped and wrapped sequences pass. | Join, late join, disconnect and reconnect with two peers. Check owner and observer views. |
| **PR3 — owner prediction and replay · XL** | Proposed `Networking/net_prediction.gd`, `Networking/{net_avatar,net_players,net_snapshot}.gd`, simulation/render eye adapters and prediction tests. Enable ordinary ground/air movement in the fixture first. | Same-tick displacement from rest with delivery held. Forced push/rejected jump converge. Corrections preserve future input and unsent look. No replay effects, weapon calls or trigger events. | Dedicated LAN walk/stop/turn/jump/crouch. Repeat at 150 ms and inspect a forced correction beside a wall. |
| **PR4 — slide, boundaries and lifecycle · L** | Movement step and `Networking/{net_seats,net_death,net_travel,net_carry,net_wield,net_elements}.gd` integration points. Complete static stairs/slide and authority handoffs. | Slide-jump, fallback entry/exit, stamina gate, freeze, carry throw, driver swap, death, respawn, failed/successful travel and stale old-room frames pass. Remote clocks and host authority pass regression tests. | Complete the GUI checklist below with two players, including an unmatched destination seat. |
| **PR5 — release gate and defaults · M** | `tests/net/process_arena.gd/.tscn`, `tools/check_multiplayer.py`, `docs/networking.md`, `docs/player-controller.md`, `docs/dev/multiplayer-plan.md`. Enable the verified mode set by default. | Both topologies pass the impairment and offline gates. Record payload B/s, correction distribution, replay depth, p95/p99 replay CPU and worst physics frame alongside hardware and scene. | Maintainer signs off at 16 ms and 100–150 ms, including a long walking/turning run. |

### Manual GUI checklist

Run on a dedicated server with an owning client and an observer. Repeat at the measured
LAN RTT near 16 ms and a simulated 100–150 ms RTT. Repeat the role-sensitive cases with
a listen host. Record actual RTT, FPS, mode, correction size and replay depth.

- Walk from complete rest, sprint, release, reverse and turn while strafing. The first
  movement should coincide with input. Look must stay continuous between physics ticks.
- Tap jump between samples, land, sprint-jump, crouch in hold and toggle modes, and try
  standing under a low ceiling. Check eye, collision shape and interaction reach together.
- Walk up and down stairs, slide and slide-jump, then land hard enough to roll. Check the
  camera at each transition and listen for duplicate footsteps, slide or landing sounds.
- Enter and leave a ladder, jump off it, swim up and dive, climb out at a ledge, and step
  onto and off a moving platform. Check the first normal walking step after every handoff.
- Push a body, take an external impulse, carry and rotate a box near a wall, then throw.
  Fire while moving and during a forced correction. Check one throw, one shot and correct ammo.
- Use a door/button at the edge of reach, open inventory, freeze/thaw, sit, drive and stand.
  Watch the observer and verify private effects and server decisions.
- Die and respawn, travel Lobby → Lab → Lobby while holding movement, repeat carrying/seated,
  and reconnect. Check for old motion or aim leaking across spawn, seat and room boundaries.

## 8. Decisions for the maintainer

| Open question | Recommended 1.4 default |
|---|---|
| How much movement must predict before release? | Require ground, static stairs, crouch, sprint, ordinary jump/landing and slide. Keep ladder, water, ledge, roll, dynamic support and vehicles server-driven until each has a reproducible tick and handoff test. If the common-mode replay gate fails, keep the release open rather than count partial smoothing as completion. |
| How much error merits a replay? | Start at 2 cm position, 0.10 m/s velocity and 1 cm eye height. Any gameplay-relevant discrete mismatch corrects immediately. Tune against measured distributions on static geometry. |
| How should corrections look? | Use a 50 ms visual half-life, 0.25 m maximum visual offset, wall/ceiling clipping and a visual snap over 1 m or at lifecycle boundaries. Keep authoritative resets explicit. |
| How much history and CPU? | Keep 128 commands, replay at most 24 on one correction. Start with a p95 replay-work target of 2 ms on the agreed minimum client at 150 ms RTT. Measure stairs separately and publish p99/worst frames before sign-off. |
| Change snapshot rate or remote delay? | Keep 25 Hz, 100 ms remote interpolation and 50 ms maximum extrapolation. Revisit only if measured correction age or observer jitter warrants the extra traffic. |
| Predict the carried object or moving platform? | Keep their physical poses authoritative. Review owner-only cosmetic carry presentation after testing with the existing wall clamp. Platform prediction needs timestamped support motion and stable attachment references. |
| Ship artificial latency in server config? | Put seeded knobs in the test transports and a development-only GUI launch path. Keep production config and save data free of impairment settings. |
| What was verified here? | Source inspection, timing arithmetic, same-frame Godot/Jolt movement and Variant sizes. The GUI, full suite, gameplay equivalence, final wire rate and replay CPU are acceptance work for the implementation PRs. |

# Multiplayer sessions

Daedalion 1.4 MP2 spawns a server-owned Advanced player for each admitted identity and synchronizes interactions with authored world objects. The offline demo still starts from the main menu.

## Try the Laboratory

Run from the project root. On the host machine, open a listen session with a playable first-person view.

```sh
nice -n 19 godot --path . -- --host --port 7777
```

On another machine, join using the host's LAN IP. On the same machine, substitute `127.0.0.1` and give each process its own `XDG_DATA_HOME` to keep identities and saves independent. Walk, turn, jump and crouch. The other window shows the moving mannequin.

```sh
nice -n 19 godot --path . -- --join 192.168.1.10 --port 7777
```

For a dedicated session, start the simulation first and use the same join command from each client.

```sh
nice -n 19 godot --headless --path . -- --server --bind 0.0.0.0 --port 7777
```

For a two-machine test, pass an SSH destination and optional UDP port to the helper. It copies the project with rsync to `~/daedalion`, imports it with the remote `godot`, and runs the dedicated server in the foreground. Use a LAN hostname or IPv4 address your client can resolve. The script prints the local join command. Ctrl-C in the SSH terminal stops the server. Both machines need compatible Godot builds and the host needs the selected UDP port open.

```sh
tools/run_lan_test.sh maintainer@192.168.1.10 7777
```

## Open a session

Connect to `CogitoNet.session_ready` and `CogitoNet.session_failed` **before** opening a session. A listen host or dedicated server can become ready during the opening call. A client becomes ready after the server admits it, its local identity is saved and its initial roster is available.

```gdscript
# Listen host on a LAN interface. Use the host machine's actual address.
var err := CogitoNet.host({
	"bind": "192.168.1.10",
	"port": 7777,
	"max_players": 4,
	"display_name": "Sam",
})
```

```gdscript
# On a different instance of the game
var err := CogitoNet.join("192.168.1.10", 7777, {"display_name": "Alex"})
```

Both calls return an immediate Godot `Error`. A client receiving `OK` can still fail asynchronously during connection or admission. Call `disconnect_session()` to leave or shut down. A lost server or rejected handshake also returns the client to offline mode.

| `mode()` | Authority | Local identity |
| --- | --- | --- |
| `Mode.OFFLINE` | Local | Empty. The singleton uses the engine's offline peer and adds no children, timers or frame callbacks. |
| `Mode.LISTEN_HOST` | Server | One admitted player on peer 1 |
| `Mode.CLIENT` | Remote server | Assigned on admission |
| `Mode.DEDICATED` | Server | Empty, including when clients are present |

Use `is_server()`, `is_online()` and `is_dedicated()` to query these roles. `is_online()` includes a client waiting for admission. `is_server()` is true in offline mode.

`players()` returns copies of admitted records with `player_id: String`, `peer_id: int` and `display_name: String`. `player_for_peer(peer_id)` and `player_for_id(player_id)` return a record or an empty dictionary. `local_player_id()` returns the local ID or an empty string. `local_player()` returns the local network avatar once spawned. Offline, during admission, and on dedicated it returns null. Subscribe to `local_player_changed(actor)` to bind a local view or clear it on removal. A roster entry can exist before its scene has loaded. `CogitoSceneManager.get_player()` continues to resolve the local presentation owner. Use `player_joined(player_id)` and `player_left(player_id)` for roster changes. `peer_rejected(peer_id, reason)` runs on the server and `session_failed(reason)` reports a refusal to the client. Treat display names as labels. Connection IDs can change on every join.

## Dedicated server

From the project root, start a loopback server with a private world directory.

```sh
nice -n 19 godot --headless --path . -- --server --bind 127.0.0.1 --port 7777 --max-players 8 --save-dir user://net/server
```

The dedicated CLI loads the Laboratory by default. Supply `--level res://path/to/level.tscn` to select another local scene. A successful boot writes `NET READY port=7777` to stdout. Invalid configuration or a bind failure exits with a nonzero status. A normal build recognizes `--server` after `--`. An export with the `dedicated_server` feature selects the same role automatically. You can also select the scene explicitly.

```sh
nice -n 19 godot --headless --path . res://addons/cogito/Networking/dedicated_server.tscn -- --server --config server.cfg
```

Use a Godot ConfigFile with a `[server]` section. CLI options override file settings in any order. Programmatic hosts and `start_server(config)` take the same keys in a dictionary.

```ini
[server]
bind="127.0.0.1"
port=7777
max_players=8
save_dir="user://net/server"
content_version="my-game-1.0"
```

| Key | Default and meaning | CLI override |
| --- | --- | --- |
| `bind` | `127.0.0.1`. Supply a local interface IP for LAN access, or `*` for all interfaces. | `--bind` |
| `port` | UDP 7777, valid range 1–65535. | `--port` |
| `max_players` | ENet supports up to 4095 remote connections. Omitting the limit requests that ceiling. A listen host counts its local player, allowing up to 4096 total. | `--max-players` |
| `save_dir` | `user://net/server`. Give each server its own writable directory. | `--save-dir` |
| `content_version` | The `version` string from `addons/cogito/plugin.cfg`. Include the plugin config in an export or supply a game release or content hash. Set the same value in client join credentials. | Config file |
| `level` | Path to the local PackedScene loaded by the dedicated bootstrap. Clients must load the matching level. | `--level` |
| `display_name` | `Host` for the listen player. Clients supply their own name in join credentials, default `Player`. | Config file |

The protocol version is a networking-code constant. Both protocol and content must match. Direct internet connections require the selected UDP port to reach the server. ENet support in MP0 covers native direct-address connections and LAN.

The dedicated level starts empty and simulates admitted remote avatars. Their first-person cameras, HUDs and light-meter cameras are omitted. The default demo boot prevents the menu subtree from entering the tree. Dedicated startup skips solo save recovery and cleanup, the fade panel, game options, graphics and input-map setup by Cogito's menu autoload. The engine still loads project resources, Cogito settings and the existing autoload nodes, including InputHelper, DebugLine, InputRouter, audio and quest services. Full export stripping is scheduled for MP11.

## Identity and recovery

Each normalized address and port has its own profile in `user://net/identity.cfg`. The ConfigFile section name is the SHA-256 hex digest of the lowercase, trimmed address followed by a slash and the decimal port, for example `127.0.0.1/7777`. The listen host uses a separate profile keyed by its server save directory. Using a different hostname or port creates a different profile. All processes running a game should have exclusive use of their client data directory.

On first admission the client generates a random 96-byte secret. The server sends a fresh 32-byte nonce. The client returns an HMAC-SHA256 proof and, for enrollment only, a SHA-256 verifier. HMAC normalizes a key this long to its SHA-256 digest, allowing the server to check the proof with the stored verifier. The server issues a random 128-bit ID and persists the verifier in `<save_dir>/identities.cfg`. On reconnect the client presents its ID and answers a new challenge using only the proof. A second live connection claiming the same ID receives a rejection. An unknown ID starts a new enrollment with a fresh secret.

Keep the verifier registry private. A verifier is sufficient to produce proofs, and native ENet sends registration traffic without encryption. The default provider is intended for trusted networks. Back up both stores to retain identities. With the game stopped, removing the client profile (or the entire client file) starts a new identity on the next join. Removing the server registry resets every binding in that server directory. There is no account-recovery flow in MP0.

A game can assign a subclass of `addons/cogito/Networking/net_identity.gd` to `CogitoNet.identity_provider` before opening a session. Override `open_server`, `load_client`, `is_known`, `respond`, `authenticate` and `save_client` to implement enrollment, proof and persistence. Join credentials are available to `load_client`. Only the claimed ID, versions, response and display name travel over the control endpoint. A custom provider should put only wire-safe values in its response. The server always applies the capacity and single-login checks.

For a transport extension, assign a zero-argument `Callable` to `CogitoNet.transport_factory`. It returns an `enet_transport.gd` subclass implementing `open_server(config, listen)` and `open_client(address, port)` and exposing its resulting `MultiplayerPeer` through `peer`. The built-in adapter uses ENet. Session RPCs use reliable channel 0 at `/root/CogitoNet/Session`.

## Player lifecycle and movement

A `CogitoScene` opened online takes the transform of its authored `Player` before its children enter the tree. A running level can also open a session. A custom scene can call `CogitoNet.player_world.bind_level(root, start, key)` with its local root, a level-local start transform and a matching string key on every peer. One root is active on each peer. The server spawns all admitted players there, including the listen host. The default advances along the start's X axis in 1.5 m steps until it clears existing players. Games can choose another transform with `CogitoNet.spawn_policy`.

```gdscript
func choose_spawn(level: Node3D, player_id: String, start: Transform3D) -> Transform3D:
	var marker := level.get_node_or_null("Starts/" + player_id) as Node3D
	if marker:
		return level.global_transform.affine_inverse() * marker.global_transform
	return start

func open_session() -> Error:
	CogitoNet.spawn_policy = choose_spawn
	return CogitoNet.host({"port": 7777})
```

Reliable spawn RPCs use the stable session endpoint `Session/Players`. A client announces its level key after both admission and level setup. The server sends a new observer the **current** poses of existing players. This handshake lets slow loaders receive the same baseline as other observers. Spawn names derive from the durable identity. Commands and poses carry a server-issued incarnation number, so late packets from a departed avatar cannot affect its replacement. Roster removal releases held actions, carry and seat ownership and removes the avatar. Reconnect starts at a fresh spawn.

| Role | Movement and view |
| --- | --- |
| Listen host's own avatar | Local input drives the authoritative Advanced chart. Its camera and HUD belong to the host. |
| Client's own avatar | Local input drives immediate mouse/stick look and sends one command packet each physics tick. Translation follows authoritative positions with exponential smoothing. |
| Another player on a client | Snapshot playback updates the mannequin, including body yaw, head pitch and crouch height. The locomotion chart and device sampling are inactive. |
| Client-owned avatar on either server | A per-avatar network source supplies commands to the same Advanced physics controller used offline. |

The project uses 60 physics ticks per second by default. Commands use unreliable ordered channel 1. A packet contains the last four MP1a frames with byte lengths. Only movement actions go on the wire. The receiver checks lengths, action IDs and finite values, normalizes the move vector, wraps yaw and clamps pitch. It resolves the avatar from the RPC sender. Each controller consumes at most one new sequence per physics tick. The receive queue holds up to 24 frames, starts with a two-tick jitter window, skips unrecovered gaps, and expires to neutral after 12 ticks without a fresh frame. The packet budget is four per avatar per server tick. Wire sequences are uint32 and extend to the nearest sequence around the next expected tick using signed modular distance. This assumes consecutive accepted sequences differ by less than half the number space. ENet's adaptive packet throttle is disabled on every connection (`throttle_configure(5000, PACKET_THROTTLE_SCALE, 0)`): under RTT jitter it silently discards runs of unreliable sends on the sender side, longer than the four-frame redundancy can recover.

`CogitoNet.snapshot_hz` defaults to 25. After physics the server sends one batch on unreliable channel 1 per ready peer per snapshot tick. The batch contains the poses of every avatar sharing that observer’s `CogitoLevel` root. Each pose includes server tick, input acknowledgement, position, velocity, yaw, neck yaw, pitch, head height and posture/moving/seat state. The owner keeps local aim during ordinary updates. Remote playback uses a 100 ms buffer and extrapolates velocity for at most 50 ms. A position discontinuity over 4 m clears the history. After forcing a server teleport, look or in-place respawn, call `CogitoNet.player_world.mark_teleport(player_id)`. The next pose revision resets local look and invalidates buffered input from before the change. A new incarnation starts with empty history.

Use `CogitoNet.player_world.avatar_for(player_id)` to look up a live binding. Its `actor` is the Advanced node. On a replica, `timeline.latest()` exposes the last received pose including `tick` and `ack`. On the server, `actor.last_consumed_sequence` records the last applied command.

## World interactions

Listen hosts and dedicated servers validate interactions with doors, including keyed locks,
buttons, switches, keypads, spinners, turnwheels and lockpicks. Pressure plates and cutscene
zones detect occupants on the server. Readable, keypad and device interfaces belong to one viewer. Another player can continue moving or
interacting while a panel is open. Inventory changes, including consumption of a disposable
key, take place in the acting avatar’s server inventory. A remote player’s inventory UI does
not yet reflect those changes.

### Addresses and requests

Binding a level indexes its objects by `(level_key, CogitoPersistentId.of(object))`. The level
key must match on all peers. Authored scene paths relative to the level already provide
persistent ids. An explicitly restored id takes precedence. A duplicate id produces an
error and excludes every object with that id. The component key is the authored path from the
object to its interaction component. Renaming an object or component changes its default wire
address and requires matching content on all peers. Network lookups use the registration
tables built at bind time.

`CogitoInteractionAction.action_id` defaults to the component’s input action, with `interact`
as the fallback for an empty binding. Pass a fifth constructor argument for a component with
multiple actions. The shipped dual component uses `press` and `hold`. A keypad has an
additional `submit_code` action. Prompt text can change or be translated independently.

The local interaction ray drives the HUD. The existing input and context-menu entry points
send the chosen action to `Session/Players/Interactions` on reliable channel 2. A request
contains `level_key`, `epoch`, `request_id`, `entity_id`, `component_key`, `action_id`,
`expected_revision` and a phase. The only optional field is a schema-checked payload. The
requester can select a registered action. Its actor, the callable, inventory changes and the
resulting world state are all determined on the server.

1. The server binds the transport sender to its admitted avatar. The listen host enters the
   same path directly as peer 1. All RPCs use `call_remote`.
2. The server checks the active level, epoch and object revision. It raycasts from the server
   avatar’s eye toward the configured target or collider, excluding the actor. Reach is the
   actor’s interaction-ray length plus 0.25 m. Carry, posture, air and interface restrictions,
   enabled actions and attribute thresholds are checked against that actor.
3. Hold start and release are distinct requests. Release validates the target again and uses
   server elapsed time. A short dual press selects the quick action. A short plain hold or a
   cancellation spends nothing. Losing the target or the local input context cancels the hold.
4. The server checks key ownership and code validity before committing. An ordinary open on a
   keyed lock can unlock and open it in the same request. Only the acting inventory spends a
   disposable key. Each changed object publishes its own revision, including linked doors
   and switches used as lamps. A wrong code leaves both keypad and linked doors unchanged.
5. A per-connection, per-level result cache remembers accepted and rejected monotonic request
   ids. Retrying an id returns its original result. A competing request with an old revision
   is rejected as `Stale revision`. Retry a newly selected action against the refreshed state.
   Only the requester receives the result, HUD hint text and icon, or instruction to open a
   readable/keypad. Replayed replies do not repeat private presentation.

The result retains the precise rejection reason for logs and tests. The HUD displays authored
hint keys or short gameplay messages. Protocol errors map to `Unavailable`. Stale revisions,
old requests, short holds and an immediate repeat of a just-accepted action are silent.

### Continuous devices and private views

Protocol version 4 adds `Session/Players/Interactions/Devices` on reliable channel 2.
Enter through the object's usual MP2 request, with its authored component key, reach, LOS,
posture, attribute and revision checks. The server grants one ongoing device per actor.
A second user of the same spinner, wheel or lock receives `In use`. Each private input
contains the level key and epoch, server-issued session token, operation and one integer. The
receiver resolves ownership from the sender. Reopening a device invalidates its old token.
Device requests keep their parent object's entity id and authored component path. The
spinner and lockpick components each publish a separate state row under their own persistent
id. This lets a lockpick share a door with its ordinary key interaction.

Leaving the level, losing the avatar, death or moving out of interaction range releases
the device. Dismissing a private view also releases input and restores its owner's HUD.

- **Spinner.** The owner's mouse or stick drives the existing virtual ring. Whole steps
  accumulate locally. The server accepts one signed batch of up to four steps per physics
  tick and calls the authored `spin_step` for each. It alone evaluates limits, rise,
  overrotation and directional/goal signals. A replica interpolates the clamped value and
  resulting pose from `value` and `pose`. Each live goal crossing plays its sound once. Destruction at the goal
  sets `removed` for silent late joins.
- **Turnwheel.** Press starts an exclusive MP2a hold. The server rotates the wheel from its
  starting pose at the authored speed, capped at `hold_time`. Release after the minimum
  server-observed interval commits once and passes the instigator to each supported linked
  object. A short release, cancellation or lost target restores the starting pose. Live
  observers interpolate rotation and loop the hold sound between start and stop. Baselines
  snap silently to `rotation` and `turned`, including for an observer arriving mid-turn.
- **Lockpick.** The authority checks the acting inventory and initializes the sweet spot,
  tolerance, pick health and skill adjustment from the authored minigame. The owner positions
  the pick with the mouse or stick and applies tension with the usual right input. The two
  input edges are `press` with an angle in tenths of a degree (−900 through 900), and
  `relax` with zero. Physics time, angle error and the authored damage rates determine
  keyhole travel, breakage and success. Only keyhole movement, jam/break feedback and the
  remaining count reach the picker. A break removes one item from one server stack. A new
  pick requires a fresh press. Success unlocks the registered `doors_to_unlock` and emits
  `lockpick_success` on the server. The public lockpick state contains only `disabled`.
  The inventory screen awaits MP3 replication.
- **Cutscene.** An authoritative area entry consumes the once flag at start. The entering
  avatar's peer plays the authored camera animation and owns the input context. The server
  consumes that avatar's movement sequences as neutral for the clip duration. The owning
  peer may cancel when `allow_cancel` is enabled. With `allow_repeat` another entry may
  start a new viewing. A baseline contains only `triggered`. Author camera and local
  visual tracks for cutscenes. A track that animates a shared object plays only in the
  viewer's scene. Drive shared gameplay through an authoritative object adapter, especially
  on a listen host where the viewer and server share a scene.

### State, baselines and author extensions

The server assigns an epoch at level bind. Live state, events and private results carry the
level key and epoch. At level-ready the server sends the current states and revisions on
reliable channel 3 in chunks of up to 32 objects. A client load nonce identifies the matching
baseline, even when reloading the same key. An acknowledgement releases queued live changes
on channel 2. Each live record carries a state update and a separate presentation event id.
A replica applies the state first, then plays that event once for its revision. A late join
only applies state. The collision body of a door snaps to the target on baseline and follows
the server-selected motion locally on live updates. Server collision controls passage.

Start with a working offline interactable. Its collider belongs to the `interactable` group
and exposes the interaction components used by the local ray and HUD. Give its object root
a stable level-relative placement or a persistent id, then implement the following contract.

| Member | Contract |
| --- | --- |
| `signal net_changed(event: StringName)` | Emit synchronously on the authority after each committed change, including timer, sensor or linked-object changes. |
| `net_state() -> Dictionary` | Return a fresh, compact dictionary of wire-safe state sufficient to reconstruct pose, collision and visible state. |
| `apply_net_state(state: Dictionary, silent: bool)` | Assign replica fields and visuals without invoking gameplay signals or calling linked objects. With `silent` true, install the final pose immediately. |
| `present_net_event(event: StringName)` | Optional one-shot sound or animation for a live change. Handle listen-host presentation in the authority’s local transition. |
| `net_bind_authority()`, `net_bind_replica()`, `net_unbind()` | Optional hooks to install or release role-specific simulation and presentation. |

On a custom interaction component, return stable choices from `get_actions(actor)` and
implement `net_commit(action_id, actor, payload)` to opt in. The actor argument is the
server-resolved `PlayerInteractionComponent`. Keep eligibility queries side-effect free.
`attribute_passes(actor)` checks the threshold without applying effects or sending hints.
Commit the state and emit `net_changed` before yielding. Capture the explicit actor for any
delayed linked operation and check that it is still live before using it.

Override `net_payload_schema(action_id) -> StringName` to reserve input for a particular
action. The default accepts no payload. The built-in `digits` schema accepts 1–16 ASCII digits
as a string, preserving leading zeroes. For a custom numeric panel, return `&"digits"` for
its submission action, validate the submitted value in game logic, and only then change the
object. Extending the wire schema requires a matching change to the server validator.
`actor.send_hint(icon, text)` addresses the acting peer. Offline controllers continue to call
`interact(actor)` and `perform_action(action)` directly.

## Current limitations

- MP2 synchronizes players and the listed authored objects in one active level. Translation includes network latency. Client prediction, rollback, independent travel and reconnect state restoration are future stages.
- Inventory and currency transactions, pickups, weapon use and vendors await MP3. Carrying and seats await MP4. Unsupported interactions stay inert online. Direct server grants of authored items can be used to exercise keyed doors.
- NPCs, damage, death, movable props, quests, runtime spawns and network saves still need subsystem replication. A linked custom object needs its own state adapter to appear on observers. Use level-authored motion/visual tracks for replica animations. Method, nested-animation and audio tracks on door/switch replica players are removed at bind.
- The sender repeats four frames. A burst that loses every copy of an edge can still lose the action. Artificial loss in the process test covers individual packet loss. LAN feel under jitter and mannequin animation need a visual playtest.

## Verification

```sh
GODOT_BIN=/usr/bin/godot NICE='nice -n 19' bash tools/check.sh multiplayer
```

The loopback ENet harness runs a dedicated server with two clients, then a listen host with one client. Separate temporary user directories preserve the MP0 identity, rejection, disconnect and restart checks. In a small arena it also checks stationary avatars, forward and turning distances, observation by the opposite peer, the late-join pose and removal. Clients drop every tenth command datagram after encoding its redundant history. A jump tap lands on a dropped datagram and the server and observer must see the jump height. The interaction checks also exercise a closed and open collision doorway, duplicate requests, rejection at distance, a button-linked door, wrong/right keypad codes a turnwheel-linked door, a lockpick-locked door and movement by another player during an owner-only cutscene. A third client verifies a silent baseline. In the listen topology the host opens the first door and the client opens the linked door. Each topology has a 45 s deadline.

The regular gdUnit run includes the socket-free codec, jitter, wrap, interpolation, level interest, role, actor-lifecycle, entity identity, validation, concurrent commits, private interfaces, plate and baseline tests in `tests/net/`.

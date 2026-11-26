# Multiplayer sessions

Daedalion 1.4 MP6 gives each admitted identity a server-owned Advanced player and private inventory. The server simulates world interactions, pickups, shared containers, vendor transactions and equipped items. It also simulates rigid bodies, grants exclusive carry and seat ownership and drives vehicles from their occupant’s movement commands. Hitscan, melee and ballistic impacts resolve in the shooter’s server world. The server owns survival meters, damage, death and individual respawns. It also owns NPC perception, combat, loot and draggable corpses. Offline death uses the existing save-slot reload screen.

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
friendly_fire=true
respawn_delay=10.0
```

| Key | Default and meaning | CLI override |
| --- | --- | --- |
| `bind` | `127.0.0.1`. Supply a local interface IP for LAN access, or `*` for all interfaces. | `--bind` |
| `port` | UDP 7777, valid range 1–65535. | `--port` |
| `max_players` | ENet supports up to 4095 remote connections. Omitting the limit requests that ceiling. A listen host counts its local player, allowing up to 4096 total. | `--max-players` |
| `save_dir` | `user://net/server`. Give each server its own writable directory. | `--save-dir` |
| `content_version` | The `version` string from `addons/cogito/plugin.cfg`. Include the plugin config in an export or supply a game release or content hash. Set the same value in client join credentials. | Config file |
| `level` | Path to the local PackedScene loaded by the dedicated bootstrap. Clients must load the matching level. | `--level` |
| `friendly_fire` | Boolean, default `true`. Allow one player to damage another. | `--friendly-fire false` or `--friendly-fire true` |
| `respawn_delay` | Finite, nonnegative seconds, default `10.0`. Zero enables immediate requests. | `--respawn-delay 1.5` |
| `display_name` | `Host` for the listen player. Clients supply their own name in join credentials, default `Player`. | Config file |

The protocol version is 10. Both protocol and content must match. Direct internet connections require the selected UDP port to reach the server. ENet support in MP0 covers native direct-address connections and LAN.

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

Reliable spawn RPCs use the stable session endpoint `Session/Players`. A client announces its level key after both admission and level setup. The server sends a new observer the **current** poses of existing players. This handshake lets slow loaders receive the same baseline as other observers. Spawn names derive from the durable identity. Commands and poses carry a server-issued incarnation number, so late packets from a departed avatar cannot affect its replacement. Roster removal releases held actions, carry and seat ownership and removes the avatar. Reconnect creates a new avatar at the normal join spawn and restores its private attributes. A dead identity remains dead with its existing server deadline.

| Role | Movement and view |
| --- | --- |
| Listen host's own avatar | Local input drives the authoritative Advanced chart. Its camera and HUD belong to the host. |
| Client's own avatar | Local input drives immediate mouse/stick look and sends one command packet each physics tick. Translation follows authoritative positions with exponential smoothing. |
| Another player on a client | Snapshot playback updates the mannequin, including body yaw, head pitch and crouch height. The locomotion chart and device sampling are inactive. |
| Client-owned avatar on either server | A per-avatar network source supplies commands to the same Advanced physics controller used offline. |

The project uses 60 physics ticks per second by default. Commands use unreliable ordered channel 1. A packet contains the last four MP1a frames with byte lengths. Protocol 6 includes movement, primary, secondary, reload and change-ammo actions. Each frame ends with the owner’s last observed equip generation (uint32). The receiver checks lengths, action IDs and finite values, normalizes the move vector, wraps yaw and clamps pitch for movement. A combat frame with yaw or neck yaw outside ±π, or pitch outside ±π/2, invalidates the packet. It resolves the avatar from the RPC sender. Each controller consumes at most one new sequence per physics tick. The receive queue holds up to 24 frames, starts with a two-tick jitter window, skips unrecovered gaps, and expires to neutral after 12 ticks without a fresh frame. The packet budget is four per avatar per server tick. Wire sequences are uint32 and extend to the nearest sequence around the next expected tick using signed modular distance. This assumes consecutive accepted sequences differ by less than half the number space. ENet's adaptive packet throttle is disabled on every connection (`throttle_configure(5000, PACKET_THROTTLE_SCALE, 0)`): under RTT jitter it silently discards runs of unreliable sends on the sender side, longer than the four-frame redundancy can recover. Both transport hosts also announce unlimited bandwidth explicitly (`host.bandwidth_limit(0, 0)` right after creation); without it Godot 4.7's ENet can cut a peer's throttle limit to 1/32 for whole one-second bandwidth intervals with the same effect (`tests/net/enet_transport_test.gd`).

`CogitoNet.snapshot_hz` defaults to 25. After physics the server sends one batch on unreliable channel 1 per ready peer per snapshot tick. The batch contains the poses of every avatar sharing that observer’s `CogitoLevel` root. Each pose includes server tick, input acknowledgement, position, velocity, yaw, neck yaw, pitch, head height and posture/moving/seat state. The owner keeps local aim during ordinary updates. Remote playback uses a 100 ms buffer and extrapolates velocity for at most 50 ms. A position discontinuity over 4 m clears the history. After forcing a server teleport or look, call `CogitoNet.player_world.mark_teleport(player_id)`. The next pose revision resets local look and invalidates buffered input from before the change. A new incarnation starts with empty history.

Use `CogitoNet.player_world.avatar_for(player_id)` to look up a live binding. Its `actor` is the Advanced node. On a replica, `timeline.latest()` exposes the last received pose including `tick` and `ack`. On the server, `actor.last_consumed_sequence` records the last applied command.

## World interactions

Listen hosts and dedicated servers validate interactions with doors, including keyed locks,
buttons, switches, keypads, spinners, turnwheels and lockpicks. Pressure plates and cutscene
zones detect occupants on the server. Readable, keypad and device interfaces belong to one viewer. Another player can continue moving or
interacting while a panel is open. Inventory changes, including consumption of a disposable
key, take place in the acting avatar’s server inventory. The owner’s HUD and inventory receive the resulting private update.

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
`expected_revision`, avatar `life` and a phase. The only optional field is a schema-checked payload. The
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
  Losing a pick also updates the owner’s inventory and quickslots.
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

## Inventories and shared items

Protocol 5 adds `Session/Players/Inventory` and `Session/Players/Containers` on reliable
channel 2. Once the client acknowledges the level baseline and has its local avatar, it
receives a private inventory baseline. The listen player uses the authoritative resource
directly. An inventory revision covers grid size, cells, wallet and quickslot assignments.
The server assigns each stack an integer id scoped to its inventory. Moving it preserves the
id. Splitting it creates a new id. Replica rows carry an item definition, origin cell,
quantity, rotation and, for wieldables, charge and ammo selection. All occupied cells and
bound quickslots point at the same local stack. An empty delta row removes a stack.

The existing inventory panel, HUD, quickslot bar and wheel read this model. Dragging keeps
a local preview until the player chooses a destination. A custom interface can use
`CogitoNet.player_world.inventory.make_request(op, args)` and `dispatch(request)`, or
`submit(op, args)`. Subscribe to `result_received(result)` for the private outcome. Each
request carries exactly `request_id`, `life` (avatar incarnation), `revision`, `op` and
`args`. The server resolves the actor from the sender and validates the current model.
Arguments below are nonnegative integers bounded by the actual grid, stack or bar.
`source` is a cell in the source inventory, `id` is its observed stack id, and `rotated`
is 0 or 1. The first cell and quickslot both have index 0.

| Operation | Positional args | Effect |
| --- | --- | --- |
| `move` | source, id, destination, quantity, rotated | Move, swap, split or merge if both footprints and the quantity fit. |
| `combine` | source, id, target cell | Consume one of each ingredient and insert the authored recipe result. |
| `drop` | source, id, quantity | Create the authored pickup in front of the server avatar and debit its stack. |
| `use` | source, id | Invoke the item with the server actor. Selecting a wieldable equips its stack, switches to it, or puts it away if already equipped. |
| `ammo` | source, id, ammo index | Select the authored pistol ammo type, equip that stack and start reloading after a change. |
| `bind` / `unbind` | source, id, quickslot / quickslot | Assign or clear the owner's binding. |
| `put`, `take`, `external_move` | source, id, destination, quantity, rotated, token, container revision | Move to, from or within the granted container. |
| `take_all`, `close` | token, container revision | Take fitting quantities or release the grant. |

Retries with the same positive id return the cached outcome. The server remembers the
last 64 results per connection and rejects older requests. A rejected mutation sends the
owner a fresh baseline and refreshes any granted container. The public world baseline
contains neither player inventories nor container contents.

**Item use.** The server calls `use(actor)` with the resolved player and returns changed
attribute current/maximum pairs to that owner. HUD displays receive `attribute_restored`.
Consumables, keys, ammo hints, currency items and combine recipes use their authored
behavior. Holding the use action over a wieldable can pick it up and equip it. Holding over compatible ammo can transfer units into reserve and start a timed reload if they fit.

**Pickups and loot.** A press goes through MP2 reach, sight and revision checks. Extended
pickups offer `press` and `hold`. The authority also processes its avatar's auto-pickup
area. An inventory can accept part of a stack. The remaining world quantity reaches all
level observers. An exhausted authored pickup leaves a removal record for late joiners.
Runtime drops use a server-minted `runtime:<number>` id. The spawn record identifies an
item definition whose authored `drop_scene` supplies the prefab, or a registered level
loot component whose `loot_bag_scene` supplies the bag. Player commands carry only slot
and quantity information. Pickups use the shared MP4 body stream. Movement preserves the pickup's
interaction revision so a falling item remains eligible for a request. Grabbing and releasing the
item advance its revision. Loot tables, bag timers
and respawns run on the authority even with an empty roster.

**Containers and vendors.** An MP2 open grants that player a container token. Several
players can hold grants to the same box. A transfer checks the token, reach and both
revisions before editing the two inventories. Each viewer receives changes to the box.
Take-all sends capacity hints to the actor. The vending machine's ordinary button buys one
unit of the product in its authored pickup scene. Its `sell` action accepts the same product
at the button's authored unit cost. Stock is public. The buyer's item and wallet are private.
`CurrencyCheck.transaction_success(purchaser)` identifies the player who completed the
transaction, including on ordinary paid buttons.

**Reconnect.** The active server retains inventories, currencies and quickslot bindings by
durable player id. An identity receives its starter items on its first spawn in that server
run. Rejoin restores the profile and creates a new incarnation, request cache and view grant.

### Authoring items and containers

Save each inventory item definition as an authored `InventoryItemPD` resource with an icon
and ship it on every peer. Set its stack size and grid footprint. To make it droppable, set
`drop_scene` to a pickup scene with a `PickupComponent` holding its authored slot. Give
custom use logic a synchronous `use(actor) -> bool` method. Return success after committing
the effect and use the supplied actor for attributes, currency and hints. Mutable custom
fields beyond the built-in stack row need an extension to the stock codec. Put initial
player stacks in the game's starter list.

Derive a container from `CogitoContainer`, supply its inventory dimensions and cells,
and attach a `BasicInteraction` to its collider as in the shipped container scene. Set
`starter_contents` or use a lootable container with an authored loot table. Supply a stable
entity id if the authored path can change. A custom interface can read the active stock
and token from `CogitoNet.player_world.containers` after the private open.

## Wieldables

Selecting an inventory cell, quickslot or wheel entry sends the same revision-checked
`use(source, stack_id)` transaction. The private inventory baseline and deltas include
`equipped` (zero for empty hands), `generation` and `reloading`. Use
`inventory.local.equipped_stack()` for the owner stack. The existing stack row carries
magazine charge and ammo type. Moving the stack preserves the selection. Removing or
transferring it cancels reload and clears the selection. Reconnecting retains charges and
reserve ammo. A living player rejoins with empty hands. A dead player retains the equipped
stack for the next respawn.

`player_world.avatar_for(id).wield` exposes `public_item` (definition resource path),
`light_on` and `aiming`. The server sends these fields with the initial avatar spawn and
on changes over reliable channel 0. The mannequin uses a head-mounted spotlight for the
flashlight. It has no hand prop or third-person weapon animation. The owner's view uses the
authored first-person model and visual animation tracks.

**Input and timing.** The 60 Hz movement command carries the trigger held state and ordered
action edges with the same yaw, pitch, sequence and redundant history as movement.
This supports the automatic rifle without per-shot reliable requests. The server resolves
the sender's avatar and equip generation. A delayed trigger from a previous selection cannot
fire the next item. The server uses the rifle's authored firing delay, the pistol and melee
action clip durations and the flashlight toggle interval. Reload runs for the authored
reload clip duration. At completion the server counts matching reserve stacks, debits
units according to their `reload_amount` and fills the magazine up to `charge_max`.
Change-ammo cycles to an available authored type and starts a reload. The quickslot submenu can select the exact type. Unloading requires space for the rounds already in the magazine. UI takeover sends
neutral commands. Server view grants, death, blocked input, element locks, carrying and
sitting also guard use. The flashlight drains its own stack on server physics ticks. Its
continuous charge changes share the inventory’s 5 Hz scan.

**Hits and consumables.** The laser and pickaxe raycast from the authoritative Advanced
eye along its forward axis, excluding the shooter and using the item's range and damage.
The pickaxe also checks the wielder's stamina. A hit emits the target's existing
`damage_received(amount, shooter, direction, point)` signal. A player target uses its
existing attribute damage entry point. Hitbox listeners receive the shooter as instigator.
MP2-adapted objects such as shootable switches publish their ordinary state changes.
A drink applies its authored consumable effects to the wielder at the end of the server
equip delay and spends one unit. Player attribute changes use the owner’s MP5 meter stream and silent HUD refresh.

**Projectiles.** The toy pistol launches the equipped definition's selected projectile.
A throwable uses its authored override or its drop scene. Each launch gets a fresh
session serial, independent of node identity and the offline pistol pool. The server
integrates gravity and sweeps the flight segment every physics tick. First contact ends
that flight before damage or pickup creation. Foam rounds and soft darts deal physical
damage to soft targets. A projectile without material properties, such as the stone round,
also damages hard targets. Cold/poison buildup and elemental damage use the target's element
API. Burning and wet darts apply the authored contact reactions on the server. A recoverable
dart or foam round becomes one MP3a runtime pickup with a separate id and normal pickup
validation. An expired flight simply despawns.

Ready observers receive reliable epoch-scoped launch and end records on channel 2.
Launch carries the serial, shooter/incarnation, item definition, ammo index, position,
velocity and gravity. Observers render a mesh-only flight with no collision or damage
callbacks. Baselines include currently flying projectiles at their current positions.
Completed shots and impacts have no baseline record.

**Feedback.** Trigger and reload input can immediately play local sound, muzzle flash
and viewmodel animation. Aim adjusts the owner's field of view. The owner pose carries
an acknowledgement used to stop rejected cosmetic playback silently. Accepted fire,
reload and confirmed impact events reach level observers once. A hitscan weapon with an
authored ray scene (the laser rifle's `laser_ray_prefab`) draws it like offline: the owner
predicts it from the viewmodel muzzle to its own camera hit and drops it with a rejected
shot; observers draw it from the server's fire event, which carries the trace end. The owner receives the
confirmed impact position and normal for the authored impact effect and decal. Game
presentation code can subscribe to `player_world.combat.presented(actor, event, point)`,
`player_world.projectiles.launched(id, visual)` and `ended(id, impact)`. The dedicated server keeps only simulation data and passes a null visual.

**Authoring.** Give the inventory item an external `WieldableItemPD` definition. Its
`wieldable_scene` can use or extend one of the six shipped wieldable scripts. Configure
damage, range, charges, ammo types and animation names as for offline play. The network
profile reads those exported settings from a detached instance. Keep viewmodel animation
tracks visual. Use a `CogitoProjectile` scene with mesh geometry for a launch, and a
pickup scene with a `PickupComponent` for recovery. To add a different behavior, extend
`net_wield_profile.gd` and the authority action in `net_wield.gd`. Add a recipient-side
effect only if the existing visual events are insufficient. Game-specific destructibles
can publish their result with the MP2 state adapter contract above.

## Rigid bodies, carry and seats

Protocol 7 adds the level-scoped `Session/Players/Bodies` stream. Both server topologies
run Godot physics at the project physics rate. The Advanced avatar's slide contacts apply
the ordinary push impulse. Buoyancy, impact damage, hearing stimuli and authored carry
callbacks run on the server. Client rigid bodies are frozen in kinematic mode with contact
reporting and their physics callbacks disabled. Their shapes and layers remain available
to local rays. The owning player collides with simulated bodies during server movement
and displays the resulting translation on the client. There is no client movement prediction.

| Body and observer | Delivery |
| --- | --- |
| Awake within 24 m of any avatar, or driven vehicle | Up to 20 Hz to interested peers |
| Other awake body | Up to 5 Hz |
| Observer farther than 96 m or in another level | No motion traffic to that peer. Server physics continues. |
| First observation or return to interest | Reliable current pose at the next body tick after level acknowledgement, applied immediately |
| Sleep or freeze | One reliable final pose, followed by silence until movement, wake or interest re-entry |

Each ready observer receives at most one body batch per 20 Hz tick. A batch shares a level,
epoch and physics tick. Its rows contain a registered id, transform, linear and angular
velocity and playback flags. Ordinary motion uses unreliable channel 1. A batch containing
an interest baseline or final rest pose uses reliable channel 2, ordered with runtime
spawns. The entry tick distinguishes a new observation even if motion overtakes the baseline.
Playback interpolates position and orientation 100 ms behind the server clock and extrapolates
for at most 50 ms. The same playback draws the owner's carried body. An authored
`ImpactSounds` collision sends a one-shot to ready listeners in body interest. Joining or
returning to interest installs the pose silently.

**Carrying and dragging.** The grab uses the existing MP2 component action, attribute check,
reach and line of sight. The server grants one body to one actor. The reliable world row
exposes its durable player id through `player_world.world.holders.get(body_id, "")`.
A private grant token binds drop, throw and rotation input to the sending connection.
The server computes the carry point from the avatar's eye, command aim, authored carry
marker and body size. A server ray clamps that point to walls, including for a headless
avatar. Secondary plus mouse or right stick rotates a manually rotatable body. The owner
accumulates one vector per physics tick. The server accepts one finite vector of length
at most 48 per tick and uses the authored rotation speed. Throw uses the server mass,
force limits, stamina threshold and stamina drain. Break distance, avatar death, seat
entry, level departure and disconnect release the grant. The owner's grab binding drops
the body. Its own pickup action still works while carried.

**Seats and vehicles.** A seat's ordinary MP2 interaction enters, swaps or exits. An auto
seat uses its server area overlap. Manual area restrictions are checked for each actor.
The seat row contains `occupant`, the durable player id or an empty string. The avatar
snapshot carries the seat id and its seated basis. The server attaches the actor to the
sit marker and the mannequin uses the prefab's sitting animation. Owner look is immediate.
The server clamps the composed body and neck yaw and head pitch to the authored seat limits.
The occupant can exit using the seat binding. In network sessions `AUTO` exit uses the
authored leave marker, falling back to the original position if there is no marker.

A vehicle has one driver. It consumes that occupant's validated movement vector from the
ordinary command stream. Old command revisions are discarded at seat transitions and
out-of-range driver axes reject the packet. Forward/back controls acceleration and
left/right controls turning. A separate passenger sittable can follow the same vehicle
as a child. Releasing the driver seat clears its drive input and momentum.

**Snap slots.** The server's snap area matches the expected scene or its nonempty authored
object name, releases the entering body's carrier and freezes it at `SnapPosition`. The
slot's MP2 row carries `occupied` and `object` (body id). A second overlap cannot claim
the occupied slot. Grabbing or destroying the snapped body releases its slot. Restoring a
slot baseline updates its marker and prompt without playing a placement sound.

**Authoring.** Place a `RigidBody3D` under the bound level, with matching content and a
unique authored path or persistent id on each peer. The level registry indexes plain
bodies as well as `CogitoObject` and `FloatableBody3D`. The spawn service registers runtime
pickup bodies automatically. A custom spawn service must first create the matching object
on each peer and register the same server-issued id with `world.entities.register_runtime`.
Attach a direct `CogitoCarryableComponent` child to the interactable rigid body to allow
grabs. An authored `CogitoBodyDrag` on a rigid body uses this same contract. For a seat,
use `CogitoSittable` with its `BasicInteraction`, sit marker, look marker and optional area
and exit marker. For driving, use `CogitoVehicle` and point `vehicle_node` at the
level-local vehicle body. The vehicle itself is the default network target. A custom
gameplay callback outside the body's physics loop must check its branch authority.

**Bandwidth.** Motion traffic grows with the number of awake bodies inside each observer's
interest radius. Sleep eliminates repeated rows. Reliable interest entry and world baselines
add bursts. The process harness prints received RPC payload bytes per second per file-bus
client during the physics scenario, including player snapshots, world events and inventory.
These measurements exclude ENet, IP and link headers.

## Attributes, damage and respawn

On dedicated and listen servers, the authoritative avatar advances all its attributes, including sprint and jump costs, regeneration, underwater oxygen, suffocation and sanity. Each hazard and attribute zone tracks its own occupants, delay and hint counters. Leaving a zone removes that player from that zone. Water checks the individual avatar’s head. Online, authored light zones drive the HUD light meter on both server types, so the same level works headless. They affect NPC sight only when the player prefab has its own visibility attribute, as offline. The offline light meter keeps its camera sampling.

| Recipient | Reliable channel 0 payload |
| --- | --- |
| Owner | Every attribute’s exact current and maximum on spawn, join and respawn. Changes send sparse pairs, normally at most once per 100 ms per attribute. Attributed health hits, a cumulative health loss of at least one point, and death bypass the cap. Only the dead owner receives the remaining delay. |
| Same-level observer | Public `health_fraction` (0–1) and `dead` on spawn, health changes and life transitions. Read `player_world.avatar_for(id).health_fraction` and `.actor.is_dead`. |
| Other levels | No avatar vitals. Server-side simulation continues independently of observers. |

To add a meter, attach a direct `CogitoAttribute` child to the player prefab on every peer and give it a unique `attribute_name`. Its current/max pair joins the owner stream automatically, including when `dont_save_current_value` is enabled. Put gameplay ticks in the component’s processing callbacks. Replicas freeze these callbacks and ordinary mutations. `apply_replica_value(current, maximum)` installs authoritative values and emits only `attribute_restored`. Bind custom HUDs to that notification as well as the normal local `attribute_changed` signal.

Player damage enters through `victim.decrease_attribute(name, amount, source)`. Pass the shooter, melee wielder, projectile instigator or attributed body as the source. The server resolves the durable attacker ID and calls `player_world.death.can_damage(attacker_player_id, victim_player_id, source)`. The default allows self-damage and environment/NPC damage (empty attacker ID). With `friendly_fire=false`, another player’s hits, including impacts from a carried or thrown body, leave the victim’s attributes intact. A dead avatar ignores further damage. Games can assign a team-aware `CogitoNet.damage_policy` callable with the same signature before opening the session.

At zero health the server marks the current incarnation dead once, releases its interaction, carry, seat and driver grants, clears held input and holsters the weapon. The mannequin’s rig tips onto its side. Movement, interaction and combat are rejected while dead. Only the owner sees the death screen and countdown. Esc opens their pause menu, the mouse is released and other players and the server clock continue. The default policy retains inventory, wallet, quickslots, selected equipment and quest state. A weapon holstered to carry a body is re-equipped after respawn.

The button sends a reliable request containing only the owner’s observed incarnation. The server resolves the sender, checks death and the monotonic deadline, and selects a spawn. Success assigns a new incarnation and pose revision, discards the old command and interpolation history, sends a private baseline, closes the death screen and restores gameplay input. An early, duplicate or stale request cannot change state. A reconnect to the same server process retains the original deadline. A stored zero-health profile without a deadline is immediately eligible. Both paths restore the death presentation silently, without charging a second penalty.

### Authoring respawns

Place `CogitoRespawnPoint` markers in the level. Each has an `enabled` switch and a free-form `tag: StringName`. Only enabled markers in the avatar’s own level instance are candidates. In node-path order the default policy picks the first point at least one metre from every other avatar. If all points are occupied it picks the greatest clearance, breaking ties by path. With no candidates it uses the same spawn selection as a joining player.

Configure game hooks alongside `CogitoNet.spawn_policy` before calling `host`, `start_server` or `join`.

```gdscript
CogitoNet.respawn_policy = preload("res://game/clinic_respawn.tres")
CogitoNet.death_screen_scene = preload("res://ui/player_death.tscn")
CogitoNet.damage_policy = team_rules.can_damage
```

Subclass `CogitoRespawnPolicy` for server rules. Override `select(player_id, level, candidates)` to return a level-local transform, `on_death(player_id)` to apply a penalty once, and `restore_attributes(avatar)` to change recovery. The default restores health, oxygen, stamina and sanity to their maxima. Override `auto_respawn(player_id)` to return true for automatic respawn after the configured delay. The same deadline and life checks apply.

The optional death screen is a `Control` instantiated under the local HUD. Implement `open_online(actor, remaining_seconds, request: Callable)` and `close_online()`. The first method presents the countdown, takes local mouse/input ownership and calls `request.call()` on button activation. The second releases that ownership. The built-in screen also supports Main Menu and Quit. The server exposes private rejection signals on `player_world.death` for custom feedback.

## NPCs, perception and combat

The level server runs each authored `CogitoNPC` even when nobody can see it. Its navigation agent, behaviour chart, detectors, attack timers, hitbox, panic movement and death logic have one authority. A client binds the same actor as a collision-free presentation node. Its chart stays frozen, its proximity areas and avoidance are disabled, and its animation tree consumes replicated posture and velocity. Offline levels use the authored chart, detectors, damage, ragdoll and save format.

### Perception and target policy

Each physics tick the server evaluates the admitted, live avatars in the NPC’s level. Each player has an independent cone/LOS test, visibility, sight and hearing suspicion, decay timers, distance and last-known point. A wall in front of one player leaves every other player’s ray independent. Sight compares the player's visibility attribute with `minimum_visibility` on the same raw scale as offline `SightDetection`. A player prefab without a visibility attribute is always fully visible, as offline. The meter the server adds in place of a rendered light meter only drives the HUD light meter and does not hide players from NPCs. Footstep and landing stimuli come from the server movement clock. They work with the footstep audio node removed. Thrown-object impacts can carry the responsible player’s identity.

The default `CogitoNpcTargetPolicy` considers visible candidates with positive suspicion. It adds normalized sight suspicion and one quarter of normalized hearing suspicion, then gives the current candidate a configurable `hysteresis` bonus (default 0.15). Equal scores favour the closer player, then the lexicographically smaller stable player ID. A lost target leaves its last-known point for the search. Death, departure, despawn and input-blocking cutscenes remove the candidate. A new avatar incarnation starts with fresh suspicion.

Set `CogitoNPC.target_policy` on an individual NPC, or assign a shared default before opening the session.

```gdscript
CogitoNet.npc_target_policy = preload("res://game/security_targeting.tres")
```

Derive the resource from `CogitoNpcTargetPolicy`. Override `eligible(npc, actor)` for game-specific exclusions. Override `choose(npc, candidates, current)` to return a player ID or an empty string. Candidate rows are keyed by ID and expose `actor`, `sight`, `hearing`, `visibility`, `visible`, `score`, `distance` and `last_known`. Treat them as read-only. A policy can direct investigation to a heard candidate’s last-known point. Firing requires a visible, eligible target in the same incarnation.

### Replication and authoring

| Data | Delivery |
| --- | --- |
| Position, orientation and locomotion velocity | Shared MP4 motion batches within 96 m. Moving NPCs send at up to 20 Hz when a player is within 24 m, otherwise 5 Hz. Replicas use the 100 ms interpolation buffer and up to 50 ms extrapolation. Entry and final rest poses are reliable. An idle pose drops out of subsequent batches. |
| Behaviour, target ID, walk/run, upper-body posture, equipped mesh visibility, melee phase, health fraction and death | The MP2 join baseline includes nearby actors and deaths. Reliable, change-driven interest updates carry the current MP2 revision at up to 20 Hz. An in-progress melee swing includes its age. Joining and returning to interest install state silently. |
| Sight/hearing indicators and combat music | Reliable per-listener updates carry quantized suspicion and a music request. Each client and the listen host resolve requests from their own NPC sources. Leaving interest clears that source. The dedicated server has no listener. |
| Barks, shot, hit and death effects | MP3 combat events go to current observers in range. A hitscan fire event supplies muzzle and impact points for the flash, sound and tracer. Ballistic weapons use the server projectile sweep. An authored bark identifies the processor’s sound property in the shared scene. These one-shot events are absent from baselines. |

Player hits use the server hitbox, including knockback and hit reactions. NPC attacks enter MP5 with an empty attacker player ID. Disabling friendly fire leaves NPC damage enabled. On death the authority publishes the dead actor, runs its death signal once, and spawns the configured pickup or loot component output through the runtime spawner.

For the template mannequin, the server instantiates one draggable rigid torso with a prone, skinned mannequin and its authored hip grip. MP4 replicates the rigid transform, velocities and final sleeping pose. A bounded payload per awake corpse keeps bandwidth independent of the skeleton’s bone count. The prone limbs stay fixed relative to the torso. An observer joining during or after a drag resolves the corpse’s runtime ID and current pose through the existing body lifecycle. Games requiring articulated corpse physics need a matching bone representation on each peer.

For a custom behaviour, add the server-side state processor and a chart transition from each state that can enter it. Extend `CogitoNPC.net_state()` and `apply_net_state(fields, silent)`, preserving the base fields and calling the base apply method. Store durable animation parameters in those fields, including any phase needed for joining midway. Replica apply must only install presentation values. Send transient cosmetics with `player_world.combat.npc_event(npc, event, point)` on the server and handle custom events on `npc_presented`. Keep damage, item spawns and navigation in server callbacks. NPC state and event payloads must be understood by both content builds.

## Current limitations

- One active level is supported. Translation includes network latency. Prediction, rollback and coordinated travel remain future work.
- There is no lag compensation. The server tests targets where they are when the command is consumed. A moving target may have left the crosshair by then. Ballistic replicas can briefly overshoot until the authoritative impact arrives.
- Recovered projectiles become independent rigid pickups. Attachment to moving hit targets and procedural debris need their own lifecycle. Online corpses use the single-torso approximation described above.
- Living NPCs are bound from the shared level scene. A game that creates new living NPCs at runtime needs an archetype and spawn adapter. Authored mannequin corpses and loot already have runtime records.
- Custom breakage without an MP2 state adapter remains server-local. Element spread and persistent elemental visuals need MP7. Quest inventory flags retain their offline evaluation until MP8 defines a network quest subject.
- Inventories, attribute profiles and respawn deadlines are retained for one server process. MP9 covers saving world objects and player profiles to disk. The offline save format is unchanged.
- A linked custom object needs its own state adapter to appear on observers. Use level-authored motion/visual tracks for replica animations. Method, nested-animation and audio tracks on door/switch replica players are removed at bind.
- The sender repeats four frames. A burst that loses every copy of an edge can still lose the action. Artificial loss in the process test covers individual packet loss. LAN feel under jitter and mannequin animation need a visual playtest.

## Verification

```sh
GODOT_BIN=/usr/bin/godot NICE='nice -n 19' bash tools/check.sh multiplayer
```

The loopback ENet harness runs a dedicated server with two clients, then a listen host with one client. Separate temporary user directories preserve the MP0 identity, rejection, disconnect and restart checks. In a small arena it also checks stationary avatars, forward and turning distances, observation by the opposite peer, the late-join pose and removal. Clients drop every tenth command datagram after encoding its redundant history. A jump tap lands on a dropped datagram and the server and observer must see the jump height. The interaction checks also exercise a closed and open collision doorway, duplicate requests, rejection at distance, a button-linked door, wrong/right keypad codes a turnwheel-linked door, a lockpick-locked door and movement by another player during an owner-only cutscene. A third client verifies a silent baseline. In the listen topology the host opens the first door and the client opens the linked door. The same scenarios race an authored pickup, move a runtime drop between players, trade through a shared container and purchase from a vendor. The dedicated scenario also reopens the container on a late joiner and checks inventory after reconnect. The combat fixture checks bounded automatic shots against hitboxes, owner-private magazines, observed fire, projectile impact and recovery, light state and a silent late join. In the listen topology both players shoot the opposite player’s target. The MP4 scenario races the same box, carries it through the open doorway, throws it and checks the final position within 3.5 cm on both peers. It contests and releases a seat, drives a chair and snaps the box for a late joiner. Listen mode repeats the carry in both directions. MP5 adds overlapping hazards, rifle kills, owner-only countdown and Esc, early request rejection, retained inventory and snap-to-marker respawn. A late client checks the surviving player’s public health and the respawned player’s pose. Listen players also kill and respawn each other. A separate friendly-fire-off run fires the rifle at another player and checks health. Each scenario has a 103 s deadline. Select `--scenario dedicated`, `--scenario listen` or `--scenario friendly_fire_off` with `python tools/check_multiplayer.py`. Use `--survival-only` to run the MP5 stages independently. Add `--file-transport` to exercise the same RPCs in separate processes with a local file queue.

The additional `npc_dedicated` and `npc_listen` scenarios stage the arena guard, patrol and occluder. They check listener-specific detection, target loss and reacquisition, fire count against MP5 health, a single death and loot drop, corpse agreement within 4 cm, and a server-authorized drag. Dedicated also checks a silent late join. The harness prints received file-transport payload bytes per second, including other game traffic. The playing clients measure from the split through corpse settlement. The late client measures from its restored baseline through the first observed drag. For a visual Laboratory check, split up near its two authored NPCs, break sight, compare indicators and music, then kill the armed guard and drag the corpse from each peer.

The regular gdUnit run includes the socket-free codec, jitter, wrap, interpolation, level interest, role, actor-lifecycle, entity identity, validation, concurrent commits, private interfaces, plate and baseline tests in `tests/net/`.

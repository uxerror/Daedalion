extends Node
## Reliable level-ready baseline and spawn endpoint. Roster removal is the reliable despawn.
## Using the session path lets slow loaders receive their baseline after their level exists.

## The local controller has its initial pose, or has been removed.
signal local_changed(actor: CogitoPlayer)

const COMBAT := preload("net_combat_events.gd")
const PROJECTILES := preload("net_projectiles.gd")
const PROFILE := preload("net_wield_profile.gd")
const INVENTORY := preload("net_inventory.gd")
const CONTAINERS := preload("net_containers.gd")
const SPAWNER := preload("net_spawner.gd")
const INTERACTIONS := preload("net_interactions.gd")
const WORLD := preload("net_world_state.gd")
const SESSION := preload("net_session.gd")
const AVATAR := preload("net_avatar.gd")
const CHANNEL := preload("net_command_channel.gd")
const SNAPSHOT := preload("net_snapshot.gd")

## Optional game spawn transform selector, supplied by the facade.
var spawn_policy: Callable
## Number of snapshot broadcasts per second.
var snapshot_hz := 25
## Sender-side packet policy. A custom channel can drop or delay packets for transport tests.
var command_channel := CHANNEL.new()
## Local network controller once ready. Dedicated sessions leave this empty.
var local_actor: CogitoPlayerAdvanced
## Replicated object registry and state for this online branch.
var world := WORLD.new()
## Reliable gameplay requests and private results for this session.
var interactions := INTERACTIONS.new()
## Private player inventories, viewer grants and level-local runtime objects.
var inventory := INVENTORY.new()
var containers := CONTAINERS.new()
var spawner := SPAWNER.new()
## Motion stream shared by authored and runtime bodies.
var bodies := preload("net_bodies.gd").new()
## Owner-scoped carry input and release.
var carry := preload("net_carry.gd").new()
## Authoritative seat and driver claims.
var seats := preload("net_seats.gd").new()
var combat := COMBAT.new()
var projectiles := PROJECTILES.new()
var _profiles := {}
var _bindings := {}
var _session: SESSION
var _prefab: PackedScene
var _level: Node
var _owns_root := false
var _level_key: String
var _start: Transform3D
var _avatars: Dictionary[String, AVATAR] = {}
var _ready_levels: Dictionary[int, String] = {}
var _peer_by_id: Dictionary[String, int] = {}
var _serial := 0
var _tick := 0
var _elapsed := 0.0


func _ready() -> void:
	combat.name = "Combat"
	add_child(combat)
	projectiles.name = "Projectiles"
	add_child(projectiles)
	inventory.name = "Inventory"
	add_child(inventory)
	containers.name = "Containers"
	add_child(containers)
	carry.name = "Carry"
	add_child(carry)
	bodies.name = "Bodies"
	add_child(bodies)
	spawner.name = "Spawner"
	add_child(spawner)
	world.name = "World"
	add_child(world)
	interactions.name = "Interactions"
	interactions.world = world
	add_child(interactions)
	_session = get_parent()
	process_physics_priority = 100
	_session.joined.connect(_joined)
	_session.left.connect(_remove)
	_session.ready_for_play.connect(_announce_level)


## The level currently accepting spawns on this session branch.
func active_level() -> Node:
	return _level


## Binds the scene selected by the game on this branch, in level-local coordinates.
func bind_level(root: Node, start: Transform3D, key: String) -> void:
	if is_queued_for_deletion() or not is_inside_tree() or not root.is_inside_tree():
		return
	if _level == root:
		return
	assert(not is_instance_valid(_level))
	_level = root
	_level_key = key
	_start = start
	set_process(not multiplayer.is_server())
	_owns_root = CogitoLevel.mark_network_root(root)
	root.set_meta(&"cogito_net_players", self)
	spawner.bind(root)
	world.bind(root, key)
	for id in world.entities.objects:
		var node := world.entities.objects[id]
		if node is RigidBody3D:
			bodies.track(id, node)
		if node is CogitoVehicle:
			var target: Node3D = node.vehicle_node if node.vehicle_node else node
			if not target is RigidBody3D and CogitoLevel.root_of(target) == root:
				bodies.track(CogitoPersistentId.of(target), target)
	spawner.track_authored()
	root.tree_exiting.connect(_level_exiting, CONNECT_ONE_SHOT)
	if multiplayer.is_server():
		for record in _session.records():
			_joined(record.player_id)
	else:
		_announce_level()


func _exit_tree() -> void:
	if is_instance_valid(_level):
		_level.tree_exiting.disconnect(_level_exiting)
		_level_exiting()


func _level_exiting() -> void:
	if multiplayer.has_multiplayer_peer() and 1 in multiplayer.get_peers():
		_level_left.rpc_id(1, _level_key, world.binding())
	projectiles.clear()
	clear()
	interactions.clear()
	bodies.clear()
	world.clear()
	_bindings.clear()
	if _owns_root:
		CogitoLevel.unmark_network_root(_level)
		_owns_root = false
	_level.remove_meta(&"cogito_net_players")
	_level = null
	_ready_levels.clear()


func _announce_level() -> void:
	if (
		is_instance_valid(_level)
		and not _session.local_id.is_empty()
		and not multiplayer.is_server()
	):
		_level_ready.rpc_id(1, _level_key, world.binding())


@rpc("any_peer", "call_remote", "reliable", 0)
func _level_left(key: String, nonce: int) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if multiplayer.is_server() and _bindings.get(peer) == nonce and _ready_levels.get(peer) == key:
		_release_subscription(peer)


func _release_subscription(peer: int) -> void:
	_ready_levels.erase(peer)
	carry.release(peer, false)
	var avatar := avatar_for(_session.for_peer(peer).get("player_id", ""))
	if avatar:
		seats.release(avatar.actor)
	interactions.forget(peer)
	containers.forget(peer)
	world.forget(peer)
	bodies.forget(peer)


@rpc("any_peer", "call_remote", "reliable", 0)
func _level_ready(key: String, nonce: int) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if not multiplayer.is_server() or _session.for_peer(peer).is_empty() or key.length() > 512:
		return
	if nonce <= int(_bindings.get(peer, 0)):
		return
	_peer_by_id[_session.for_peer(peer).player_id] = peer
	if _bindings.has(peer):
		_release_subscription(peer)
	_bindings[peer] = nonce
	_ready_levels[peer] = key
	for id in _avatars:
		if _visible(peer, id):
			_send_spawn(peer, id)

	_subscribe(peer)


func _subscribe(peer: int) -> void:
	var id: String = _session.for_peer(peer).get("player_id", "")
	if _avatars.has(id) and _visible(peer, id):
		world.subscribe(peer, _bindings[peer])


## True for the listen player or an admitted observer bound to this live root.
func peer_in_level(peer: int) -> bool:
	var id: String = _session.for_peer(peer).get("player_id", "")
	var avatar := avatar_for(id)
	if not avatar or CogitoLevel.root_of(avatar.actor) != _level:
		return false
	return peer == 1 or _ready_levels.get(peer) == _level_key


func _visible(peer: int, id: String) -> bool:
	if peer == 1 or _ready_levels.get(peer) != _level_key:
		return false
	var viewer := _session.for_peer(peer)
	if viewer.is_empty() or not _avatars.has(viewer.player_id):
		return false
	var viewer_root := CogitoLevel.root_of(_avatars[viewer.player_id].actor)
	return viewer_root == CogitoLevel.root_of(_avatars[id].actor)


func _joined(id: String) -> void:
	if not multiplayer.is_server() or not is_instance_valid(_level) or _avatars.has(id):
		return
	_serial += 1
	var slot := 0
	var start := _start
	if spawn_policy.is_valid():
		start = spawn_policy.call(_level, id, _start)
	else:
		while not _clear_position(start.origin):
			slot += 1
			start.origin = _start.origin + _start.basis.x * (1.5 * slot)
	_create(id, _serial, start)
	for peer: int in _ready_levels:
		if _visible(peer, id):
			_send_spawn(peer, id)
		# A level can finish loading after several of its clients have signalled ready.
		if peer == _peer_by_id[id]:
			_subscribe(peer)
			for other in _avatars:
				if other != id and _visible(peer, other):
					_send_spawn(peer, other)


func _clear_position(point: Vector3) -> bool:
	for avatar in _avatars.values():
		if avatar.actor.position.distance_squared_to(point) < 1.4 * 1.4:
			return false
	return true


func _create(id: String, life: int, start: Transform3D, initial_pose: Dictionary = {}) -> void:
	var avatar := AVATAR.new()
	avatar.lifetime = life
	_avatars[id] = avatar
	_peer_by_id[id] = _session.for_id(id).peer_id
	var local := id == _session.local_id
	if not _prefab:
		_prefab = load(AVATAR.PREFAB)
	avatar.spawn(_prefab, _level, id, start, local, multiplayer.is_server())
	avatar.actor.player_interaction_component.network_interactions = interactions
	avatar.wield.actor = avatar.actor
	avatar.wield.players = self
	avatar.wield.player_id = id
	avatar.wield.life = life
	avatar.wield.owner_peer = _peer_by_id[id]
	avatar.actor.set_meta(&"net_wield", avatar.wield)
	inventory.attach(avatar.actor, id, _peer_by_id[id], life)
	if not initial_pose.is_empty():
		avatar.receive(initial_pose)
	if local:
		command_channel.clear()
		local_actor = avatar.actor
		local_changed.emit(local_actor)
		world.acknowledge_local_avatar()


func _send_spawn(peer: int, id: String) -> void:
	var avatar := _avatars[id]
	var frame := SNAPSHOT.capture(avatar.actor, _tick, avatar.revision)
	var wield := avatar.wield
	frame.wield = [wield.public_item, wield.light_on, wield.aiming]
	_spawn.rpc_id(peer, _level_key, id, avatar.lifetime, frame)


@rpc("authority", "call_remote", "reliable", 0)
func _spawn(key: String, id: String, life: int, frame: Dictionary) -> void:
	if not is_instance_valid(_level) or _level_key != key or _session.for_id(id).is_empty():
		return
	if _avatars.has(id):
		return
	_create(id, life, Transform3D(Basis.IDENTITY, frame.position), frame)
	_wield_state(id, life, frame.wield[0], frame.wield[1], frame.wield[2])


func _remove(id: String) -> void:
	var peer := int(_peer_by_id.get(id, 0))
	carry.release(peer, false)
	if multiplayer.is_server() and _avatars.has(id):
		seats.release(_avatars[id].actor)
	bodies.forget(peer)
	world.forget(peer)
	interactions.forget(peer)
	_bindings.erase(peer)
	_ready_levels.erase(peer)
	_peer_by_id.erase(id)
	if not _avatars.has(id):
		return
	var avatar := _avatars[id]
	_avatars.erase(id)
	var local := avatar.actor == local_actor
	if local:
		interactions.close_view(avatar.actor.player_interaction_component)
		if avatar.actor.player_hud.is_inventory_visible():
			avatar.actor.player_hud.set_inventory_visibility(false)
	containers.forget(peer)
	avatar.wield.clear()
	inventory.detach(peer, avatar.actor)
	avatar.despawn()
	if local:
		local_actor = null
		local_changed.emit(null)


## Removes session actors while their controller and level are still valid.
func clear() -> void:
	for id: String in _avatars.keys():
		_remove(id)


## Look up one live incarnation, including a replica's latest acknowledged input sequence.
func avatar_for(id: String) -> AVATAR:
	return _avatars.get(id)


## Resolve a live server-side body to its admitted connection.
func peer_for_actor(actor: CogitoPlayer) -> int:
	for id in _avatars:
		if _avatars[id].actor == actor:
			return _peer_by_id[id]
	return 0


## Increment after a server-forced look, seat change, teleport or respawn in place.
func mark_teleport(id: String) -> void:
	if multiplayer.is_server() and _avatars.has(id):
		var avatar := _avatars[id]
		avatar.revision += 1
		if avatar.source:
			avatar.source.clear()


## Load an authored simulation profile once per definition per session.
func wield_profile(path: String) -> PROFILE:
	if not _profiles.has(path):
		var profile := PROFILE.new()
		profile.configure(load(path) as WieldableItemPD)
		_profiles[path] = profile
	return _profiles[path]


## Admitted remote peers that have installed this level's event baseline.
func observers() -> Array[int]:
	var peers: Array[int] = []
	for peer: int in _ready_levels:
		if peer_in_level(peer) and world.ready_for_events(peer):
			peers.append(peer)
	return peers


## Equip state shares ordered channel 0 with avatar spawns.
func publish_wield(id: String) -> void:
	var avatar := avatar_for(id)
	if not avatar:
		return
	var w := avatar.wield
	for peer: int in _ready_levels:
		if _visible(peer, id):
			_wield_state.rpc_id(peer, id, avatar.lifetime, w.public_item, w.light_on, w.aiming)


@rpc("authority", "call_remote", "reliable", 0)
func _wield_state(id: String, life: int, path: String, on: bool, ads: bool) -> void:
	var avatar := avatar_for(id)
	if avatar and avatar.lifetime == life:
		avatar.wield.apply_public(path, on, ads)


func _physics_process(delta: float) -> void:
	if _avatars.is_empty():
		return
	carry.flush_rotation()
	if local_actor:
		carry.filter_trigger(local_actor.current_command)
	if local_actor and inventory.local:
		var own := _avatars[_session.local_id].wield
		local_actor.current_command.wield_generation = inventory.local.snapshot.get("generation", 0)
		own.predict(local_actor.current_command, delta)
	if not multiplayer.is_server():
		if local_actor and local_actor.last_consumed_sequence >= 0:
			var packet := command_channel.packet(local_actor.current_command)
			if not packet.is_empty():
				var avatar := _avatars[_session.local_id]
				_commands.rpc_id(1, avatar.lifetime, avatar.revision, packet)
		return
	for avatar in _avatars.values():
		if avatar.actor.is_dead:
			seats.release(avatar.actor)
		if local_actor:
			avatar.present_seat(avatar.actor.is_sitting)
		avatar.wield.tick(delta)
		if local_actor and avatar.actor == local_actor:
			avatar.wield.reconcile(
				local_actor.last_consumed_sequence, avatar.wield.accepted_sequence
			)
	var positions := {}
	for id in _avatars:
		positions[_peer_by_id[id]] = _avatars[id].actor.global_position
	bodies.advance(delta, positions, observers())
	_tick += 1
	_elapsed += delta
	var interval := 1.0 / clampi(snapshot_hz, 1, Engine.physics_ticks_per_second)
	if _elapsed < interval:
		return
	_elapsed = fmod(_elapsed, interval)
	var poses := {}
	for id in _avatars:
		var avatar := _avatars[id]
		poses[id] = [id, avatar.lifetime, SNAPSHOT.capture(avatar.actor, _tick, avatar.revision)]
	for peer: int in _ready_levels:
		var batch := []
		for id in _avatars:
			if _visible(peer, id):
				var pose: Array = poses[id]
				if _peer_by_id[id] == peer:
					pose = pose + [_avatars[id].wield.accepted_sequence]
				batch.append(pose)
		if not batch.is_empty():
			_poses.rpc_id(peer, batch)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _commands(life: int, revision: int, data: PackedByteArray) -> void:
	if not multiplayer.is_server():
		return
	var record := _session.for_peer(multiplayer.get_remote_sender_id())
	var avatar := avatar_for(record.get("player_id", ""))
	if avatar and avatar.lifetime == life and avatar.revision == revision and avatar.source:
		avatar.source.receive(data, avatar.actor.current_seat is CogitoVehicle)


@rpc("authority", "call_remote", "unreliable", 1)
func _poses(batch: Array) -> void:
	for pose: Array in batch:
		_receive_pose(pose[0], pose[1], pose[2], pose[3] if pose.size() > 3 else -1)


func _receive_pose(id: String, life: int, frame: Dictionary, accepted := -1) -> void:
	var avatar := avatar_for(id)
	if avatar and avatar.timeline and avatar.lifetime == life:
		var previous_revision := avatar.revision
		avatar.receive(frame)
		if avatar.actor == local_actor:
			avatar.wield.reconcile(frame.ack, accepted)
		if avatar.actor == local_actor and avatar.revision != previous_revision:
			command_channel.clear()


func _process(delta: float) -> void:
	bodies.present()
	for avatar in _avatars.values():
		if avatar.timeline:
			avatar.present(delta)

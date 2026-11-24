extends Node
## Reliable level-ready baseline and spawn endpoint. Roster removal is the reliable despawn.
## Using the session path lets slow loaders receive their baseline after their level exists.

## The local controller has its initial pose, or has been removed.
signal local_changed(actor: CogitoPlayer)

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
	world.bind(root, key)
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
	clear()
	interactions.clear()
	world.clear()
	_bindings.clear()
	if _owns_root:
		CogitoLevel.unmark_network_root(_level)
		_owns_root = false
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
func _level_ready(key: String, nonce: int) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if not multiplayer.is_server() or _session.for_peer(peer).is_empty() or key.length() > 512:
		return
	if nonce <= int(_bindings.get(peer, 0)):
		return
	_peer_by_id[_session.for_peer(peer).player_id] = peer
	world.forget(peer)
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
	if not initial_pose.is_empty():
		avatar.receive(initial_pose)
	if local:
		command_channel.clear()
		local_actor = avatar.actor
		local_changed.emit(local_actor)


func _send_spawn(peer: int, id: String) -> void:
	var avatar := _avatars[id]
	var frame := SNAPSHOT.capture(avatar.actor, _tick, avatar.revision)
	_spawn.rpc_id(peer, _level_key, id, avatar.lifetime, frame)


@rpc("authority", "call_remote", "reliable", 0)
func _spawn(key: String, id: String, life: int, frame: Dictionary) -> void:
	if not is_instance_valid(_level) or _level_key != key or _session.for_id(id).is_empty():
		return
	if _avatars.has(id):
		return
	_create(id, life, Transform3D(Basis.IDENTITY, frame.position), frame)


func _remove(id: String) -> void:
	var peer := int(_peer_by_id.get(id, 0))
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


## Increment after a server-forced look, seat change, teleport or respawn in place.
func mark_teleport(id: String) -> void:
	if multiplayer.is_server() and _avatars.has(id):
		var avatar := _avatars[id]
		avatar.revision += 1
		if avatar.source:
			avatar.source.clear()


func _physics_process(delta: float) -> void:
	if _avatars.is_empty():
		return
	if not multiplayer.is_server():
		if local_actor and local_actor.last_consumed_sequence >= 0:
			var packet := command_channel.packet(local_actor.current_command)
			if not packet.is_empty():
				var avatar := _avatars[_session.local_id]
				_commands.rpc_id(1, avatar.lifetime, avatar.revision, packet)
		return
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
				batch.append(poses[id])
		if not batch.is_empty():
			_poses.rpc_id(peer, batch)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _commands(life: int, revision: int, data: PackedByteArray) -> void:
	if not multiplayer.is_server():
		return
	var record := _session.for_peer(multiplayer.get_remote_sender_id())
	var avatar := avatar_for(record.get("player_id", ""))
	if avatar and avatar.lifetime == life and avatar.revision == revision and avatar.source:
		avatar.source.receive(data)


@rpc("authority", "call_remote", "unreliable", 1)
func _poses(batch: Array) -> void:
	for pose: Array in batch:
		_receive_pose(pose[0], pose[1], pose[2])


func _receive_pose(id: String, life: int, frame: Dictionary) -> void:
	var avatar := avatar_for(id)
	if avatar and avatar.timeline and avatar.lifetime == life:
		var previous_revision := avatar.revision
		avatar.receive(frame)
		if avatar.actor == local_actor and avatar.revision != previous_revision:
			command_channel.clear()


func _process(delta: float) -> void:
	for avatar in _avatars.values():
		if avatar.timeline:
			avatar.present(delta)

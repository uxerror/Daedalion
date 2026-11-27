extends Node
## Reliable level-ready baseline and spawn endpoint. Roster removal is the reliable despawn.
## Using the session path lets slow loaders receive their baseline after their level exists.

## The local controller has its initial pose, or has been removed.
signal local_changed(actor: CogitoPlayer)

const Attributes := preload("net_attributes.gd")
const COMBAT := preload("net_combat_events.gd")
const PROJECTILES := preload("net_projectiles.gd")
const PROFILE := preload("net_wield_profile.gd")
const STOCK := preload("net_stock.gd")
const INVENTORY := preload("net_inventory.gd")
const CONTAINERS := preload("net_containers.gd")
const SPAWNER := preload("net_spawner.gd")
const INTERACTIONS := preload("net_interactions.gd")
const Persistence := preload("net_persistence.gd")
const WORLD := preload("net_world_state.gd")
const SESSION := preload("net_session.gd")
const AVATAR := preload("net_avatar.gd")
const CHANNEL := preload("net_command_channel.gd")
const SNAPSHOT := preload("net_snapshot.gd")

## Optional game spawn transform selector, supplied by the facade.
var spawn_policy: Callable
## Owned only by a persistent server session.
var persistence: Persistence
## Shared default for NPCs without an authored policy.
var npc_target_policy := CogitoNpcTargetPolicy.new()
## Number of snapshot broadcasts per second.
var snapshot_hz := 25
## Sender-side packet policy. A custom channel can drop or delay packets for transport tests.
var command_channel := CHANNEL.new()
## Local network controller once ready. Dedicated sessions leave this empty.
var local_actor: CogitoPlayerAdvanced
## Replicated object registry and state for this online branch.
var world := WORLD.new()
## World and personal quest progression for this session.
var quests := preload("net_quests.gd").new()
## Reliable gameplay requests and private results for this session.
var interactions := INTERACTIONS.new()
## Private player inventories, viewer grants and level-local runtime objects.
var inventory := INVENTORY.new()
var containers := CONTAINERS.new()
var spawner := SPAWNER.new()
## Motion stream shared by authored and runtime bodies.
var bodies := preload("net_bodies.gd").new()
## Listener-specific NPC perception and presentation.
var npcs := preload("net_npc_listeners.gd").new()
## Public elemental state for world objects and avatars in observer interest.
var elements := preload("net_elements.gd").new()
## Owner-scoped carry input and release.
var carry := preload("net_carry.gd").new()
## Authoritative seat and driver claims.
var seats := preload("net_seats.gd").new()
## Server damage, life transitions and private respawn endpoint.
var death := preload("net_death.gd").new()
var combat := COMBAT.new()
var projectiles := PROJECTILES.new()
## Stable session coordinator shared by the live level endpoints.
var travel: Node
var _secondary := false
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
	if not _secondary:
		travel = preload("net_travel.gd").new()
		travel.name = "Travel"
		add_child(travel)
		quests.name = "Quests"
		add_child(quests)
	elements.name = "Elements"
	add_child(elements)
	npcs.name = "Npcs"
	add_child(npcs)
	death.name = "Death"
	add_child(death)
	combat.name = "Combat"
	add_child(combat)
	projectiles.name = "Projectiles"
	add_child(projectiles)
	if not _secondary:
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
	if _secondary:
		_session.left.connect(_remove)
		return
	_session.joined.connect(travel.admit)
	_session.left.connect(_remove)
	_session.ready_for_play.connect(_announce_level)


## The level currently accepting spawns on this session branch.
func active_level() -> Node:
	return _level


## Binds the scene selected by the game on this branch, in level-local coordinates.
func bind_level(root: Node, start: Transform3D, key: String) -> void:
	if (
		_level == root
		or is_queued_for_deletion()
		or not is_inside_tree()
		or not root.is_inside_tree()
	):
		return
	if not _secondary and travel.loading:
		travel.adopt_key(root, key)
	if not _secondary and travel.primary_key.is_empty():
		travel.primary_key = key
	if persistence and persistence.levels.has(key):
		if persistence.levels[key].active_level() != root:
			push_error("A live level already owns key " + key)
		return
	if not _secondary and key != travel.primary_key:
		_bind_secondary(root, start, key)
		return
	if is_instance_valid(_level):
		return
	_level = root
	_level_key = key
	_start = start
	set_process(not multiplayer.is_server())
	set_physics_process(true)
	_owns_root = CogitoLevel.mark_network_root(root)
	root.set_meta(&"cogito_net_players", self)
	travel.levels[key] = self
	if persistence:
		persistence.rebuild(key, root)
	spawner.bind(root)
	world.bind(root, key)
	for id in world.entities.objects:
		var node := world.entities.objects[id]
		elements.track(id, node)
		if node is CogitoNPC:
			npcs.track(node)
			bodies.track(id, node)
		if (
			node is RigidBody3D
			and not (node.get_parent() is BoneAttachment3D and node.owner is CogitoNPC)
		):
			bodies.track(id, node)
		if node is CogitoVehicle:
			var target: Node3D = node.vehicle_node if node.vehicle_node else node
			if not target is RigidBody3D and CogitoLevel.root_of(target) == root:
				bodies.track(CogitoPersistentId.of(target), target)
	spawner.track_authored()
	root.tree_exiting.connect(_level_exiting, CONNECT_ONE_SHOT)
	if persistence:
		persistence.restore_level(key, self)
		if persistence.restore_error != OK:
			if not _secondary and not travel.managed:
				multiplayer.multiplayer_peer.refuse_new_connections = true
				_session.get_parent()._failed_world.call_deferred(key, persistence.restore_error)
			return
		if not _secondary:
			multiplayer.multiplayer_peer.refuse_new_connections = false
	if _secondary or travel.loading:
		return
	if multiplayer.is_server():
		if not _session.local_id.is_empty():
			quests.baseline(1)
		for record in _session.records():
			travel.admit(record.player_id)
	else:
		_announce_level()


# Each room owns its simulation and observer sets. The party and private stock span rooms.
func _bind_secondary(root: Node, start: Transform3D, key: String) -> void:
	var path := "Level_" + key.sha256_text()
	var endpoint := _session.get_node_or_null(NodePath(path))
	if endpoint:
		endpoint.bind_level(root, start, key)
		return
	endpoint = get_script().new()
	endpoint.name = path
	endpoint._secondary = true
	endpoint.travel = travel
	endpoint.spawn_policy = spawn_policy
	endpoint.snapshot_hz = snapshot_hz
	endpoint.npc_target_policy = npc_target_policy
	endpoint.death.policy = death.policy
	endpoint.death.damage_policy = death.damage_policy
	endpoint.death.screen_scene = death.screen_scene
	endpoint.local_changed.connect(local_changed.emit)
	endpoint.persistence = persistence
	endpoint.quests.free()
	endpoint.quests = quests
	endpoint.inventory.free()
	endpoint.inventory = inventory
	_session.add_child(endpoint)
	endpoint.bind_level(root, start, key)


func _exit_tree() -> void:
	if is_instance_valid(_level):
		_level.tree_exiting.disconnect(_level_exiting)
		_level_exiting()
	if persistence and not _secondary:
		persistence.close()


## Release network ownership immediately when a hosted room is queued for deletion.
func unbind_level() -> void:
	_level.tree_exiting.disconnect(_level_exiting)
	_level_exiting()


func _level_exiting() -> void:
	if not travel.loading and multiplayer.has_multiplayer_peer() and 1 in multiplayer.get_peers():
		_level_left.rpc_id(1, _level_key, world.binding())
	projectiles.clear()
	clear()
	interactions.clear()
	npcs.clear()
	bodies.clear()
	elements.clear()
	world.clear()
	_bindings.clear()
	if _owns_root:
		CogitoLevel.unmark_network_root(_level)
		_owns_root = false
	travel.levels.erase(_level_key)
	if persistence:
		persistence.levels.erase(_level_key)
	# Keep the RPC path for late datagrams. No scene or subscriptions remain on it.
	spawner.clear()
	if _secondary:
		set_physics_process(false)
	set_process(false)
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
	npcs.forget(peer)
	bodies.forget(peer)
	elements.forget(peer)


@rpc("any_peer", "call_remote", "reliable", 0)
func _level_ready(key: String, nonce: int) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if not multiplayer.is_server() or _session.for_peer(peer).is_empty() or key.length() > 512:
		return
	if travel.managed or travel.pending.has(_session.for_peer(peer).player_id):
		return
	if nonce <= int(_bindings.get(peer, 0)):
		return
	accept_ready(peer, key, nonce)


## Install only this observer after admission or a validated travel acknowledgement.
func accept_ready(peer: int, key: String, nonce: int) -> void:
	if key != _level_key or not _avatars.has(_session.for_peer(peer).player_id):
		return
	_peer_by_id[_session.for_peer(peer).player_id] = peer
	if _bindings.has(peer):
		_release_subscription(peer)
	_bindings[peer] = nonce
	_ready_levels[peer] = key
	quests.baseline(peer)
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


func _joined(id: String, placement: Variant = null, attached := {}) -> void:
	if not multiplayer.is_server() or not is_instance_valid(_level) or _avatars.has(id):
		return
	_serial = travel.next_serial()
	var start := join_transform(id)
	_create(id, _serial, start)
	if placement is Transform3D:
		var actor := _avatars[id].actor
		actor.position = placement.origin
		actor.body.rotation.y = placement.basis.get_euler().y
		travel.rules().arrived(actor, attached, self)
		mark_teleport(id)
		actor.reset_physics_interpolation()
	for peer: int in _ready_levels:
		if _visible(peer, id):
			_send_spawn(peer, id)
		# A level can finish loading after several of its clients have signalled ready.
		if peer == _peer_by_id[id]:
			_subscribe(peer)
			for other in _avatars:
				if other != id and _visible(peer, other):
					_send_spawn(peer, other)


## Level-local spawn used on admission and as the respawn fallback.
func join_transform(id: String) -> Transform3D:
	var slot := 0
	var start := _start
	if spawn_policy.is_valid():
		start = spawn_policy.call(_level, id, _start)
	else:
		while not _clear_position(start.origin, id):
			slot += 1
			start.origin = _start.origin + _start.basis.x * (1.5 * slot)
	return start


func _clear_position(point: Vector3, id: String) -> bool:
	for avatar in _avatars.values():
		if (
			avatar != avatar_for(id)
			and avatar.actor.position.distance_squared_to(point) < 1.4 * 1.4
		):
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
	elements.track("avatar:" + id, avatar.actor)
	avatar.actor.player_interaction_component.network_interactions = interactions
	avatar.wield.actor = avatar.actor
	avatar.wield.players = self
	avatar.wield.player_id = id
	avatar.wield.life = life
	avatar.wield.owner_peer = _peer_by_id[id]
	avatar.actor.set_meta(&"net_wield", avatar.wield)
	if persistence:
		avatar.actor.set_meta(&"profile_name", _session.for_id(id).display_name)
		persistence.mark_dirty()
	inventory.attach(avatar.actor, id, _peer_by_id[id], life)
	if not initial_pose.is_empty():
		avatar.receive(initial_pose)
	if local:
		command_channel.clear()
		local_actor = avatar.actor
		local_changed.emit(local_actor)
		world.acknowledge_local_avatar()
	if multiplayer.is_server():
		if persistence:
			persistence.lives.attach(id, avatar.actor, self, persistence.placement)
		death.attach(id, avatar.actor)
		avatar.health_fraction = Attributes.health_fraction(avatar.actor)


func _send_spawn(peer: int, id: String) -> void:
	var avatar := _avatars[id]
	var frame := SNAPSHOT.capture(avatar.actor, _tick, avatar.revision)
	var wield := avatar.wield
	frame.wield = [wield.public_item, wield.light_on, wield.aiming]
	var private := Attributes.capture(avatar.actor) if peer == _peer_by_id[id] else {}
	frame.vitals = _vitals(id, peer, private)
	_spawn.rpc_id(peer, _level_key, _bindings[peer], id, avatar.lifetime, frame)


@rpc("authority", "call_remote", "reliable", 0)
func _spawn(key: String, binding: int, id: String, life: int, frame: Dictionary) -> void:
	if binding != world.binding() or not is_instance_valid(_level):
		return
	if _level_key != key or _session.for_id(id).is_empty():
		return
	var avatar := avatar_for(id)
	if avatar:
		if life <= avatar.lifetime:
			return
		_install_life(avatar, life)
		avatar.timeline = SNAPSHOT.new()
		avatar.receive(frame)
		if avatar.actor == local_actor:
			_life_ready.rpc_id(1, life)
	else:
		_create(id, life, Transform3D(Basis.IDENTITY, frame.position), frame)
	_apply_vitals(id, life, frame.vitals)
	_wield_state(id, life, frame.wield[0], frame.wield[1], frame.wield[2])


func _remove(id: String) -> void:
	if not _avatars.has(id):
		return
	if persistence:
		persistence.departing(id, _avatars[id].actor, self)
	var peer := int(_peer_by_id.get(id, 0))
	carry.release(peer, false)
	if multiplayer.is_server() and _avatars.has(id):
		seats.release(_avatars[id].actor)
	npcs.forget(peer)
	bodies.forget(peer)
	elements.forget(peer)
	world.forget(peer)
	interactions.forget(peer)
	_bindings.erase(peer)
	_ready_levels.erase(peer)
	_peer_by_id.erase(id)
	if not _avatars.has(id):
		return
	var avatar := _avatars[id]
	death.detach(id, avatar.actor)
	_avatars.erase(id)
	var local := avatar.actor == local_actor
	if local:
		interactions.close_view(avatar.actor.player_interaction_component)
		if avatar.actor.player_hud.is_inventory_visible():
			avatar.actor.player_hud.set_inventory_visibility(false)
	containers.forget(peer)
	avatar.wield.clear()
	inventory.detach(peer, avatar.actor)
	if persistence:
		inventory.restore(id, persistence.lives.pending[id].stock)
		death.forget(id)
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
		profile.configure(STOCK.load_definition(path) as WieldableItemPD)
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


## Capture all state on the server main thread at one physics frame.
func save_world() -> Error:
	return persistence.save(self, Engine.get_physics_frames()) if persistence else ERR_UNAUTHORIZED


## Signal a durable change to the authority writer when this level belongs to a world.
func mark_world_dirty() -> void:
	if persistence:
		persistence.mark_dirty()


func _physics_process(delta: float) -> void:
	if persistence and not _secondary:
		travel.advance()
		persistence.poll(self, Engine.get_physics_frames())
		if not is_inside_tree():
			return
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
		if local_actor and not local_actor.is_dead and local_actor.last_consumed_sequence >= 0:
			var packet := command_channel.packet(local_actor.current_command)
			if not packet.is_empty():
				var avatar := _avatars[_session.local_id]
				_commands.rpc_id(1, avatar.lifetime, avatar.revision, packet)
		return
	for id in _avatars:
		var avatar := _avatars[id]
		flush_attributes(id)
		if avatar.actor.is_dead:
			death.check_automatic(id, avatar.lifetime)
			continue
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
	var peers := observers()
	bodies.advance(delta, positions, peers)
	elements.advance(delta, positions, peers)
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
	var sender := multiplayer.get_remote_sender_id()
	var record := _session.for_peer(sender)
	var avatar := avatar_for(record.get("player_id", ""))
	if not peer_in_level(sender) or travel.pending.has(record.get("player_id", "")):
		return
	if avatar and avatar.lifetime == life and avatar.revision == revision and avatar.source:
		if not death.reject_dead_input(sender):
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


func _install_life(avatar: AVATAR, life: int) -> void:
	avatar.lifetime = life
	avatar.wield.life = life
	avatar.actor.set_meta(&"inventory_life", life)
	if avatar.actor == local_actor:
		command_channel.clear()


## Start a new incarnation in place, preserving inventory, equipment and game-owned quest state.
func renew_life(id: String) -> void:
	var avatar := _avatars[id]
	_serial = travel.next_serial()
	_install_life(avatar, _serial)
	mark_teleport(id)
	avatar.health_fraction = Attributes.health_fraction(avatar.actor)
	avatar.wield.resume_equipped()
	inventory.flush_actor(avatar.actor)
	for peer: int in _ready_levels:
		if _visible(peer, id):
			_send_spawn(peer, id)
	if _peer_by_id[id] == 1:
		inventory.baseline(1)


@rpc("any_peer", "call_remote", "reliable", 0)
func _life_ready(life: int) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if multiplayer.is_server() and peer_in_level(peer):
		var avatar := avatar_for(_session.for_peer(peer).player_id)
		if avatar.lifetime == life:
			inventory.baseline(peer)


func _vitals(id: String, peer: int, changes: Dictionary) -> Dictionary:
	var avatar := _avatars[id]
	var fields := {
		"dead": avatar.actor.is_dead,
		"health_fraction": Attributes.health_fraction(avatar.actor),
	}
	if peer == _peer_by_id[id]:
		fields.attributes = changes
		if avatar.actor.is_dead:
			fields.remaining = death.remaining(id)
	return fields


## Flush due meters at the end of a synchronous transaction or server physics tick.
func flush_attributes(id: String, hit := false) -> void:
	var avatar := _avatars[id]
	var changes := avatar.attributes.changes(avatar.actor, Time.get_ticks_msec(), hit)
	if not changes.is_empty():
		publish_vitals(id, changes)


## Send private values only to the owner. Other observers need only health and death transitions.
func publish_vitals(id: String, changes: Dictionary) -> void:
	var avatar := _avatars[id]
	avatar.health_fraction = Attributes.health_fraction(avatar.actor)
	for peer: int in _ready_levels:
		if _visible(peer, id) and (peer == _peer_by_id[id] or changes.has("health")):
			_apply_vitals.rpc_id(peer, id, avatar.lifetime, _vitals(id, peer, changes))


@rpc("authority", "call_remote", "reliable", 0)
func _apply_vitals(id: String, life: int, fields: Dictionary) -> void:
	var avatar := avatar_for(id)
	if not avatar or avatar.lifetime != life:
		return
	avatar.health_fraction = fields.health_fraction
	if avatar.actor.is_local_presentation:
		Attributes.apply(avatar.actor, fields.get("attributes", {}))
	death.present(avatar.actor, fields.dead, fields.get("remaining", 0.0))

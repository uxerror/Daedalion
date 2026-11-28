extends Node
## Level-scoped authoritative physics stream. Motion never advances an interaction revision.

const TIMELINE := preload("net_body_timeline.gd")
const NEAR := 24.0
const INTEREST := 96.0

var _bodies: Dictionary[String, Node3D] = {}
var _npc_poses := {}
var _original := {}
var _observers := {}
var _timelines: Dictionary[String, TIMELINE] = {}
var _tick := 0
var _elapsed := 0.0
var _batch_number := 0


## Freeze physical state independently of interest and observer interpolation.
func capture() -> Dictionary:
	var records := {}
	for id in _bodies:
		var body := _bodies[id]
		if CogitoPersistentId.is_disappearing(body):
			continue
		var row := {"transform": body.transform}
		if body is RigidBody3D:
			row.linear = body.linear_velocity
			row.angular = body.angular_velocity
			row.sleeping = body.sleeping
			row.frozen = body.freeze and not body.has_meta(&"net_carrier")
		if body is NetNpcCorpse:
			var root: Transform3D = body.frame_root()
			row.transform = body.get_parent_node_3d().global_transform.affine_inverse() * root
			row.bones = NetNpcCorpse.Codec.encode(body.bones, root)
			row.sleeping = true
		records[id] = row
	return records


## Restore after runtime bodies are registered, before physics advances.
func restore(records: Dictionary) -> void:
	for id: String in records:
		var body := _bodies.get(id) as Node3D
		if body and not CogitoPersistentId.is_disappearing(body):
			var row: Dictionary = records[id]
			body.transform = row.transform
			if body is NetNpcCorpse:
				if row.has("bones"):
					body.restore_frame(body.global_transform, row.bones)
				else:
					# Old MP4 saves store the box centre. Its skin had this local transform.
					body.transform *= Transform3D(
						Basis(Vector3.RIGHT, -PI / 2), Vector3.BACK * 0.85
					)
			if body is RigidBody3D and row.has("linear"):
				body.freeze = row.get("frozen", body.freeze)
				body.linear_velocity = row.linear
				body.angular_velocity = row.angular
				body.sleeping = row.sleeping
			body.reset_physics_interpolation()


## Register an authored or spawned body before its first observer baseline.
func track(id: String, body: Node3D) -> void:
	if _bodies.has(id):
		return
	_bodies[id] = body
	body.tree_exiting.connect(_untrack.bind(id), CONNECT_ONE_SHOT)
	if not multiplayer.is_server() and body is RigidBody3D:
		_original[id] = [
			body.freeze, body.freeze_mode, body.contact_monitor, body.is_physics_processing()
		]
		body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		body.freeze = true
		body.contact_monitor = false
		body.set_physics_process(false)


func _untrack(id: String) -> void:
	var body := _bodies[id]
	if body.tree_exiting.is_connected(_untrack.bind(id)):
		body.tree_exiting.disconnect(_untrack.bind(id))
	if _original.has(id):
		var rigid := body as RigidBody3D
		var old: Array = _original[id]
		rigid.freeze_mode = old[1]
		rigid.freeze = old[0]
		rigid.contact_monitor = old[2]
		rigid.set_physics_process(old[3])
		_original.erase(id)
	for seen: Dictionary in _observers.values():
		seen.erase(id)
	_npc_poses.erase(id)
	_bodies.erase(id)
	_timelines.erase(id)


## Restore authored simulation settings if the level survives session shutdown.
func clear() -> void:
	for id: String in _bodies.keys():
		_untrack(id)
	_observers.clear()


## A new level subscription needs fresh interest baselines, even for sleeping bodies.
func forget(peer: int) -> void:
	_observers.erase(peer)


## Collect once per tick, then send one filtered batch per interested connection.
func advance(delta: float, players: Dictionary, peers: Array[int]) -> void:
	_tick += 1
	_elapsed += delta
	if _elapsed + 0.000001 < 0.05:
		return
	_elapsed = maxf(0, _elapsed - 0.05)
	_batch_number += 1
	if peers.is_empty():
		return
	var samples := {}
	for id in _bodies:
		var body := _bodies[id]
		var rigid := body as RigidBody3D
		var driven := body.has_meta(&"net_driver")
		var rest: bool = not driven and (rigid == null or rigid.freeze or rigid.sleeping)
		var pose := body.global_transform
		if body is NetNpcCorpse:
			pose = body.frame_root()
			rest = body.resting
		var nearby := false
		for point: Vector3 in players.values():
			if point.distance_squared_to(pose.origin) <= NEAR * NEAR:
				nearby = true
				break
		var linear := rigid.linear_velocity if rigid and not rest else Vector3.ZERO
		var angular := rigid.angular_velocity if rigid and not rest else Vector3.ZERO
		if body is CogitoNPC:
			rest = body.global_transform.is_equal_approx(_npc_poses.get(id, body.global_transform))
			linear = Vector3.ZERO if rest else body.get_real_velocity()
			_npc_poses[id] = body.global_transform
		if driven:
			var vehicle: CogitoVehicle = body.get_meta(&"net_driver")
			linear = vehicle.velocity
			angular = body.global_basis.y.normalized() * vehicle.rotation_momentum
		samples[id] = [pose, linear, angular, rest, nearby or driven]
	var entities: Variant = get_parent().world.entities
	for peer in peers:
		var session := get_parent().get_parent()
		get_parent().npcs.publish(peer, players[peer], session.for_peer(peer).player_id)
		var batch := batch_for(peer, players[peer], samples)
		if batch.rows.is_empty():
			continue
		if batch.reliable:
			_baselines.rpc_id(peer, entities.level_key, entities.epoch, _tick, batch.rows)
		else:
			_motion.rpc_id(peer, entities.level_key, entities.epoch, _tick, batch.rows)


## Build current interest, including stationary transforms moved by scripts or snap slots.
func batch_for(peer: int, viewer: Vector3, samples: Dictionary) -> Dictionary:
	var seen: Dictionary = _observers.get_or_add(peer, {})
	var rows := []
	var reliable := false
	for id: String in samples:
		var sample: Array = samples[id]
		var pose: Transform3D = sample[0]
		if viewer.distance_squared_to(pose.origin) > INTEREST * INTEREST:
			seen.erase(id)
			continue
		var last: Array = seen.get(id, [])
		var rest: bool = sample[3]
		var reset := last.is_empty()
		var corpse := _bodies.get(id) as NetNpcCorpse
		if not reset and rest and last[1] and pose.is_equal_approx(last[0]):
			continue
		if not reset and not rest and not sample[4] and _batch_number % 4:
			if corpse:
				# Even a wake shorter than the far cadence needs a final joint pose.
				last[1] = false
			continue
		var entry_tick: int = _tick if reset else last[2]
		seen[id] = [pose, rest, entry_tick]
		reset = reset or rest
		reliable = reliable or reset
		var row := [id, pose, sample[1], sample[2], reset, entry_tick, rest]
		if corpse:
			if sample.size() == 5:
				sample.append(NetNpcCorpse.Codec.encode(corpse.bones, pose))
			row.append(sample[5])
		rows.append(row)
	return {"rows": rows, "reliable": reliable}


@rpc("authority", "call_remote", "reliable", 2)
func _baselines(key: String, epoch: int, tick: int, rows: Array) -> void:
	_receive(key, epoch, tick, rows)


@rpc("authority", "call_remote", "unreliable", 1)
func _motion(key: String, epoch: int, tick: int, rows: Array) -> void:
	_receive(key, epoch, tick, rows)


func _receive(key: String, epoch: int, tick: int, rows: Array) -> void:
	if not get_parent().world.entities.matches(key, epoch):
		return
	for row: Array in rows:
		var id: String = row[0]
		if not _bodies.has(id):
			continue
		if not _timelines.has(id):
			_timelines[id] = TIMELINE.new()
		if _bodies[id] is CogitoNPC and tick > _timelines[id].tick:
			_bodies[id].network_state.motion(row[2])
		var corpse := _bodies[id] as NetNpcCorpse
		if corpse:
			if tick <= _timelines[id].tick or row.size() != 8:
				continue
			var bytes: PackedByteArray = row[7]
			if bytes.size() != corpse.bones.size() * NetNpcCorpse.Codec.STRIDE:
				continue
		if _timelines[id].push(tick, row):
			if corpse:
				_timelines[id].snap_corpse(corpse)
				corpse.reset_physics_interpolation()
				continue
			_bodies[id].global_transform = row[1]
			_bodies[id].reset_physics_interpolation()


## Apply client presentation only. Gameplay collisions keep their server geometry.
func present() -> void:
	for id in _timelines:
		if _timelines[id].tick >= 0 and not _timelines[id].resting:
			var corpse := _bodies[id] as NetNpcCorpse
			var pose := _timelines[id].pose(Engine.physics_ticks_per_second, corpse)
			if not corpse:
				_bodies[id].global_transform = pose


## Publish a live sound selected by the registered body's authored ImpactSounds component.
func impact(body: Node3D, sound: ImpactSounds) -> void:
	var entities: Variant = get_parent().world.entities
	var id: String = entities.id_for(body)
	for peer: int in get_parent().observers():
		if _observers.get(peer, {}).has(id):
			_sound.rpc_id(peer, entities.level_key, entities.epoch, id, body.get_path_to(sound))


@rpc("authority", "call_remote", "reliable", 2)
func _sound(key: String, epoch: int, id: String, path: NodePath) -> void:
	if get_parent().world.entities.matches(key, epoch) and _bodies.has(id):
		var sound := _bodies[id].get_node_or_null(path) as ImpactSounds
		if sound and sound.audio_stream_player_3d:
			sound.audio_stream_player_3d.play()

extends Node
## Level-scoped authoritative physics stream. Motion never advances an interaction revision.

const TIMELINE := preload("net_body_timeline.gd")
const NEAR := 24.0
const INTEREST := 96.0

var _bodies: Dictionary[String, Node3D] = {}
var _original := {}
var _observers := {}
var _timelines: Dictionary[String, TIMELINE] = {}
var _tick := 0
var _elapsed := 0.0
var _batch_number := 0


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
		var nearby := false
		for point: Vector3 in players.values():
			if point.distance_squared_to(body.global_position) <= NEAR * NEAR:
				nearby = true
				break
		var linear := rigid.linear_velocity if rigid and not rest else Vector3.ZERO
		var angular := rigid.angular_velocity if rigid and not rest else Vector3.ZERO
		if driven:
			var vehicle: CogitoVehicle = body.get_meta(&"net_driver")
			linear = vehicle.velocity
			angular = body.global_basis.y.normalized() * vehicle.rotation_momentum
		samples[id] = [body.global_transform, linear, angular, rest, nearby or driven]
	var entities: Variant = get_parent().world.entities
	for peer in peers:
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
		if not reset and rest and last[1] and pose.is_equal_approx(last[0]):
			continue
		if not reset and not rest and not sample[4] and _batch_number % 4:
			continue
		var entry_tick: int = _tick if reset else last[2]
		seen[id] = [pose, rest, entry_tick]
		reset = reset or rest
		reliable = reliable or reset
		rows.append([id, pose, sample[1], sample[2], reset, entry_tick, rest])
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
		if _timelines[id].push(tick, row):
			_bodies[id].global_transform = row[1]
			_bodies[id].reset_physics_interpolation()


## Apply client presentation only. Gameplay collisions keep their server geometry.
func present() -> void:
	for id in _timelines:
		if not _timelines[id].resting:
			_bodies[id].global_transform = _timelines[id].pose(Engine.physics_ticks_per_second)


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

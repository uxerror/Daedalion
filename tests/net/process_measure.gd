extends Node
## Measures one steady window after every owner has installed the demo room and its baseline.

const Travel := preload("process_travel.gd")
const Schedule := preload("packet_schedule.gd")

var args: Dictionary
var _actor: CogitoPlayerAdvanced
var _control := OS.get_environment("COGITO_TEST_CONTROL")
var _ready_roles := false
var _running := false
var _start := 0
var _tick_start := 0
var _previous_start := 0
var _worst_interval := 0
var _ticks := PackedInt64Array()
var _replay := PackedInt64Array()
var _corrections := PackedInt64Array()
var _depths := PackedInt32Array()
var _steps := PackedInt64Array()
var _errors := PackedFloat64Array()
var _ack_errors := PackedFloat64Array()
var _last_point: Vector3
var _walked := 0.0
var _bytes := Vector2i.ZERO
var _checkpoint_sizes := {}
var _driver := Route.new()
var _predicted_ticks := 0
var _engine_peak_us := 0
var _lift_origin := 0.0
var _lift_travel := 0.0
var _room: Node
var _starts: Array[Vector3] = []
var _staged := {}
var _events: Array[Dictionary] = []
var _authority_contacts := {}
var _first_sequence := 0


class Route:
	extends CogitoPlayerInputSource
	const ACTION := CogitoPlayerCommand.Action
	var ticks := 0
	var wait_ticks := 0
	var anchor := Vector3.ZERO
	var bounded := true

	func sample(actor: CogitoPlayer, seq: int) -> CogitoPlayerCommand:
		var cmd := super.sample(actor, seq)
		var t := ticks - wait_ticks
		ticks += 1
		if t < 0:
			cmd.yaw = PI / 2
			return cmd
		var phase := t % 120
		cmd.yaw = PI / 2 * (floori(t / 120.0) % 4) + minf(phase / 30.0, 1.0) * PI / 2
		cmd.move = Vector2.UP
		if bounded:
			# Steer back to authored floor instead of integrating turn error indefinitely.
			# The rider leaves the lift along its open side and returns to the landing.
			var side := 1 if int(t / 60.0) % 2 == 0 else -1
			var target := anchor + Vector3(0, 0, 1.8 * side)
			if wait_ticks:
				target = anchor + Vector3(-1.5, 0, -1.0 if side > 0 else 1.0)
			var offset := target - actor.global_position
			cmd.yaw = atan2(-offset.x, -offset.z)
			if Vector2(offset.x, offset.z).length() < 0.25:
				cmd.move = Vector2.ZERO
		cmd.toggle_crouch = false
		if phase < 40:
			cmd.held = 1 << ACTION.SPRINT
		elif phase >= 80:
			cmd.held = 1 << ACTION.CROUCH
		if phase == 40:
			cmd.held |= 1 << ACTION.JUMP
			cmd.add_edge(ACTION.JUMP)
		return cmd


func _ready() -> void:
	process_physics_priority = 2147483647
	get_tree().physics_frame.connect(_frame_start)
	if CogitoNet.is_server():
		if int(args["--players"]) > 2:
			CogitoNet.player_world.spawn_policy = _admit_at_marker
		if CogitoNet.player_world.travel.start(args["--measure-scene"]) != OK:
			push_error("Cannot load measurement room")
			get_tree().quit(2)


func _frame_start() -> void:
	_tick_start = Time.get_ticks_usec()


func _physics_process(_delta: float) -> void:
	if not _ready_roles:
		_prepare()
	elif not _running:
		if FileAccess.file_exists(_control.path_join("measure")):
			_begin()
	else:
		_tick()


func _prepare() -> void:
	var travel := CogitoNet.player_world.travel
	_room = travel.levels.get(args["--measure-scene"])
	if not _room:
		return
	var server := CogitoNet.is_server()
	if server and int(args["--players"]) > 2:
		_stage_arrivals()
	if _room._avatars.size() != int(args["--players"]):
		return
	var peer := multiplayer.multiplayer_peer
	if server:
		if _room.observers().size() != int(args["--players"]):
			return
		for record in CogitoNet.players():
			if peer.has_method("configure"):
				peer.configure(record.peer_id, 1, Schedule.profile(int(args["--rtt"])))
			if record.display_name == "P1" and args["--measure-scene"] == Travel.LOBBY:
				var actor: CogitoPlayerAdvanced = _room.avatar_for(record.player_id).actor
				var lift: Node3D = _room.active_level().get_node("Platform")
				actor.global_position = lift.to_global(Vector3(0.85, 0.96, -1.15))
				actor.velocity = Vector3.ZERO
				_room.mark_teleport(record.player_id)
	else:
		_actor = CogitoNet.local_player()
		if not _actor or not _room.avatar_for(CogitoNet.local_player_id()).latest_owner_baseline():
			return
		if peer.has_method("configure"):
			peer.configure(1, 1, Schedule.profile(int(args["--rtt"])))
		if _rider():
			var lift: Node3D = _room.active_level().get_node("Platform")
			if _actor.global_position.distance_to(lift.to_global(Vector3(0.85, 0.96, -1.15))) > 0.5:
				return
	_ready_roles = true
	print("NET MEASURE READY")


func _rider() -> bool:
	return args["--measure-scene"] == Travel.LOBBY and args["--name"] == "P1"


## Admit at the authored safe marker. Assign separate floor positions on the next physics tick.
func _admit_at_marker(_level: Node, _id: String, marker: Transform3D) -> Transform3D:
	return marker


func _stage_arrivals() -> void:
	for id: String in _room._avatars:
		if _staged.has(id):
			continue
		var actor: CogitoPlayerAdvanced = _room.avatar_for(id).actor
		actor.global_position = _route_start(actor)
		_starts.append(actor.global_position)
		_staged[id] = true
		actor.velocity = Vector3.ZERO
		_room.mark_teleport(id)


func _route_start(actor: CogitoPlayerAdvanced) -> Vector3:
	var level: Node3D = _room.active_level()
	var marker: Transform3D = level.get_meta(&"network_start")
	var origin := level.to_global(marker.origin)
	var space := actor.get_world_3d().direct_space_state
	var shape := PhysicsShapeQueryParameters3D.new()
	shape.shape = actor.standing_collision_shape.shape
	shape.collision_mask = actor.collision_mask
	for ring in 5:
		for z in range(-ring, ring + 1):
			for x in range(-ring, ring + 1):
				if maxi(absi(x), absi(z)) != ring:
					continue
				var point := origin + Vector3(2 * x, 0, 2 * z)
				var ray := PhysicsRayQueryParameters3D.create(
					point + Vector3.UP * 0.7, point + Vector3.DOWN * 2, actor.collision_mask
				)
				var hit := space.intersect_ray(ray)
				if hit.is_empty() or not hit.collider is StaticBody3D or hit.normal.y < 0.95:
					continue
				point = hit.position + Vector3.UP * (actor.standing_height / 2 + 0.05)
				shape.transform = Transform3D(actor.global_basis, point)
				shape.transform *= actor.standing_collision_shape.transform
				if space.intersect_shape(shape, 1).is_empty() and not point in _starts:
					return point
	push_error("No clear static floor for measurement route")
	get_tree().quit(2)
	return actor.global_position


func _traffic() -> Vector2i:
	var peer := multiplayer.multiplayer_peer
	return (
		Vector2i(peer.sent_bytes, peer.received_bytes)
		if peer.has_method("configure")
		else Vector2i.ZERO
	)


func _begin() -> void:
	_running = true
	_start = Time.get_ticks_usec()
	_bytes = _traffic()
	if not _actor:
		return
	if _rider():
		var lift: Node3D = _room.active_level().get_node("Platform")
		_lift_origin = lift.position.y
		_driver.wait_ticks = 90
		_room.interactions.submit(lift.get_node("GenericSwitch/BasicInteraction"), &"interact")
	_last_point = _actor.global_position
	_driver.anchor = _actor.global_position
	_driver.bounded = args.get("--measure-route", "steady") == "steady"
	_first_sequence = _actor.last_consumed_sequence + 1
	_actor.input_source = _driver
	var prediction := _actor.owner_prediction
	if prediction:
		prediction.measurement_event.connect(_record_event)
		prediction.measure_replay = true


func _collider(id: int) -> String:
	var node := instance_from_id(id) if id else null
	if is_instance_valid(node) and node is CollisionObject3D:
		return (
			"%s (%s, layer %d)"
			% [_room.active_level().get_path_to(node), node.get_class(), node.collision_layer]
		)
	return ""


func _record_event(kind: String, detail: String, seq: int, collider_id: int) -> void:
	var prediction := _actor.owner_prediction
	var t := seq - _first_sequence - _driver.wait_ticks
	var phase := posmod(t, 120)
	var action := "sprint"
	if t < 0:
		action = "ride"
	elif phase == 40:
		action = "jump"
	elif phase >= 80:
		action = "crouch"
	elif phase > 40:
		action = "walk"
	(
		_events
		. append(
			{
				"kind": kind,
				"reason": detail,
				"seq": seq,
				"route_tick": t,
				"action": action,
				"tick": prediction.baseline.tick if prediction.baseline else -1,
				"position": str(_actor.global_position),
				"collider": _collider(collider_id),
				"active": prediction.active,
			}
		)
	)


func _record_authority() -> void:
	for record in CogitoNet.players():
		var avatar = _room.avatar_for(record.player_id)
		var kernel = avatar.actor.authority_movement
		if not kernel or not kernel.room or avatar.checkpoint_eligible:
			continue
		var contacts: Array = _authority_contacts.get_or_add(record.display_name, [])
		var body := _collider(kernel.room.boundary_collider_id)
		var tick: int = _room._tick
		if contacts and contacts.back().end == tick - 1 and contacts.back().collider == body:
			contacts.back().end = tick
		else:
			contacts.append({"start": tick, "end": tick, "collider": body})


func _tick() -> void:
	_ticks.append(Time.get_ticks_usec() - _tick_start)
	var physics_us := roundi(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1e6)
	_engine_peak_us = maxi(physics_us, _engine_peak_us)
	if _previous_start:
		_worst_interval = maxi(_worst_interval, _tick_start - _previous_start)
	_previous_start = _tick_start
	if _actor:
		var point := _actor.global_position
		_walked += Vector2(point.x - _last_point.x, point.z - _last_point.z).length()
		_last_point = point
		var prediction := _actor.owner_prediction
		_replay.append(prediction.replay_usec if prediction else 0)
		_predicted_ticks += int(prediction != null and prediction.active)
		if prediction and prediction.compared_post:
			_ack_errors.append(prediction.last_position_error * 100)
		if prediction and prediction.replay_steps >= 0:
			_corrections.append(prediction.replay_usec)
			_steps.append_array(prediction.replay_step_times)
			_depths.append(prediction.replay_steps)
			_errors.append(prediction.last_position_error * 100)
		var block: NetOwnerState = (
			_room.avatar_for(CogitoNet.local_player_id()).latest_owner_baseline()
		)
		if block:
			var size := NetOwnerState.ELIGIBLE_BYTES if block.state else NetOwnerState.HEADER_BYTES
			_checkpoint_sizes[size] = true
		if _rider() and _driver.ticks < _driver.wait_ticks:
			var lift: Node3D = _room.active_level().get_node("Platform")
			if absf(_actor.global_position.y - lift.global_position.y - 0.9) < 0.2:
				_lift_travel = maxf(_lift_travel, absf(lift.position.y - _lift_origin))
	else:
		_record_authority()
	if Time.get_ticks_usec() - _start >= int(args["--seconds"]) * 1000000:
		_finish()


func _finish() -> void:
	set_physics_process(false)
	var elapsed := (Time.get_ticks_usec() - _start) * 0.000001
	var traffic := _traffic() - _bytes
	var data := {
		"seconds": elapsed,
		"contacts": _authority_contacts,
		"ticks_us": _ticks,
		"worst_interval_us": _worst_interval,
		"engine_peak_us": _engine_peak_us,
		"entities": _room.world.entities.objects.size() + _room._avatars.size(),
		"sent_Bps": traffic.x / elapsed,
		"received_Bps": traffic.y / elapsed,
		"cpu": OS.get_processor_name(),
		"logical_cpus": OS.get_processor_count(),
		"godot": Engine.get_version_info().string,
	}
	if _actor:
		data.merge(
			{
				"replay_us": _replay,
				"corrections_us": _corrections,
				"depth": _depths,
				"error_cm": _errors,
				"ack_cm": _ack_errors,
				"walked_m": _walked,
				"checkpoint_bytes": _checkpoint_sizes.keys(),
				"hard_resets": 0,
				"resumes": 0,
				"events": _events,
				"causes": {},
				"suspensions": {},
				"rider_travel_m": _lift_travel
			}
		)
		var prediction := _actor.owner_prediction
		if prediction:
			data.causes = prediction.restore_samples
			data.resumes = prediction.measured_resumes
			data.hard_resets = prediction.measured_resets
			data.suspensions = prediction.measured_reasons
		data.predictor_installed = prediction != null
		data.predicted_ticks = _predicted_ticks
		data.step_us = _steps
	print("NET MEASURE RESULT ", JSON.stringify(data))

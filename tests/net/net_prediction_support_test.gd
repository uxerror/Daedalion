extends "prediction_session_suite.gd"

const Door := preload("res://addons/cogito/CogitoObjects/cogito_door.gd")
const Schedule := preload("packet_schedule.gd")


class PoseProbe:
	extends Node
	var door: CogitoDoor
	var worst := 0.0
	var samples := 0

	func _physics_process(_dt: float) -> void:
		var world: Node = door.get_meta(&"cogito_net_world")
		var physical: Transform3D = PhysicsServer3D.body_get_state(
			door.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM
		)
		var expected := door.net_support.world_pose(world.support_tick)
		worst = maxf(worst, physical.origin.distance_to(expected.origin))
		samples += 1


func _level(branch: Facade, key: String = "arena") -> Node:
	var host := CogitoLevelHost.new()
	branch.add_child(host)
	var root := host.load_level("res://tests/player/movement_level.tscn", &"arena")
	_fixture(root, "Lift", Vector3(5, 1, 8), Vector3(0, 2.614, 0))
	_fixture(root, "Platform", Vector3(-5, 1, 8), Vector3(3, 0, 0))
	_fixture(root, "Door", Vector3(0, 1, 15), Vector3(0, 0, 2))
	_fixture(root, "Bank", Vector3(0, 1.25, -4.3), Vector3(0.75, 0.2, 0))
	_fixture(root, "Gate", Vector3(10, 1, 15), Vector3.ZERO)
	branch.player_world.bind_level(root, Transform3D(Basis.IDENTITY, Vector3.UP), key)
	return root


func _fixture(root: Node, label: String, at: Vector3, travel: Vector3) -> void:
	var body := AnimatableBody3D.new()
	body.name = label
	body.set_script(Door)
	var door := (body as Node3D) as CogitoDoor
	door.door_type = CogitoDoor.DoorType.SLIDING
	door.door_speed = 3.0
	door.closed_position = at
	door.open_position = at + travel
	body.position = at
	var hull := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3, 0.4, 3) if label != "Door" else Vector3(3, 2, 0.3)
	if label == "Bank":
		box.size = Vector3(4, 1, 5)
	if label == "Gate":
		box.size = Vector3(3, 2, 0.2)
		hull.position.x = 1.5
		door.door_type = CogitoDoor.DoorType.ROTATING
		door.open_rotation = Vector3(0, 90, 0)
		door.door_speed = 1.0
	hull.shape = box
	body.add_child(hull)
	root.add_child(body)


func _door(branch: Facade, label: String) -> CogitoDoor:
	return branch.player_world.active_level().get_node(label)


func _board(label: String) -> CogitoDoor:
	var door := _door(_server, label)
	await _stage_volume(door.position + Vector3.UP * 1.1)
	await _ticks(24)
	assert_int(_owner.prediction.state.support_key).is_equal(door.net_support.key)
	return door


func test_ride_reverse_and_jump_from_rising_and_falling_lift() -> void:
	await _ticks(40)
	var lift := await _board("Lift")
	var probe := PoseProbe.new()
	probe.door = lift
	probe.process_physics_priority = -99
	lift.add_child(probe)
	var low := _authority.actor.position.y
	var events: Array[StringName] = []
	var object_id := _server.player_world.world.entities.id_for(lift)
	var on_event := func(id: String, _rev: int, event: StringName):
		if id == object_id:
			events.append(event)
	_client.player_world.world.presented.connect(on_event)
	lift.open_door(null)
	await _ticks(35)
	var high := _authority.actor.position.y
	assert_float(high - low).is_equal_approx(34 * 2.614 / 180.0, 0.002)
	var motion := lift.net_support
	var tick := _server.player_world.world.support_tick
	assert_vector(lift.position).is_equal(motion.pose(tick).origin)
	var replica := _door(_client, "Lift")
	assert_vector(replica.net_support.pose(tick).origin).is_equal(lift.position)
	_equip_rifle()
	await _push_in_volume(CogitoMovementState.Mode.IDLE)
	_driver.held = 1 << ACTION.JUMP
	await _ticks(1)
	var jump := _owner.prediction.state
	assert_int(jump.support_key).is_zero()
	assert_float(jump.main_velocity.y).is_greater(_authority.actor.JUMP_VELOCITY)
	await _ticks(4)
	await _push_in_volume(CogitoMovementState.Mode.JUMPING)
	_driver.held = 0
	await _ticks(80)
	var generation := _owner.prediction.baseline.generation
	var resets := _owner.prediction.hard_resets
	var corrections := _owner.prediction.corrections
	lift.close_door(null)
	await _ticks(25)
	assert_int(_owner.prediction.baseline.generation).is_equal(generation)
	assert_int(_owner.prediction.hard_resets).is_equal(resets)
	assert_int(_owner.prediction.corrections).is_greater(corrections)
	assert_array(events).contains_exactly([&"open", &"close"])
	assert_int(probe.samples).is_greater(100)
	assert_float(probe.worst).is_less(0.00001)
	print("PR8 RID samples=", probe.samples, " max_error=", probe.worst)
	assert_float(_owner.prediction.state.support_velocity.y).is_less(0)
	_driver.held = 1 << ACTION.JUMP
	await _ticks(1)
	assert_float(_owner.prediction.state.main_velocity.y).is_less(_authority.actor.JUMP_VELOCITY)
	assert_int(_owner.prediction.state.support_key).is_zero()


func test_rtt_routes_with_command_loss(_timeout := 65000) -> void:
	await _ticks(35)
	_network[2].drop_every_tenth_command = true
	for rtt: int in [0, 16, 100, 150]:
		for peer: int in [1, 2]:
			_network[peer].configure(3 - peer, 1, Schedule.profile(rtt))
			_network[peer].configure(3 - peer, 2, Schedule.profile(rtt))
		for label: String in ["Lift", "Platform", "Door"]:
			await _route(label, rtt)


func _route(label: String, rtt: int) -> void:
	var door := _door(_server, label)
	var push := label == "Door"
	if push:
		var side := -1 if door.is_open else 1
		await _stage_volume(door.position + Vector3(0, -0.19, side * 0.52))
		await _ticks(30)
	else:
		await _board(label)
	if door.is_open:
		door.close_door(null)
	else:
		door.open_door(null)
	var prediction := _owner.prediction
	var errors: Array[float] = []
	var start := _authority.actor.position
	var depth := 0
	var initial_resets := prediction.hard_resets
	var reasons := prediction.reasons.duplicate()
	for i in 95:
		await _ticks(1)
		assert_bool(prediction.active).is_true()
		depth = maxi(depth, prediction.last_replay.size())
		var block := prediction.queued
		if block and block.state:
			var post := prediction.post_at(block.ack)
			if post:
				errors.append(post.transform.origin.distance_to(block.state.transform.origin))
	assert_float(_authority.actor.position.distance_to(start)).is_greater(0.35)
	assert_int(errors.size()).is_greater(15)
	var resets := prediction.hard_resets - initial_resets
	assert_int(resets).is_zero()
	assert_dict(prediction.reasons).is_equal(reasons)
	errors.sort()
	var p95 := errors[ceili(0.95 * errors.size()) - 1]
	print(
		"PR8 LANE ",
		label,
		" ",
		rtt,
		" ",
		[errors[errors.size() >> 1], p95, errors.back(), depth, resets, prediction.reasons]
	)
	assert_float(p95).is_less_equal(0.02)


func test_rotating_door_sweep_and_ledge_checkpoint() -> void:
	await _ticks(35)
	await _stage_volume(Vector3(11.5, 0.81, 14.35))
	await _ticks(18)
	var gate := _door(_server, "Gate")
	gate.open_door(null)
	var start := _authority.actor.position
	await _ticks(65)
	assert_float(_authority.actor.position.distance_to(start)).is_greater(0.35)
	assert_bool(_owner.prediction.active).is_true()
	await _stage_volume(Vector3.UP)
	await _ticks(32)
	var bank := _door(_server, "Bank")
	bank.open_door(null)
	_driver.walking = true
	_driver.held = 0
	await _ticks(17)
	_driver.held = 1 << ACTION.JUMP
	_ear = AudioTest.Recorder.new(_owner)
	for i in 65:
		await _ticks(1)
		var state := _owner.prediction.state
		if state and state.mode == CogitoMovementState.Mode.LEDGE_CLIMBING:
			assert_int(state.support_key).is_equal(bank.net_support.key)
			await _ticks(3)
			await _push_in_volume(CogitoMovementState.Mode.LEDGE_CLIMBING)
			return
	fail("The moving ledge was never captured")


func test_silent_late_join_and_restart_mid_segment() -> void:
	await _ticks(40)
	var server := _server.player_world
	var lift := _door(_server, "Lift")
	lift.open_door(null)
	await _ticks(39)
	var late := _branch(3)
	assert_int(late.join("memory", 1803)).is_equal(OK)
	var events: Array = []
	late.player_world.world.presented.connect(
		func(_id: String, _rev: int, event: StringName): events.append(event)
	)
	var previous_env := OS.get_environment("COGITO_AUTHORITY_MOVEMENT")
	OS.set_environment("COGITO_AUTHORITY_MOVEMENT", "1")
	_level(late)
	_pump()
	OS.set_environment("COGITO_AUTHORITY_MOVEMENT", previous_env)
	var seen := _door(late, "Lift")
	assert_array(events).is_empty()
	assert_vector(seen.position).is_equal(lift.position)
	assert_vector(seen.net_support.pose(server.world.support_tick + 11).origin).is_equal(
		lift.net_support.pose(server.world.support_tick + 11).origin
	)
	await _board("Lift")
	var guest := server.avatar_for(late.local_player_id()).actor as CogitoPlayerAdvanced
	guest.position = lift.position + Vector3(1.05, 1.1, 0)
	server.mark_teleport(late.local_player_id())
	await _ticks(36)
	var rider := _client.player_world.avatar_for(late.local_player_id())
	assert_int(rider.timeline.latest().get("support", 0)).is_equal(lift.net_support.key)
	lift.close_door(null)
	var worst := 0.0
	for i in 24:
		await _ticks(1)
		var render_tick := _client.player_world.world.present_supports()
		rider.present(1.0 / 60, render_tick)
		worst = maxf(worst, absf(rider.actor.position.y - _owner.actor.position.y))
	assert_float(worst).is_less(0.002)
	print("PR8 co-rider max height difference=", worst)
	var records := server.world.capture()
	var saved := lift.position
	var future := lift.net_support.pose(server.world.support_tick + 8).origin
	await _ticks(33)
	assert_int(server.world.restore(records)).is_equal(OK)
	assert_vector(lift.position).is_equal(saved)
	await _ticks(8)
	assert_vector(lift.position).is_equal(future)


func test_step_off_and_back_onto_translating_floor(
	rigid: bool, _test_parameters := [[false], [true]]
) -> void:
	for branch in [_server, _client]:
		var landing: PhysicsBody3D
		if rigid:
			var crate := RigidBody3D.new()
			crate.freeze = true
			landing = crate
		else:
			landing = StaticBody3D.new()
		var hull := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(10, 0.4, 4)
		hull.shape = box
		landing.add_child(hull)
		landing.position = Vector3(-4, 1, 4.5)
		branch.player_world.active_level().add_child(landing)
	await _ticks(40)
	var platform := await _board("Platform")
	_ear = AudioTest.Recorder.new(_owner)
	platform.open_door(null)
	_driver.walking = true
	await _crossing(false, rigid, platform.net_support.key)
	assert_int(_ear.feet.footsteps).is_greater(0)
	await _ticks(8)
	if rigid:
		assert_str(_owner.prediction.reason).is_equal("dynamic_support")
	_driver.reverse = true
	await _crossing(true, rigid, platform.net_support.key)
	# The capsule can straddle the seam. Clear the crate's edge before braking.
	await _ticks(10)
	_driver.walking = false
	await _ticks(10)
	assert_bool(_owner.prediction.active).is_true()
	assert_int(_owner.prediction.state.support_key).is_equal(platform.net_support.key)


func _crossing(boarding: bool, rigid: bool, key: int) -> void:
	var actor := _authority.actor
	for i in 70:
		var start := actor.position
		var count := actor.authority_solve_count
		await _ticks(1)
		assert_int(actor.authority_solve_count - count).is_equal(1)
		var hit := actor.authority_movement.contacts
		var boarded := hit != null and hit.support_key == key
		if boarded == boarding:
			var displacement := actor.position - start
			var requested := actor.velocity.z / 60.0
			assert_float(absf(requested)).is_greater(0.01)
			var carry := 0.0 if boarding else 1.0 / 60.0
			assert_float(displacement.x).is_equal_approx(carry, actor.safe_margin * 2)
			assert_float(displacement.z).is_equal_approx(requested, actor.safe_margin * 2)
			print("PR8 CROSS boarding=", boarding, " rigid=", rigid, " delta=", displacement)
			return
	fail("Missing floor crossing")

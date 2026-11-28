extends "prediction_session_suite.gd"

const Lamp := preload("res://addons/cogito/PackedScenes/ceiling_lamp.tscn")


func _level(branch: Facade, key: String = "arena") -> Node:
	var host := CogitoLevelHost.new()
	branch.add_child(host)
	var root := host.load_level("res://tests/player/movement_level.tscn", &"arena")
	var lamp := Lamp.instantiate() as AnimatableBody3D
	lamp.name = "FixedLamp"
	lamp.basis = lamp.basis.rotated(Vector3.UP, PI)
	lamp.position = Vector3(0, 0.9, -1.5)
	root.add_child(lamp)
	branch.player_world.bind_level(root, Transform3D(Basis.IDENTITY, Vector3.UP), key)
	return root


func test_fixed_room_switch_blocks_motion_and_moved_switch_suspends() -> void:
	await _ticks(45)
	_driver.walking = true
	await _ticks(24)
	var prediction := _owner.prediction
	assert_bool(prediction.active).is_true()
	assert_bool(prediction.state.on_wall).is_true()
	var lamp: AnimatableBody3D = _client.player_world.active_level().get_node("FixedLamp")
	lamp.position.z += 0.05
	await _ticks(1)
	await _ticks(1)
	assert_bool(prediction.active).is_false()
	assert_str(prediction.reason).is_equal("unsupported_contact")


func test_suspend_resume_preserves_rendered_eye_and_rig_and_counts_only_snaps() -> void:
	await _ticks(45)
	var prediction := _owner.prediction
	var actor := _owner.actor
	var rig: Node3D = actor.get_node("Rig")
	prediction.measure_replay = true
	for shift: float in [0.18, 1.2]:
		var block := NetOwnerState.decode(NetOwnerState.encode(prediction.baseline))
		block.state.copy_from(prediction.state)
		block.state.transform.origin.x += shift
		block.tick += 1
		block.last_fresh_tick = block.tick
		block.ack = prediction.newest
		block.disposition = NetOwnerState.Disposition.FRESH
		var eye := actor.camera.global_position
		var visible_body := rig.global_position
		prediction._suspend("dynamic_support")
		assert_vector(actor.camera.global_position).is_equal_approx(eye, Vector3.ONE * 0.00001)
		assert_vector(rig.global_position).is_equal_approx(visible_body, Vector3.ONE * 0.00001)
		prediction.queued = block
		prediction.begin_tick()
		prediction.live(actor.neutral_command(prediction.newest + 1))
		assert_bool(prediction.active).is_true()
		if shift < prediction.OFFSET_CAP:
			assert_vector(actor.camera.global_position).is_equal_approx(eye, Vector3.ONE * 0.001)
			assert_vector(rig.global_position).is_equal_approx(visible_body, Vector3.ONE * 0.001)
			assert_float(prediction.render_offset.length()).is_equal_approx(shift, 0.001)
			prediction.render(0.25)
			assert_float(prediction.render_offset.length()).is_less(0.01)
			assert_int(prediction.measured_resets).is_zero()
		else:
			assert_vector(prediction.render_offset).is_equal(Vector3.ZERO)
			assert_float(rig.global_position.distance_to(visible_body)).is_greater(1)
	assert_int(prediction.measured_resets).is_equal(1)
	assert_int(prediction.measured_resumes).is_equal(2)
	assert_dict(prediction.measured_reasons).is_equal({"dynamic_support": 2})


func test_failed_resume_waits_for_entire_untrusted_tail() -> void:
	await _ticks(45)
	var prediction := _owner.prediction
	var block := NetOwnerState.decode(NetOwnerState.encode(prediction.baseline))
	block.ack = prediction.newest
	block.state.copy_from(prediction.state)
	prediction._suspend("dynamic_support")
	for i in 8:
		prediction.live(_owner.actor.neutral_command(prediction.newest + 1))
	block.disposition = NetOwnerState.Disposition.HELD
	# The pending replay cannot resolve the authoritative footing in this room.
	block.state.support_key = 424242
	block.tick += 1
	prediction.queued = block
	prediction.begin_tick()
	assert_str(prediction.reason).is_equal("dynamic_support")
	assert_int(prediction._boundary_sequence).is_equal(prediction.newest + 8)
	block = NetOwnerState.decode(NetOwnerState.encode(block))
	block.state.support_key = 0
	block.ack += 1
	block.tick += 1
	prediction.queued = block
	prediction.begin_tick()
	assert_bool(prediction.active).is_false()
	assert_str(prediction.reason).is_equal("awaiting_boundary_ack")
	block = NetOwnerState.decode(NetOwnerState.encode(prediction.baseline))
	block.ack = prediction.newest
	block.tick += 1
	prediction.queued = block
	prediction.begin_tick()
	assert_bool(prediction.active).is_false()
	for i in 8:
		prediction.live(_owner.actor.neutral_command(prediction.newest + 1))
	block = NetOwnerState.decode(NetOwnerState.encode(prediction.baseline))
	block.ack = prediction.newest
	block.tick += 1
	prediction.queued = block
	prediction.begin_tick()
	assert_bool(prediction.active).is_true()

extends "prediction_session_suite.gd"

const MODE := CogitoMovementState.Mode
const STAGE := CogitoMovementState.LedgeStage


func _bank() -> void:
	for branch in [_server, _client]:
		var bank := StaticBody3D.new()
		bank.name = "TrainingBank"
		var hull := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(4, 1, 5)
		hull.shape = box
		bank.add_child(hull)
		bank.position = Vector3(0, 1.25, -4.3)
		branch.player_world.active_level().add_child(bank)


func _approach() -> void:
	_driver.walking = true
	await _ticks(17)
	_driver.held = 1 << ACTION.JUMP


func test_air_capture_and_replay_crouched_middle_after_push() -> void:
	_bank()
	await _ticks(45)
	_ear = AudioTest.Recorder.new(_owner)
	_network[2].configure(1, 1, {"delay_ms": 50})
	await _approach()
	var rising := false
	for i in 75:
		var height := _owner.actor.position.y
		await _ticks(1)
		assert_bool(_owner.prediction.active).is_true()
		var s := _owner.prediction.state
		if s.mode != MODE.LEDGE_CLIMBING:
			continue
		if not rising:
			assert_int(s.ledge_stage).is_equal(STAGE.RISE)
			assert_float(s.transform.origin.y - height).is_equal_approx(2.5 / 60, 0.0001)
			rising = true
		if s.ledge_stage == STAGE.MIDDLE:
			assert_bool(s.try_crouch and s.crouching_shape).is_true()
			_driver.held = 0
			await _push_in_volume(MODE.LEDGE_CLIMBING)
			await _ticks(65)
			_driver.walking = false
			await _ticks(40)
			_assert_rest()
			return
	fail("No predicted rise/middle crossing")


func test_roll_live_animation_and_mid_roll_replay_after_push(
	first_frame: bool, _test_parameters := [[false], [true]]
) -> void:
	await _ticks(45)
	_ear = AudioTest.Recorder.new(_owner)
	_network[2].configure(1, 1, {"delay_ms": 65})
	await _stage_volume(Vector3(0, 6, 0))
	var clips: Array[StringName] = []
	_owner.actor.animationPlayer.animation_started.connect(clips.append)
	var started := -1
	for i in 160:
		var airborne := not _owner.prediction.state.on_floor
		if first_frame and airborne and started < 0:
			_owner.movement_audio.reset()
		await _ticks(1)
		assert_bool(_owner.prediction.active).is_true()
		var s := _owner.prediction.state
		if started < 0 and s.mode == MODE.ROLLING:
			assert_bool(airborne and s.on_floor).is_true()
			assert_int(s.roll_ticks).is_equal(60)
			assert_str(_owner.actor.animationPlayer.current_animation).is_equal("roll")
			assert_bool(_owner.actor.is_in_interaction_state).is_false()
			assert_bool(_owner.actor.is_in_unpausable_state).is_true()
			started = _owner.prediction.newest
			await _push_in_volume(MODE.ROLLING)
		elif started >= 0 and s.mode != MODE.ROLLING:
			assert_int(_owner.prediction.newest - started).is_equal(60)
			assert_int(_ear.feet.landings).is_equal(1)
			assert_int(clips.count(&"roll")).is_equal(1)
			assert_bool(_owner.actor.is_in_interaction_state).is_true()
			assert_bool(_owner.actor.is_in_unpausable_state).is_false()
			return
	fail("No predicted roll entry/exit")


func test_release_on_first_rise_tick_and_capture_on_grounded_jump() -> void:
	_bank()
	await _ticks(45)
	await _stage_volume(Vector3(0, 0.802, -1.40))
	await _ticks(12)
	var start := _owner.actor.position
	_driver.walking = true
	_driver.held = 1 << ACTION.JUMP
	await _ticks(1)
	var seq := _owner.prediction.newest
	assert_int(_owner.prediction.state.mode).is_equal(MODE.LEDGE_CLIMBING)
	assert_float(_owner.actor.position.y - start.y).is_equal_approx(
		2.5 / 60, _owner.actor.safe_margin
	)
	_driver.held = 0
	await _ticks(1)
	assert_int(_owner.prediction.state.mode).is_not_equal(MODE.LEDGE_CLIMBING)
	var observed := false
	for i in 10:
		var actor := _authority.actor
		if actor.last_consumed_sequence == seq:
			assert_int(actor.current_moving_state).is_equal(MODE.LEDGE_CLIMBING)
			observed = true
		elif actor.last_consumed_sequence == seq + 1:
			assert_int(actor.current_moving_state).is_not_equal(MODE.LEDGE_CLIMBING)
		await _ticks(1)
	assert_bool(observed).is_true()


func test_static_ledge_starts_moving_during_rise(
	rotating: bool, _test_parameters := [[false], [true]]
) -> void:
	_bank()
	await _ticks(45)
	await _stage_volume(Vector3(0, 0.802, -1.40))
	await _ticks(12)
	_network[2].configure(1, 1, {"delay_ms": 80})
	_driver.walking = true
	_driver.held = 1 << ACTION.JUMP
	await _ticks(5)
	var actor := _authority.actor
	assert_int(actor.current_moving_state).is_equal(MODE.LEDGE_CLIMBING)
	assert_int(_owner.prediction.state.mode).is_equal(MODE.LEDGE_CLIMBING)
	for branch in [_server, _client]:
		var bank: StaticBody3D = branch.player_world.active_level().get_node("TrainingBank")
		if rotating:
			bank.constant_angular_velocity = Vector3.UP * 0.1
		else:
			bank.constant_linear_velocity = Vector3.RIGHT * 0.1
	var start := actor.position
	var count := actor.authority_solve_count
	var commits := actor.authority_movement.solves
	await _ticks(1)
	assert_int(actor.authority_solve_count - count).is_equal(1)
	assert_int(actor.authority_movement.solves).is_equal(commits)
	assert_str(_owner.prediction.reason).is_equal("moving_ledge")
	var delta := actor.position - start
	assert_float(delta.y).is_equal_approx(actor.CLIMBING_SPEED / 60, actor.safe_margin)
	print("PR7 CROSS static->moving ledge ", delta)
	for i in 30:
		await _ticks(1)
		if actor.is_in_ledge_climbing_middle_stage:
			break
	assert_bool(actor.is_in_ledge_climbing_middle_stage).is_true()
	for branch in [_server, _client]:
		var bank: StaticBody3D = branch.player_world.active_level().get_node("TrainingBank")
		bank.constant_linear_velocity = Vector3.ZERO
		bank.constant_angular_velocity = Vector3.ZERO
	start = actor.position
	count = actor.authority_solve_count
	commits = actor.authority_movement.solves
	await _ticks(1)
	assert_int(actor.authority_solve_count - count).is_equal(1)
	assert_int(actor.authority_movement.solves - commits).is_equal(1)
	assert_int(actor._motion.ledge_stage).is_equal(STAGE.MIDDLE)
	delta = actor.position - start
	assert_float(delta.y).is_equal_approx(actor.CLIMBING_SPEED / 60, actor.safe_margin)
	print("PR7 CROSS moving->static ledge ", delta)
	await _ticks(14)
	assert_int(_owner.prediction.baseline.state.mode).is_equal(MODE.LEDGE_CLIMBING)
	assert_bool(_owner.prediction.active).is_true()
	assert_int(_owner.prediction.reasons.get("moving_ledge", 0)).is_equal(1)


func test_matched_ledge_and_roll_routes_under_loss(_timeout := 55000) -> void:
	_bank()
	await _ticks(45)
	_network[2].drop_every_tenth_command = true
	for rtt: int in [0, 16, 100, 150]:
		for peer: int in [1, 2]:
			_network[peer].configure(3 - peer, 1, preload("packet_schedule.gd").profile(rtt))
		for mode in [MODE.LEDGE_CLIMBING, MODE.ROLLING]:
			await _measure(mode, rtt)


func _measure(mode: int, rtt: int) -> void:
	_driver.held = 0
	_driver.walking = false
	var ledge := mode == MODE.LEDGE_CLIMBING
	await _stage_volume(Vector3.UP if ledge else Vector3(0, 6, 0))
	if ledge:
		await _ticks(30)
		await _approach()
	var prediction := _owner.prediction
	var initial := prediction.reasons.duplicate()
	var errors: Array[float] = []
	var resets := 0
	var depth := 0
	var matched := 0
	var seen := false
	for i in 165:
		await _ticks(1)
		resets += int(not prediction.active)
		if not prediction.active:
			continue
		if prediction.state.mode == mode:
			seen = true
		elif seen:
			_driver.held = 0
			_driver.walking = false
		var block := prediction.queued
		if block and block.state:
			var post := prediction.post_at(block.ack)
			if post:
				errors.append(post.transform.origin.distance_to(block.state.transform.origin))
				if block.state.mode == mode:
					matched += 1
					assert_int(post.mode).is_equal(mode)
					assert_int(post.ledge_stage).is_equal(block.state.ledge_stage)
					assert_int(post.roll_ticks).is_equal(block.state.roll_ticks)
		depth = maxi(depth, prediction.last_replay.size())
	assert_int(matched).is_greater(5)
	assert_bool(seen).is_true()
	assert_dict(prediction.reasons).is_equal(initial)
	assert_int(resets).is_zero()
	errors.sort()
	var p95 := errors[ceili(errors.size() * 0.95) - 1]
	var row := {
		"p50": errors[errors.size() >> 1],
		"p95": p95,
		"max": errors.back(),
		"depth": depth,
		"resets": resets,
		"matched": matched,
		"suspensions": prediction.reasons
	}
	print("PR7 LANE ", MODE.keys()[mode], " ", rtt, " ", JSON.stringify(row))
	assert_float(p95).is_less_equal(0.02)

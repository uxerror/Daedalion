extends "prediction_session_suite.gd"


func _replay_after_spend() -> void:
	var spent_at := _server.player_world._tick
	_authority.actor.decrease_attribute("stamina", 3.0)
	for i in 20:
		await _ticks(1)
		var block := _owner.prediction.queued
		if block and block.tick > spent_at and block.state:
			assert_int(_owner.prediction.newest - block.ack).is_greater(0)
			_verify_replay(block)
			return
	fail("No checkpoint after authoritative spend")


func test_slide_jump_live_audio_and_replay() -> void:
	await _ticks(45)
	_ear = AudioTest.Recorder.new(_owner)
	_network[2].configure(1, 1, {"delay_ms": 65})
	_driver.walking = true
	_driver.held = 1 << ACTION.SPRINT
	await _ticks(35)
	_driver.held |= 1 << ACTION.CROUCH
	await _ticks(3)
	var state := _owner.prediction.state
	assert_int(state.mode).is_equal(CogitoMovementState.Mode.SLIDING)
	assert_float(state.slide_remaining).is_greater(1.0)
	assert_vector(state.slide_vector).is_equal(Vector2.UP)
	await _replay_after_spend()
	_driver.held |= 1 << ACTION.JUMP
	await _ticks(1)
	_driver.held = 0
	_driver.walking = false
	state = _owner.prediction.state
	assert_bool(state.jumped_from_slide).is_true()
	assert_bool(state.slide_stopped).is_true()
	assert_float(state.jump_remaining).is_greater(0.0)
	await _replay_after_spend()
	await _ticks(90)
	assert_array(_ear.slides).contains_exactly([true, false])
	assert_int(_ear.jumps).is_equal(1)
	assert_int(_ear.feet.landings).is_equal(1)
	assert_int(_ear.feet.footsteps).is_greater(0)
	_assert_rest()


func test_static_stairs_replay_both_directions() -> void:
	for branch in [_server, _client]:
		var level: Node = branch.player_world.active_level()
		var obstacles := StaticBody3D.new()
		level.add_child(obstacles)
		for i in 3:
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(4, 1, 1)
			shape.shape = box
			shape.position = Vector3(0, -0.3 + 0.2 * i, -1.5 - i)
			obstacles.add_child(shape)
	await _ticks(45)
	_ear = AudioTest.Recorder.new(_owner)
	_network[2].configure(1, 1, {"delay_ms": 65})
	var ground := _owner.actor.position.y
	_driver.walking = true
	await _ticks(15)
	await _replay_after_spend()
	await _ticks(23)
	assert_float(_owner.actor.position.y - ground).is_greater(0.38)
	_driver.reverse = true
	await _ticks(12)
	await _replay_after_spend()
	await _ticks(54)
	assert_float(_owner.actor.position.y).is_equal_approx(ground, 0.01)
	_driver.walking = false
	await _ticks(60)
	_assert_rest()


func test_lost_impulse_fallback_snaps_generation_and_replays_pending_walk() -> void:
	await _ticks(45)
	_driver.walking = true
	await _ticks(12)
	var prediction := _owner.prediction
	var generation := prediction.baseline.generation
	_network[2].configure(1, 1, {"loss": 1.0})
	_authority.actor.apply_external_force(Vector3.RIGHT * 6)
	await _ticks(4)
	assert_bool(prediction.active).is_true()
	_network[2].configure(1, 1, {"loss": 0.0})
	for i in 8:
		await _ticks(1)
		var block := prediction.queued
		if block and block.generation > generation:
			assert_object(block.state).is_not_null()
			var z := _owner.actor.camera.global_position.z
			prediction.render_offset = Vector3.RIGHT * 0.2
			prediction.begin_tick()
			assert_bool(prediction.active).is_true()
			assert_vector(prediction.render_offset).is_equal(Vector3.ZERO)
			assert_bool(_owner.movement_audio._previous.is_empty()).is_true()
			var pending := range(block.ack + 1, prediction.newest + 1)
			assert_array(prediction.last_replay).contains_exactly(pending)
			await _ticks(1)
			assert_float(_owner.actor.camera.global_position.z).is_less(z)
			return
	fail("No supported generation after dropped fallback")


func test_local_dynamic_support_waits_for_crossing_ack_and_continues_sending() -> void:
	await _ticks(45)
	var platform := AnimatableBody3D.new()
	var hull := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 1, 4)
	hull.shape = box
	platform.add_child(hull)
	platform.position = _owner.actor.position - Vector3.UP * 1.25
	_client.player_world.active_level().add_child(platform)
	_network[2].configure(1, 1, {"delay_ms": 100})
	await _ticks(4)
	var prediction := _owner.prediction
	assert_bool(prediction.active).is_false()
	var crossing := prediction._boundary_sequence
	assert_int(crossing).is_greater(prediction.baseline.ack)
	var packets := _channel.packets
	platform.free()
	for i in 18:
		await _ticks(1)
		if prediction.baseline.ack < crossing:
			assert_bool(prediction.active).is_false()
	assert_int(_channel.packets - packets).is_equal(18)
	assert_bool(prediction.active).is_true()
	assert_int(prediction.baseline.ack).is_greater_equal(crossing)
	assert_vector(prediction.render_offset).is_equal(Vector3.ZERO)


func test_freeze_replays_a_live_jump_and_thaw_restores_permissions() -> void:
	await _ticks(45)
	_ear = AudioTest.Recorder.new(_owner)
	_network[2].configure(1, 1, {"delay_ms": 65})
	var initial := _owner.prediction.baseline.modifier_generation
	var floor_y := _owner.actor.position.y
	var props := _authority.actor.cogito_properties
	props.make_wet()
	props.apply_element(CogitoProperties.Element.COLD, 1.1)
	_driver.tap = true
	await _ticks(1)
	assert_float(_owner.actor.position.y).is_greater(floor_y)
	for i in 16:
		await _ticks(1)
		var block := _owner.prediction.queued
		if block and not block.state.jump_allowed:
			assert_int(block.modifier_generation).is_greater(initial)
			assert_bool(block.state.posture_locked).is_true()
			assert_float(block.state.speed_multiplier).is_zero()
			_verify_replay(block)
			assert_bool(_owner.prediction.state.on_floor).is_true()
			assert_int(_ear.jumps).is_equal(1)
			initial = block.modifier_generation
			break
	assert_bool(_owner.prediction.baseline.state.jump_allowed).is_false()
	for i in 6:
		_authority.actor.actor_elements.struggle()
	await _ticks(18)
	var thawed := _owner.prediction.baseline
	assert_int(thawed.modifier_generation).is_greater(initial)
	assert_bool(thawed.state.jump_allowed).is_true()
	assert_bool(thawed.state.posture_locked).is_false()
	_driver.tap = true
	await _ticks(1)
	assert_float(_owner.actor.position.y).is_greater(floor_y)
	assert_int(_ear.jumps).is_equal(2)


func test_stamina_gate_after_external_spend_and_sprint_exhaustion() -> void:
	await _ticks(45)
	_ear = AudioTest.Recorder.new(_owner)
	_authority.actor.stamina_attribute.value_current = 6.3
	var stamina := _authority.actor.stamina_attribute as CogitoStaminaAttribute
	stamina.run_exhaustion_speed = 8.0
	stamina.use_floor_slope_for_run_exhaustion = false
	await _ticks(12)
	_driver.walking = true
	_driver.held = 1 << ACTION.SPRINT
	await _ticks(10)
	assert_int(_owner.prediction.state.mode).is_equal(CogitoMovementState.Mode.SPRINTING)
	await _replay_after_spend()
	await _ticks(36)
	var tired := _owner.prediction.state.duplicate() as CogitoMovementState
	assert_float(tired.stamina).is_less(_owner.prediction.baseline.jump_cost)
	assert_int(tired.mode).is_equal(CogitoMovementState.Mode.WALKING)
	_driver.tap = true
	await _ticks(1)
	assert_bool(_owner.prediction.state.on_floor).is_true()
	_driver.held = 0
	_driver.walking = false
	await _ticks(150)
	assert_float(_owner.prediction.state.stamina).is_greater(tired.stamina)
	assert_int(_ear.jumps).is_zero()


func test_death_during_slide_jump_and_reused_node_respawn() -> void:
	await _ticks(45)
	_driver.walking = true
	_driver.held = 1 << ACTION.SPRINT
	await _ticks(25)
	_driver.held |= 1 << ACTION.CROUCH
	await _ticks(5)
	_driver.tap = true
	await _ticks(4)
	var actor := _owner.actor
	var old := _owner.latest_owner_baseline()
	var sequence := actor.last_consumed_sequence
	var prediction := _owner.prediction
	var id := _client.local_player_id()
	var server := _server.player_world
	assert_bool(_authority.actor.jumped_from_slide).is_true()
	_driver.held = 0
	_driver.walking = false
	actor.player_interaction_component.wieldables.primary_action_held = true
	server.death.die(_authority.actor)
	_pump()
	assert_bool(actor.is_dead).is_true()
	assert_bool(actor.player_interaction_component.wieldables.primary_action_held).is_false()
	assert_bool(prediction.active).is_false()
	assert_object(prediction.queued).is_null()
	assert_object(prediction.post_at(sequence)).is_null()
	assert_array(_channel._history).is_empty()
	assert_bool(_owner.movement_audio._previous.is_empty()).is_true()
	assert_vector(prediction.render_offset).is_equal(Vector3.ZERO)
	await _ticks(4)
	assert_int(actor.last_consumed_sequence).is_equal(sequence)
	assert_str(server.death.try_respawn(id, old.life)).is_empty()
	_pump()
	assert_object(_owner.actor).is_same(actor)
	assert_int(_owner.lifetime).is_greater(old.life)
	var fresh := _owner.latest_owner_baseline()
	_deliver(old)
	assert_object(_owner.latest_owner_baseline()).is_same(fresh)
	await _ticks(15)
	assert_bool(prediction.active).is_true()
	assert_bool(prediction.state.jumped_from_slide).is_false()
	assert_bool(prediction.state.jump_stopped and prediction.state.slide_stopped).is_true()
	assert_float(prediction.state.stamina).is_equal(_authority.actor.stamina_attribute.value_max)
	assert_int(prediction.baseline.ack).is_greater(sequence)


func test_moving_ledge_suspends_at_local_contact_before_revoking_pose() -> void:
	for branch in [_server, _client]:
		var level: Node = branch.player_world.active_level()
		var ledge := StaticBody3D.new()
		ledge.name = "MovingBank"
		ledge.constant_linear_velocity = Vector3.RIGHT * 0.1
		var hull := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(4, 1, 5)
		hull.shape = box
		ledge.add_child(hull)
		ledge.position = Vector3(0, 1.25, -4.3)
		level.add_child(ledge)
	await _ticks(40)
	_network[2].configure(1, 1, {"loss": 1.0})
	_driver.walking = true
	await _ticks(17)
	_driver.held = 1 << ACTION.JUMP
	for i in 48:
		await _ticks(1)
		if not _owner.prediction.active:
			break
	assert_str(_owner.prediction.reason).is_equal("moving_ledge")
	assert_object(_owner.prediction.baseline.state).is_not_null()
	assert_int(_owner.prediction._boundary_sequence).is_greater(_owner.prediction.baseline.ack)
	_driver.held = 0
	_driver.reverse = true
	_network[2].configure(1, 1, {"loss": 0.0})
	var saw_capture := false
	for i in 100:
		await _ticks(1)
		saw_capture = (
			saw_capture
			or (
				_authority.actor.current_moving_state
				== CogitoPlayerAdvanced.MovingState.LedgeClimbing
			)
		)
	assert_bool(saw_capture).is_true()
	assert_bool(_owner.prediction.active).is_true()


func test_slide_expiry_replays_across_last_timer_tick() -> void:
	await _ticks(45)
	_ear = AudioTest.Recorder.new(_owner)
	_network[2].configure(1, 1, {"delay_ms": 80})
	_driver.held = 1 << ACTION.SPRINT
	_driver.walking = true
	await _ticks(20)
	_driver.held |= 1 << ACTION.CROUCH
	await _ticks(87)
	assert_int(_owner.prediction.state.mode).is_equal(CogitoMovementState.Mode.SLIDING)
	await _replay_after_spend()
	var state := _owner.prediction.state
	assert_bool(state.slide_stopped).is_true()
	assert_int(state.mode).is_equal(CogitoMovementState.Mode.SNEAKING)
	assert_array(_ear.slides).contains_exactly([true, false])


func test_same_tick_climb_jump_off_and_restore() -> void:
	await _ticks(45)
	_ear = AudioTest.Recorder.new(_owner)
	await _stage_volume(Vector3(-10, 4, 0.2))
	var s := _owner.prediction.state
	assert_int(s.mode).is_equal(CogitoMovementState.Mode.LADDER_CLIMBING)
	assert_int(s.ladder_ticks).is_greater(0)
	_network[2].configure(1, 1, {"delay_ms": 65})
	var start := _owner.actor.position.y
	_driver.walking = true
	await _ticks(1)
	assert_float(_owner.actor.position.y - start).is_equal_approx(2.0 / 60, 0.00001)
	await _ticks(5)
	await _push_in_volume(CogitoMovementState.Mode.LADDER_CLIMBING)
	_driver.reverse = true
	start = _owner.actor.position.y
	await _ticks(1)
	assert_float(_owner.actor.position.y - start).is_equal_approx(-2.0 / 60, 0.00001)
	var push_tick := _server.player_world._tick
	_authority.actor.position.x += 0.30
	await _ticks(3)
	_driver.held = 1 << ACTION.JUMP
	await _ticks(1)
	var departure := _owner.actor.last_consumed_sequence
	assert_int(_owner.prediction.state.mode).is_equal(CogitoMovementState.Mode.JUMPING)
	assert_int(_ear.jumps).is_equal(1)
	_driver.held = 0
	var crossed := false
	for i in 10:
		var block := _owner.prediction.queued
		if block and block.state and block.tick > push_tick and block.ack < departure:
			assert_int(block.state.mode).is_equal(CogitoMovementState.Mode.LADDER_CLIMBING)
			assert_int(block.state.ladder_ticks).is_greater(0)
			_verify_replay(block)
			assert_bool(departure in _owner.prediction.last_replay).is_true()
			var post := _owner.prediction.post_at(departure)
			assert_int(post.mode).is_equal(CogitoMovementState.Mode.JUMPING)
			assert_bool(post.on_ladder).is_false()
			print("PR6 REPLAY jump-off sequence=", departure, " from ladder ack=", block.ack)
			crossed = true
			break
		await _ticks(1)
	assert_bool(crossed).is_true()
	await _replay_after_spend()
	assert_int(_ear.jumps).is_equal(1)


func test_same_tick_dive_and_restore_rise_to_surface() -> void:
	await _ticks(45)
	_ear = AudioTest.Recorder.new(_owner)
	await _stage_volume(Vector3(10, 9, 0))
	_network[2].configure(1, 1, {"delay_ms": 65})
	var start := _owner.actor.position.y
	var initial := _owner.prediction.state
	var profile := _owner.prediction.solver.profile
	var dt := 1.0 / _owner.prediction.baseline.rate
	var weight := dt * profile.lerp_speed
	var speed := lerpf(initial.current_speed, profile.swimming_speed, weight)
	var expected := lerpf(initial.main_velocity.y, -speed * initial.speed_multiplier, weight) * dt
	_driver.held = 1 << ACTION.CROUCH
	await _ticks(1)
	var dive_delta := _owner.actor.position.y - start
	assert_float(dive_delta).is_less(0)
	assert_float(dive_delta).is_equal_approx(expected, 0.000001)
	print("PR6 INPUT dive dy=", dive_delta, " expected=", expected)
	assert_int(_owner.prediction.state.mode).is_equal(CogitoMovementState.Mode.SWIMMING)
	assert_bool(_owner.prediction.state.submerged).is_true()
	await _ticks(8)
	await _push_in_volume(CogitoMovementState.Mode.SWIMMING)
	_driver.held = 1 << ACTION.JUMP
	await _ticks(125)
	assert_float(_owner.actor.position.y).is_greater(start)
	assert_bool(_owner.prediction.state.submerged).is_false()
	assert_float(absf(_owner.actor.velocity.y)).is_less(0.02)
	assert_int(_ear.strokes).is_greater(0)


func test_climb_and_swim_rubber_banding(_timeout := 45000) -> void:
	await _ticks(45)
	_network[2].drop_every_tenth_command = true
	for rtt: int in [0, 16, 100, 150]:
		for peer: int in [1, 2]:
			_network[peer].configure(3 - peer, 1, preload("packet_schedule.gd").profile(rtt))
		for swimming: bool in [false, true]:
			_driver.held = 0
			_driver.walking = false
			await _stage_volume(Vector3(10, 8, 0) if swimming else Vector3(-10, 4, 0.2))
			await _ticks(35)
			var mode := (
				CogitoMovementState.Mode.SWIMMING
				if swimming
				else CogitoMovementState.Mode.LADDER_CLIMBING
			)
			assert_int(_owner.prediction.state.mode).is_equal(mode)
			var samples: Array[float] = []
			var depth := 0
			var last_tick := -1
			var resets := 0
			var initial := _owner.prediction.reasons.duplicate()
			for i in 90:
				_driver.walking = not swimming
				_driver.reverse = i >= 45
				_driver.held = (1 << (ACTION.CROUCH if i < 45 else ACTION.JUMP)) if swimming else 0
				await _ticks(1)
				var prediction := _owner.prediction
				resets += int(not prediction.active)
				if last_tick != prediction.baseline.tick:
					last_tick = prediction.baseline.tick
					samples.append(prediction.last_position_error)
					if prediction.last_restore_tick == last_tick:
						depth = maxi(depth, prediction.last_replay.size())
			samples.sort()
			var p95 := samples[ceili(samples.size() * 0.95) - 1]
			print(
				"PR6 LANE ",
				"swim" if swimming else "ladder",
				" ",
				rtt,
				" ",
				JSON.stringify(
					{
						"p50": samples[samples.size() >> 1],
						"p95": p95,
						"max": samples.back(),
						"depth": depth,
						"resets": resets,
						"suspensions": _owner.prediction.reasons
					}
				)
			)
			assert_int(resets).is_zero()
			assert_dict(_owner.prediction.reasons).is_equal(initial)
			assert_float(p95).is_less_equal(0.02)


func test_swim_ledge_capture_stays_predicted() -> void:
	for branch in [_server, _client]:
		var bank := StaticBody3D.new()
		bank.name = "Bank"
		var hull := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(4, 1, 5)
		hull.shape = box
		bank.add_child(hull)
		bank.position = Vector3(10, 11.8, -6.4)
		branch.player_world.active_level().add_child(bank)
	await _ticks(40)
	await _stage_volume(Vector3(10, 11.3, 0))
	_network[2].configure(1, 1, {"delay_ms": 50})
	_driver.held = 1 << ACTION.JUMP
	_driver.walking = true
	var captured := false
	var predicted := false
	var reasons := _owner.prediction.reasons.duplicate()
	for i in 180:
		await _ticks(1)
		captured = (
			captured
			or _authority.actor.current_moving_state == CogitoMovementState.Mode.LEDGE_CLIMBING
		)
		assert_bool(_owner.prediction.active).is_true()
		predicted = (
			predicted or _owner.prediction.state.mode == CogitoMovementState.Mode.LEDGE_CLIMBING
		)
		if captured and predicted and _owner.prediction.state.mode == CogitoMovementState.Mode.IDLE:
			break
	assert_dict(_owner.prediction.reasons).is_equal(reasons)
	assert_bool(captured and predicted).is_true()
	assert_bool(_owner.prediction.active).is_true()
	assert_array(_entries).is_empty()


func test_live_volume_audio_edges_and_vertical_steps() -> void:
	await _ticks(40)
	_ear = AudioTest.Recorder.new(_owner)
	for branch in [_server, _client]:
		var pool: Area3D = branch.player_world.active_level().get_node("Pool")
		pool.position = Vector3(0, 1, 0)
		pool.force_update_transform()
	await _ticks(3)
	assert_int(_owner.prediction.state.mode).is_equal(CogitoMovementState.Mode.SWIMMING)
	assert_int(_ear.strokes).is_equal(1)
	for branch in [_server, _client]:
		var pool: Area3D = branch.player_world.active_level().get_node("Pool")
		pool.position = Vector3(10, 6, 0)
		pool.force_update_transform()
	await _ticks(5)
	assert_int(_ear.strokes).is_equal(2)
	await _stage_volume(Vector3(-10, 4, 0.2))
	_driver.walking = true
	var initial := _ear.feet.footsteps
	await _ticks(45)
	assert_int(_ear.feet.footsteps).is_greater(initial)
	assert_int(_ear.strokes).is_equal(2)

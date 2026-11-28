extends "prediction_session_suite.gd"

const Schedule := preload("packet_schedule.gd")


class RenderProbe:
	extends Node
	var camera: Camera3D
	var previous: float
	var backwards := 0
	var frames := 0

	func _process(_delta: float) -> void:
		var current := camera.global_position.z
		backwards += int(current > previous + 0.00001)
		previous = current
		frames += 1


func test_authority_push_while_turning_in_air() -> void:
	await _ticks(50)
	var rifle := _equip_rifle()
	var initial_charge := rifle.charge_current
	_network[1].configure(2, 1, {"delay_ms": 50})
	_driver.walking = true
	_driver.turn = 0.025
	for i in 25:
		await _ticks(1)
		if _ear.feet.footsteps:
			break
	assert_int(_ear.feet.footsteps).is_equal(1)
	_driver.tap = true
	await _ticks(9)
	_authority.actor.position.x += 0.30
	var pushed := _server.player_world._tick
	for i in 12:
		await _ticks(1)
		var block := _owner.prediction.queued
		if block and block.tick > pushed:
			assert_bool(block.state.on_floor).is_false()
			_verify_replay(block)
			break
	assert_int(_owner.prediction.last_restore_tick).is_greater(pushed)
	assert_int(_ear.jumps).is_equal(1)
	assert_int(_ear.feet.footsteps).is_equal(1)
	assert_int(_shots).is_equal(1)
	assert_float(rifle.charge_current).is_equal(initial_charge - 1)
	var offset := _owner.prediction.render_offset.length()
	assert_float(offset).is_between(0.249, 0.250001)
	_owner.present(0.25)
	assert_float(_owner.prediction.render_offset.length()).is_less(0.01)
	print("PR3 DECAY ", offset, " -> ", _owner.prediction.render_offset.length())
	_driver.walking = false
	_driver.turn = 0
	await _ticks(100)
	_assert_rest()


func test_server_lock_rejects_predicted_jump() -> void:
	await _ticks(50)
	var rifle := _equip_rifle()
	var initial_charge := rifle.charge_current
	_network[1].configure(2, 1, {"delay_ms": 65})
	_authority.actor.network_input_blocked = true
	_driver.tap = true
	var start := _owner.actor.position.y
	await _ticks(1)
	assert_float(_owner.actor.position.y).is_greater(start)
	for i in 12:
		await _ticks(1)
		var block := _owner.prediction.queued
		if block and block.input_blocked:
			var pending := _owner.wield._pending_sequence
			assert_int(pending).is_greater_equal(0)
			var stale := _owner.timeline.latest().duplicate()
			var stale_block := NetOwnerState.decode(NetOwnerState.encode(block))
			stale_block.ack = pending
			stale.ack = pending
			stale.owner_state = NetOwnerState.encode(stale_block)
			_client.player_world._receive_pose(_client.local_player_id(), block.life, stale)
			assert_int(_owner.wield._pending_sequence).is_equal(pending)
			_verify_replay(block)
			assert_int(_ear.jumps).is_equal(1)
			assert_int(_shots).is_equal(1)
			assert_float(rifle.charge_current).is_equal(initial_charge)
			await _ticks(1)
			_assert_rest()
			return
	fail("No authority lock checkpoint")


func test_all_four_copies_of_jump_lost_and_history_recovers() -> void:
	await _ticks(50)
	_channel.mute = 4
	_driver.tap = true
	var start := _owner.actor.position.y
	await _ticks(1)
	assert_float(_owner.actor.position.y).is_greater(start)
	var tap := _owner.actor.last_consumed_sequence
	var peak := _authority.actor.position.y
	for i in 24:
		await _ticks(1)
		peak = maxf(peak, _authority.actor.position.y)
	assert_float(peak).is_equal_approx(start, 0.001)
	assert_int(_owner.latest_owner_baseline().ack).is_greater(tap)
	assert_int(_owner.latest_owner_baseline().discontinuities).is_greater(0)
	_assert_rest()
	_network[2].configure(1, 1, {"loss": 1.0})
	await _ticks(140)
	assert_str(_owner.prediction.reason).is_equal("missing_history")
	assert_bool(_owner.prediction.active).is_false()
	_network[2].configure(1, 1, {"loss": 0.0})
	await _ticks(10)
	assert_bool(_owner.prediction.active).is_true()
	_assert_rest()


func test_rubber_banding_profiles(_timeout := 30000) -> void:
	_network[2].drop_every_tenth_command = true
	for rtt: int in [0, 16, 100, 150]:
		for peer: int in [1, 2]:
			_network[peer].configure(3 - peer, 1, Schedule.profile(rtt))
		await _ticks(60)
		_driver.walking = true
		var samples: Array[float] = []
		var render := RenderProbe.new()
		render.camera = _owner.actor.camera
		render.previous = render.camera.global_position.z
		render.process_priority = 101
		_client.add_child(render)
		var depth := 0
		var resets := 0
		var last_tick := -1
		for i in 90:
			await _ticks(1)
			var prediction := _owner.prediction
			resets += int(not prediction.active)
			if prediction.baseline.tick != last_tick:
				last_tick = prediction.baseline.tick
				samples.append(prediction.last_position_error)
				if prediction.last_restore_tick == last_tick:
					depth = maxi(depth, prediction.last_replay.size())
		assert_int(render.frames).is_greater(0)
		var backwards := render.backwards
		render.free()
		samples.sort()
		var p95 := samples[ceili(samples.size() * 0.95) - 1]
		print(
			"PR3 LANE ",
			rtt,
			" ",
			JSON.stringify(
				{
					"p50": samples[samples.size() >> 1],
					"p95": p95,
					"max": samples.back(),
					"depth": depth,
					"resets": resets,
					"back": backwards
				}
			)
		)
		assert_int(resets).is_zero()
		assert_int(backwards).is_zero()
		assert_float(p95).is_less_equal(0.02)
		_driver.walking = false
		await _ticks(70)
		_assert_rest()


func test_held_ack_expiry_budget_and_resume() -> void:
	await _ticks(45)
	_driver.walking = true
	await _ticks(12)
	_channel.mute = 42
	var held: NetOwnerState = null
	var moving_hold := false
	var neutral := false
	var expiry := -1
	for i in 40:
		await _ticks(1)
		var source := _authority.source
		if source.disposition == NetOwnerState.Disposition.NEUTRAL and expiry < 0:
			expiry = source._tick - source._last_arrival
		var block := _owner.prediction.baseline
		if block.disposition == NetOwnerState.Disposition.HELD:
			if held and held.tick != block.tick:
				assert_int(block.ack).is_equal(held.ack)
				moving_hold = held.state.transform.origin != block.state.transform.origin
				assert_int(_owner.prediction.last_restore_tick).is_equal(block.tick)
			held = block
		elif block.disposition == NetOwnerState.Disposition.NEUTRAL and held:
			neutral = true
			assert_int(block.ack).is_equal(held.ack)
	assert_bool(moving_hold).is_true()
	assert_bool(neutral).is_true()
	assert_int(expiry).is_equal(12)
	assert_str(_owner.prediction.reason).is_equal("replay_budget")
	assert_bool(_owner.prediction.active).is_false()
	assert_vector(_owner.prediction.render_offset).is_equal(Vector3.ZERO)
	_driver.walking = false
	await _ticks(20)
	assert_bool(_owner.prediction.active).is_true()
	assert_int(_owner.prediction.reasons.replay_budget).is_equal(1)


func test_scope_ack_checks_and_coalescing_across_wire_wrap() -> void:
	await _ticks(50)
	var prediction := _owner.prediction
	var base := 0xfffffffc
	_owner.actor.last_consumed_sequence = base
	prediction.reset()
	var block := NetOwnerState.decode(NetOwnerState.encode(_owner.latest_owner_baseline()))
	block.tick += 1
	block.last_fresh_tick = block.tick
	block.disposition = NetOwnerState.Disposition.FRESH
	block.ack = base
	_deliver(block)
	prediction.begin_tick()
	for seq in range(base + 1, base + 9):
		var cmd := _owner.actor.neutral_command(seq)
		cmd.move = Vector2.UP
		prediction.live(cmd)
		cmd.move = Vector2.DOWN
	block.ack = base + 3
	block.tick += 1
	block.last_fresh_tick = block.tick
	_deliver(block)
	block.tick += 1
	block.disposition = NetOwnerState.Disposition.HELD
	block.discontinuities += 1
	_deliver(block)
	prediction.begin_tick()
	assert_int(prediction.last_restore_tick).is_equal(block.tick)
	assert_array(prediction.last_replay).contains_exactly(range(base + 4, base + 9))
	assert_float(prediction.state.transform.origin.z).is_less(block.state.transform.origin.z)
	block.tick += 1
	block.ack = base + 100
	_deliver(block)
	prediction.begin_tick()
	assert_str(prediction.reason).is_equal("impossible_ack")
	block.tick += 1
	block.ack = base + 7
	_deliver(block)
	prediction.begin_tick()
	assert_bool(prediction.active).is_true()
	assert_array(prediction.last_replay).contains_exactly([base + 8])


func test_client_dynamic_obstruction() -> void:
	await _ticks(50)
	var obstacle := AnimatableBody3D.new()
	obstacle.collision_layer = 32
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2, 3, 0.1)
	collider.shape = box
	obstacle.add_child(collider)
	obstacle.position = _owner.actor.position + Vector3.FORWARD * 0.6
	var placed := obstacle.position
	_client.player_world.active_level().add_child(obstacle)
	_driver.walking = true
	for i in 20:
		await _ticks(1)
		if not _owner.prediction.active:
			break
	assert_str(_owner.prediction.reason).is_equal("unsupported_contact")
	assert_vector(obstacle.position).is_equal(placed)
	obstacle.free()
	await _ticks(15)
	assert_bool(_owner.prediction.active).is_true()
	assert_int(_owner.actor.collision_layer | _owner.actor.collision_mask).is_zero()


func test_camera_clearance_and_simulation_rays() -> void:
	await _ticks(50)
	var actor := _owner.actor
	var prediction := _owner.prediction
	var pic := actor.player_interaction_component
	var aim := actor.get_aim_transform()
	var ceiling := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2, 0.02, 2)
	collider.shape = box
	ceiling.add_child(collider)
	ceiling.position = aim.origin + Vector3.UP * 0.12
	_client.player_world.active_level().add_child(ceiling)
	await _ticks(1)
	aim = actor.get_aim_transform()
	var marker := pic.carryable_position.global_position
	var socket := pic.wieldable_container.global_position
	ceiling.position = aim.origin + Vector3.UP * 0.12
	ceiling.force_update_transform()
	prediction.render_offset = Vector3.UP * 0.25
	prediction._clip_offset()
	prediction.render(0)
	assert_float(prediction.render_offset.length()).is_between(0.001, 0.11)
	var visual := actor.camera.global_position - aim.origin
	assert_vector(visual).is_equal_approx(prediction.render_offset, Vector3.ONE * 0.00001)
	assert_vector(pic.wieldable_container.global_position - socket).is_equal_approx(
		visual, Vector3.ONE * 0.00001
	)
	assert_that(actor.get_aim_transform()).is_equal(aim)
	assert_vector(pic.interaction_raycast.global_position).is_equal(aim.origin)
	assert_vector(pic.carryable_position.global_position).is_equal(marker)
	ceiling.position = aim.origin
	ceiling.force_update_transform()
	prediction._clip_offset()
	assert_vector(prediction.render_offset).is_equal(Vector3.ZERO)


func test_unmarked_push_at_rest_converges_by_second_pose() -> void:
	await _ticks(45)
	var first_tick := _server.player_world._tick
	_authority.actor.position.x += 0.3
	var arrived := 0
	var latest := first_tick
	for i in 8:
		await _ticks(1)
		var tick := _owner.prediction.baseline.tick
		if tick > latest:
			arrived += 1
			latest = tick
		if arrived == 2:
			break
	assert_int(arrived).is_equal(2)
	_assert_rest()


func test_matched_ack_thresholds_and_discrete_state() -> void:
	await _ticks(45)
	var prediction := _owner.prediction
	var block := NetOwnerState.decode(NetOwnerState.encode(prediction.baseline))
	var post := block.state.duplicate() as CogitoMovementState
	block.disposition = NetOwnerState.Disposition.FRESH
	post.transform.origin.x += 0.019
	post.velocity.x += 0.099
	post.head_position.y += 0.009
	prediction.last_position_error = post.transform.origin.distance_to(block.state.transform.origin)
	assert_bool(prediction._matches(block, block, post)).is_true()
	post.head_position.y += 0.002
	assert_bool(prediction._matches(block, block, post)).is_false()
	post.head_position = block.state.head_position
	post.velocity.x += 0.002
	assert_bool(prediction._matches(block, block, post)).is_false()
	post.velocity = block.state.velocity
	prediction.last_position_error = 0.021
	assert_bool(prediction._matches(block, block, post)).is_false()
	prediction.last_position_error = 0.0
	for key: String in NetOwnerState.FLAGS:
		post.set(key, not block.state.get(key))
		assert_bool(prediction._matches(block, block, post)).is_false()
		post.set(key, block.state.get(key))
	for key: String in NetOwnerState.TIMERS:
		post.set(key, block.state.get(key) + 0.000001)
		assert_bool(prediction._matches(block, block, post)).is_false()
		post.set(key, block.state.get(key))


func test_forced_revision_and_life_clear_history_preserve_watermark() -> void:
	await _ticks(45)
	var prediction := _owner.prediction
	var seq := _owner.actor.last_consumed_sequence
	assert_object(prediction.post_at(seq)).is_not_null()
	assert_bool(_channel._history.is_empty()).is_false()
	var revision := _owner.revision
	_server.player_world.mark_teleport(_client.local_player_id())
	for i in 6:
		await _ticks(1)
		if _owner.revision != revision:
			break
	assert_int(_owner.revision).is_greater(revision)
	assert_array(_channel._history).is_empty()
	assert_object(prediction.post_at(seq)).is_null()
	assert_object(prediction.state).is_null()
	assert_vector(prediction.render_offset).is_equal(Vector3.ZERO)
	assert_int(prediction.newest).is_equal(_owner.actor.last_consumed_sequence)
	await _ticks(8)
	assert_bool(prediction.active).is_true()
	var life := _owner.lifetime
	seq = _owner.actor.last_consumed_sequence
	_server.player_world.renew_life(_client.local_player_id())
	_pump()
	assert_int(_owner.lifetime).is_greater(life)
	assert_array(_channel._history).is_empty()
	assert_object(prediction.post_at(seq)).is_null()
	assert_object(prediction.state).is_null()
	assert_int(prediction.newest).is_equal(seq)
	await _ticks(10)
	assert_bool(prediction.active).is_true()
	assert_int(_owner.latest_owner_baseline().ack).is_greater(seq)


func test_duplicate_and_reordered_poses_and_commands() -> void:
	await _ticks(45)
	var options := {"delay_ms": 36, "jitter_ms": 27, "dup": 1.0, "seed": 31}
	_network[1].configure(2, 1, options)
	_network[2].configure(1, 1, options)
	_equip_rifle()
	_driver.tap = true
	var tick := _owner.latest_owner_baseline().tick
	var ack := _owner.latest_owner_baseline().ack
	var jumps := 0
	var previous_mode := _authority.actor.current_moving_state
	for i in 90:
		await _ticks(1)
		var mode := _authority.actor.current_moving_state
		jumps += int(mode != previous_mode and mode == CogitoPlayerAdvanced.MovingState.Jumping)
		previous_mode = mode
		var block := _owner.latest_owner_baseline()
		assert_int(block.tick).is_greater_equal(tick)
		assert_int(block.ack).is_greater_equal(ack)
		tick = block.tick
		ack = block.ack
	assert_int(jumps).is_equal(1)
	assert_int(_ear.jumps).is_equal(1)
	assert_int(_shots).is_equal(1)
	_assert_rest()

extends "prediction_session_suite.gd"
## The validator portion of each Godot 4 ObjectID increments at construction.
## Two sentinels on the same synchronous call stack also see short-lived objects.


func _serial() -> int:
	var marker := RefCounted.new()
	return (marker.get_instance_id() >> 24) & 0x7fffffffff


func test_steady_walk_twelve_command_replay_and_authority_allocations() -> void:
	_driver.walking = true
	await _ticks(45)
	var prediction := _owner.prediction
	var block := NetOwnerState.decode(NetOwnerState.encode(prediction.baseline))
	var command := CogitoPlayerCommand.new()
	command.move = Vector2.UP
	command.sequence = prediction.newest + 1
	var serial := _serial()
	OS.get_environment("PR6_BEGIN_MATH_PROFILE")
	prediction.live(command)
	OS.get_environment("PR6_END_MATH_PROFILE")
	var live := _serial() - serial - 1
	# Preserve twelve unacknowledged commands and force a restore on their preceding post.
	block.ack = prediction.newest
	block.state = prediction.state.duplicate()
	block.state.transform.origin.x += 0.05
	for i in 12:
		command.sequence += 1
		prediction.live(command)
	prediction.queued = block
	serial = _serial()
	OS.get_environment("PR6_BEGIN_MATH_PROFILE")
	prediction.begin_tick()
	OS.get_environment("PR6_END_MATH_PROFILE")
	var replay := _serial() - serial - 1
	var kernel := _authority.actor.authority_movement
	var solved := kernel.solves
	serial = _serial()
	OS.get_environment("PR6_BEGIN_MATH_PROFILE")
	kernel.advance(_authority.actor, 1.0 / 60)
	OS.get_environment("PR6_END_MATH_PROFILE")
	var authority := _serial() - serial - 1
	print("PR9 OBJECTS walk=", live, " replay12=", replay, " kernel=", authority)
	assert_int(prediction.last_replay.size()).is_equal(12)
	assert_int(kernel.solves).is_equal(solved + 1)
	assert_int(live).is_zero()
	assert_int(replay).is_zero()
	assert_int(authority).is_zero()


func test_local_sample_and_command_receive_reuse_while_preserving_held_records() -> void:
	await _ticks(45)
	var actor := _owner.actor
	var one := actor.neutral_command(400)
	var two := actor.neutral_command(401)
	assert_int(one.sequence).is_equal(400)
	assert_int(two.sequence).is_equal(401)
	one = null
	two = null
	_driver.commands.clear()
	var source := preload("res://addons/cogito/Networking/net_input_source.gd").new()
	var channel := Channel.new()
	var serial := _serial()
	for i in 32:
		var command := actor.neutral_command(i)
		command.move = Vector2.UP
		source.receive(channel.packet(command))
		source.sample(null, i)
	assert_int(_serial() - serial - 1).is_zero()
	assert_int(source.last_fresh_sequence).is_greater(28)

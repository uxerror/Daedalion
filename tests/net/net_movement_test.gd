extends GdUnitTestSuite

const CHANNEL := preload("res://addons/cogito/Networking/net_command_channel.gd")
const SOURCE := preload("res://addons/cogito/Networking/net_input_source.gd")
const SNAPSHOT := preload("res://addons/cogito/Networking/net_snapshot.gd")


func _command(seq: int) -> CogitoPlayerCommand:
	var command := CogitoPlayerCommand.new()
	command.sequence = seq
	command.move = Vector2(2, 0)
	command.pitch = 10.0
	command.held = 1 << CogitoPlayerCommand.Action.INTERACT
	command.add_edge(CogitoPlayerCommand.Action.JUMP)
	command.add_edge(CogitoPlayerCommand.Action.INTERACT)
	return command


func test_redundancy_clamps_and_filters_actions() -> void:
	var channel := CHANNEL.new()
	var packet := PackedByteArray()
	for seq in 6:
		packet = channel.packet(_command(seq))
	packet.encode_float(5, 20.0)  # Forged wire axis bypasses the local command setter.
	var frames := CHANNEL.decode(packet)
	assert_int(frames.size()).is_equal(4)
	for index in frames.size():
		assert_int(frames[index].sequence).is_equal(index + 2)
		assert_vector(frames[index].move).is_equal(Vector2.RIGHT)
		assert_float(frames[index].pitch).is_equal(PI / 2)
		assert_int(frames[index].held).is_zero()
		assert_int(frames[index].edges.size()).is_equal(1)
		assert_int(frames[index].edges[0]).is_equal(CogitoPlayerCommand.Action.JUMP)
	assert_array(CHANNEL.decode(packet.slice(0, -1))).is_empty()
	packet.encode_float(13, NAN)
	assert_array(CHANNEL.decode(packet)).is_empty()


func test_order_duplicates_missing_and_stale() -> void:
	var source := SOURCE.new()
	for seq: int in [1, 0, 1, 3]:
		source.receive(CHANNEL.new().packet(_command(seq)))
	assert_object(source.sample(null, 0)).is_null()
	assert_int(source.sample(null, 0).sequence).is_zero()
	assert_int(source.sample(null, 0).sequence).is_equal(1)
	assert_int(source.sample(null, 0).sequence).is_equal(3)
	source.receive(CHANNEL.new().packet(_command(2)))
	assert_int(source.sample(null, 0).sequence).is_equal(3)
	for tick in SOURCE.STALE_TICKS:
		source.sample(null, 0)
	assert_object(source.sample(null, 0)).is_null()


func test_packet_budget_and_sequence_wrap() -> void:
	var source := SOURCE.new()
	for seq in 5:
		source.receive(CHANNEL.new().packet(_command(seq)))
	for tick in 6:
		source.sample(null, 0)
	assert_int(source.sample(null, 0).sequence).is_equal(3)
	assert_int(SOURCE.unwrap(0, 0xffffffff)).is_equal(0x100000000)
	assert_int(SOURCE.unwrap(0xffffffff, 0x100000001)).is_equal(0xffffffff)


func _frame(tick: int, x: float) -> Dictionary:
	return {
		"tick": tick,
		"revision": 0,
		"position": Vector3.RIGHT * x,
		"velocity": Vector3.RIGHT,
		"yaw": 0,
		"neck": 0,
		"pitch": 0,
		"height": 0,
		"sitting": false,
	}


func test_interpolation_extrapolation_and_discontinuities() -> void:
	var timeline := SNAPSHOT.new()
	assert_int(timeline.push(_frame(40, 1))).is_equal(SNAPSHOT.Acceptance.RESET)
	assert_int(timeline.push(_frame(50, 2))).is_equal(SNAPSHOT.Acceptance.ACCEPTED)
	assert_vector(timeline.at_tick(45, 60).position).is_equal(Vector3.RIGHT * 1.5)
	assert_vector(timeline.at_tick(200, 60).position).is_equal(Vector3.RIGHT * 2.05)
	assert_int(timeline.push(_frame(49, 100))).is_equal(SNAPSHOT.Acceptance.REJECTED)
	assert_int(timeline.push(_frame(51, 100))).is_equal(SNAPSHOT.Acceptance.RESET)
	assert_vector(timeline.at_tick(40, 60).position).is_equal(Vector3.RIGHT * 100)
	var forced := _frame(52, 101)
	forced.revision = 1
	assert_int(timeline.push(forced)).is_equal(SNAPSHOT.Acceptance.RESET)


func test_wield_command_has_generation_and_rejects_forged_aim() -> void:
	var cmd := CogitoPlayerCommand.new()
	cmd.wield_generation = 17
	cmd.held = 1 << CogitoPlayerCommand.Action.PRIMARY
	cmd.add_edge(CogitoPlayerCommand.Action.RELOAD)
	var packet := CHANNEL.new().packet(cmd)
	var frame := CHANNEL.decode(packet)[0]
	assert_int(frame.wield_generation).is_equal(17)
	assert_int(frame.held).is_equal(cmd.held)
	assert_int(frame.edges[0]).is_equal(CogitoPlayerCommand.Action.RELOAD)
	for offset in [13, 17, 21]:
		var forged := packet.duplicate()
		forged.encode_float(offset, 20.0)
		assert_array(CHANNEL.decode(forged)).is_empty()


func test_alignment_apply_hold_skip_expire_and_wrap() -> void:
	var source := SOURCE.new()
	source.receive(CHANNEL.new().packet(_command(40)))
	assert_object(source.sample(null, 0)).is_null()
	source.sample(null, 0)
	assert_int(source.last_fresh_sequence).is_equal(40)
	assert_int(source.last_fresh_tick).is_equal(2)
	assert_int(source.disposition).is_equal(SOURCE.DISPOSITION.FRESH)
	source.sample(null, 0)
	assert_int(source.last_fresh_sequence).is_equal(40)
	assert_int(source.last_fresh_tick).is_equal(2)
	assert_int(source.disposition).is_equal(SOURCE.DISPOSITION.HELD)
	assert_int(source.discontinuities).is_equal(1)
	source.receive(CHANNEL.new().packet(_command(42)))
	source.sample(null, 0)
	source.sample(null, 0)
	assert_int(source.last_fresh_sequence).is_equal(42)
	assert_int(source.disposition).is_equal(SOURCE.DISPOSITION.GAP)
	assert_int(source.discontinuities).is_equal(2)
	source.clear()
	assert_int(source.disposition).is_equal(SOURCE.DISPOSITION.GAP)
	assert_int(source.last_fresh_tick).is_equal(5)
	source.receive(CHANNEL.new().packet(_command(41)))
	for i in SOURCE.STALE_TICKS:
		source.sample(null, 0)
	assert_int(source.disposition).is_equal(SOURCE.DISPOSITION.NEUTRAL)
	assert_int(source.last_fresh_sequence).is_equal(42)
	assert_int(source.last_fresh_tick).is_equal(5)
	for base: int in [0x7fffffff, 0xffffffff]:
		var wrapped := SOURCE.new()
		wrapped._ack = base - 1
		wrapped.receive(CHANNEL.new().packet(_command(base)))
		wrapped.receive(CHANNEL.new().packet(_command(base + 1)))
		for i in 3:
			wrapped.sample(null, 0)
		assert_int(wrapped.last_fresh_sequence).is_equal(base + 1)
		assert_int(wrapped.discontinuities).is_zero()
	assert_int(SOURCE.unwrap(0x80000000, 0)).is_equal(-0x80000000)

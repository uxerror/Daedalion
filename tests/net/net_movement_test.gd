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
	assert_bool(timeline.push(_frame(40, 1))).is_true()
	assert_bool(timeline.push(_frame(50, 2))).is_false()
	assert_vector(timeline.at_tick(45, 60).position).is_equal(Vector3.RIGHT * 1.5)
	assert_vector(timeline.at_tick(200, 60).position).is_equal(Vector3.RIGHT * 2.05)
	assert_bool(timeline.push(_frame(49, 100))).is_false()
	assert_bool(timeline.push(_frame(51, 100))).is_true()
	assert_vector(timeline.at_tick(40, 60).position).is_equal(Vector3.RIGHT * 100)
	var forced := _frame(52, 101)
	forced.revision = 1
	assert_bool(timeline.push(forced)).is_true()

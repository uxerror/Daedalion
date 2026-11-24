extends GdUnitTestSuite


func test_codec_preserves_aim_held_and_ordered_edges() -> void:
	var command := CogitoPlayerCommand.new()
	command.sequence = 1234567
	command.move = Vector2(3.0, -4.0)
	command.yaw = -1.25
	command.pitch = 0.875
	command.neck_yaw = 0.25
	command.toggle_crouch = true
	command.held = (
		(1 << CogitoPlayerCommand.Action.SPRINT) | (1 << CogitoPlayerCommand.Action.PRIMARY)
	)
	command.add_edge(CogitoPlayerCommand.Action.PRIMARY)
	command.add_edge(CogitoPlayerCommand.Action.PRIMARY, false)
	command.add_edge(CogitoPlayerCommand.Action.PRIMARY)
	var data := command.encode()
	assert_int(data.size()).is_equal(31)
	var copy := CogitoPlayerCommand.decode(data)
	assert_vector(copy.move).is_equal_approx(Vector2(0.6, -0.8), Vector2.ONE * 0.00001)
	assert_float(copy.yaw).is_equal(command.yaw)
	assert_float(copy.pitch).is_equal(command.pitch)
	assert_float(copy.neck_yaw).is_equal(command.neck_yaw)
	assert_int(copy.sequence).is_equal(command.sequence)
	assert_int(copy.held).is_equal(command.held)
	assert_bool(copy.toggle_crouch).is_true()
	assert_that(copy.edges).is_equal(command.edges)


func test_codec_rejects_invalid_input() -> void:
	assert_object(CogitoPlayerCommand.decode(PackedByteArray())).is_null()
	var data := CogitoPlayerCommand.new().encode()
	data.append(127)
	assert_object(CogitoPlayerCommand.decode(data)).is_null()
	data.resize(CogitoPlayerCommand.HEADER_SIZE)
	data.encode_float(4, NAN)
	assert_object(CogitoPlayerCommand.decode(data)).is_null()


func test_suppressed_frame_retains_look_without_buttons() -> void:
	var command := CogitoPlayerCommand.new()
	command.has_control = false
	command.yaw = -2.5
	var decoded := CogitoPlayerCommand.decode(command.encode())
	assert_bool(decoded.has_control).is_false()
	assert_float(decoded.yaw).is_equal(command.yaw)
	assert_vector(decoded.move).is_equal(Vector2.ZERO)
	assert_int(decoded.held).is_equal(0)

extends GdUnitTestSuite

const Codec := preload("res://addons/cogito/Networking/net_owner_state.gd")


func _block() -> NetOwnerState:
	var block := Codec.new()
	block.binding = 13
	block.life = 5
	block.revision = 3
	block.generation = 19
	block.tick = 600
	block.ack = 0x100000004
	block.last_fresh_tick = 598
	block.disposition = Codec.Disposition.HELD
	block.discontinuities = 7
	block.rate = 120
	return block


func test_legacy_alignment_and_framing() -> void:
	var block := _block()
	var wire := Codec.encode(block)
	assert_int(wire.size()).is_equal(Codec.HEADER_BYTES)
	var copy := Codec.decode(wire)
	assert_object(copy).is_not_null()
	assert_object(copy.state).is_null()
	for field: String in Codec.ALIGNMENT + ["disposition", "rate"]:
		assert_int(copy.get(field)).is_equal(block.get(field))
	assert_object(Codec.decode(wire.slice(0, -1))).is_null()
	assert_object(Codec.decode(wire + PackedByteArray([0]))).is_null()
	wire[0] += 1
	assert_object(Codec.decode(wire)).is_null()


func _fill(s: CogitoMovementState, invert: bool) -> Array[String]:
	var fields: Array[String] = []
	for prop: Dictionary in s.get_property_list():
		if not (
			prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and prop.usage & PROPERTY_USAGE_STORAGE
		):
			continue
		var key: String = prop.name
		fields.append(key)
		var n := fields.size()
		match prop.type:
			TYPE_BOOL:
				s.set(key, (n % 2 == 0) != invert)
			TYPE_INT:
				s.set(key, 2)
			TYPE_FLOAT:
				s.set(key, 0.147 * n)
			TYPE_VECTOR2:
				s.set(key, Vector2(n, -n))
			TYPE_VECTOR3:
				s.set(key, Vector3(n, 1.25, -n))
			TYPE_BASIS:
				s.set(key, Basis(Vector3.UP, 0.7))
			TYPE_TRANSFORM3D:
				s.set(key, Transform3D(Basis(Vector3.RIGHT, 0.3), Vector3(-123456.75, 12, n)))
			_:
				fail("Unhandled checkpoint field " + key)
	return fields


func test_every_stored_field_and_adapter_latch_round_trips() -> void:
	for invert: bool in [false, true]:
		var block := _block()
		block.state = CogitoMovementState.new()
		var fields := _fill(block.state, invert)
		block.pending_force = Vector3(5, -3, 4)
		block.teleported = invert
		block.force_requested = not invert
		block.stamina_locked = invert
		block.input_blocked = not invert
		block.use_floor_slope_for_run_exhaustion = not invert
		for i in Codec.STAMINA_TUNING.size():
			block.set(Codec.STAMINA_TUNING[i], 0.123 + i)
		var wire := Codec.encode(block)
		assert_int(wire.size()).is_equal(Codec.ELIGIBLE_BYTES)
		var copy := Codec.decode(wire)
		assert_object(copy).is_not_null()
		for key in fields:
			var expected: Variant = block.state.get(key)
			if expected is float:
				assert_float(copy.state.get(key)).is_equal_approx(expected, 1e-12)
			else:
				assert_that(copy.state.get(key)).is_equal(expected)
		assert_vector(copy.pending_force).is_equal(block.pending_force)
		for key: String in Codec.STAMINA_TUNING:
			assert_float(copy.get(key)).is_equal(block.get(key))
		assert_bool(copy.input_blocked).is_equal(not invert)
		assert_bool(copy.stamina_locked).is_equal(invert)
		assert_bool(copy.use_floor_slope_for_run_exhaustion).is_equal(not invert)
		assert_bool(copy.teleported).is_equal(invert)
		assert_bool(copy.force_requested).is_equal(not invert)
		assert_object(Codec.decode(wire.slice(0, -1))).is_null()
		assert_object(Codec.decode(wire + PackedByteArray([0]))).is_null()
		wire.encode_double(wire.size() - 8, NAN)
		assert_object(Codec.decode(wire)).is_null()

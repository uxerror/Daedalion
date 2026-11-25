extends "memory_session_suite.gd"

const BODIES := preload("res://addons/cogito/Networking/net_bodies.gd")


func test_interest_batches_reliable_rest_then_silence_and_reentry() -> void:
	var stream := BODIES.new()
	auto_free(stream)
	var pose := Transform3D.IDENTITY
	var samples := {"box": [pose, Vector3.RIGHT, Vector3.UP, false, true]}
	samples["other"] = samples.box.duplicate()
	var first := stream.batch_for(2, Vector3.ZERO, samples)
	assert_int(first.rows.size()).is_equal(2)
	assert_bool(first.reliable).is_true()
	assert_bool(stream.batch_for(2, Vector3.ZERO, samples).reliable).is_false()
	assert_bool(stream.batch_for(3, Vector3.ZERO, samples).reliable).is_true()
	samples.box[3] = true
	assert_bool(stream.batch_for(2, Vector3.ZERO, samples).reliable).is_true()
	assert_int(stream.batch_for(2, Vector3.ZERO, samples).rows.size()).is_equal(1)
	samples.box[3] = false
	assert_int(stream.batch_for(2, Vector3.ZERO, samples).rows.size()).is_equal(2)
	assert_array(stream.batch_for(2, Vector3.RIGHT * 120, samples).rows).is_empty()
	pose.origin = Vector3.RIGHT * 10
	samples.box = [pose, Vector3.ZERO, Vector3.ZERO, true, true]
	var reentry := stream.batch_for(2, pose.origin, samples)
	assert_bool(reentry.reliable).is_true()
	assert_that(reentry.rows[0][1]).is_equal(pose)


func _float_level(branch: Facade) -> FloatableBody3D:
	var host := CogitoLevelHost.new()
	branch.add_child(host)
	var root := host.load_level("res://tests/player/movement_level.tscn", &"pool")
	var body := FloatableBody3D.new()
	body.name = "Float"
	body.position = Vector3(4, 3, 0)
	body.gravity_scale = 0
	root.add_child(body)
	branch.player_world.bind_level(root, Transform3D.IDENTITY, "pool")
	return body


func test_float_authority_and_sleeping_late_join() -> void:
	var server := _branch(1)
	assert_int(server.start_server({"save_dir": create_temp_dir("float")})).is_equal(OK)
	var body := _float_level(server)
	body.global_position = Vector3(5, 2, 1)
	body.sleeping = true
	var client := _branch(2)
	assert_int(client.join("memory", 2302)).is_equal(OK)
	var copy := _float_level(client)
	await _ticks(10)
	assert_bool(body.freeze).is_false()
	assert_bool(body.is_physics_processing()).is_true()
	assert_bool(copy.freeze).is_true()
	assert_int(copy.freeze_mode).is_equal(RigidBody3D.FREEZE_MODE_KINEMATIC)
	assert_bool(copy.is_physics_processing()).is_false()
	assert_vector(copy.global_position).is_equal(body.global_position)


func test_reentry_and_fluid_force_over_memory_transport() -> void:
	var server := _branch(1)
	server.start_server({"save_dir": create_temp_dir("interest")})
	var body := _float_level(server)
	var client := _branch(2)
	client.join("memory", 2502)
	var copy := _float_level(client)
	await _ticks(12)
	var actor := server.player_world.avatar_for(client.local_player_id()).actor
	actor.position.x += 140
	await _ticks(5)
	var away := copy.global_transform
	body.global_position += Vector3.RIGHT * 2
	body.sleeping = true
	await _ticks(8)
	assert_that(copy.global_transform).is_equal(away)
	actor.position = Vector3.ZERO
	await _ticks(5)
	assert_that(copy.global_transform).is_equal(body.global_transform)
	var water := FluidArea3D.new()
	water.position.y = 5
	body.get_parent().add_child(water)
	body.gravity_scale = 1
	body.fluid_interactor.add_floater(Vector3.ZERO, 0.5)
	body.fluid_interactor.volume = 1
	body.fluid_area_enter(water)
	body.sleeping = false
	await _ticks(8)
	assert_float(body.linear_velocity.y).is_greater(0)
	assert_vector(copy.fluid_interactor.float_force).is_equal(Vector3.ZERO)

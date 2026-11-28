extends "memory_session_suite.gd"

const MODE := CogitoMovementState.Mode
const ACTION := CogitoPlayerCommand.Action
const SWITCH := "COGITO_AUTHORITY_MOVEMENT"
const CustomPlayer := preload("res://tests/net/custom_movement_player.tscn")
const Seat := preload("res://addons/cogito/DemoScenes/DemoPrefabs/cogito_sittable.tscn")

var _old_switch: String
var _previous: Node
var _room: Node3D
var _server: Facade
var _owner: Facade
var _actor: CogitoPlayerAdvanced
var _driver := Driver.new()


class Driver:
	extends CogitoPlayerInputSource
	var axes := Vector2.ZERO
	var held := 0

	func sample(actor: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
		var cmd := super.sample(actor, sequence)
		cmd.move = axes
		cmd.held = held
		cmd.toggle_crouch = false
		return cmd


func before_test() -> void:
	_old_switch = OS.get_environment(SWITCH)
	OS.set_environment(SWITCH, "1")
	_previous = get_tree().current_scene
	_room = load("res://tests/player/golden_level.tscn").instantiate()
	get_tree().root.add_child(_room)
	get_tree().current_scene = _room
	_driver = Driver.new()


func after_test() -> void:
	super.after_test()
	get_tree().current_scene = _previous
	_room.free()
	OS.set_environment(SWITCH, _old_switch)


func _stage(listen := true) -> void:
	_server = _branch(1, _room)
	var folder := create_temp_dir("authority-%s" % Time.get_ticks_usec())
	var config := {"save_dir": folder, "respawn_delay": 0.0}
	if listen:
		assert_int(_server.host(config)).is_equal(OK)
	else:
		assert_int(_server.start_server(config)).is_equal(OK)
	_server.player_world.bind_level(_room, Transform3D(Basis.IDENTITY, Vector3.UP), "arena")
	if listen:
		_actor = _server.player_world.local_actor
	else:
		_owner = _branch(2)
		assert_int(_owner.join("memory", 1839)).is_equal(OK)
		_level(_owner)
		_pump()
		_actor = _server.player_world.avatar_for(_owner.local_player_id()).actor
	_actor.input_source = _driver
	await _ticks(30)
	assert_bool(_actor.movement_grounded()).is_true()


func _one_move(kernel: bool) -> Vector3:
	var start := _actor.position
	var count := _actor.authority_solve_count
	var solves := _actor.authority_movement.solves
	await _ticks(1)
	assert_int(_actor.authority_solve_count - count).is_equal(1)
	assert_int(_actor.authority_movement.solves - solves).is_equal(int(kernel))
	var displacement := _actor.position - start
	if not kernel:
		assert_vector(displacement).is_equal_approx(
			_actor.get_position_delta(), Vector3.ONE * 0.0001
		)
	return displacement


func test_queries_from_corrected_origin_leave_actor_and_old_contacts_intact() -> void:
	await _stage()
	var movement := _actor.authority_movement
	var s := _actor.capture_movement_state()
	var original := _actor.global_transform
	var air := original.translated(Vector3.UP * 4.0)
	var grounded := movement.room.solve(original, s, movement.profile, 1.0 / 60)
	var corrected := movement.room.solve(air, s, movement.profile, 1.0 / 60)
	var repeated := movement.room.solve(original, s, movement.profile, 1.0 / 60)
	assert_vector(grounded.floor_normal).is_equal(Vector3.UP)
	assert_vector(corrected.floor_normal).is_equal(Vector3.ZERO)
	assert_that(repeated.pose).is_equal(grounded.pose)
	assert_that(_actor.global_transform).is_equal(original)
	assert_bool(_actor.movement_grounded()).is_true()


func test_ladder_and_external_impulse_crossings() -> void:
	await _stage()
	_driver.axes = Vector2.UP
	var walk := await _one_move(true)
	assert_float(-walk.z).is_greater(0.001)
	_actor.enter_ladder(_room.get_node("Ladder/ClimbArea"), Vector3.BACK)
	assert_int(_actor.current_moving_state).is_equal(MODE.LADDER_CLIMBING)
	var climb := await _one_move(false)
	assert_float(climb.y).is_equal_approx(_actor.LADDER_SPEED / 60.0, 0.001)
	_actor.exit_ladder()
	var departure := await _one_move(true)
	assert_float(departure.y).is_greater(0)
	_driver.axes = Vector2.ZERO
	await _ticks(50)
	_actor.apply_external_force(Vector3.RIGHT * 6)
	var impulse := await _one_move(false)
	assert_float(impulse.x).is_equal_approx(0.1, 0.001)
	var resumed := await _one_move(true)
	assert_float(absf(resumed.x)).is_less(0.001)
	print("PR4 CROSS ladder=", [walk, climb, departure], " impulse=", [impulse, resumed])


func test_water_crossing_preserves_one_writer() -> void:
	await _stage()
	var pool: Area3D = _room.get_node("Pool")
	pool.position = Vector3(0, 1, 0)
	_driver.axes = Vector2.UP
	var saw_swim := false
	for i in 5:
		var count := _actor.authority_solve_count
		await _ticks(1)
		assert_int(_actor.authority_solve_count - count).is_equal(1)
		saw_swim = saw_swim or _actor.current_moving_state == MODE.SWIMMING
	assert_bool(saw_swim).is_true()
	var swim := await _one_move(false)
	assert_float(-swim.z).is_greater(0.001)
	pool.position = Vector3(10, 6, 0)
	for i in 10:
		var count := _actor.authority_solve_count
		await _ticks(1)
		assert_int(_actor.authority_solve_count - count).is_equal(1)
	var resumed := await _one_move(true)
	assert_float(-resumed.z).is_greater(0.001)
	print("PR4 CROSS swim=", swim, " walk=", resumed)


func test_seat_and_death_release_to_one_simulation() -> void:
	await _stage()
	var seat := Seat.instantiate() as CogitoSittable
	seat.sit_area_behaviour = CogitoSittable.SitAreaBehaviour.NONE
	seat.placement_on_leave = CogitoSittable.PlacementOnLeave.ORIGINAL
	seat.prompt_pos_mode = CogitoSittable.PromptPositionMode.MARKER
	seat.prompt_marker = seat.get_node("Look Marker")
	seat.position = Vector3(4, 1, -1)
	_room.add_child(seat)
	var endpoint := _server.player_world
	var id := _server.local_player_id()
	var result := endpoint.seats.use(seat, _actor.player_interaction_component)
	assert_bool(result.ok).is_true()
	var occupied := _actor.global_position
	var count := _actor.authority_solve_count
	await _ticks(3)
	assert_vector(_actor.global_position).is_equal(occupied)
	assert_int(_actor.authority_solve_count).is_equal(count)
	endpoint.seats.release(_actor)
	_driver.axes = Vector2.UP
	var resumed := await _one_move(true)
	assert_float(-resumed.z).is_greater(0.001)
	print("PR4 CROSS seat=", occupied, " walk=", resumed)
	endpoint.death.die(_actor)
	count = _actor.authority_solve_count
	occupied = _actor.global_position
	await _ticks(3)
	assert_vector(_actor.global_position).is_equal(occupied)
	assert_int(_actor.authority_solve_count).is_equal(count)
	var life: int = endpoint.avatar_for(id).lifetime
	assert_str(endpoint.death.try_respawn(id, life)).is_empty()
	var respawned := await _one_move(true)
	assert_float(-respawned.z).is_greater(0.001)


func _route() -> Array[Vector3]:
	var path: Array[Vector3] = []
	var start := _actor.position
	_driver.axes = Vector2.UP
	for tick in 90:
		if tick == 35:
			_driver.held = 1 << ACTION.SPRINT
		elif tick == 60:
			_driver.held = 0
			_driver.axes = Vector2.ZERO
		await _one_move(true)
		path.append(_actor.position - start)
	return path


func test_dedicated_and_listen_follow_same_route_and_replicate_drain() -> void:
	await _stage(false)
	var dedicated := await _route()
	var stamina := _actor.stamina_attribute.value_current
	assert_float(stamina).is_less(_actor.stamina_attribute.value_max)
	_server.player_world.flush_attributes(_owner.local_player_id(), true)
	await _ticks(10)
	var hud := _owner.local_player().player_hud as CogitoPlayerHudManager
	assert_float(hud.fixed_stamina_bar.attribute_bar.value_current).is_equal_approx(stamina, 0.05)
	super.after_test()
	_driver = Driver.new()
	await _stage()
	var listen := await _route()
	var maximum := 0.0
	for tick in listen.size():
		maximum = maxf(maximum, listen[tick].distance_to(dedicated[tick]))
	assert_float(maximum).is_less(0.001)


func test_platform_contact_hands_the_whole_tick_to_advanced() -> void:
	await _stage()
	_actor.position = Vector3(22, 1.801, 0)
	_server.player_world.mark_teleport(_server.local_player_id())
	await _one_move(false)
	_driver.axes = Vector2.UP
	var resumed := false
	for i in 90:
		var start := _actor.position
		var count := _actor.authority_solve_count
		var solves := _actor.authority_movement.solves
		await _ticks(1)
		assert_int(_actor.authority_solve_count - count).is_equal(1)
		assert_float(_actor.position.distance_to(start)).is_less(0.15)
		if _actor.authority_movement.solves > solves:
			resumed = true
	assert_bool(resumed).is_true()
	assert_bool(_actor.movement_grounded()).is_true()
	assert_float(_actor.position.z).is_less(-4.0)


func test_ladder_jump_off_displaces_once_on_departure() -> void:
	await _stage()
	_driver.axes = Vector2.UP
	_actor.enter_ladder(_room.get_node("Ladder/ClimbArea"), Vector3.BACK)
	await _one_move(false)
	_actor.ladder_direction = Vector3.FORWARD
	_driver.held = 1 << ACTION.JUMP
	var departure := await _one_move(true)
	assert_int(_actor.current_moving_state).is_equal(MODE.JUMPING)
	assert_float(departure.y).is_equal_approx(_actor.JUMP_VELOCITY * 0.5 / 60, 0.001)


func test_unmatched_prefab_keeps_legacy_writer() -> void:
	await _stage()
	var avatar := preload("res://addons/cogito/Networking/net_avatar.gd").new()
	avatar.spawn(
		CustomPlayer, _room, "custom", Transform3D(Basis.IDENTITY, Vector3(3, 1, 0)), false, true
	)
	assert_object(avatar.actor.authority_movement).is_null()
	await _ticks(3)
	assert_int(avatar.actor.authority_solve_count).is_greater(0)
	avatar.despawn()


func _cross_animated_mode(start: Vector3, mode: int) -> void:
	_actor.position = start
	_server.player_world.mark_teleport(_server.local_player_id())
	var entered := false
	var exited := false
	var legacy_moves := 0
	for tick in 165:
		if mode == MODE.LEDGE_CLIMBING:
			_driver.axes = Vector2.UP if tick >= 15 and tick < 95 else Vector2.ZERO
			_driver.held = (1 << ACTION.JUMP) if tick >= 32 and tick < 90 else 0
		var origin := _actor.position
		var active := _actor.current_moving_state == mode
		var count := _actor.authority_solve_count
		var solves := _actor.authority_movement.solves
		await _ticks(1)
		var moves := _actor.authority_solve_count - count
		assert_int(moves).is_less_equal(1)
		if active:
			assert_int(_actor.authority_movement.solves).is_equal(solves)
			legacy_moves += moves
		if active != (_actor.current_moving_state == mode):
			assert_int(moves).is_equal(1)
			var displacement := _actor.position - origin
			print("PR4 CROSS mode=", mode, " entering=", not active, " delta=", displacement)
			if active:
				assert_vector(displacement).is_equal_approx(
					_actor.get_position_delta(), Vector3.ONE * 0.0001
				)
			entered = entered or not active
			exited = exited or active
	assert_bool(entered and exited).is_true()
	assert_int(legacy_moves).is_greater(0)
	await _one_move(true)


func test_ledge_climb_and_return_to_ground() -> void:
	await _stage()
	await _cross_animated_mode(Vector3(16, 1, 0), MODE.LEDGE_CLIMBING)


func test_hard_landing_roll_and_return_to_ground() -> void:
	await _stage()
	await _cross_animated_mode(Vector3(0, 6, 0), MODE.ROLLING)


func _crossing(previous: NetOwnerState, eligible: bool) -> NetOwnerState:
	await _ticks(7)
	var view := _owner.player_world.avatar_for(_owner.local_player_id())
	var current := view.latest_owner_baseline()
	assert_bool(current.state != null).is_equal(eligible)
	assert_int(current.generation).is_greater(previous.generation)
	return current


func test_owner_checkpoint_changes_generation_on_legacy_crossings() -> void:
	await _stage(false)
	var id := _owner.local_player_id()
	var view := _owner.player_world.avatar_for(id)
	var block := view.latest_owner_baseline()
	assert_object(block.state).is_not_null()
	_actor.enter_ladder(_room.get_node("Ladder/ClimbArea"), Vector3.BACK)
	block = await _crossing(block, false)
	_actor.exit_ladder()
	block = await _crossing(block, true)
	var pool: Area3D = _room.get_node("Pool")
	var original := pool.position
	pool.position = _actor.position
	block = await _crossing(block, false)
	pool.position = original
	block = await _crossing(block, true)
	var seat := Seat.instantiate() as CogitoSittable
	seat.sit_area_behaviour = CogitoSittable.SitAreaBehaviour.NONE
	seat.placement_on_leave = CogitoSittable.PlacementOnLeave.ORIGINAL
	seat.prompt_pos_mode = CogitoSittable.PromptPositionMode.MARKER
	seat.prompt_marker = seat.get_node("Look Marker")
	seat.position = Vector3(4, 1, -1)
	_room.add_child(seat)
	var players := _server.player_world
	assert_bool(players.seats.use(seat, _actor.player_interaction_component).ok).is_true()
	block = await _crossing(block, false)
	players.seats.release(_actor)
	block = await _crossing(block, true)
	players.death.die(_actor)
	_pump()
	assert_object(view.latest_owner_baseline()).is_null()
	block = await _crossing(block, false)
	assert_str(players.death.try_respawn(id, block.life)).is_empty()
	_pump()
	var renewed := view.latest_owner_baseline()
	assert_int(renewed.life).is_greater(block.life)
	assert_int(renewed.generation).is_greater(block.generation)
	assert_object(renewed.state).is_null()
	await _crossing(renewed, true)

extends "memory_session_suite.gd"

const CHANNEL := preload("res://addons/cogito/Networking/net_command_channel.gd")

var _server: Facade
var _a: Facade
var _b: Facade
var _level_root: Node3D


func before_test() -> void:
	_server = _branch(1)
	_server.start_server({"save_dir": "user://net/physics-actions"})
	_level_root = _arena(_server)
	_a = _observer(2)
	_b = _observer(3)
	await _ticks(10)


func _stage(place: String) -> void:
	_level_root.stage_physics(_server.player_world, place, _a.local_player_id())
	await _ticks(8)


func _actor(branch: Facade) -> CogitoPlayerAdvanced:
	return _server.player_world.avatar_for(branch.local_player_id()).actor


func _grab(branch: Facade) -> void:
	_use(branch, "CarryBox/CarryableComponent", &"interact2")


func test_grab_race_bounded_rotation_and_single_charged_throw() -> void:
	await _stage("carry")
	var box: RigidBody3D = _level_root.get_node("CarryBox")
	var component: CogitoCarryableComponent = box.get_node("CarryableComponent")
	component.attribute_check = InteractionComponent.AttributeCheck.NONE
	component.enable_manual_rotating = true
	_grab(_a)
	_grab(_b)
	assert_object(component.carrier).is_same(_actor(_a))
	assert_bool(_b.local_player().player_interaction_component.carrying.is_carrying).is_false()
	var api := _server.player_world.carry
	var token := _a.player_world.carry._local_token
	var initial_basis := box.global_basis
	api.apply_input(3, token, &"throw", Vector2.ZERO)
	api.apply_input(2, token, &"rotate", Vector2(100, 0))
	assert_that(box.global_basis).is_equal(initial_basis)
	api.apply_input(2, token, &"rotate", Vector2(10, 5))
	var rotated := box.global_basis
	assert_bool(initial_basis.is_equal_approx(rotated)).is_false()
	api.apply_input(2, token, &"rotate", Vector2(5, 10))
	assert_that(box.global_basis).is_equal(rotated)
	var pic := _actor(_a).player_interaction_component
	pic.stamina_attribute = _actor(_a).stamina_attribute
	pic.throw_stamina_threshold = 0
	var stamina := pic.stamina_attribute.value_current
	var impulses: Array[Vector3] = []
	component.thrown.connect(func(impulse: Vector3): impulses.append(impulse))
	api.apply_input(2, token, &"throw", Vector2.ZERO)
	api.apply_input(2, token, &"throw", Vector2.ZERO)
	assert_int(impulses.size()).is_equal(1)
	assert_float(pic.stamina_attribute.value_current).is_equal(stamina - pic.throw_stamina_drain)
	assert_bool(component.is_being_carried).is_false()


func test_break_death_and_disconnect_release_once() -> void:
	await _stage("carry")
	var component: CogitoCarryableComponent = _level_root.get_node("CarryBox/CarryableComponent")
	component.attribute_check = InteractionComponent.AttributeCheck.NONE
	var changes: Array[bool] = []
	component.carry_state_changed.connect(func(held: bool): changes.append(held))
	_grab(_a)
	_actor(_a).position += Vector3.RIGHT * 10
	await _ticks(2)
	assert_array(changes).contains_exactly([true, false])
	await _stage("carry")
	_grab(_a)
	_actor(_a)._on_death()
	_actor(_a).player_interaction_component.on_death()
	_pump()
	assert_array(changes).contains_exactly([true, false, true, false])
	_grab(_b)
	_b.disconnect_session()
	_pump()
	assert_array(changes).contains_exactly([true, false, true, false, true, false])


func test_seat_race_swap_drive_exit_and_disconnect() -> void:
	await _stage("seat")
	var seat: CogitoSittable = _level_root.get_node("Seat")
	var vehicle: CogitoVehicle = _level_root.get_node("Vehicle")
	_use(_a, "Seat/BasicInteraction")
	_use(_b, "Seat/BasicInteraction")
	assert_str(seat.occupant_id).is_equal(_a.local_player_id())
	assert_bool(_actor(_b).is_sitting).is_false()
	await _ticks(10)
	var replica := _a.local_player() as CogitoPlayerAdvanced
	assert_object(replica.current_seat).is_same(_a.player_world.active_level().get_node("Seat"))
	assert_str(replica.get_node("AnimationPlayer").current_animation).is_equal("Sitting_Idle")
	seat.vertical_look_angle = 15
	_actor(_a).head.rotation.x = 1.2
	_server.player_world.seats.clamp_look(_actor(_a))
	assert_float(_actor(_a).head.rotation.x).is_equal_approx(deg_to_rad(15), 0.001)
	_use(_a, "Vehicle/BasicInteraction")
	assert_bool(seat.is_occupied).is_false()
	assert_str(vehicle.occupant_id).is_equal(_a.local_player_id())
	var command := CogitoPlayerCommand.new()
	var channel := CHANNEL.new()
	var forged := channel.packet(command)
	forged.encode_float(5, 2.0)
	assert_array(CHANNEL.decode(forged, true)).is_empty()
	var initial := vehicle.position
	_actor(_b).current_command.move = Vector2.UP
	vehicle._physics_process(0.1)
	assert_vector(vehicle.position).is_equal(initial)
	_actor(_a).current_command.move = Vector2.UP
	_actor(_a).current_command.has_control = true
	vehicle._physics_process(0.1)
	assert_bool(vehicle.position.is_equal_approx(initial)).is_false()
	_use(_a, "Vehicle/BasicInteraction")
	assert_bool(vehicle.is_occupied).is_false()
	_use(_b, "Seat/BasicInteraction")
	var exits: Array[bool] = []
	seat.player_stand_up.connect(func(): exits.append(true))
	_b.disconnect_session()
	_pump()
	assert_array(exits).contains_exactly([true])
	assert_str(seat.occupant_id).is_empty()


func test_snap_one_result_and_late_join() -> void:
	await _stage("slot")
	var box: RigidBody3D = _level_root.get_node("CarryBox")
	var component: CogitoCarryableComponent = box.get_node("CarryableComponent")
	component.attribute_check = InteractionComponent.AttributeCheck.NONE
	_grab(_a)
	var slot: CogitoSnapSlot = _level_root.get_node("Slot")
	var placed: Array[bool] = []
	slot.object_placed.connect(func(): placed.append(true))
	slot.place_carryable(box)
	slot.place_carryable(box)
	assert_array(placed).contains_exactly([true])
	assert_bool(component.is_being_carried).is_false()
	var late := _observer(4)
	await _ticks(8)
	for branch in [_a, _b, late]:
		var root: Node = branch.player_world.active_level()
		assert_str(root.get_node("Slot").snapped_id).is_equal("physics:box")
		assert_vector(root.get_node("CarryBox").global_position).is_equal(box.global_position)


func test_authored_rigid_drag_and_wall_clamp() -> void:
	await _stage("carry")
	var body: RigidBody3D = _level_root.get_node("Draggable")
	var drag: CogitoCarryableComponent = body.get_node("CarryableComponent")
	var actor := _actor(_a)
	_level_root.get_node("CarryBox").position.x += 8
	body.global_position = actor.get_aim_transform().origin + Vector3.FORWARD
	await _ticks(3)
	var pic := actor.player_interaction_component
	_use(_a, "Draggable/CarryableComponent", &"interact2")
	assert_object(pic.carrying.carried_object).is_same(drag)
	var eye := actor.get_aim_transform().origin
	var end := eye + Vector3.FORWARD * 5
	var clamped: Vector3 = _server.player_world.carry.clamp_anchor(pic, body, end)
	assert_float(eye.distance_to(clamped)).is_less(eye.distance_to(end))
	_actor(_a).position += Vector3.RIGHT * 12
	await _ticks(2)
	assert_bool(drag.is_being_carried).is_false()


func test_leaving_level_releases_carry_and_seat_once() -> void:
	await _stage("seat")
	var seat: CogitoSittable = _level_root.get_node("Seat")
	var exits: Array[bool] = []
	seat.player_stand_up.connect(func(): exits.append(true))
	_use(_a, "Seat/BasicInteraction")
	await _stage("carry")
	var body: CogitoCarryableComponent = _level_root.get_node("CarryBox/CarryableComponent")
	var changes: Array[bool] = []
	body.carry_state_changed.connect(func(held: bool): changes.append(held))
	_grab(_b)
	var host := _b.player_world.active_level().get_parent().get_parent() as CogitoLevelHost
	host.unload_level(&"arena")
	await _ticks(5)
	assert_array(changes).contains_exactly([true, false])
	assert_bool(seat.is_occupied).is_true()
	host = _level_root.get_parent().get_parent() as CogitoLevelHost
	host.unload_level(&"arena")
	await _ticks(5)
	assert_array(exits).contains_exactly([true])


func test_one_live_impact_and_silent_late_join() -> void:
	await _stage("carry")
	var body: RigidBody3D = _level_root.get_node("CarryBox")
	var sound: ImpactSounds = body.get_node("ImpactSounds")
	sound.audio_stream_player_3d.stop()
	sound.is_delaying = false
	body.freeze = false
	body.linear_velocity = Vector3.RIGHT
	var transport: MemoryPeer = _network[1]
	transport.capture = true
	sound._on_parent_node_collision(null)
	var packets := transport.sent.size()
	assert_int(packets).is_greater(0)
	sound._on_parent_node_collision(null)
	assert_int(transport.sent.size()).is_equal(packets)
	_pump()
	var copy: ImpactSounds = _a.player_world.active_level().get_node("CarryBox/ImpactSounds")
	assert_bool(copy.audio_stream_player_3d.playing).is_true()
	var late := _observer(4)
	copy = late.player_world.active_level().get_node("CarryBox/ImpactSounds")
	assert_bool(copy.audio_stream_player_3d.playing).is_false()

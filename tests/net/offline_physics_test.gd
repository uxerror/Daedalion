extends GdUnitTestSuite

const PLAYER := preload("res://addons/cogito/PackedScenes/cogito_player_advanced.tscn")
const ARENA := preload("process_arena.tscn")


func test_original_carry_seat_vehicle_snap_and_buoyancy() -> void:
	var previous := CogitoSceneManager.get_player()
	var previous_seat := CogitoSceneManager._current_sittable_node
	var mouse := Input.mouse_mode
	var level := ARENA.instantiate()
	add_child(level)
	var actor: CogitoPlayerAdvanced = PLAYER.instantiate()
	level.add_child(actor)
	var pic := actor.player_interaction_component
	var component: CogitoCarryableComponent = level.get_node("CarryBox/CarryableComponent")
	var slot: CogitoSnapSlot = level.get_node("Slot")
	var box: RigidBody3D = component.get_parent()
	component.attribute_check = InteractionComponent.AttributeCheck.NONE
	assert_object(pic.network_interactions).is_null()
	assert_int(CogitoNet.get_child_count()).is_zero()
	component.interact(pic)
	assert_object(pic.carrying.carried_object).is_same(component)
	slot.player_interaction_component = pic
	slot.setter_delay = 0
	slot.place_carryable(box)
	assert_bool(slot.save().is_holding_object).is_true()
	assert_bool(box.freeze).is_true()
	assert_vector(box.global_position).is_equal(slot.snap_position.global_position)
	assert_bool(pic.carrying.is_carrying).is_false()
	await get_tree().process_frame
	var vehicle: CogitoVehicle = level.get_node("Vehicle")
	vehicle.interact_cooldown_duration = 0
	vehicle.tween_duration = 0
	vehicle.rotation_tween_duration = 0
	vehicle.interact(pic)
	assert_object(actor.current_seat).is_same(vehicle)
	assert_bool(vehicle.save().is_occupied).is_true()
	actor.current_command.held = 1 << CogitoPlayerCommand.Action.FORWARD
	var start := vehicle.position
	vehicle._physics_process(0.1)
	assert_bool(vehicle.position.is_equal_approx(start)).is_false()
	await get_tree().process_frame
	vehicle.interact(pic)
	assert_bool(vehicle.save().is_occupied).is_false()
	var fluid := FluidArea3D.new()
	level.add_child(fluid)
	var floater := FloatableBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	floater.add_child(shape)
	level.add_child(floater)
	floater.position.y = -2
	floater.fluid_area_enter(fluid)
	floater._physics_process(1.0 / 60)
	assert_float(floater.fluid_interactor.float_force.y).is_greater(0)
	assert_bool(floater.freeze).is_false()
	InputRouter.remove(actor.on_input)
	actor.current_seat = previous_seat
	level.free()
	CogitoSceneManager.register_player(previous)
	Input.mouse_mode = mouse

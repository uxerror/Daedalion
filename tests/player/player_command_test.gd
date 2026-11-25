extends GdUnitTestSuite

const PLAYER := preload("res://addons/cogito/PackedScenes/cogito_player_advanced.tscn")
const LEVEL := preload("res://tests/player/movement_level.tscn")
const SEAT := preload("res://addons/cogito/DemoScenes/DemoPrefabs/cogito_sittable.tscn")


class ScriptedSource:
	extends CogitoPlayerInputSource

	var axes := Vector2.ZERO
	var buttons: int
	var yaw: float
	var pending := PackedByteArray()
	var repeat: CogitoPlayerCommand

	func sample(actor: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
		if repeat:
			return repeat
		var command := super.sample(actor, sequence)
		command.yaw = yaw
		command.move = axes
		command.held = buttons
		command.edges = pending
		pending = PackedByteArray()
		return command


var _world: Node3D
var _previous_player: CogitoPlayer
var _previous_scene: Node
var _previous_seat: Node
var _mouse: Input.MouseMode
var _mode: CogitoNet.Mode
var _time_scale: float


func before_test() -> void:
	_previous_scene = get_tree().current_scene
	_previous_player = CogitoSceneManager.get_player()
	_previous_seat = CogitoSceneManager._current_sittable_node
	_mouse = Input.mouse_mode
	_mode = CogitoNet.mode()
	_time_scale = Engine.time_scale
	_world = LEVEL.instantiate()
	get_tree().root.add_child(_world)
	get_tree().current_scene = _world


func after_test() -> void:
	Input.action_release("forward")
	Input.action_release("action_primary")
	Input.action_release("quickslot_wheel")
	InputRouter.remove(_menu_input)
	get_tree().current_scene = _previous_scene
	_world.free()
	CogitoSceneManager._current_player_node = _previous_player
	CogitoSceneManager._current_sittable_node = _previous_seat
	Input.mouse_mode = _mouse
	CogitoNet._mode = _mode
	Engine.time_scale = _time_scale


func _spawn(
	at: Vector3, source: CogitoPlayerInputSource, local: bool = false
) -> CogitoPlayerAdvanced:
	var actor: CogitoPlayerAdvanced = PLAYER.instantiate()
	actor.is_local_presentation = local
	actor.input_source = source
	actor.position = at
	_world.add_child(actor)
	return actor


func _ticks(count: int) -> void:
	for tick in count:
		await get_tree().physics_frame


func _menu_input(_event: InputEvent) -> void:
	pass


func test_walk_sprint_jump_and_land(_timeout := 10000) -> void:
	var source := ScriptedSource.new()
	source.yaw = PI / 2
	var actor := _spawn(Vector3(0, 1, 4), source)
	await _ticks(15)
	source.axes = Vector2.UP
	await _ticks(60)
	assert_float(actor.position.x).is_less(-2.0)
	assert_float(absf(actor.position.z - 4.0)).is_less(0.05)
	var walking := actor.velocity.length()
	source.buttons = 1 << CogitoPlayerCommand.Action.SPRINT
	await _ticks(60)
	assert_int(actor.current_moving_state).is_equal(CogitoPlayerAdvanced.MovingState.Sprinting)
	assert_float(actor.velocity.length()).is_greater(walking + 1.0)
	source.buttons = 1 << CogitoPlayerCommand.Action.JUMP
	await _ticks(5)
	assert_bool(actor.is_on_floor()).is_false()
	assert_float(actor.velocity.y).is_greater(0.0)
	source.buttons = 0
	await _ticks(100)
	assert_bool(actor.is_on_floor()).is_true()


func test_toggle_edges_are_consumed_once_and_hold_releases() -> void:
	var source := ScriptedSource.new()
	var actor := _spawn(Vector3.UP, source)
	actor.TOGGLE_CROUCH = true
	await _ticks(15)
	var frame := source.sample(actor, actor.last_consumed_sequence + 1)
	frame.add_edge(CogitoPlayerCommand.Action.CROUCH)
	source.repeat = frame
	await _ticks(5)
	assert_int(actor.last_consumed_sequence).is_equal(frame.sequence)
	assert_int(actor.current_body_posture_state).is_equal(
		CogitoPlayerAdvanced.BodyPostureState.Crouching
	)
	source.repeat = null
	source.pending.append(CogitoPlayerCommand.Action.CROUCH)
	await _ticks(5)
	assert_int(actor.current_body_posture_state).is_equal(
		CogitoPlayerAdvanced.BodyPostureState.Standing
	)
	actor.TOGGLE_CROUCH = false
	source.buttons = 1 << CogitoPlayerCommand.Action.CROUCH
	await _ticks(10)
	assert_int(actor.current_body_posture_state).is_equal(
		CogitoPlayerAdvanced.BodyPostureState.Crouching
	)
	source.buttons = 0
	await _ticks(10)
	assert_int(actor.current_body_posture_state).is_equal(
		CogitoPlayerAdvanced.BodyPostureState.Standing
	)


func test_fall_triggers_roll_and_finishes_headless(_timeout := 6000) -> void:
	var actor := _spawn(Vector3.UP * 6.0, ScriptedSource.new())
	actor.TOGGLE_CROUCH = true
	var roll_ticks := 0
	for tick in 160:
		await get_tree().physics_frame
		if actor.current_moving_state == CogitoPlayerAdvanced.MovingState.Rolling:
			roll_ticks += 1
	assert_int(roll_ticks).is_greater(45)
	assert_int(actor.current_moving_state).is_not_equal(CogitoPlayerAdvanced.MovingState.Rolling)
	assert_int(actor.current_body_posture_state).is_equal(
		CogitoPlayerAdvanced.BodyPostureState.Standing
	)
	assert_bool(actor.is_on_floor()).is_true()


func test_ladder_climb_and_swim_in_level_volumes() -> void:
	var climb := ScriptedSource.new()
	var swimmer := ScriptedSource.new()
	var climber := _spawn(Vector3(-10, 1, 0.2), climb)
	var diver := _spawn(Vector3(10, 4, 0), swimmer)
	await _ticks(8)
	assert_int(climber.current_moving_state).is_equal(
		CogitoPlayerAdvanced.MovingState.LadderClimbing
	)
	assert_int(diver.current_moving_state).is_equal(CogitoPlayerAdvanced.MovingState.Swimming)
	var start_y := climber.position.y
	var depth := diver.position.y
	climb.axes = Vector2.UP
	swimmer.buttons = 1 << CogitoPlayerCommand.Action.JUMP
	swimmer.axes = Vector2.UP
	await _ticks(30)
	assert_float(climber.position.y).is_greater(start_y + 0.5)
	assert_float(diver.position.y).is_greater(depth + 0.4)
	assert_float(diver.position.z).is_less(-0.4)
	swimmer.buttons = 1 << CogitoPlayerCommand.Action.CROUCH
	await _ticks(45)
	assert_float(diver.position.y).is_less(depth)


func test_interact_sits_and_exits_without_seating_other_player(
	local_seat: bool, _test_parameters := [[true], [false]]
) -> void:
	var source := ScriptedSource.new()
	var actor := _spawn(Vector3.UP, source, local_seat)
	var other := _spawn(Vector3(3, 1, 0), ScriptedSource.new(), not local_seat)
	var seat: CogitoSittable = SEAT.instantiate()
	seat.sit_area_behaviour = CogitoSittable.SitAreaBehaviour.NONE
	seat.interact_cooldown_duration = 0
	seat.tween_duration = 0.05
	seat.rotation_tween_duration = 0.05
	seat.prompt_pos_mode = CogitoSittable.PromptPositionMode.MARKER
	seat.prompt_marker = seat.get_node("Look Marker")
	seat.position = Vector3(0, 1, -1.2)
	_world.add_child(seat)
	await _ticks(20)
	var entry_position := actor.position
	actor.player_interaction_component.targeting.interactable = seat
	source.pending.append(CogitoPlayerCommand.Action.INTERACT)
	await _ticks(20)
	assert_bool(actor.is_sitting and seat.is_occupied).is_true()
	assert_int(actor.current_moving_state).is_equal(CogitoPlayerAdvanced.MovingState.Sitting)
	assert_bool(other.is_sitting).is_false()
	actor.player_interaction_component.targeting.interactable = seat
	source.pending.append(CogitoPlayerCommand.Action.INTERACT)
	await _ticks(30)
	assert_bool(actor.is_sitting or seat.is_occupied).is_false()
	assert_float(actor.position.distance_to(entry_position)).is_less(0.15)


func test_two_sources_and_local_presentation() -> void:
	var one := ScriptedSource.new()
	var two := ScriptedSource.new()
	var local := _spawn(Vector3.UP, one, true)
	await _ticks(5)
	var mouse_mode := Input.mouse_mode
	var remote := _spawn(Vector3(4, 1, 0), two)
	await _ticks(15)
	assert_object(get_viewport().get_camera_3d()).is_same(local.camera)
	assert_object(CogitoSceneManager.get_player()).is_same(local)
	assert_object(local.player_hud).is_not_null()
	assert_object(remote.camera).is_null()
	assert_object(remote.player_hud).is_null()
	assert_bool(remote.has_node("GUI")).is_false()
	assert_bool(InputRouter.is_input_active(local)).is_true()
	assert_object(local.inventory_data).is_not_same(remote.inventory_data)
	one.axes = Vector2.UP
	two.pending.append(CogitoPlayerCommand.Action.MENU)
	two.pending.append(CogitoPlayerCommand.Action.INVENTORY)
	two.pending.append(CogitoPlayerCommand.Action.WHEEL)
	var remote_start := remote.position
	await _ticks(30)
	assert_float(local.position.z).is_less(-0.5)
	assert_float(remote.position.distance_to(remote_start)).is_less(0.01)
	assert_int(Input.mouse_mode).is_equal(mouse_mode)
	assert_bool(get_tree().paused).is_false()
	assert_float(Engine.time_scale).is_equal(1.0)
	assert_bool(InputRouter.is_input_active(local)).is_true()
	one.axes = Vector2.ZERO
	two.axes = Vector2.RIGHT
	await _ticks(60)
	assert_float(remote.position.x).is_greater(remote_start.x + 2.0)
	assert_float(absf(local.position.x)).is_less(0.01)


func test_menu_takeover_releases_held_and_discards_pending_edges() -> void:
	var actor := _spawn(Vector3.UP, null, true)
	await _ticks(8)
	Input.action_press("forward")
	Input.action_press("action_primary")
	var press := InputEventAction.new()
	press.action = &"action_primary"
	press.pressed = true
	actor.on_input(press)
	await _ticks(2)
	assert_bool(actor.current_command.is_held(CogitoPlayerCommand.Action.PRIMARY)).is_true()
	assert_bool(actor.player_interaction_component.wieldables.primary_action_held).is_true()
	press.action = &"crouch"
	actor.on_input(press)
	InputRouter.push(_menu_input)
	assert_bool(actor.player_interaction_component.wieldables.primary_action_held).is_false()
	await _ticks(2)
	assert_int(actor.current_command.held).is_equal(0)
	assert_vector(actor.current_command.move).is_equal(Vector2.ZERO)
	assert_bool(actor.current_command.edges.is_empty()).is_true()
	InputRouter.remove(_menu_input)
	await _ticks(2)
	assert_int(actor.current_body_posture_state).is_equal(
		CogitoPlayerAdvanced.BodyPostureState.Standing
	)


func test_mouse_look_is_immediate_and_tap_is_ordered_in_one_command() -> void:
	var actor := _spawn(Vector3.UP, null, true)
	await _ticks(8)
	var sequence := actor.last_consumed_sequence
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(24, 12)
	InputRouter.on_input.emit(motion)
	var yaw := actor.body.rotation.y
	var pitch := actor.head.rotation.x
	assert_float(absf(yaw)).is_greater(0.01)
	assert_float(absf(pitch)).is_greater(0.01)
	assert_int(actor.last_consumed_sequence).is_equal(sequence)
	var press := InputEventAction.new()
	press.action = &"action_primary"
	press.pressed = true
	InputRouter.on_input.emit(press)
	var release := InputEventAction.new()
	release.action = &"action_primary"
	InputRouter.on_input.emit(release)
	await _ticks(1)
	assert_float(actor.current_command.yaw).is_equal_approx(yaw, 0.00001)
	assert_float(actor.current_command.pitch).is_equal_approx(pitch, 0.00001)
	assert_that(actor.current_command.edges).is_equal(
		PackedByteArray(
			[
				CogitoPlayerCommand.Action.PRIMARY,
				CogitoPlayerCommand.Action.PRIMARY | CogitoPlayerCommand.RELEASE
			]
		)
	)
	assert_bool(actor.player_interaction_component.wieldables.primary_action_held).is_false()
	await _ticks(1)
	assert_bool(actor.current_command.edges.is_empty()).is_true()


func test_wheel_owns_input_and_only_slows_offline_world(
	online: bool, _test_parameters := [[false], [true]]
) -> void:
	var actor := _spawn(Vector3.UP, null, true)
	await _ticks(12)
	var wheel: CogitoQuickslotWheel = actor.player_hud.get_node("QuickslotWheel")
	wheel.time_scale_while_open = 0.25
	# Exercise MP0's timing policy without opening a transport.
	if online:
		CogitoNet._mode = CogitoNet.Mode.LISTEN_HOST
	Input.action_press("quickslot_wheel")
	var down := InputEventAction.new()
	down.action = &"quickslot_wheel"
	down.pressed = true
	InputRouter.on_input.emit(down)
	await _ticks(3)
	assert_bool(wheel.is_open).is_true()
	assert_bool(InputRouter.is_input_active(wheel)).is_true()
	assert_int(actor.current_command.held).is_equal(0)
	assert_float(Engine.time_scale).is_equal(1.0 if online else 0.25)
	var up := InputEventAction.new()
	up.action = &"quickslot_wheel"
	Input.action_release("quickslot_wheel")
	InputRouter.on_input.emit(up)
	assert_bool(wheel.is_open).is_false()
	assert_bool(InputRouter.is_input_active(actor)).is_true()
	assert_float(Engine.time_scale).is_equal(_time_scale)


func test_online_pause_menu_keeps_physics_running() -> void:
	var actor := _spawn(Vector3.UP, null, true)
	await _ticks(12)
	CogitoNet._mode = CogitoNet.Mode.LISTEN_HOST
	var down := InputEventAction.new()
	down.action = &"menu"
	down.pressed = true
	InputRouter.on_input.emit(down)
	await _ticks(3)
	var menus := actor.find_children("*", "CogitoPauseMenu", false, false)
	assert_int(menus.size()).is_equal(1)
	if menus.is_empty():
		return
	var menu := menus[0] as CogitoPauseMenu
	assert_bool(InputRouter.is_input_active(menu)).is_true()
	assert_bool(get_tree().paused).is_false()
	var sequence := actor.last_consumed_sequence
	await _ticks(2)
	assert_int(actor.last_consumed_sequence).is_greater(sequence)
	assert_bool(actor.current_command.has_control).is_false()
	menu.close_pause_menu()
	assert_bool(InputRouter.is_input_active(actor)).is_true()


# A networked avatar (client or listen host) takes the network_movement_only
# path; Esc must still open the pause menu and free the mouse.
func test_networked_avatar_menu_opens_pause_menu() -> void:
	var actor := _spawn(Vector3.UP, null, true)
	actor.network_movement_only = true
	await _ticks(12)
	CogitoNet._mode = CogitoNet.Mode.CLIENT
	var down := InputEventAction.new()
	down.action = &"menu"
	down.pressed = true
	InputRouter.on_input.emit(down)
	await _ticks(3)
	var menus := actor.find_children("*", "CogitoPauseMenu", false, false)
	assert_int(menus.size()).is_equal(1)
	if menus.is_empty():
		return
	var menu := menus[0] as CogitoPauseMenu
	assert_bool(get_tree().paused).is_false()
	assert_bool(menu.save_button.visible).is_false()
	assert_bool(menu.load_button.visible).is_false()
	menu.close_pause_menu()
	assert_bool(InputRouter.is_input_active(actor)).is_true()

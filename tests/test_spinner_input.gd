extends SceneTree
## Run after importing the project:
## godot --headless --path . --script tests/test_spinner_input.gd

class PlayerShell extends Node3D:
	signal toggled_interface(visible: bool)

var checks := 0
var failures := 0
var spinner: Node3D
var player_shell: Node3D
var pic: Node3D
var input_helper: Node
var cursor := Vector2.ZERO
var goals := 0
var clockwise_steps := 0
var counterclockwise_steps := 0


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	Input.use_accumulated_input = false
	input_helper = root.get_node("InputHelper")
	input_helper.device_index = -1
	player_shell = PlayerShell.new()
	pic = load("res://addons/cogito/Components/PlayerInteractionComponent.gd").new()
	var timer := Timer.new()
	timer.name = "Timer"
	pic.add_child(timer)
	player_shell.add_child(pic)
	root.add_child(player_shell)
	spinner = load("res://addons/cogito/Components/Interactions/SpinnerInteraction.gd").new()
	root.add_child(spinner)
	spinner.set_process(false)
	spinner.spinner_goal_met.connect(func(): goals += 1)
	spinner.spin_clockwise.connect(func(): clockwise_steps += 1)
	spinner.spin_counterclockwise.connect(func(): counterclockwise_steps += 1)
	check(spinner.get("mouse_requires_hold") == true, "Hold is enabled by default")
	check(spinner.get("mouse_rotation_multiplier") == 1.0, "Default multiplier is 1.0")
	for property_name in ["mouse_requires_hold", "mouse_rotation_multiplier"]:
		var exposed := false
		for property in spinner.get_property_list():
			if property.name == property_name:
				exposed = (property.usage & PROPERTY_USAGE_EDITOR) != 0
		check(exposed, property_name + " is exposed in the inspector")
	spinner.enter(pic)
	move_mouse(0.0)
	tick()
	move_mouse(0.5)
	tick()
	check(is_zero_approx(spinner.spinner_value), "Unheld mouse movement must not rotate by default")
	# A held drag rotates; releasing and re-grabbing between frames must rebase.
	mouse_button(true)
	tick()
	move_mouse(1.0)
	tick()
	check(spinner.spinner_value > 0.0, "Held mouse movement rotates")
	var before_release: float = spinner.spinner_value
	spinner.spin_accumulator = 0.025
	mouse_button(false)
	move_mouse(-1.0)
	mouse_button(true)
	tick()
	check(is_equal_approx(spinner.spinner_value, before_release), "Re-grabbing between frames must not jump")
	check(is_zero_approx(spinner.spin_accumulator), "Re-grabbing discards the previous partial step")
	mouse_button(false)
	tick()
	move_mouse(2.0)
	tick()
	check(is_equal_approx(spinner.spinner_value, before_release), "Released movement does not rotate")
	spinner.mouse_requires_hold = false
	move_mouse(0.0)
	tick()
	move_mouse(0.5)
	tick()
	check(spinner.spinner_value > before_release, "Hold opt-out rotates without a button")
	# Scale input before stepping, so value, transform and rise stay in sync.
	var rotating_object := Node3D.new()
	spinner.add_child(rotating_object)
	spinner.rotating_object = rotating_object
	spinner.spinning_axis = Vector3.UP
	spinner.rise_when_rotate = 0.001
	for multiplier in [1.0, 0.5, 0.0]:
		spinner.set("mouse_rotation_multiplier", multiplier)
		for direction in [1, -1]:
			reset_spin()
			move_mouse(0.0)
			tick()
			move_mouse(1.025 * direction)
			tick()
			var expected: float = 20.0 * multiplier * direction
			check(is_equal_approx(spinner.spinner_value, expected), "Mouse multiplier %s direction %s scales value" % [multiplier, direction])
			check(is_equal_approx(rotating_object.rotation.y, expected * 0.05), "Mouse multiplier scales object rotation")
			check(is_equal_approx(rotating_object.position.y, 1.0 - expected * 0.001), "Mouse multiplier scales rise")
	# Mouse settings must not gate or scale stick rotation.
	spinner.mouse_requires_hold = true
	for multiplier in [0.0, 0.5, 1.0]:
		spinner.mouse_rotation_multiplier = multiplier
		for direction in [1, -1]:
			reset_spin()
			move_stick(0.0)
			tick()
			move_stick(1.025 * direction)
			tick()
			check(is_equal_approx(spinner.spinner_value, 20.0 * direction), "Mouse settings do not affect the stick")
	# Mouse events during device-switch debounce must not reset stick history.
	reset_spin()
	move_stick(0.0)
	tick()
	move_stick(0.025)
	tick()
	var stick_remainder: float = spinner.spin_accumulator
	var stick_angle: float = spinner.previous_angle
	var previous_device_change: int = input_helper.device_last_changed_at
	input_helper.device_last_changed_at = Engine.get_frames_drawn() + 1000
	mouse_button(true)
	mouse_button(false)
	check(input_helper.device_index == 0, "Controller remains selected during debounce")
	check(is_equal_approx(spinner.spin_accumulator, stick_remainder), "Mouse buttons preserve stick remainder during debounce")
	check(is_equal_approx(spinner.previous_angle, stick_angle), "Mouse buttons preserve stick angle during debounce")
	move_stick(0.075)
	tick()
	check(is_equal_approx(spinner.spinner_value, 1.0), "Stick continues stepping after unrelated mouse buttons")
	input_helper.device_last_changed_at = previous_device_change
	# A right click must not satisfy the hold requirement.
	input_helper.device_index = -1
	spinner.mouse_rotation_multiplier = 1.0
	reset_spin()
	mouse_button(true, MOUSE_BUTTON_RIGHT)
	move_mouse(0.0)
	tick()
	move_mouse(0.5)
	tick()
	check(is_zero_approx(spinner.spinner_value), "Right button does not enable rotation")
	mouse_button(false, MOUSE_BUTTON_RIGHT)
	# Bounds and goal signals still correspond to the actual rotated steps.
	spinner.mouse_requires_hold = false
	spinner.mouse_rotation_multiplier = 0.5
	spinner.overrotate = false
	for direction in [1, -1]:
		spinner.spinner_goal_value = 5.0 * direction
		reset_spin()
		move_mouse(0.0)
		tick()
		move_mouse(1.025 * direction)
		tick()
		check(is_equal_approx(spinner.spinner_value, 5.0 * direction), "Scaled input clamps at goal")
		check(is_equal_approx(rotating_object.rotation.y, 0.25 * direction), "Rotation stops at goal")
		check(goals == 1, "Goal emits once on reaching bound")
		check(clockwise_steps + counterclockwise_steps == 5, "Step signals match applied steps")
		move_mouse(2.05 * direction)
		tick()
		check(goals == 1, "Further movement at goal does not emit again")
		check(is_equal_approx(rotating_object.rotation.y, 0.25 * direction), "No overrotation at bound")
	# Angle wrapping and dead-zone re-entry remain stable with scaling.
	spinner.spinner_goal_value = 0.0
	reset_spin()
	move_mouse(PI - 0.125)
	tick()
	move_mouse(-PI + 0.125)
	tick()
	check(is_equal_approx(spinner.spinner_value, 2.0), "Angle seam uses the short wrapped delta")
	move_mouse(0.0, 0.0)
	tick()
	var value_before_dead_zone_exit: float = spinner.spinner_value
	move_mouse(0.0)
	tick()
	check(is_equal_approx(spinner.spinner_value, value_before_dead_zone_exit), "Dead-zone re-entry does not jump")
	spinner.exit(pic)
	spinner.enter(pic)
	check(is_nan(spinner.previous_angle) and is_zero_approx(spinner.spin_accumulator), "New interaction resets input history")
	move_mouse(2.0)
	tick()
	check(is_equal_approx(spinner.spinner_value, value_before_dead_zone_exit), "First sample after entry does not rotate")
	spinner.exit(pic)
	spinner.free()
	player_shell.free()
	var screw := load("res://addons/cogito/DemoScenes/DemoPrefabs/ScrewInteractable.tscn").instantiate() as Node
	var screw_spinner := screw.get_node("SpinnerInteraction")
	check(screw_spinner.get("mouse_requires_hold") == true, "Screw requires a held drag")
	check(screw_spinner.get("mouse_rotation_multiplier") == 0.5, "Screw uses half mouse sensitivity")
	screw.free()
	print("Spinner input: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func move_mouse(angle: float, radius: float = 200.0) -> void:
	var event := InputEventMouseMotion.new()
	var position := root.get_visible_rect().size / 2.0 + Vector2.from_angle(angle) * radius
	event.position = position
	event.global_position = position
	event.relative = position - cursor
	cursor = position
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func mouse_button(pressed: bool, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = cursor
	event.global_position = cursor
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func move_stick(angle: float) -> void:
	for axis in [JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y]:
		var event := InputEventJoypadMotion.new()
		event.device = 0
		event.axis = axis
		event.axis_value = sin(-angle) if axis == JOY_AXIS_RIGHT_X else cos(-angle)
		Input.parse_input_event(event)
	Input.flush_buffered_events()
	# Device detection is debounced; select the simulated controller explicitly.
	input_helper.device_index = 0


func reset_spin() -> void:
	goals = 0
	clockwise_steps = 0
	counterclockwise_steps = 0
	spinner.previous_angle = NAN
	spinner.spin_accumulator = 0.0
	spinner.spinner_value = 0.0
	if spinner.rotating_object:
		spinner.rotating_object.rotation = Vector3.ZERO
		spinner.rotating_object.position = Vector3(0, 1, 0)


func tick() -> void:
	spinner._process(1.0 / 60.0)


func check(condition: bool, message: String) -> void:
	checks += 1
	if !condition:
		failures += 1
		printerr("FAIL: " + message)

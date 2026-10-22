extends InteractionComponent

#region inspector settings
@export_group("Spinner Settings")
@export var rotating_object : Node3D
## Sets the spinning axis for the rotating object.
@export var spinning_axis : Vector3
## Object rotation per spin step, in radians. One step also takes this angle of cursor or stick rotation, so the object follows the input.
@export var rotation_speed : float = .05
## Move object as you rotate it
@export var rise_when_rotate : float = 0
## Keep rotating even when a spinner min or max value is hit.
@export var overrotate : bool = true
## Show when interacting
@export var interacting_gizmo : Node

@export_group("Spinner Input Settings")
## Cursor distance from the screen center, in pixels, below which mouse movement is ignored. Close to the center small movements turn into large angles.
@export var mouse_dead_zone : float = 20.0
## Right stick deflection below which gamepad input is ignored.
@export var stick_dead_zone : float = 0.3

@export_group("Spinner Signal Setting")
## The value the spinner starts at. Does not get saved.
@export var spinner_min_value : float = 0
## Spinner value starts at 0. If spinner goal gets hit, a signal is sent. Set bigger than min_value for clockwise, smaller for counter-clockwise. Set to 0 if not using. Does not get saved.
@export var spinner_goal_value : float = 0
## Destroys the object if spinner goal is met.
@export var destroy_on_goal_met : bool = false
@export var sound_on_goal_met : AudioStream


#region Cogito interaction variables
# Check for if this object is being interacted with
var is_being_controlled : bool
var player_interaction_component : PlayerInteractionComponent
signal object_state_updated(interaction_text : String)
#endregion

#region Spin detection variables
## Input angle from the previous frame, in radians. NAN while the input is inside its dead zone.
var previous_angle : float = NAN
## Input rotation collected since the last whole step, in radians. Positive is clockwise.
var spin_accumulator : float = 0.0
## Spinner value is used as a goal for signals. Eg. Spin from 0 to 100 to meet the goal.
var spinner_value : float = 0.0 :
	set(value):
		if spinner_min_value < spinner_goal_value : # Goal is going clockwise
			spinner_value = clampf(value, spinner_min_value, spinner_goal_value)
		elif spinner_min_value > spinner_goal_value : # Goal is going counter-clockwise
			spinner_value = clampf(value, spinner_goal_value, spinner_min_value)
		else: # No goal, nothing to clamp to.
			spinner_value = value


signal spin_clockwise
signal spin_counterclockwise
signal spinner_goal_met
#endregion


func _ready() -> void:
	is_being_controlled = false
	if interacting_gizmo: interacting_gizmo.set_visible(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		force_exit()


## Input event for input routing
func on_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact") or event.is_action_pressed("ui_cancel"):
		exit(player_interaction_component)


func interact(_player_interaction_component: PlayerInteractionComponent) -> void:
	if is_being_controlled:
		exit(_player_interaction_component)
	else:
		enter(_player_interaction_component)


func enter(_pic: PlayerInteractionComponent) -> void:
	player_interaction_component = _pic
	InputRouter.push(on_input)
	player_interaction_component.get_parent().toggled_interface.emit(true)

	previous_angle = NAN
	spin_accumulator = 0.0
	is_being_controlled = true
	if interacting_gizmo: interacting_gizmo.set_visible(true)

	if InputHelper.device_index == -1:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func exit(_player: PlayerInteractionComponent) -> void:
	if interacting_gizmo: interacting_gizmo.set_visible(false)
	_player.get_parent().toggled_interface.emit(false)
	InputRouter.pop()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	is_being_controlled = false


func force_exit() -> void:
	if is_being_controlled:
		exit(player_interaction_component)


func _process(_delta: float) -> void:
	if !is_being_controlled:
		return

	# Switch between mouse spin detection or gamepad spin detection based on input device
	var angle : float
	if InputHelper.device_index == -1:
		angle = get_mouse_angle()
	else:
		angle = get_stick_angle()

	if !is_nan(angle) and !is_nan(previous_angle):
		# angle_difference wraps across the -PI/PI seam.
		spin_accumulator += angle_difference(angle, previous_angle)
		apply_spin()
	previous_angle = angle


## Cursor angle around the screen center, in radians, or NAN inside the dead zone. Decreases when the cursor moves clockwise.
func get_mouse_angle() -> float:
	var viewport := get_viewport()
	# The mouse position is in viewport coordinates, which differ from window pixels under stretch modes.
	var offset := viewport.get_mouse_position() - viewport.get_visible_rect().size / 2
	if offset.length() < mouse_dead_zone:
		return NAN
	return -offset.angle()


## Right stick angle, in radians, or NAN inside the dead zone. Decreases when the stick moves clockwise.
func get_stick_angle() -> float:
	var stick := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y), Input.get_joy_axis(0, JOY_AXIS_RIGHT_X))
	if stick.length() < stick_dead_zone:
		return NAN
	return stick.angle()


## Turns every whole rotation_speed of collected input into one spin step.
func apply_spin() -> void:
	if rotation_speed <= 0:
		return
	while spin_accumulator >= rotation_speed and is_being_controlled:
		spin_accumulator -= rotation_speed
		spin_step(1)
	while spin_accumulator <= -rotation_speed and is_being_controlled:
		spin_accumulator += rotation_speed
		spin_step(-1)


func spin_step(direction: int) -> void:
	var previous_value := spinner_value
	var was_goal_met := is_goal_met()
	spinner_value += direction
	# At the min or goal value the spinner stops unless it may overrotate.
	if !overrotate and spinner_value == previous_value:
		return

	if direction > 0:
		spin_clockwise.emit()
	else:
		spin_counterclockwise.emit()
	apply_rotation(direction)

	if !was_goal_met and is_goal_met():
		spinner_goal_met.emit()
		if sound_on_goal_met :
			CogitoAudio.play_sound_3d(sound_on_goal_met, global_position)
		if destroy_on_goal_met:
			force_exit()
			get_parent().queue_free()


func is_goal_met() -> bool:
	return ( spinner_goal_value < 0 and spinner_value <= spinner_goal_value ) or ( spinner_goal_value > 0 and spinner_value >= spinner_goal_value )


func apply_rotation(direction:int) -> void:
	if !rotating_object:
		return
	
	rotating_object.rotate_object_local(spinning_axis,rotation_speed * direction)
	
	if rise_when_rotate:
		rotating_object.position.y += rise_when_rotate * direction * -1
		if rotating_object.position.y < 0: # Avoid object sinking below zero.
			rotating_object.position.y = 0

class_name CogitoLocalInputSource
extends CogitoPlayerInputSource
## Reads the shared devices only for the player at the top of the local router.

const ACTION := CogitoPlayerCommand.Action

var _pending := PackedByteArray()
var _stick := Vector2.ZERO
# Local views can bind several actions to one physical event. Give them that event once.
var _pending_view_events: Dictionary[int, InputEvent] = {}
var _frame_view_events: Dictionary[int, InputEvent] = {}


## Collect action transitions between ticks and apply local mouse look at event frequency.
func on_input(actor: CogitoPlayerAdvanced, event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if actor.is_mouselook_active:
			_mouse_look(actor, event)
	elif event is InputEventJoypadMotion and actor.is_mouselook_active:
		match event.axis:
			JOY_AXIS_RIGHT_X:
				_stick.x = event.axis_value
			JOY_AXIS_RIGHT_Y:
				_stick.y = event.axis_value
	var first_edge := _pending.size()
	if not event.is_echo() and not event is InputEventMouseMotion:
		for id in CogitoPlayerCommand.ACTIONS.size():
			var action := CogitoPlayerCommand.ACTIONS[id]
			if event.is_action_pressed(action):
				# The demo gamepad shares reload with interact.
				if id == ACTION.RELOAD and InputHelper.device_index != -1:
					if actor.player_interaction_component.targeting.interactable != null:
						continue
				_pending.append(id)
			elif event.is_action_released(action):
				_pending.append(id | CogitoPlayerCommand.RELEASE)
	if _pending.size() > first_edge:
		_pending_view_events[_pending.size() - 1] = event
		if actor.player_interaction_component.handles_action_event(event):
			actor.get_viewport().set_input_as_handled()
	else:
		# Custom views may also handle motion or an action outside the shipped action map.
		actor.handle_quickslot_input(event)


## Original event for local HUD bindings, including custom quickslots and overlapping actions.
func view_event(edge_index: int) -> InputEvent:
	return _frame_view_events.get(edge_index)


## Discard events owned by the previous input context, including latched stick motion.
func clear() -> void:
	_pending.clear()
	_pending_view_events.clear()
	_frame_view_events.clear()
	_stick = Vector2.ZERO


func sample(player: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
	var command := super.sample(player, sequence)
	var actor := player as CogitoPlayerAdvanced
	if not actor or not actor.is_local_presentation or not InputRouter.is_input_active(actor):
		clear()
		command.has_control = false
		return command
	command.move = Input.get_vector("left", "right", "forward", "back")
	command.held = sample_buttons()
	command.edges = _pending
	_pending = PackedByteArray()
	_frame_view_events = _pending_view_events
	_pending_view_events = {}
	_stick_look(actor, 90.0, 120.0)
	if not actor.free_look_requested(command):
		actor.body.rotation.y += actor.neck.rotation.y
		actor.neck.rotation.y = 0.0
	# These chart states historically applied a second stick step after free look.
	if actor.current_moving_state == CogitoPlayerAdvanced.MovingState.LadderClimbing:
		_stick_look(actor, 90.0, 120.0)
	elif actor.is_sitting and actor.current_seat:
		_stick_look(actor, actor.current_seat.horizontal_look_angle, 180.0)
	command.yaw = actor.body.rotation.y
	command.pitch = actor.head.rotation.x
	command.neck_yaw = actor.neck.rotation.y
	return command


## Reads the Input Map for a local actor, including legacy offline vehicle controllers.
static func sample_buttons() -> int:
	var buttons := 0
	for id in CogitoPlayerCommand.ACTIONS.size():
		if Input.is_action_pressed(CogitoPlayerCommand.ACTIONS[id]):
			buttons |= 1 << id
	return buttons


func _stick_look(actor: CogitoPlayerAdvanced, pitch_limit: float, yaw_limit: float) -> void:
	if absf(_stick.y) > actor.JOY_DEADZONE:
		var pitch := deg_to_rad(_stick.y * actor.JOY_H_SENS)
		actor.head.rotate_x(pitch if actor.INVERT_Y_AXIS else -pitch)
		var limit := deg_to_rad(pitch_limit)
		actor.head.rotation.x = clampf(actor.head.rotation.x, -limit, limit)
	if absf(_stick.x) > actor.JOY_DEADZONE:
		actor.neck.rotate_y(deg_to_rad(-_stick.x * actor.JOY_V_SENS))
		var limit := deg_to_rad(yaw_limit)
		actor.neck.rotation.y = clampf(actor.neck.rotation.y, -limit, limit)


func _mouse_look(actor: CogitoPlayerAdvanced, event: InputEventMouseMotion) -> void:
	var movement := Vector2.ZERO
	if actor.is_sitting and actor.current_seat and actor.current_seat.look_marker_node:
		apply_seated_look(actor, event.relative)
	else:
		var yaw := deg_to_rad(-event.relative.x * actor.MOUSE_SENS)
		if actor.is_free_looking:
			actor.neck.rotate_y(yaw)
			actor.neck.rotation.y = clampf(actor.neck.rotation.y, deg_to_rad(-120), deg_to_rad(120))
		else:
			actor.body.rotate_y(yaw)
			movement.x = -event.relative.x
		movement.y = -event.relative.y if actor.INVERT_Y_AXIS else event.relative.y
		actor.head.rotate_x(deg_to_rad(-movement.y * actor.MOUSE_SENS))
		actor.head.rotation.x = clampf(actor.head.rotation.x, -PI / 2.0, PI / 2.0)
	actor.report_mouse_movement(movement)


## Rotates around the authored look marker within the seat's horizontal and vertical limits.
func apply_seated_look(actor: CogitoPlayerAdvanced, relative: Vector2) -> void:
	var to_marker := actor.sittable_look_marker - actor.neck.global_position
	var target := Vector2(to_marker.x, to_marker.z).normalized()
	var turn := deg_to_rad(-relative.x * actor.MOUSE_SENS)
	actor.neck.rotate_y(turn)
	var forward := actor.neck.global_basis.z
	var facing := Vector2(forward.x, forward.z).normalized()
	var angle := wrapf(rad_to_deg(facing.angle_to(target)), 0.0, 360.0)
	if absf(angle - 180.0) >= actor.sittable_look_angle:
		actor.neck.rotation.y -= turn
	var pitch := deg_to_rad(relative.y * actor.MOUSE_SENS)
	actor.head.rotate_x(pitch if actor.INVERT_Y_AXIS else -pitch)
	var limit := deg_to_rad(actor.current_seat.vertical_look_angle)
	actor.head.rotation.x = clampf(actor.head.rotation.x, -limit, limit)

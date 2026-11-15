extends CogitoQuickslotView
class_name CogitoQuickslotWheel

## Radial quick-select menu for any CogitoQuickslotSet.
## Hold open_action to open the wheel, point in a direction (mouse motion or the right stick) to hover a slot,
## release open_action to activate the hovered slot. Releasing while pointing at the centre cancels.
## The mouse stays captured: mouse motion is accumulated into a virtual stick, the cursor position is never used.
## While open, the wheel takes over input through the InputRouter, so the player doesn't look around, move or use wieldables.
## Slots keep their position: slot 0 is at the top, the others follow clockwise. Empty slots are drawn as empty segments.
## Add the wheel to CogitoQuickslots.views, CogitoQuickslots then gives it its set and forwards the open_action to it.
## Without CogitoQuickslots, set quickslot_set and call open()/close() yourself.

## Emitted when the wheel opens.
signal opened
## Emitted when the wheel closes. activated_index is the slot that got activated on close, -1 if none.
signal closed(activated_index: int)

## Holding this action keeps the wheel open.
@export var open_action : String = "quickslot_wheel"
## If true, releasing open_action activates the hovered slot. If false, confirm_action activates the hovered slot
## (the wheel stays open) and releasing open_action only closes the wheel.
@export var activate_on_release : bool = true
## Activates the hovered slot when activate_on_release is false.
@export var confirm_action : String = "action_primary"
## These actions close the wheel and are then passed on, so for example the pause menu or the inventory still open.
@export var passthrough_actions : Array[String] = ["menu", "inventory"]
## Engine.time_scale while the wheel is open. 1 = no slow motion. The previous time scale is restored on close.
@export_range(0.0, 1.0, 0.01) var time_scale_while_open : float = 1.0

@export_group("Selection")
## Part of the stick range (0-1) in the centre where nothing is hovered.
@export_range(0.0, 0.95, 0.01) var deadzone : float = 0.35
## How far (in pixels of mouse motion) the virtual mouse stick reaches. Lower = more sensitive.
@export var mouse_stick_radius : float = 120.0
## If true, the gamepad keeps the hovered slot when the stick returns to the centre,
## so the stick can be let go before releasing open_action. The mouse never does this, move back to the centre to cancel.
@export var gamepad_keeps_hover : bool = true

@export_group("Look")
## Outer radius of the wheel in pixels.
@export var radius : float = 170.0
## Width of the slot ring in pixels.
@export var ring_width : float = 90.0
## Gap between two segments in degrees.
@export var segment_gap_degrees : float = 2.0
## Size of the slot icons in pixels.
@export var icon_size : float = 48.0
@export var segment_color : Color = Color(0.101961, 0.101961, 0.101961, 0.784314)
@export var hovered_color : Color = Color(0.974511, 0.772854, 0.0, 0.35)
@export var outline_color : Color = Color(0.974511, 0.772854, 0.0, 1.0)

@export_group("Sounds")
## Plays when the wheel opens.
@export var sound_open : AudioStream
## Plays when a non-empty slot gets hovered.
@export var sound_hover : AudioStream

## True while the wheel is open.
var is_open : bool = false
## The slot that is currently hovered, -1 if none.
var hovered_index : int = -1
## Context passed to CogitoQuickslotSet.activate() (usually the player). Set by CogitoQuickslots when it opens the wheel.
var activation_context : Object

# Current direction, length 0-1. Mouse motion accumulates into it, the gamepad stick sets it.
var _stick : Vector2 = Vector2.ZERO
var _joy : Vector2 = Vector2.ZERO
var _joy_device : int = -1
var _selection_before_open : int = -1
var _activated_while_open : bool = false
var _time_scale_before_open : float = 1.0
var _icons : Array[TextureRect] = []
var _counters : Array[Label] = []
var _name_label : Label
var _count_label : Label


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func _ready() -> void:
	var centre := VBoxContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.alignment = BoxContainer.ALIGNMENT_CENTER
	centre.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	centre.grow_horizontal = Control.GROW_DIRECTION_BOTH
	centre.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(centre, false, Node.INTERNAL_MODE_FRONT)
	_name_label = _make_label()
	_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name_label.custom_minimum_size.x = maxf((radius - ring_width) * 2.0 - 16.0, 32.0)
	centre.add_child(_name_label)
	_count_label = _make_label()
	centre.add_child(_count_label)
	resized.connect(_layout)
	set_process(false)
	_rebuild()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_PAUSED, NOTIFICATION_EXIT_TREE:
			# Never leave the engine slowed down or the input router taken over.
			close(false)
		NOTIFICATION_PREDELETE:
			if is_open:
				_restore_time_scale()


func _process(_delta: float) -> void:
	if !is_open:
		return
	# Something else took over input (pause menu, death screen, a keypad...) or the release got lost.
	if !InputRouter.is_input_active(self) or (open_action != "" and InputMap.has_action(open_action) and !Input.is_action_pressed(open_action)):
		close(false)


## Called by CogitoQuickslots with input it receives while the player has input focus.
## Opens the wheel when open_action gets pressed. Returns true if the event was consumed.
func handle_quickslot_input(event: InputEvent, context: Object) -> bool:
	if is_open or !_is_action(event, open_action) or !event.is_pressed() or event.is_echo():
		return false
	activation_context = context
	return open()


## Opens the wheel. Returns false if there is nothing to show.
func open() -> bool:
	if is_open or !quickslot_set or quickslot_set.size() == 0 or !is_inside_tree():
		return false
	is_open = true
	_stick = Vector2.ZERO
	_joy = Vector2.ZERO
	_joy_device = -1
	hovered_index = -1
	_activated_while_open = false
	_selection_before_open = quickslot_set.selected_index
	_time_scale_before_open = Engine.time_scale
	if time_scale_while_open < 1.0:
		Engine.time_scale = time_scale_while_open
	InputRouter.push(_on_router_input)
	set_process(true)
	_rebuild()
	show()
	CogitoAudio.play_sound(sound_open)
	CogitoGlobals.debug_log(true, "cogito_quickslot_wheel.gd", "Opened with " + str(quickslot_set.size()) + " slots.")
	opened.emit()
	return true


## Closes the wheel. If activate is true, the hovered slot gets activated. Returns the activated index or -1.
func close(activate: bool = false) -> int:
	if !is_open:
		return -1
	is_open = false
	set_process(false)
	InputRouter.remove(_on_router_input)
	_restore_time_scale()
	_return_stick_to_input()
	var activated_index : int = -1
	if activate:
		if _activate_hovered():
			activated_index = hovered_index
	elif quickslot_set and !_activated_while_open:
		quickslot_set.select(_selection_before_open)
	hide()
	CogitoGlobals.debug_log(true, "cogito_quickslot_wheel.gd", "Closed, activated slot: " + str(activated_index))
	closed.emit(activated_index)
	return activated_index


## Returns the slot at a direction (length 0-1) for a wheel with slot_count slots, -1 inside the deadzone.
## Slot 0 is at the top, the others follow clockwise (screen coordinates, y pointing down).
static func get_slot_at(direction: Vector2, slot_count: int, deadzone_length: float = 0.0) -> int:
	if slot_count <= 0 or direction.length() <= deadzone_length or direction.is_zero_approx():
		return -1
	var segment := TAU / slot_count
	var angle_from_top := fposmod(direction.angle() + PI / 2.0, TAU)
	return posmod(roundi(angle_from_top / segment), slot_count)


## Returns the direction (unit vector) of the centre of a slot.
static func get_slot_direction(index: int, slot_count: int) -> Vector2:
	return Vector2.UP.rotated(TAU * index / maxi(slot_count, 1))


## The current pointing direction, length 0-1.
func get_stick() -> Vector2:
	return _stick


func _on_router_input(event: InputEvent) -> void:
	if !is_open:
		return
	if _is_action(event, open_action):
		if event.is_released():
			close(activate_on_release)
		return
	if event is InputEventMouseMotion:
		_stick = (_stick + event.relative / maxf(mouse_stick_radius, 1.0)).limit_length(1.0)
		_update_hover()
		return
	if event is InputEventJoypadMotion:
		_on_joypad_motion(event)
		return
	if !activate_on_release and _is_action(event, confirm_action) and event.is_pressed() and !event.is_echo():
		_activate_hovered()
		return
	for action in passthrough_actions:
		if _is_action(event, action) and event.is_pressed() and !event.is_echo():
			close(false)
			Input.parse_input_event(event.duplicate())
			return


func _on_joypad_motion(event: InputEventJoypadMotion) -> void:
	if event.axis == JOY_AXIS_RIGHT_X:
		_joy.x = event.axis_value
	elif event.axis == JOY_AXIS_RIGHT_Y:
		_joy.y = event.axis_value
	else:
		return
	_joy_device = event.device
	if _joy.length() > deadzone or !gamepad_keeps_hover:
		_stick = _joy.limit_length(1.0)
		_update_hover()


func _update_hover() -> void:
	var new_index := get_slot_at(_stick, quickslot_set.size(), deadzone) if quickslot_set else -1
	if new_index == hovered_index:
		queue_redraw()
		return
	hovered_index = new_index
	var entry := quickslot_set.get_entry(hovered_index) if quickslot_set else null
	if entry:
		quickslot_set.select(hovered_index)
		CogitoAudio.play_sound(sound_hover)
	elif quickslot_set:
		quickslot_set.select(_selection_before_open)
	_update_centre()
	queue_redraw()


func _activate_hovered() -> bool:
	if !quickslot_set:
		return false
	var entry := quickslot_set.get_entry(hovered_index)
	if !entry or !entry.is_available():
		return false
	quickslot_set.select(hovered_index)
	if !quickslot_set.activate(hovered_index, activation_context):
		return false
	_activated_while_open = true
	return true


func _restore_time_scale() -> void:
	if time_scale_while_open < 1.0:
		Engine.time_scale = _time_scale_before_open


# The look stick was ours while the wheel was open. Pass its current state on,
# otherwise whoever had input before would keep the stick values from before the wheel opened.
func _return_stick_to_input() -> void:
	if _joy_device == -1:
		return
	for axis in [JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y]:
		var motion := InputEventJoypadMotion.new()
		motion.device = _joy_device
		motion.axis = axis
		motion.axis_value = _joy.x if axis == JOY_AXIS_RIGHT_X else _joy.y
		Input.parse_input_event(motion)


func _is_action(event: InputEvent, action: String) -> bool:
	return action != "" and InputMap.has_action(action) and event.is_action(action)


#region Drawing
func _on_slot_changed(index: int) -> void:
	if !is_node_ready():
		return
	if !quickslot_set or quickslot_set.size() != _icons.size():
		_rebuild()
		return
	_display_slot(index)
	if index == hovered_index:
		_update_centre()


func _on_selection_changed(_index: int) -> void:
	queue_redraw()


func _rebuild() -> void:
	if !is_node_ready():
		return
	var slot_count := quickslot_set.size() if quickslot_set else 0
	while _icons.size() > slot_count:
		_icons.pop_back().queue_free()
		_counters.pop_back()
	while _icons.size() < slot_count:
		var icon := TextureRect.new()
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		add_child(icon, false, Node.INTERNAL_MODE_FRONT)
		var counter := _make_label()
		counter.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
		counter.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		counter.grow_vertical = Control.GROW_DIRECTION_BEGIN
		icon.add_child(counter)
		_icons.append(icon)
		_counters.append(counter)
	if hovered_index >= slot_count:
		hovered_index = -1
	for i in slot_count:
		_display_slot(i)
	_layout()
	_update_centre()


func _display_slot(index: int) -> void:
	if index < 0 or index >= _icons.size():
		return
	var entry := quickslot_set.get_entry(index)
	var icon := _icons[index]
	var counter := _counters[index]
	icon.texture = entry.get_icon() if entry else null
	icon.modulate = Color.WHITE if !entry or entry.is_available() else Color(1, 1, 1, 0.4)
	var count : int = entry.get_count() if entry else -1
	counter.text = str(count)
	counter.visible = count >= 0
	queue_redraw()


func _layout() -> void:
	var centre := size / 2.0
	var icon_radius := radius - ring_width / 2.0
	for i in _icons.size():
		var icon := _icons[i]
		icon.size = Vector2(icon_size, icon_size)
		icon.position = centre + get_slot_direction(i, _icons.size()) * icon_radius - icon.size / 2.0
	queue_redraw()


func _update_centre() -> void:
	if !_name_label:
		return
	var entry := quickslot_set.get_entry(hovered_index) if quickslot_set else null
	_name_label.text = entry.get_display_name() if entry else ""
	var count : int = entry.get_count() if entry else -1
	_count_label.text = "x" + str(count) if count >= 0 else ""
	_count_label.visible = count >= 0


func _draw() -> void:
	var slot_count := _icons.size()
	if slot_count == 0:
		return
	var centre := size / 2.0
	var inner_radius := maxf(radius - ring_width, 0.0)
	var segment := TAU / slot_count
	var gap := deg_to_rad(segment_gap_degrees) if slot_count > 1 else 0.0
	for i in slot_count:
		var mid_angle := get_slot_direction(i, slot_count).angle()
		var from := mid_angle - segment / 2.0 + gap / 2.0
		var to := mid_angle + segment / 2.0 - gap / 2.0
		var points := _ring_segment(centre, inner_radius, radius, from, to)
		draw_colored_polygon(points, segment_color)
		if i == hovered_index:
			draw_colored_polygon(points, hovered_color)
			points.append(points[0])
			draw_polyline(points, outline_color, 2.0, true)
	draw_circle(centre, maxf(inner_radius - 6.0, 0.0), segment_color)
	if !_stick.is_zero_approx():
		draw_circle(centre + _stick * maxf(inner_radius - 12.0, 0.0), 4.0, outline_color)


func _ring_segment(centre: Vector2, inner: float, outer: float, from: float, to: float) -> PackedVector2Array:
	var steps := maxi(ceili((to - from) / deg_to_rad(6.0)), 1)
	var points := PackedVector2Array()
	for s in steps + 1:
		points.append(centre + Vector2.from_angle(lerpf(from, to, float(s) / steps)) * outer)
	for s in range(steps, -1, -1):
		var point := centre + Vector2.from_angle(lerpf(from, to, float(s) / steps)) * inner
		if inner <= 0.0:
			points.append(centre)
			break
		points.append(point)
	return points


func _make_label() -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label
#endregion

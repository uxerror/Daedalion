extends CogitoQuickslotView
class_name CogitoQuickslotWheel

## Radial quick-select menu for any CogitoQuickslotSet.
## Hold open_action to open the wheel, point in a direction (mouse motion or the right stick) to hover a slot,
## release open_action to activate the hovered slot. Releasing while pointing at the centre cancels.
## The mouse stays captured: mouse motion is accumulated into a virtual stick, the cursor position is never used.
## While open, the wheel takes over input through the InputRouter, so the player doesn't look around, move or use wieldables.
## Slots keep their position: slot 0 is at the top, the others follow clockwise. Empty slots are drawn as empty segments.
## Add the wheel to CogitoQuickslots.views, CogitoQuickslots then gives it its set and forwards the open_action to it.
## Without CogitoQuickslots, set quickslot_set (and context_set) and call open()/close() yourself.
##
## Submenus: quickslot_set is the root menu. Every entry with a non-empty CogitoQuickslotEntry.get_submenu() opens that set
## as a submenu, at any level: a CogitoSubmenuQuickslotEntry, or a quickslotted item that offers a set (for example the ammo
## types of a toy pistol, equipped or not). Such segments get a small marker. Inside a submenu the wheel adds a Back segment.
## Press confirm_action on a segment with a submenu or on Back to navigate (or hover it for submenu_hover_time).
## Releasing open_action always activates the hovered entry like its quickslot key does (for an item: use / equip it,
## for a CogitoSubmenuQuickslotEntry: nothing), over Back or the context segment it closes without activating anything.
## The context_set (the equipped wieldable's set) is usually the submenu of the wieldable's quickslot. If no root slot leads
## to it (for example the wieldable was equipped from the inventory), the root gets an extra context segment instead,
## drawn with the context set's icon.
## Back and the context segment are drawn by the wheel, they are not entries of any set, so slot indices and other views
## (the quickslot bar) don't change. They are always the last segment, just counter-clockwise of slot 0.

## Emitted when the wheel opens.
signal opened
## Emitted when the wheel closes. activated_index is the slot that got activated on close, -1 if none.
signal closed(activated_index: int)
## Emitted when the wheel entered a submenu or went back. current_set is the set that is shown now.
signal menu_changed(current_set: CogitoQuickslotSet)

## Shown in the centre while the Back segment is hovered.
const BACK_TEXT : String = "QUICKSLOT_back"

## Holding this action keeps the wheel open.
@export var open_action : String = "quickslot_wheel"
## If true, releasing open_action activates the hovered slot. If false, confirm_action activates the hovered slot
## (the wheel stays open) and releasing open_action only closes the wheel.
@export var activate_on_release : bool = true
## Enters the hovered submenu / goes back when the Back segment is hovered.
## Also activates the hovered slot when activate_on_release is false.
@export var confirm_action : String = "action_primary"
## If true and there is a context_set (the equipped wieldable's set), the wheel opens inside it, Back leads to quickslot_set.
## If false, the wheel opens at quickslot_set and the context set is one segment of it.
@export var open_in_wieldable_set : bool = true
## Hovering a segment with a submenu, the context set segment or Back for this many seconds (real time) navigates without confirm_action. 0 = off.
@export var submenu_hover_time : float = 0.0
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
## Fill of the segments drawn by the wheel (Back, the context set segment) and of the submenu marker.
@export var navigation_color : Color = Color(0.2, 0.2, 0.2, 0.85)
## Icon of the Back segment. If empty, an arrow is drawn.
@export var back_icon : Texture2D

@export_group("Sounds")
## Plays when the wheel opens.
@export var sound_open : AudioStream
## Plays when a non-empty slot gets hovered.
@export var sound_hover : AudioStream
## Plays when the wheel enters a submenu or goes back.
@export var sound_navigate : AudioStream

## True while the wheel is open.
var is_open : bool = false
## The segment that is currently hovered, -1 if none. Segments 0 to current_set.size() - 1 are the slots of current_set,
## get_navigation_index() is the Back / context set segment.
var hovered_index : int = -1
## The set that is shown right now: quickslot_set at the root, otherwise the submenu that was entered last.
var current_set : CogitoQuickslotSet:
	get: return _path.back() if !_path.is_empty() else quickslot_set
## Context passed to CogitoQuickslotSet.activate() (usually the player). Set by CogitoQuickslots when it opens the wheel.
var activation_context : Object

# Current direction, length 0-1. Mouse motion accumulates into it, the gamepad stick sets it.
var _stick : Vector2 = Vector2.ZERO
var _joy : Vector2 = Vector2.ZERO
var _joy_device : int = -1
# After navigating, the gamepad stick has to return to the centre before it hovers again.
var _joy_needs_recentre : bool = false
# Submenus entered since opening, below the root (quickslot_set).
var _path : Array[CogitoQuickslotSet] = []
# The set whose signals are connected (the shown set while open).
var _shown_set : CogitoQuickslotSet
# Selection of every set shown while open, from before it got shown (or after an activation). Restored on leaving / closing.
var _selection_before : Dictionary = {}
var _hover_started_msec : int = 0
var _time_scale_before_open : float = -1.0
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
		return
	if submenu_hover_time > 0.0 and _is_hovering_navigation() and Time.get_ticks_msec() - _hover_started_msec >= submenu_hover_time * 1000.0:
		_navigate_hovered()


## Replacing the set while the wheel is open closes it without activating anything.
func set_quickslot_set(new_set: CogitoQuickslotSet) -> void:
	if is_open and new_set != quickslot_set:
		close(false)
	super.set_quickslot_set(new_set)


## Replacing the context set while the wheel is open (for example the equipped wieldable changed) closes it without activating anything.
func set_context_set(new_set: CogitoQuickslotSet) -> void:
	if is_open and new_set != context_set:
		close(false)
	super.set_context_set(new_set)


## Called by CogitoQuickslots with input it receives while the player has input focus.
## Opens the wheel when open_action gets pressed. Returns true if the event was consumed.
func handle_quickslot_input(event: InputEvent, context: Object) -> bool:
	if is_open or !_is_action(event, open_action) or !event.is_pressed() or event.is_echo():
		return false
	activation_context = context
	return open()


## Opens the wheel, inside the context set if open_in_wieldable_set. Returns false if there is nothing to show.
func open() -> bool:
	if is_open or !is_inside_tree():
		return false
	_path.clear()
	if open_in_wieldable_set and _has_context_set():
		_path.append(context_set)
	if get_segment_count() == 0:
		_path.clear()
		return false
	is_open = true
	_stick = Vector2.ZERO
	_joy = Vector2.ZERO
	_joy_device = -1
	_joy_needs_recentre = false
	_selection_before.clear()
	_show_set(current_set)
	if time_scale_while_open < 1.0 and not CogitoNet.is_online():
		_time_scale_before_open = Engine.time_scale
		Engine.time_scale = time_scale_while_open
	InputRouter.push(_on_router_input)
	set_process(true)
	show()
	CogitoAudio.play_sound(sound_open)
	CogitoGlobals.debug_log(true, "cogito_quickslot_wheel.gd", "Opened with " + str(get_segment_count()) + " segments, in a submenu: " + str(!_path.is_empty()))
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
	if activate and _activate_hovered():
		activated_index = hovered_index
	# Activated sets keep their new selection (_activate_hovered() stored it), everything else is restored.
	for touched_set: CogitoQuickslotSet in _selection_before:
		touched_set.select(_selection_before[touched_set])
	_selection_before.clear()
	_path.clear()
	_show_set(null)
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


## Number of segments: the slots of current_set, plus the Back / context set segment if there is one.
## At the root there is no context set segment if a slot's submenu is the context set.
func get_segment_count() -> int:
	var slot_count := current_set.size() if current_set else 0
	return slot_count + (1 if _has_navigation_segment() else 0)


## Index of the Back segment (inside a submenu) or the context set segment (at the root), -1 if there is none.
## It is always the last segment.
func get_navigation_index() -> int:
	if !_has_navigation_segment():
		return -1
	return current_set.size() if current_set else 0


## The set that the segment at index of the shown set enters (it gets a marker), or null:
## the entry's submenu (CogitoQuickslotEntry.get_submenu(), only if it has slots and the entry is available),
## or context_set for the context set segment. Back returns null, it goes back instead (see go_back()).
func get_segment_submenu(index: int) -> CogitoQuickslotSet:
	if index < 0:
		return null
	if index == get_navigation_index():
		return context_set if _path.is_empty() else null
	return _get_entry_submenu(current_set.get_entry(index) if current_set else null)


## True if the wheel shows quickslot_set (not a submenu).
func is_at_root() -> bool:
	return _path.is_empty()


## Enters a set as a submenu while the wheel is open. Returns false if the wheel is closed or the set has no slots.
func enter_set(target_set: CogitoQuickslotSet) -> bool:
	if !is_open or !target_set or target_set.size() == 0:
		return false
	_leave_current_set()
	_path.append(target_set)
	_on_navigated()
	return true


## Goes back to the previous set while the wheel is open. Returns false at the root.
func go_back() -> bool:
	if !is_open or _path.is_empty():
		return false
	_leave_current_set()
	_path.pop_back()
	_on_navigated()
	return true


func _on_router_input(event: InputEvent) -> void:
	if !is_open:
		return
	if _is_action(event, open_action):
		# Over a segment with a submenu its entry gets activated like any slot (a pure submenu entry does nothing).
		# Over Back or the context segment this closes without activation, they are no entries.
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
	if _is_action(event, confirm_action) and event.is_pressed() and !event.is_echo():
		if !_navigate_hovered() and !activate_on_release:
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
	if _joy_needs_recentre:
		if _joy.length() > deadzone:
			return
		_joy_needs_recentre = false
	if _joy.length() > deadzone or !gamepad_keeps_hover:
		_stick = _joy.limit_length(1.0)
		_update_hover()


func _update_hover() -> void:
	var new_index := get_slot_at(_stick, get_segment_count(), deadzone)
	if new_index == hovered_index:
		queue_redraw()
		return
	hovered_index = new_index
	_hover_started_msec = Time.get_ticks_msec()
	var shown := current_set
	var entry := _get_hovered_entry()
	if entry:
		shown.select(hovered_index)
	elif shown:
		shown.select(_selection_before.get(shown, -1))
	if entry or _is_hovering_navigation():
		CogitoAudio.play_sound(sound_hover)
	_update_centre()
	queue_redraw()


func _activate_hovered() -> bool:
	var shown := current_set
	var entry := _get_hovered_entry()
	if !entry or !entry.is_available():
		return false
	shown.select(hovered_index)
	if !shown.activate(hovered_index, activation_context):
		return false
	# Keep the selection the activation left (for example the new ammo type) when closing.
	_selection_before[shown] = shown.selected_index
	return true


func _get_hovered_entry() -> CogitoQuickslotEntry:
	return current_set.get_entry(hovered_index) if current_set else null


func _has_context_set() -> bool:
	return context_set != null and context_set.size() > 0 and context_set != quickslot_set


# Back inside a submenu. At the root the context set segment, unless a root slot already leads to the context set.
func _has_navigation_segment() -> bool:
	if !_path.is_empty():
		return true
	if !_has_context_set() or !quickslot_set:
		return false
	for i in quickslot_set.size():
		if _get_entry_submenu(quickslot_set.get_entry(i)) == context_set:
			return false
	return true


func _get_entry_submenu(entry: CogitoQuickslotEntry) -> CogitoQuickslotSet:
	if !entry or !entry.is_available():
		return null
	var submenu := entry.get_submenu()
	return submenu if submenu and submenu.size() > 0 else null


# True if the hovered segment navigates: Back or a segment with a submenu.
func _is_hovering_navigation() -> bool:
	if hovered_index < 0:
		return false
	if !_path.is_empty() and hovered_index == get_navigation_index():
		return true
	return get_segment_submenu(hovered_index) != null


# Enters the hovered segment's submenu, or goes back. Returns false if the hovered segment doesn't navigate.
func _navigate_hovered() -> bool:
	if hovered_index < 0:
		return false
	if !_path.is_empty() and hovered_index == get_navigation_index():
		return go_back()
	var submenu := get_segment_submenu(hovered_index)
	return submenu != null and enter_set(submenu)


# Navigating doesn't change selections: the set that is left gets its selection back.
func _leave_current_set() -> void:
	var shown := current_set
	if shown and _selection_before.has(shown):
		shown.select(_selection_before[shown])


func _on_navigated() -> void:
	_stick = Vector2.ZERO
	_joy_needs_recentre = _joy.length() > deadzone
	_show_set(current_set)
	CogitoAudio.play_sound(sound_navigate)
	CogitoGlobals.debug_log(true, "cogito_quickslot_wheel.gd", "Showing " + ("the root" if _path.is_empty() else "submenu '" + current_set.display_name + "'") + ", " + str(get_segment_count()) + " segments.")
	menu_changed.emit(current_set)


# Connects to the shown set (null while closed) and redraws without hover.
func _show_set(new_set: CogitoQuickslotSet) -> void:
	if _shown_set != new_set:
		if _shown_set:
			_shown_set.slot_changed.disconnect(_on_shown_slot_changed)
			_shown_set.selection_changed.disconnect(_on_shown_selection_changed)
		_shown_set = new_set
		if _shown_set:
			_shown_set.slot_changed.connect(_on_shown_slot_changed)
			_shown_set.selection_changed.connect(_on_shown_selection_changed)
	if new_set and !_selection_before.has(new_set):
		_selection_before[new_set] = new_set.selected_index
	hovered_index = -1
	_hover_started_msec = Time.get_ticks_msec()
	_rebuild()


func _restore_time_scale() -> void:
	if _time_scale_before_open >= 0.0:
		Engine.time_scale = _time_scale_before_open
		_time_scale_before_open = -1.0


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
func _on_shown_slot_changed(index: int) -> void:
	if !is_node_ready():
		return
	if get_segment_count() != _icons.size():
		_rebuild()
		return
	_display_slot(index)
	if index == hovered_index:
		_update_centre()


func _on_shown_selection_changed(_index: int) -> void:
	queue_redraw()


func _rebuild() -> void:
	if !is_node_ready():
		return
	var slot_count := get_segment_count() if is_open else 0
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
	var icon := _icons[index]
	var counter := _counters[index]
	if index == get_navigation_index():
		icon.texture = back_icon if !_path.is_empty() else context_set.icon
		icon.modulate = Color.WHITE
		counter.visible = false
		queue_redraw()
		return
	var entry := current_set.get_entry(index)
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
	var entry := _get_hovered_entry()
	if entry:
		_name_label.text = entry.get_display_name()
	elif hovered_index >= 0 and hovered_index == get_navigation_index():
		_name_label.text = BACK_TEXT if !_path.is_empty() else context_set.display_name
	else:
		# Nothing hovered: the shown set's name as a title (for example the equipped wieldable's name).
		_name_label.text = current_set.display_name if current_set else ""
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
	var navigation_index := get_navigation_index()
	var back_index := navigation_index if !_path.is_empty() else -1
	for i in slot_count:
		var mid_angle := get_slot_direction(i, slot_count).angle()
		var from := mid_angle - segment / 2.0 + gap / 2.0
		var to := mid_angle + segment / 2.0 - gap / 2.0
		var points := _ring_segment(centre, inner_radius, radius, from, to)
		draw_colored_polygon(points, navigation_color if i == navigation_index else segment_color)
		if i == back_index and !back_icon:
			_draw_back_arrow(centre + get_slot_direction(i, slot_count) * (radius - ring_width / 2.0))
		if get_segment_submenu(i):
			_draw_submenu_marker(centre, mid_angle)
		if i == hovered_index:
			draw_colored_polygon(points, hovered_color)
			points.append(points[0])
			draw_polyline(points, outline_color, 2.0, true)
	draw_circle(centre, maxf(inner_radius - 6.0, 0.0), segment_color)
	if !_stick.is_zero_approx():
		draw_circle(centre + _stick * maxf(inner_radius - 12.0, 0.0), 4.0, outline_color)


func _draw_back_arrow(at: Vector2) -> void:
	var half := icon_size * 0.3
	var tip := at - Vector2(half, 0.0)
	draw_line(tip, at + Vector2(half, 0.0), Color.WHITE, 3.0, true)
	draw_polyline(PackedVector2Array([tip + Vector2(half * 0.6, -half * 0.6), tip, tip + Vector2(half * 0.6, half * 0.6)]), Color.WHITE, 3.0, true)


# A small chevron at the outer edge of a slot, pointing outwards: this slot opens a submenu.
func _draw_submenu_marker(centre: Vector2, angle: float) -> void:
	var outward := Vector2.from_angle(angle)
	var side := outward.orthogonal()
	var half := icon_size * 0.15
	var tip := centre + outward * (radius - half * 0.5)
	var back := tip - outward * half
	var points := PackedVector2Array([tip, back + side * half, back - side * half])
	draw_colored_polygon(points, navigation_color)
	points.append(points[0])
	draw_polyline(points, outline_color, 1.5, true)


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

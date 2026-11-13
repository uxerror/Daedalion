extends Control
## HUD element for element states (CogitoProperties): a row of state icons with buildup bars,
## and a screen-edge overlay while frozen, burning, poisoned or chilled (plus a flash when stunned by a SHOCK).
## Bind it with bind() or bind_player(). CogitoPlayerHudManager does this when its element_status_hud is set.
class_name CogitoElementStatusHud

## The states shown, in this order.
enum Status { FIRE, WET, SHOCK, CHILLED, FROZEN, POISON }

## CogitoProperties shown. Usually set through bind() / bind_player().
@export var properties : CogitoProperties
## Optional, used for the stun flash.
@export var actor_elements : CogitoActorElements

@export_group("Icons")
@export var icon_fire : Texture2D
@export var icon_wet : Texture2D
@export var icon_shock : Texture2D
@export var icon_chilled : Texture2D
@export var icon_frozen : Texture2D
@export var icon_poison : Texture2D
@export var icon_size : float = 28.0
## Icon alpha while an element builds up but its state isn't active yet.
@export_range(0.0, 1.0) var buildup_alpha : float = 0.4

@export_group("Colors")
@export var color_fire : Color = Color(1.0, 0.5, 0.1)
@export var color_wet : Color = Color(0.3, 0.6, 1.0)
@export var color_shock : Color = Color(1.0, 0.9, 0.2)
@export var color_chilled : Color = Color(0.65, 0.9, 1.0)
@export var color_frozen : Color = Color(0.85, 0.95, 1.0)
@export var color_poison : Color = Color(0.4, 0.9, 0.2)

@export_group("Screen Overlay")
## Shows the screen-edge overlay.
@export var show_overlay : bool = true
## Seconds the overlay takes to fade in or out.
@export var overlay_fade_time : float = 0.3
## Overlay strength per state.
@export_range(0.0, 1.0) var overlay_fire : float = 0.55
@export_range(0.0, 1.0) var overlay_chilled : float = 0.3
@export_range(0.0, 1.0) var overlay_frozen : float = 0.8
@export_range(0.0, 1.0) var overlay_poison : float = 0.5
@export_range(0.0, 1.0) var overlay_shock_flash : float = 0.7
## Seconds the stun flash lasts.
@export var shock_flash_time : float = 0.35

## Seconds between bar updates while any element level is above zero.
const UPDATE_INTERVAL := 0.1

@onready var row : HBoxContainer = $Row
@onready var overlay : ColorRect = $Overlay

var _entries : Dictionary = {} # Status -> {root, icon, fill}
var _timer : Timer
var _overlay_material : ShaderMaterial
var _overlay_tween : Tween
var _overlay_target : float = 0.0
var _overlay_state : int = -1
var _flash_left : float = 0.0
var _connections : Array = [] # [Signal, Callable] made by bind()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_material = overlay.material as ShaderMaterial
	overlay.visible = false
	_timer = Timer.new()
	_timer.wait_time = UPDATE_INTERVAL
	_timer.timeout.connect(refresh)
	add_child(_timer)
	_build_entries()
	set_process(false)
	if properties:
		bind(properties, actor_elements)
	else:
		refresh()


## Binds the HUD to the element states of a player (its cogito_properties and actor_elements). Does nothing without them.
func bind_player(player: Node) -> void:
	var props := CogitoProperties.get_properties_of(player)
	var elements = player.get("actor_elements") if player else null
	bind(props, elements as CogitoActorElements)


## Binds the HUD to a CogitoProperties (and optionally CogitoActorElements for the stun flash).
func bind(new_properties: CogitoProperties, new_actor_elements: CogitoActorElements = null) -> void:
	_disconnect_all()
	properties = new_properties
	actor_elements = new_actor_elements
	if properties:
		for sig in [properties.has_ignited, properties.has_been_extinguished, properties.has_become_wet,
				properties.has_become_dry, properties.has_become_electric, properties.has_lost_electricity,
				properties.has_become_chilled, properties.has_warmed_up, properties.has_frozen, properties.has_thawed,
				properties.has_been_poisoned, properties.has_been_cured, properties.burned_out]:
			_connect(sig, refresh)
		_connect(properties.element_applied, _on_element_applied)
		_connect(properties.reaction_triggered, _on_reaction)
		if !actor_elements:
			_connect(properties.has_become_electric, flash_shock)
	if actor_elements:
		_connect(actor_elements.stunned, flash_shock)
		_connect(actor_elements.struggled, _on_struggled)
	refresh()


func _connect(sig: Signal, callable: Callable) -> void:
	if !sig.is_connected(callable):
		sig.connect(callable)
		_connections.append([sig, callable])


func _disconnect_all() -> void:
	for connection in _connections:
		var sig : Signal = connection[0]
		if is_instance_valid(sig.get_object()) and sig.is_connected(connection[1]):
			sig.disconnect(connection[1])
	_connections.clear()


func _on_element_applied(_element, _amount, _source) -> void:
	refresh()


func _on_reaction(_reaction) -> void:
	refresh()


func _on_struggled(_remaining) -> void:
	refresh()


## True if the icon of a state is visible.
func is_status_visible(status: Status) -> bool:
	return _entries.has(status) and _entries[status].root.visible


## True if the icon of a state is shown as active (not only building up).
func is_status_active(status: Status) -> bool:
	return is_status_visible(status) and _entries[status].icon.modulate.a > buildup_alpha + 0.01


## Bar value (0..1) of a state.
func get_status_value(status: Status) -> float:
	return _entries[status].fill.anchor_right if _entries.has(status) else 0.0


## The state the overlay shows, or -1.
func get_overlay_status() -> int:
	return _overlay_state


## Updates icons, bars and the overlay from the bound properties.
func refresh() -> void:
	if !is_node_ready():
		return
	var props := properties if is_instance_valid(properties) else null
	for status in _entries:
		var active := false
		var value := 0.0
		if props:
			var info := _status_info(props, status)
			active = info.x > 0.5
			value = info.y
		_set_entry(status, active, value)
	_update_overlay(props)
	# Bars only need updating while something decays or burns down.
	var needs_timer : bool = props != null and (!props.element_levels.is_empty() or props.is_on_fire)
	if needs_timer and _timer.is_stopped():
		_timer.start()
	elif !needs_timer and !_timer.is_stopped():
		_timer.stop()


## Returns Vector2(active, bar value) of a state.
func _status_info(props: CogitoProperties, status: Status) -> Vector2:
	var threshold := maxf(props.buildup_threshold, 0.001)
	match status:
		Status.FIRE:
			if props.is_on_fire:
				if props.fuel > 0.0:
					return Vector2(1, clampf(props.fuel_remaining / props.fuel, 0.0, 1.0))
				return Vector2(1, 1)
			return Vector2(0, clampf(props.get_element_level(CogitoProperties.Element.FIRE) / threshold, 0.0, 1.0))
		Status.WET:
			return _level_info(props, CogitoProperties.Element.WATER, props.is_wet)
		Status.SHOCK:
			return _level_info(props, CogitoProperties.Element.SHOCK, props.is_electric)
		Status.CHILLED:
			if props.is_frozen:
				return Vector2.ZERO # The FROZEN icon shows the cold.
			return _level_info(props, CogitoProperties.Element.COLD, props.is_chilled)
		Status.FROZEN:
			if !props.is_frozen:
				return Vector2.ZERO
			return Vector2(1, clampf(props.get_element_level(CogitoProperties.Element.COLD) / threshold, 0.0, 1.0))
		Status.POISON:
			return _level_info(props, CogitoProperties.Element.POISON, props.is_poisoned)
	return Vector2.ZERO


func _level_info(props: CogitoProperties, element: CogitoProperties.Element, active: bool) -> Vector2:
	var value := clampf(props.get_element_level(element) / maxf(props.buildup_threshold, 0.001), 0.0, 1.0)
	return Vector2(1.0 if active else 0.0, value)


func _set_entry(status: Status, active: bool, value: float) -> void:
	var entry : Dictionary = _entries[status]
	var shown := active or value > 0.0
	entry.root.visible = shown
	if !shown:
		return
	entry.icon.modulate.a = 1.0 if active else buildup_alpha
	entry.fill.anchor_right = value
	entry.fill.modulate.a = 1.0 if active else buildup_alpha


func _build_entries() -> void:
	for child in row.get_children():
		child.queue_free()
	var setup := {
		Status.FIRE: [icon_fire, color_fire],
		Status.WET: [icon_wet, color_wet],
		Status.SHOCK: [icon_shock, color_shock],
		Status.CHILLED: [icon_chilled, color_chilled],
		Status.FROZEN: [icon_frozen, color_frozen],
		Status.POISON: [icon_poison, color_poison],
	}
	for status in setup:
		var entry_root := VBoxContainer.new()
		entry_root.name = Status.keys()[status]
		entry_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		entry_root.add_theme_constant_override("separation", 2)
		var icon := TextureRect.new()
		icon.texture = setup[status][0]
		icon.self_modulate = setup[status][1]
		icon.custom_minimum_size = Vector2(icon_size, icon_size)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		entry_root.add_child(icon)
		var bar := ColorRect.new()
		bar.color = Color(0, 0, 0, 0.5)
		bar.custom_minimum_size = Vector2(icon_size, 4)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var fill := ColorRect.new()
		fill.color = setup[status][1]
		fill.anchor_bottom = 1.0
		fill.anchor_right = 0.0
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.add_child(fill)
		entry_root.add_child(bar)
		entry_root.visible = false
		row.add_child(entry_root)
		_entries[status] = {"root": entry_root, "icon": icon, "fill": fill}


#region Overlay

## Briefly flashes the screen edges (stun by SHOCK).
func flash_shock() -> void:
	if !show_overlay or overlay_shock_flash <= 0.0:
		return
	_flash_left = shock_flash_time
	_apply_overlay_look(Status.SHOCK)
	_overlay_state = Status.SHOCK
	_fade_overlay_to(overlay_shock_flash, 0.05)
	set_process(true)


func _process(delta: float) -> void:
	_flash_left -= delta
	if _flash_left <= 0.0:
		_flash_left = 0.0
		set_process(false)
		_overlay_state = -2 # Forces the state look (or the fade out) to be applied again.
		_update_overlay(properties if is_instance_valid(properties) else null)


func _update_overlay(props: CogitoProperties) -> void:
	if _flash_left > 0.0:
		return # The flash ends first.
	var status := -1
	var strength := 0.0
	if props and show_overlay:
		# Priority: frozen > fire > poison > chilled.
		if props.is_frozen:
			status = Status.FROZEN; strength = overlay_frozen
		elif props.is_on_fire:
			status = Status.FIRE; strength = overlay_fire
		elif props.is_poisoned:
			status = Status.POISON; strength = overlay_poison
		elif props.is_chilled:
			status = Status.CHILLED; strength = overlay_chilled
	if status != _overlay_state:
		_overlay_state = status
		if status != -1:
			_apply_overlay_look(status)
		_fade_overlay_to(strength, overlay_fade_time)


func _apply_overlay_look(status: int) -> void:
	if !_overlay_material:
		return
	var tint := color_fire
	var flicker := 0.0
	var pulse := 0.0
	match status:
		Status.FIRE:
			tint = color_fire; flicker = 1.0
		Status.CHILLED:
			tint = color_chilled
		Status.FROZEN:
			tint = color_frozen
		Status.POISON:
			tint = color_poison; pulse = 1.0
		Status.SHOCK:
			tint = color_shock; flicker = 0.5
	_overlay_material.set_shader_parameter("tint", tint)
	_overlay_material.set_shader_parameter("flicker", flicker)
	_overlay_material.set_shader_parameter("pulse", pulse)


func _fade_overlay_to(target: float, time: float) -> void:
	if !_overlay_material:
		return
	if is_equal_approx(target, _overlay_target) and (target > 0.0) == overlay.visible:
		return
	_overlay_target = target
	if _overlay_tween:
		_overlay_tween.kill()
	if target > 0.0:
		overlay.visible = true
	var current = _overlay_material.get_shader_parameter("intensity")
	var from : float = current if current != null else 0.0
	_overlay_tween = create_tween()
	_overlay_tween.tween_method(_set_overlay_intensity, from, target, maxf(time, 0.01))
	if target <= 0.0:
		_overlay_tween.tween_callback(func(): overlay.visible = false)


func _set_overlay_intensity(value: float) -> void:
	_overlay_material.set_shader_parameter("intensity", value)


## True while the overlay is shown (fading counts).
func is_overlay_visible() -> bool:
	return overlay.visible

#endregion

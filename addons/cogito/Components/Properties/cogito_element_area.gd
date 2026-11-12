extends Area3D
## A volume that keeps exposing everything inside it to an element: campfire, rain, poison gas, a puddle.
## Each tick, bodies and areas inside get element buildup through their CogitoProperties
## (or their own apply_element(), e.g. other element areas), and anything with a
## damage_received signal takes damage of the area's element.
## Set collision_mask to the layers that should be affected (e.g. Interactables, Player, NPC).
class_name CogitoElementArea

## Emitted when the area gets switched on or off (interact(), douse, reignite).
signal enabled_changed(is_enabled: bool)
## Emitted on reactions with other elements: &"douse" (water put the fire out), &"ignite" (fire relit it).
signal reaction_triggered(reaction: StringName)
signal has_become_electric()
signal has_lost_electricity()

## Interval of element ticks, in seconds.
const TICK := 0.25

## Element this area applies.
@export var element : CogitoProperties.Element = CogitoProperties.Element.FIRE
## If off, the area applies nothing (it can still conduct electricity and react).
@export var enabled : bool = true : set = set_enabled
## Element buildup per second applied to everything inside (in buildup_threshold units).
## Has to be higher than the targets' buildup_decay_per_second to change their state.
@export var amount_per_second : float = 2.0
## Damage per second of the area's element dealt to everything inside. 0 = buildup only.
@export var damage_per_second : float = 0.0
## Nodes that are only visible while the area is enabled (flames, rain particles, ...).
@export var visuals : Array[Node3D] = []

@export_group("Reactions")
## FIRE areas: WATER buildup that puts the area out. 0 = can't be doused.
@export var douse_threshold : float = 1.0
## FIRE areas: FIRE buildup that lights a doused area again. 0 = stays out.
@export var reignite_threshold : float = 1.0
## Reaction buildup lost per second.
@export var reaction_decay_per_second : float = 0.5
## Electricity spreads through the area (water, puddles): while an electric body is inside, or
## after a SHOCK hit, everything inside gets shocked.
@export var conducts_shock : bool = false
## SHOCK buildup per second applied to everything inside while the area is electrified.
@export var shock_amount_per_second : float = 2.0
## SHOCK damage per second dealt to everything inside while the area is electrified.
@export var shock_damage_per_second : float = 0.0
## Seconds the area stays electrified after a SHOCK hit or after the last electric body left.
@export var shock_hold_time : float = 1.0

@export_group("Debuging")
@export var is_logging : bool = false

var is_electric : bool = false
var _levels : Dictionary = {} # Element -> reaction buildup
var _shock_time_left : float = 0.0
## Properties electrified by this area. They don't count as sources, so the area can't keep itself charged.
var _charged_by_me : Dictionary = {}
var _timer : Timer


func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = TICK
	_timer.autostart = true
	_timer.timeout.connect(_tick)
	add_child(_timer)
	_update_visuals()


func set_enabled(value: bool) -> void:
	if enabled == value:
		return
	enabled = value
	if is_inside_tree():
		_update_visuals()
		_log("enabled" if value else "disabled")
	enabled_changed.emit(value)


## Toggles the area. Lets CogitoButton/CogitoSwitch (objects_call_interact) switch it.
func interact(_player_interaction_component = null) -> void:
	set_enabled(!enabled)


## Exposes the area to an element, see CogitoProperties.apply_element(). Returns the amount used.
func apply_element(applied: CogitoProperties.Element, amount: float, _source: Node = null) -> float:
	if amount <= 0.0:
		return 0.0
	var is_fire_area := element == CogitoProperties.Element.FIRE
	match applied:
		CogitoProperties.Element.WATER:
			if is_fire_area and enabled and douse_threshold > 0.0:
				if _add_level(applied, amount) >= douse_threshold:
					_levels.clear()
					set_enabled(false)
					reaction_triggered.emit(&"douse")
				return amount
		CogitoProperties.Element.FIRE:
			if is_fire_area and !enabled and reignite_threshold > 0.0:
				if _add_level(applied, amount) >= reignite_threshold:
					_levels.clear()
					set_enabled(true)
					reaction_triggered.emit(&"ignite")
				return amount
		CogitoProperties.Element.SHOCK:
			if conducts_shock:
				_shock_time_left = maxf(_shock_time_left, shock_hold_time)
				_set_electric(true)
				return amount
	return 0.0


func _tick() -> void:
	var delta := _timer.wait_time
	for key in _levels.keys():
		_levels[key] -= reaction_decay_per_second * delta
		if _levels[key] <= 0.0:
			_levels.erase(key)
	
	var targets : Array = []
	targets.append_array(get_overlapping_bodies())
	for area in get_overlapping_areas():
		if area != self and area.has_method("apply_element"):
			targets.append(area)
	
	if enabled:
		var amount := amount_per_second * delta
		var damage := damage_per_second * delta
		for target in targets:
			if amount > 0.0:
				CogitoProperties.apply_element_to(target, element, amount, self)
			if damage > 0.0:
				CogitoProperties.deal_elemental_damage(target, damage, element, self)
	
	if conducts_shock:
		_tick_shock(targets, delta)


func _tick_shock(targets: Array, delta: float) -> void:
	for props in _charged_by_me.keys():
		if !is_instance_valid(props) or !props.is_electric:
			_charged_by_me.erase(props)
	
	var bodies : Array = []
	var has_source := false
	for target in targets:
		if !(target is PhysicsBody3D):
			continue # Electricity doesn't jump between areas.
		bodies.append(target)
		var props := CogitoProperties.get_properties_of(target)
		if props and props.is_electric and !_charged_by_me.has(props):
			has_source = true
	
	if has_source:
		_shock_time_left = shock_hold_time
	else:
		_shock_time_left -= delta
	_set_electric(_shock_time_left > 0.0)
	if !is_electric:
		return
	
	for body in bodies:
		var props := CogitoProperties.get_properties_of(body)
		if props:
			if props.is_electric and !_charged_by_me.has(props):
				continue # The source itself.
			var was_electric := props.is_electric
			props.apply_element(CogitoProperties.Element.SHOCK, shock_amount_per_second * delta, self)
			if !was_electric and props.is_electric:
				_charged_by_me[props] = true
		if shock_damage_per_second > 0.0:
			CogitoProperties.deal_elemental_damage(body, shock_damage_per_second * delta, CogitoProperties.Element.SHOCK, self)


func _set_electric(value: bool) -> void:
	if is_electric == value:
		return
	is_electric = value
	if value:
		_log("electrified")
		has_become_electric.emit()
	else:
		# _charged_by_me is kept: bodies still carrying our charge must not re-electrify the area.
		_shock_time_left = 0.0
		_log("lost electricity")
		has_lost_electricity.emit()


func _add_level(key: CogitoProperties.Element, amount: float) -> float:
	_levels[key] = _levels.get(key, 0.0) + amount
	return _levels[key]


func _update_visuals() -> void:
	for node in visuals:
		if is_instance_valid(node):
			node.visible = enabled


func _log(message: String) -> void:
	CogitoGlobals.debug_log(is_logging, "cogito_element_area.gd", name + ": " + message)

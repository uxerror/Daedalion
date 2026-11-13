@icon("res://addons/cogito/Assets/Graphics/Editor/Icon_CogitoProperties.svg")
extends Node
## Turns the element states of an actor (player, NPC) into movement and action effects.
## Sits next to the actor's CogitoProperties: chilled actors move slower, frozen ones can't move or jump
## (they can struggle free), a SHOCK stuns them for a moment. Actors read speed_multiplier, can_jump() and can_act().
class_name CogitoActorElements

## Emitted when speed_multiplier changed.
signal movement_changed(speed_multiplier: float)
## Emitted when a SHOCK stunned the actor.
signal stunned()
## Emitted when a stun wore off.
signal stun_ended()
## Emitted when struggle() lowered the freeze. remaining is the COLD level left (0 = broke free).
signal struggled(remaining: float)

## The actor's CogitoProperties. Leave empty to use a sibling or child CogitoProperties.
@export var properties : CogitoProperties

@export_group("Cold")
## Speed multiplier while chilled.
@export_range(0.0, 1.0, 0.01) var chilled_speed_multiplier : float = 0.6
## If on, a frozen actor can't act (interact, use wieldables or items). It can always look around.
@export var frozen_blocks_actions : bool = true
## COLD removed per struggle() call, in buildup_threshold units. When the level runs out the actor thaws.
@export var struggle_per_press : float = 0.2
## Seconds after a freeze ended in which the actor can be chilled but not frozen again, so it can walk out of a cold source.
@export var refreeze_immunity_time : float = 3.0
## If off (default), COLD doesn't refresh a freeze on this actor (properties.frozen_absorbs_cold is turned off),
## so struggling always gets it free, even inside a cold source. Turn on for the object-like behaviour.
@export var absorb_cold_while_frozen : bool = false
## If on, the actor struggles by itself every npc_struggle_interval seconds while frozen (for NPCs).
## Players call struggle() on movement input instead.
@export var auto_struggle : bool = false
## Seconds between struggles with auto_struggle.
@export var npc_struggle_interval : float = 0.5

@export_group("Shock")
## Seconds a SHOCK stuns the actor. 0 = no stun.
@export var shock_stun_time : float = 0.5
## Seconds after a stun in which a new SHOCK doesn't stun again (damage still applies).
@export var shock_stun_cooldown : float = 1.5

## Multiplier for the actor's movement speed: 1 normally, chilled_speed_multiplier while chilled,
## 0 while frozen or stunned. Read only.
var speed_multiplier : float = 1.0
## True while a SHOCK stun lasts. Read only.
var is_stunned : bool = false
## Seconds left of the current stun. Read only.
var stun_time_left : float = 0.0
## Seconds left in which a new SHOCK doesn't stun. Read only.
var stun_cooldown_left : float = 0.0

var _struggle_tick : float = 0.0
var _immunity_left : float = 0.0


func _ready() -> void:
	add_to_group(CogitoProperties.ELEMENT_STATE_GROUP)
	if !properties:
		properties = _find_properties()
	if properties:
		properties.element_state_restored.connect(_update_movement)
		properties.has_become_chilled.connect(_update_movement)
		properties.has_warmed_up.connect(_update_movement)
		properties.has_frozen.connect(_on_frozen)
		properties.has_thawed.connect(_on_thawed)
		properties.frozen_absorbs_cold = absorb_cold_while_frozen
		properties.element_applied.connect(_on_element_applied)
		properties.has_become_electric.connect(_on_shocked)
		properties.elemental_damage_taken.connect(_on_damage_taken)
	else:
		CogitoGlobals.debug_log(true, "cogito_actor_elements.gd", get_parent().name + ": no CogitoProperties found.")
	_update_movement()
	_update_processing()


## The CogitoProperties of a node's actor elements, found next to it or below it.
func _find_properties() -> CogitoProperties:
	var parent := get_parent()
	if !parent:
		return null
	for child in parent.get_children():
		if child is CogitoProperties:
			return child
	var found := find_children("", "CogitoProperties", true, false)
	if found.size() > 0:
		return found[0]
	return null


func is_frozen() -> bool:
	return properties != null and properties.is_frozen


func is_chilled() -> bool:
	return properties != null and properties.is_chilled


func is_on_fire() -> bool:
	return properties != null and properties.is_on_fire


## False while frozen or stunned.
func can_jump() -> bool:
	return !is_stunned and !is_frozen()


## False while stunned, and while frozen if frozen_blocks_actions is on.
## Actors check this before interacting, using wieldables or items.
func can_act() -> bool:
	if is_stunned:
		return false
	return !(frozen_blocks_actions and is_frozen())


## True while the actor can't move at all (frozen or stunned).
func is_movement_locked() -> bool:
	return speed_multiplier <= 0.0


## Struggles against a freeze: removes struggle_per_press of COLD. The actor thaws when it runs out.
## Returns true if the actor was frozen.
func struggle() -> bool:
	if !is_frozen():
		return false
	var remaining := properties.reduce_element(CogitoProperties.Element.COLD, struggle_per_press * properties.buildup_threshold)
	struggled.emit(remaining)
	return true


## Stuns the actor for seconds, unless it is still immune from the last stun.
## Returns true if the actor got stunned.
func stun(seconds: float = shock_stun_time) -> bool:
	if seconds <= 0.0 or is_stunned or stun_cooldown_left > 0.0:
		return false
	is_stunned = true
	stun_time_left = seconds
	_update_movement()
	_update_processing()
	stunned.emit()
	return true


## Returns the stun and freeze timers as a dictionary of plain values, see CogitoProperties.get_element_save_data().
func get_element_save_data() -> Dictionary:
	return {
		"v": CogitoProperties.ELEMENT_SAVE_VERSION,
		"stunned": is_stunned,
		"stun_time_left": stun_time_left,
		"stun_cooldown_left": stun_cooldown_left,
		"immunity_left": _immunity_left,
		"struggle_tick": _struggle_tick,
	}


## Restores timers saved with get_element_save_data(). Apply the CogitoProperties data first.
## Doesn't emit stunned or stun_ended.
func apply_element_save_data(data: Dictionary) -> void:
	if data.is_empty():
		return
	is_stunned = bool(data.get("stunned", false))
	stun_time_left = float(data.get("stun_time_left", 0.0))
	stun_cooldown_left = float(data.get("stun_cooldown_left", 0.0))
	_immunity_left = float(data.get("immunity_left", 0.0))
	_struggle_tick = float(data.get("struggle_tick", 0.0))
	if properties:
		properties.freeze_immune = _immunity_left > 0.0
	_update_movement()


func _on_element_applied(element: CogitoProperties.Element, _amount: float, _source: Node) -> void:
	if element == CogitoProperties.Element.SHOCK:
		_on_shocked()


func _on_damage_taken(_amount: float, element: CogitoProperties.Element, _source: Node) -> void:
	if element == CogitoProperties.Element.SHOCK:
		_on_shocked()


func _on_shocked() -> void:
	stun(shock_stun_time)


func _on_frozen() -> void:
	_struggle_tick = 0.0
	_update_movement()


func _on_thawed() -> void:
	if refreeze_immunity_time > 0.0:
		_immunity_left = refreeze_immunity_time
		properties.freeze_immune = true
	_update_movement()


func _update_movement() -> void:
	var value := 1.0
	if is_stunned or is_frozen():
		value = 0.0
	elif is_chilled():
		value = chilled_speed_multiplier
	if !is_equal_approx(value, speed_multiplier):
		speed_multiplier = value
		movement_changed.emit(speed_multiplier)
	_update_processing()


func _update_processing() -> void:
	set_process(is_stunned or stun_cooldown_left > 0.0 or _immunity_left > 0.0 or (auto_struggle and is_frozen()))


func _process(delta: float) -> void:
	if _immunity_left > 0.0:
		_immunity_left -= delta
		if _immunity_left <= 0.0:
			_immunity_left = 0.0
			if properties:
				properties.freeze_immune = false
	if is_stunned:
		stun_time_left -= delta
		if stun_time_left <= 0.0:
			stun_time_left = 0.0
			is_stunned = false
			stun_cooldown_left = shock_stun_cooldown
			_update_movement()
			stun_ended.emit()
	elif stun_cooldown_left > 0.0:
		stun_cooldown_left = maxf(0.0, stun_cooldown_left - delta)

	if auto_struggle and is_frozen():
		_struggle_tick += delta
		var interval := maxf(npc_struggle_interval, 0.01)
		while _struggle_tick >= interval and is_frozen():
			_struggle_tick -= interval
			struggle()

	_update_processing()

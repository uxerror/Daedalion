@icon("res://addons/cogito/Assets/Graphics/Editor/Icon_CogitoProperties.svg")
extends Node3D
## This class handles systeminc properties. Needs to be attached to a CogitoObject to work properly. For proper processing, said Object needs to have a signal hooked up to call check_for_systemic_interactions(collider).
class_name CogitoProperties

signal has_ignited()
signal has_been_extinguished()
signal deal_burn_damage(burn_damage_amount:float)
signal has_become_wet()
signal has_become_dry()
signal has_become_electric()
signal has_lost_electricity()
## Emitted when an element was applied through apply_element() (after resistances).
signal element_applied(element: Element, amount: float, source: Node)
## Emitted when two elements react with each other, e.g. &"steam" (fire on wet), &"douse" (water on fire).
signal reaction_triggered(reaction: StringName)
## Emitted when a burning object ran out of fuel (see fuel and burn_out_result).
signal burned_out()

## Elements used for buildup, reactions, resistances and damage types.
enum Element {
	PHYSICAL,
	FIRE,
	COLD,
	SHOCK,
	WATER,
	POISON,
}

enum ElementalProperties{
	CONDUCTIVE = 1,
	FLAMMABLE = 2,
	WET = 4,
}

## What happens when a burning object runs out of fuel.
enum BurnOutResult {
	NOTHING, ## Goes out and can be lit again with full fuel.
	CHAR, ## Goes out and is no longer FLAMMABLE.
	DESTROY, ## Goes out and frees the parent object.
}

enum MaterialProperties{
	SOFT = 1,
}

@onready var damage_timer: Timer = $DamageTimer
@onready var reaction_timer: Timer = $ReactionTimer

## Bitflag for elemental properties. Gets handled when a collision calls "check_for_systemic_interactions(collider)".
@export_flags("CONDUCTIVE", "FLAMABLE", "WET") var elemental_properties: int = 0
## Bitflag for material properites. Gets handled when a projectile or similar damage call applies. SOFT materials can get damaged by SOFT projectiles.
@export_flags("SOFT") var material_properties: int = 0

## Time it takes for a property state change to happen. E.g. an object only ignites if exposed to fire for at least 1 second.
@export var reaction_threshold_time : float = 1.0
## The maximum amount of spawned vfx. Lower this to reduce potential performance issues.
@export var max_spawned_vfx : int = 5

@export_group("Burn Parameters")
## Sets if the object should ignite itself on ready. Needs to be flammable for this to work.
@export var ignite_on_ready : bool
## Amount of damage dealt to the health component while object is on fire.
@export var burn_damage_amount : float
## Interval the burn damage is applied in seconds.
@export var burn_damage_interval : float = 1.0


@export_group("Heat and Fuel")
## Radius in meters in which a burning object heats up its surroundings, so fire can spread. 0 = off.
@export var heat_radius : float = 0.0
## FIRE buildup per second applied to everything inside heat_radius while burning.
## Has to be higher than the neighbours' buildup_decay_per_second to ignite them.
@export var heat_per_second : float = 2.0
## Physics layers scanned for things to heat up (bodies and element areas).
@export_flags_3d_physics var heat_collision_mask : int = 1 | 2 | 4 | 32
## Seconds this object can burn before it burns out. Negative = burns forever.
@export var fuel : float = -1.0
## What happens when the fuel runs out.
@export var burn_out_result : BurnOutResult = BurnOutResult.CHAR


@export_group("Electricity Parameters")
## Sets if the object should become electrified on ready. Needs to be conductive for this to work.
@export var electric_on_ready : bool


@export_group("Element Buildup")
## Amount of an element needed to change state (ignite, get wet, get electrified).
## apply_element() amounts are measured in this unit, so 1.0 = exactly enough.
@export var buildup_threshold : float = 1.0
## Upper limit for stored buildup. Higher values let strong effects last longer.
@export var buildup_max : float = 3.0
## Buildup lost per second. Heat below the ignition point cools down, applied charge runs out.
@export var buildup_decay_per_second : float = 0.5
## Seconds it takes for applied wetness (buildup_threshold worth) to dry out. 0 = never dries.
## Objects that start WET or got wet by touching a wet object stay wet.
@export var dry_time : float = 20.0
## Damage multiplier for SHOCK damage while the object is wet.
@export var wet_shock_damage_multiplier : float = 1.5


@export_group("Resistances")
## Resistance in percent. 100 = immune, 0 = normal, negative values = weakness (-50 = 1.5x).
## Scales both damage of that type and element buildup.
@export_range(-100, 100, 1, "or_greater") var resist_fire : float = 0.0
@export_range(-100, 100, 1, "or_greater") var resist_cold : float = 0.0
@export_range(-100, 100, 1, "or_greater") var resist_shock : float = 0.0
## Water resistance only affects getting wet (e.g. waterproof objects).
@export_range(-100, 100, 1, "or_greater") var resist_water : float = 0.0
@export_range(-100, 100, 1, "or_greater") var resist_poison : float = 0.0
@export_range(-100, 100, 1, "or_greater") var resist_physical : float = 0.0


@export_group("VFX PackedScenes")
## PackedScene of VFX etc that gets spawned when object ignites.
@export var spawn_on_ignite : PackedScene
## PackedScene of VFX etc that gets spawned when object gets wet.
@export var spawn_on_wet : PackedScene
## PackedScene of VFX etc that gets spawned when object is electrified
@export var spawn_on_electrified : PackedScene


@export_group("Audio")
@export var audio_stream_player_3d: AudioStreamPlayer3D
@export var audio_igniting : AudioStream
@export var audio_burning : AudioStream
@export var audio_extinguishing : AudioStream

@export_group("Debuging")
## If turned on, this object will print log messages (only if the global is_logging is turned on as well!)
@export var is_logging : bool = true

var reaction_collider : Node3D = null
var spawned_effects : Array[Node] # Used to store and clear out spawned effects
var is_on_fire : bool = false
var is_electric : bool = false
var is_wet : bool = false
var player_is_touching : bool = false
var player_node : Node3D = null

var reaction_bodies : Array[Node3D] #Used to keep track of bodies with systemic properties.

## Current buildup per element (Element -> float). Read with get_element_level().
var element_levels : Dictionary = {}
## Elements whose state was caused by buildup and wears off by itself (Element -> true).
## States set directly (contact, on ready, set_on_fire() etc.) are sustained and don't wear off.
var _timed_states : Dictionary = {}
## Seconds of burning left (only used when fuel >= 0).
var fuel_remaining : float = -1.0
var _heat_sensor : Area3D = null
var _heat_tick : float = 0.0

## Interval of heat radiation ticks, in seconds.
const HEAT_TICK := 0.25

## Meta key used to tag spawned VFX with the state that spawned them, so clearing one state keeps the others.
const VFX_KIND_META := &"cogito_vfx_kind"
const VFX_FIRE := &"fire"
const VFX_WET := &"wet"
const VFX_ELECTRIC := &"electric"


func _ready():
	if !audio_stream_player_3d:
		var players: Array[Node] = find_children("", "AudioStreamPlayer3D")
		if len(players): audio_stream_player_3d = players[0]
		
	fuel_remaining = fuel
	reaction_timer.timeout.connect(check_for_systemic_reactions)
	damage_timer.timeout.connect(apply_burn_damage)
	
	await get_parent().is_node_ready()
	
	if ignite_on_ready:
		set_on_fire.call_deferred()
		
	if electric_on_ready:
		make_electric.call_deferred()
		
	if elemental_properties & ElementalProperties.WET:
		make_wet.call_deferred()
	
	_update_processing()


## Returns the CogitoProperties of a node, or null if it has none (or no such member at all).
static func get_properties_of(node: Object) -> CogitoProperties:
	if node == null or not is_instance_valid(node):
		return null
	var props = node.get("cogito_properties")
	return props as CogitoProperties


func start_reaction_threshold_timer(passed_collider: Node3D):
	# Quick check to see if the collider has any CogitoProperties.
	if !get_properties_of(passed_collider):
		CogitoGlobals.debug_log(is_logging, "cogito_properties.gd", "Collider " + passed_collider.name + " has no properties.")
		return
	
	# Saving passed collider to make sure we're reaction to the right thing.
	reaction_collider = passed_collider
	
	add_systemic_body(passed_collider)
	
	# Starting the reaction timer.
	if reaction_timer.is_stopped():
		reaction_timer.wait_time = reaction_threshold_time
		reaction_timer.start()


func check_for_reaction_timer_interrupt(passed_collider: Node3D):

	# Quick check to see if the collider has any CogitoProperties.
	if !get_properties_of(passed_collider):
		CogitoGlobals.debug_log(is_logging, "cogito_properties.gd", "Collider " + passed_collider.name + " has no properties.")
		return
	
	remove_systemic_body(passed_collider)
	
	# If the passed_collider is the reaction_collider, then this reaction needs to be stopped.
	if passed_collider == reaction_collider:
		if !reaction_timer.is_stopped():
			_log("stopped reaction timer, " + passed_collider.name + " is no longer in contact.")
			reaction_timer.stop()
	
	if reaction_bodies.size() == 0:
		if is_electric and !electric_on_ready and !_timed_states.has(Element.SHOCK):
			loose_electricity()


func check_for_systemic_reactions():
	if !is_instance_valid(reaction_collider):
		CogitoGlobals.debug_log(is_logging, "cogito_properties.gd","Reaction collider was null.")
		return
	var other : CogitoProperties = get_properties_of(reaction_collider)
	if !other:
		# Case where the object has no properties defined.
		_log("Collider " + reaction_collider.name + " has no properties.")
		return
	
	### FIRE REACTIONS
	if other.is_on_fire:
		if elemental_properties & ElementalProperties.FLAMMABLE:
			_log("Touched burning collider " + reaction_collider.name + ". I'm flammable, igniting self.")
			set_on_fire()
		else:
			_log("Touched collider " + reaction_collider.name + " which is on fire, but I'm not flammable, so nothing happens.")
		if elemental_properties & ElementalProperties.WET:
			_log("Touched burning collider " + reaction_collider.name + ". I'm wet so I'll extinguish the collider.")
			other.extinguish()

	### ELECTRICITY REACTIONS
	if can_conduct():
		if is_electric:
			_log("Electrified, touched collider " + reaction_collider.name + ". Trying to pass on electricity!")
			other.make_electric()
		if other.is_electric:
			_log("Touched by electrified collider " + reaction_collider.name + ". Getting electric.")
			make_electric()

	### WATER REACTIONS
	if other.elemental_properties & ElementalProperties.WET:
		_log("Touched by wet collider " + reaction_collider.name + ". Getting wet.")
		make_wet()


func make_conductive():
	elemental_properties |= ElementalProperties.CONDUCTIVE


func make_flammable():
	elemental_properties |= ElementalProperties.FLAMMABLE


func make_wet():
	if is_on_fire:
		extinguish()
	elemental_properties |= ElementalProperties.WET
	if is_wet:
		return # Already wet.
	is_wet = true
	_timed_states.erase(Element.WATER)
	element_levels[Element.WATER] = buildup_max
	if spawn_on_wet:
		spawn_elemental_vfx(spawn_on_wet, VFX_WET)
	has_become_wet.emit()


func make_dry():
	if !(elemental_properties & ElementalProperties.WET):
		return
	elemental_properties &= ~ElementalProperties.WET
	is_wet = false
	_timed_states.erase(Element.WATER)
	element_levels.erase(Element.WATER)
	clear_spawned_effects(VFX_WET)
	has_become_dry.emit()


func set_on_fire():
	if elemental_properties & ElementalProperties.FLAMMABLE:
		if is_on_fire:
			return # Already burning.
		is_on_fire = true
		element_levels[Element.FIRE] = buildup_max
		if spawn_on_ignite:
			spawn_elemental_vfx(spawn_on_ignite, VFX_FIRE)
		CogitoAudio.play_sound_3d_attached(audio_igniting, self)
		has_ignited.emit()
		
		if burn_damage_amount > 0:
			start_burn_damage_timer()
			
		if audio_stream_player_3d and audio_burning:
			audio_stream_player_3d.stream = audio_burning
			audio_stream_player_3d.play()
		
		if fuel >= 0.0 and fuel_remaining < 0.0:
			fuel_remaining = fuel # Fuel was set after _ready().
		_start_heat()
		_update_processing()
	else:
		CogitoGlobals.debug_log(is_logging, "cogito_properties.gd", get_parent().name + " is not FLAMMABLE.")


func start_burn_damage_timer():
	if damage_timer.is_stopped():
		damage_timer.wait_time = burn_damage_interval
		damage_timer.start()


func apply_burn_damage():
	var amount := burn_damage_amount * get_damage_multiplier(Element.FIRE)
	deal_burn_damage.emit(amount)
	# Calling damage received on Cogito Object or Enemy parent node.
	if get_parent().has_signal("damage_received"):
		get_parent().damage_received.emit(amount)
	
	if is_on_fire:
		start_burn_damage_timer()


func extinguish(play_sound: bool = true):
	if !is_on_fire:
		return
	is_on_fire = false
	element_levels.erase(Element.FIRE)
	_stop_heat()
	if !damage_timer.is_stopped():
		damage_timer.stop()
	if audio_stream_player_3d:
		audio_stream_player_3d.stop()
	if play_sound:
		CogitoAudio.play_sound_3d(audio_extinguishing, global_position)
	clear_spawned_effects(VFX_FIRE)
	has_been_extinguished.emit()


## Frees spawned VFX. With a kind (VFX_FIRE, VFX_WET, VFX_ELECTRIC) only that state's VFX are cleared.
func clear_spawned_effects(kind: StringName = &""):
	var kept : Array[Node] = []
	for node in spawned_effects:
		if !is_instance_valid(node):
			continue
		if kind != &"" and node.get_meta(VFX_KIND_META, &"") != kind:
			kept.append(node)
			continue
		CogitoGlobals.debug_log(is_logging, "cogito_properties.gd", "Clearing out spawned effect " + node.name)
		node.queue_free()
	spawned_effects = kept


func make_electric():
	if can_conduct():
		if is_electric:
			return # Already electric.
		is_electric = true
		_timed_states.erase(Element.SHOCK)
		element_levels[Element.SHOCK] = buildup_max
		if spawn_on_electrified:
			spawn_elemental_vfx(spawn_on_electrified, VFX_ELECTRIC)
		CogitoGlobals.debug_log(is_logging, "cogito_properties.gd", get_parent().name + " has become electric.")
		has_become_electric.emit()
		
		recheck_systemic_reactions()
	else:
		CogitoGlobals.debug_log(is_logging, "cogito_properties.gd", get_parent().name + " is not CONDUCTIVE or wet.")


func loose_electricity():
	if !is_electric:
		return
	is_electric = false
	_timed_states.erase(Element.SHOCK)
	element_levels.erase(Element.SHOCK)
	clear_spawned_effects(VFX_ELECTRIC)
	has_lost_electricity.emit()


func spawn_elemental_vfx(vfx_packed_scene:PackedScene, kind: StringName = &""):
	if !vfx_packed_scene:
		return
	# If max spawned vfx is reached, the oldest ones are freed.
	while spawned_effects.size() >= max(max_spawned_vfx, 1):
		var oldest : Node = spawned_effects.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()
	var spawned_object = vfx_packed_scene.instantiate()
	spawned_object.set_meta(VFX_KIND_META, kind)
	spawned_effects.append(spawned_object)
	await get_tree().process_frame
	if !is_instance_valid(spawned_object) or spawned_object.is_queued_for_deletion():
		return # Cleared while waiting a frame.
	get_parent().add_child(spawned_object)


func add_systemic_body(body: Node3D):
	if reaction_bodies.find(body) == -1:
		reaction_bodies.append(body)


func remove_systemic_body(body: Node3D):
	var index_in_reaction_bodies : int = reaction_bodies.find(body)
	if index_in_reaction_bodies != -1:
		reaction_bodies.remove_at(index_in_reaction_bodies)


func recheck_systemic_reactions():
	if reaction_bodies.size() < 1:
		CogitoGlobals.debug_log(is_logging, "cogito_properties.gd", get_parent().name + " systemic properties: Can't recheck reactions as there's no reaction bodies stored.")
		return
		
	for reaction_body in reaction_bodies:
		start_reaction_threshold_timer(reaction_body)


#region Elements: buildup, reactions, resistances

## Wet objects conduct electricity like CONDUCTIVE ones.
func can_conduct() -> bool:
	return bool(elemental_properties & ElementalProperties.CONDUCTIVE) or is_wet


func get_element_level(element: Element) -> float:
	return element_levels.get(element, 0.0)


## Resistance in percent for an element (see the Resistances export group).
func get_resistance(element: Element) -> float:
	match element:
		Element.FIRE: return resist_fire
		Element.COLD: return resist_cold
		Element.SHOCK: return resist_shock
		Element.WATER: return resist_water
		Element.POISON: return resist_poison
		Element.PHYSICAL: return resist_physical
	return 0.0


## Multiplier applied to element buildup: 100% resistance = 0, -100% = 2.
func get_resistance_multiplier(element: Element) -> float:
	return maxf(0.0, 1.0 - get_resistance(element) / 100.0)


## Multiplier applied to incoming damage of a type, including state modifiers (wet + shock).
func get_damage_multiplier(element: Element) -> float:
	var multiplier := get_resistance_multiplier(element)
	if element == Element.SHOCK and is_wet:
		multiplier *= wet_shock_damage_multiplier
	return multiplier


## Exposes this object to an element. Amount is measured in buildup_threshold units:
## reaching the threshold ignites, wets or electrifies the object. States caused this way wear off
## (wetness dries, applied charge runs out); a fire keeps burning until extinguished.
## Returns the amount that was actually applied after resistances and reactions.
func apply_element(element: Element, amount: float, source: Node = null) -> float:
	if amount <= 0.0 or element == Element.PHYSICAL:
		return 0.0
	amount *= get_resistance_multiplier(element)
	if amount <= 0.0:
		return 0.0
	
	match element:
		Element.FIRE:
			amount = _react_fire(amount)
		Element.WATER:
			amount = _react_water(amount)
		Element.SHOCK:
			amount = _react_shock(amount)
		_:
			# COLD and POISON only build up for now.
			_add_level(element, amount)
	
	if amount > 0.0:
		_log("applied " + Element.keys()[element] + " x" + str(snappedf(amount, 0.01)))
		element_applied.emit(element, amount, source)
	_update_processing()
	return amount


## Deals damage of an element to a target, scaled by the target's resistances and states.
## Works with anything that has a damage_received signal (CogitoObject, CogitoNPC, ...).
## Returns the damage that was dealt.
static func deal_elemental_damage(target: Node, amount: float, element: Element, source: Node = null, hit_direction := Vector3.ZERO, hit_position := Vector3.ZERO) -> float:
	if !is_instance_valid(target) or !target.has_signal("damage_received"):
		return 0.0
	var props := get_properties_of(target)
	if props:
		amount *= props.get_damage_multiplier(element)
	if amount <= 0.0:
		return 0.0
	target.damage_received.emit(amount, source, hit_direction, hit_position)
	return amount


## Applies an element to any node: its CogitoProperties, or its own apply_element() (e.g. CogitoElementArea).
## Returns the amount that was actually applied.
static func apply_element_to(target: Node, element: Element, amount: float, source: Node = null) -> float:
	if !is_instance_valid(target):
		return 0.0
	var props := get_properties_of(target)
	if props:
		return props.apply_element(element, amount, source)
	if target.has_method("apply_element"):
		return target.apply_element(element, amount, source)
	return 0.0


## Called when the fuel runs out. Puts the fire out and applies burn_out_result.
func burn_out():
	if !is_on_fire:
		return
	_log("burned out.")
	extinguish(false)
	match burn_out_result:
		BurnOutResult.NOTHING:
			fuel_remaining = fuel
		BurnOutResult.CHAR:
			elemental_properties &= ~ElementalProperties.FLAMMABLE
	burned_out.emit()
	if burn_out_result == BurnOutResult.DESTROY:
		get_parent().queue_free()


func _start_heat() -> void:
	if heat_radius <= 0.0 or _heat_sensor:
		return
	_heat_sensor = Area3D.new()
	_heat_sensor.name = "HeatSensor"
	_heat_sensor.monitorable = false
	_heat_sensor.collision_layer = 0
	_heat_sensor.collision_mask = heat_collision_mask
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = heat_radius
	shape.shape = sphere
	_heat_sensor.add_child(shape)
	add_child(_heat_sensor)
	_heat_tick = 0.0


func _stop_heat() -> void:
	if _heat_sensor:
		_heat_sensor.queue_free()
		_heat_sensor = null


func _radiate_heat(delta: float) -> void:
	var amount := heat_per_second * delta
	if amount <= 0.0:
		return
	var targets : Array = []
	targets.append_array(_heat_sensor.get_overlapping_bodies())
	targets.append_array(_heat_sensor.get_overlapping_areas())
	for target in targets:
		if target == get_parent() or get_properties_of(target) == self:
			continue
		apply_element_to(target, Element.FIRE, amount, get_parent())


func _react_fire(amount: float) -> float:
	if is_wet:
		if !_timed_states.has(Element.WATER):
			# Permanently wet objects swallow the heat.
			reaction_triggered.emit(&"steam")
			return 0.0
		var wetness := get_element_level(Element.WATER)
		reaction_triggered.emit(&"steam")
		if amount <= wetness:
			_set_level(Element.WATER, wetness - amount)
			return 0.0
		amount -= wetness
		make_dry()
	if _add_level(Element.FIRE, amount) >= buildup_threshold and !is_on_fire:
		if elemental_properties & ElementalProperties.FLAMMABLE:
			set_on_fire()
	return amount


func _react_water(amount: float) -> float:
	if is_on_fire:
		reaction_triggered.emit(&"douse")
		extinguish()
	else:
		element_levels.erase(Element.FIRE) # Cools down heat that hasn't ignited yet.
	if is_wet:
		if _timed_states.has(Element.WATER):
			_add_level(Element.WATER, amount)
		return amount
	if _add_level(Element.WATER, amount) >= buildup_threshold:
		var level := get_element_level(Element.WATER)
		make_wet()
		_timed_states[Element.WATER] = true
		_set_level(Element.WATER, level)
	return amount


func _react_shock(amount: float) -> float:
	if !can_conduct():
		return 0.0
	if is_electric:
		if _timed_states.has(Element.SHOCK):
			_add_level(Element.SHOCK, amount)
		return amount
	if _add_level(Element.SHOCK, amount) >= buildup_threshold:
		var level := get_element_level(Element.SHOCK)
		make_electric()
		if is_electric:
			_timed_states[Element.SHOCK] = true
			_set_level(Element.SHOCK, level)
	return amount


func _add_level(element: Element, amount: float) -> float:
	return _set_level(element, get_element_level(element) + amount)


func _set_level(element: Element, value: float) -> float:
	value = clampf(value, 0.0, buildup_max)
	if value <= 0.0:
		element_levels.erase(element)
	else:
		element_levels[element] = value
	return value


## Levels that should decay: sub-threshold buildup and timed states. Sustained states stay.
func _is_decaying(element: Element) -> bool:
	match element:
		Element.FIRE: return !is_on_fire
		Element.WATER: return !is_wet or _timed_states.has(Element.WATER)
		Element.SHOCK: return !is_electric or _timed_states.has(Element.SHOCK)
	return true


func _update_processing() -> void:
	if is_on_fire and (fuel >= 0.0 or _heat_sensor):
		set_process(true)
		return
	for element in element_levels:
		if _is_decaying(element):
			set_process(true)
			return
	set_process(false)


func _process(delta: float) -> void:
	for element in element_levels.keys():
		if !_is_decaying(element):
			continue
		var rate := buildup_decay_per_second
		if element == Element.WATER:
			if dry_time <= 0.0:
				continue
			rate = buildup_threshold / dry_time
		if _set_level(element, get_element_level(element) - rate * delta) <= 0.0:
			_on_level_depleted(element)
	if is_on_fire:
		if _heat_sensor:
			_heat_tick += delta
			if _heat_tick >= HEAT_TICK:
				_radiate_heat(_heat_tick)
				_heat_tick = 0.0
		if fuel >= 0.0:
			fuel_remaining -= delta
			if fuel_remaining <= 0.0:
				burn_out()
	_update_processing()


func _on_level_depleted(element: Element) -> void:
	if !_timed_states.has(element):
		return
	match element:
		Element.WATER:
			make_dry()
		Element.SHOCK:
			loose_electricity()
	_timed_states.erase(element)

#endregion


func _log(message: String) -> void:
	CogitoGlobals.debug_log(is_logging, "cogito_properties.gd", get_parent().name + ": " + message)

@icon("res://addons/cogito/Assets/Graphics/Editor/Icon_CogitoProperties.svg")
extends Node3D
## This class handles systeminc properties. Needs to be attached to a CogitoObject to work properly. For proper processing, said Object needs to have a signal hooked up to call check_for_systemic_interactions(collider).
class_name CogitoProperties

## Presentation-only notification after a network sample, including silent interest entry.
signal replica_updated()
signal has_ignited()
signal has_been_extinguished()
signal deal_burn_damage(burn_damage_amount:float)
signal has_become_wet()
signal has_become_dry()
signal has_become_electric()
signal has_lost_electricity()
## Emitted when the COLD buildup chilled the object.
signal has_become_chilled()
## Emitted when a chill wore off.
signal has_warmed_up()
## Emitted when a wet object froze.
signal has_frozen()
## Emitted when a frozen object thawed (it becomes wet again).
signal has_thawed()
## Emitted when the POISON buildup poisoned the object.
signal has_been_poisoned()
## Emitted when the poison wore off or was cured with cure_poison().
signal has_been_cured()
## Emitted when an element was applied through apply_element() (after resistances).
signal element_applied(element: Element, amount: float, source: Node)
## Emitted when two elements react with each other, e.g. &"steam" (fire on wet), &"douse" (water on fire),
## &"freeze" (cold on wet), &"thaw" (fire on frozen), &"quench" (cold on fire).
signal reaction_triggered(reaction: StringName)
## Emitted when a burning object ran out of fuel (see fuel and burn_out_result).
signal burned_out()
## Emitted when deal_elemental_damage() dealt damage to the object (after resistances), with its element.
signal elemental_damage_taken(amount: float, element: Element, source: Node)
## Emitted after apply_element_save_data() restored the element states from a save.
## The single state signals (has_ignited, ...) are not emitted by a restore, so listeners refresh on this one.
signal element_state_restored()

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
## FIRE damage per second dealt to the object while it burns. Unlike burn_damage_amount it goes through
## deal_elemental_damage(), so it reaches HitboxComponents and players and keeps its damage type.
## Ticks with state_damage_interval.
@export var fire_damage_per_second : float = 0.0


@export_group("Heat and Fuel")
## Radius in meters in which a burning object heats up its surroundings, so fire can spread. 0 = off.
@export var heat_radius : float = 0.0
## FIRE buildup per second applied to everything inside heat_radius while burning.
## Has to be higher than the neighbours' buildup_decay_per_second to ignite them.
@export var heat_per_second : float = 2.0
## Physics layers scanned for things to heat up (bodies and element areas).
@export_flags_3d_physics var heat_collision_mask : int = 1 | 2 | 4 | 16 | 32
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


@export_group("Cold and Poison")
## Seconds a chill of one buildup_threshold lasts. While chilled the COLD level decays at buildup_threshold / chill_time.
@export var chill_time : float = 5.0
## Seconds a freeze caused by buildup lasts before it thaws by itself. 0 = never thaws by itself.
## Objects frozen with freeze() stay frozen until thaw() or fire.
@export var freeze_time : float = 15.0
## COLD damage per second dealt to the object while it is chilled or frozen.
@export var cold_damage_per_second : float = 0.0
## While frozen, incoming COLD refreshes the freeze (adds to the COLD level). Turn off for actors (CogitoActorElements does)
## so they can struggle free inside a cold source: COLD applied to a frozen object is then ignored and the freeze only
## wears off (freeze_time), melts (fire) or is struggled away.
@export var frozen_absorbs_cold : bool = true
## Seconds one buildup_threshold of poison lasts while poisoned.
@export var poison_time : float = 10.0
## POISON damage per second dealt to the object while it is poisoned.
@export var poison_damage_per_second : float = 2.0
## Interval of cold and poison damage ticks in seconds. Damage per tick = damage per second * interval.
@export var state_damage_interval : float = 1.0


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
## PackedScene of VFX etc that gets spawned when object gets chilled.
@export var spawn_on_chilled : PackedScene
## PackedScene of VFX etc that gets spawned when object freezes.
@export var spawn_on_frozen : PackedScene
## PackedScene of VFX etc that gets spawned when object gets poisoned.
@export var spawn_on_poisoned : PackedScene
## PackedScene of VFX etc that gets spawned when the object burns out as CHAR. It stays for good and is never cleared.
@export var spawn_on_charred : PackedScene


@export_group("Audio")
@export var audio_stream_player_3d: AudioStreamPlayer3D
@export var audio_igniting : AudioStream
@export var audio_burning : AudioStream
@export var audio_extinguishing : AudioStream

@export_group("Debuging")
## If turned on, this object will print log messages (only if the global is_logging is turned on as well!)
@export var is_logging : bool = true

## True for a presentation copy bound to a remote authority.
var network_replica := false
## Received server deadlines in deciseconds: fuel, then FIRE through POISON (-1 = indefinite).
var replica_deadlines := PackedInt32Array()

var reaction_collider : Node3D = null
var spawned_effects : Array[Node] # Used to store and clear out spawned effects
var is_on_fire : bool = false
var is_electric : bool = false
var is_wet : bool = false
var is_chilled : bool = false
var is_frozen : bool = false
var is_poisoned : bool = false
## Runtime flag, not exported. While true, COLD can chill the object but never freeze it
## (a wet chilled object just stays chilled). CogitoActorElements sets it for a while after a freeze ended.
var freeze_immune : bool = false
## True after the object burned out with BurnOutResult.CHAR.
var is_charred : bool = false
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
## COLD buildup against a fire (separate from the FIRE level). Reaching buildup_threshold puts the fire out.
var _cold_vs_fire : float = 0.0
## Whether the wetness an object had before freezing was sustained (and has to be restored as such).
var _frozen_wet_sustained : bool = false
var _rigid_freeze_before : bool = false
var _state_tick : float = 0.0
var _replica_clock_offset := 0.0
var _authored_elemental_properties := 0

## Interval of heat radiation ticks, in seconds.
const HEAT_TICK := 0.25

## Meta key used to tag spawned VFX with the state that spawned them, so clearing one state keeps the others.
const VFX_KIND_META := &"cogito_vfx_kind"
const VFX_FIRE := &"fire"
const VFX_WET := &"wet"
const VFX_ELECTRIC := &"electric"
const VFX_CHILLED := &"chilled"
const VFX_FROZEN := &"frozen"
const VFX_POISONED := &"poisoned"
const VFX_CHARRED := &"charred"

## Group of nodes whose element states are saved with the scene (see CogitoSceneManager.save_scene_state()).
const ELEMENT_STATE_GROUP := &"cogito_element_state"
## Version of the dictionary returned by get_element_save_data().
const ELEMENT_SAVE_VERSION := 1


@onready var damage_timer: Timer = $DamageTimer
@onready var reaction_timer: Timer = $ReactionTimer


func _ready():
	add_to_group(ELEMENT_STATE_GROUP)
	if !audio_stream_player_3d:
		var players: Array[Node] = find_children("", "AudioStreamPlayer3D")
		if len(players): audio_stream_player_3d = players[0]
		
	fuel_remaining = fuel
	_authored_elemental_properties = elemental_properties
	network_replica = is_client_copy(self)
	reaction_timer.timeout.connect(check_for_systemic_reactions)
	damage_timer.timeout.connect(apply_burn_damage)
	
	if not get_parent().is_node_ready():
		await get_parent().ready
	
	if network_replica:
		set_process(false)
		return
	if ignite_on_ready:
		set_on_fire.call_deferred()
		
	if electric_on_ready:
		make_electric.call_deferred()
		
	if elemental_properties & ElementalProperties.WET:
		make_wet.call_deferred()
	
	_update_processing()


## Determine the role from the node's MultiplayerAPI, including isolated level branches.
static func is_client_copy(node: Node) -> bool:
	return (
		node.is_inside_tree() and node.multiplayer != null
		and node.multiplayer.has_multiplayer_peer() and not node.multiplayer.is_server()
	)


## Stop previously running offline timers when binding a loaded level to a client.
func bind_element_replica() -> void:
	network_replica = true
	damage_timer.stop()
	reaction_timer.stop()
	_stop_heat()
	set_process(false)


## Install quantized levels and notify presentation after flags and actor restrictions are set.
func apply_element_replica(
	levels: Dictionary, remaining_fuel: float, deadlines: PackedInt32Array, sample_time: float
) -> void:
	element_levels = levels
	fuel_remaining = remaining_fuel
	replica_deadlines = deadlines
	_replica_clock_offset = sample_time - Time.get_ticks_msec() * 0.001
	replica_updated.emit()


## Resume the ordinary component when its level survives disconnection.
func unbind_element_replica() -> void:
	network_replica = false
	replica_deadlines.clear()
	if is_on_fire:
		_start_heat()
		if burn_damage_amount > 0:
			start_burn_damage_timer()
	_update_processing()


## Returns the CogitoProperties of a node, or null if it has none (or no such member at all).
static func get_properties_of(node: Object) -> CogitoProperties:
	if node == null or not is_instance_valid(node):
		return null
	var props = node.get("cogito_properties")
	return props as CogitoProperties


func start_reaction_threshold_timer(passed_collider: Node3D):
	if network_replica:
		return
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
	if network_replica:
		return

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
	if network_replica:
		return
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
	if network_replica:
		return
	elemental_properties |= ElementalProperties.CONDUCTIVE


func make_flammable():
	if network_replica:
		return
	elemental_properties |= ElementalProperties.FLAMMABLE


func make_wet():
	if network_replica:
		return
	if is_frozen:
		_log("is frozen and can't get wet.")
		return
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
	if network_replica:
		return
	if !(elemental_properties & ElementalProperties.WET):
		return
	elemental_properties &= ~ElementalProperties.WET
	is_wet = false
	_timed_states.erase(Element.WATER)
	element_levels.erase(Element.WATER)
	clear_spawned_effects(VFX_WET)
	has_become_dry.emit()


func set_on_fire():
	if network_replica:
		return
	if is_frozen:
		_log("is frozen and can't burn.")
		return
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
	if network_replica:
		return
	if damage_timer.is_stopped():
		damage_timer.wait_time = burn_damage_interval
		damage_timer.start()


func apply_burn_damage():
	if network_replica:
		return
	var amount := burn_damage_amount * get_damage_multiplier(Element.FIRE)
	var parent := get_parent()
	if parent is CogitoPlayer and parent.network_movement_only:
		if parent.receive_elemental_damage(amount, Element.FIRE, parent, Vector3.ZERO, Vector3.ZERO, true):
			deal_burn_damage.emit(amount)
	else:
		deal_burn_damage.emit(amount)
		if parent.has_signal("damage_received"):
			var hit_position: Vector3 = parent.global_position if parent is Node3D else Vector3.ZERO
			parent.damage_received.emit(amount, parent, Vector3.ZERO, hit_position)

	if is_on_fire:
		start_burn_damage_timer()


func extinguish(play_sound: bool = true):
	if network_replica:
		return
	if !is_on_fire:
		return
	is_on_fire = false
	element_levels.erase(Element.FIRE)
	_cold_vs_fire = 0.0
	_stop_heat()
	if !damage_timer.is_stopped():
		damage_timer.stop()
	if audio_stream_player_3d:
		audio_stream_player_3d.stop()
	if play_sound:
		CogitoAudio.play_sound_3d_in(self, audio_extinguishing, global_position)
	clear_spawned_effects(VFX_FIRE)
	has_been_extinguished.emit()


## Frees spawned VFX. With a kind (VFX_FIRE, VFX_WET, VFX_ELECTRIC, VFX_CHILLED, ...) only that state's VFX are cleared.
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
	if network_replica:
		return
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
	if network_replica:
		return
	if !is_electric:
		return
	is_electric = false
	_timed_states.erase(Element.SHOCK)
	element_levels.erase(Element.SHOCK)
	clear_spawned_effects(VFX_ELECTRIC)
	has_lost_electricity.emit()


func spawn_elemental_vfx(vfx_packed_scene:PackedScene, kind: StringName = &""):
	if !vfx_packed_scene or not is_inside_tree():
		return
	# If max spawned vfx is reached, the oldest ones are freed.
	while spawned_effects.size() >= max(max_spawned_vfx, 1):
		var oldest : Node = spawned_effects.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()
	var spawned_object = vfx_packed_scene.instantiate()
	if network_replica and get_parent() is CogitoNPC:
		# MP6 disables the gameplay subtree. Its cosmetic particles still need frame time.
		spawned_object.process_mode = Node.PROCESS_MODE_ALWAYS
	spawned_object.set_meta(VFX_KIND_META, kind)
	spawned_effects.append(spawned_object)
	await get_tree().process_frame
	if !is_instance_valid(spawned_object) or spawned_object.is_queued_for_deletion():
		return # Cleared while waiting a frame.
	get_parent().add_child(spawned_object)


func _exit_tree() -> void:
	# A reset or despawn can remove the component during the deferred VFX frame.
	for effect in spawned_effects:
		if is_instance_valid(effect) and not effect.get_parent():
			effect.queue_free()


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

## Wet objects conduct electricity like CONDUCTIVE ones. Frozen objects don't conduct.
func can_conduct() -> bool:
	if is_frozen:
		return false
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
## reaching the threshold ignites, wets, electrifies, chills (freezes if wet) or poisons the object. States caused this way wear off
## (wetness dries, applied charge runs out); a fire keeps burning until extinguished.
## Returns the amount that was actually applied after resistances and reactions.
func apply_element(element: Element, amount: float, source: Node = null) -> float:
	if network_replica or amount <= 0.0 or element == Element.PHYSICAL:
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
		Element.COLD:
			amount = _react_cold(amount)
		Element.POISON:
			amount = _react_poison(amount)
	
	if amount > 0.0:
		_log("applied " + Element.keys()[element] + " x" + str(snappedf(amount, 0.01)))
		element_applied.emit(element, amount, source)
	_update_processing()
	return amount


## Deals damage of an element to a target, scaled by the target's resistances and states.
## Works with anything that has a damage_received signal (CogitoObject, CogitoNPC, ...) or a
## receive_elemental_damage(amount, element, source, hit_direction, hit_position) method (e.g. CogitoPlayer),
## which gets the damage type too. Returns the damage that was dealt.
static func deal_elemental_damage(
	target: Node, amount: float, element: Element, source: Node = null,
	hit_direction := Vector3.ZERO, hit_position := Vector3.ZERO, environment := false
) -> float:
	if !is_instance_valid(target) or is_client_copy(target):
		return 0.0
	var typed := target.has_method("receive_elemental_damage")
	if !typed and !target.has_signal("damage_received"):
		return 0.0
	var props := get_properties_of(target)
	if props:
		if props.network_replica:
			return 0.0
		amount *= props.get_damage_multiplier(element)
	if amount <= 0.0:
		return 0.0
	if target is CogitoPlayer and target.network_movement_only:
		if not target.receive_elemental_damage(
			amount, element, source, hit_direction, hit_position, environment
		):
			return 0.0
	elif typed:
		target.receive_elemental_damage(amount, element, source, hit_direction, hit_position)
	else:
		target.damage_received.emit(amount, source, hit_direction, hit_position)
	if props:
		props.elemental_damage_taken.emit(amount, element, source)
	return amount


## Applies an element to any node: its CogitoProperties, or its own apply_element() (e.g. CogitoElementArea).
## Returns the amount that was actually applied.
static func apply_element_to(target: Node, element: Element, amount: float, source: Node = null) -> float:
	if !is_instance_valid(target) or is_client_copy(target):
		return 0.0
	var props := get_properties_of(target)
	if props:
		return props.apply_element(element, amount, source)
	if target.has_method("apply_element"):
		return target.apply_element(element, amount, source)
	return 0.0


## Called when the fuel runs out. Puts the fire out and applies burn_out_result.
func burn_out():
	if network_replica:
		return
	if !is_on_fire:
		return
	_log("burned out.")
	extinguish(false)
	match burn_out_result:
		BurnOutResult.NOTHING:
			fuel_remaining = fuel
		BurnOutResult.CHAR:
			elemental_properties &= ~ElementalProperties.FLAMMABLE
			is_charred = true
			if spawn_on_charred:
				spawn_elemental_vfx(spawn_on_charred, VFX_CHARRED)
	burned_out.emit()
	if burn_out_result == BurnOutResult.DESTROY:
		var target := get_parent()
		if target is CogitoPlayer and target.network_movement_only:
			# The avatar binding survives death so the owner can respawn through MP5.
			var health: CogitoAttribute = target.player_attributes.get("health")
			if health:
				target.receive_elemental_damage(
					health.value_current, Element.FIRE, target, Vector3.ZERO, Vector3.ZERO, true
				)
			return
		if target is CogitoNPC and target.network_state:
			target.damage_received.emit(target.health.value_current, target, Vector3.ZERO, global_position)
			return
		# Lets a save remember that the object is gone, also when it isn't a Persist node.
		CogitoSceneManager.register_destroyed_node(get_parent())
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
	# Fire melts ice and warms up a chill first.
	var absorbed := 0.0
	if is_frozen or is_chilled:
		var cold := get_element_level(Element.COLD)
		if amount < cold:
			_set_level(Element.COLD, cold - amount)
			return amount
		absorbed = cold
		amount -= cold
		if is_frozen:
			thaw()
			reaction_triggered.emit(&"thaw")
		else:
			_set_level(Element.COLD, 0.0)
			_warm_up()
		if amount <= 0.0:
			return absorbed
	return absorbed + _heat_up(amount)


func _heat_up(amount: float) -> float:
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
	if is_frozen:
		return 0.0
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


func _react_cold(amount: float) -> float:
	if is_on_fire:
		# Cold has to beat the fire; what is left over is discarded.
		_cold_vs_fire += amount
		if _cold_vs_fire >= buildup_threshold:
			_cold_vs_fire = 0.0
			extinguish()
			reaction_triggered.emit(&"quench")
		return amount
	if is_frozen:
		if !frozen_absorbs_cold:
			return 0.0
		if _timed_states.has(Element.COLD):
			_add_level(Element.COLD, amount) # Refreshes the freeze.
		return amount
	var rest := amount
	var heat := get_element_level(Element.FIRE)
	if heat > 0.0:
		# Cools down heat that hasn't ignited yet.
		var cooled := minf(heat, rest)
		_set_level(Element.FIRE, heat - cooled)
		rest -= cooled
	if rest <= 0.0:
		return amount
	var level := _add_level(Element.COLD, rest)
	if level >= buildup_threshold:
		if is_wet and !freeze_immune:
			_freeze(true)
			reaction_triggered.emit(&"freeze")
		elif !is_chilled:
			_chill()
	return amount


func _react_poison(amount: float) -> float:
	if _add_level(Element.POISON, amount) >= buildup_threshold and !is_poisoned:
		is_poisoned = true
		_timed_states[Element.POISON] = true
		if spawn_on_poisoned:
			spawn_elemental_vfx(spawn_on_poisoned, VFX_POISONED)
		has_been_poisoned.emit()
	return amount


func _chill() -> void:
	is_chilled = true
	_timed_states[Element.COLD] = true
	if spawn_on_chilled:
		spawn_elemental_vfx(spawn_on_chilled, VFX_CHILLED)
	has_become_chilled.emit()


func _warm_up() -> void:
	if !is_chilled:
		return
	is_chilled = false
	_timed_states.erase(Element.COLD)
	clear_spawned_effects(VFX_CHILLED)
	has_warmed_up.emit()


## Freezes a wet object and keeps it frozen until thaw() or fire. Does nothing if the object isn't wet.
func freeze() -> void:
	if network_replica:
		return
	_freeze(false)


## Freezes a wet object. A timed freeze thaws by itself after freeze_time.
func _freeze(timed: bool) -> void:
	if is_frozen:
		return
	if !is_wet:
		_log("is not wet and can't freeze.")
		return
	# The wetness is given back on thaw. It froze, it didn't dry, so has_become_dry isn't emitted.
	_frozen_wet_sustained = !_timed_states.has(Element.WATER)
	is_wet = false
	elemental_properties &= ~ElementalProperties.WET
	_timed_states.erase(Element.WATER)
	element_levels.erase(Element.WATER)
	clear_spawned_effects(VFX_WET)
	loose_electricity()
	# Frozen supersedes chilled.
	is_chilled = false
	clear_spawned_effects(VFX_CHILLED)
	is_frozen = true
	if timed:
		_timed_states[Element.COLD] = true
		element_levels[Element.COLD] = buildup_threshold
	else:
		_timed_states.erase(Element.COLD)
		element_levels[Element.COLD] = buildup_max
	var body := get_parent() as RigidBody3D
	if body:
		_rigid_freeze_before = body.freeze
		body.freeze = true
	if spawn_on_frozen:
		spawn_elemental_vfx(spawn_on_frozen, VFX_FROZEN)
	_log("froze.")
	has_frozen.emit()
	_update_processing()


## Melts a frozen object. It becomes wet again, as it was before it froze.
func thaw() -> void:
	if network_replica:
		return
	if !is_frozen:
		return
	is_frozen = false
	_timed_states.erase(Element.COLD)
	element_levels.erase(Element.COLD)
	var body := get_parent() as RigidBody3D
	if body:
		body.freeze = _rigid_freeze_before
	clear_spawned_effects(VFX_FROZEN)
	_log("thawed.")
	has_thawed.emit()
	make_wet()
	if !_frozen_wet_sustained:
		_timed_states[Element.WATER] = true
		_set_level(Element.WATER, buildup_threshold)
	_update_processing()


## Lowers the buildup of an element, e.g. a frozen actor struggling free (see CogitoActorElements.struggle()).
## When the level runs out the state ends as if it had worn off: a frozen object thaws (and is wet again),
## a chill warms up, poison ends. Returns the new level.
func reduce_element(element: Element, amount: float) -> float:
	if network_replica or amount <= 0.0:
		return get_element_level(element)
	var level := _set_level(element, get_element_level(element) - amount)
	if level <= 0.0:
		if _timed_states.has(element):
			_on_level_depleted(element)
		elif element == Element.COLD and is_frozen:
			thaw() # Frozen with freeze(): struggling free still melts it.
	_update_processing()
	return level


## Removes all poison buildup and the poisoned state.
func cure_poison() -> void:
	if network_replica:
		return
	element_levels.erase(Element.POISON)
	_timed_states.erase(Element.POISON)
	_end_poison()
	_update_processing()


func _end_poison() -> void:
	if !is_poisoned:
		return
	is_poisoned = false
	clear_spawned_effects(VFX_POISONED)
	has_been_cured.emit()


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
		Element.COLD:
			if is_frozen:
				return _timed_states.has(Element.COLD) and freeze_time > 0.0
			if is_chilled:
				return chill_time > 0.0
		Element.POISON:
			if is_poisoned:
				return poison_time > 0.0
	return true


## Seconds until this buildup expires at the current decay rate without further exposure.
func element_time_remaining(element: Element) -> float:
	if network_replica:
		if element == Element.PHYSICAL or element >= replica_deadlines.size():
			return -1.0
		if replica_deadlines[element] < 0:
			return -1.0
		var now := _replica_clock_offset + Time.get_ticks_msec() * 0.001
		return maxf(0.0, replica_deadlines[element] / 10.0 - now)
	if not _is_decaying(element):
		return -1.0
	var rate := _decay_rate(element)
	return get_element_level(element) / rate if rate > 0.0 else -1.0


func _decay_rate(element: Element) -> float:
	var duration: float
	if element == Element.WATER:
		duration = dry_time
	elif element == Element.COLD and (is_frozen or is_chilled):
		duration = freeze_time if is_frozen else chill_time
	elif element == Element.POISON and is_poisoned:
		duration = poison_time
	else:
		return buildup_decay_per_second
	return buildup_threshold / duration if duration > 0.0 else 0.0


## True while fire, cold or poison damage ticks are due.
func _has_state_ticks() -> bool:
	return (is_poisoned and poison_damage_per_second > 0.0) or ((is_chilled or is_frozen) and cold_damage_per_second > 0.0) \
		or (is_on_fire and fire_damage_per_second > 0.0)


func _update_processing() -> void:
	if network_replica:
		set_process(false)
		return
	if is_on_fire and (fuel >= 0.0 or _heat_sensor):
		set_process(true)
		return
	if _has_state_ticks() or _cold_vs_fire > 0.0:
		set_process(true)
		return
	for element in element_levels:
		if _is_decaying(element):
			set_process(true)
			return
	set_process(false)


func _process(delta: float) -> void:
	if network_replica:
		return
	for element in element_levels.keys():
		if !_is_decaying(element):
			continue
		var rate := _decay_rate(element)
		if _set_level(element, get_element_level(element) - rate * delta) <= 0.0:
			_on_level_depleted(element)
	if _cold_vs_fire > 0.0:
		_cold_vs_fire = maxf(0.0, _cold_vs_fire - buildup_decay_per_second * delta)
	if _has_state_ticks():
		_state_tick += delta
		var interval := maxf(state_damage_interval, 0.01)
		while _state_tick >= interval:
			_state_tick -= interval
			if is_poisoned and poison_damage_per_second > 0.0:
				_deal_state_damage(poison_damage_per_second * interval, Element.POISON)
			if (is_chilled or is_frozen) and cold_damage_per_second > 0.0:
				_deal_state_damage(cold_damage_per_second * interval, Element.COLD)
			if is_on_fire and fire_damage_per_second > 0.0:
				_deal_state_damage(fire_damage_per_second * interval, Element.FIRE)
	else:
		_state_tick = 0.0
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


func _deal_state_damage(amount: float, element: Element) -> void:
	deal_elemental_damage(
		get_parent(), amount, element, get_parent(), Vector3.ZERO, Vector3.ZERO, true
	)


func _on_level_depleted(element: Element) -> void:
	if !_timed_states.has(element):
		return
	match element:
		Element.WATER:
			make_dry()
		Element.SHOCK:
			loose_electricity()
		Element.COLD:
			if is_frozen:
				thaw()
			else:
				_warm_up()
		Element.POISON:
			_end_poison()
	_timed_states.erase(element)

#endregion


#region Saving

## Returns the runtime element state as a dictionary of plain values (safe for resources and JSON),
## so apply_element_save_data() can continue it after a load.
func get_element_save_data() -> Dictionary:
	var levels := {}
	for element in element_levels:
		levels[str(element)] = float(element_levels[element])
	var timed : Array = []
	for element in _timed_states:
		timed.append(int(element))
	var burn_damage_left := 0.0
	if damage_timer and !damage_timer.is_stopped():
		burn_damage_left = damage_timer.time_left
	return {
		"v": ELEMENT_SAVE_VERSION,
		"elemental_properties": elemental_properties,
		"on_fire": is_on_fire,
		"wet": is_wet,
		"electric": is_electric,
		"chilled": is_chilled,
		"frozen": is_frozen,
		"poisoned": is_poisoned,
		"charred": is_charred,
		"freeze_immune": freeze_immune,
		"levels": levels,
		"timed": timed,
		"fuel_remaining": fuel_remaining,
		"cold_vs_fire": _cold_vs_fire,
		"frozen_wet_sustained": _frozen_wet_sustained,
		"rigid_freeze_before": _rigid_freeze_before,
		"state_tick": _state_tick,
		"heat_tick": _heat_tick,
		"burn_damage_left": burn_damage_left,
	}


## Silently returns to the authored, element-free state: no reactions, damage or state
## signals, only element_state_restored. Used when a networked player respawns.
func reset_element_state() -> void:
	apply_element_save_data({"v": ELEMENT_SAVE_VERSION, "elemental_properties": _authored_elemental_properties})


## Restores element states saved with get_element_save_data(). States, levels and timers continue where they were.
## Nothing reacts to the restore: no reactions, damage, burn out or state signals, only element_state_restored.
func apply_element_save_data(data: Dictionary) -> void:
	if network_replica:
		return
	if data.is_empty():
		return
	var body := get_parent() as RigidBody3D
	# Back to a neutral state, silently.
	clear_spawned_effects()
	_stop_heat()
	if damage_timer:
		damage_timer.stop()
	if is_on_fire and audio_stream_player_3d:
		audio_stream_player_3d.stop()
	if is_frozen and body:
		body.freeze = _rigid_freeze_before
	
	elemental_properties = int(data.get("elemental_properties", elemental_properties))
	is_on_fire = bool(data.get("on_fire", false))
	is_wet = bool(data.get("wet", false))
	is_electric = bool(data.get("electric", false))
	is_chilled = bool(data.get("chilled", false))
	is_frozen = bool(data.get("frozen", false))
	is_poisoned = bool(data.get("poisoned", false))
	is_charred = bool(data.get("charred", false))
	freeze_immune = bool(data.get("freeze_immune", false))
	element_levels.clear()
	var levels : Dictionary = data.get("levels", {})
	for key in levels:
		element_levels[int(key)] = float(levels[key])
	_timed_states.clear()
	for element in data.get("timed", []):
		_timed_states[int(element)] = true
	fuel_remaining = float(data.get("fuel_remaining", fuel))
	_cold_vs_fire = float(data.get("cold_vs_fire", 0.0))
	_frozen_wet_sustained = bool(data.get("frozen_wet_sustained", false))
	_rigid_freeze_before = bool(data.get("rigid_freeze_before", body.freeze if body else false))
	_state_tick = float(data.get("state_tick", 0.0))
	
	# Rebuild what follows from the states.
	if is_frozen and body:
		body.freeze = true
	if is_charred and spawn_on_charred:
		spawn_elemental_vfx(spawn_on_charred, VFX_CHARRED)
	if is_wet and spawn_on_wet:
		spawn_elemental_vfx(spawn_on_wet, VFX_WET)
	if is_electric and spawn_on_electrified:
		spawn_elemental_vfx(spawn_on_electrified, VFX_ELECTRIC)
	if is_chilled and spawn_on_chilled:
		spawn_elemental_vfx(spawn_on_chilled, VFX_CHILLED)
	if is_frozen and spawn_on_frozen:
		spawn_elemental_vfx(spawn_on_frozen, VFX_FROZEN)
	if is_poisoned and spawn_on_poisoned:
		spawn_elemental_vfx(spawn_on_poisoned, VFX_POISONED)
	if is_on_fire:
		if spawn_on_ignite:
			spawn_elemental_vfx(spawn_on_ignite, VFX_FIRE)
		if audio_stream_player_3d and audio_burning:
			audio_stream_player_3d.stream = audio_burning
			audio_stream_player_3d.play()
		_start_heat()
		_heat_tick = float(data.get("heat_tick", 0.0))
		if burn_damage_amount > 0.0 and damage_timer:
			var burn_damage_left := float(data.get("burn_damage_left", 0.0))
			damage_timer.wait_time = burn_damage_left if burn_damage_left > 0.0 else burn_damage_interval
			damage_timer.start()
	_update_processing()
	_log("element state restored.")
	element_state_restored.emit()

#endregion


func _log(message: String) -> void:
	CogitoGlobals.debug_log(is_logging, "cogito_properties.gd", get_parent().name + ": " + message)

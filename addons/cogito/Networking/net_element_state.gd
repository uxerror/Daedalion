extends RefCounted
## Presentation sample for one authored property component or hazard area.

# Five consecutive levels and deadlines follow the CogitoProperties.Element order.
enum Field {
	FLAGS,
	MATERIAL,
	FIRE,
	COLD,
	SHOCK,
	WATER,
	POISON,
	FUEL,
	FUEL_END,
	FIRE_END,
	COLD_END,
	SHOCK_END,
	WATER_END,
	POISON_END,
	STUNNED,
	SPEED,
	STUN_END,
	COOLDOWN_END,
	IMMUNITY_END,
	CAN_ACT,
}

const FLAGS := [
	&"is_on_fire",
	&"is_wet",
	&"is_electric",
	&"is_chilled",
	&"is_frozen",
	&"is_poisoned",
	&"is_charred",
]
const EFFECTS := [
	&"spawn_on_ignite",
	&"spawn_on_wet",
	&"spawn_on_electrified",
	&"spawn_on_chilled",
	&"spawn_on_frozen",
	&"spawn_on_poisoned",
	&"spawn_on_charred",
]
const KINDS := [&"fire", &"wet", &"electric", &"chilled", &"frozen", &"poisoned", &"charred"]
const ELEMENT := CogitoProperties.Element
const LEVEL_SCALE := 32.0

var anchor: Node3D
var props: CogitoProperties
var area: CogitoElementArea
var actor: CogitoActorElements
var health: CogitoHealthAttribute
var sampled := PackedInt32Array()
var revision := 0
var _watched: Array[Signal] = []
var _changed: Callable
var _dirty := true
var _was_active := false
var _rest_levels := {}


func _init(component: Node3D) -> void:
	anchor = component
	props = component as CogitoProperties
	area = component as CogitoElementArea
	if props:
		for child in props.get_parent().get_children():
			if child is CogitoActorElements and child.properties == props:
				actor = child
			elif child is CogitoHealthAttribute and not props.get_parent() is CharacterBody3D:
				health = child


## Wake the network sampler on discrete transitions, including a short stun between level samples.
func watch_flags(changed: Callable) -> void:
	_changed = changed
	if area:
		_watched.assign([area.enabled_changed, area.has_become_electric, area.has_lost_electricity])
	else:
		(
			_watched
			. assign(
				[
					props.has_ignited,
					props.has_been_extinguished,
					props.has_become_wet,
					props.has_become_dry,
					props.has_become_electric,
					props.has_lost_electricity,
					props.has_become_chilled,
					props.has_warmed_up,
					props.has_frozen,
					props.has_thawed,
					props.has_been_poisoned,
					props.has_been_cured,
					props.burned_out,
					props.element_state_restored,
				]
			)
		)
		if actor:
			_watched.append(actor.stunned)
			_watched.append(actor.stun_ended)
	for transition in _watched:
		transition.connect(_wake)


func _wake(_enabled := false) -> void:
	_dirty = true
	_changed.call()


## A scene may survive the network session and bind again later.
func unwatch() -> void:
	for transition in _watched:
		if is_instance_valid(transition.get_object()) and transition.is_connected(_wake):
			transition.disconnect(_wake)
	_watched.clear()


## Suppress simulation even when an already running offline scene becomes a replica.
func bind_replica() -> void:
	if props:
		props.bind_element_replica()
		if actor:
			actor.set_process(false)
	elif area:
		area.apply_element_replica(area.enabled, area.is_electric, 0.0)


## Absolute deadlines use the authority simulation clock, in tenths of a second.
func _deadline(now: float, remaining: float) -> int:
	return roundi((now + remaining) * 10.0) if remaining > 0.0 else -1


# Only interest is polled for a settled component. Take one final sample as it goes to sleep.
func _needs_sample() -> bool:
	var active: bool
	var changed := _dirty
	if area:
		active = area.is_electric or not area._levels.is_empty()
	else:
		active = (
			props.can_process() and (props.is_processing() or (actor and actor.is_processing()))
		)
		if not sampled.is_empty() and not active:
			changed = (
				changed
				or props.element_levels != _rest_levels
				or props.elemental_properties != sampled[Field.MATERIAL]
				or roundi(props.fuel_remaining * 10.0) != sampled[Field.FUEL]
				or (health and roundi(health.value_current * 100.0) != sampled[-1])
			)
		if not active and (changed or _was_active):
			_rest_levels = props.element_levels.duplicate()
	var needed := changed or active or _was_active
	_was_active = active
	_dirty = false
	return needed


## A revision advances only for a different quantized sample.
func sample(now: float) -> void:
	if not _needs_sample():
		return
	var values := PackedInt32Array()
	if area:
		values = PackedInt32Array(
			[
				int(area.enabled),
				int(area.is_electric),
				_deadline(now, area._shock_time_left),
				roundi(area._levels.get(ELEMENT.FIRE, 0) * LEVEL_SCALE),
				roundi(area._levels.get(ELEMENT.WATER, 0) * LEVEL_SCALE),
			]
		)
	else:
		var flags := 0
		for i in FLAGS.size():
			if props.get(FLAGS[i]):
				flags |= 1 << i
		values.append_array([flags, props.elemental_properties])
		for i in range(ELEMENT.FIRE, ELEMENT.POISON + 1):
			values.append(roundi(props.get_element_level(i) * LEVEL_SCALE))
		values.append(roundi(props.fuel_remaining * 10.0))
		values.append(_deadline(now, props.fuel_remaining if props.is_on_fire else -1.0))
		for i in range(ELEMENT.FIRE, ELEMENT.POISON + 1):
			values.append(_deadline(now, props.element_time_remaining(i)))
		if actor:
			(
				values
				. append_array(
					[
						int(actor.is_stunned),
						roundi(actor.speed_multiplier * 1000.0),
						_deadline(now, actor.stun_time_left),
						_deadline(now, actor.stun_cooldown_left),
						_deadline(now, actor._immunity_left),
						int(actor.can_act()),
					]
				)
			)
		if health:
			values.append(roundi(health.value_current * 100.0))
	if values != sampled:
		sampled = values
		revision += 1


## Install a sample directly. Only a live transition may produce one-shot feedback.
func apply(values: PackedInt32Array, now: float, silent: bool) -> void:
	if area:
		area.apply_element_replica(values[0] != 0, values[1] != 0, _remaining(values[2], now))
		area._levels.clear()
		if values[3] > 0:
			area._levels[ELEMENT.FIRE] = values[3] / LEVEL_SCALE
		if values[4] > 0:
			area._levels[ELEMENT.WATER] = values[4] / LEVEL_SCALE
		return
	for i in FLAGS.size():
		var active := (values[Field.FLAGS] & (1 << i)) != 0
		if props.get(FLAGS[i]) != active:
			props.set(FLAGS[i], active)
			_present_flag(i, active, silent)
	props.elemental_properties = values[Field.MATERIAL]
	var levels := {}
	for i in range(ELEMENT.FIRE, ELEMENT.POISON + 1):
		var value := values[Field.FIRE + i - ELEMENT.FIRE]
		if value > 0:
			levels[i] = value / LEVEL_SCALE
	if actor:
		props.freeze_immune = values[Field.IMMUNITY_END] >= 0
		actor.apply_element_replica(
			values[Field.STUNNED] != 0,
			values[Field.SPEED] / 1000.0,
			_remaining(values[Field.STUN_END], now),
			_remaining(values[Field.COOLDOWN_END], now),
			values[Field.CAN_ACT] != 0,
			silent
		)
	if health and not is_equal_approx(health.value_current, values[-1] / 100.0):
		health.apply_replica_value(values[-1] / 100.0, health.value_max)
	props.apply_element_replica(
		levels, values[Field.FUEL] / 10.0, values.slice(Field.FUEL_END, Field.STUNNED), now
	)


func _remaining(deadline: int, now: float) -> float:
	return maxf(0, deadline / 10.0 - now)


func _present_flag(index: int, active: bool, silent: bool) -> void:
	if active:
		var scene: PackedScene = props.get(EFFECTS[index])
		if scene:
			props.spawn_elemental_vfx(scene, KINDS[index])
	else:
		props.clear_spawned_effects(KINDS[index])
	if index != 0:
		return
	var audio := props.audio_stream_player_3d
	if audio:
		if active and props.audio_burning:
			audio.stream = props.audio_burning
			audio.play()
		else:
			audio.stop()
	if not silent:
		var clip := props.audio_igniting if active else props.audio_extinguishing
		CogitoAudio.play_sound_3d_in(props, clip, props.global_position)

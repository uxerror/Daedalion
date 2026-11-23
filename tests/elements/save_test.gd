extends GdUnitTestSuite

const FIXTURES := preload("res://tests/fixtures/element_fixtures.gd")
const SAVE_LEVEL := preload("res://tests/fixtures/element_save_level.gd")
const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
const HUD := preload("res://addons/cogito/Components/UI/UI_ElementStatus.tscn")
const CRATE := preload(
	"res://addons/cogito/DemoScenes/DemoPrefabs/ElementStands/element_crate.tscn"
)
const E = CogitoProperties.Element
const F = CogitoProperties.ElementalProperties
const S = CogitoElementStatusHud.Status
const SLOT := "e4b_test"
const SCENE_NAME := "E4bTestLevel"

var _world: FIXTURES.PlayerWorld
var _previous_destroyed_nodes: Array
var _previous_destroyed_level_id: int
var _previous_level: Node
var _previous_state: CogitoSceneState
var _level: SAVE_LEVEL
var _dummy_vfx: PackedScene
var _next_x: float


func before_test() -> void:
	_world = auto_free(FIXTURES.PlayerWorld.new())
	get_tree().root.add_child(_world)
	_previous_destroyed_nodes = CogitoSceneManager._destroyed_nodes
	_previous_destroyed_level_id = CogitoSceneManager._destroyed_nodes_level_id
	CogitoSceneManager._destroyed_nodes = []
	_previous_level = CogitoSceneManager._current_scene_root_node
	_previous_state = CogitoSceneManager._scene_state
	CogitoSceneManager._current_scene_root_node = _world
	CogitoSceneManager._scene_state = null
	_next_x = 0.0
	_dummy_vfx = PackedScene.new()
	var effect := Node3D.new()
	_dummy_vfx.pack(effect)
	effect.free()


func after_test() -> void:
	await _frames()
	_world.restore()
	CogitoSceneManager._current_scene_root_node = _previous_level
	CogitoSceneManager._scene_state = _previous_state
	CogitoSceneManager._destroyed_nodes = _previous_destroyed_nodes
	CogitoSceneManager._destroyed_nodes_level_id = _previous_destroyed_level_id
	_cleanup_saves()


func _spawn(flags: int, settings := {}, with_actor := false, rigid := false) -> CogitoProperties:
	var holder: Node3D
	if rigid:
		holder = FIXTURES.RigidHolder.new()
	else:
		holder = FIXTURES.Holder.new()
	_next_x += 10.0
	holder.position = Vector3(_next_x, 50, 0)
	var original: CogitoProperties = PROPS.instantiate()
	original.elemental_properties = flags
	original.is_logging = false
	original.spawn_on_chilled = _dummy_vfx
	original.spawn_on_frozen = _dummy_vfx
	original.spawn_on_poisoned = _dummy_vfx
	original.spawn_on_charred = _dummy_vfx
	for key in settings:
		original.set(key, settings[key])
	holder.add_child(original)
	holder.cogito_properties = original
	if with_actor:
		var a := CogitoActorElements.new()
		a.name = "CogitoActorElements"
		holder.add_child(a)
	_world.add_child(holder)
	await _frames()
	return original


func _actor_of(original: CogitoProperties) -> CogitoActorElements:
	return original.get_parent().get_node("CogitoActorElements")


func _damage_taken(original: CogitoProperties) -> float:
	return original.get_parent().taken


# Serialises like a save file would, both as Variant text and through JSON.


func _roundtrip(data: Dictionary, json := false) -> Dictionary:
	if json:
		return JSON.parse_string(JSON.stringify(data))
	return str_to_var(var_to_str(data))


func _effect_count(original: CogitoProperties, kind: StringName) -> int:
	var n := 0
	for child in original.get_parent().get_children():
		if (
			child.get_meta(CogitoProperties.VFX_KIND_META, &"x") == kind
			and !child.is_queued_for_deletion()
		):
			n += 1
	return n


func _frames(count := 2) -> void:
	for _frame in count:
		await get_tree().process_frame


func _physics_frames(count := 2) -> void:
	for _frame in count:
		await get_tree().physics_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _near(a: float, b: float, tolerance := 0.1) -> bool:
	return absf(a - b) <= tolerance


func _make_area(fire := true) -> CogitoElementArea:
	var area := CogitoElementArea.new()
	area.element = E.FIRE if fire else E.WATER
	area.collision_mask = 0
	_next_x += 10.0
	area.position = Vector3(_next_x, -50, 0)
	var visual := Node3D.new()
	area.add_child(visual)
	area.visuals = [visual]
	_world.add_child(area)
	return area


func _build_level() -> void:
	_level = SAVE_LEVEL.new()
	_level.name = "Level"
	_world.add_child(_level)
	CogitoSceneManager._current_scene_root_node = _level
	_level.populate()


func _level_properties(path: String) -> CogitoProperties:
	return _level.get_node(path + "/CogitoProperties") as CogitoProperties


func _free_level() -> void:
	CogitoSceneManager._current_scene_root_node = _world
	_level.free()
	_level = null


func _cleanup_saves() -> void:
	var dir := CogitoSceneManager.cogito_state_dir + SLOT
	if !DirAccess.dir_exists_absolute(dir):
		return
	for file_name in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + file_name)
	DirAccess.remove_absolute(dir)


func test_sustained_fire() -> void:
	var original := await _spawn(F.FLAMMABLE, {"heat_radius": 1.0})
	original.set_on_fire()
	var data := _roundtrip(original.get_element_save_data())
	var fire_data := assert_bool(data.get("v") == 1 and data.get("on_fire") == true)
	fire_data.override_failure_message("save data has version 1 and the fire").is_true()
	var restored := await _spawn(F.FLAMMABLE, {"heat_radius": 1.0})
	var signals_seen := FIXTURES.RestoreSignals.new(restored)
	restored.apply_element_save_data(data)
	var sustained_fire := assert_bool(
		(
			restored.is_on_fire
			and restored.get_element_level(E.FIRE) == restored.buildup_max
			and restored._timed_states.is_empty()
		)
	)
	sustained_fire.override_failure_message("sustained fire restored").is_true()
	var radiant_heat := assert_bool(
		restored.get_node_or_null("HeatSensor") != null and restored.is_processing()
	)
	radiant_heat.override_failure_message(
		"restored fire radiates heat again (heat sensor, processing)"
	)
	radiant_heat.is_true()
	var restore_signal := assert_bool(signals_seen.quiet() and signals_seen.restored == 1)
	(
		restore_signal
		. override_failure_message("fire restore emits only element_state_restored")
		. is_true()
	)
	await _frames()
	var fire_effect := assert_bool(_effect_count(restored, CogitoProperties.VFX_FIRE) == 1)
	fire_effect.override_failure_message("fire VFX present after restore").is_true()
	original.extinguish(false)
	restored.extinguish(false)


func test_remaining_fuel_and_charred_state() -> void:
	var original := await _spawn(F.FLAMMABLE, {"fuel": 2.0})
	original.apply_element(E.FIRE, 1.0)
	await _wait(0.8)
	var data := _roundtrip(original.get_element_save_data(), true)
	original.extinguish(false)
	var restored := await _spawn(F.FLAMMABLE, {"fuel": 2.0})
	var signals_seen := FIXTURES.RestoreSignals.new(restored)
	restored.apply_element_save_data(data)
	var remaining_fuel := assert_bool(
		restored.is_on_fire and _near(restored.fuel_remaining, 1.2, 0.1)
	)
	remaining_fuel.override_failure_message(
		"fuel_remaining continues after JSON round trip: %.2f" % restored.fuel_remaining
	)
	remaining_fuel.is_true()
	await _wait(0.8)
	var still_burning := assert_bool(restored.is_on_fire)
	(
		still_burning
		. override_failure_message("still burning before the remaining fuel is used")
		. is_true()
	)
	await _wait(0.7)
	var burnout := assert_bool(
		(
			!restored.is_on_fire
			and restored.is_charred
			and !(restored.elemental_properties & F.FLAMMABLE)
		)
	)
	burnout.override_failure_message("burns out at the remaining time (CHAR)").is_true()
	var quiet_burnout := assert_bool(signals_seen.reactions.is_empty())
	(
		quiet_burnout
		. override_failure_message("no reactions from the restore or the burn out")
		. is_true()
	)

	# Charred object stays charred
	data = _roundtrip(restored.get_element_save_data())
	var r := await _spawn(F.FLAMMABLE, {"fuel": 2.0})
	r.apply_element_save_data(data)
	await _frames()
	var charred_state := assert_bool(
		(
			r.is_charred
			and !(r.elemental_properties & F.FLAMMABLE)
			and _effect_count(r, CogitoProperties.VFX_CHARRED) == 1
		)
	)
	charred_state.override_failure_message("charred restored: not flammable, charred VFX").is_true()
	r.apply_element(E.FIRE, 3.0)
	var ignition := assert_bool(!r.is_on_fire)
	ignition.override_failure_message("restored charred object can't be lit").is_true()


func test_saved_wetness(sustained: bool, _test_parameters := [[false], [true]]) -> void:
	var settings := {} if sustained else {"dry_time": 4.0}
	var original := await _spawn(F.WET if sustained else 0, settings)
	if sustained:
		await _frames(1)
	else:
		original.apply_element(E.WATER, 1.0)
		await _wait(2.0)
	var data := _roundtrip(original.get_element_save_data())
	if !sustained:
		original.make_dry()
	var restored := await _spawn(0, settings)
	restored.apply_element_save_data(data)
	if sustained:
		var sustained_wetness := assert_bool(
			(
				restored.is_wet
				and !restored._timed_states.has(E.WATER)
				and (restored.elemental_properties & F.WET)
			)
		)
		sustained_wetness.override_failure_message("sustained wetness restored").is_true()
		await _wait(0.5)
		(
			assert_bool(restored.is_wet)
			. override_failure_message("sustained wetness doesn't dry")
			. is_true()
		)
		return
	var timed_wetness := assert_bool(
		(
			restored.is_wet
			and restored._timed_states.has(E.WATER)
			and _near(restored.get_element_level(E.WATER), 0.5)
		)
	)
	timed_wetness.override_failure_message(
		"timed wetness restored with its level: %.2f" % restored.get_element_level(E.WATER)
	)
	timed_wetness.is_true()
	var wet_flag := assert_bool((restored.elemental_properties & F.WET) != 0)
	wet_flag.override_failure_message("WET flag restored").is_true()
	await _wait(1.2)
	var still_wet := assert_bool(restored.is_wet)
	still_wet.override_failure_message("still wet before the remaining dry time").is_true()
	await _wait(1.3)
	var dried := assert_bool(!restored.is_wet)
	(
		dried
		. override_failure_message("dries after the remaining time, not the full dry_time")
		. is_true()
	)


func test_timed_electricity() -> void:
	var original := await _spawn(F.CONDUCTIVE)
	original.apply_element(E.SHOCK, 1.0)
	await _wait(1.0)
	var data := _roundtrip(original.get_element_save_data())
	original.loose_electricity()
	var restored := await _spawn(F.CONDUCTIVE)
	restored.apply_element_save_data(data)
	var timed_charge := assert_bool(
		(
			restored.is_electric
			and restored._timed_states.has(E.SHOCK)
			and _near(restored.get_element_level(E.SHOCK), 0.5)
		)
	)
	timed_charge.override_failure_message(
		"timed electricity restored: %.2f" % restored.get_element_level(E.SHOCK)
	)
	timed_charge.is_true()
	await _wait(1.3)
	var discharged := assert_bool(!restored.is_electric)
	discharged.override_failure_message("electricity runs out after the remaining time").is_true()


func test_chill() -> void:
	var original := await _spawn(0, {"chill_time": 4.0})
	original.apply_element(E.COLD, 1.0)
	await _wait(1.0)
	var data := _roundtrip(original.get_element_save_data())
	original._warm_up()
	var restored := await _spawn(0, {"chill_time": 4.0})
	restored.apply_element_save_data(data)
	await _frames()
	var chill := assert_bool(
		(
			restored.is_chilled
			and _near(restored.get_element_level(E.COLD), 0.75)
			and _effect_count(restored, CogitoProperties.VFX_CHILLED) == 1
		)
	)
	chill.override_failure_message(
		"chill restored with level and VFX: %.2f" % restored.get_element_level(E.COLD)
	)
	chill.is_true()
	await _wait(3.3)
	var warmed := assert_bool(
		!restored.is_chilled and _effect_count(restored, CogitoProperties.VFX_CHILLED) == 0
	)
	warmed.override_failure_message("chill wears off after the remaining time").is_true()


func test_timed_freeze_on_moving_body() -> void:
	var original := await _spawn(0, {"freeze_time": 3.0, "dry_time": 0.0}, false, true)
	var p_body := original.get_parent() as RigidBody3D
	original.apply_element(E.WATER, 1.0)
	original.apply_element(E.COLD, 1.0)
	var frozen_setup := assert_bool(original.is_frozen and p_body.freeze)
	frozen_setup.override_failure_message("setup: timed freeze").is_true()
	await _wait(1.0)
	var data := _roundtrip(original.get_element_save_data())
	original.thaw()
	var restored := await _spawn(0, {"freeze_time": 3.0, "dry_time": 0.0}, false, true)
	var body := restored.get_parent() as RigidBody3D
	restored.apply_element_save_data(data)
	await _frames()
	var restored_ice := assert_bool(
		(
			restored.is_frozen
			and body.freeze
			and restored._timed_states.has(E.COLD)
			and _near(restored.get_element_level(E.COLD), 0.67)
		)
	)
	restored_ice.override_failure_message(
		"timed freeze restored, body frozen: %.2f" % restored.get_element_level(E.COLD)
	)
	restored_ice.is_true()
	var frozen_effect := assert_bool(
		_effect_count(restored, CogitoProperties.VFX_FROZEN) == 1 and !restored.is_wet
	)
	frozen_effect.override_failure_message("frozen VFX, not wet while frozen").is_true()
	await _wait(2.4)
	var thawed := assert_bool(!restored.is_frozen and !body.freeze)
	thawed.override_failure_message(
		"thaws after the remaining time, body back to its original freeze (false)"
	)
	thawed.is_true()
	var timed_water := assert_bool(restored.is_wet and restored._timed_states.has(E.WATER))
	timed_water.override_failure_message("thawed: timed wetness as before the freeze").is_true()


func test_sustained_freeze_on_held_body() -> void:
	var original := await _spawn(F.WET, {}, false, true)
	(original.get_parent() as RigidBody3D).freeze = true
	await _frames(3)
	original.freeze()
	var data := _roundtrip(original.get_element_save_data())
	var restored := await _spawn(0, {}, false, true)
	var body := restored.get_parent() as RigidBody3D
	assert_bool(!body.freeze).override_failure_message("setup: fresh body not frozen").is_true()
	restored.apply_element_save_data(data)
	var held_ice := assert_bool(
		restored.is_frozen and body.freeze and !restored._timed_states.has(E.COLD)
	)
	held_ice.override_failure_message("freeze() freeze restored, sustained").is_true()
	restored.apply_element_save_data(data)
	var repeated_restore := assert_bool(
		restored.is_frozen and body.freeze and restored._rigid_freeze_before
	)
	repeated_restore.override_failure_message("applying twice keeps the original freeze value")
	repeated_restore.is_true()
	restored.thaw()
	var original_freeze := assert_bool(body.freeze)
	original_freeze.override_failure_message(
		"thaw restores the original freeze value (true) from the save"
	)
	original_freeze.is_true()
	var wetness := assert_bool(
		(
			restored.is_wet
			and !restored._timed_states.has(E.WATER)
			and (restored.elemental_properties & F.WET)
		)
	)
	wetness.override_failure_message("thaw restores sustained wetness").is_true()
	body.freeze = false


func test_poison_tick_progress() -> void:
	var original := await _spawn(0, {"poison_time": 10.0, "poison_damage_per_second": 2.0})
	original.apply_element(E.POISON, 1.0)
	await _wait(0.5)
	var data := _roundtrip(original.get_element_save_data())
	original.cure_poison()
	var restored := await _spawn(0, {"poison_time": 10.0, "poison_damage_per_second": 2.0})
	restored.apply_element_save_data(data)
	await _frames()
	var poison_state := assert_bool(
		(
			restored.is_poisoned
			and _damage_taken(restored) == 0.0
			and _effect_count(restored, CogitoProperties.VFX_POISONED) == 1
		)
	)
	(
		poison_state
		. override_failure_message("poison restored, no damage from the restore, VFX")
		. is_true()
	)
	await _wait(0.6)
	var next_tick := assert_bool(_near(_damage_taken(restored), 2.0, 0.01))
	next_tick.override_failure_message(
		"poison tick continues from the saved tick time: %.2f" % _damage_taken(restored)
	)
	next_tick.is_true()


func test_subthreshold_buildup() -> void:
	var original := await _spawn(F.FLAMMABLE)
	original.apply_element(E.FIRE, 0.5)
	original.apply_element(E.POISON, 0.3)
	var data := _roundtrip(original.get_element_save_data())
	var restored := await _spawn(F.FLAMMABLE)
	restored.apply_element_save_data(data)
	var levels := assert_bool(
		(
			_near(restored.get_element_level(E.FIRE), 0.5, 0.02)
			and _near(restored.get_element_level(E.POISON), 0.3, 0.02)
			and !restored.is_on_fire
			and !restored.is_poisoned
		)
	)
	levels.override_failure_message("element buildup restored without states").is_true()
	var decay := assert_bool(restored.is_processing())
	decay.override_failure_message("buildup decays again (processing)").is_true()


func test_quiet_restore_replaces_effects() -> void:
	var original := await _spawn(F.CONDUCTIVE, {"poison_damage_per_second": 5.0})
	original.apply_element(E.WATER, 1.0)
	original.apply_element(E.SHOCK, 1.0)
	original.apply_element(E.POISON, 1.0)
	var data := _roundtrip(original.get_element_save_data())
	var neutral := await _spawn(F.FLAMMABLE)
	var neutral_data := _roundtrip(neutral.get_element_save_data())
	original.cure_poison()

	# Restoring onto a burning object: wet data doesn't douse, steam or extinguish
	var restored := await _spawn(F.CONDUCTIVE | F.FLAMMABLE, {"poison_damage_per_second": 5.0})
	restored.set_on_fire()
	await _frames()
	var signals_seen := FIXTURES.RestoreSignals.new(restored)
	restored.apply_element_save_data(data)
	restored.apply_element_save_data(data)
	await _frames()
	var active_states := assert_bool(
		!restored.is_on_fire and restored.is_wet and restored.is_electric and restored.is_poisoned
	)
	active_states.override_failure_message("states replaced by the save").is_true()
	var quiet_restore := assert_bool(
		signals_seen.quiet() and signals_seen.restored == 2 and _damage_taken(restored) == 0.0
	)
	quiet_restore.override_failure_message(
		(
			"restore: no reactions, no state signals, no damage (reactions %s)"
			% [signals_seen.reactions]
		)
	)
	quiet_restore.is_true()
	var active_effects := assert_bool(
		(
			_effect_count(restored, CogitoProperties.VFX_WET) == 1
			and _effect_count(restored, CogitoProperties.VFX_ELECTRIC) == 1
			and _effect_count(restored, CogitoProperties.VFX_POISONED) == 1
		)
	)
	(
		active_effects
		. override_failure_message("one VFX per active state after applying twice")
		. is_true()
	)
	var inactive_effects := assert_bool(
		(
			_effect_count(restored, CogitoProperties.VFX_FIRE) == 0
			and _effect_count(restored, CogitoProperties.VFX_CHILLED) == 0
		)
	)
	inactive_effects.override_failure_message("no VFX for inactive states").is_true()
	restored.apply_element_save_data(neutral_data)
	await _frames()
	var cleared_states := assert_bool(
		(
			!restored.is_wet
			and !restored.is_electric
			and !restored.is_poisoned
			and restored.element_levels.is_empty()
		)
	)
	cleared_states.override_failure_message("neutral save clears all states").is_true()
	var cleared_effects := assert_bool(
		(
			(
				_effect_count(restored, CogitoProperties.VFX_WET)
				+ _effect_count(restored, CogitoProperties.VFX_ELECTRIC)
				+ _effect_count(restored, CogitoProperties.VFX_POISONED)
			)
			== 0
		)
	)
	cleared_effects.override_failure_message("neutral save removes the VFX").is_true()
	var idle_restore := assert_bool(signals_seen.quiet() and !restored.is_processing())
	idle_restore.override_failure_message("neutral restore quiet, nothing processing").is_true()


func test_remaining_stun_and_cooldown() -> void:
	var original := await _spawn(F.CONDUCTIVE, {}, true)
	var a := _actor_of(original)
	a.stun(2.0)
	await _wait(0.5)
	var data := _roundtrip(original.get_element_save_data())
	var actor_data := _roundtrip(a.get_element_save_data())
	var restored := await _spawn(F.CONDUCTIVE, {}, true)
	var b := _actor_of(restored)
	var stuns := [0]
	b.stunned.connect(func(): stuns[0] += 1)
	restored.apply_element_save_data(data)
	b.apply_element_save_data(actor_data)
	var stun := assert_bool(
		b.is_stunned and _near(b.stun_time_left, 1.5) and b.speed_multiplier == 0.0 and !b.can_act()
	)
	stun.override_failure_message("stun restored with remaining time: %.2f" % b.stun_time_left)
	stun.is_true()
	(
		assert_bool(stuns[0] == 0)
		. override_failure_message("restored stun doesn't emit stunned")
		. is_true()
	)
	await _wait(1.7)
	var cooldown := assert_bool(
		!b.is_stunned and b.stun_cooldown_left > 1.0 and b.speed_multiplier == 1.0
	)
	(
		cooldown
		. override_failure_message("stun ends after the remaining time, cooldown starts")
		. is_true()
	)


func test_remaining_refreeze_immunity() -> void:
	var original := await _spawn(0, {}, true)
	var a := _actor_of(original)
	original.apply_element(E.WATER, 1.0)
	original.apply_element(E.COLD, 1.0)
	for _press in 20:
		if !original.is_frozen:
			break
		a.struggle()
	await _wait(1.0)
	var data := _roundtrip(original.get_element_save_data())
	var actor_data := _roundtrip(a.get_element_save_data())
	var restored := await _spawn(0, {}, true)
	var b := _actor_of(restored)
	restored.apply_element_save_data(data)
	b.apply_element_save_data(actor_data)
	var immunity := assert_bool(
		restored.freeze_immune and _near(b._immunity_left, 2.0) and restored.is_wet
	)
	(
		immunity
		. override_failure_message("refreeze immunity restored: %.2f" % b._immunity_left)
		. is_true()
	)
	restored.apply_element(E.COLD, 1.0)
	var chilled := assert_bool(restored.is_chilled and !restored.is_frozen)
	chilled.override_failure_message("immune actor gets chilled, not frozen").is_true()
	await _wait(2.3)
	var expired := assert_bool(!restored.freeze_immune)
	expired.override_failure_message("immunity ends after the remaining time").is_true()


func test_frozen_actor_cannot_move() -> void:
	var original := await _spawn(0, {}, true)
	original.apply_element(E.WATER, 1.0)
	original.apply_element(E.COLD, 1.0)
	var data := _roundtrip(original.get_element_save_data())
	var restored := await _spawn(0, {}, true)
	restored.apply_element_save_data(data)
	var movement := assert_bool(
		_actor_of(restored).speed_multiplier == 0.0 and !_actor_of(restored).can_jump()
	)
	movement.override_failure_message("restored frozen actor can't move").is_true()


func test_campfire_state_and_relight_buildup() -> void:
	var a := _make_area()
	await _frames()
	var reactions := []
	a.reaction_triggered.connect(func(r): reactions.append(r))
	a.apply_element(E.WATER, 1.0)
	var doused := assert_bool(!a.enabled and reactions == [&"douse"])
	doused.override_failure_message("setup: campfire doused").is_true()
	a.apply_element(E.FIRE, 0.4)
	var data := _roundtrip(a.get_element_save_data())
	var b := _make_area()
	await _frames()
	var b_reactions := []
	b.reaction_triggered.connect(func(r): b_reactions.append(r))
	b.apply_element_save_data(data)
	var relight_level := assert_bool(
		!b.enabled and !b.visuals[0].visible and _near(b._levels.get(E.FIRE, 0.0), 0.4, 0.05)
	)
	relight_level.override_failure_message("doused campfire stays doused, relight buildup kept")
	relight_level.is_true()
	var quiet_area := assert_bool(b_reactions.is_empty())
	quiet_area.override_failure_message("area restore emits no reaction").is_true()
	await _wait(0.6)
	var still_doused := assert_bool(!b.enabled)
	still_doused.override_failure_message("restored doused campfire doesn't relight by itself")
	still_doused.is_true()

	# Disabled -> enabled
	var c := _make_area()
	c.enabled = false
	await _frames()
	b.enabled = true
	data = _roundtrip(b.get_element_save_data())
	c.apply_element_save_data(data)
	var enabled_state := assert_bool(c.enabled and c.visuals[0].visible)
	enabled_state.override_failure_message(
		"enabled state restored on an area that is off by default"
	)
	enabled_state.is_true()
	b.interact()
	data = _roundtrip(b.get_element_save_data(), true)
	c.apply_element_save_data(data)
	var disabled_state := assert_bool(!c.enabled)
	(
		disabled_state
		. override_failure_message("switched off area stays off (JSON round trip)")
		. is_true()
	)


func test_electrified_water() -> void:
	var water := _make_area(false)
	water.conducts_shock = true
	await _frames()
	water.apply_element(E.SHOCK, 1.0)
	var data := _roundtrip(water.get_element_save_data())
	var water2 := _make_area(false)
	water2.conducts_shock = true
	await _frames()
	water2.apply_element_save_data(data)
	var charged_water := assert_bool(
		water2.is_electric and _near(water2._shock_time_left, water.shock_hold_time, 0.3)
	)
	charged_water.override_failure_message("electrified water restored").is_true()


func test_scene_state_rebuilds_level(_timeout := 15000) -> void:
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(400, 1, 400)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0, -0.5, 100)
	_world.add_child(floor_body)
	_build_level()
	await _physics_frames(10)
	var npc: CogitoNPC = _level.get_node("NPC")
	var npc2: CogitoNPC = _level.get_node("NPC2")
	var level_setup := assert_bool(
		_level_properties("Torch").is_on_fire and _level.get_node("Campfire").enabled
	)
	level_setup.override_failure_message("setup: torch lit on ready, campfire burning").is_true()
	_level_properties("Crate").apply_element(E.WATER, 1.0)
	_level_properties("Stump").set_on_fire()
	_level.get_node("Campfire").apply_element(E.WATER, 1.0)
	_level_properties("Torch").extinguish(false)
	_level_properties("Bush").set_on_fire()
	_level_properties("Crate2").set_on_fire()
	npc.cogito_properties.set_on_fire()
	npc2.state_chart.send_event("panic")
	# A Persist object created during play (no level id, created again from its scene file on load).
	var spawned: Node3D = CRATE.instantiate()
	spawned.name = "Spawned"
	spawned.position = Vector3(80, 200, 0)
	_level.add_child(spawned)
	spawned.get_node("CogitoProperties").apply_element(E.POISON, 1.0)
	var spawned_id := CogitoPersistentId.of(spawned)
	await _physics_frames(3)
	var panic_setup := assert_bool(
		npc.is_panicking() and npc2.is_panicking() and !npc2.cogito_properties.is_on_fire
	)
	(
		panic_setup
		. override_failure_message("setup: burning NPC and NPC panicking without fire")
		. is_true()
	)
	await _wait(0.6)
	var burned_objects := assert_bool(
		_level.get_node_or_null("Bush") == null and _level.get_node_or_null("Crate2") == null
	)
	burned_objects.override_failure_message("setup: bush and Persist crate burned to nothing")
	burned_objects.is_true()
	var crate_level := _level_properties("Crate").get_element_level(E.WATER)

	CogitoSceneManager.save_scene_state(SCENE_NAME, SLOT)
	var state: CogitoSceneState = CogitoSceneManager._scene_state
	var destroyed_list := assert_bool(
		state.saved_destroyed_nodes == [{"cogito_id": "Bush", "path": "."}]
	)
	destroyed_list.override_failure_message(
		"destroyed non-Persist bush recorded: %s" % [state.saved_destroyed_nodes]
	)
	destroyed_list.is_true()
	var keys := state.saved_element_states.map(func(e): return e["cogito_id"] + "|" + e["path"])
	var state_keys := assert_bool(
		(
			keys.has("level:Crate|CogitoProperties")
			and keys.has("Stump/CogitoProperties|.")
			and keys.has("Campfire|.")
			and keys.has("level:NPC|CogitoActorElements")
		)
	)
	state_keys.override_failure_message(
		"element states keyed by Persist owner or level path: %s" % [keys]
	)
	state_keys.is_true()

	# "Load the level again": fresh level from scratch, then the scene state.
	_free_level()
	_build_level()
	var level_defaults := assert_bool(
		(
			_level.get_node_or_null("Bush") != null
			and _level.get_node_or_null("Crate2") != null
			and _level.get_node("Campfire").enabled
		)
	)
	level_defaults.override_failure_message("fresh level has its defaults").is_true()
	# Load in the same frame, while the torch's on-ready ignition is still pending.
	CogitoSceneManager.load_scene_state(SCENE_NAME, SLOT)
	await _frames(2)
	await _physics_frames(2)
	npc = _level.get_node("NPC")
	npc2 = _level.get_node("NPC2")
	var wet_crate := assert_bool(
		(
			_level_properties("Crate").is_wet
			and _level_properties("Crate")._timed_states.has(E.WATER)
			and _near(_level_properties("Crate").get_element_level(E.WATER), crate_level, 0.1)
		)
	)
	wet_crate.override_failure_message("Persist crate: timed wetness restored").is_true()
	var wet_effect := assert_bool(
		_effect_count(_level_properties("Crate"), CogitoProperties.VFX_WET) == 1
	)
	wet_effect.override_failure_message("Persist crate: one wet VFX").is_true()
	var burning_stump := assert_bool(_level_properties("Stump").is_on_fire)
	burning_stump.override_failure_message("non-Persist stump: fire restored").is_true()
	var spawned2 := CogitoPersistentId.find(get_tree(), spawned_id)
	var spawned_state := assert_bool(
		(
			spawned_id.begins_with("persist:")
			and spawned2 != null
			and spawned2.get_node("CogitoProperties").is_poisoned
		)
	)
	spawned_state.override_failure_message(
		"Persist object spawned during play: created again, poison restored"
	)
	spawned_state.is_true()
	var torch_state := assert_bool(
		(
			!_level_properties("Torch").is_on_fire
			and _effect_count(_level_properties("Torch"), CogitoProperties.VFX_FIRE) == 0
		)
	)
	torch_state.override_failure_message("ignite_on_ready torch put out before the save stays out")
	torch_state.is_true()
	var campfire_state := assert_bool(!_level.get_node("Campfire").enabled)
	campfire_state.override_failure_message("doused campfire stays doused").is_true()
	var missing_bush := assert_bool(
		_level.get_node_or_null("Bush") == null or _level.get_node("Bush").is_queued_for_deletion()
	)
	missing_bush.override_failure_message("destroyed non-Persist bush stays gone").is_true()
	var missing_crate := assert_bool(
		(
			_level.get_node_or_null("Crate2") == null
			or _level.get_node("Crate2").is_queued_for_deletion()
		)
	)
	missing_crate.override_failure_message("destroyed Persist crate stays gone").is_true()
	var destroyed_count := assert_bool(CogitoSceneManager._get_destroyed_nodes().size() == 1)
	(
		destroyed_count
		. override_failure_message("destroyed list carried over to the next save")
		. is_true()
	)
	var burning_panic := assert_bool(npc.cogito_properties.is_on_fire and npc.is_panicking())
	burning_panic.override_failure_message("burning NPC loads burning and panicking").is_true()
	var idle_npc := assert_bool(!npc2.is_panicking())
	idle_npc.override_failure_message("NPC saved panicking without fire calms down").is_true()
	await _wait(0.5)
	var stable_panic := assert_bool(npc.is_panicking() and !npc2.is_panicking())
	stable_panic.override_failure_message("panic states stay that way").is_true()
	npc.cogito_properties.extinguish(false)
	await _physics_frames(2)
	var idle_after_dousing := assert_bool(!npc.is_panicking())
	idle_after_dousing.override_failure_message("restored burning NPC calms down when extinguished")
	idle_after_dousing.is_true()
	_free_level()


func test_legacy_scene_and_player_state() -> void:
	var slot_dir := CogitoSceneManager.cogito_state_dir.path_join(SLOT)
	DirAccess.make_dir_recursive_absolute(slot_dir)
	var legacy_path := slot_dir.path_join("old_state.tres")
	var state := CogitoSceneState.new()
	ResourceSaver.save(state, legacy_path)
	var text := FileAccess.get_file_as_string(legacy_path)
	var lines := PackedStringArray()
	for line in text.split("\n"):
		if !line.begins_with("saved_element_states") and !line.begins_with("saved_destroyed_nodes"):
			lines.append(line)
	var file := FileAccess.open(legacy_path, FileAccess.WRITE)
	file.store_string("\n".join(lines))
	file.close()
	var old: CogitoSceneState = ResourceLoader.load(
		legacy_path, "", ResourceLoader.CACHE_MODE_IGNORE
	)
	var legacy_fields := assert_bool(
		old != null and old.saved_element_states.is_empty() and old.saved_destroyed_nodes.is_empty()
	)
	(
		legacy_fields
		. override_failure_message("old scene state loads with empty element fields")
		. is_true()
	)
	DirAccess.remove_absolute(legacy_path)
	_build_level()
	await _frames(2)
	# Write it as the slot's scene state and load it.
	old.write_state(SLOT, SCENE_NAME)
	CogitoSceneManager.load_scene_state(SCENE_NAME, SLOT)
	await _frames(2)
	var initial_states := assert_bool(
		(
			_level_properties("Torch").is_on_fire
			and _level.get_node("Campfire").enabled
			and _level.get_node_or_null("Bush") != null
		)
	)
	(
		initial_states
		. override_failure_message("old save leaves elements at the scene defaults")
		. is_true()
	)
	var player_state := CogitPlayerAdvancedState.new()
	var empty_player_data := assert_bool(player_state.element_state.is_empty())
	empty_player_data.override_failure_message("old player state has no element data").is_true()
	_free_level()


func test_player_state_updates_status_hud() -> void:
	var player := await _world.spawn_player(Vector3(-100, 1, 0))
	var hud: CogitoElementStatusHud = HUD.instantiate()
	_world.add_child(hud)
	await _physics_frames(10)
	hud.bind_player(player)
	var props := player.cogito_properties
	props.poison_damage_per_second = 0.0
	props.apply_element(E.WATER, 1.0)
	props.apply_element(E.POISON, 2.0)
	player.actor_elements.stun(3.0)
	var state := player.create_new_state() as CogitPlayerAdvancedState
	state._save_element_state(player)
	var saved_sections := assert_bool(
		state.element_state.has("properties") and state.element_state.has("actor")
	)
	(
		saved_sections
		. override_failure_message("player state holds properties and actor data")
		. is_true()
	)
	var saved: Dictionary = str_to_var(var_to_str(state.element_state))
	props.cure_poison()
	props.make_dry()
	player.actor_elements.stun_time_left = 0.01
	await _wait(0.6)  # Stun and its flash end.
	var clean_player := assert_bool(
		(
			!hud.is_status_visible(S.POISON)
			and !hud.is_status_visible(S.WET)
			and !player.actor_elements.is_stunned
		)
	)
	clean_player.override_failure_message("setup: player clean, HUD empty").is_true()
	var signals_seen := FIXTURES.RestoreSignals.new(props)
	state.element_state = saved
	state._load_element_state(player)
	await _frames(1)
	var restored_status := assert_bool(
		props.is_poisoned and props.is_wet and props._timed_states.has(E.POISON)
	)
	restored_status.override_failure_message("player element states restored from the player state")
	restored_status.is_true()
	var restored_stun := assert_bool(
		player.actor_elements.is_stunned and player.actor_elements.stun_time_left > 2.0
	)
	restored_stun.override_failure_message("player stun restored").is_true()
	assert_bool(signals_seen.quiet()).override_failure_message("player restore quiet").is_true()
	var hud_states := assert_bool(hud.is_status_active(S.POISON) and hud.is_status_active(S.WET))
	hud_states.override_failure_message("HUD shows the restored states").is_true()
	var poison_overlay := assert_bool(
		hud.get_overlay_status() == S.POISON and hud.is_overlay_visible()
	)
	poison_overlay.override_failure_message(
		(
			"HUD overlay for the restored poison (%s, %s)"
			% [hud.get_overlay_status(), hud.is_overlay_visible()]
		)
	)
	poison_overlay.is_true()
	# Saves without element data leave the player alone.
	state.element_state = {}
	state._load_element_state(player)
	await _frames(1)
	var unaffected_player := assert_bool(props.is_poisoned)
	unaffected_player.override_failure_message("empty element_state doesn't touch the player")
	unaffected_player.is_true()

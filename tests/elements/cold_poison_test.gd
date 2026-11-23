extends GdUnitTestSuite

const FIXTURES := preload("res://tests/fixtures/element_fixtures.gd")
const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
const E = CogitoProperties.Element
const F = CogitoProperties.ElementalProperties

var _world: Node3D


class RigidHolder:
	extends RigidBody3D
	var cogito_properties: CogitoProperties


func before_test() -> void:
	_world = auto_free(Node3D.new())
	add_child(_world)


func after_test() -> void:
	await _frames()


func _set_durations(properties: CogitoProperties) -> void:
	properties.chill_time = 0.3
	properties.freeze_time = 0.3
	properties.poison_time = 0.3
	properties.state_damage_interval = 0.1
	properties.dry_time = 20.0


func _make_properties(
	flags: int, pos := Vector3.ZERO, settings := {}, holder: Node3D = null
) -> CogitoProperties:
	var body: Node3D = holder if holder else FIXTURES.Holder.new()
	body.position = pos
	var properties: CogitoProperties = PROPS.instantiate()
	properties.elemental_properties = flags
	properties.is_logging = false
	_set_durations(properties)
	for key in settings:
		properties.set(key, settings[key])
	body.add_child(properties)
	body.cogito_properties = properties
	_world.add_child(body)
	return properties


func _frames(count := 2) -> void:
	for _frame in count:
		await get_tree().process_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## Counts emissions of the given signals by name.


func _watch(properties: CogitoProperties) -> Dictionary:
	var events := {}
	for signal_name in [
		&"has_become_chilled",
		&"has_warmed_up",
		&"has_frozen",
		&"has_thawed",
		&"has_been_poisoned",
		&"has_been_cured",
		&"has_become_dry",
		&"has_become_wet",
		&"has_been_extinguished",
	]:
		events[signal_name] = 0
		properties.connect(signal_name, func(): events[signal_name] += 1)
	events["reactions"] = []
	properties.reaction_triggered.connect(func(r): events["reactions"].append(r))
	return events


func test_chill_buildup_and_recovery() -> void:
	var properties := _make_properties(0)
	var events := _watch(properties)
	await _frames()
	(
		assert_bool(!properties.is_processing())
		. override_failure_message("idle object: _process off")
		. is_true()
	)
	properties.apply_element(E.COLD, 0.5)
	(
		assert_bool(!properties.is_chilled)
		. override_failure_message("sub-threshold cold doesn't chill")
		. is_true()
	)
	properties.apply_element(E.COLD, 0.6)
	(
		assert_bool(properties.is_chilled and events[&"has_become_chilled"] == 1)
		. override_failure_message("dry object chills at threshold, signal fired")
		. is_true()
	)
	(
		assert_bool(properties.is_processing())
		. override_failure_message("chilled: _process on")
		. is_true()
	)
	await _wait(0.6)
	(
		assert_bool(
			(
				!properties.is_chilled
				and events[&"has_warmed_up"] == 1
				and properties.get_element_level(E.COLD) == 0.0
			)
		)
		. override_failure_message("chill wears off after chill_time, level 0")
		. is_true()
	)
	(
		assert_bool(!properties.is_processing())
		. override_failure_message("after chill: _process off")
		. is_true()
	)


func test_fire_warms_a_chilled_object() -> void:
	var properties := _make_properties(F.FLAMMABLE)
	var events := _watch(properties)
	await _frames()
	properties.apply_element(E.COLD, 1.2)
	properties.apply_element(E.FIRE, 0.5)
	(
		assert_bool(
			(
				properties.is_chilled
				and properties.get_element_level(E.COLD) < 0.8
				and properties.get_element_level(E.FIRE) == 0.0
			)
		)
		. override_failure_message("fire on chilled first reduces the chill")
		. is_true()
	)
	properties.apply_element(E.FIRE, 2.0)
	(
		assert_bool(
			!properties.is_chilled and events[&"has_warmed_up"] == 1 and properties.is_on_fire
		)
		. override_failure_message("enough fire ends the chill, leftover ignites")
		. is_true()
	)


func test_cold_cancels_heat_buildup() -> void:
	var properties := _make_properties(F.FLAMMABLE)
	await _frames()
	properties.apply_element(E.FIRE, 0.7)
	properties.apply_element(E.COLD, 0.4)
	(
		assert_bool(
			(
				is_equal_approx(properties.get_element_level(E.FIRE), 0.3)
				and properties.get_element_level(E.COLD) == 0.0
			)
		)
		. override_failure_message("cold cancels sub-threshold fire buildup first")
		. is_true()
	)
	properties.apply_element(E.COLD, 0.6)
	(
		assert_bool(
			(
				is_equal_approx(properties.get_element_level(E.COLD), 0.3)
				and properties.get_element_level(E.FIRE) == 0.0
			)
		)
		. override_failure_message("rest of the cold continues as buildup")
		. is_true()
	)


func test_frozen_objects_reject_water_fire_and_shock() -> void:
	var properties := _make_properties(F.CONDUCTIVE)
	var events := _watch(properties)
	await _frames()
	properties.apply_element(E.WATER, 1.0)
	assert_bool(properties.is_wet).override_failure_message("setup: timed wet").is_true()
	properties.apply_element(E.SHOCK, 1.0)
	(
		assert_bool(properties.is_electric)
		. override_failure_message("setup: electrified while wet")
		. is_true()
	)
	properties.apply_element(E.COLD, 1.0)
	(
		assert_bool(properties.is_frozen and !properties.is_wet and events[&"has_frozen"] == 1)
		. override_failure_message("wet + cold freezes, no longer wet")
		. is_true()
	)
	(
		assert_bool(&"freeze" in events["reactions"])
		. override_failure_message("reaction freeze emitted")
		. is_true()
	)
	(
		assert_bool(events[&"has_become_dry"] == 0)
		. override_failure_message("has_become_dry not emitted on freeze")
		. is_true()
	)
	(
		assert_bool(!properties.is_electric)
		. override_failure_message("electric object loses electricity when frozen")
		. is_true()
	)
	(
		assert_bool(!properties.can_conduct())
		. override_failure_message("frozen can't conduct even if CONDUCTIVE")
		. is_true()
	)
	properties.make_wet()
	properties.set_on_fire()
	(
		assert_bool(!properties.is_wet and !properties.is_on_fire)
		. override_failure_message("make_wet and set_on_fire do nothing while frozen")
		. is_true()
	)
	(
		assert_bool(
			(
				properties.apply_element(E.WATER, 1.0) == 0.0
				and properties.apply_element(E.SHOCK, 1.0) == 0.0
			)
		)
		. override_failure_message("WATER and SHOCK return 0 while frozen")
		. is_true()
	)
	(
		assert_bool(!properties.is_electric and !properties.is_wet)
		. override_failure_message("still neither electric nor wet")
		. is_true()
	)


func test_fire_partially_melts_then_thaws_ice() -> void:
	var properties := _make_properties(F.FLAMMABLE)
	var events := _watch(properties)
	await _frames()
	properties.apply_element(E.WATER, 1.0)
	properties.apply_element(E.COLD, 1.0)
	assert_bool(properties.is_frozen).override_failure_message("setup: frozen flammable").is_true()
	properties.apply_element(E.FIRE, 0.4)
	(
		assert_bool(properties.is_frozen and events[&"has_thawed"] == 0)
		. override_failure_message("small fire only melts part of the ice")
		. is_true()
	)
	properties.apply_element(E.FIRE, 0.6)
	(
		assert_bool(!properties.is_frozen and events[&"has_thawed"] == 1 and properties.is_wet)
		. override_failure_message("enough fire thaws, object is wet again")
		. is_true()
	)
	(
		assert_bool(&"thaw" in events["reactions"])
		. override_failure_message("reaction thaw emitted")
		. is_true()
	)
	(
		assert_bool(
			(
				properties.get_element_level(E.WATER) == properties.buildup_threshold
				and properties._timed_states.has(E.WATER)
			)
		)
		. override_failure_message("timed wetness restored")
		. is_true()
	)


func test_excess_fire_steams_after_thaw() -> void:
	var properties := _make_properties(F.FLAMMABLE)
	var events := _watch(properties)
	await _frames()
	properties.apply_element(E.WATER, 1.0)
	properties.apply_element(E.COLD, 1.0)
	properties.apply_element(E.FIRE, 3.0)
	(
		assert_bool(
			(
				!properties.is_frozen
				and !properties.is_wet
				and events[&"has_become_dry"] == 1
				and &"steam" in events["reactions"]
			)
		)
		. override_failure_message("leftover fire dries the thawed object (steam)")
		. is_true()
	)


func test_timed_freeze_restores_timed_wetness() -> void:
	var properties := _make_properties(0)
	var events := _watch(properties)
	await _frames()
	properties.apply_element(E.WATER, 1.0)
	properties.apply_element(E.COLD, 1.0)
	assert_bool(properties.is_frozen).override_failure_message("setup: timed freeze").is_true()
	await _wait(0.6)
	(
		assert_bool(
			(
				!properties.is_frozen
				and events[&"has_thawed"] == 1
				and properties.is_wet
				and properties._timed_states.has(E.WATER)
			)
		)
		. override_failure_message("timed freeze thaws by itself into timed wet")
		. is_true()
	)


func test_timed_freeze_restores_sustained_wetness() -> void:
	var properties := _make_properties(F.WET)
	await _frames()
	(
		assert_bool(properties.is_wet)
		. override_failure_message("setup: WET flag object is wet")
		. is_true()
	)
	properties.apply_element(E.COLD, 1.0)
	(
		assert_bool(properties.is_frozen and !(properties.elemental_properties & F.WET))
		. override_failure_message("sustained wet object freezes, WET flag cleared")
		. is_true()
	)
	await _wait(0.6)
	(
		assert_bool(
			(
				!properties.is_frozen
				and properties.is_wet
				and (properties.elemental_properties & F.WET)
				and !properties._timed_states.has(E.WATER)
			)
		)
		. override_failure_message("thaws back to sustained wet with WET flag")
		. is_true()
	)


func test_manual_freeze_requires_water_and_persists() -> void:
	var properties := _make_properties(0)
	await _frames()
	properties.freeze()
	(
		assert_bool(!properties.is_frozen)
		. override_failure_message("freeze() on a dry object does nothing")
		. is_true()
	)
	properties.make_wet()
	properties.freeze()
	(
		assert_bool(properties.is_frozen)
		. override_failure_message("freeze() freezes a wet object")
		. is_true()
	)
	await _wait(0.6)
	(
		assert_bool(properties.is_frozen)
		. override_failure_message("sustained freeze doesn't thaw by itself")
		. is_true()
	)
	properties.thaw()
	(
		assert_bool(!properties.is_frozen and properties.is_wet)
		. override_failure_message("thaw() melts it")
		. is_true()
	)


func test_wet_chilled_object_freezes_on_next_exposure() -> void:
	var properties := _make_properties(0)
	await _frames()
	properties.freeze_time = 0.0
	properties.apply_element(E.COLD, 1.0)
	properties.chill_time = 5.0
	properties.apply_element(E.WATER, 1.0)
	(
		assert_bool(properties.is_chilled and properties.is_wet)
		. override_failure_message("water on chilled: stays chilled and wet")
		. is_true()
	)
	properties.apply_element(E.COLD, 0.1)
	(
		assert_bool(properties.is_frozen and !properties.is_chilled)
		. override_failure_message("chilled + wet + more cold freezes")
		. is_true()
	)
	await _wait(0.5)
	(
		assert_bool(properties.is_frozen)
		. override_failure_message("freeze_time 0 never thaws by itself")
		. is_true()
	)


func test_rigid_body_recovers_its_original_freeze_setting() -> void:
	var moving_body := RigidHolder.new()
	moving_body.freeze = false
	var properties := _make_properties(F.WET, Vector3.ZERO, {}, moving_body)
	await _frames()
	properties.apply_element(E.COLD, 1.0)
	assert_bool(moving_body.freeze).override_failure_message("RigidBody3D parent freezes").is_true()
	await _wait(0.6)
	(
		assert_bool(!properties.is_frozen and !moving_body.freeze)
		. override_failure_message("RigidBody3D freeze restored to false after thaw")
		. is_true()
	)
	var held_body := RigidHolder.new()
	held_body.freeze = true
	properties = _make_properties(F.WET, Vector3.ZERO, {}, held_body)
	await _frames()
	properties.apply_element(E.COLD, 1.0)
	properties.thaw()
	(
		assert_bool(held_body.freeze)
		. override_failure_message("RigidBody3D original freeze=true restored")
		. is_true()
	)


func test_cold_quenches_a_fire() -> void:
	var properties := _make_properties(F.FLAMMABLE)
	var events := _watch(properties)
	await _frames()
	properties.set_on_fire()
	properties.apply_element(E.COLD, 0.6)
	(
		assert_bool(properties.is_on_fire)
		. override_failure_message("burning: sub-threshold cold doesn't extinguish")
		. is_true()
	)
	properties.apply_element(E.COLD, 0.6)
	(
		assert_bool(
			(
				!properties.is_on_fire
				and events[&"has_been_extinguished"] == 1
				and &"quench" in events["reactions"]
			)
		)
		. override_failure_message("cold >= threshold extinguishes, reaction quench")
		. is_true()
	)
	(
		assert_bool(properties.get_element_level(E.COLD) == 0.0 and !properties.is_chilled)
		. override_failure_message("leftover cold discarded")
		. is_true()
	)


func test_poison_damage_expiry_and_cure() -> void:
	var target := _make_properties(0)
	var events := _watch(target)
	await _frames()
	target.apply_element(E.POISON, 0.5)
	(
		assert_bool(!target.is_poisoned)
		. override_failure_message("sub-threshold poison doesn't poison")
		. is_true()
	)
	target.apply_element(E.POISON, 0.6)
	(
		assert_bool(target.is_poisoned and events[&"has_been_poisoned"] == 1)
		. override_failure_message("poison buildup poisons, signal fired")
		. is_true()
	)
	await _wait(0.25)
	var holder := target.get_parent() as FIXTURES.Holder
	assert_bool(holder.taken > 0.0).override_failure_message("poison damages the holder").is_true()
	var initial_level := target.get_element_level(E.POISON)
	target.apply_element(E.FIRE, 1.0)
	target.apply_element(E.WATER, 1.0)
	target.apply_element(E.COLD, 0.5)
	target.apply_element(E.SHOCK, 1.0)
	(
		assert_bool(target.get_element_level(E.POISON) <= initial_level)
		. override_failure_message("FIRE/WATER/COLD/SHOCK don't change the POISON level")
		. is_true()
	)
	await _wait(0.7)
	(
		assert_bool(!target.is_poisoned and events[&"has_been_cured"] == 1)
		. override_failure_message("timed poison ends by itself")
		. is_true()
	)
	target.apply_element(E.POISON, 1.5)
	assert_bool(target.is_poisoned).override_failure_message("re-poisoned").is_true()
	target.cure_poison()
	(
		assert_bool(
			(
				!target.is_poisoned
				and target.get_element_level(E.POISON) == 0.0
				and events[&"has_been_cured"] == 2
			)
		)
		. override_failure_message("cure_poison() ends it and emits signal")
		. is_true()
	)
	target.cure_poison()
	(
		assert_bool(events[&"has_been_cured"] == 2)
		. override_failure_message("cure_poison() when not poisoned emits nothing")
		. is_true()
	)
	await _frames()
	var properties := _make_properties(0)
	await _frames()
	properties.apply_element(E.POISON, 1.5)
	properties.cure_poison()
	(
		assert_bool(!properties.is_processing())
		. override_failure_message("cured object: _process off")
		. is_true()
	)


func test_poison_resistance_scales_buildup_and_damage() -> void:
	var properties := _make_properties(0, Vector3.ZERO, {"resist_poison": 100.0})
	await _frames()
	(
		assert_bool(properties.apply_element(E.POISON, 5.0) == 0.0 and !properties.is_poisoned)
		. override_failure_message("resist_poison 100: no buildup")
		. is_true()
	)
	await _wait(0.3)
	(
		assert_bool((properties.get_parent() as FIXTURES.Holder).taken == 0.0)
		. override_failure_message("resist_poison 100: no damage")
		. is_true()
	)
	# poison damage applies resistance
	properties = _make_properties(
		0, Vector3.ZERO, {"resist_poison": 50.0, "poison_damage_per_second": 10.0}
	)
	await _frames()
	properties.apply_element(E.POISON, 2.0)
	await _wait(0.35)
	var taken := (properties.get_parent() as FIXTURES.Holder).taken
	(
		assert_bool(taken > 0.0 and taken <= 3 * 0.5)
		. override_failure_message("poison damage scaled by resistance")
		. is_true()
	)


func test_configured_and_default_cold_damage() -> void:
	var properties := _make_properties(
		0, Vector3.ZERO, {"cold_damage_per_second": 5.0, "chill_time": 5.0}
	)
	await _frames()
	properties.apply_element(E.COLD, 1.0)
	await _wait(0.35)
	(
		assert_bool((properties.get_parent() as FIXTURES.Holder).taken > 0.0)
		. override_failure_message("cold_damage_per_second damages a chilled holder")
		. is_true()
	)
	properties = _make_properties(0)
	await _frames()
	properties.apply_element(E.COLD, 1.0)
	await _wait(0.2)
	(
		assert_bool((properties.get_parent() as FIXTURES.Holder).taken == 0.0)
		. override_failure_message("default cold_damage_per_second 0 deals nothing")
		. is_true()
	)


func test_cold_douses_a_fire_area() -> void:
	var area := CogitoElementArea.new()
	area.element = E.FIRE
	_world.add_child(area)
	var douses := [0]
	area.reaction_triggered.connect(
		func(r):
			if r == &"douse":
				douses[0] += 1
	)
	await _frames()
	area.apply_element(E.COLD, 0.6)
	(
		assert_bool(area.enabled)
		. override_failure_message("fire area survives sub-threshold cold")
		. is_true()
	)
	area.apply_element(E.COLD, 0.6)
	(
		assert_bool(!area.enabled and douses[0] == 1)
		. override_failure_message("fire area doused by cold")
		. is_true()
	)


func test_processing_stops_after_cold_and_poison_decay() -> void:
	var properties := _make_properties(F.FLAMMABLE | F.CONDUCTIVE)
	await _frames()
	properties.apply_element(E.COLD, 0.5)
	properties.apply_element(E.POISON, 0.5)
	await _wait(1.5)
	(
		assert_bool(!properties.is_processing())
		. override_failure_message("_process off once all buildup decayed")
		. is_true()
	)

extends GdUnitTestSuite

const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
const E = CogitoProperties.Element
const F = CogitoProperties.ElementalProperties

var _world: Node3D


class Holder:
	extends Node3D
	signal damage_received(
		amount: float, source: Node, hit_direction: Vector3, hit_position: Vector3
	)
	var cogito_properties: CogitoProperties
	var taken := 0.0

	func _init() -> void:
		damage_received.connect(func(amount, _source, _direction, _position): taken += amount)


func before_test() -> void:
	_world = auto_free(Node3D.new())
	add_child(_world)


func after_test() -> void:
	# Elemental VFX attach to their holder on the next frame.
	await _frames()


func _make_properties(flags: int) -> CogitoProperties:
	var holder := Holder.new()
	_world.add_child(holder)
	var properties: CogitoProperties = PROPS.instantiate()
	properties.elemental_properties = flags
	properties.is_logging = false
	holder.add_child(properties)
	holder.cogito_properties = properties
	return properties


func _frames(count := 2) -> void:
	for _frame in count:
		await get_tree().process_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func test_fire_buildup_dousing_and_drying() -> void:
	var wood := _make_properties(F.FLAMMABLE)
	await _frames()
	wood.apply_element(E.FIRE, 0.6)
	assert_bool(!wood.is_on_fire).override_failure_message("0.6 heat doesn't ignite").is_true()
	wood.apply_element(E.FIRE, 0.6)
	assert_bool(wood.is_on_fire).override_failure_message("accumulated heat ignites").is_true()
	var reactions := []
	wood.reaction_triggered.connect(func(r): reactions.append(r))
	wood.apply_element(E.WATER, 1.0)
	(
		assert_bool(!wood.is_on_fire and wood.is_wet and &"douse" in reactions)
		. override_failure_message("water douses fire and wets")
		. is_true()
	)
	wood.dry_time = 0.5
	await _wait(0.8)
	assert_bool(!wood.is_wet).override_failure_message("applied wetness dries out").is_true()


func test_nonflammable_material_loses_heat() -> void:
	var stone := _make_properties(0)
	stone.apply_element(E.FIRE, 2.0)
	(
		assert_bool(!stone.is_on_fire and stone.get_element_level(E.FIRE) > 0)
		. override_failure_message("non-flammable heats but doesn't burn")
		. is_true()
	)
	var initial_heat := stone.get_element_level(E.FIRE)
	await _wait(0.5)
	(
		assert_bool(stone.get_element_level(E.FIRE) < initial_heat)
		. override_failure_message("heat decays")
		. is_true()
	)


func test_heat_decays_between_exposures() -> void:
	var wood := _make_properties(F.FLAMMABLE)
	wood.buildup_decay_per_second = 10.0
	wood.apply_element(E.FIRE, 0.6)
	await _wait(0.2)
	wood.apply_element(E.FIRE, 0.6)
	(
		assert_bool(!wood.is_on_fire)
		. override_failure_message("heat decays between exposures, no ignition")
		. is_true()
	)


func test_heat_steams_then_ignites_wet_wood() -> void:
	var wood := _make_properties(F.FLAMMABLE)
	wood.apply_element(E.WATER, 1.5)
	var reactions := []
	wood.reaction_triggered.connect(func(r): reactions.append(r))
	wood.apply_element(E.FIRE, 1.0)
	(
		assert_bool(!wood.is_on_fire and wood.is_wet and &"steam" in reactions)
		. override_failure_message("fire on wet object makes steam, no ignition")
		. is_true()
	)
	wood.apply_element(E.FIRE, 1.5)
	(
		assert_bool(!wood.is_wet and wood.is_on_fire)
		. override_failure_message("enough heat dries and ignites")
		. is_true()
	)


func test_permanently_wet_material() -> void:
	var bottle := _make_properties(F.FLAMMABLE | F.WET)
	await _frames()
	bottle.apply_element(E.FIRE, 3.0)
	(
		assert_bool(bottle.is_wet and !bottle.is_on_fire)
		. override_failure_message("permanently wet object can't be ignited by apply_element")
		. is_true()
	)
	bottle.dry_time = 0.1
	await _wait(0.3)
	(
		assert_bool(bottle.is_wet)
		. override_failure_message("permanently wet object doesn't dry")
		. is_true()
	)


func test_wet_wood_conducts_shock() -> void:
	var plank := _make_properties(0)
	plank.apply_element(E.SHOCK, 2.0)
	(
		assert_bool(!plank.is_electric and plank.get_element_level(E.SHOCK) == 0.0)
		. override_failure_message("non-conductor ignores shock")
		. is_true()
	)
	plank.apply_element(E.WATER, 1.0)
	plank.apply_element(E.SHOCK, 1.0)
	assert_bool(plank.is_electric).override_failure_message("wet object conducts").is_true()


func test_applied_charge_expires() -> void:
	var metal := _make_properties(F.CONDUCTIVE)
	metal.buildup_decay_per_second = 4.0
	var lost := [0]
	metal.has_lost_electricity.connect(func(): lost[0] += 1)
	metal.apply_element(E.SHOCK, 1.0)
	assert_bool(metal.is_electric).override_failure_message("conductor gets electric").is_true()
	await _wait(0.6)
	(
		assert_bool(!metal.is_electric and lost[0] == 1)
		. override_failure_message("applied charge runs out")
		. is_true()
	)


func test_sustained_charge() -> void:
	var cathode := _make_properties(F.CONDUCTIVE)
	cathode.make_electric()
	cathode.buildup_decay_per_second = 10.0
	await _wait(0.3)
	(
		assert_bool(cathode.is_electric)
		. override_failure_message("directly electrified (sustained) stays electric")
		. is_true()
	)


func test_fire_immunity_and_weakness() -> void:
	var asbestos := _make_properties(F.FLAMMABLE)
	asbestos.resist_fire = 100
	(
		assert_bool(asbestos.apply_element(E.FIRE, 5.0) == 0.0 and !asbestos.is_on_fire)
		. override_failure_message("100% fire resistance = immune")
		. is_true()
	)
	var weak := _make_properties(F.FLAMMABLE)
	weak.resist_fire = -100
	weak.apply_element(E.FIRE, 0.5)
	(
		assert_bool(weak.is_on_fire)
		. override_failure_message("-100% fire resistance doubles buildup")
		. is_true()
	)


func test_damage_scales_with_resistance_and_wetness() -> void:
	var target := _make_properties(F.CONDUCTIVE)
	target.resist_fire = 50
	var holder: Holder = target.get_parent()
	var dealt := CogitoProperties.deal_elemental_damage(holder, 10.0, E.FIRE)
	(
		assert_bool(is_equal_approx(dealt, 5.0) and is_equal_approx(holder.taken, 5.0))
		. override_failure_message("fire damage halved by 50%% resistance: %s" % holder.taken)
		. is_true()
	)
	target.apply_element(E.WATER, 1.0)
	holder.taken = 0.0
	CogitoProperties.deal_elemental_damage(holder, 10.0, E.SHOCK)
	(
		assert_bool(is_equal_approx(holder.taken, 15.0))
		. override_failure_message("wet target takes 1.5x shock: %s" % holder.taken)
		. is_true()
	)


func test_burn_tick_uses_fire_resistance() -> void:
	var burner := _make_properties(F.FLAMMABLE)
	burner.resist_fire = 75
	burner.burn_damage_amount = 4.0
	burner.apply_burn_damage()
	(
		assert_bool(is_equal_approx((burner.get_parent() as Holder).taken, 1.0))
		. override_failure_message("burn tick respects resistance")
		. is_true()
	)


func test_damage_without_a_receiver() -> void:
	var target: Node3D = auto_free(Node3D.new())
	(
		assert_bool(CogitoProperties.deal_elemental_damage(target, 5.0, E.FIRE) == 0.0)
		. override_failure_message("no damage_received -> 0, no crash")
		. is_true()
	)


func test_idle_properties_stop_processing() -> void:
	var idle := _make_properties(0)
	idle.buildup_decay_per_second = 10.0
	idle.apply_element(E.COLD, 0.5)
	(
		assert_bool(idle.is_processing())
		. override_failure_message("processing while decaying")
		. is_true()
	)
	await _wait(0.2)
	(
		assert_bool(!idle.is_processing() and idle.get_element_level(E.COLD) == 0.0)
		. override_failure_message("processing stops when nothing decays")
		. is_true()
	)

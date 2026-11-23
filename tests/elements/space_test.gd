extends GdUnitTestSuite

const FIXTURES := preload("res://tests/fixtures/element_fixtures.gd")
const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
const E = CogitoProperties.Element
const F = CogitoProperties.ElementalProperties

var _world: Node3D
var _previous_destroyed_nodes: Array
var _previous_destroyed_level_id: int


func before_test() -> void:
	_world = auto_free(Node3D.new())
	add_child(_world)
	_previous_destroyed_nodes = CogitoSceneManager._destroyed_nodes
	_previous_destroyed_level_id = CogitoSceneManager._destroyed_nodes_level_id
	CogitoSceneManager._destroyed_nodes = []


func after_test() -> void:
	await _frames()
	CogitoSceneManager._destroyed_nodes = _previous_destroyed_nodes
	CogitoSceneManager._destroyed_nodes_level_id = _previous_destroyed_level_id


func _make_properties(flags: int, pos: Vector3, settings := {}) -> CogitoProperties:
	var holder := FIXTURES.Holder.new()
	holder.position = pos
	var p: CogitoProperties = PROPS.instantiate()
	p.elemental_properties = flags
	p.is_logging = false
	for key in settings:
		p.set(key, settings[key])
	holder.add_child(p)
	holder.cogito_properties = p
	_world.add_child(holder)
	return p


func _make_area(area: CogitoElementArea, pos: Vector3, size := 2.0) -> CogitoElementArea:
	area.position = pos
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * size
	shape.shape = box
	area.add_child(shape)
	_world.add_child(area)
	return area


func _frames(count := 2) -> void:
	for _frame in count:
		await get_tree().process_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func test_heat_spreads_and_drives_off_wetness(_timeout := 10000) -> void:
	var fire := _make_properties(
		F.FLAMMABLE, Vector3(0, 0, 0), {"heat_radius": 2.0, "heat_per_second": 2.0}
	)
	var near := _make_properties(F.FLAMMABLE, Vector3(1.2, 0, 0))
	var far := _make_properties(F.FLAMMABLE, Vector3(6, 0, 0))
	var wet_near := _make_properties(F.FLAMMABLE, Vector3(-1.2, 0, 0))
	await _frames()
	wet_near.apply_element(E.WATER, 1.0)
	var steams := [0]
	wet_near.reaction_triggered.connect(
		func(r):
			if r == &"steam":
				steams[0] += 1
	)
	fire.set_on_fire()
	(
		assert_bool(fire.get_node_or_null("HeatSensor") != null)
		. override_failure_message("heat sensor created on ignition")
		. is_true()
	)
	var lit := {}
	var elapsed := 0.0
	while elapsed < 3.0:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		for p in [near, wet_near, far]:
			if p.is_on_fire and !lit.has(p):
				lit[p] = elapsed
	(
		assert_bool(lit.has(near))
		. override_failure_message("neighbour in heat radius ignites")
		. is_true()
	)
	(
		assert_bool(!lit.has(far))
		. override_failure_message("object outside heat radius stays cold")
		. is_true()
	)
	assert_bool(steams[0] > 0).override_failure_message("wet neighbour steams").is_true()
	(
		assert_bool(lit.has(wet_near) and lit[wet_near] > lit.get(near, 99.0))
		. override_failure_message("wet neighbour ignites later, after drying: %s" % [lit.values()])
		. is_true()
	)
	fire.extinguish()
	await _frames()
	(
		assert_bool(fire.get_node_or_null("HeatSensor") == null)
		. override_failure_message("heat sensor removed when extinguished")
		. is_true()
	)
	for p in [fire, near, wet_near]:
		p.extinguish()


func test_fire_without_a_heat_radius() -> void:
	var old := _make_properties(F.FLAMMABLE, Vector3(0, 10, 0))
	var old_near := _make_properties(F.FLAMMABLE, Vector3(0.6, 10, 0))
	await _frames()
	old.set_on_fire()
	await _wait(1.0)
	(
		assert_bool(!old_near.is_on_fire and old.get_node_or_null("HeatSensor") == null)
		. override_failure_message("heat_radius 0: no spreading")
		. is_true()
	)
	(
		assert_bool(!old.is_processing())
		. override_failure_message("eternal fire without heat radius doesn't process")
		. is_true()
	)
	old.extinguish()


func test_limited_fuel_and_burnout_results() -> void:
	var burnt := [0]
	var charring := _make_properties(F.FLAMMABLE, Vector3(20, 0, 0), {"fuel": 0.3})
	charring.burned_out.connect(func(): burnt[0] += 1)
	var nothing := _make_properties(
		F.FLAMMABLE,
		Vector3(22, 0, 0),
		{"fuel": 0.3, "burn_out_result": CogitoProperties.BurnOutResult.NOTHING}
	)
	var destroy := _make_properties(
		F.FLAMMABLE,
		Vector3(24, 0, 0),
		{"fuel": 0.3, "burn_out_result": CogitoProperties.BurnOutResult.DESTROY}
	)
	var destroy_holder := destroy.get_parent()
	await _frames()
	for p in [charring, nothing, destroy]:
		p.set_on_fire()
	await _wait(0.15)
	assert_bool(charring.is_on_fire).override_failure_message("burns while fuel lasts").is_true()
	await _wait(0.4)
	(
		assert_bool(!charring.is_on_fire and burnt[0] == 1)
		. override_failure_message("burns out when fuel runs out")
		. is_true()
	)
	(
		assert_bool(!(charring.elemental_properties & F.FLAMMABLE))
		. override_failure_message("CHAR: no longer flammable")
		. is_true()
	)
	charring.apply_element(E.FIRE, 3.0)
	(
		assert_bool(!charring.is_on_fire)
		. override_failure_message("charred object can't be lit again")
		. is_true()
	)
	(
		assert_bool(
			(
				!nothing.is_on_fire
				and (nothing.elemental_properties & F.FLAMMABLE)
				and is_equal_approx(nothing.fuel_remaining, 0.3)
			)
		)
		. override_failure_message("NOTHING: goes out, fuel refilled")
		. is_true()
	)
	(
		assert_bool(!is_instance_valid(destroy_holder) or destroy_holder.is_queued_for_deletion())
		. override_failure_message("DESTROY: parent freed")
		. is_true()
	)


func test_fire_area_switch_dousing_and_relighting(_timeout := 15000) -> void:
	var camp := _make_area(CogitoElementArea.new(), Vector3(40, 0, 0))
	camp.damage_per_second = 4.0
	var wood := _make_properties(F.FLAMMABLE, Vector3(40, 0, 0))
	await _wait(1.0)
	var wood_holder: FIXTURES.Holder = wood.get_parent()
	(
		assert_bool(wood.is_on_fire)
		. override_failure_message("fire area ignites flammable body inside")
		. is_true()
	)
	(
		assert_bool(wood_holder.taken > 3.0)
		. override_failure_message("fire area deals damage: %s" % wood_holder.taken)
		. is_true()
	)
	wood.extinguish()
	var toggles := []
	camp.enabled_changed.connect(func(v): toggles.append(v))
	camp.interact()
	(
		assert_bool(!camp.enabled and toggles == [false])
		. override_failure_message("interact() toggles area off")
		. is_true()
	)
	wood_holder.taken = 0.0
	await _wait(1.5)
	(
		assert_bool(!wood.is_on_fire and wood_holder.taken == 0.0)
		. override_failure_message("disabled area does nothing")
		. is_true()
	)
	camp.interact()
	var reactions := []
	camp.reaction_triggered.connect(func(r): reactions.append(r))
	camp.apply_element(E.WATER, 0.6)
	(
		assert_bool(camp.enabled)
		. override_failure_message("a little water doesn't douse the fire area")
		. is_true()
	)
	camp.apply_element(E.WATER, 0.6)
	(
		assert_bool(!camp.enabled and reactions.has(&"douse"))
		. override_failure_message("water douses the fire area")
		. is_true()
	)
	camp.apply_element(E.FIRE, 1.0)
	(
		assert_bool(camp.enabled and reactions.has(&"ignite"))
		. override_failure_message("fire relights the fire area")
		. is_true()
	)
	wood.extinguish()

	# Rain area over the campfire puts it out
	var rain := _make_area(CogitoElementArea.new(), Vector3(40, 0, 0), 3.0)
	rain.element = E.WATER
	rain.amount_per_second = 4.0
	await _wait(0.8)
	(
		assert_bool(!camp.enabled)
		. override_failure_message("rain area douses overlapping fire area")
		. is_true()
	)
	rain.queue_free()
	await _frames()

	# Burning object with heat radius relights a doused campfire
	var torch := _make_properties(
		F.FLAMMABLE, Vector3(41.5, 0, 0), {"heat_radius": 1.5, "heat_per_second": 4.0}
	)
	wood.elemental_properties = 0
	await _frames()
	torch.set_on_fire()
	await _wait(0.8)
	(
		assert_bool(camp.enabled)
		. override_failure_message("heat radiation relights a doused fire area")
		. is_true()
	)
	torch.extinguish()


func test_submerged_bodies_and_electrified_water(_timeout := 15000) -> void:
	var water: FluidArea3D = _make_area(FluidArea3D.new(), Vector3(60, 0, 0), 3.0)
	(
		assert_bool(water.element == E.WATER and water.conducts_shock)
		. override_failure_message("FluidArea3D is a conducting water area")
		. is_true()
	)
	var burning := _make_properties(F.FLAMMABLE, Vector3(80, 0, 0))
	await _frames()
	burning.set_on_fire()
	burning.get_parent().position = Vector3(60, 0, 0)
	await _wait(0.6)
	(
		assert_bool(!burning.is_on_fire and burning.is_wet)
		. override_failure_message("submerged burning object is doused and wet")
		. is_true()
	)
	var wood := burning
	var victim: FIXTURES.Holder = wood.get_parent()
	victim.taken = 0.0
	var battery := _make_properties(F.CONDUCTIVE, Vector3(90, 0, 0))
	await _frames()
	battery.make_electric()
	battery.get_parent().position = Vector3(60.8, 0, 0)
	await _wait(1.2)
	(
		assert_bool(water.is_electric)
		. override_failure_message("electric object in water electrifies it")
		. is_true()
	)
	(
		assert_bool(wood.is_electric)
		. override_failure_message("wet body in electrified water gets electric")
		. is_true()
	)
	(
		assert_bool(victim.taken > 1.0)
		. override_failure_message("electrified water deals shock damage: %s" % victim.taken)
		. is_true()
	)
	(
		assert_bool((battery.get_parent() as FIXTURES.Holder).taken == 0.0)
		. override_failure_message("the source itself isn't shocked")
		. is_true()
	)
	battery.get_parent().position = Vector3(90, 0, 0)
	await _wait(1.6)
	(
		assert_bool(!water.is_electric)
		. override_failure_message("water loses charge when source leaves (no self-sustain)")
		. is_true()
	)
	var damage_after_discharge := victim.taken
	await _wait(0.5)
	(
		assert_bool(is_equal_approx(victim.taken, damage_after_discharge))
		. override_failure_message("no damage after charge is gone")
		. is_true()
	)
	water.apply_element(E.SHOCK, 1.0)
	assert_bool(water.is_electric).override_failure_message("SHOCK hit electrifies water").is_true()
	await _wait(1.6)
	(
		assert_bool(!water.is_electric)
		. override_failure_message("SHOCK hit charge wears off after hold time")
		. is_true()
	)

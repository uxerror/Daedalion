extends GdUnitTestSuite

const DIR := "res://addons/cogito/DemoScenes/DemoPrefabs/ElementStands/"
const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
const E = CogitoProperties.Element
const F = CogitoProperties.ElementalProperties
const PICKUPS := "res://addons/cogito/PackedScenes/Pickups/"

var _world: Node3D
var _previous_scene: Node
var _previous_time_scale: float
var _previous_physics_rate: int
var _previous_destroyed_nodes: Array
var _previous_destroyed_level_id: int


class Holder:
	extends StaticBody3D
	# Projectiles look up this signal on their collision target.
	@warning_ignore("unused_signal")
	signal damage_received(
		amount: float, source: Node, hit_direction: Vector3, hit_position: Vector3
	)
	var cogito_properties: CogitoProperties

	func _init() -> void:
		collision_layer = 3
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3.ONE
		shape.shape = box
		add_child(shape)


func before() -> void:
	_previous_time_scale = Engine.time_scale
	_previous_physics_rate = Engine.physics_ticks_per_second


func before_test() -> void:
	_previous_scene = get_tree().current_scene
	_world = auto_free(Node3D.new())
	get_tree().root.add_child(_world)
	get_tree().current_scene = _world
	_previous_destroyed_nodes = CogitoSceneManager._destroyed_nodes
	_previous_destroyed_level_id = CogitoSceneManager._destroyed_nodes_level_id
	CogitoSceneManager._destroyed_nodes = []


func after_test() -> void:
	await _frames()
	get_tree().current_scene = _previous_scene
	CogitoSceneManager._destroyed_nodes = _previous_destroyed_nodes
	CogitoSceneManager._destroyed_nodes_level_id = _previous_destroyed_level_id


func after() -> void:
	Engine.time_scale = _previous_time_scale
	Engine.physics_ticks_per_second = _previous_physics_rate


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _frames(count := 2) -> void:
	for _frame in count:
		await get_tree().process_frame


func _wait_until(cond: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await get_tree().process_frame
		t += get_process_delta_time()
	return cond.call()


func _add_floor(pos: Vector3) -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10, 0.2, 10)
	shape.shape = box
	shape.position.y = -0.1
	body.add_child(shape)
	body.position = pos
	_world.add_child(body)


func _load_stand(file: String, pos: Vector3) -> Node3D:
	_add_floor(pos)
	var runner := scene_runner(DIR + file)
	var stand := runner.scene() as Node3D
	stand.position = pos
	return stand


func _properties_of(node: Node) -> CogitoProperties:
	return CogitoProperties.get_properties_of(node)


func _health(node: Node) -> float:
	return (node.get_node("HealthAttribute") as CogitoHealthAttribute).value_current


func _label_text(node: Node) -> String:
	var label: CogitoElementDebugLabel = node.get_node("ElementDebugLabel")
	label.update_text()
	return label.text


func test_fire(_timeout := 95000) -> void:
	var stand := _load_stand("stand_fire.tscn", Vector3(0, 0, 0))
	await _frames(3)
	var campfire: CogitoElementArea = stand.get_node("Campfire")
	(
		assert_bool(!campfire.enabled and !stand.get_node("Campfire/Flames").visible)
		. override_failure_message("fire: campfire starts off, flames hidden")
		. is_true()
	)
	var grass: Array[Node] = []
	var lit := {}
	for i in range(1, 5):
		var g: Node = stand.get_node("Grass%d" % i)
		grass.append(g)
		_properties_of(g).has_ignited.connect(func(): lit[i] = true)
	var crate_a: Node = stand.get_node("CrateA")
	var crate_b: Node = stand.get_node("CrateB")
	stand.get_node("Console/CampfireSwitch").switch()
	(
		assert_bool(campfire.enabled and stand.get_node("Campfire/Flames").visible)
		. override_failure_message("fire: switch turns the campfire on")
		. is_true()
	)
	(
		assert_bool(_label_text(campfire).contains("FIRE ON"))
		. override_failure_message("fire: area debug label shows FIRE ON")
		. is_true()
	)
	(
		assert_bool(await _wait_until(func(): return lit.has(1), 4.0))
		. override_failure_message("fire: campfire ignites the first grass")
		. is_true()
	)
	(
		assert_bool(_label_text(grass[0]).contains("FIRE"))
		. override_failure_message("fire: grass debug label shows FIRE")
		. is_true()
	)
	(
		assert_bool(await _wait_until(func(): return lit.has(4), 15.0))
		. override_failure_message("fire: fire spreads to the last grass")
		. is_true()
	)
	(
		assert_bool(await _wait_until(func(): return stand.get_node_or_null("Grass1") == null, 8.0))
		. override_failure_message("fire: burned grass is destroyed")
		. is_true()
	)
	var crate_props := [_properties_of(crate_a), _properties_of(crate_b)]
	(
		assert_bool(
			await _wait_until(
				func(): return crate_props[0].is_on_fire or crate_props[1].is_on_fire, 10.0
			)
		)
		. override_failure_message("fire: a crate catches fire from the grass")
		. is_true()
	)
	var charred := func():
		for p in crate_props:
			if (
				is_instance_valid(p)
				and !p.is_on_fire
				and p.fuel_remaining <= 0.0
				and !(p.elemental_properties & F.FLAMMABLE)
			):
				return true
		return false
	(
		assert_bool(await _wait_until(charred, 25.0))
		. override_failure_message(
			"fire: a crate burns out and ends CHARRED (not FLAMMABLE, not burning)"
		)
		. is_true()
	)
	var charred_crate: Node = null
	for c in [crate_a, crate_b]:
		if (
			is_instance_valid(c)
			and !_properties_of(c).is_on_fire
			and !(_properties_of(c).elemental_properties & F.FLAMMABLE)
		):
			charred_crate = c
	await _frames(3)
	var vfx: Node = null
	var overlaid := false
	if charred_crate:
		for ch in charred_crate.get_children():
			if ch.scene_file_path.ends_with("vfx_charred.tscn"):
				vfx = ch
		for m in charred_crate.find_children("*", "MeshInstance3D", true, false):
			if (
				m.material_overlay
				== load("res://addons/cogito/Assets/VFX/char_overlay_material.tres")
			):
				overlaid = true
	(
		assert_bool(vfx != null)
		. override_failure_message("fire: charred crate has the vfx_charred child")
		. is_true()
	)
	(
		assert_bool(overlaid)
		. override_failure_message("fire: charred crate meshes have the char overlay material")
		. is_true()
	)
	# Reset
	stand.get_node("Console/CampfireSwitch").switch()
	(
		assert_bool(!campfire.enabled)
		. override_failure_message("fire: switch turns the campfire off")
		. is_true()
	)
	await _wait_until(func(): return stand.get_node_or_null("Grass4") == null, 10.0)
	stand.get_node("Console/ResetButton").press()
	await _frames(3)
	var restored := true
	for i in range(1, 5):
		var g: Node = stand.get_node_or_null("Grass%d" % i)
		if (
			!g
			or !_properties_of(g)
			or _properties_of(g).is_on_fire
			or !(_properties_of(g).elemental_properties & F.FLAMMABLE)
		):
			restored = false
	(
		assert_bool(restored)
		. override_failure_message("fire: reset button restores the destroyed grass")
		. is_true()
	)
	var new_crate: Node = stand.get_node_or_null("CrateA")
	(
		assert_bool(
			(
				new_crate
				and new_crate != crate_a
				and _properties_of(new_crate).elemental_properties & F.FLAMMABLE
				and _properties_of(new_crate).fuel == 10.0
			)
		)
		. override_failure_message("fire: reset restores the crates with their stand settings")
		. is_true()
	)


func test_water_shock(_timeout := 30000) -> void:
	var stand := _load_stand("stand_water_shock.tscn", Vector3(30, 0, 0))
	await _frames(3)
	var puddle: CogitoElementArea = stand.get_node("Puddle")
	var rod: RigidBody3D = stand.get_node("ChargedRod")
	var dummy: Node = stand.get_node("DummyA")
	var brazier: Node = stand.get_node("Brazier")
	(
		assert_bool(_properties_of(rod).is_electric and !puddle.is_electric)
		. override_failure_message("water: rod starts electric, puddle not")
		. is_true()
	)
	(
		assert_bool(_properties_of(brazier).is_on_fire)
		. override_failure_message("water: brazier burns on ready")
		. is_true()
	)
	var hp := _health(dummy)
	await _wait(1.0)
	(
		assert_bool(!puddle.is_electric and _health(dummy) == hp)
		. override_failure_message(
			"water: dummies in the puddle take no damage without electricity"
		)
		. is_true()
	)
	rod.global_position = puddle.global_position + Vector3(0, -0.05, 0.6)
	(
		assert_bool(await _wait_until(func(): return puddle.is_electric, 3.0))
		. override_failure_message("water: electric rod in the puddle electrifies it")
		. is_true()
	)
	(
		assert_bool(await _wait_until(func(): return _health(dummy) < hp, 3.0))
		. override_failure_message("water: dummy in the electrified puddle takes damage")
		. is_true()
	)
	(
		assert_bool(_health(stand.get_node("DummyB")) < 100.0)
		. override_failure_message("water: second dummy takes damage too")
		. is_true()
	)
	(
		assert_bool(_label_text(puddle).contains("ELECTRIC"))
		. override_failure_message("water: puddle debug label shows ELECTRIC")
		. is_true()
	)
	# Rain
	stand.get_node("Console/RainSwitch").switch()
	(
		assert_bool(await _wait_until(func(): return !_properties_of(brazier).is_on_fire, 3.0))
		. override_failure_message("water: rain puts the brazier out")
		. is_true()
	)
	stand.get_node("Console/RainSwitch").switch()
	var dart: RigidBody3D = load(PICKUPS + "pickup_dart_fire.tscn").instantiate()
	_world.add_child(dart)
	dart.global_position = brazier.global_position + Vector3(0, 0.6, 1.2)
	dart.linear_velocity = Vector3(0, 0, -10)
	(
		assert_bool(await _wait_until(func(): return _properties_of(brazier).is_on_fire, 3.0))
		. override_failure_message("water: rain off, a fire dart lights the brazier again")
		. is_true()
	)
	if is_instance_valid(dart):
		dart.queue_free()


func test_cold(_timeout := 30000) -> void:
	var stand := _load_stand("stand_cold.tscn", Vector3(60, 0, 0))
	await _frames(3)
	var wet: Node = stand.get_node("WetCrate")
	var dry: Node = stand.get_node("DryCrate")
	var ball: RigidBody3D = stand.get_node("Ball")
	(
		assert_bool(
			(
				_properties_of(wet).is_wet
				and !_properties_of(dry).is_wet
				and _properties_of(ball).is_wet
			)
		)
		. override_failure_message("cold: wet crate and ball are wet, dry crate is dry")
		. is_true()
	)
	(
		assert_bool(ball.freeze)
		. override_failure_message("cold: ball is held above the freezer")
		. is_true()
	)
	stand.get_node("Console/FreezerSwitch").switch()
	(
		assert_bool(await _wait_until(func(): return _properties_of(wet).is_frozen, 3.0))
		. override_failure_message("cold: wet crate freezes in the freezer")
		. is_true()
	)
	await _frames(3)
	(
		assert_bool((wet.get_node("MeshInstance3D") as MeshInstance3D).material_overlay != null)
		. override_failure_message("cold: frozen crate gets the ice overlay")
		. is_true()
	)
	(
		assert_bool(_label_text(wet).contains("FROZEN"))
		. override_failure_message("cold: debug label shows FROZEN")
		. is_true()
	)
	await _wait(1.5)
	(
		assert_bool(_properties_of(dry).is_chilled and !_properties_of(dry).is_frozen)
		. override_failure_message("cold: dry crate is chilled, not frozen")
		. is_true()
	)
	(
		assert_bool(_label_text(dry).contains("CHILL"))
		. override_failure_message("cold: debug label shows CHILL")
		. is_true()
	)
	stand.get_node("Console/DropButton").press()
	(
		assert_bool(!ball.freeze)
		. override_failure_message("cold: drop button releases the ball")
		. is_true()
	)
	(
		assert_bool(
			await _wait_until(func(): return _properties_of(ball).is_frozen and ball.freeze, 5.0)
		)
		. override_failure_message("cold: released ball falls into the freezer, freezes and stops")
		. is_true()
	)
	stand.get_node("Console/BrazierSwitch").switch()
	(
		assert_bool(stand.get_node("Brazier").enabled)
		. override_failure_message("cold: brazier switch turns the fire on")
		. is_true()
	)
	ball.global_position = stand.get_node("Brazier").global_position
	(
		assert_bool(await _wait_until(func(): return !_properties_of(ball).is_frozen, 5.0))
		. override_failure_message("cold: brazier thaws the frozen ball")
		. is_true()
	)
	await _frames(3)
	(
		assert_bool(!ball.freeze and _properties_of(ball).is_wet)
		. override_failure_message("cold: thawed ball moves again and is wet")
		. is_true()
	)
	(
		assert_bool((ball.get_node("MeshInstance3D") as MeshInstance3D).material_overlay == null)
		. override_failure_message("cold: ice overlay removed after thawing")
		. is_true()
	)
	stand.get_node("Console/ResetButton").press()
	await _frames(3)
	var new_ball: RigidBody3D = stand.get_node("Ball")
	(
		assert_bool(
			new_ball != ball and new_ball.freeze and is_equal_approx(new_ball.position.y, 2.5)
		)
		. override_failure_message("cold: reset hangs a new ball above the freezer")
		. is_true()
	)


func test_poison(_timeout := 25000) -> void:
	var stand := _load_stand("stand_poison.tscn", Vector3(90, 0, 0))
	await _frames(3)
	var susceptible: Node = stand.get_node("Dummy0")
	var resistant: Node = stand.get_node("Dummy50")
	var immune: Node = stand.get_node("Dummy100")
	(
		assert_bool(
			(
				_properties_of(resistant).resist_poison == 50.0
				and _properties_of(immune).resist_poison == 100.0
			)
		)
		. override_failure_message("poison: dummies have their resistances")
		. is_true()
	)
	stand.get_node("Console/GasSwitch").switch()
	(
		assert_bool(
			await _wait_until(
				func():
					return (
						_properties_of(susceptible).is_poisoned
						and _properties_of(resistant).is_poisoned
					),
				10.0
			)
		)
		. override_failure_message("poison: dummies 0% and 50% get poisoned")
		. is_true()
	)
	await _wait(1.5)
	(
		assert_bool(_health(susceptible) < 100.0 and _health(resistant) < 100.0)
		. override_failure_message("poison: poisoned dummies lose health")
		. is_true()
	)
	(
		assert_bool(100.0 - _health(resistant) < 100.0 - _health(susceptible))
		. override_failure_message("poison: 50% dummy loses less health")
		. is_true()
	)
	(
		assert_bool(
			(
				!_properties_of(immune).is_poisoned
				and _health(immune) == 100.0
				and _properties_of(immune).get_element_level(E.POISON) == 0.0
			)
		)
		. override_failure_message("poison: 100% dummy untouched")
		. is_true()
	)
	var text := _label_text(susceptible)
	(
		assert_bool(text.contains("POISON") and text.contains("HP"))
		. override_failure_message("poison: debug label shows POISON and HP")
		. is_true()
	)
	stand.get_node("Console/GasSwitch").switch()
	stand.get_node("Console/AntidoteButton").press()
	(
		assert_bool(
			(
				!_properties_of(susceptible).is_poisoned
				and !_properties_of(resistant).is_poisoned
				and _properties_of(susceptible).get_element_level(E.POISON) == 0.0
			)
		)
		. override_failure_message("poison: antidote cures the dummies")
		. is_true()
	)
	stand.get_node("Console/ResetButton").press()
	await _frames(3)
	(
		assert_bool(
			(
				_health(stand.get_node("Dummy0")) == 100.0
				and stand.get_node("Dummy50") != resistant
				and _properties_of(stand.get_node("Dummy50")).resist_poison == 50.0
			)
		)
		. override_failure_message(
			"poison: reset restores dummies with full health and resistances"
		)
		. is_true()
	)
	var weak: Node = stand.get_node("DummyFireproof")
	(
		assert_bool(
			_properties_of(weak).resist_fire == 100.0 and _properties_of(weak).resist_cold == -50.0
		)
		. override_failure_message("poison: fireproof dummy is weak to cold")
		. is_true()
	)


func _throw_dart(file: String, origin: Vector3) -> CogitoProperties:
	var target := Holder.new()
	target.position = origin + Vector3(0, 0.5, 0)
	var p: CogitoProperties = PROPS.instantiate()
	p.is_logging = false
	target.add_child(p)
	target.cogito_properties = p
	_world.add_child(target)
	await _frames(3)
	var dart: RigidBody3D = load(file).instantiate()
	_world.add_child(dart)
	dart.global_position = origin + Vector3(0, 0.6, 2.0)
	dart.linear_velocity = Vector3(0, 0, -12)
	return p


func test_cold_dart_impact(_timeout := 10000) -> void:
	_add_floor(Vector3(120, 0, 0))
	var cold := await _throw_dart(PICKUPS + "pickup_dart_cold.tscn", Vector3(120, 0, 0))
	var applied := [0]
	cold.element_applied.connect(
		func(element, _amount, _source):
			if element == E.COLD:
				applied[0] += 1
	)
	(
		assert_bool(await _wait_until(func(): return cold.is_chilled, 3.0))
		. override_failure_message("dart: cold dart chills the target")
		. is_true()
	)
	await _wait(1.5)
	(
		assert_bool(applied[0] == 1)
		. override_failure_message("dart: cold applied once (%d)" % applied[0])
		. is_true()
	)


func test_poison_dart_impact(_timeout := 10000) -> void:
	_add_floor(Vector3(124, 0, 0))
	var poison := await _throw_dart(PICKUPS + "pickup_dart_poison.tscn", Vector3(124, 0, 0))
	var applied_p := [0]
	poison.element_applied.connect(
		func(element, _amount, _source):
			if element == E.POISON:
				applied_p[0] += 1
	)
	(
		assert_bool(await _wait_until(func(): return poison.is_poisoned, 3.0))
		. override_failure_message("dart: poison dart poisons the target")
		. is_true()
	)
	await _wait(1.5)
	(
		assert_bool(applied_p[0] == 1)
		. override_failure_message("dart: poison applied once (%d)" % applied_p[0])
		. is_true()
	)


func test_dart_properties_and_inventory() -> void:
	var dart: RigidBody3D = auto_free(load(PICKUPS + "pickup_dart_cold.tscn").instantiate())
	var dart_props: CogitoProperties = dart.get_node("CogitoProperties")
	(
		assert_bool(dart_props.elemental_properties == 0 and !dart_props.ignite_on_ready)
		. override_failure_message("dart: cold dart itself has no flags and doesn't burn")
		. is_true()
	)
	var item: InventoryItemPD = load(
		"res://addons/cogito/InventoryPD/Items/Cogito_Dart_Poison.tres"
	)
	(
		assert_bool(
			item.name == "Poison Dart" and item.drop_scene.ends_with("pickup_dart_poison.tscn")
		)
		. override_failure_message("dart: poison dart inventory item")
		. is_true()
	)

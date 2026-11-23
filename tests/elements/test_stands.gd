extends Node3D
## E5: element demo stands, cold/poison darts, debug label.

const DIR := "res://addons/cogito/DemoScenes/DemoPrefabs/ElementStands/"
const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
const E = CogitoProperties.Element
const F = CogitoProperties.ElementalProperties
var fails := 0

class Holder extends StaticBody3D:
	signal damage_received(amount)
	var cogito_properties : CogitoProperties
	func _init():
		collision_layer = 3
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3.ONE
		shape.shape = box
		add_child(shape)

func check(cond: bool, msg: String):
	if !cond:
		fails += 1
		print("FAIL: ", msg)
	else:
		print("ok: ", msg)

func wait(sec: float):
	await get_tree().create_timer(sec).timeout

func frames(n := 2):
	for i in n: await get_tree().process_frame

## Waits until cond returns true or timeout (game seconds) runs out. Returns the result of cond.
func wait_until(cond: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await get_tree().process_frame
		t += get_process_delta_time()
	return cond.call()

func add_floor(pos: Vector3) -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10, 0.2, 10)
	shape.shape = box
	shape.position.y = -0.1
	body.add_child(shape)
	body.position = pos
	add_child(body)

func load_stand(file: String, pos: Vector3) -> Node3D:
	add_floor(pos)
	var stand : Node3D = load(DIR + file).instantiate()
	stand.position = pos
	add_child(stand)
	return stand

func props(node: Node) -> CogitoProperties:
	return CogitoProperties.get_properties_of(node)

func health(node: Node) -> float:
	return (node.get_node("HealthAttribute") as CogitoHealthAttribute).value_current

func label_text(node: Node) -> String:
	var label : CogitoElementDebugLabel = node.get_node("ElementDebugLabel")
	label.update_text()
	return label.text

func _ready():
	Engine.time_scale = 4.0
	await frames()
	await test_fire()
	await test_water_shock()
	await test_cold()
	await test_poison()
	await test_darts()
	Engine.time_scale = 1.0
	print("RESULT fails=", fails)
	get_tree().quit(fails)


func test_fire():
	var st := load_stand("stand_fire.tscn", Vector3(0, 0, 0))
	await frames(3)
	var campfire : CogitoElementArea = st.get_node("Campfire")
	check(!campfire.enabled and !st.get_node("Campfire/Flames").visible, "fire: campfire starts off, flames hidden")
	var grass : Array = []
	var lit := {}
	for i in range(1, 5):
		var g : Node = st.get_node("Grass%d" % i)
		grass.append(g)
		props(g).has_ignited.connect(func(): lit[i] = true)
	var crate_a : Node = st.get_node("CrateA")
	var crate_b : Node = st.get_node("CrateB")
	st.get_node("Console/CampfireSwitch").switch()
	check(campfire.enabled and st.get_node("Campfire/Flames").visible, "fire: switch turns the campfire on")
	check(label_text(campfire).contains("FIRE ON"), "fire: area debug label shows FIRE ON")
	check(await wait_until(func(): return lit.has(1), 4.0), "fire: campfire ignites the first grass")
	check(label_text(grass[0]).contains("FIRE"), "fire: grass debug label shows FIRE")
	check(await wait_until(func(): return lit.has(4), 15.0), "fire: fire spreads to the last grass")
	check(await wait_until(func(): return st.get_node_or_null("Grass1") == null, 8.0), "fire: burned grass is destroyed")
	var crate_props := [props(crate_a), props(crate_b)]
	check(await wait_until(func(): return crate_props[0].is_on_fire or crate_props[1].is_on_fire, 10.0), "fire: a crate catches fire from the grass")
	var charred := func():
		for p in crate_props:
			if is_instance_valid(p) and !p.is_on_fire and p.fuel_remaining <= 0.0 and !(p.elemental_properties & F.FLAMMABLE):
				return true
		return false
	check(await wait_until(charred, 25.0), "fire: a crate burns out and ends CHARRED (not FLAMMABLE, not burning)")
	var charred_crate : Node = null
	for c in [crate_a, crate_b]:
		if is_instance_valid(c) and !props(c).is_on_fire and !(props(c).elemental_properties & F.FLAMMABLE):
			charred_crate = c
	await frames(3)
	var vfx : Node = null
	var overlaid := false
	if charred_crate:
		for ch in charred_crate.get_children():
			if ch.scene_file_path.ends_with("vfx_charred.tscn"):
				vfx = ch
		for m in charred_crate.find_children("*", "MeshInstance3D", true, false):
			if m.material_overlay == load("res://addons/cogito/Assets/VFX/char_overlay_material.tres"):
				overlaid = true
	check(vfx != null, "fire: charred crate has the vfx_charred child")
	check(overlaid, "fire: charred crate meshes have the char overlay material")
	# Reset
	st.get_node("Console/CampfireSwitch").switch()
	check(!campfire.enabled, "fire: switch turns the campfire off")
	await wait_until(func(): return st.get_node_or_null("Grass4") == null, 10.0)
	st.get_node("Console/ResetButton").press()
	await frames(3)
	var restored := true
	for i in range(1, 5):
		var g : Node = st.get_node_or_null("Grass%d" % i)
		if !g or !props(g) or props(g).is_on_fire or !(props(g).elemental_properties & F.FLAMMABLE):
			restored = false
	check(restored, "fire: reset button restores the destroyed grass")
	var new_crate : Node = st.get_node_or_null("CrateA")
	check(new_crate and new_crate != crate_a and props(new_crate).elemental_properties & F.FLAMMABLE and props(new_crate).fuel == 10.0, "fire: reset restores the crates with their stand settings")
	st.queue_free()
	await frames()


func test_water_shock():
	var st := load_stand("stand_water_shock.tscn", Vector3(30, 0, 0))
	await frames(3)
	var puddle : CogitoElementArea = st.get_node("Puddle")
	var rod : RigidBody3D = st.get_node("ChargedRod")
	var dummy : Node = st.get_node("DummyA")
	var brazier : Node = st.get_node("Brazier")
	check(props(rod).is_electric and !puddle.is_electric, "water: rod starts electric, puddle not")
	check(props(brazier).is_on_fire, "water: brazier burns on ready")
	var hp := health(dummy)
	await wait(1.0)
	check(!puddle.is_electric and health(dummy) == hp, "water: dummies in the puddle take no damage without electricity")
	rod.global_position = puddle.global_position + Vector3(0, -0.05, 0.6)
	check(await wait_until(func(): return puddle.is_electric, 3.0), "water: electric rod in the puddle electrifies it")
	check(await wait_until(func(): return health(dummy) < hp, 3.0), "water: dummy in the electrified puddle takes damage")
	check(health(st.get_node("DummyB")) < 100.0, "water: second dummy takes damage too")
	check(label_text(puddle).contains("ELECTRIC"), "water: puddle debug label shows ELECTRIC")
	# Rain
	st.get_node("Console/RainSwitch").switch()
	check(await wait_until(func(): return !props(brazier).is_on_fire, 3.0), "water: rain puts the brazier out")
	st.get_node("Console/RainSwitch").switch()
	var dart : RigidBody3D = load("res://addons/cogito/PackedScenes/Pickups/pickup_dart_fire.tscn").instantiate()
	add_child(dart)
	dart.global_position = brazier.global_position + Vector3(0, 0.6, 1.2)
	dart.linear_velocity = Vector3(0, 0, -10)
	check(await wait_until(func(): return props(brazier).is_on_fire, 3.0), "water: rain off, a fire dart lights the brazier again")
	if is_instance_valid(dart):
		dart.queue_free()
	st.queue_free()
	await frames()


func test_cold():
	var st := load_stand("stand_cold.tscn", Vector3(60, 0, 0))
	await frames(3)
	var wet : Node = st.get_node("WetCrate")
	var dry : Node = st.get_node("DryCrate")
	var ball : RigidBody3D = st.get_node("Ball")
	check(props(wet).is_wet and !props(dry).is_wet and props(ball).is_wet, "cold: wet crate and ball are wet, dry crate is dry")
	check(ball.freeze, "cold: ball is held above the freezer")
	st.get_node("Console/FreezerSwitch").switch()
	check(await wait_until(func(): return props(wet).is_frozen, 3.0), "cold: wet crate freezes in the freezer")
	await frames(3)
	check((wet.get_node("MeshInstance3D") as MeshInstance3D).material_overlay != null, "cold: frozen crate gets the ice overlay")
	check(label_text(wet).contains("FROZEN"), "cold: debug label shows FROZEN")
	await wait(1.5)
	check(props(dry).is_chilled and !props(dry).is_frozen, "cold: dry crate is chilled, not frozen")
	check(label_text(dry).contains("CHILL"), "cold: debug label shows CHILL")
	st.get_node("Console/DropButton").press()
	check(!ball.freeze, "cold: drop button releases the ball")
	check(await wait_until(func(): return props(ball).is_frozen and ball.freeze, 5.0), "cold: released ball falls into the freezer, freezes and stops")
	st.get_node("Console/BrazierSwitch").switch()
	check(st.get_node("Brazier").enabled, "cold: brazier switch turns the fire on")
	ball.global_position = st.get_node("Brazier").global_position
	check(await wait_until(func(): return !props(ball).is_frozen, 5.0), "cold: brazier thaws the frozen ball")
	await frames(3)
	check(!ball.freeze and props(ball).is_wet, "cold: thawed ball moves again and is wet")
	check((ball.get_node("MeshInstance3D") as MeshInstance3D).material_overlay == null, "cold: ice overlay removed after thawing")
	st.get_node("Console/ResetButton").press()
	await frames(3)
	var new_ball : RigidBody3D = st.get_node("Ball")
	check(new_ball != ball and new_ball.freeze and is_equal_approx(new_ball.position.y, 2.5), "cold: reset hangs a new ball above the freezer")
	st.queue_free()
	await frames()


func test_poison():
	var st := load_stand("stand_poison.tscn", Vector3(90, 0, 0))
	await frames(3)
	var d0 : Node = st.get_node("Dummy0")
	var d50 : Node = st.get_node("Dummy50")
	var d100 : Node = st.get_node("Dummy100")
	check(props(d50).resist_poison == 50.0 and props(d100).resist_poison == 100.0, "poison: dummies have their resistances")
	st.get_node("Console/GasSwitch").switch()
	check(await wait_until(func(): return props(d0).is_poisoned and props(d50).is_poisoned, 10.0), "poison: dummies 0% and 50% get poisoned")
	await wait(1.5)
	check(health(d0) < 100.0 and health(d50) < 100.0, "poison: poisoned dummies lose health")
	check(100.0 - health(d50) < 100.0 - health(d0), "poison: 50% dummy loses less health")
	check(!props(d100).is_poisoned and health(d100) == 100.0 and props(d100).get_element_level(E.POISON) == 0.0, "poison: 100% dummy untouched")
	var text := label_text(d0)
	check(text.contains("POISON") and text.contains("HP"), "poison: debug label shows POISON and HP")
	st.get_node("Console/GasSwitch").switch()
	st.get_node("Console/AntidoteButton").press()
	check(!props(d0).is_poisoned and !props(d50).is_poisoned and props(d0).get_element_level(E.POISON) == 0.0, "poison: antidote cures the dummies")
	st.get_node("Console/ResetButton").press()
	await frames(3)
	check(health(st.get_node("Dummy0")) == 100.0 and st.get_node("Dummy50") != d50 and props(st.get_node("Dummy50")).resist_poison == 50.0, "poison: reset restores dummies with full health and resistances")
	var weak : Node = st.get_node("DummyFireproof")
	check(props(weak).resist_fire == 100.0 and props(weak).resist_cold == -50.0, "poison: fireproof dummy is weak to cold")
	st.queue_free()
	await frames()


func throw_dart(file: String, origin: Vector3) -> CogitoProperties:
	var target := Holder.new()
	target.position = origin + Vector3(0, 0.5, 0)
	var p : CogitoProperties = PROPS.instantiate()
	p.is_logging = false
	target.add_child(p)
	target.cogito_properties = p
	add_child(target)
	await frames(3)
	var dart : RigidBody3D = load(file).instantiate()
	add_child(dart)
	dart.global_position = origin + Vector3(0, 0.6, 2.0)
	dart.linear_velocity = Vector3(0, 0, -12)
	return p


func test_darts():
	add_floor(Vector3(120, 0, 0))
	var cold := await throw_dart("res://addons/cogito/PackedScenes/Pickups/pickup_dart_cold.tscn", Vector3(120, 0, 0))
	var applied := [0]
	cold.element_applied.connect(func(element, _amount, _source): if element == E.COLD: applied[0] += 1)
	check(await wait_until(func(): return cold.is_chilled, 3.0), "dart: cold dart chills the target")
	await wait(1.5)
	check(applied[0] == 1, "dart: cold applied once (%d)" % applied[0])
	var poison := await throw_dart("res://addons/cogito/PackedScenes/Pickups/pickup_dart_poison.tscn", Vector3(124, 0, 0))
	var applied_p := [0]
	poison.element_applied.connect(func(element, _amount, _source): if element == E.POISON: applied_p[0] += 1)
	check(await wait_until(func(): return poison.is_poisoned, 3.0), "dart: poison dart poisons the target")
	await wait(1.5)
	check(applied_p[0] == 1, "dart: poison applied once (%d)" % applied_p[0])
	var dart_props : CogitoProperties = load("res://addons/cogito/PackedScenes/Pickups/pickup_dart_cold.tscn").instantiate().get_node("CogitoProperties")
	check(dart_props.elemental_properties == 0 and !dart_props.ignite_on_ready, "dart: cold dart itself has no flags and doesn't burn")
	dart_props.get_parent().free()
	var item : InventoryItemPD = load("res://addons/cogito/InventoryPD/Items/Cogito_Dart_Poison.tres")
	check(item.name == "Poison Dart" and item.drop_scene.ends_with("pickup_dart_poison.tscn"), "dart: poison dart inventory item")

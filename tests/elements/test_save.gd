extends Node3D
## E4b: saving and loading element states (CogitoProperties, CogitoActorElements, CogitoElementArea,
## scene state, player state, NPC panic).

const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
const PLAYER := preload("res://addons/cogito/PackedScenes/cogito_player_advanced.tscn")
const NPC := preload("res://addons/cogito/CogitoNPC/cogito_npc.tscn")
const HUD := preload("res://addons/cogito/Components/UI/UI_ElementStatus.tscn")
const CRATE := preload("res://addons/cogito/DemoScenes/DemoPrefabs/ElementStands/element_crate.tscn")
const E = CogitoProperties.Element
const F = CogitoProperties.ElementalProperties
const S = CogitoElementStatusHud.Status
const SLOT := "e4b_test"
const SCENE_NAME := "E4bTestLevel"
var fails := 0
var dummy_vfx : PackedScene

class Holder extends StaticBody3D:
	signal damage_received(amount)
	var cogito_properties : CogitoProperties
	var taken := 0.0
	func _init():
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3.ONE * 0.5
		shape.shape = box
		add_child(shape)
		damage_received.connect(func(a, _s = null, _d = Vector3.ZERO, _p = Vector3.ZERO): taken += a)

class RigidHolder extends RigidBody3D:
	signal damage_received(amount)
	var cogito_properties : CogitoProperties
	var taken := 0.0
	func _init():
		gravity_scale = 0.0
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3.ONE * 0.5
		shape.shape = box
		add_child(shape)
		damage_received.connect(func(a, _s = null, _d = Vector3.ZERO, _p = Vector3.ZERO): taken += a)

# Counts signals of a CogitoProperties that a restore must not emit.
class Watch:
	var reactions : Array = []
	var state_signals := 0
	var damage := 0.0
	var restored := 0
	func _init(p: CogitoProperties):
		p.reaction_triggered.connect(func(r): reactions.append(r))
		p.elemental_damage_taken.connect(func(a, _e, _s): damage += a)
		p.element_state_restored.connect(func(): restored += 1)
		for sig in [p.has_ignited, p.has_been_extinguished, p.has_become_wet, p.has_become_dry, p.has_become_electric,
				p.has_lost_electricity, p.has_become_chilled, p.has_warmed_up, p.has_frozen, p.has_thawed,
				p.has_been_poisoned, p.has_been_cured, p.burned_out]:
			sig.connect(func(): state_signals += 1)
	func quiet() -> bool:
		return reactions.is_empty() and state_signals == 0 and damage == 0.0

var next_x := 0.0

func make(flags: int, setup := Callable(), with_actor := false, rigid := false) -> CogitoProperties:
	var h : Node3D = RigidHolder.new() if rigid else Holder.new()
	next_x += 10.0
	h.position = Vector3(next_x, 50, 0)
	var p : CogitoProperties = PROPS.instantiate()
	p.elemental_properties = flags
	p.is_logging = false
	p.spawn_on_chilled = dummy_vfx
	p.spawn_on_frozen = dummy_vfx
	p.spawn_on_poisoned = dummy_vfx
	p.spawn_on_charred = dummy_vfx
	if setup.is_valid():
		setup.call(p)
	h.add_child(p)
	h.cogito_properties = p
	if with_actor:
		var a := CogitoActorElements.new()
		a.name = "CogitoActorElements"
		h.add_child(a)
	add_child(h)
	return p

func actor_of(p: CogitoProperties) -> CogitoActorElements:
	return p.get_parent().get_node("CogitoActorElements")

func taken(p: CogitoProperties) -> float:
	return p.get_parent().taken

# Serialises like a save file would, both as Variant text and through JSON.
func roundtrip(data: Dictionary, json := false) -> Dictionary:
	if json:
		return JSON.parse_string(JSON.stringify(data))
	return str_to_var(var_to_str(data))

func vfx_count(p: CogitoProperties, kind: StringName) -> int:
	var n := 0
	for child in p.get_parent().get_children():
		if child.get_meta(CogitoProperties.VFX_KIND_META, &"x") == kind and !child.is_queued_for_deletion():
			n += 1
	return n

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

func physics_frames(n := 2):
	for i in n: await get_tree().physics_frame

func near(a: float, b: float, tolerance := 0.1) -> bool:
	return absf(a - b) <= tolerance


func _ready():
	dummy_vfx = PackedScene.new()
	dummy_vfx.pack(Node3D.new())
	await frames()
	await test_fire()
	await test_wet_electric()
	await test_cold()
	await test_poison_levels()
	await test_vfx_and_quiet()
	await test_actor_elements()
	await test_area()
	await test_scene_state()
	await test_old_save()
	await test_player()
	_cleanup_saves()
	print("RESULT fails=", fails)
	get_tree().quit(fails)


func test_fire() -> void:
	# Sustained fire
	var p := make(F.FLAMMABLE, func(p): p.heat_radius = 1.0)
	await frames()
	p.set_on_fire()
	var data := roundtrip(p.get_element_save_data())
	check(data.get("v") == 1 and data.get("on_fire") == true, "save data has version 1 and the fire")
	var q := make(F.FLAMMABLE, func(p): p.heat_radius = 1.0)
	await frames()
	var w := Watch.new(q)
	q.apply_element_save_data(data)
	check(q.is_on_fire and q.get_element_level(E.FIRE) == q.buildup_max and q._timed_states.is_empty(), "sustained fire restored")
	check(q.get_node_or_null("HeatSensor") != null and q.is_processing(), "restored fire radiates heat again (heat sensor, processing)")
	check(w.quiet() and w.restored == 1, "fire restore emits only element_state_restored")
	await frames()
	check(vfx_count(q, CogitoProperties.VFX_FIRE) == 1, "fire VFX present after restore")
	p.extinguish(false)
	q.extinguish(false)

	# Fire from buildup with fuel, burns out at the remaining time after load
	p = make(F.FLAMMABLE, func(p): p.fuel = 2.0)
	await frames()
	p.apply_element(E.FIRE, 1.0)
	await wait(0.8)
	data = roundtrip(p.get_element_save_data(), true)
	p.extinguish(false)
	q = make(F.FLAMMABLE, func(p): p.fuel = 2.0)
	await frames()
	w = Watch.new(q)
	q.apply_element_save_data(data)
	check(q.is_on_fire and near(q.fuel_remaining, 1.2, 0.1), "fuel_remaining continues after JSON round trip: %.2f" % q.fuel_remaining)
	await wait(0.8)
	check(q.is_on_fire, "still burning before the remaining fuel is used")
	await wait(0.7)
	check(!q.is_on_fire and q.is_charred and !(q.elemental_properties & F.FLAMMABLE), "burns out at the remaining time (CHAR)")
	check(w.reactions.is_empty(), "no reactions from the restore or the burn out")

	# Charred object stays charred
	data = roundtrip(q.get_element_save_data())
	var r := make(F.FLAMMABLE, func(p): p.fuel = 2.0)
	await frames()
	r.apply_element_save_data(data)
	await frames()
	check(r.is_charred and !(r.elemental_properties & F.FLAMMABLE) and vfx_count(r, CogitoProperties.VFX_CHARRED) == 1, "charred restored: not flammable, charred VFX")
	r.apply_element(E.FIRE, 3.0)
	check(!r.is_on_fire, "restored charred object can't be lit")


func test_wet_electric() -> void:
	# Timed wetness dries after the remaining time
	var p := make(0, func(p): p.dry_time = 4.0)
	await frames()
	p.apply_element(E.WATER, 1.0)
	await wait(2.0)
	var data := roundtrip(p.get_element_save_data())
	p.make_dry()
	var q := make(0, func(p): p.dry_time = 4.0)
	await frames()
	q.apply_element_save_data(data)
	check(q.is_wet and q._timed_states.has(E.WATER) and near(q.get_element_level(E.WATER), 0.5), "timed wetness restored with its level: %.2f" % q.get_element_level(E.WATER))
	check(q.elemental_properties & F.WET, "WET flag restored")
	await wait(1.2)
	check(q.is_wet, "still wet before the remaining dry time")
	await wait(1.3)
	check(!q.is_wet, "dries after the remaining time, not the full dry_time")

	# Sustained wetness
	p = make(F.WET)
	await frames(3)
	data = roundtrip(p.get_element_save_data())
	q = make(0)
	await frames()
	q.apply_element_save_data(data)
	check(q.is_wet and !q._timed_states.has(E.WATER) and (q.elemental_properties & F.WET), "sustained wetness restored")
	await wait(0.5)
	check(q.is_wet, "sustained wetness doesn't dry")

	# Timed electricity
	p = make(F.CONDUCTIVE)
	await frames()
	p.apply_element(E.SHOCK, 1.0)
	await wait(1.0)
	data = roundtrip(p.get_element_save_data())
	p.loose_electricity()
	q = make(F.CONDUCTIVE)
	await frames()
	q.apply_element_save_data(data)
	check(q.is_electric and q._timed_states.has(E.SHOCK) and near(q.get_element_level(E.SHOCK), 0.5), "timed electricity restored: %.2f" % q.get_element_level(E.SHOCK))
	await wait(1.3)
	check(!q.is_electric, "electricity runs out after the remaining time")


func test_cold() -> void:
	# Chill
	var p := make(0, func(p): p.chill_time = 4.0)
	await frames()
	p.apply_element(E.COLD, 1.0)
	await wait(1.0)
	var data := roundtrip(p.get_element_save_data())
	p._warm_up()
	var q := make(0, func(p): p.chill_time = 4.0)
	await frames()
	q.apply_element_save_data(data)
	await frames()
	check(q.is_chilled and near(q.get_element_level(E.COLD), 0.75) and vfx_count(q, CogitoProperties.VFX_CHILLED) == 1, "chill restored with level and VFX: %.2f" % q.get_element_level(E.COLD))
	await wait(3.3)
	check(!q.is_chilled and vfx_count(q, CogitoProperties.VFX_CHILLED) == 0, "chill wears off after the remaining time")

	# Timed freeze on a rigid body
	p = make(0, func(p): p.freeze_time = 3.0; p.dry_time = 0.0, false, true)
	await frames()
	var p_body := p.get_parent() as RigidBody3D
	p.apply_element(E.WATER, 1.0)
	p.apply_element(E.COLD, 1.0)
	check(p.is_frozen and p_body.freeze, "setup: timed freeze")
	await wait(1.0)
	data = roundtrip(p.get_element_save_data())
	p.thaw()
	q = make(0, func(p): p.freeze_time = 3.0; p.dry_time = 0.0, false, true)
	await frames()
	var body := q.get_parent() as RigidBody3D
	q.apply_element_save_data(data)
	await frames()
	check(q.is_frozen and body.freeze and q._timed_states.has(E.COLD) and near(q.get_element_level(E.COLD), 0.67), "timed freeze restored, body frozen: %.2f" % q.get_element_level(E.COLD))
	check(vfx_count(q, CogitoProperties.VFX_FROZEN) == 1 and !q.is_wet, "frozen VFX, not wet while frozen")
	await wait(2.4)
	check(!q.is_frozen and !body.freeze, "thaws after the remaining time, body back to its original freeze (false)")
	check(q.is_wet and q._timed_states.has(E.WATER), "thawed: timed wetness as before the freeze")

	# Freeze from sustained wetness, body that was held (freeze = true) before
	p = make(F.WET, Callable(), false, true)
	(p.get_parent() as RigidBody3D).freeze = true
	await frames(3)
	p.freeze()
	data = roundtrip(p.get_element_save_data())
	q = make(0, Callable(), false, true)
	await frames()
	body = q.get_parent() as RigidBody3D
	check(!body.freeze, "setup: fresh body not frozen")
	q.apply_element_save_data(data)
	check(q.is_frozen and body.freeze and !q._timed_states.has(E.COLD), "freeze() freeze restored, sustained")
	q.apply_element_save_data(data)
	check(q.is_frozen and body.freeze and q._rigid_freeze_before, "applying twice keeps the original freeze value")
	q.thaw()
	check(body.freeze, "thaw restores the original freeze value (true) from the save")
	check(q.is_wet and !q._timed_states.has(E.WATER) and (q.elemental_properties & F.WET), "thaw restores sustained wetness")
	body.freeze = false


func test_poison_levels() -> void:
	var p := make(0, func(p): p.poison_time = 10.0; p.poison_damage_per_second = 2.0)
	await frames()
	p.apply_element(E.POISON, 1.0)
	await wait(0.5)
	var data := roundtrip(p.get_element_save_data())
	p.cure_poison()
	var q := make(0, func(p): p.poison_time = 10.0; p.poison_damage_per_second = 2.0)
	await frames()
	q.apply_element_save_data(data)
	await frames()
	check(q.is_poisoned and taken(q) == 0.0 and vfx_count(q, CogitoProperties.VFX_POISONED) == 1, "poison restored, no damage from the restore, VFX")
	await wait(0.6)
	check(near(taken(q), 2.0, 0.01), "poison tick continues from the saved tick time: %.2f" % taken(q))

	# Buildup below the thresholds
	p = make(F.FLAMMABLE)
	await frames()
	p.apply_element(E.FIRE, 0.5)
	p.apply_element(E.POISON, 0.3)
	data = roundtrip(p.get_element_save_data())
	q = make(F.FLAMMABLE)
	await frames()
	q.apply_element_save_data(data)
	check(near(q.get_element_level(E.FIRE), 0.5, 0.02) and near(q.get_element_level(E.POISON), 0.3, 0.02) and !q.is_on_fire and !q.is_poisoned, "element buildup restored without states")
	check(q.is_processing(), "buildup decays again (processing)")


func test_vfx_and_quiet() -> void:
	var p := make(F.CONDUCTIVE, func(p): p.poison_damage_per_second = 5.0)
	await frames()
	p.apply_element(E.WATER, 1.0)
	p.apply_element(E.SHOCK, 1.0)
	p.apply_element(E.POISON, 1.0)
	var data := roundtrip(p.get_element_save_data())
	var neutral := make(F.FLAMMABLE)
	await frames()
	var neutral_data := roundtrip(neutral.get_element_save_data())
	p.cure_poison()

	# Restoring onto a burning object: wet data doesn't douse, steam or extinguish
	var q := make(F.CONDUCTIVE | F.FLAMMABLE, func(p): p.poison_damage_per_second = 5.0)
	await frames()
	q.set_on_fire()
	await frames()
	var w := Watch.new(q)
	q.apply_element_save_data(data)
	q.apply_element_save_data(data)
	await frames()
	check(!q.is_on_fire and q.is_wet and q.is_electric and q.is_poisoned, "states replaced by the save")
	check(w.quiet() and w.restored == 2 and taken(q) == 0.0, "restore: no reactions, no state signals, no damage (reactions %s)" % [w.reactions])
	check(vfx_count(q, CogitoProperties.VFX_WET) == 1 and vfx_count(q, CogitoProperties.VFX_ELECTRIC) == 1 and vfx_count(q, CogitoProperties.VFX_POISONED) == 1, "one VFX per active state after applying twice")
	check(vfx_count(q, CogitoProperties.VFX_FIRE) == 0 and vfx_count(q, CogitoProperties.VFX_CHILLED) == 0, "no VFX for inactive states")
	q.apply_element_save_data(neutral_data)
	await frames()
	check(!q.is_wet and !q.is_electric and !q.is_poisoned and q.element_levels.is_empty(), "neutral save clears all states")
	check(vfx_count(q, CogitoProperties.VFX_WET) + vfx_count(q, CogitoProperties.VFX_ELECTRIC) + vfx_count(q, CogitoProperties.VFX_POISONED) == 0, "neutral save removes the VFX")
	check(w.quiet() and !q.is_processing(), "neutral restore quiet, nothing processing")


func test_actor_elements() -> void:
	# Stun
	var p := make(F.CONDUCTIVE, Callable(), true)
	await frames()
	var a := actor_of(p)
	a.stun(2.0)
	await wait(0.5)
	var data := roundtrip(p.get_element_save_data())
	var actor_data := roundtrip(a.get_element_save_data())
	var q := make(F.CONDUCTIVE, Callable(), true)
	await frames()
	var b := actor_of(q)
	var stuns := [0]
	b.stunned.connect(func(): stuns[0] += 1)
	q.apply_element_save_data(data)
	b.apply_element_save_data(actor_data)
	check(b.is_stunned and near(b.stun_time_left, 1.5) and b.speed_multiplier == 0.0 and !b.can_act(), "stun restored with remaining time: %.2f" % b.stun_time_left)
	check(stuns[0] == 0, "restored stun doesn't emit stunned")
	await wait(1.7)
	check(!b.is_stunned and b.stun_cooldown_left > 1.0 and b.speed_multiplier == 1.0, "stun ends after the remaining time, cooldown starts")

	# Refreeze immunity
	p = make(0, Callable(), true)
	await frames()
	a = actor_of(p)
	p.apply_element(E.WATER, 1.0)
	p.apply_element(E.COLD, 1.0)
	while p.is_frozen:
		a.struggle()
	await wait(1.0)
	data = roundtrip(p.get_element_save_data())
	actor_data = roundtrip(a.get_element_save_data())
	q = make(0, Callable(), true)
	await frames()
	b = actor_of(q)
	q.apply_element_save_data(data)
	b.apply_element_save_data(actor_data)
	check(q.freeze_immune and near(b._immunity_left, 2.0) and q.is_wet, "refreeze immunity restored: %.2f" % b._immunity_left)
	q.apply_element(E.COLD, 1.0)
	check(q.is_chilled and !q.is_frozen, "immune actor gets chilled, not frozen")
	await wait(2.3)
	check(!q.freeze_immune, "immunity ends after the remaining time")

	# Frozen actor: speed 0 right after the restore
	p = make(0, Callable(), true)
	await frames()
	p.apply_element(E.WATER, 1.0)
	p.apply_element(E.COLD, 1.0)
	data = roundtrip(p.get_element_save_data())
	q = make(0, Callable(), true)
	await frames()
	q.apply_element_save_data(data)
	check(actor_of(q).speed_multiplier == 0.0 and !actor_of(q).can_jump(), "restored frozen actor can't move")


func make_area(fire := true) -> CogitoElementArea:
	var area := CogitoElementArea.new()
	area.element = E.FIRE if fire else E.WATER
	area.collision_mask = 0
	next_x += 10.0
	area.position = Vector3(next_x, -50, 0)
	var visual := Node3D.new()
	area.add_child(visual)
	area.visuals = [visual]
	add_child(area)
	return area


func test_area() -> void:
	var a := make_area()
	await frames()
	var reactions := []
	a.reaction_triggered.connect(func(r): reactions.append(r))
	a.apply_element(E.WATER, 1.0)
	check(!a.enabled and reactions == [&"douse"], "setup: campfire doused")
	a.apply_element(E.FIRE, 0.4)
	var data := roundtrip(a.get_element_save_data())
	var b := make_area()
	await frames()
	var b_reactions := []
	b.reaction_triggered.connect(func(r): b_reactions.append(r))
	b.apply_element_save_data(data)
	check(!b.enabled and !b.visuals[0].visible and near(b._levels.get(E.FIRE, 0.0), 0.4, 0.05), "doused campfire stays doused, relight buildup kept")
	check(b_reactions.is_empty(), "area restore emits no reaction")
	await wait(0.6)
	check(!b.enabled, "restored doused campfire doesn't relight by itself")

	# Disabled -> enabled
	var c := make_area()
	c.enabled = false
	await frames()
	b.enabled = true
	data = roundtrip(b.get_element_save_data())
	c.apply_element_save_data(data)
	check(c.enabled and c.visuals[0].visible, "enabled state restored on an area that is off by default")
	b.interact()
	data = roundtrip(b.get_element_save_data(), true)
	c.apply_element_save_data(data)
	check(!c.enabled, "switched off area stays off (JSON round trip)")

	# Electrified water
	var water := make_area(false)
	water.conducts_shock = true
	await frames()
	water.apply_element(E.SHOCK, 1.0)
	data = roundtrip(water.get_element_save_data())
	var water2 := make_area(false)
	water2.conducts_shock = true
	await frames()
	water2.apply_element_save_data(data)
	check(water2.is_electric and near(water2._shock_time_left, water.shock_hold_time, 0.3), "electrified water restored")


#region Scene state

var level : Node3D

func add_to_level(node: Node, parent: Node = null) -> Node:
	(parent if parent else level).add_child(node)
	node.owner = level
	return node

func props_body(body_name: String, flags: int, pos: Vector3, setup := Callable()) -> CogitoProperties:
	var body := Holder.new()
	body.name = body_name
	body.position = pos
	add_to_level(body)
	var p : CogitoProperties = PROPS.instantiate()
	p.elemental_properties = flags
	p.is_logging = false
	if setup.is_valid():
		setup.call(p)
	body.cogito_properties = p
	add_to_level(p, body)
	return p

# Builds the same small level each time, like loading the level's scene file.
func build_level() -> void:
	level = Node3D.new()
	level.name = "Level"
	add_child(level)
	CogitoSceneManager._current_scene_root_node = level
	var crate : Node3D = CRATE.instantiate()
	crate.name = "Crate"
	crate.position = Vector3(0, 200, 0)
	add_to_level(crate)
	var crate2 : Node3D = CRATE.instantiate()
	crate2.name = "Crate2"
	crate2.position = Vector3(10, 200, 0)
	add_to_level(crate2)
	crate2.get_node("CogitoProperties").make_flammable()
	crate2.get_node("CogitoProperties").fuel = 0.3
	crate2.get_node("CogitoProperties").fuel_remaining = 0.3
	crate2.get_node("CogitoProperties").burn_out_result = CogitoProperties.BurnOutResult.DESTROY
	props_body("Stump", F.FLAMMABLE, Vector3(20, 200, 0))
	props_body("Bush", F.FLAMMABLE, Vector3(30, 200, 0), func(p): p.fuel = 0.3; p.burn_out_result = CogitoProperties.BurnOutResult.DESTROY)
	props_body("Torch", F.FLAMMABLE, Vector3(40, 200, 0), func(p): p.ignite_on_ready = true)
	var area := CogitoElementArea.new()
	area.name = "Campfire"
	area.collision_mask = 0
	area.position = Vector3(50, 200, 0)
	add_to_level(area)
	for npc_name in ["NPC", "NPC2"]:
		var npc : CogitoNPC = NPC.instantiate()
		npc.name = npc_name
		npc.position = Vector3(60 if npc_name == "NPC" else 70, 0.1, 100)
		add_to_level(npc)
	CogitoPersistentId.stamp_level(level)

func lp(path: String) -> CogitoProperties:
	return level.get_node(path + "/CogitoProperties") as CogitoProperties

func free_level() -> void:
	level.free()
	level = null


func test_scene_state() -> void:
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(400, 1, 400)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0, -0.5, 100)
	add_child(floor_body)
	build_level()
	await physics_frames(10)
	var npc : CogitoNPC = level.get_node("NPC")
	var npc2 : CogitoNPC = level.get_node("NPC2")
	check(lp("Torch").is_on_fire and level.get_node("Campfire").enabled, "setup: torch lit on ready, campfire burning")
	lp("Crate").apply_element(E.WATER, 1.0)
	lp("Stump").set_on_fire()
	level.get_node("Campfire").apply_element(E.WATER, 1.0)
	lp("Torch").extinguish(false)
	lp("Bush").set_on_fire()
	lp("Crate2").set_on_fire()
	npc.cogito_properties.set_on_fire()
	npc2.state_chart.send_event("panic")
	# A Persist object created during play (no level id, created again from its scene file on load).
	var spawned : Node3D = CRATE.instantiate()
	spawned.name = "Spawned"
	spawned.position = Vector3(80, 200, 0)
	level.add_child(spawned)
	spawned.get_node("CogitoProperties").apply_element(E.POISON, 1.0)
	var spawned_id := CogitoPersistentId.of(spawned)
	await physics_frames(3)
	check(npc.is_panicking() and npc2.is_panicking() and !npc2.cogito_properties.is_on_fire, "setup: burning NPC and NPC panicking without fire")
	await wait(0.6)
	check(level.get_node_or_null("Bush") == null and level.get_node_or_null("Crate2") == null, "setup: bush and Persist crate burned to nothing")
	var crate_level := lp("Crate").get_element_level(E.WATER)

	CogitoSceneManager.save_scene_state(SCENE_NAME, SLOT)
	var state : CogitoSceneState = CogitoSceneManager._scene_state
	check(state.saved_destroyed_nodes == [{"cogito_id": "Bush", "path": "."}], "destroyed non-Persist bush recorded: %s" % [state.saved_destroyed_nodes])
	var keys := state.saved_element_states.map(func(e): return e["cogito_id"] + "|" + e["path"])
	check(keys.has("level:Crate|CogitoProperties") and keys.has("Stump/CogitoProperties|.") and keys.has("Campfire|.") and keys.has("level:NPC|CogitoActorElements"), "element states keyed by Persist owner or level path: %s" % [keys])

	# "Load the level again": fresh level from scratch, then the scene state.
	free_level()
	build_level()
	check(level.get_node_or_null("Bush") != null and level.get_node_or_null("Crate2") != null and level.get_node("Campfire").enabled, "fresh level has its defaults")
	# Same frame as building the level, like the loading screen: the on-ready states (torch) are still pending.
	CogitoSceneManager.load_scene_state(SCENE_NAME, SLOT)
	await frames(2)
	await physics_frames(2)
	npc = level.get_node("NPC")
	npc2 = level.get_node("NPC2")
	check(lp("Crate").is_wet and lp("Crate")._timed_states.has(E.WATER) and near(lp("Crate").get_element_level(E.WATER), crate_level, 0.1), "Persist crate: timed wetness restored")
	check(vfx_count(lp("Crate"), CogitoProperties.VFX_WET) == 1, "Persist crate: one wet VFX")
	check(lp("Stump").is_on_fire, "non-Persist stump: fire restored")
	var spawned2 := CogitoPersistentId.find(get_tree(), spawned_id)
	check(spawned_id.begins_with("persist:") and spawned2 != null and spawned2.get_node("CogitoProperties").is_poisoned, "Persist object spawned during play: created again, poison restored")
	check(!lp("Torch").is_on_fire and vfx_count(lp("Torch"), CogitoProperties.VFX_FIRE) == 0, "ignite_on_ready torch put out before the save stays out")
	check(!level.get_node("Campfire").enabled, "doused campfire stays doused")
	check(level.get_node_or_null("Bush") == null or level.get_node("Bush").is_queued_for_deletion(), "destroyed non-Persist bush stays gone")
	check(level.get_node_or_null("Crate2") == null or level.get_node("Crate2").is_queued_for_deletion(), "destroyed Persist crate stays gone")
	check(CogitoSceneManager._get_destroyed_nodes().size() == 1, "destroyed list carried over to the next save")
	check(npc.cogito_properties.is_on_fire and npc.is_panicking(), "burning NPC loads burning and panicking")
	check(!npc2.is_panicking(), "NPC saved panicking without fire calms down")
	await wait(0.5)
	check(npc.is_panicking() and !npc2.is_panicking(), "panic states stay that way")
	npc.cogito_properties.extinguish(false)
	await physics_frames(2)
	check(!npc.is_panicking(), "restored burning NPC calms down when extinguished")
	free_level()


func test_old_save() -> void:
	# A scene state as saved before element states existed: no saved_element_states / saved_destroyed_nodes.
	var state := CogitoSceneState.new()
	ResourceSaver.save(state, "user://e4b_old_state.tres")
	var text := FileAccess.get_file_as_string("user://e4b_old_state.tres")
	var lines := Array(text.split("\n")).filter(func(l): return !l.begins_with("saved_element_states") and !l.begins_with("saved_destroyed_nodes"))
	var file := FileAccess.open("user://e4b_old_state.tres", FileAccess.WRITE)
	file.store_string("\n".join(lines))
	file.close()
	var old : CogitoSceneState = ResourceLoader.load("user://e4b_old_state.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	check(old != null and old.saved_element_states.is_empty() and old.saved_destroyed_nodes.is_empty(), "old scene state loads with empty element fields")
	DirAccess.remove_absolute("user://e4b_old_state.tres")
	build_level()
	await frames(2)
	# Write it as the slot's scene state and load it.
	old.write_state(SLOT, SCENE_NAME)
	CogitoSceneManager.load_scene_state(SCENE_NAME, SLOT)
	await frames(2)
	check(lp("Torch").is_on_fire and level.get_node("Campfire").enabled and level.get_node_or_null("Bush") != null, "old save leaves elements at the scene defaults")
	var player_state := CogitPlayerAdvancedState.new()
	check(player_state.element_state.is_empty(), "old player state has no element data")
	free_level()

#endregion


func test_player() -> void:
	var player : CogitoPlayerAdvanced = PLAYER.instantiate()
	player.position = Vector3(-100, 1, 0)
	add_child(player)
	var hud : CogitoElementStatusHud = HUD.instantiate()
	add_child(hud)
	await physics_frames(10)
	hud.bind_player(player)
	var props := player.cogito_properties
	props.poison_damage_per_second = 0.0
	props.apply_element(E.WATER, 1.0)
	props.apply_element(E.POISON, 2.0)
	player.actor_elements.stun(3.0)
	var state = player.create_new_state()
	state._save_element_state(player)
	check(state.element_state.has("properties") and state.element_state.has("actor"), "player state holds properties and actor data")
	var saved : Dictionary = str_to_var(var_to_str(state.element_state))
	props.cure_poison()
	props.make_dry()
	player.actor_elements.stun_time_left = 0.01
	await wait(0.6) # Stun and its flash end.
	check(!hud.is_status_visible(S.POISON) and !hud.is_status_visible(S.WET) and !player.actor_elements.is_stunned, "setup: player clean, HUD empty")
	var w := Watch.new(props)
	state.element_state = saved
	state._load_element_state(player)
	await frames(1)
	check(props.is_poisoned and props.is_wet and props._timed_states.has(E.POISON), "player element states restored from the player state")
	check(player.actor_elements.is_stunned and player.actor_elements.stun_time_left > 2.0, "player stun restored")
	check(w.quiet(), "player restore quiet")
	check(hud.is_status_active(S.POISON) and hud.is_status_active(S.WET), "HUD shows the restored states")
	check(hud.get_overlay_status() == S.POISON and hud.is_overlay_visible(), "HUD overlay for the restored poison (%s, %s)" % [hud.get_overlay_status(), hud.is_overlay_visible()])
	# Saves without element data leave the player alone.
	state.element_state = {}
	state._load_element_state(player)
	await frames(1)
	check(props.is_poisoned, "empty element_state doesn't touch the player")
	player.queue_free()
	hud.queue_free()


func _cleanup_saves() -> void:
	var dir := CogitoSceneManager.cogito_state_dir + SLOT
	for file_name in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + file_name)
	DirAccess.remove_absolute(dir)

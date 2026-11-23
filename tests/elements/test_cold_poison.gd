extends Node3D
## E3: COLD (chill, freeze, thaw, quench) and POISON.

const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
const E = CogitoProperties.Element
const F = CogitoProperties.ElementalProperties
var fails := 0

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
	var cogito_properties : CogitoProperties

func fast(p: CogitoProperties) -> void:
	p.chill_time = 0.3
	p.freeze_time = 0.3
	p.poison_time = 0.3
	p.state_damage_interval = 0.1
	p.dry_time = 20.0

func make(flags: int, pos := Vector3.ZERO, setup := Callable(), holder: Node3D = null) -> CogitoProperties:
	var h : Node3D = holder if holder else Holder.new()
	h.position = pos
	var p : CogitoProperties = PROPS.instantiate()
	p.elemental_properties = flags
	p.is_logging = false
	fast(p)
	if setup.is_valid():
		setup.call(p)
	h.add_child(p)
	h.cogito_properties = p
	add_child(h)
	return p

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

## Counts emissions of the given signals by name.
func watch(p: CogitoProperties) -> Dictionary:
	var c := {}
	for s in [&"has_become_chilled", &"has_warmed_up", &"has_frozen", &"has_thawed", &"has_been_poisoned", &"has_been_cured", &"has_become_dry", &"has_become_wet", &"has_been_extinguished"]:
		c[s] = 0
		p.connect(s, func(): c[s] += 1)
	c["reactions"] = []
	p.reaction_triggered.connect(func(r): c["reactions"].append(r))
	return c

func _ready():
	await frames()
	var p : CogitoProperties
	var c : Dictionary

	# --- Chill
	p = make(0)
	c = watch(p)
	await frames()
	check(!p.is_processing(), "idle object: _process off")
	p.apply_element(E.COLD, 0.5)
	check(!p.is_chilled, "sub-threshold cold doesn't chill")
	p.apply_element(E.COLD, 0.6)
	check(p.is_chilled and c[&"has_become_chilled"] == 1, "dry object chills at threshold, signal fired")
	check(p.is_processing(), "chilled: _process on")
	await wait(0.6)
	check(!p.is_chilled and c[&"has_warmed_up"] == 1 and p.get_element_level(E.COLD) == 0.0, "chill wears off after chill_time, level 0")
	check(!p.is_processing(), "after chill: _process off")

	# --- Chilled + fire
	p = make(F.FLAMMABLE)
	c = watch(p)
	await frames()
	p.apply_element(E.COLD, 1.2)
	p.apply_element(E.FIRE, 0.5)
	check(p.is_chilled and p.get_element_level(E.COLD) < 0.8 and p.get_element_level(E.FIRE) == 0.0, "fire on chilled first reduces the chill")
	p.apply_element(E.FIRE, 2.0)
	check(!p.is_chilled and c[&"has_warmed_up"] == 1 and p.is_on_fire, "enough fire ends the chill, leftover ignites")
	# cold cancels sub-threshold fire
	p = make(F.FLAMMABLE)
	await frames()
	p.apply_element(E.FIRE, 0.7)
	p.apply_element(E.COLD, 0.4)
	check(is_equal_approx(p.get_element_level(E.FIRE), 0.3) and p.get_element_level(E.COLD) == 0.0, "cold cancels sub-threshold fire buildup first")
	p.apply_element(E.COLD, 0.6)
	check(is_equal_approx(p.get_element_level(E.COLD), 0.3) and p.get_element_level(E.FIRE) == 0.0, "rest of the cold continues as buildup")

	# --- Freeze
	p = make(F.CONDUCTIVE)
	c = watch(p)
	await frames()
	p.apply_element(E.WATER, 1.0)
	check(p.is_wet, "setup: timed wet")
	p.apply_element(E.SHOCK, 1.0)
	check(p.is_electric, "setup: electrified while wet")
	p.apply_element(E.COLD, 1.0)
	check(p.is_frozen and !p.is_wet and c[&"has_frozen"] == 1, "wet + cold freezes, no longer wet")
	check(&"freeze" in c["reactions"], "reaction freeze emitted")
	check(c[&"has_become_dry"] == 0, "has_become_dry not emitted on freeze")
	check(!p.is_electric, "electric object loses electricity when frozen")
	check(!p.can_conduct(), "frozen can't conduct even if CONDUCTIVE")
	p.make_wet()
	p.set_on_fire()
	check(!p.is_wet and !p.is_on_fire, "make_wet and set_on_fire do nothing while frozen")
	check(p.apply_element(E.WATER, 1.0) == 0.0 and p.apply_element(E.SHOCK, 1.0) == 0.0, "WATER and SHOCK return 0 while frozen")
	check(!p.is_electric and !p.is_wet, "still neither electric nor wet")

	# frozen + fire -> thaw
	p = make(F.FLAMMABLE)
	c = watch(p)
	await frames()
	p.apply_element(E.WATER, 1.0)
	p.apply_element(E.COLD, 1.0)
	check(p.is_frozen, "setup: frozen flammable")
	p.apply_element(E.FIRE, 0.4)
	check(p.is_frozen and c[&"has_thawed"] == 0, "small fire only melts part of the ice")
	p.apply_element(E.FIRE, 0.6)
	check(!p.is_frozen and c[&"has_thawed"] == 1 and p.is_wet, "enough fire thaws, object is wet again")
	check(&"thaw" in c["reactions"], "reaction thaw emitted")
	check(p.get_element_level(E.WATER) == p.buildup_threshold and p._timed_states.has(E.WATER), "timed wetness restored")
	# leftover dries it
	p = make(F.FLAMMABLE)
	c = watch(p)
	await frames()
	p.apply_element(E.WATER, 1.0)
	p.apply_element(E.COLD, 1.0)
	p.apply_element(E.FIRE, 3.0)
	check(!p.is_frozen and !p.is_wet and c[&"has_become_dry"] == 1 and &"steam" in c["reactions"], "leftover fire dries the thawed object (steam)")

	# freeze by itself
	p = make(0)
	c = watch(p)
	await frames()
	p.apply_element(E.WATER, 1.0)
	p.apply_element(E.COLD, 1.0)
	check(p.is_frozen, "setup: timed freeze")
	await wait(0.6)
	check(!p.is_frozen and c[&"has_thawed"] == 1 and p.is_wet and p._timed_states.has(E.WATER), "timed freeze thaws by itself into timed wet")
	# sustained wet
	p = make(F.WET)
	await frames()
	check(p.is_wet, "setup: WET flag object is wet")
	p.apply_element(E.COLD, 1.0)
	check(p.is_frozen and !(p.elemental_properties & F.WET), "sustained wet object freezes, WET flag cleared")
	await wait(0.6)
	check(!p.is_frozen and p.is_wet and (p.elemental_properties & F.WET) and !p._timed_states.has(E.WATER), "thaws back to sustained wet with WET flag")
	# public freeze
	p = make(0)
	await frames()
	p.freeze()
	check(!p.is_frozen, "freeze() on a dry object does nothing")
	p.make_wet()
	p.freeze()
	check(p.is_frozen, "freeze() freezes a wet object")
	await wait(0.6)
	check(p.is_frozen, "sustained freeze doesn't thaw by itself")
	p.thaw()
	check(!p.is_frozen and p.is_wet, "thaw() melts it")
	# chilled becoming wet then cold
	p = make(0)
	await frames()
	p.freeze_time = 0.0
	p.apply_element(E.COLD, 1.0)
	p.chill_time = 5.0
	p.apply_element(E.WATER, 1.0)
	check(p.is_chilled and p.is_wet, "water on chilled: stays chilled and wet")
	p.apply_element(E.COLD, 0.1)
	check(p.is_frozen and !p.is_chilled, "chilled + wet + more cold freezes")
	await wait(0.5)
	check(p.is_frozen, "freeze_time 0 never thaws by itself")

	# --- Rigid body
	var rb := RigidHolder.new()
	rb.freeze = false
	p = make(F.WET, Vector3.ZERO, Callable(), rb)
	await frames()
	p.apply_element(E.COLD, 1.0)
	check(rb.freeze, "RigidBody3D parent freezes")
	await wait(0.6)
	check(!p.is_frozen and !rb.freeze, "RigidBody3D freeze restored to false after thaw")
	var rb2 := RigidHolder.new()
	rb2.freeze = true
	p = make(F.WET, Vector3.ZERO, Callable(), rb2)
	await frames()
	p.apply_element(E.COLD, 1.0)
	p.thaw()
	check(rb2.freeze, "RigidBody3D original freeze=true restored")

	# --- Quench
	p = make(F.FLAMMABLE)
	c = watch(p)
	await frames()
	p.set_on_fire()
	p.apply_element(E.COLD, 0.6)
	check(p.is_on_fire, "burning: sub-threshold cold doesn't extinguish")
	p.apply_element(E.COLD, 0.6)
	check(!p.is_on_fire and c[&"has_been_extinguished"] == 1 and &"quench" in c["reactions"], "cold >= threshold extinguishes, reaction quench")
	check(p.get_element_level(E.COLD) == 0.0 and !p.is_chilled, "leftover cold discarded")

	# --- Poison
	var hp := make(0)
	c = watch(hp)
	await frames()
	hp.apply_element(E.POISON, 0.5)
	check(!hp.is_poisoned, "sub-threshold poison doesn't poison")
	hp.apply_element(E.POISON, 0.6)
	check(hp.is_poisoned and c[&"has_been_poisoned"] == 1, "poison buildup poisons, signal fired")
	await wait(0.25)
	var holder := hp.get_parent() as Holder
	check(holder.taken > 0.0, "poison damages the holder")
	var lvl := hp.get_element_level(E.POISON)
	hp.apply_element(E.FIRE, 1.0); hp.apply_element(E.WATER, 1.0); hp.apply_element(E.COLD, 0.5); hp.apply_element(E.SHOCK, 1.0)
	check(hp.get_element_level(E.POISON) <= lvl, "FIRE/WATER/COLD/SHOCK don't change the POISON level")
	await wait(0.7)
	check(!hp.is_poisoned and c[&"has_been_cured"] == 1, "timed poison ends by itself")
	hp.apply_element(E.POISON, 1.5)
	check(hp.is_poisoned, "re-poisoned")
	hp.cure_poison()
	check(!hp.is_poisoned and hp.get_element_level(E.POISON) == 0.0 and c[&"has_been_cured"] == 2, "cure_poison() ends it and emits signal")
	hp.cure_poison()
	check(c[&"has_been_cured"] == 2, "cure_poison() when not poisoned emits nothing")
	await frames()
	p = make(0)
	await frames()
	p.apply_element(E.POISON, 1.5)
	p.cure_poison()
	check(!p.is_processing(), "cured object: _process off")
	# resist
	p = make(0, Vector3.ZERO, func(q): q.resist_poison = 100.0)
	await frames()
	check(p.apply_element(E.POISON, 5.0) == 0.0 and !p.is_poisoned, "resist_poison 100: no buildup")
	await wait(0.3)
	check((p.get_parent() as Holder).taken == 0.0, "resist_poison 100: no damage")
	# poison damage applies resistance
	p = make(0, Vector3.ZERO, func(q): q.resist_poison = 50.0; q.poison_damage_per_second = 10.0)
	await frames()
	p.apply_element(E.POISON, 2.0)
	await wait(0.35)
	var taken := (p.get_parent() as Holder).taken
	check(taken > 0.0 and taken <= 3 * 0.5, "poison damage scaled by resistance")

	# --- Cold damage
	p = make(0, Vector3.ZERO, func(q): q.cold_damage_per_second = 5.0; q.chill_time = 5.0)
	await frames()
	p.apply_element(E.COLD, 1.0)
	await wait(0.35)
	check((p.get_parent() as Holder).taken > 0.0, "cold_damage_per_second damages a chilled holder")
	p = make(0)
	await frames()
	p.apply_element(E.COLD, 1.0)
	await wait(0.2)
	check((p.get_parent() as Holder).taken == 0.0, "default cold_damage_per_second 0 deals nothing")

	# --- Element area
	var area := CogitoElementArea.new()
	area.element = E.FIRE
	add_child(area)
	var douses := [0]
	area.reaction_triggered.connect(func(r): if r == &"douse": douses[0] += 1)
	await frames()
	area.apply_element(E.COLD, 0.6)
	check(area.enabled, "fire area survives sub-threshold cold")
	area.apply_element(E.COLD, 0.6)
	check(!area.enabled and douses[0] == 1, "fire area doused by cold")

	# --- Idle
	p = make(F.FLAMMABLE | F.CONDUCTIVE)
	await frames()
	p.apply_element(E.COLD, 0.5)
	p.apply_element(E.POISON, 0.5)
	await wait(1.5)
	check(!p.is_processing(), "_process off once all buildup decayed")

	print("RESULT fails=", fails)
	get_tree().quit(fails)

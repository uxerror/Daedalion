extends Node3D
## E1: element buildup, reactions, resistances, typed damage.

const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
const E = CogitoProperties.Element
const F = CogitoProperties.ElementalProperties
var fails := 0

class Holder extends Node3D:
	signal damage_received(amount)
	var cogito_properties : CogitoProperties
	var taken := 0.0
	func _init():
		damage_received.connect(func(a, _s = null, _d = Vector3.ZERO, _p = Vector3.ZERO): taken += a)

func make(flags: int) -> CogitoProperties:
	var h := Holder.new()
	add_child(h)
	var p : CogitoProperties = PROPS.instantiate()
	p.elemental_properties = flags
	p.is_logging = false
	h.add_child(p)
	h.cogito_properties = p
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

func _ready():
	await frames()
	# Fire buildup
	var wood := make(F.FLAMMABLE)
	await frames()
	wood.apply_element(E.FIRE, 0.6)
	check(!wood.is_on_fire, "0.6 heat doesn't ignite")
	wood.apply_element(E.FIRE, 0.6)
	check(wood.is_on_fire, "accumulated heat ignites")
	var stone := make(0)
	stone.apply_element(E.FIRE, 2.0)
	check(!stone.is_on_fire and stone.get_element_level(E.FIRE) > 0, "non-flammable heats but doesn't burn")
	var lvl := stone.get_element_level(E.FIRE)
	await wait(0.5)
	check(stone.get_element_level(E.FIRE) < lvl, "heat decays")

	# Sub-threshold decay
	var w2 := make(F.FLAMMABLE)
	w2.buildup_decay_per_second = 10.0
	w2.apply_element(E.FIRE, 0.6)
	await wait(0.2)
	w2.apply_element(E.FIRE, 0.6)
	check(!w2.is_on_fire, "heat decays between exposures, no ignition")

	# Water douses fire and wets with drying
	var reactions := []
	wood.reaction_triggered.connect(func(r): reactions.append(r))
	wood.apply_element(E.WATER, 1.0)
	check(!wood.is_on_fire and wood.is_wet and &"douse" in reactions, "water douses fire and wets")
	wood.dry_time = 0.5
	await wait(0.8)
	check(!wood.is_wet, "applied wetness dries out")

	# Wet blocks ignition until dried by heat (steam)
	var w3 := make(F.FLAMMABLE)
	w3.apply_element(E.WATER, 1.5)
	reactions.clear()
	w3.reaction_triggered.connect(func(r): reactions.append(r))
	w3.apply_element(E.FIRE, 1.0)
	check(!w3.is_on_fire and w3.is_wet and &"steam" in reactions, "fire on wet object makes steam, no ignition")
	w3.apply_element(E.FIRE, 1.5)
	check(!w3.is_wet and w3.is_on_fire, "enough heat dries and ignites")

	# Permanently wet swallows fire
	var bottle := make(F.FLAMMABLE | F.WET)
	await frames()
	bottle.apply_element(E.FIRE, 3.0)
	check(bottle.is_wet and !bottle.is_on_fire, "permanently wet object can't be ignited by apply_element")
	bottle.dry_time = 0.1
	await wait(0.3)
	check(bottle.is_wet, "permanently wet object doesn't dry")

	# Shock
	var plank := make(0)
	plank.apply_element(E.SHOCK, 2.0)
	check(!plank.is_electric and plank.get_element_level(E.SHOCK) == 0.0, "non-conductor ignores shock")
	plank.apply_element(E.WATER, 1.0)
	plank.apply_element(E.SHOCK, 1.0)
	check(plank.is_electric, "wet object conducts")
	var metal := make(F.CONDUCTIVE)
	metal.buildup_decay_per_second = 4.0
	var lost := [0]
	metal.has_lost_electricity.connect(func(): lost[0] += 1)
	metal.apply_element(E.SHOCK, 1.0)
	check(metal.is_electric, "conductor gets electric")
	await wait(0.6)
	check(!metal.is_electric and lost[0] == 1, "applied charge runs out")
	var cathode := make(F.CONDUCTIVE)
	cathode.make_electric()
	cathode.buildup_decay_per_second = 10.0
	await wait(0.3)
	check(cathode.is_electric, "directly electrified (sustained) stays electric")

	# Resistances
	var asbestos := make(F.FLAMMABLE)
	asbestos.resist_fire = 100
	check(asbestos.apply_element(E.FIRE, 5.0) == 0.0 and !asbestos.is_on_fire, "100% fire resistance = immune")
	var weak := make(F.FLAMMABLE)
	weak.resist_fire = -100
	weak.apply_element(E.FIRE, 0.5)
	check(weak.is_on_fire, "-100% fire resistance doubles buildup")

	# Damage
	var target := make(F.CONDUCTIVE)
	target.resist_fire = 50
	var h : Holder = target.get_parent()
	var dealt := CogitoProperties.deal_elemental_damage(h, 10.0, E.FIRE)
	check(is_equal_approx(dealt, 5.0) and is_equal_approx(h.taken, 5.0), "fire damage halved by 50%% resistance: %s" % h.taken)
	target.apply_element(E.WATER, 1.0)
	h.taken = 0.0
	CogitoProperties.deal_elemental_damage(h, 10.0, E.SHOCK)
	check(is_equal_approx(h.taken, 15.0), "wet target takes 1.5x shock: %s" % h.taken)
	var burner := make(F.FLAMMABLE)
	burner.resist_fire = 75
	burner.burn_damage_amount = 4.0
	burner.apply_burn_damage()
	check(is_equal_approx((burner.get_parent() as Holder).taken, 1.0), "burn tick respects resistance")
	check(CogitoProperties.deal_elemental_damage(Node3D.new(), 5.0, E.FIRE) == 0.0, "no damage_received -> 0, no crash")

	# Processing turns off when idle
	var idle := make(0)
	idle.buildup_decay_per_second = 10.0
	idle.apply_element(E.COLD, 0.5)
	check(idle.is_processing(), "processing while decaying")
	await wait(0.2)
	check(!idle.is_processing() and idle.get_element_level(E.COLD) == 0.0, "processing stops when nothing decays")

	print("RESULT fails=", fails)
	get_tree().quit(fails)

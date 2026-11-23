extends Node3D
## E2: heat spreading, fuel/burn out, CogitoElementArea, FluidArea3D.

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

func make(flags: int, pos: Vector3, setup := Callable()) -> CogitoProperties:
	var h := Holder.new()
	h.position = pos
	var p : CogitoProperties = PROPS.instantiate()
	p.elemental_properties = flags
	p.is_logging = false
	if setup.is_valid():
		setup.call(p)
	h.add_child(p)
	h.cogito_properties = p
	add_child(h)
	return p

func make_area(script_or_null, pos: Vector3, size := 2.0) -> CogitoElementArea:
	var a : CogitoElementArea = CogitoElementArea.new() if script_or_null == null else script_or_null.new()
	a.position = pos
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * size
	shape.shape = box
	a.add_child(shape)
	add_child(a)
	return a

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
	# --- Heat spreading
	var fire := make(F.FLAMMABLE, Vector3(0, 0, 0), func(p): p.heat_radius = 2.0; p.heat_per_second = 2.0)
	var near := make(F.FLAMMABLE, Vector3(1.2, 0, 0))
	var far := make(F.FLAMMABLE, Vector3(6, 0, 0))
	var wet_near := make(F.FLAMMABLE, Vector3(-1.2, 0, 0))
	await frames()
	wet_near.apply_element(E.WATER, 1.0)
	var steams := [0]
	wet_near.reaction_triggered.connect(func(r): if r == &"steam": steams[0] += 1)
	fire.set_on_fire()
	check(fire.get_node_or_null("HeatSensor") != null, "heat sensor created on ignition")
	var lit := {}
	var t := 0.0
	while t < 3.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		for p in [near, wet_near, far]:
			if p.is_on_fire and !lit.has(p): lit[p] = t
	check(lit.has(near), "neighbour in heat radius ignites")
	check(!lit.has(far), "object outside heat radius stays cold")
	check(steams[0] > 0, "wet neighbour steams")
	check(lit.has(wet_near) and lit[wet_near] > lit.get(near, 99.0), "wet neighbour ignites later, after drying: %s" % [lit.values()])
	fire.extinguish()
	await frames()
	check(fire.get_node_or_null("HeatSensor") == null, "heat sensor removed when extinguished")
	for p in [fire, near, wet_near]: p.extinguish()

	# heat_radius 0 = old behaviour
	var old := make(F.FLAMMABLE, Vector3(0, 10, 0))
	var old_near := make(F.FLAMMABLE, Vector3(0.6, 10, 0))
	await frames()
	old.set_on_fire()
	await wait(1.0)
	check(!old_near.is_on_fire and old.get_node_or_null("HeatSensor") == null, "heat_radius 0: no spreading")
	check(!old.is_processing(), "eternal fire without heat radius doesn't process")
	old.extinguish()

	# --- Fuel
	var burnt := [0]
	var char := make(F.FLAMMABLE, Vector3(20, 0, 0), func(p): p.fuel = 0.3)
	char.burned_out.connect(func(): burnt[0] += 1)
	var nothing := make(F.FLAMMABLE, Vector3(22, 0, 0), func(p): p.fuel = 0.3; p.burn_out_result = CogitoProperties.BurnOutResult.NOTHING)
	var destroy := make(F.FLAMMABLE, Vector3(24, 0, 0), func(p): p.fuel = 0.3; p.burn_out_result = CogitoProperties.BurnOutResult.DESTROY)
	var destroy_holder := destroy.get_parent()
	await frames()
	for p in [char, nothing, destroy]: p.set_on_fire()
	await wait(0.15)
	check(char.is_on_fire, "burns while fuel lasts")
	await wait(0.4)
	check(!char.is_on_fire and burnt[0] == 1, "burns out when fuel runs out")
	check(!(char.elemental_properties & F.FLAMMABLE), "CHAR: no longer flammable")
	char.apply_element(E.FIRE, 3.0)
	check(!char.is_on_fire, "charred object can't be lit again")
	check(!nothing.is_on_fire and (nothing.elemental_properties & F.FLAMMABLE) and is_equal_approx(nothing.fuel_remaining, 0.3), "NOTHING: goes out, fuel refilled")
	check(!is_instance_valid(destroy_holder) or destroy_holder.is_queued_for_deletion(), "DESTROY: parent freed")

	# --- CogitoElementArea: fire
	var camp := make_area(null, Vector3(40, 0, 0))
	camp.damage_per_second = 4.0
	var log := make(F.FLAMMABLE, Vector3(40, 0, 0))
	await wait(1.0)
	var log_h : Holder = log.get_parent()
	check(log.is_on_fire, "fire area ignites flammable body inside")
	check(log_h.taken > 3.0, "fire area deals damage: %s" % log_h.taken)
	log.extinguish()
	var toggles := []
	camp.enabled_changed.connect(func(v): toggles.append(v))
	camp.interact()
	check(!camp.enabled and toggles == [false], "interact() toggles area off")
	log_h.taken = 0.0
	await wait(1.5)
	check(!log.is_on_fire and log_h.taken == 0.0, "disabled area does nothing")
	camp.interact()
	var reactions := []
	camp.reaction_triggered.connect(func(r): reactions.append(r))
	camp.apply_element(E.WATER, 0.6)
	check(camp.enabled, "a little water doesn't douse the fire area")
	camp.apply_element(E.WATER, 0.6)
	check(!camp.enabled and reactions.has(&"douse"), "water douses the fire area")
	camp.apply_element(E.FIRE, 1.0)
	check(camp.enabled and reactions.has(&"ignite"), "fire relights the fire area")
	log.extinguish()

	# Rain area over the campfire puts it out
	var rain := make_area(null, Vector3(40, 0, 0), 3.0)
	rain.element = E.WATER
	rain.amount_per_second = 4.0
	await wait(0.8)
	check(!camp.enabled, "rain area douses overlapping fire area")
	rain.queue_free()
	await frames()

	# Burning object with heat radius relights a doused campfire
	var torch := make(F.FLAMMABLE, Vector3(41.5, 0, 0), func(p): p.heat_radius = 1.5; p.heat_per_second = 4.0)
	log.elemental_properties = 0
	await frames()
	torch.set_on_fire()
	await wait(0.8)
	check(camp.enabled, "heat radiation relights a doused fire area")
	torch.extinguish()

	# --- FluidArea3D
	var water : FluidArea3D = make_area(FluidArea3D, Vector3(60, 0, 0), 3.0)
	check(water.element == E.WATER and water.conducts_shock, "FluidArea3D is a conducting water area")
	var burning := make(F.FLAMMABLE, Vector3(80, 0, 0))
	await frames()
	burning.set_on_fire()
	burning.get_parent().position = Vector3(60, 0, 0)
	await wait(0.6)
	check(!burning.is_on_fire and burning.is_wet, "submerged burning object is doused and wet")
	var wood := burning
	var victim : Holder = wood.get_parent()
	victim.taken = 0.0
	var battery := make(F.CONDUCTIVE, Vector3(90, 0, 0))
	await frames()
	battery.make_electric()
	battery.get_parent().position = Vector3(60.8, 0, 0)
	await wait(1.2)
	check(water.is_electric, "electric object in water electrifies it")
	check(wood.is_electric, "wet body in electrified water gets electric")
	check(victim.taken > 1.0, "electrified water deals shock damage: %s" % victim.taken)
	check((battery.get_parent() as Holder).taken == 0.0, "the source itself isn't shocked")
	battery.get_parent().position = Vector3(90, 0, 0)
	await wait(1.6)
	check(!water.is_electric, "water loses charge when source leaves (no self-sustain)")
	var t0 := victim.taken
	await wait(0.5)
	check(is_equal_approx(victim.taken, t0), "no damage after charge is gone")
	water.apply_element(E.SHOCK, 1.0)
	check(water.is_electric, "SHOCK hit electrifies water")
	await wait(1.6)
	check(!water.is_electric, "SHOCK hit charge wears off after hold time")

	print("RESULT fails=", fails)
	get_tree().quit(fails)

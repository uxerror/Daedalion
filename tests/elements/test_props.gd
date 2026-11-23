extends Node3D

const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
var fails := 0

class Holder extends Node3D:
	signal damage_received(amount, source, hit_direction, hit_position)
	var cogito_properties : CogitoProperties

func make(flags: int, with_audio := true) -> CogitoProperties:
	var h := Holder.new()
	add_child(h)
	var p : CogitoProperties = PROPS.instantiate()
	p.elemental_properties = flags
	p.is_logging = false
	if !with_audio:
		p.get_node("AudioStreamPlayer3D").free()
	h.add_child(p)
	h.cogito_properties = p
	return p

func check(cond: bool, msg: String):
	if !cond:
		fails += 1
		print("FAIL: ", msg)
	else:
		print("ok: ", msg)

func kinds(p: CogitoProperties) -> Array:
	var r := []
	for n in p.spawned_effects:
		if is_instance_valid(n): r.append(String(n.get_meta(CogitoProperties.VFX_KIND_META)))
	r.sort()
	return r

func _ready():
	await get_tree().process_frame
	var F = CogitoProperties.ElementalProperties
	var a := make(0)
	a.make_dry()
	check(!(a.elemental_properties & F.WET), "make_dry on dry object keeps it dry")
	a.make_conductive(); a.make_conductive()
	check(a.elemental_properties & F.CONDUCTIVE, "make_conductive twice stays conductive")

	var burning := make(F.FLAMMABLE, false)
	burning.set_on_fire()
	await get_tree().process_frame; await get_tree().process_frame
	check(burning.is_on_fire and kinds(burning) == ["fire"], "ignite spawns fire vfx")
	var wetcond := make(F.WET | F.CONDUCTIVE)
	await get_tree().process_frame
	burning.reaction_collider = wetcond.get_parent()
	burning.check_for_systemic_reactions()
	await get_tree().process_frame; await get_tree().process_frame
	check(!burning.is_on_fire, "WET|CONDUCTIVE collider extinguishes (no audio player, no crash)")
	check(burning.is_wet and kinds(burning) == ["wet"], "fire vfx cleared, wet vfx present: %s" % [kinds(burning)])

	var c := make(F.CONDUCTIVE | F.WET)
	await get_tree().process_frame; await get_tree().process_frame
	c.make_electric()
	await get_tree().process_frame; await get_tree().process_frame
	check(kinds(c) == ["electric", "wet"], "wet+electric vfx: %s" % [kinds(c)])
	c.loose_electricity()
	check(kinds(c) == ["wet"], "losing electricity keeps wet vfx: %s" % [kinds(c)])
	var lost := [0]
	c.has_lost_electricity.connect(func(): lost[0] += 1)
	c.loose_electricity()
	check(lost[0] == 0, "loose_electricity when not electric emits nothing")
	var wet_emits := [0]
	c.has_become_wet.connect(func(): wet_emits[0] += 1)
	c.make_wet(); c.make_wet()
	check(wet_emits[0] == 0 and kinds(c) == ["wet"], "make_wet on wet object doesn't respawn vfx")

	var plain := Node3D.new(); add_child(plain)
	c.start_reaction_threshold_timer(plain)
	c.check_for_reaction_timer_interrupt(plain)
	check(true, "body without cogito_properties member doesn't crash")

	var dmg := make(F.FLAMMABLE)
	dmg.burn_damage_amount = 2.0
	var got := [0.0]
	var src := [null]
	dmg.get_parent().damage_received.connect(func(x, s, _d, _p): got[0] += x; src[0] = s)
	dmg.apply_burn_damage()
	check(got[0] == 2.0, "burn damage reaches parent")
	check(src[0] == dmg.get_parent(), "burn damage comes from the burning parent itself")
	var nosig := Node3D.new(); add_child(nosig)
	var p2 : CogitoProperties = PROPS.instantiate(); p2.is_logging = false; nosig.add_child(p2)
	p2.apply_burn_damage()
	check(true, "burn damage on parent without damage_received doesn't crash")

	var many := make(F.FLAMMABLE | F.CONDUCTIVE)
	many.max_spawned_vfx = 2
	many.set_on_fire(); many.make_electric(); many.make_wet()
	await get_tree().process_frame; await get_tree().process_frame
	check(many.spawned_effects.size() <= 2, "max_spawned_vfx respected: %d" % many.spawned_effects.size())

	print("RESULT fails=", fails)
	get_tree().quit(fails)

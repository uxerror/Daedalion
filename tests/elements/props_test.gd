extends GdUnitTestSuite

const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
const F = CogitoProperties.ElementalProperties

var _world: Node3D


class Holder:
	extends Node3D
	signal damage_received(
		amount: float, source: Node, hit_direction: Vector3, hit_position: Vector3
	)
	var cogito_properties: CogitoProperties


func before_test() -> void:
	_world = auto_free(Node3D.new())
	add_child(_world)


func after_test() -> void:
	# Elemental VFX attach to their holder on the next frame.
	await _frames()


func _make_properties(flags: int, with_audio := true) -> CogitoProperties:
	var holder := Holder.new()
	_world.add_child(holder)
	var properties: CogitoProperties = PROPS.instantiate()
	properties.elemental_properties = flags
	properties.is_logging = false
	if !with_audio:
		properties.get_node("AudioStreamPlayer3D").free()
	holder.add_child(properties)
	holder.cogito_properties = properties
	return properties


func _effect_kinds(properties: CogitoProperties) -> Array:
	var result := []
	for effect in properties.spawned_effects:
		if is_instance_valid(effect):
			result.append(String(effect.get_meta(CogitoProperties.VFX_KIND_META)))
	result.sort()
	return result


func _frames(count := 2) -> void:
	for _frame in count:
		await get_tree().process_frame


func test_dry_and_conductive_flags() -> void:
	var subject := _make_properties(0)
	subject.make_dry()
	(
		assert_bool(!(subject.elemental_properties & F.WET))
		. override_failure_message("make_dry on dry object keeps it dry")
		. is_true()
	)
	subject.make_conductive()
	subject.make_conductive()
	(
		assert_bool((subject.elemental_properties & F.CONDUCTIVE) != 0)
		. override_failure_message("make_conductive twice stays conductive")
		. is_true()
	)


func test_wet_conductive_collision_extinguishes_fire_without_audio() -> void:
	var burning := _make_properties(F.FLAMMABLE, false)
	burning.set_on_fire()
	await _frames()
	(
		assert_bool(burning.is_on_fire and _effect_kinds(burning) == ["fire"])
		. override_failure_message("ignite spawns fire vfx")
		. is_true()
	)
	var wet_conductor := _make_properties(F.WET | F.CONDUCTIVE)
	await get_tree().process_frame
	burning.reaction_collider = wet_conductor.get_parent()
	burning.check_for_systemic_reactions()
	await _frames()
	(
		assert_bool(!burning.is_on_fire)
		. override_failure_message(
			"WET|CONDUCTIVE collider extinguishes (no audio player, no crash)"
		)
		. is_true()
	)
	(
		assert_bool(burning.is_wet and _effect_kinds(burning) == ["wet"])
		. override_failure_message(
			"fire vfx cleared, wet vfx present: %s" % [_effect_kinds(burning)]
		)
		. is_true()
	)


func test_losing_charge_preserves_the_wet_effect() -> void:
	var conductor := _make_properties(F.CONDUCTIVE | F.WET)
	await _frames()
	conductor.make_electric()
	await _frames()
	(
		assert_bool(_effect_kinds(conductor) == ["electric", "wet"])
		. override_failure_message("wet+electric vfx: %s" % [_effect_kinds(conductor)])
		. is_true()
	)
	conductor.loose_electricity()
	(
		assert_bool(_effect_kinds(conductor) == ["wet"])
		. override_failure_message(
			"losing electricity keeps wet vfx: %s" % [_effect_kinds(conductor)]
		)
		. is_true()
	)
	var lost := [0]
	conductor.has_lost_electricity.connect(func(): lost[0] += 1)
	conductor.loose_electricity()
	(
		assert_bool(lost[0] == 0)
		. override_failure_message("loose_electricity when not electric emits nothing")
		. is_true()
	)
	var wet_emits := [0]
	conductor.has_become_wet.connect(func(): wet_emits[0] += 1)
	conductor.make_wet()
	conductor.make_wet()
	(
		assert_bool(wet_emits[0] == 0 and _effect_kinds(conductor) == ["wet"])
		. override_failure_message("make_wet on wet object doesn't respawn vfx")
		. is_true()
	)


func test_reaction_timer_ignores_body_without_properties() -> void:
	var conductor := _make_properties(F.CONDUCTIVE | F.WET)
	var plain := Node3D.new()
	_world.add_child(plain)
	var check_contact := func() -> void:
		conductor.start_reaction_threshold_timer(plain)
		conductor.check_for_reaction_timer_interrupt(plain)
	(
		assert_error(check_contact)
		. override_failure_message("body without cogito_properties member doesn't crash")
		. is_success()
	)


func test_burn_damage_reaches_its_source() -> void:
	var burning := _make_properties(F.FLAMMABLE)
	burning.burn_damage_amount = 2.0
	var damage := [0.0]
	var sources := [null]
	var holder := burning.get_parent() as Holder
	holder.damage_received.connect(
		func(amount, source, _direction, _position):
			damage[0] += amount
			sources[0] = source
	)
	burning.apply_burn_damage()
	assert_bool(damage[0] == 2.0).override_failure_message("burn damage reaches parent").is_true()
	(
		assert_bool(sources[0] == burning.get_parent())
		. override_failure_message("burn damage comes from the burning parent itself")
		. is_true()
	)


func test_burn_damage_ignores_parent_without_signal() -> void:
	var plain_body := Node3D.new()
	_world.add_child(plain_body)
	var properties: CogitoProperties = PROPS.instantiate()
	properties.is_logging = false
	plain_body.add_child(properties)
	(
		assert_error(properties.apply_burn_damage)
		. override_failure_message("burn damage on parent without damage_received doesn't crash")
		. is_success()
	)


func test_spawned_effect_limit() -> void:
	var many := _make_properties(F.FLAMMABLE | F.CONDUCTIVE)
	many.max_spawned_vfx = 2
	many.set_on_fire()
	many.make_electric()
	many.make_wet()
	await _frames()
	(
		assert_bool(many.spawned_effects.size() <= 2)
		. override_failure_message("max_spawned_vfx respected: %d" % many.spawned_effects.size())
		. is_true()
	)

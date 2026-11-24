extends "res://tests/saves/slot_fixture.gd"

const FIXTURES := preload("res://tests/fixtures/element_fixtures.gd")


func _build_level() -> Node3D:
	get_tree().current_scene.free()
	var level := Node3D.new()
	level.name = "HealthLevel"
	get_tree().root.add_child(level)
	get_tree().current_scene = level
	manager._current_scene_root_node = level
	for object_name: String in ["Crate", "Breakable", "Static"]:
		var body: Node3D
		if object_name == "Crate":
			body = CogitoObject.new()
		else:
			body = CogitoStaticInteractable.new()
		body.name = object_name
		var health := CogitoHealthAttribute.new()
		health.name = "Health"
		health.value_max = 100.0
		health.value_start = 100.0
		body.add_child(health)
		level.add_child(body)
		body.owner = level
	var npc := FIXTURES.make_npc()
	npc.name = "NPC"
	level.add_child(npc)
	npc.owner = level
	CogitoPersistentId.stamp_level(level)
	return level


func test_damaged_attributes_and_retained_corpses_restore_silently(
	dead: bool, _test_parameters := [[false], [true]]
) -> void:
	var level := _build_level()
	await get_tree().process_frame
	var hp := 0.0 if dead else 35.0
	var npc: CogitoNPC = level.get_node("NPC")
	npc.health.spawn_on_death = []
	npc.health.destroy_on_death = []
	for health: CogitoHealthAttribute in [npc.health, level.get_node("Crate/Health")]:
		health.set_attribute(hp, 140.0)
	var static_health: CogitoHealthAttribute = level.get_node("Static/Health")
	static_health.set_attribute(17.0, 80.0)
	var broken: CogitoHealthAttribute = level.get_node("Breakable/Health")
	broken.destroy_on_death = [NodePath("..")]
	broken.subtract(100.0)
	assert_int(manager.save_scene_state("Health", "temp")).is_equal(OK)
	level = _build_level()
	npc = level.get_node("NPC")
	var crate: CogitoHealthAttribute = level.get_node("Crate/Health")
	monitor_signals(npc.health, false)
	monitor_signals(crate, false)
	for _repeat in 2:
		manager.load_scene_state("Health", "temp")
		await get_tree().process_frame
	assert_object(level.get_node_or_null("Breakable")).is_null()
	for health: CogitoHealthAttribute in [npc.health, crate]:
		assert_float(health.value_current).is_equal(hp)
		assert_float(health.value_max).is_equal(140.0)
		await assert_no_health_effects(health)
	assert_bool(npc.is_dead()).is_equal(dead)
	assert_bool(npc.can_process()).is_equal(not dead)
	static_health = level.get_node("Static/Health")
	assert_float(static_health.value_current).is_equal(17.0)
	assert_float(static_health.value_max).is_equal(80.0)


func test_npc_replaced_by_persistent_ragdoll_in_frame_of_death() -> void:
	var level := _build_level()
	await get_tree().process_frame
	var npc: CogitoNPC = level.get_node("NPC")
	npc.health.subtract(npc.health.value_max)
	assert_bool(npc.is_queued_for_deletion()).is_true()
	assert_int(manager.save_scene_state("Health", "temp")).is_equal(OK)
	level = _build_level()
	npc = level.get_node("NPC")
	var deaths: Array[bool] = []
	npc.health.death.connect(func() -> void: deaths.append(true))
	manager.load_scene_state("Health", "temp")
	await get_tree().process_frame
	await get_tree().process_frame
	assert_array(deaths).is_empty()
	assert_object(level.get_node_or_null("NPC")).is_null()
	assert_int(level.find_children("*", "CogitoRagdoll", true, false).size()).is_equal(1)

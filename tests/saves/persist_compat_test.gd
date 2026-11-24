extends "res://tests/saves/slot_fixture.gd"


func _new_level() -> Node3D:
	get_tree().current_scene.free()
	var level := Node3D.new()
	get_tree().root.add_child(level)
	get_tree().current_scene = level
	manager._current_scene_root_node = level
	return level


func _object(parent: Node, object_name: String) -> CogitoObject:
	var object := CogitoObject.new()
	object.name = object_name
	parent.add_child(object)
	object.owner = get_tree().current_scene
	return object


func test_level_edit_matches_moved_object_and_keeps_only_new_content() -> void:
	var level := _new_level()
	var crate := _object(level, "Crate")
	var health := CogitoHealthAttribute.new()
	health.name = "Health"
	health.value_start = 25.0
	health.value_max = 25.0
	crate.add_child(health)
	health.subtract(10.0)
	crate.position.x = 3.0
	var pickup := _object(level, "Pickup")
	CogitoPersistentId.stamp_level(level)
	pickup.free()
	assert_int(manager.save_scene_state("Edited", "temp")).is_equal(OK)
	level = _new_level()
	var shelf := Node3D.new()
	level.add_child(shelf)
	shelf.owner = level
	crate = _object(shelf, "MovedCrate")
	crate.set_meta(CogitoPersistentId.META_KEY, "level:Crate")
	health = CogitoHealthAttribute.new()
	health.name = "Health"
	crate.add_child(health)
	_object(level, "Pickup")
	var added := _object(level, "NewCrate")
	added.position.x = 42.0
	CogitoPersistentId.stamp_level(level)
	manager.load_scene_state("Edited", "temp")
	await get_tree().process_frame
	assert_object(level.get_node_or_null("Pickup")).is_null()
	assert_object(CogitoPersistentId.find(get_tree(), "level:Crate")).is_same(crate)
	assert_float(crate.position.x).is_equal(3.0)
	assert_float(health.value_current).is_equal(15.0)
	assert_float(added.position.x).is_equal(42.0)
	assert_bool(added.is_inside_tree()).is_true()


func test_empty_manifest_differs_from_missing_legacy_manifest(
	legacy: bool, _test_parameters := [[false], [true]]
) -> void:
	var level := _new_level()
	CogitoPersistentId.stamp_level(level)
	if legacy:
		var directory: String = manager.cogito_state_dir.path_join("temp")
		assert_int(DirAccess.make_dir_recursive_absolute(directory)).is_equal(OK)
		var path: String = manager.legacy_scene_file("temp", "Empty")
		assert_int(ResourceSaver.save(CogitoSceneState.new(), path)).is_equal(OK)
	else:
		assert_int(manager.save_scene_state("Empty", "temp")).is_equal(OK)
	level = _new_level()
	_object(level, "NewPickup")
	CogitoPersistentId.stamp_level(level)
	manager.load_scene_state("Empty", "temp")
	await get_tree().process_frame
	assert_bool(level.has_node("NewPickup")).is_equal(not legacy)

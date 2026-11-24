extends "res://tests/saves/slot_fixture.gd"

const TARGET := "1"


func start_level() -> void:
	get_tree().current_scene.free()
	var packed: PackedScene = load(LEVEL)
	var player: CogitoPlayerAdvanced = packed.instantiate()
	player.name = "A"
	get_tree().root.add_child(player)
	get_tree().current_scene = player
	manager._screenshot_to_save = Image.create_empty(3, 2, false, Image.FORMAT_RGBA8)
	manager._current_world_dict = {"generation": "old"}


func write_scene(slot: String, level: String, marker: String) -> void:
	var scene := CogitoSceneState.new()
	scene.saved_states = [{"marker": marker}]
	assert_int(scene.write_state(slot, level)).is_equal(OK)


func file_hashes(slot: String) -> Dictionary:
	var directory := manager.cogito_state_dir.path_join(slot)
	var hashes := {}
	for entry in DirAccess.get_files_at(directory):
		hashes[entry] = FileAccess.get_sha256(directory.path_join(entry))
	return hashes


func seed_overwrite() -> void:
	start_level()
	write_scene("temp", "B", "old")
	assert_int(manager.save_game(TARGET)).is_equal(OK)
	assert_int(manager.save_game("2")).is_equal(OK)
	manager._current_world_dict["generation"] = "new"
	manager._screenshot_to_save.fill(Color.RED)
	assert_int(DirAccess.remove_absolute(manager.scene_file("temp", "B"))).is_equal(OK)
	write_scene("temp", "C", "new")


func restart_storage() -> void:
	manager.storage = manager.SlotStorage.new(manager.cogito_state_dir)
	assert_int(manager.storage.recover_all()).is_equal(OK)


func test_overwrite_publishes_exact_set_and_new_preview() -> void:
	seed_overwrite()
	assert_int(manager.save_game(TARGET)).is_equal(OK)
	restart_storage()
	var slot := manager.prepare_slot(TARGET)
	assert_int(slot.status).is_equal(manager.SlotStatus.OK)
	assert_str(slot.player.world_dictionary["generation"]).is_equal("new")
	assert_str(manager.get_last_saved_slot()).is_equal(TARGET)
	assert_int(file_hashes(TARGET).size()).is_equal(4)
	assert_bool(FileAccess.file_exists(manager.scene_file(TARGET, "B"))).is_false()
	assert_str(FileAccess.get_sha256(manager.scene_file(TARGET, "C"))).is_equal(
		FileAccess.get_sha256(manager.scene_file("temp", "C"))
	)
	var image := Image.load_from_file(slot.player.player_state_screenshot_file)
	assert_object(image).is_not_null()
	assert_bool(image.get_pixel(0, 0).is_equal_approx(Color.RED)).is_true()


func test_io_failure_preserves_generation_and_index(
	step: String,
	_test_parameters := [
		["create staging"],
		["copy scene_C.v2.json"],
		["copy scene_D.v2.json"],
		["write player"],
		["write current scene"],
		["write screenshot"],
		["seal staging"],
		["back up live"],
		["publish staging"],
		["write index"],
		["publish index"],
	]
) -> void:
	seed_overwrite()
	write_scene("temp", "D", "new")
	var old_generation := file_hashes(TARGET)
	var index_hash := FileAccess.get_sha256(manager.saves_data_file_path)
	manager.storage.fail_before = func(operation: String) -> bool: return operation == step
	var button := make_button(TARGET)
	assert_int(button.save_in_slot()).is_not_equal(OK)
	assert_str(button.save_time_label.text).is_equal("Save failed.")
	assert_str(manager._active_slot).is_equal("2")
	restart_storage()
	assert_dict(file_hashes(TARGET)).is_equal(old_generation)
	assert_int(manager.prepare_slot(TARGET).status).is_equal(manager.SlotStatus.OK)
	assert_str(FileAccess.get_sha256(manager.saves_data_file_path)).is_equal(index_hash)


func test_restart_retries_failed_rollback() -> void:
	seed_overwrite()
	var old_generation := file_hashes(TARGET)
	manager.storage.fail_before = func(operation: String) -> bool:
		return operation in ["publish staging", "restore backup"]
	assert_int(manager.save_game(TARGET)).is_not_equal(OK)
	(
		assert_bool(DirAccess.dir_exists_absolute(manager.cogito_state_dir.path_join(TARGET)))
		. is_false()
	)
	restart_storage()
	assert_dict(file_hashes(TARGET)).is_equal(old_generation)
	assert_str(manager.get_last_saved_slot()).is_equal("2")
	assert_int(manager.prepare_slot(TARGET).status).is_equal(manager.SlotStatus.OK)


func test_crash_between_directory_and_index_commits() -> void:
	seed_overwrite()
	manager.storage.fail_before = func(operation: String) -> bool:
		return operation in ["publish index", "withdraw publication"]
	assert_int(manager.save_game(TARGET)).is_not_equal(OK)
	restart_storage()
	var slot := manager.prepare_slot(TARGET)
	assert_int(slot.status).is_equal(manager.SlotStatus.OK)
	assert_str(slot.player.world_dictionary["generation"]).is_equal("new")
	assert_int(file_hashes(TARGET).size()).is_equal(4)
	assert_bool(FileAccess.file_exists(manager.scene_file(TARGET, "B"))).is_false()
	assert_bool(FileAccess.file_exists(manager.scene_file(TARGET, "C"))).is_true()
	assert_str(manager.get_last_saved_slot()).is_equal("2")


func test_new_slot_recovers_only_sealed_staging() -> void:
	make_slot("draft")
	var root := manager.cogito_state_dir
	assert_int(DirAccess.rename_absolute(root + "draft", root + ".writing-1")).is_equal(OK)
	restart_storage()
	assert_int(manager.prepare_slot(TARGET).status).is_equal(manager.SlotStatus.EMPTY)
	make_slot("sealed")
	write_scene("sealed", "CogitoPlayer", "complete")
	var sealed := file_hashes("sealed")
	assert_int(DirAccess.rename_absolute(root + "sealed", root + ".ready-1")).is_equal(OK)
	manager.storage.fail_before = func(operation: String) -> bool: return operation == "recover 1"
	assert_int(manager.storage.recover_all()).is_not_equal(OK)
	restart_storage()
	assert_dict(file_hashes(TARGET)).is_equal(sealed)
	assert_int(manager.prepare_slot(TARGET).status).is_equal(manager.SlotStatus.OK)


func test_invalid_index_aborts_overwrite() -> void:
	seed_overwrite()
	var old_generation := file_hashes(TARGET)
	var config := ConfigFile.new()
	config.set_value("save", "slots", 42)
	assert_int(config.save(manager.saves_data_file_path)).is_equal(OK)
	var index_hash := FileAccess.get_sha256(manager.saves_data_file_path)
	assert_bool(manager.is_saved_slots_empty()).is_false()
	assert_int(manager.save_game(TARGET)).is_not_equal(OK)
	restart_storage()
	assert_dict(file_hashes(TARGET)).is_equal(old_generation)
	assert_str(FileAccess.get_sha256(manager.saves_data_file_path)).is_equal(index_hash)


func test_autosave_keeps_fresh_current_scene() -> void:
	start_level()
	write_scene("temp", "A", "stale")
	write_scene("temp", "C", "visited")
	var stale := FileAccess.get_sha256(manager.scene_file("temp", "A"))
	assert_int(manager._save_autosave_state()).is_equal(OK)
	var autosave := CogitoGlobals.cogito_settings.auto_save_name
	var slot := manager.prepare_slot(autosave)
	assert_int(slot.status).is_equal(manager.SlotStatus.OK)
	assert_array(slot.scene.saved_states).is_empty()
	assert_str(FileAccess.get_sha256(manager.scene_file(autosave, "A"))).is_not_equal(stale)
	assert_str(FileAccess.get_sha256(manager.scene_file(autosave, "C"))).is_equal(
		FileAccess.get_sha256(manager.scene_file("temp", "C"))
	)
	assert_str(manager.get_last_saved_slot()).is_empty()

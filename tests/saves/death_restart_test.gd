extends "res://tests/saves/slot_fixture.gd"

const DEATH_SCREEN := preload("res://addons/cogito/PackedScenes/death_screen.tscn")

var _new_games := 0


func _write_slot(slot: String, time: int) -> void:
	var state := make_slot(slot)
	state.player_state_savetime = time
	state.player_state_screenshot_file = manager.cogito_state_dir.path_join("missing.png")
	assert_int(ResourceSaver.save(state, manager.legacy_player_file(slot))).is_equal(OK)


func _open_screen() -> CogitoDeathScreen:
	var screen: CogitoDeathScreen = DEATH_SCREEN.instantiate()
	get_tree().current_scene.add_child(screen)
	screen.open_death_screen()
	return screen


func _wait_for_transition() -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while manager.is_currently_loading and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	assert_bool(manager.is_currently_loading).is_false()


func test_reload_button_loads_newest_valid_save_without_screenshot(
	newest_is_auto: bool, _test_parameters := [[true], [false]]
) -> void:
	var auto_slot := CogitoGlobals.cogito_settings.auto_save_name
	_write_slot("1", 50)
	_write_slot("8", 80)
	_write_slot(auto_slot, 90 if newest_is_auto else 70)
	_write_slot("9", 99)
	write_text(manager.scene_file("9", "CogitoPlayer"), "corrupt")
	_write_slot("temp", 999)
	# Index can be missing or can point to a broken slot.
	if newest_is_auto:
		assert_int(manager.save_last_saved_slot("9")).is_equal(OK)
	manager.is_loaded_from_start_new_game = true
	var expected := auto_slot if newest_is_auto else "8"
	var screen := _open_screen()
	var shot: TextureRect = screen.get_node("%Screenshot_Spot")
	assert_object(shot.texture).is_same(screen.empty_slot_texture)
	assert_str(screen.label_active_slot.text).ends_with(" " + expected)
	assert_str(screen.load_button.text).is_equal("BTN_Reload")
	assert_bool(InputRouter.is_input_active(screen)).is_true()
	screen.load_button.pressed.emit()
	screen.load_button.pressed.emit()
	await _wait_for_transition()
	assert_bool(get_tree().paused).is_false()
	assert_bool(is_instance_valid(screen)).is_false()
	assert_bool(InputRouter.is_input_active(manager.get_player())).is_true()
	assert_str(manager._active_slot).is_equal(expected)
	assert_dict(manager._current_world_dict).is_equal({"loaded": expected})


func test_ties_use_manual_history_then_directory_order() -> void:
	var auto_slot := CogitoGlobals.cogito_settings.auto_save_name
	for slot: String in ["8", auto_slot, "1"]:
		_write_slot(slot, 100)
	assert_str(manager.find_latest_loadable_slot().slot).is_equal("1")
	assert_int(manager.save_last_saved_slot("1")).is_equal(OK)
	assert_int(manager.save_last_saved_slot("8")).is_equal(OK)
	assert_str(manager.find_latest_loadable_slot().slot).is_equal("8")


func test_untimed_legacy_slot_uses_player_file_mtime() -> void:
	_write_slot("old", 0)
	_write_slot("1", 1)
	var latest := manager.find_latest_loadable_slot()
	assert_str(latest.slot).is_equal("old")
	var modified := FileAccess.get_modified_time(manager.legacy_player_file("old"))
	assert_int(latest.save_time).is_equal(modified)


func test_failed_copy_keeps_death_input_and_level() -> void:
	_write_slot("1", 50)
	_write_slot("temp", 40)
	var previous := get_tree().current_scene
	var hash_before := FileAccess.get_sha256(manager.legacy_player_file("temp"))
	var screen := _open_screen()
	manager.storage.fail_before = func(step: String) -> bool: return step.begins_with("copy ")
	screen.load_button.pressed.emit()
	await _wait_for_transition()
	assert_object(get_tree().current_scene).is_same(previous)
	assert_bool(get_tree().paused).is_true()
	assert_bool(InputRouter.is_input_active(screen)).is_true()
	assert_str(screen.load_button.text).is_equal("Cannot prepare saved files.")
	assert_str(manager._active_slot).is_equal("A")
	assert_str(FileAccess.get_sha256(manager.legacy_player_file("temp"))).is_equal(hash_before)
	manager.storage.fail_before = Callable()
	screen.load_button.pressed.emit()
	await _wait_for_transition()
	assert_bool(get_tree().paused).is_false()
	assert_str(manager._active_slot).is_equal("1")


func test_no_loadable_slot_restarts_current_level_from_entry() -> void:
	assert_int(await manager.start_new_game(LEVEL)).is_equal(OK)
	await get_tree().process_frame
	var old_player := manager.get_player()
	old_player.global_position = Vector3(21, 35, -7)
	manager._current_world_dict = {"previous": true}
	assert_int(manager.save_temp_game()).is_equal(OK)
	_new_games = 0
	manager.new_game_started.connect(_record_new_game, CONNECT_ONE_SHOT)
	var screen := old_player.find_child("DeathScreen", true, false) as CogitoDeathScreen
	screen.open_death_screen()
	assert_bool(screen.label_active_slot.visible).is_false()
	screen.load_button.pressed.emit()
	await _wait_for_transition()
	assert_bool(is_instance_valid(old_player)).is_false()
	assert_int(_new_games).is_equal(1)
	assert_str(get_tree().current_scene.scene_file_path).is_equal(LEVEL)
	assert_float(manager.get_player().position.distance_to(Vector3.ZERO)).is_less(1.0)
	assert_bool(manager._current_world_dict.has("previous")).is_false()
	assert_array(DirAccess.get_files_at(manager.cogito_state_dir.path_join("temp"))).is_empty()
	assert_bool(manager.is_loaded_from_start_new_game).is_true()
	assert_str(manager._active_slot).is_empty()
	assert_bool(get_tree().paused).is_false()


func _record_new_game() -> void:
	_new_games += 1

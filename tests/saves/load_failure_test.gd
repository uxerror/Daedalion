extends "res://tests/saves/slot_fixture.gd"

const SIMPLE_STATE_SCRIPT := "res://addons/cogito/SceneManagement/cogito_player_simple_state.gd"
const SIMPLE_STATE_UID := "uid://j6wrecbyfem0"
const RETIRED_STATE_FIXTURE := "res://tests/saves/retired_player_state.res"

var _signals: Array[String] = []


func _observe_player(node: Node) -> void:
	if node is CogitoPlayer:
		node.player_state_loaded.connect(_record_load)


func _record_load() -> void:
	_signals.append(str(manager._current_world_dict.get("loaded")))


func test_missing_player_is_empty() -> void:
	assert_int(CogitoSceneState.new().write_state("missing", "A")).is_equal(OK)
	assert_int(manager.prepare_slot("missing").status).is_equal(manager.SlotStatus.EMPTY)
	var button := make_button("missing")
	assert_str(button.slot_name_label.text).is_equal(tr("TXT_EMPTY_SLOT"))


func test_truncated_player_shows_broken_slot() -> void:
	make_slot("B")
	var file := FileAccess.open(manager.legacy_player_file("B"), FileAccess.READ_WRITE)
	assert_int(file.resize(4)).is_equal(OK)
	file.close()
	var button := make_button("B")
	assert_int(button.slot_status).is_equal(manager.SlotStatus.BROKEN)
	assert_str(button.slot_name_label.text).is_not_equal(tr("TXT_EMPTY_SLOT"))
	assert_str(button.save_time_label.text).is_equal("Cannot read player state.")


func test_wrong_player_resource_class() -> void:
	make_slot("B")
	var path := manager.legacy_player_file("B")
	assert_int(ResourceSaver.save(CogitoSceneState.new(), path)).is_equal(OK)
	assert_int(manager.prepare_slot("B").status).is_equal(manager.SlotStatus.BROKEN)


func test_removed_simple_player_state_v2_shows_broken_slot() -> void:
	make_slot("B")
	var path := manager.player_file("B")
	var doc := {
		"format": "daedalion-save",
		"version": 2,
		"kind": "player",
		"engine": "4.7",
		"root": {"$local": 0},
		"resources":
		[
			{
				"class": "Resource",
				"script": {"$res": SIMPLE_STATE_UID, "path": SIMPLE_STATE_SCRIPT},
				"properties": {"player_current_scene": "CogitoPlayer"},
			},
		],
	}
	write_text(path, JSON.stringify(doc))
	var slot := manager.prepare_slot("B")
	assert_array(slot.warnings).contains_exactly(
		[{"path": SIMPLE_STATE_SCRIPT, "uid": SIMPLE_STATE_UID, "field": "player.script"}]
	)
	_assert_unreadable_player_slot(slot)


func test_removed_simple_player_state_legacy_shows_broken_slot() -> void:
	var path := manager.legacy_player_file("B")
	assert_int(DirAccess.make_dir_recursive_absolute(path.get_base_dir())).is_equal(OK)
	# Godot ResourceSaver wrote this CogitoPlayerSimpleState before the script was removed.
	assert_int(FileAccess.get_file_as_bytes(RETIRED_STATE_FIXTURE).size()).is_greater(0)
	assert_int(DirAccess.copy_absolute(RETIRED_STATE_FIXTURE, path)).is_equal(OK)
	_assert_unreadable_player_slot(manager.prepare_slot("B"))


func _assert_unreadable_player_slot(slot: CogitoSceneManager.PreparedSlot) -> void:
	assert_int(slot.status).is_equal(manager.SlotStatus.BROKEN)
	assert_str(slot.reason).is_equal("Cannot read player state.")
	var button := make_button(slot.slot)
	assert_int(button.slot_status).is_equal(manager.SlotStatus.BROKEN)
	assert_str(button.slot_name_label.text).is_not_equal(tr("TXT_EMPTY_SLOT"))
	assert_str(button.save_time_label.text).is_equal(slot.reason)


func test_unavailable_target_level(
	path: String,
	_test_parameters := [["res://missing-level.tscn"], ["res://addons/cogito/CogitoSettings.tres"]]
) -> void:
	var state := make_slot("B")
	state.player_current_scene_path = path
	assert_int(ResourceSaver.save(state, manager.legacy_player_file("B"))).is_equal(OK)
	assert_str(manager.prepare_slot("B").reason).is_equal("Saved level is unavailable.")


func test_bad_scene_preserves_active_slot_temp_and_level() -> void:
	manager._player_state = make_slot("A")
	var previous_state := manager._player_state
	make_slot("B")
	make_slot("temp")
	var previous_level := get_tree().current_scene
	var temp_hash := FileAccess.get_sha256(manager.legacy_player_file("temp"))
	write_text(manager.scene_file("B", "CogitoPlayer"), "invalid binary resource")
	assert_int(manager.prepare_slot("B").status).is_equal(manager.SlotStatus.BROKEN)
	var button := make_button("B")
	assert_int(await button.load_from_slot()).is_not_equal(OK)
	assert_str(button.save_time_label.text).is_equal("Cannot read level state.")
	assert_str(manager._active_slot).is_equal("A")
	assert_object(manager._player_state).is_same(previous_state)
	assert_object(get_tree().current_scene).is_same(previous_level)
	assert_str(FileAccess.get_sha256(manager.legacy_player_file("temp"))).is_equal(temp_hash)


func test_failed_temp_copy_preserves_running_game() -> void:
	make_slot("B")
	make_slot("temp")
	var previous_level := get_tree().current_scene
	var temp_hash := FileAccess.get_sha256(manager.legacy_player_file("temp"))
	manager.storage.fail_before = func(step: String) -> bool: return step.begins_with("copy ")
	assert_int(await manager.loading_saved_game("B")).is_not_equal(OK)
	assert_str(manager._active_slot).is_equal("A")
	assert_object(get_tree().current_scene).is_same(previous_level)
	assert_str(FileAccess.get_sha256(manager.legacy_player_file("temp"))).is_equal(temp_hash)


func test_requested_player_only_slot_applied_once() -> void:
	manager._player_state = make_slot("A")
	make_slot("B")
	make_slot("temp")
	var stale := manager.scene_file("temp", "OldLevel")
	write_text(stale, "old level")
	_signals.clear()
	get_tree().node_added.connect(_observe_player)
	assert_int(await manager.loading_saved_game("B")).is_equal(OK)
	await get_tree().create_timer(0.8).timeout
	get_tree().node_added.disconnect(_observe_player)
	assert_str(manager._active_slot).is_equal("B")
	assert_bool(FileAccess.file_exists(stale)).is_false()
	assert_str(manager.get_existing_player_state("temp").player_state_slot_name).is_equal("B")
	assert_array(_signals).contains_exactly(["B"])


func test_missing_png_and_legacy_external_png() -> void:
	var state := make_slot("B")
	var filename := manager.cogito_player_state_prefix + "B.png"
	state.player_state_screenshot_file = manager.cogito_state_dir.path_join(filename)
	assert_int(ResourceSaver.save(state, manager.legacy_player_file("B"))).is_equal(OK)
	var button := make_button("B")
	assert_int(button.slot_status).is_equal(manager.SlotStatus.OK)
	assert_object(button.screenshot_spot.texture).is_same(button.empty_slot_screenshot)
	var image := Image.create_empty(3, 2, false, Image.FORMAT_RGBA8)
	assert_int(image.save_png(state.player_state_screenshot_file)).is_equal(OK)
	button.refresh()
	assert_vector(button.screenshot_spot.texture.get_size()).is_equal(Vector2(3, 2))


func test_failed_threaded_load_keeps_current_level() -> void:
	var level := get_tree().current_scene
	var error := await manager.load_next_scene(
		"res://missing-level.tscn", "", "temp", manager.CogitoSceneLoadMode.TEMP
	)
	assert_int(error).is_not_equal(OK)
	assert_bool(manager.is_currently_loading).is_false()
	assert_object(get_tree().current_scene).is_same(level)
	assert_str(manager.last_slot_message).is_equal("Cannot open level.")


func test_rejected_threaded_request_keeps_current_level() -> void:
	var level := get_tree().current_scene
	var error := await manager.load_next_scene("", "", "temp", manager.CogitoSceneLoadMode.TEMP)
	assert_int(error).is_not_equal(OK)
	assert_bool(manager.is_currently_loading).is_false()
	assert_object(get_tree().current_scene).is_same(level)


func test_invalid_threaded_status_dismisses_loading_screen() -> void:
	var level := get_tree().current_scene
	var screen: CanvasLayer = manager._new_loading_screen()
	# No request owns this path, so the engine reports THREAD_LOAD_INVALID_RESOURCE.
	screen.set("next_scene_path", "user://no-threaded-request.tscn")
	manager.is_currently_loading = true
	get_tree().root.add_child(screen)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_bool(is_instance_valid(screen)).is_false()
	assert_bool(manager.is_currently_loading).is_false()
	assert_object(get_tree().current_scene).is_same(level)


func test_failed_saved_level_thread_preserves_menu_and_temp() -> void:
	var state := make_slot("B")
	make_slot("temp")
	var level_path := manager.cogito_state_dir.path_join("broken.tscn")
	write_text(level_path, "[gd_scene format=3]\n[ext_resource")
	state.player_current_scene_path = level_path
	assert_int(state.write_state("B")).is_equal(OK)
	assert_int(manager.prepare_slot("B").status).is_equal(manager.SlotStatus.OK)
	var previous_level := get_tree().current_scene
	var hash_before := FileAccess.get_sha256(manager.legacy_player_file("temp"))
	var button := make_button("B")
	assert_int(await button.load_from_slot()).is_not_equal(OK)
	assert_str(button.save_time_label.text).is_equal("Cannot open saved level.")
	assert_object(get_tree().current_scene).is_same(previous_level)
	assert_str(manager._active_slot).is_equal("A")
	assert_str(FileAccess.get_sha256(manager.legacy_player_file("temp"))).is_equal(hash_before)
	assert_bool(manager.is_currently_loading).is_false()
	make_slot("working")
	assert_int(await manager.loading_saved_game("working")).is_equal(OK)
	await get_tree().process_frame
	assert_str(manager._active_slot).is_equal("working")

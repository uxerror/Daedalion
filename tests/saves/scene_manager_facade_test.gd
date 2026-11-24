extends "res://tests/saves/slot_fixture.gd"
## Pins the autoload contract used by levels, menus and save resources.

const FACADE_METHODS := [
	"get_player",
	"restore_gameplay_mouse_mode",
	"register_player",
	"grab_screenshot",
	"send_player_hint",
	"player_file",
	"scene_file",
	"legacy_player_file",
	"legacy_scene_file",
	"get_existing_player_state",
	"prepare_slot",
	"slot_error",
	"loading_saved_game",
	"find_latest_loadable_slot",
	"restart_after_death",
	"activate_saved_slot",
	"apply_saved_game",
	"load_player_state",
	"write_state_resource",
	"slot_screenshot",
	"load_scene_state",
	"save_scene_state",
	"get_element_state_key",
	"find_element_state_node",
	"register_destroyed_node",
	"is_part_of_player",
	"load_next_scene",
	"start_new_game",
	"finish_transition",
	"transition_from_zone",
	"activate_new_game",
	"scene_load_failed",
	"delete_save",
	"delete_temp_saves",
	"find_object_from_uid",
	"starting_a_new_game",
	"save_game",
	"save_temp_game",
	"instantiate_fade_panel",
	"fade_in",
	"fade_out",
	"save_last_saved_slot",
	"delete_from_saved_slots",
	"get_last_saved_slot",
	"is_saved_slots_empty",
	"saved_slots_count",
	"max_saved_slot_nubmer",
	"is_saved_slot_exist",
]

const FACADE_FIELDS := [
	"_active_slot",
	"_current_world_dict",
	"_current_player_node",
	"_player_state",
	"_screenshot_to_save",
	"_current_sittable_node",
	"_current_scene_name",
	"_current_scene_path",
	"_scene_state",
	"_current_scene_root_node",
	"storage",
	"last_slot_message",
	"scene_load_mode",
	"cogito_state_dir",
	"cogito_scene_state_prefix",
	"cogito_player_state_prefix",
	"default_fade_duration",
	"fade_panel",
	"saves_data_file_path",
	"is_currently_loading",
	"is_loaded_from_start_new_game",
	"is_starting_new_game",
	"previous_menu",
	"previous_menu_button_pressed",
	"pause_menu",
	"game_menu",
	"save_load_menu",
	"_destroyed_nodes",
	"_destroyed_nodes_level_id",
]

const FACADE_SIGNALS := [
	"fade_finished",
	"update_gui",
	"new_game_started",
	"sit_requested",
	"stand_requested",
	"seat_move_requested",
]


class LegacyPersistNode:
	extends Node3D
	var uid: int


func test_facade_api() -> void:
	for method: String in FACADE_METHODS:
		assert_bool(manager.has_method(method)).override_failure_message(method).is_true()
	for field: String in FACADE_FIELDS:
		assert_bool(field in manager).override_failure_message(field).is_true()
	for event: String in FACADE_SIGNALS:
		assert_bool(manager.has_signal(event)).override_failure_message(event).is_true()
	assert_int(CogitoSceneManager.CogitoSceneLoadMode.TEMP).is_equal(0)
	assert_int(CogitoSceneManager.CogitoSceneLoadMode.LOAD_SAVE).is_equal(1)
	assert_int(CogitoSceneManager.CogitoSceneLoadMode.RESET).is_equal(2)
	var prepared := CogitoSceneManager.PreparedSlot.new()
	assert_int(prepared.status).is_equal(CogitoSceneManager.SlotStatus.BROKEN)


func test_index_promotes_existing_slots_and_deletes_from_history() -> void:
	assert_bool(manager.is_saved_slots_empty()).is_true()
	assert_str(manager.get_last_saved_slot()).is_empty()
	assert_int(manager.max_saved_slot_nubmer()).is_zero()
	for slot: String in ["2", "10", "2"]:
		assert_int(manager.save_last_saved_slot(slot)).is_equal(OK)
	assert_int(manager.saved_slots_count()).is_equal(2)
	assert_str(manager.get_last_saved_slot()).is_equal("2")
	assert_int(manager.max_saved_slot_nubmer()).is_equal(10)
	assert_bool(manager.is_saved_slot_exist("10")).is_true()
	assert_int(manager.delete_from_saved_slots("10")).is_equal(OK)
	assert_bool(manager.is_saved_slot_exist("10")).is_false()
	assert_int(manager.max_saved_slot_nubmer()).is_equal(2)
	assert_int(manager.delete_from_saved_slots("2")).is_equal(OK)
	assert_bool(manager.is_saved_slots_empty()).is_true()


func test_index_rejects_invalid_slot_names_and_stays_readable() -> void:
	assert_int(manager.save_last_saved_slot("1")).is_equal(OK)
	for slot: String in ["../invalid", "", ".hidden", "saves.data", "a/b"]:
		assert_int(manager.save_last_saved_slot(slot)).override_failure_message(slot).is_equal(
			ERR_INVALID_PARAMETER
		)
		assert_int(manager.delete_from_saved_slots(slot)).override_failure_message(slot).is_equal(
			ERR_INVALID_PARAMETER
		)
	assert_str(manager.get_last_saved_slot()).is_equal("1")
	assert_int(manager.saved_slots_count()).is_equal(1)


func test_delete_temp_and_named_slot_preserves_other_slots_and_history() -> void:
	make_slot("temp")
	make_slot("1")
	make_slot("2")
	var filename := manager.cogito_player_state_prefix + "1.png"
	var screenshot := manager.cogito_state_dir.path_join(filename)
	write_text(screenshot, "legacy screenshot")
	assert_int(manager.save_last_saved_slot("1")).is_equal(OK)
	assert_int(manager.delete_temp_saves()).is_equal(OK)
	var temp_dir := manager.cogito_state_dir.path_join("temp")
	assert_bool(DirAccess.dir_exists_absolute(temp_dir)).is_false()
	assert_bool(FileAccess.file_exists(manager.legacy_player_file("1"))).is_true()
	assert_int(manager.delete_save("1")).is_equal(OK)
	assert_bool(DirAccess.dir_exists_absolute(manager.cogito_state_dir.path_join("1"))).is_false()
	assert_bool(FileAccess.file_exists(screenshot)).is_false()
	assert_bool(FileAccess.file_exists(manager.legacy_player_file("2"))).is_true()
	assert_bool(manager.is_saved_slot_exist("1")).is_true()


func test_busy_guard_rejects_delete_and_scene_save() -> void:
	make_slot("1")
	manager.is_currently_loading = true
	assert_int(manager.delete_save("1")).is_equal(ERR_BUSY)
	assert_int(manager.save_scene_state("RunningLevel", "1")).is_equal(ERR_BUSY)
	assert_str(manager.last_slot_message).is_equal("Level transition in progress.")
	assert_bool(manager.is_currently_loading).is_true()
	assert_bool(FileAccess.file_exists(manager.legacy_player_file("1"))).is_true()
	assert_bool(FileAccess.file_exists(manager.scene_file("1", "RunningLevel"))).is_false()
	manager.finish_transition()
	assert_bool(manager.is_currently_loading).is_false()


func test_fades_emit_once_at_their_final_colour_before_returning() -> void:
	var original := manager.fade_panel.modulate
	var colours: Array[Color] = []
	var record := func() -> void: colours.append(manager.fade_panel.modulate)
	manager.fade_finished.connect(record)
	await manager.fade_out(0.01)
	assert_array(colours).contains_exactly([Color.BLACK])
	await manager.fade_in(0.01)
	assert_array(colours).contains_exactly([Color.BLACK, Color.TRANSPARENT])
	manager.fade_finished.disconnect(record)
	manager.fade_panel.modulate = original


func test_legacy_uid_lookup_only_searches_persist_group() -> void:
	var node := LegacyPersistNode.new()
	node.uid = 375
	get_tree().current_scene.add_child(node)
	assert_object(manager.find_object_from_uid(375)).is_null()
	node.add_to_group("Persist")
	assert_object(manager.find_object_from_uid(375)).is_same(node)
	assert_object(manager.find_object_from_uid(376)).is_null()


func test_destroyed_node_round_trip() -> void:
	var level := get_tree().current_scene
	manager._current_scene_root_node = level
	var node := Node3D.new()
	node.name = "Breakable"
	level.add_child(node)
	manager.register_destroyed_node(node)
	var key := {"cogito_id": "Breakable", "path": "."}
	assert_array(manager._get_destroyed_nodes()).contains_exactly([key])
	assert_int(manager.save_scene_state(level.name, "roundtrip")).is_equal(OK)
	manager._destroyed_nodes = []
	manager.load_scene_state(level.name, "roundtrip")
	assert_array(manager._get_destroyed_nodes()).contains_exactly([key])
	assert_bool(node.is_queued_for_deletion()).is_true()
	await node.tree_exited
	await get_tree().process_frame
	assert_bool(level.has_node("Breakable")).is_false()


func test_slot_screenshot_returns_supplied_placeholder() -> void:
	var placeholder := GradientTexture1D.new()
	var state := CogitoPlayerSimpleState.new()
	assert_object(manager.slot_screenshot(null, placeholder)).is_same(placeholder)
	assert_object(manager.slot_screenshot(state, placeholder)).is_same(placeholder)
	state.player_state_screenshot_file = manager.cogito_state_dir.path_join("missing.png")
	assert_object(manager.slot_screenshot(state, placeholder)).is_same(placeholder)

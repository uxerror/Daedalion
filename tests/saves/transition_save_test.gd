extends "res://tests/saves/slot_fixture.gd"

const ZONE := preload("res://addons/cogito/Scripts/scene_transition_zone.gd")
const DESTINATION := "res://tests/saves/transition_level.tscn"

var _restores := 0
var _save_during_apply: Error


func _observe_player(node: Node) -> void:
	if node is CogitoPlayer:
		node.player_state_loaded.connect(_during_apply)


func _during_apply() -> void:
	_restores += 1
	_save_during_apply = manager.save_game("during-apply")


func test_zone_owns_fade_load_and_restore() -> void:
	make_slot("1")
	assert_int(await manager.loading_saved_game("1")).is_equal(OK)
	await get_tree().process_frame
	var player := manager.get_player()
	player.player_attributes["health"].set_attribute(27, 90)
	player.global_position = Vector3(5, 4, 3)
	var zone := ZONE.new()
	player.add_child(zone)
	zone.target_scene_path = DESTINATION
	zone.target_connector = "Arrival"
	_restores = 0
	get_tree().node_added.connect(_observe_player)
	zone.transition_to_next_scene()
	assert_bool(manager.is_currently_loading).is_true()
	var departed := FileAccess.get_sha256(manager.player_file("temp"))
	assert_int(await zone.transition_to_next_scene()).is_equal(ERR_BUSY)
	assert_int(await manager.loading_saved_game("1")).is_equal(ERR_BUSY)
	assert_int(await manager.start_new_game(LEVEL)).is_equal(ERR_BUSY)
	assert_int(manager.save_game("manual")).is_equal(ERR_BUSY)
	assert_int(manager._save_autosave_state()).is_equal(ERR_BUSY)
	assert_str(FileAccess.get_sha256(manager.player_file("temp"))).is_equal(departed)
	var deadline := Time.get_ticks_msec() + 5000
	while manager.is_currently_loading and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	get_tree().node_added.disconnect(_observe_player)
	assert_bool(manager.is_currently_loading).is_false()
	assert_int(_restores).is_equal(1)
	assert_int(_save_during_apply).is_equal(ERR_BUSY)
	assert_int(manager.prepare_slot("manual").status).is_equal(manager.SlotStatus.EMPTY)
	var saved := manager.prepare_slot("temp")
	assert_int(saved.status).is_equal(manager.SlotStatus.OK)
	assert_str(saved.player.player_current_scene).is_equal("Destination")
	assert_vector(saved.player.player_position).is_equal(Vector3(17, 12, -3))
	assert_vector(saved.player.player_attributes["health"]).is_equal(Vector2(27, 90))


func test_failed_load_releases_guard_and_double_load_applies_once() -> void:
	assert_int(await manager.loading_saved_game("absent")).is_equal(ERR_FILE_CANT_READ)
	assert_bool(manager.is_currently_loading).is_false()
	var mode := manager.CogitoSceneLoadMode.TEMP
	assert_int(await manager.load_next_scene("", "", "temp", mode)).is_equal(ERR_FILE_BAD_PATH)
	assert_bool(manager.is_currently_loading).is_false()
	make_slot("B")
	manager.storage.fail_before = func(step: String) -> bool: return step.begins_with("copy ")
	assert_int(await manager.loading_saved_game("B")).is_not_equal(OK)
	assert_bool(manager.is_currently_loading).is_false()
	manager.storage.fail_before = Callable()
	_restores = 0
	get_tree().node_added.connect(_observe_player)
	manager.loading_saved_game("B")
	assert_int(await manager.loading_saved_game("B")).is_equal(ERR_BUSY)
	var deadline := Time.get_ticks_msec() + 5000
	while manager.is_currently_loading and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	get_tree().node_added.disconnect(_observe_player)
	assert_bool(manager.is_currently_loading).is_false()
	assert_int(_restores).is_equal(1)
	assert_str(manager._active_slot).is_equal("B")
	assert_int(manager.save_game("manual")).is_equal(OK)

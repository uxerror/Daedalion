extends "res://tests/saves/slot_fixture.gd"

const MAIN_MENU := preload("res://addons/cogito/EasyMenus/Scenes/main_menu.tscn")
const PAUSE_MENU := preload("res://addons/cogito/EasyMenus/Scenes/PauseMenu.tscn")

var _first_level: PackedScene


func before_test() -> void:
	super()
	_first_level = CogitoGlobals.cogito_settings.new_game_start_scene
	CogitoGlobals.cogito_settings.new_game_start_scene = load(LEVEL)


func after_test() -> void:
	CogitoGlobals.cogito_settings.new_game_start_scene = _first_level
	get_tree().paused = false
	super()


func test_new_game_from_menu(from_pause: bool, _test_parameters := [[false], [true]]) -> void:
	var manual := make_slot("1")
	var autosave := CogitoGlobals.cogito_settings.auto_save_name
	make_slot(autosave)
	assert_int(manager.save_last_saved_slot("1")).is_equal(OK)
	var manual_hash := FileAccess.get_sha256(manager.legacy_player_file("1"))
	var auto_hash := FileAccess.get_sha256(manager.legacy_player_file(autosave))
	var index_hash := FileAccess.get_sha256(manager.saves_data_file_path)
	make_slot("temp")
	manager._scene_state = CogitoSceneState.new()
	assert_int(manager._scene_state.write_state("temp", "SecondLevel")).is_equal(OK)
	# Simulate a crash after the working generation was moved aside.
	var root := manager.cogito_state_dir
	assert_int(DirAccess.rename_absolute(root + "temp", root + ".previous-temp")).is_equal(OK)
	manager._active_slot = "1"
	manager._player_state = manual
	manager._current_world_dict = {"from_previous_run": true}
	manager._current_sittable_node = get_tree().current_scene
	manager._destroyed_nodes = [{"path": "OldObject"}]
	manager._destroyed_nodes_level_id = 123
	manager._screenshot_to_save = Image.create_empty(2, 2, false, Image.FORMAT_RGB8)
	var quest := CogitoQuest.new()
	var objective := CogitoQuestObjective.new()
	objective.objective_state = CogitoQuestObjective.ObjectiveState.Hidden
	quest.quest_objectives.append(objective)
	quest.start(true)
	objective.objective_state = CogitoQuestObjective.ObjectiveState.Completed
	CogitoQuestManager.active.add_quest(quest)
	CogitoQuestManager.completed.add_quest(CogitoQuest.new())
	CogitoQuestManager.failed.add_quest(CogitoQuest.new())

	var menu := (PAUSE_MENU if from_pause else MAIN_MENU).instantiate()
	get_tree().current_scene.add_child(menu)
	await menu.call("start_new_game")
	await get_tree().process_frame
	assert_object(manager.get_player()).is_not_null()
	assert_bool(get_tree().paused).is_false()
	assert_array(DirAccess.get_files_at(root + "temp")).is_empty()
	assert_bool(DirAccess.dir_exists_absolute(root + ".previous-temp")).is_false()
	assert_array(CogitoQuestManager.active.quests).is_empty()
	assert_array(CogitoQuestManager.completed.quests).is_empty()
	assert_array(CogitoQuestManager.failed.quests).is_empty()
	assert_int(quest.quest_state).is_equal(CogitoQuest.QuestState.NotStarted)
	assert_int(objective.objective_state).is_equal(CogitoQuestObjective.ObjectiveState.Hidden)
	assert_dict(manager._current_world_dict).is_equal(
		CogitoGlobals.cogito_settings.get_new_game_world_dict()
	)
	assert_array(manager._destroyed_nodes).is_empty()
	assert_int(manager._destroyed_nodes_level_id).is_zero()
	assert_object(manager._current_sittable_node).is_null()
	assert_object(manager._screenshot_to_save).is_null()
	assert_object(manager._player_state).is_null()
	assert_object(manager._scene_state).is_null()
	assert_str(manager._active_slot).is_empty()
	assert_bool(manager.is_starting_new_game).is_false()
	assert_bool(manager.is_loaded_from_start_new_game).is_true()
	manager.load_scene_state("SecondLevel", "temp")
	assert_object(manager._scene_state).is_null()
	assert_str(FileAccess.get_sha256(manager.legacy_player_file("1"))).is_equal(manual_hash)
	assert_str(FileAccess.get_sha256(manager.legacy_player_file(autosave))).is_equal(auto_hash)
	assert_str(FileAccess.get_sha256(manager.saves_data_file_path)).is_equal(index_hash)


func test_failed_new_game_preserves_playthrough_and_can_retry_on_empty_temp() -> void:
	make_slot("temp")
	manager._current_world_dict = {"previous": true}
	manager.storage.fail_before = func(step: String) -> bool: return step == "publish staging"
	assert_int(await manager.start_new_game(LEVEL)).is_not_equal(OK)
	assert_bool(FileAccess.file_exists(manager.legacy_player_file("temp"))).is_true()
	assert_dict(manager._current_world_dict).contains_keys(["previous"])
	manager.storage.fail_before = Callable()
	for attempt in range(2):
		assert_int(await manager.start_new_game(LEVEL)).is_equal(OK)
		await get_tree().process_frame
		assert_array(DirAccess.get_files_at(manager.cogito_state_dir + "temp")).is_empty()

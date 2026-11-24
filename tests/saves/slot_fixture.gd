extends GdUnitTestSuite

const LEVEL := "res://addons/cogito/PackedScenes/cogito_player_simple.tscn"
const BUTTON := preload("res://addons/cogito/EasyMenus/Components/SaveSlotButton.tscn")

var manager := CogitoSceneManager
var _previous: Dictionary
var _previous_world: Dictionary
var _original_level: Node
var _original_mouse: Input.MouseMode


func before_test() -> void:
	_original_level = get_tree().current_scene
	_original_mouse = Input.mouse_mode
	_previous_world = manager._current_world_dict.duplicate(true)
	for key: String in [
		"storage",
		"cogito_state_dir",
		"saves_data_file_path",
		"_current_scene_name",
		"_current_scene_path",
		"_current_scene_root_node",
		"_current_player_node",
		"_active_slot",
		"_player_state",
		"_scene_state",
		"_screenshot_to_save",
		"_current_sittable_node",
		"_destroyed_nodes",
		"_destroyed_nodes_level_id",
		"scene_load_mode",
		"is_starting_new_game",
		"is_loaded_from_start_new_game",
		"is_currently_loading",
		"last_slot_message",
	]:
		_previous[key] = manager.get(key)
	manager.cogito_state_dir = "user://slot-tests-%d/" % Time.get_ticks_usec()
	manager.storage = manager.SlotStorage.new(manager.cogito_state_dir)
	assert_int(manager.storage.recover_all()).is_equal(OK)
	manager.saves_data_file_path = manager.cogito_state_dir.path_join("saves.data")
	manager._active_slot = "A"
	var level := Node3D.new()
	level.name = "RunningLevel"
	get_tree().root.add_child(level)
	get_tree().current_scene = level


func after_test() -> void:
	var level := get_tree().current_scene
	var player := manager.get_player()
	if player is CogitoPlayerSimple:
		InputRouter.remove(player.on_input)
	get_tree().current_scene = _original_level
	level.free()
	for key: String in _previous:
		manager.set(key, _previous[key])
	manager._current_world_dict = _previous_world
	Input.mouse_mode = _original_mouse


func make_slot(slot: String) -> CogitoPlayerSimpleState:
	var directory := manager.cogito_state_dir.path_join(slot)
	assert_int(DirAccess.make_dir_recursive_absolute(directory)).is_equal(OK)
	var state := CogitoPlayerSimpleState.new()
	state.player_current_scene = "CogitoPlayer"
	state.player_current_scene_path = LEVEL
	state.player_state_slot_name = slot
	state.player_inventory = CogitoInventory.new()
	state.world_dictionary = {"loaded": slot}
	assert_int(ResourceSaver.save(state, manager.legacy_player_file(slot))).is_equal(OK)
	return state


func write_text(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_object(file).is_not_null()
	assert_bool(file.store_string(contents)).is_true()
	file.close()


func make_button(slot: String) -> CogitoSaveSlotButton:
	var button: CogitoSaveSlotButton = auto_free(BUTTON.instantiate())
	add_child(button)
	button.manual_save_slot_name = slot
	button.refresh()
	return button

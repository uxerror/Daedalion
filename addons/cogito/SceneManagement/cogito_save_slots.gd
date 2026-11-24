extends RefCounted
## Captures, publishes, activates and deletes save generations.

const Manager := preload("cogito_scene_manager.gd")

var _manager: Manager


func _init(manager: Manager) -> void:
	_manager = manager


func slot_error(message: String, detail: String, error := FAILED) -> Error:
	_manager.last_slot_message = message
	push_warning("%s %s (%s)" % [message, detail, error_string(error)])
	CogitoGlobals.debug_log(true, "CSM", detail)
	return error


## Ties prefer the latest manual history entry, then a directory name, then autosave.
func find_latest_loadable_slot() -> Manager.PreparedSlot:
	var candidates := _manager._save_index.saved_slots()
	candidates.reverse()
	var autosave := CogitoGlobals.cogito_settings.auto_save_name
	candidates.erase(autosave)
	for slot in DirAccess.get_directories_at(_manager.cogito_state_dir):
		if slot != autosave and not candidates.has(slot):
			candidates.append(slot)
	candidates.append(autosave)
	var latest: Manager.PreparedSlot = null
	for slot: String in candidates:
		if slot == "temp" or not _manager.storage.valid_slot(slot):
			continue
		var candidate := _manager.prepare_slot(slot)
		if candidate.status != Manager.SlotStatus.OK:
			continue
		if not latest or candidate.save_time > latest.save_time:
			latest = candidate
	return latest


## Called only after the threaded level was successfully instantiated. Until the
## temp generation is published both the current game and its menus remain live.
func activate_saved_slot(prepared: Manager.PreparedSlot) -> Error:
	if prepared.slot != "temp":
		var error := _manager.storage.replace("temp", prepared.slot)
		if error != OK:
			return slot_error("Cannot prepare saved files.", prepared.slot, error)
	if not prepared.scene:
		push_warning("No level state in slot %s. Loading the original level." % prepared.slot)
	_manager._active_slot = prepared.slot
	_manager.is_loaded_from_start_new_game = false
	_manager.scene_load_mode = Manager.CogitoSceneLoadMode.LOAD_SAVE
	return OK


func apply_saved_game(prepared: Manager.PreparedSlot) -> void:
	_manager._scene_state = prepared.scene
	if _manager._scene_state:
		_manager._scene_persistence.apply(prepared.scene)
	_manager._player_persistence.apply(_manager.get_player(), prepared.player)
	_manager._slot_files.show_save_warnings(prepared)


## Capture temp, manual and automatic saves with the same directory transaction.
## Only a manual save promotes its slot in the existing Continue menu history.
func save_game(slot: String, update_history := true) -> Error:
	if _manager.is_currently_loading:
		return _manager._transitions.reject_busy()
	return save_generation(slot, update_history)


func save_generation(slot: String, update_history: bool) -> Error:
	var player := _manager.get_player()
	var level := _manager.get_tree().current_scene
	if not player or not level or not _manager.storage.valid_slot(slot):
		return slot_error("Cannot save game.", slot, ERR_INVALID_PARAMETER)
	_manager._current_scene_name = level.name
	_manager._current_scene_path = level.scene_file_path
	var state := player.create_new_state()
	state.populate_save_data(player, slot)
	var scene := _manager._scene_persistence.capture(level)
	var shot: Image = _manager._screenshot_to_save if slot != "temp" else null
	if shot:
		var directory := _manager.cogito_state_dir.path_join(slot)
		state.player_state_screenshot_file = directory.path_join("screenshot.png")
	var writer := _write_generation.bind(state, scene, shot)
	var skip := PackedStringArray(
		[
			_manager.player_file(slot).get_file(),
			_manager.scene_file(slot, level.name).get_file(),
			"screenshot.png",
			_manager.legacy_player_file(slot).get_file(),
			_manager.legacy_scene_file(slot, level.name).get_file(),
		]
	)
	var promote := _manager.save_last_saved_slot.bind(slot) if update_history else Callable()
	var error := _manager.storage.recover("temp")
	if error == OK:
		var temp_dir := _manager.cogito_state_dir.path_join("temp")
		var source := "temp" if DirAccess.dir_exists_absolute(temp_dir) else ""
		error = _manager.storage.replace(slot, source, writer, skip, promote)
	if error != OK:
		return slot_error("Save failed.", slot, error)
	if update_history:
		_manager._active_slot = slot
		_manager.is_loaded_from_start_new_game = false
	_manager._player_state = state
	_manager._scene_state = scene
	return OK


func _write_generation(
	directory: String, player: CogitoPlayerState, scene: CogitoSceneState, shot: Image
) -> Error:
	var staging := directory.get_file()
	var error := _manager.storage.before("write player")
	if error == OK:
		error = player.write_state(staging)
	if error == OK:
		error = _manager.storage.before("write current scene")
	if error == OK:
		error = scene.write_state(staging, player.player_current_scene)
	if error == OK:
		error = _upgrade_visited_scenes(staging)
	if error == OK and shot:
		error = _manager.storage.before("write screenshot")
		if error == OK:
			var path := directory.path_join("screenshot.png")
			error = _manager.storage.check(shot.save_png(path), path)
	if error != OK:
		return error
	# Verify the freshly serialized states before sealing staging.
	var verified := _manager._slot_files.prepare_files(staging)
	if verified.status != Manager.SlotStatus.OK or not verified.scene:
		return _manager.storage.check(ERR_FILE_CORRUPT, directory + " " + verified.reason)
	return OK


## Convert previously visited levels in staging. On any error replace() discards
## this generation and preserves the live slot, including its legacy files.
func _upgrade_visited_scenes(staging: String) -> Error:
	var directory := _manager.cogito_state_dir.path_join(staging)
	for file in DirAccess.get_files_at(directory):
		if not file.begins_with(_manager.cogito_scene_state_prefix) or not file.ends_with(".res"):
			continue
		var level := file.trim_prefix(_manager.cogito_scene_state_prefix).trim_suffix(".res")
		var legacy := directory.path_join(file)
		var path := _manager.scene_file(staging, level)
		if not FileAccess.file_exists(path):
			var resource := ResourceLoader.load(legacy, "", ResourceLoader.CACHE_MODE_IGNORE)
			var scene := resource as CogitoSceneState
			if not scene:
				return _manager.storage.check(ERR_FILE_CORRUPT, legacy)
			var error := scene.write_state(staging, level)
			if error != OK:
				return error
		var removed := DirAccess.remove_absolute(legacy)
		if removed != OK:
			return _manager.storage.check(removed, legacy)
	return OK


func save_temp_game() -> Error:
	var error := save_game("temp", false)
	if error != OK and _manager.get_player():
		_manager.send_player_hint(null, _manager.last_slot_message)
	return error


func save_autosave_state() -> Error:
	if _manager.is_currently_loading:
		return _manager._transitions.reject_busy()
	if not _manager._screenshot_to_save:
		_manager._screenshot_to_save = _manager.grab_screenshot(CogitoGlobals.screenshot_scale)
	var error := save_game(CogitoGlobals.cogito_settings.auto_save_name, false)
	if error != OK and _manager.get_player():
		_manager.send_player_hint(null, _manager.last_slot_message)
	return error


func delete_save(slot: String) -> Error:
	if _manager.is_currently_loading:
		return _manager._transitions.reject_busy()
	var error := _manager.storage.recover(slot)
	if error != OK:
		return error
	var directory := _manager.cogito_state_dir.path_join(slot)
	if DirAccess.dir_exists_absolute(directory):
		error = OS.move_to_trash(ProjectSettings.globalize_path(directory))
		if error != OK:
			return _manager.storage.check(error, directory)
	var filename := _manager.cogito_player_state_prefix + slot + ".png"
	var external_png := _manager.cogito_state_dir.path_join(filename)
	if FileAccess.file_exists(external_png):
		error = OS.move_to_trash(ProjectSettings.globalize_path(external_png))
	return _manager.storage.check(error, external_png)


func delete_temp_saves() -> Error:
	var error := _manager.storage.recover("temp")
	if error == OK:
		error = _manager.storage.remove_directory(_manager.cogito_state_dir.path_join("temp"))
	return error

extends RefCounted
## Resolves slot filenames, reads v2 or legacy states and verifies prepared slots.

const Manager := preload("cogito_scene_manager.gd")

var _manager: Manager


func _init(manager: Manager) -> void:
	_manager = manager


func _directory(slot: String) -> String:
	return _manager.cogito_state_dir.path_join(slot)


func player_file(slot: String) -> String:
	return _directory(slot).path_join("player_state" + Manager.SaveCodec.SUFFIX)


func scene_file(slot: String, level_name: String) -> String:
	return _directory(slot).path_join("scene_" + level_name + Manager.SaveCodec.SUFFIX)


func legacy_player_file(slot: String) -> String:
	return _directory(slot).path_join(_manager.cogito_player_state_prefix + ".res")


func legacy_scene_file(slot: String, level_name: String) -> String:
	return _directory(slot).path_join(_manager.cogito_scene_state_prefix + level_name + ".res")


func read_state(
	path: String, legacy: String, kind: String, report: Manager.PreparedSlot
) -> Resource:
	if FileAccess.file_exists(path):
		var codec := Manager.SaveCodec.new()
		var state := codec.read(path, kind)
		report.warnings.append_array(codec.warnings)
		report.reason = codec.reason
		return state
	if FileAccess.file_exists(legacy):
		return ResourceLoader.load(legacy, "", ResourceLoader.CACHE_MODE_IGNORE)
	return null


func prepare_slot(slot: String) -> Manager.PreparedSlot:
	if _manager.storage.recover(slot) != OK:
		var result := Manager.PreparedSlot.new()
		result.reason = "Cannot access save slot."
		return result
	return prepare_files(slot)


func prepare_files(slot: String) -> Manager.PreparedSlot:
	var result := Manager.PreparedSlot.new()
	result.slot = slot
	var path := player_file(slot)
	var dir_path := path.get_base_dir()
	var directory := DirAccess.open(dir_path)
	if not directory:
		var parent := DirAccess.open(_manager.cogito_state_dir)
		if not parent or parent.get_directories().has(slot) or parent.file_exists(slot):
			result.reason = "Cannot access save slot."
			return result
	var files := directory.get_files() if directory else PackedStringArray()
	var legacy := legacy_player_file(slot)
	if not files.has(path.get_file()) and not files.has(legacy.get_file()):
		result.status = Manager.SlotStatus.EMPTY
		result.reason = "Empty slot."
		return result
	result.player = read_state(path, legacy, "player", result) as CogitoPlayerState
	if not _validate_player(result):
		return result
	var level_name := result.player.player_current_scene
	path = scene_file(slot, level_name)
	legacy = legacy_scene_file(slot, level_name)
	if files.has(path.get_file()) or files.has(legacy.get_file()):
		result.scene = read_state(path, legacy, "scene", result) as CogitoSceneState
		if not result.scene:
			if result.reason.is_empty():
				result.reason = "Cannot read level state."
			return result
	result.status = Manager.SlotStatus.OK
	result.save_time = result.player.player_state_savetime
	if result.save_time <= 0:
		var player_path := player_file(slot)
		if not FileAccess.file_exists(player_path):
			player_path = legacy_player_file(slot)
		result.save_time = FileAccess.get_modified_time(player_path)
	return result


func _validate_player(result: Manager.PreparedSlot) -> bool:
	if not result.player:
		if result.reason.is_empty():
			result.reason = "Cannot read player state."
		return false
	var level_path := ResourceUID.ensure_path(result.player.player_current_scene_path)
	if (
		level_path.is_empty()
		or not ResourceLoader.get_recognized_extensions_for_type("PackedScene").has(
			level_path.get_extension()
		)
		or not Manager.SaveCodec.file_exists(level_path, "PackedScene")
	):
		result.reason = "Saved level is unavailable."
		return false
	if not result.player.player_current_scene.is_valid_filename():
		result.reason = "Invalid saved level name."
		return false
	return true


func write_state_resource(state: Resource, path: String) -> Error:
	var error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if error == OK:
		var kind := "player" if state is CogitoPlayerState else "scene"
		error = Manager.SaveCodec.new().write(state, path, kind)
	return _manager.storage.check(error, path)


func slot_screenshot(state: CogitoPlayerState, placeholder: Texture2D) -> Texture2D:
	if (
		state
		and not state.player_state_screenshot_file.is_empty()
		and FileAccess.file_exists(state.player_state_screenshot_file)
	):
		var image := Image.load_from_file(state.player_state_screenshot_file)
		if image and not image.is_empty():
			return ImageTexture.create_from_image(image)
	return placeholder


func show_save_warnings(report: Manager.PreparedSlot) -> void:
	for entry: Dictionary in report.warnings:
		push_warning("Could not restore %s (%s) at %s" % [entry.path, entry.uid, entry.field])
	if not report.warnings.is_empty() and _manager.get_player():
		_manager.send_player_hint(null, "Some saved items could not be restored.")

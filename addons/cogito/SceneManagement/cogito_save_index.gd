extends RefCounted
## Reads and atomically updates the ordered manual slot history in saves.data.

const Manager := preload("cogito_scene_manager.gd")

var _manager: Manager


func _init(manager: Manager) -> void:
	_manager = manager


func _load_index(config: ConfigFile) -> Error:
	var error := config.load(_manager.saves_data_file_path)
	if error == ERR_FILE_NOT_FOUND:
		return OK
	if error != OK:
		return _manager.storage.check(error, _manager.saves_data_file_path)
	var slots: Variant = config.get_value("save", "slots", false)
	if not slots is Array:
		return _manager.storage.check(ERR_INVALID_DATA, _manager.saves_data_file_path)
	for slot: Variant in slots:
		if not slot is String or not _manager.storage.valid_slot(slot):
			return _manager.storage.check(ERR_INVALID_DATA, _manager.saves_data_file_path)
	return OK


func _update_index(slot: String, promote: bool) -> Error:
	# A name the loader rejects would make the whole history unreadable.
	if not _manager.storage.valid_slot(slot):
		return _manager.storage.check(ERR_INVALID_PARAMETER, "slot name '%s'" % slot)
	var config := ConfigFile.new()
	var error := _load_index(config)
	if error != OK:
		return error
	var slots: Array = config.get_value("save", "slots", [])
	slots.erase(slot)
	if promote:
		slots.append(slot)
	config.set_value("save", "slots", slots)
	var pending := _manager.saves_data_file_path.get_base_dir().path_join(".saves-index.next")
	error = _manager.storage.before("write index")
	if error == OK:
		error = _manager.storage.check(config.save(pending), pending)
	if error == OK:
		var verified := ConfigFile.new()
		error = _manager.storage.check(verified.load(pending), pending)
		if error == OK and verified.encode_to_text() != config.encode_to_text():
			error = _manager.storage.check(ERR_FILE_CORRUPT, pending)
	if error == OK:
		error = _manager.storage.before("publish index")
	if error == OK:
		var path := _manager.saves_data_file_path
		error = _manager.storage.check(DirAccess.rename_absolute(pending, path), path)
	if error != OK and FileAccess.file_exists(pending):
		_manager.storage.check(DirAccess.remove_absolute(pending), pending)
	return error


func save_last_saved_slot(slot: String) -> Error:
	return _update_index(slot, true)


func delete_from_saved_slots(slot: String) -> Error:
	return _update_index(slot, false)


func saved_slots() -> Array:
	var config := ConfigFile.new()
	if _load_index(config) != OK:
		return []
	return config.get_value("save", "slots", [])


func get_last_saved_slot() -> String:
	var slots := saved_slots()
	return "" if slots.is_empty() else slots.back()


func is_saved_slots_empty() -> bool:
	# Quick Load starts a new game for an empty history. A read error must
	# keep that action from clearing the current playthrough.
	var config := ConfigFile.new()
	return _load_index(config) == OK and config.get_value("save", "slots", []).is_empty()


func saved_slots_count() -> int:
	return saved_slots().size()


func max_saved_slot_nubmer() -> int:
	var highest := 0
	for slot: String in saved_slots():
		highest = maxi(highest, int(slot))
	return highest


func is_saved_slot_exist(slot: String) -> bool:
	return slot in saved_slots()

extends RefCounted
## Loads player state and applies it to the registered player before starting the fade.

const Manager := preload("cogito_scene_manager.gd")

var _manager: Manager


func _init(manager: Manager) -> void:
	_manager = manager


func get_existing_player_state(slot: String) -> CogitoPlayerState:
	if not _manager.storage.valid_slot(slot):
		return null
	return _read_player(slot, Manager.PreparedSlot.new())


func load_player_state(player: CogitoPlayer, slot: String) -> void:
	if not _manager.storage.valid_slot(slot):
		return
	var report := Manager.PreparedSlot.new()
	var state := _read_player(slot, report)
	if state:
		apply(player, state)
		_manager._slot_files.show_save_warnings(report)


func _read_player(slot: String, report: Manager.PreparedSlot) -> CogitoPlayerState:
	var path := _manager.player_file(slot)
	var legacy := _manager.legacy_player_file(slot)
	return _manager._slot_files.read_state(path, legacy, "player", report) as CogitoPlayerState


func apply(player: CogitoPlayer, state: CogitoPlayerState) -> void:
	if not player:
		push_warning("No player registered in the loaded level.")
		return
	_manager._player_state = state
	state.populate_player_data(player)
	player.player_state_loaded.emit()
	_manager.fade_in()

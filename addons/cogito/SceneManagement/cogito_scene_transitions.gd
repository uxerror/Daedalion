extends RefCounted
## Owns the transition guard and coordinates level changes, new games and death restarts.

const Manager := preload("cogito_scene_manager.gd")

var _manager: Manager
var _busy_reported := false


func _init(manager: Manager) -> void:
	_manager = manager


func load_next_scene(
	target: String,
	connector_name: String,
	passed_slot: String,
	load_mode: Manager.CogitoSceneLoadMode
) -> Error:
	if load_mode == Manager.CogitoSceneLoadMode.LOAD_SAVE:
		return await loading_saved_game(passed_slot)
	if not _begin_transition():
		return ERR_BUSY
	return await _open_level(target, connector_name, load_mode)


func loading_saved_game(slot: String) -> Error:
	if not _begin_transition():
		return ERR_BUSY
	var prepared := _manager.prepare_slot(slot)
	if prepared.status != Manager.SlotStatus.OK:
		finish_transition()
		return _manager.slot_error(prepared.reason, slot, ERR_FILE_CANT_READ)
	return await _load_prepared_slot(prepared)


func restart_after_death() -> Error:
	if CogitoNet.is_online():
		return ERR_UNAVAILABLE
	if not _begin_transition():
		return ERR_BUSY
	var latest := _manager.find_latest_loadable_slot()
	if latest:
		return await _load_prepared_slot(latest)
	var level := _manager.get_tree().current_scene
	return await _start_new_game(level.scene_file_path if level else "")


## Without an explicit level, start at the configured first level.
func start_new_game(level_path := "") -> Error:
	if not _begin_transition():
		return ERR_BUSY
	return await _start_new_game(level_path)


func _start_new_game(level_path: String) -> Error:
	if level_path.is_empty() and CogitoGlobals.cogito_settings.new_game_start_scene:
		level_path = CogitoGlobals.cogito_settings.new_game_start_scene.resource_path
	return await _open_level(level_path, "", Manager.CogitoSceneLoadMode.RESET, null, true)


func _begin_transition() -> bool:
	if _manager.is_currently_loading:
		reject_busy()
		return false
	_manager.is_currently_loading = true
	_busy_reported = false
	return true


func reject_busy() -> Error:
	_manager.last_slot_message = "Level transition in progress."
	if not _busy_reported:
		_busy_reported = true
		push_warning(_manager.last_slot_message)
	return ERR_BUSY


func finish_transition() -> void:
	_manager.is_currently_loading = false


## The zone owns the transition from the outgoing snapshot through the fade and level change.
func transition_from_zone(target: String, connector_name: String) -> Error:
	if not _begin_transition():
		return ERR_BUSY
	var error := _manager._slots.save_generation("temp", false)
	if error != OK:
		finish_transition()
		if _manager.get_player():
			_manager.send_player_hint(null, _manager.last_slot_message)
		return error
	await _manager.fade_out()
	return await _open_level(target, connector_name, Manager.CogitoSceneLoadMode.TEMP)


func _open_level(
	target: String,
	connector_name: String,
	load_mode: Manager.CogitoSceneLoadMode,
	prepared: Manager.PreparedSlot = null,
	new_game := false
) -> Error:
	var screen := new_loading_screen()
	if not screen:
		scene_load_failed(target, ERR_CANT_CREATE, "Cannot open loading screen.")
		return ERR_CANT_CREATE
	screen.next_scene_path = target
	screen.connector_name = connector_name
	screen.load_mode = load_mode
	screen.prepared_slot = prepared
	screen.new_game = new_game
	var error: Error = screen.request_scene()
	if error != OK:
		screen.free()
		if prepared:
			finish_transition()
			return _manager.slot_error("Cannot open saved level.", target, error)
		scene_load_failed(target, error)
		return error
	_manager.get_tree().root.add_child(screen)
	return await screen.save_load_ready


# Function to transition to another scene via the loading screen.
func new_loading_screen() -> CanvasLayer:
	var packed := load(CogitoGlobals.cogito_settings.loading_screen_scene_path) as PackedScene
	if not packed or not packed.can_instantiate():
		return null
	var screen := packed.instantiate()
	if screen is CanvasLayer and screen.has_method("request_scene"):
		return screen
	if screen:
		screen.free()
	return null


func _load_prepared_slot(prepared: Manager.PreparedSlot) -> Error:
	return await _open_level(
		prepared.player.player_current_scene_path,
		"",
		Manager.CogitoSceneLoadMode.LOAD_SAVE,
		prepared
	)


## Commit the reset only once the replacement level has been instantiated.
func activate_new_game() -> Error:
	var error := _manager.storage.replace("temp", "")
	if error != OK:
		return _manager.slot_error("Cannot reset working save.", "temp", error)
	CogitoQuestManager.reset_playthrough()
	_manager._reset_playthrough_state()
	return OK


func scene_load_failed(target: String, error: Error, message := "Cannot open level.") -> void:
	finish_transition()
	_manager.slot_error(message, target, error)
	_manager.fade_in()
	var player := _manager.get_player()
	if player and not _manager.get_tree().paused:
		player.resume()
		_manager.send_player_hint(null, _manager.last_slot_message)


func starting_a_new_game() -> void:
	_manager.get_tree().paused = false
	var player := _manager.get_player()
	var starter_items := CogitoGlobals.cogito_settings.new_game_starter_items
	if player:
		for stack in starter_items.duplicate_deep(Resource.DeepDuplicateMode.DEEP_DUPLICATE_ALL):
			player.inventory_data.pick_up_slot_data(stack)
	elif not starter_items.is_empty():
		push_warning("No player registered to receive starter items.")

	_manager.fade_in()
	_manager.is_starting_new_game = false

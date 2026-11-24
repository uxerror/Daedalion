extends CanvasLayer

signal save_load_ready(error: Error)

const CogitoScene := preload("res://addons/cogito/SceneManagement/cogito_scene.gd")

## Adds a forced wait time to the loading screen. Used to avoid loading screen flickering if load time is too short.
@export var forced_delay : float = 0.5
@onready var label_progress: Label = $Control/VBoxContainer/LabelProgress

var next_scene_path : String
var connector_name : String
var load_mode: CogitoSceneManager.CogitoSceneLoadMode
var progress_array: Array
var prepared_slot: CogitoSceneManager.PreparedSlot
var new_game := false


func request_scene() -> Error:
	if next_scene_path.is_empty():
		return ERR_FILE_BAD_PATH
	return ResourceLoader.load_threaded_request(next_scene_path, "PackedScene", false, ResourceLoader.CACHE_MODE_IGNORE)


func _process(_delta: float) -> void:
	var status := ResourceLoader.load_threaded_get_status(next_scene_path, progress_array)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		if not progress_array.is_empty():
			label_progress.text = "%d%%" % int(99 * float(progress_array[0]))
		return
	set_process(false)
	var level: Node
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		var packed := ResourceLoader.load_threaded_get(next_scene_path) as PackedScene
		if packed and packed.can_instantiate():
			await get_tree().create_timer(forced_delay).timeout
			level = packed.instantiate()
	if not level:
		if prepared_slot:
			CogitoSceneManager.finish_transition()
			save_load_ready.emit(CogitoSceneManager.slot_error("Cannot open saved level.", next_scene_path))
		else:
			CogitoSceneManager.scene_load_failed(next_scene_path, ERR_CANT_OPEN)
			save_load_ready.emit(ERR_CANT_OPEN)
		queue_free()
		return

	var error := OK
	if new_game:
		error = CogitoSceneManager.activate_new_game()
	elif prepared_slot:
		error = CogitoSceneManager.activate_saved_slot(prepared_slot)
	if error != OK:
		level.free()
		queue_free()
		CogitoSceneManager.finish_transition()
		save_load_ready.emit(error)
		return
	# Resume the initiating menu while it can still release its own input handler.
	# Keep the guard through swapping levels, applying deferred states and moving the player.
	save_load_ready.emit(OK)
	CogitoSceneManager.scene_load_mode = load_mode
	var current := get_tree().current_scene
	if current:
		current.free()
	CogitoSceneManager._current_scene_name = level.name
	CogitoSceneManager._current_scene_path = level.scene_file_path
	get_tree().root.add_child(level)
	get_tree().current_scene = level
	match load_mode:
		CogitoSceneManager.CogitoSceneLoadMode.LOAD_SAVE:
			CogitoSceneManager.apply_saved_game(prepared_slot)
		CogitoSceneManager.CogitoSceneLoadMode.TEMP:
			CogitoSceneManager.load_scene_state(level.name, "temp")
			CogitoSceneManager.load_player_state(CogitoSceneManager.get_player(), "temp")
		CogitoSceneManager.CogitoSceneLoadMode.RESET:
			if new_game:
				CogitoSceneManager.starting_a_new_game()
	if load_mode != CogitoSceneManager.CogitoSceneLoadMode.RESET and CogitoSceneManager.get_player():
		CogitoSceneManager.get_player().resume()
	shader_precompilation()
	if not connector_name.is_empty():
		if level.has_method("move_player_to_connector") and CogitoSceneManager.get_player():
			level.move_player_to_connector(connector_name)
		else:
			push_warning("Cannot place player at connector %s in %s." % [connector_name, next_scene_path])
	_finish_load.call_deferred(level)


func _finish_load(level: Node) -> void:
	CogitoSceneManager.finish_transition()
	if level is CogitoScene and level.save_temp_on_enter:
		level.save_temp()
	queue_free()


func shader_precompilation() -> void:
	# Iterrating through shaders
	for shader in CogitoGlobals.cogito_settings.shaders_to_preload:
		var dummy_material = ShaderMaterial.new()
		dummy_material.shader = shader
		CogitoGlobals.debug_log(true, "loading_screen", "Shader cached: " + shader.resource_path)
		dummy_material = null
	CogitoGlobals.debug_log(true, "loading_screen", "Shader precompilation complete.")

extends CanvasLayer
# Loading screen script is heavily dependent on Cogito Scene Manager and scene states.
# MODIFY AT YOUR OWN RISK. Besides the forced_delay, there aren't really any tweakable parameters here.

## Adds a forced wait time to the loading screen. Used to avoid loading screen flickering if load time is too short.
@export var forced_delay : float = 0.5
@onready var label_progress: Label = $Control/VBoxContainer/LabelProgress

var next_scene_path : String
var connector_name : String
var load_mode: CogitoSceneManager.CogitoSceneLoadMode
var progress_array: Array
var prepared_slot: CogitoSceneManager.PreparedSlot
signal save_load_ready(error: Error)


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
			CogitoSceneManager.is_currently_loading = false
			save_load_ready.emit(CogitoSceneManager.slot_error("Cannot open saved level.", next_scene_path))
		else:
			CogitoSceneManager.scene_load_failed(next_scene_path, ERR_CANT_OPEN)
		queue_free()
		return

	if prepared_slot:
		var error := CogitoSceneManager.activate_saved_slot(prepared_slot)
		# Resume the initiating menu while it is still alive to display the error
		# or close itself and release its input handler on success.
		save_load_ready.emit(error)
		if error != OK:
			level.free()
			queue_free()
			return
	var current := get_tree().current_scene
	if current:
		current.free()
	get_tree().root.add_child(level)
	get_tree().current_scene = level
	CogitoSceneManager._current_scene_name = level.name
	CogitoSceneManager._current_scene_path = level.scene_file_path
	match load_mode:
		CogitoSceneManager.CogitoSceneLoadMode.LOAD_SAVE:
			CogitoSceneManager.apply_saved_game(prepared_slot)
		CogitoSceneManager.CogitoSceneLoadMode.TEMP:
			CogitoSceneManager.load_scene_state(level.name, "temp")
			CogitoSceneManager.load_player_state(CogitoSceneManager.get_player(), "temp")
		CogitoSceneManager.CogitoSceneLoadMode.RESET:
			if CogitoSceneManager.is_starting_new_game:
				CogitoSceneManager.starting_a_new_game.call_deferred()
	if load_mode != CogitoSceneManager.CogitoSceneLoadMode.RESET and CogitoSceneManager.get_player():
		CogitoSceneManager.get_player().resume()
	shader_precompilation()
	if not connector_name.is_empty():
		level.move_player_to_connector(connector_name)
	CogitoSceneManager.is_currently_loading = false
	queue_free()


func shader_precompilation() -> void:
	# Iterrating through shaders
	for shader in CogitoGlobals.cogito_settings.shaders_to_preload:
		var dummy_material = ShaderMaterial.new()
		dummy_material.shader = shader
		CogitoGlobals.debug_log(true, "loading_screen", "Shader cached: " + shader.resource_path)
		dummy_material = null
	CogitoGlobals.debug_log(true, "loading_screen", "Shader precompilation complete.")

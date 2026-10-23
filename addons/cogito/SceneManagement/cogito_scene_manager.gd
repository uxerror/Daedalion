extends Node

## Emitted when a fade finishes
signal fade_finished

## Emitted when GUI options changed
signal update_gui

## Emitted once the first scene of a new game is loaded and the player has
## received the starter items.
signal new_game_started

# Used to set active save slot. This could be set/modified, when selecting a save slot from the MainMenu.
@export var _active_slot : String = "A"

# Cached World State Dictionary, used for checks while game is running
@export var _current_world_dict : Dictionary

# Variables for player state
## @deprecated: Use [method get_player] and [method register_player] instead.
@export var _current_player_node : Node
@export var _player_state : CogitoPlayerState
# Used to pass a screenshot to the player state when saved. This is created by the TabMenu/PauseMenu
@export var _screenshot_to_save : Image

# Variables & Signals for Player sitting
@export var _current_sittable_node : Node
signal sit_requested(Node)
signal stand_requested()
signal seat_move_requested(Node)

# Variables for scene state
@export var _current_scene_name : String
@export var _current_scene_path : String
@export var _scene_state : CogitoSceneState
@warning_ignore("unused_private_class_variable")
@export var _current_scene_root_node : Node

enum CogitoSceneLoadMode {TEMP, LOAD_SAVE, RESET}

# Keys the scene state adds to saved entries to find their nodes again. They are not node properties.
const SAVE_ID_KEYS : Array[String] = ["cogito_id", "cogito_parent_id"]
@export var scene_load_mode: CogitoSceneLoadMode

@export var cogito_state_dir : String = "user://saves/"

@onready var cogito_scene_state_prefix : String = CogitoGlobals.scene_state_prefix
@onready var cogito_player_state_prefix : String = CogitoGlobals.player_state_prefix

@onready var default_fade_duration : float = CogitoGlobals.default_transition_duration
@export var fade_panel : Panel = null

var saves_data_file_path : String = cogito_state_dir + "saves.data"

var is_currently_loading : bool = false
# This flag is used for save slot displays when new game has been started but not saved yet.
var is_loaded_from_start_new_game : bool = false
# This flag is used to call a function only when a new game is started.
var is_starting_new_game : bool = false
var previous_menu = ""
var previous_menu_button_pressed = ""
var pause_menu
var game_menu
var save_load_menu


func _ready() -> void:
	_player_state = get_existing_player_state(_active_slot) # Setting active slot (per default it's A)
	_scene_state = get_existing_scene_state(_active_slot)
	
	if not DirAccess.dir_exists_absolute(cogito_state_dir):
		DirAccess.make_dir_absolute(cogito_state_dir)
	
	reset_scene_states()
	instantiate_fade_panel()


## Returns the current player, or null if no player has been registered yet or it was freed (for example during a scene change).
func get_player() -> CogitoPlayer:
	if is_instance_valid(_current_player_node):
		return _current_player_node
	return null


## Sets the mouse mode the current player plays with. Called when an interface or menu closes.
func restore_gameplay_mouse_mode() -> void:
	var player := get_player()
	Input.mouse_mode = player.gameplay_mouse_mode if player else Input.MOUSE_MODE_CAPTURED


## Called by player controllers in their _ready() to become the current player.
func register_player(player: CogitoPlayer) -> void:
	_current_player_node = player


func grab_screenshot(scale: float = 1.0) -> Image:
	var image: Image = get_viewport().get_texture().get_image()
	image.resize(int(image.get_width() * scale), int(image.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	return image


func send_player_hint(hint_icon: Texture2D, hint_text: String):
	get_player().player_interaction_component.send_hint(hint_icon, hint_text)


func switch_active_slot_to(slot_name:String) -> void:
	_player_state = null
	_player_state = get_existing_player_state(slot_name)
	if !_player_state:
		CogitoGlobals.debug_log(true,"CSM","Existing player state for slot " + slot_name + " not found.")
	_active_slot = slot_name
	CogitoGlobals.debug_log(true,"CSM","Active slot switched to " + _active_slot)


func get_existing_player_state(passed_slot) -> CogitoPlayerState:
	var player_state_file : String = cogito_state_dir + passed_slot + "/" + cogito_player_state_prefix + ".res"
	CogitoGlobals.debug_log(true,"CSM","Looking for file: "+ player_state_file)
	if ResourceLoader.exists(player_state_file):
		CogitoGlobals.debug_log(true,"CSM","CSM: Get existing player state: found for slot "+ passed_slot)
		return ResourceLoader.load(player_state_file, "", ResourceLoader.CACHE_MODE_IGNORE)
	else:
		CogitoGlobals.debug_log(true,"CSM","Get existing player state: No player state found for slot "+ passed_slot)
		return null


func get_existing_scene_state(passed_slot) -> CogitoSceneState:
	var current_scene : String = ""
	if _player_state:
		current_scene = _player_state.player_current_scene
	var scene_state_file : String = cogito_state_dir + passed_slot + "/" + CogitoGlobals.scene_state_prefix + current_scene + ".res"
	CogitoGlobals.debug_log(true,"CSM","Looking for file: "+ scene_state_file)
	if ResourceLoader.exists(scene_state_file):
		CogitoGlobals.debug_log(true,"CSM","Get existing scene state: found for slot "+ passed_slot)
		return ResourceLoader.load(scene_state_file, "", ResourceLoader.CACHE_MODE_IGNORE)
	else:
		CogitoGlobals.debug_log(true,"CSM","Get existing scene state: No scene state found for slot "+ passed_slot)
		return null


func loading_saved_game(passed_slot: String, current_scene_name: String = "") -> void:
	CogitoGlobals.debug_log(true,"CSM","CSM: Loading saved game from slot "+ passed_slot)
	if !_player_state or !_player_state.state_exists(passed_slot):
		CogitoGlobals.debug_log(true,"CSM","CSM: Player state of passed slot doesn't exist.")
		return
		
	_player_state = _player_state.load_state(_active_slot) as CogitoPlayerState
	
	if current_scene_name == "":
		current_scene_name = get_tree().get_current_scene().get_name()
	
	CogitoGlobals.debug_log(true,"CSM","Current scene detected as "+ current_scene_name)
	# The level is loaded again from its scene file even when the save is from the current scene,
	# so the save gets applied to a clean level instead of one that is in the middle of being played.
	CogitoGlobals.debug_log(true,"CSM","Loading scene " + _player_state.player_current_scene + " for slot " + passed_slot + "...")
	load_next_scene(_player_state.player_current_scene_path, "", passed_slot, CogitoSceneLoadMode.LOAD_SAVE)


## Applies the scene and player state of a save to the level that was just loaded for it by loading_saved_game().
func apply_saved_game(passed_slot: String) -> void:
	load_scene_state(_player_state.player_current_scene, passed_slot)
	load_player_state(get_player(), passed_slot)


#region PLAYER SAVE HANDLING
func load_player_state(player, passed_slot:String) -> void:
	CogitoGlobals.debug_log(true,"CSM","Loading player state...")
	if !_player_state:
		_player_state = player.create_new_state()
	
	if _player_state and _player_state.state_exists(passed_slot):
		CogitoGlobals.debug_log(true,"CSM","Player State in slot " + passed_slot + " exists. Loading " + str(_player_state))
		_player_state = _player_state.load_state(passed_slot) as CogitoPlayerState
		
		# Applying the save state to player node.
		_player_state.populate_player_data(player)
		player.player_state_loaded.emit()
		
		fade_in()
	else:
		CogitoGlobals.debug_log(true,"CSM","Player state of slot " + passed_slot + " doesn't exist.")


func save_player_state(player, slot:String) -> void:
	if !_player_state:
		CogitoGlobals.debug_log(true,"CSM","State doesn't exist. Creating for slot " + slot + "...")
		_player_state = player.create_new_state()
	
	# Writing the save state from current player node.
	_player_state.populate_save_data(player, slot)

	# Write to temp directory first
	_player_state.write_state("temp")
#endregion


func get_active_slot_player_state_screenshot_path() -> String:
	if _player_state and _player_state.state_exists(_active_slot):
		_player_state = _player_state.load_state(_active_slot) as CogitoPlayerState
		return _player_state.player_state_screenshot_file
	else:
		return ""


func load_scene_state(_scene_name_to_load:String, slot:String) -> void:
	CogitoGlobals.debug_log(true,"CSM","Load scene state for:"+ _scene_name_to_load+ ". Slot: "+ slot)
	if !_scene_state:
		_scene_state = CogitoSceneState.new()
	
	if _scene_state and _scene_state.state_exists(slot, _scene_name_to_load):
		CogitoGlobals.debug_log(true,"CSM","Scene state exists. Loading " + str(_scene_state))
		_scene_state = _scene_state.load_state(slot,_scene_name_to_load) as CogitoSceneState
		
		if _scene_state.saved_nodes.all(func(node_data): return node_data.has("cogito_id")):
			_load_persist_nodes_in_place(_scene_state.saved_nodes)
		else:
			_load_persist_nodes_legacy(_scene_state.saved_nodes)

		# Loading states of objects in save_object_state
		var array_of_state_data = _scene_state.saved_states
		for state_data in array_of_state_data:
			var node_to_set : Node = _find_saved_node(state_data, "cogito_id", "node_path")
			if !node_to_set:
				CogitoGlobals.debug_log(true,"CSM","Saved object " + str(state_data.get("cogito_id", state_data.get("node_path"))) + " not found in the scene, skipped.")
				continue
			# Set variables here
			node_to_set.position = Vector3(state_data["pos_x"],state_data["pos_y"],state_data["pos_z"])
			node_to_set.rotation = Vector3(state_data["rot_x"],state_data["rot_y"],state_data["rot_z"])
			for data in state_data.keys():
				if data == "filename" or data == "parent" or data == "pos_x" or data == "pos_y" or data == "pos_z" or data == "rot_x" or data == "rot_y" or data == "rot_z" or data in SAVE_ID_KEYS:
					continue
				node_to_set.set(data, state_data[data])
			# Call set_state only if the method exists
			if node_to_set.has_method("set_state"):
				node_to_set.set_state()
		
		CogitoGlobals.debug_log(true,"CSM","CSM: Loading scene state finished.")
			
	else:
		CogitoGlobals.debug_log(true,"CSM","CSM: Scene state doesn't exist.")


# Restores Persist nodes on a freshly loaded level: nodes that are in the save are updated where they are,
# saved nodes that are missing get created from their scene file, and nodes of the level that are not in the save
# (picked up, destroyed) get removed.
func _load_persist_nodes_in_place(saved_nodes: Array) -> void:
	var saved_ids := {}
	for node_data in saved_nodes:
		saved_ids[node_data["cogito_id"]] = true

	var live_nodes := {}
	for node in get_tree().get_nodes_in_group("Persist"):
		if node.is_queued_for_deletion():
			continue
		var id := CogitoPersistentId.of(node)
		if saved_ids.has(id):
			live_nodes[id] = node
		elif node.has_method("save"): # Nodes without save() are never in a save, like the StateProcessors inside NPCs.
			CogitoGlobals.debug_log(true,"CSM","Removing node that is not in the save: "+ node.name)
			node.queue_free()

	for node_data in saved_nodes:
		var node : Node = live_nodes.get(node_data["cogito_id"])
		if !node:
			node = _spawn_saved_node(node_data)
			if !node:
				continue
		_apply_saved_node_data(node, node_data)


# Restores Persist nodes from a save made before ids were added: all of them get deleted and created again.
func _load_persist_nodes_legacy(saved_nodes: Array) -> void:
	# Deleting all current nodes that are in the Persist group as to not clone objects.
	var save_nodes = get_tree().get_nodes_in_group("Persist")
	for i in save_nodes:
		CogitoGlobals.debug_log(true,"CSM","Deleting existing node: "+ i.name)
		i.queue_free()

	for node_data in saved_nodes:
		var new_object := _spawn_saved_node(node_data)
		if new_object:
			_apply_saved_node_data(new_object, node_data)


func _spawn_saved_node(node_data: Dictionary) -> Node:
	if str(node_data.get("filename", "")).is_empty():
		CogitoGlobals.debug_log(true,"CSM","Saved node " + str(node_data.get("cogito_id")) + " is not in the level and has no scene file, skipped.")
		return null
	var parent_node : Node = _find_saved_node(node_data, "cogito_parent_id", "parent")
	if !parent_node:
		CogitoGlobals.debug_log(true,"CSM","Parent of saved node " + str(node_data["filename"]) + " not found, skipped.")
		return null
	var new_object = load(node_data["filename"]).instantiate()
	CogitoPersistentId.restore(new_object, node_data.get("cogito_id", ""))
	parent_node.add_child(new_object)
	CogitoGlobals.debug_log(true,"CSM","Adding to scene: "+ new_object.get_name())
	return new_object


func _apply_saved_node_data(new_object: Node, node_data: Dictionary) -> void:
	new_object.position = Vector3(node_data["pos_x"],node_data["pos_y"],node_data["pos_z"])
	new_object.rotation = Vector3(node_data["rot_x"],node_data["rot_y"],node_data["rot_z"])
	# Restore physics properties if it's a RigidBody3D
	if new_object is RigidBody3D:
		if "linear_velocity_x" in node_data and "linear_velocity_y" in node_data and "linear_velocity_z" in node_data:
			new_object.linear_velocity = Vector3(node_data["linear_velocity_x"], node_data["linear_velocity_y"], node_data["linear_velocity_z"])
		if "angular_velocity_x" in node_data and "angular_velocity_y" in node_data and "angular_velocity_z" in node_data:
			new_object.angular_velocity = Vector3(node_data["angular_velocity_x"], node_data["angular_velocity_y"], node_data["angular_velocity_z"])
	# Set the remaining variables.
	for data in node_data.keys():
		if data == "filename" or data == "parent" or data == "pos_x" or data == "pos_y" or data == "pos_z" or data == "rot_x" or data == "rot_y" or data == "rot_z" or data == "item_charge" or data in SAVE_ID_KEYS:
			continue
		new_object.set(data, node_data[data])

	if new_object.has_method("update_wieldable_data"): # Check if item is wieldable
		CogitoGlobals.debug_log(true,"CSM","Setting charge of "+ str(new_object) + " to "+ str(node_data["item_charge"]))
		new_object.slot_data.inventory_item.charge_current = node_data["item_charge"]

	# Call set_state only if the method exists
	if new_object.has_method("set_state"):
		new_object.set_state.call_deferred()


# Finds the node a saved entry belongs to. Saves made before ids were added only have an absolute path.
func _find_saved_node(data: Dictionary, id_key: String, legacy_path_key: String) -> Node:
	if data.has(id_key):
		return CogitoPersistentId.find(get_tree(), data[id_key])
	if data.has(legacy_path_key):
		return get_node_or_null(data[legacy_path_key])
	return null


func save_scene_state(_scene_name_to_save, slot: String) -> void:
	if !_scene_state:
		CogitoGlobals.debug_log(true,"CSM","CSM: Save doesn't exist. Creating...")
		_scene_state = CogitoSceneState.new()
		
	_scene_state.clear_saved_nodes() # Clearing out old saved nodes
	
	var save_nodes = get_tree().get_nodes_in_group("Persist")
	if !save_nodes:
		CogitoGlobals.debug_log(true,"CSM","No nodes in Persist group!")
	else:
		for node in save_nodes:
			# A node needs a scene file to be created again on load, unless it is part of the level and gets updated where it is.
			if node.scene_file_path.is_empty() and !CogitoPersistentId.of(node).begins_with("level:"):
				CogitoGlobals.debug_log(true,"CSM","persistent node '%s' is not an instanced scene, skipped" % node.name)
				continue

			if !node.has_method("save"): # Check the node has a save function.
				CogitoGlobals.debug_log(true,"CSM","persistent node '%s' is missing a save() function, skipped" % node.name)
				continue
				
			var node_data = node.save()
			node_data["cogito_id"] = CogitoPersistentId.of(node)
			node_data["cogito_parent_id"] = CogitoPersistentId.of(node.get_parent())
			# If the node is a RigidBody3D, then save the physics properties
			if node is RigidBody3D:
				node_data["linear_velocity_x"] = node.linear_velocity.x
				node_data["linear_velocity_y"] = node.linear_velocity.y
				node_data["linear_velocity_z"] = node.linear_velocity.z
				node_data["angular_velocity_x"] = node.angular_velocity.x
				node_data["angular_velocity_y"] = node.angular_velocity.y
				node_data["angular_velocity_z"] = node.angular_velocity.z
			_scene_state.add_node_data_to_array(node_data)
		
	_scene_state.clear_saved_states()
	
	# Saving states of objects
	var state_nodes = get_tree().get_nodes_in_group("save_object_state")
	if !state_nodes:
		CogitoGlobals.debug_log(true,"CSM","No nodes in save_object_state group!")
	else:
		for node in state_nodes:
			if !node.has_method("save"): # Check the node has a save function.
				CogitoGlobals.debug_log(true,"CSM","persistent node '%s' is missing a save() function, skipped" % node.name)
				continue
				
			var state_data = node.save()
			state_data["cogito_id"] = CogitoPersistentId.of(node)
			_scene_state.add_state_data_to_array(state_data)
			
	_scene_state.write_state(slot, _scene_name_to_save)


# Function to transition to another scene via the loading screen.
func load_next_scene(target : String, connector_name: String, passed_slot: String, load_mode: CogitoSceneLoadMode) -> void:
	CogitoSceneManager.scene_load_mode = load_mode
	# fade_out()
	var loading_screen = load(CogitoGlobals.cogito_settings.loading_screen_scene_path).instantiate()
	loading_screen.next_scene_path = target
	loading_screen.connector_name = connector_name
	loading_screen.passed_slot = passed_slot
	# loading_screen.attempt_to_load_save = loading_a_save
	loading_screen.load_mode = load_mode
	CogitoGlobals.debug_log(true, "CSM", "Loading screen initiated with: next_scene_path=" + target + " | connector = " + connector_name + " | passed_slot = " + passed_slot + " | load_mode = " + str(load_mode) )
	get_tree().get_root().add_child(loading_screen)


func delete_save(passed_slot: String) -> void:
	# var file_to_remove = cogito_state_dir + cogito_player_state_prefix + passed_slot + ".res"
	var dir_to_remove = cogito_state_dir + passed_slot
	OS.move_to_trash(ProjectSettings.globalize_path(dir_to_remove))
	var screenshot_to_remove = cogito_state_dir + CogitoGlobals.cogito_settings.player_state_prefix + passed_slot + ".png"
	OS.move_to_trash(ProjectSettings.globalize_path(screenshot_to_remove))
	CogitoGlobals.debug_log(true,"CSM","Save file removed: "+ dir_to_remove)
	
	# var scene_to_remove = cogito_state_dir + cogito_scene_state_prefix + passed_slot + ".res"


func copy_slot_saves_to_temp(passed_slot:String) -> bool:
	CogitoGlobals.debug_log(true,"CSM","Attempting to copy files from slot " + passed_slot + " to temp.")
	var slot_dir = DirAccess.open(cogito_state_dir + passed_slot)
	
	var cogito_dir = DirAccess.open(CogitoSceneManager.cogito_state_dir)
	if not cogito_dir.dir_exists("temp"):
		cogito_dir.make_dir("temp")

	if slot_dir:
		slot_dir.list_dir_begin()
		var file_name = slot_dir.get_next()
		
		while file_name != "":
			CogitoGlobals.debug_log(true,"CSM","Copying file to temp: "+ file_name)
			if slot_dir.copy(str(CogitoSceneManager.cogito_state_dir + passed_slot + "/" + file_name), str(CogitoSceneManager.cogito_state_dir + "temp/" + file_name), -1) != OK:
				CogitoGlobals.debug_log(true,"CSM","Copying file "+ file_name + " failed.")
				return false
			# iterate to next file
			file_name = slot_dir.get_next()
	
	CogitoGlobals.debug_log(true,"CSM", "Copying files to temp finished.")
	
	loading_saved_game("temp") # This loads the temp save states after moving them from the slot.
	return true


func copy_temp_saves_to_slot(passed_slot:String) -> bool:
	CogitoGlobals.debug_log(true,"CSM","Attempting to copy files from temp to slot " + passed_slot)
	var temp_dir = DirAccess.open(cogito_state_dir + "temp")
	
	var cogito_dir = DirAccess.open(CogitoSceneManager.cogito_state_dir)
	if not cogito_dir.dir_exists(passed_slot):
		cogito_dir.make_dir(passed_slot)

	if temp_dir:
		temp_dir.list_dir_begin()
		var file_name = temp_dir.get_next()
		
		while file_name != "":
			CogitoGlobals.debug_log(true,"CSM","Copying file to temp: "+ file_name)
			if temp_dir.copy(str(CogitoSceneManager.cogito_state_dir + "temp/" + file_name), str(CogitoSceneManager.cogito_state_dir + passed_slot + "/" + file_name), -1) != OK:
				CogitoGlobals.debug_log(true,"CSM","Copying file " + file_name + " failed.")
				return false
			# iterate to next file
			file_name = temp_dir.get_next()
	
	CogitoGlobals.debug_log(true,"CSM","Copying temp files to slot " + passed_slot + " finished.")
	return true


func delete_temp_saves() -> void:
	CogitoGlobals.debug_log(true,"CSM","Attempting to delete temp saves...")
	
	var dir = DirAccess.open(cogito_state_dir + "temp/")
	
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		
		while file_name != "":
			CogitoGlobals.debug_log(true,"CSM","Deleting file: " + file_name)
			if dir.remove(file_name) != OK:
				CogitoGlobals.debug_log(true,"CSM","Deleting file " + file_name + " failed.")
			# iterate to next file
			file_name = dir.get_next()
	
	var dir2 = DirAccess.open(cogito_state_dir)
	if dir2:
		dir2.list_dir_begin()
		var file_name = dir2.get_next()
		while file_name != "":
			if dir2.current_is_dir():
				CogitoGlobals.debug_log(true,"CSM","Deleting temp saves: Detected dir = " + file_name)
				if file_name == "temp":
					CogitoGlobals.debug_log(true,"CSM","Deleting temp directory: " + file_name)
					if dir2.remove(file_name) != OK:
						CogitoGlobals.debug_log(true,"CSM","Deleting temp dir failed.")
			file_name = dir2.get_next()
			
	CogitoGlobals.debug_log(true,"CSM","Delete temp saves complete!")


## @deprecated: Use [code]CogitoPersistentId.find()[/code] instead.
func find_object_from_uid(uid: int) -> Node3D:
	for node in get_tree().get_nodes_in_group("Persist"):
		if node.get("uid") == uid:
			return node
	return null


func reset_scene_states() -> void:
	# TODO: CREATE FUNCTION THAT DELETES SCENE STATE FILES.
	var scene_state_files : Dictionary
	
	var dir = DirAccess.open(cogito_state_dir)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		
		while file_name != "":
			if dir.current_is_dir():
				CogitoGlobals.debug_log(true,"CSM","Found directory: " + file_name + ". skipping ahead.")

			# Look for _temp_ files
			if file_name.find(cogito_scene_state_prefix,0) != -1:
				CogitoGlobals.debug_log(true,"CSM","Found scene state file: " + file_name)
				if file_name.find("temp",0) != -1:
					CogitoGlobals.debug_log(true,"CSM","This file is a temp scene state.")
					# DELETE HERE
			
			# iterate to next file
			file_name = dir.get_next()
			
	else:
		CogitoGlobals.debug_log(true,"CSM","An error occurred when trying to access the path.")


func starting_a_new_game() -> void:
	get_tree().paused = false
	CogitoGlobals.debug_log(true, "CSM", "New game. Adding new game start inventory to player inventory...")
	var temp_item_list = CogitoGlobals.cogito_settings.new_game_starter_items.duplicate_deep(Resource.DeepDuplicateMode.DEEP_DUPLICATE_ALL)
	for slot_data in temp_item_list:
		get_player().inventory_data.pick_up_slot_data(slot_data)
		
	fade_in()
	is_starting_new_game = false
	new_game_started.emit()


func _exit_tree() -> void:
	delete_temp_saves()


func _save_autosave_state() -> void:
	_current_scene_name = get_tree().get_current_scene().get_name()
	_current_scene_path = get_tree().current_scene.scene_file_path
	# Use the class variable instead of creating a new local variable
	if not _screenshot_to_save:
		_screenshot_to_save = grab_screenshot(CogitoGlobals.screenshot_scale)
	
	save_player_state(get_player(), CogitoGlobals.cogito_settings.auto_save_name)
	save_scene_state(_current_scene_name, CogitoGlobals.cogito_settings.auto_save_name)
	copy_temp_saves_to_slot(CogitoGlobals.cogito_settings.auto_save_name) # Use this to include scene states from other scenes in the save.


### FUNCTIONS TO HANDLE SCREEN FADING
func instantiate_fade_panel() -> void:
	fade_panel = Panel.new()
	
	var black_stylebox := StyleBoxFlat.new()
	black_stylebox.bg_color = Color.BLACK
	
	fade_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	fade_panel.focus_mode = Control.FOCUS_NONE
	fade_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade_panel.set_modulate(Color.TRANSPARENT)
	fade_panel.add_theme_stylebox_override("panel", black_stylebox)
	
	add_child(fade_panel)


func fade_in(fade_duration:float = default_fade_duration) -> void:
	fade_panel.set_modulate(Color.BLACK)
	var fade_tween = get_tree().create_tween()
	
	fade_tween.tween_property(fade_panel, "modulate", Color.TRANSPARENT, fade_duration).set_trans(Tween.TRANS_CUBIC)
	await fade_tween.finished
	fade_finished.emit()


func fade_out(fade_duration:float = default_fade_duration) -> void:
	fade_panel.set_modulate(Color.TRANSPARENT)
	var fade_tween = get_tree().create_tween()
	
	fade_tween.tween_property(fade_panel, "modulate", Color.BLACK, fade_duration).set_trans(Tween.TRANS_CUBIC)
	await fade_tween.finished
	fade_finished.emit()


func save_last_saved_slot(slot: String) -> void:
	var saved_slots = []
	var config = ConfigFile.new()
	if FileAccess.file_exists(saves_data_file_path):
		config.load(saves_data_file_path)
		saved_slots = config.get_value("save", "slots")
		saved_slots.erase(slot)
		saved_slots.append(slot)
		config.set_value("save", "slots", saved_slots)
		config.save(saves_data_file_path)
	else:
		saved_slots.append(slot)
		config.set_value("save", "slots", saved_slots)
		config.save(saves_data_file_path)
 

func get_last_saved_slot() -> String:
	if FileAccess.file_exists(saves_data_file_path):
		var config = ConfigFile.new()
		config.load(saves_data_file_path)
		var saved_slots = []
		saved_slots = config.get_value("save", "slots", [])
		if saved_slots:
			var slot = saved_slots.back()
			if slot:
				return slot

	return ""  # Return an empty string if no saved slot exists


func delete_from_saved_slots(slot: String):
	if FileAccess.file_exists(saves_data_file_path):
		var config = ConfigFile.new()
		config.load(saves_data_file_path)
		var saved_slots = []
		saved_slots = config.get_value("save", "slots")
		saved_slots.erase(slot)
		config.save(saves_data_file_path)


func is_saved_slots_empty():
	if FileAccess.file_exists(saves_data_file_path):
		var config = ConfigFile.new()
		config.load(saves_data_file_path)
		var saved_slots = []
		saved_slots = config.get_value("save", "slots")
		if saved_slots:
			return false
	
	return true


func saved_slots_count() -> int:
	if FileAccess.file_exists(saves_data_file_path):
		var config = ConfigFile.new()
		config.load(saves_data_file_path)
		var saved_slots = []
		saved_slots = config.get_value("save", "slots", [])
		if saved_slots:
			return saved_slots.size()
	
	return 0


func max_saved_slot_nubmer() -> int:
	if FileAccess.file_exists(saves_data_file_path):
		var config = ConfigFile.new()
		config.load(saves_data_file_path)
		var saved_slots = []
		saved_slots = config.get_value("save", "slots", [])
		if saved_slots:
			var max_value = 0
			for slot in saved_slots:
				if int(slot) > max_value:
					max_value = int(slot)
			
			return max_value
	
	return 0


func is_saved_slot_exist(slot: String):
	if FileAccess.file_exists(saves_data_file_path):
		var config = ConfigFile.new()
		config.load(saves_data_file_path)
		var saved_slots = []
		saved_slots = config.get_value("save", "slots")
		if saved_slots and slot in saved_slots:
			return true
	
	return false

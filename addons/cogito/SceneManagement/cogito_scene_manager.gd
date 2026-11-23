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

enum SlotStatus { EMPTY, OK, BROKEN }

class PreparedSlot:
	var status := SlotStatus.BROKEN
	var reason := ""
	var player: CogitoPlayerState
	var level: PackedScene
	var scene: CogitoSceneState

const SlotStorage := preload("res://addons/cogito/SceneManagement/cogito_slot_storage.gd")
@onready var storage := SlotStorage.new(cogito_state_dir)
var last_slot_message := ""

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

# Nodes destroyed in the current level that the Persist loader can't remove on load, see register_destroyed_node().
var _destroyed_nodes : Array = []
var _destroyed_nodes_level_id : int = 0


func _ready() -> void:
	storage.recover_all() # Individual failures are logged and retried before use.
	_player_state = get_existing_player_state(_active_slot)
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
	if DisplayServer.get_name() == "headless":
		return null
	var image: Image = get_viewport().get_texture().get_image()
	if not image or image.is_empty():
		return null
	image.resize(int(image.get_width() * scale), int(image.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	return image


func send_player_hint(hint_icon: Texture2D, hint_text: String):
	get_player().player_interaction_component.send_hint(hint_icon, hint_text)


func player_file(slot: String) -> String:
	return cogito_state_dir.path_join(slot).path_join(cogito_player_state_prefix + ".res")


func scene_file(slot: String, level_name: String) -> String:
	return cogito_state_dir.path_join(slot).path_join(cogito_scene_state_prefix + level_name + ".res")


func get_existing_player_state(slot: String) -> CogitoPlayerState:
	if storage.valid_slot(slot) and FileAccess.file_exists(player_file(slot)):
		return ResourceLoader.load(player_file(slot), "", ResourceLoader.CACHE_MODE_IGNORE) as CogitoPlayerState
	return null


func prepare_slot(slot: String) -> PreparedSlot:
	if storage.recover(slot) != OK:
		var result := PreparedSlot.new()
		result.reason = "Cannot access save slot."
		return result
	return _prepare_files(slot)


func _prepare_files(slot: String) -> PreparedSlot:
	var result := PreparedSlot.new()
	var path := player_file(slot)
	var dir_path := path.get_base_dir()
	var directory := DirAccess.open(dir_path)
	if not directory:
		var parent := DirAccess.open(cogito_state_dir)
		if not parent or parent.get_directories().has(slot) or parent.file_exists(slot):
			result.reason = "Cannot access save slot."
			return result
	var files := directory.get_files() if directory else PackedStringArray()
	if not files.has(path.get_file()):
		result.status = SlotStatus.EMPTY
		result.reason = "Empty slot."
		return result
	result.player = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as CogitoPlayerState
	if not result.player:
		result.reason = "Cannot read player state."
		return result
	var level_path := result.player.player_current_scene_path
	if ResourceLoader.exists(level_path, "PackedScene"):
		result.level = ResourceLoader.load(level_path, "PackedScene") as PackedScene
	if not result.level or not result.level.can_instantiate():
		result.reason = "Saved level is unavailable."
		return result
	var level_name := result.player.player_current_scene
	if not level_name.is_valid_filename():
		result.reason = "Invalid saved level name."
		return result
	path = scene_file(slot, level_name)
	if files.has(path.get_file()):
		result.scene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as CogitoSceneState
		if not result.scene:
			result.reason = "Cannot read level state."
			return result
	result.status = SlotStatus.OK
	return result


func slot_error(message: String, detail: String, error := FAILED) -> Error:
	last_slot_message = message
	push_warning("%s %s (%s)" % [message, detail, error_string(error)])
	CogitoGlobals.debug_log(true, "CSM", detail)
	return error


func loading_saved_game(slot: String, _current_scene_name_unused: String = "") -> Error:
	var prepared := prepare_slot(slot)
	if prepared.status != SlotStatus.OK:
		return slot_error(prepared.reason, slot, ERR_FILE_CANT_READ)
	var screen = _new_loading_screen()
	if not screen:
		return slot_error("Cannot open loading screen.", slot)
	var level := prepared.level.instantiate()
	if not level:
		screen.free()
		return slot_error("Cannot open saved level.", prepared.player.player_current_scene_path)
	if slot != "temp":
		var error := storage.replace("temp", slot)
		if error != OK:
			level.free()
			screen.free()
			return slot_error("Cannot prepare saved files.", slot, error)
	if not prepared.scene:
		push_warning("No level state in slot %s. Loading the original level." % slot)
	_active_slot = slot
	is_loaded_from_start_new_game = false
	scene_load_mode = CogitoSceneLoadMode.LOAD_SAVE
	screen.load_mode = scene_load_mode
	screen.prepared_level = level
	screen.prepared_slot = prepared
	get_tree().root.add_child(screen)
	return OK


func apply_saved_game(prepared: PreparedSlot) -> void:
	_scene_state = prepared.scene
	if _scene_state:
		_apply_scene_state()
	_apply_player_state(get_player(), prepared.player)


#region PLAYER SAVE HANDLING
func load_player_state(player: CogitoPlayer, slot: String) -> void:
	var state := get_existing_player_state(slot)
	if state:
		_apply_player_state(player, state)


func _apply_player_state(player: CogitoPlayer, state: CogitoPlayerState) -> void:
	if not player:
		push_warning("No player registered in the loaded level.")
		return
	_player_state = state
	state.populate_player_data(player)
	player.player_state_loaded.emit()
	fade_in()


func write_state_resource(state: Resource, path: String) -> Error:
	var error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if error == OK:
		error = ResourceSaver.save(state, path, ResourceSaver.FLAG_CHANGE_PATH)
	return storage.check(error, path)
#endregion


func slot_screenshot(state: CogitoPlayerState, placeholder: Texture2D) -> Texture2D:
	if state and not state.player_state_screenshot_file.is_empty() and FileAccess.file_exists(state.player_state_screenshot_file):
		var image := Image.load_from_file(state.player_state_screenshot_file)
		if image and not image.is_empty():
			return ImageTexture.create_from_image(image)
	return placeholder


func load_scene_state(level_name: String, slot: String) -> void:
	var path := scene_file(slot, level_name)
	if FileAccess.file_exists(path):
		_scene_state = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as CogitoSceneState
		if _scene_state:
			_apply_scene_state()
		else:
			push_warning("Cannot read level state: " + path)


func _apply_scene_state() -> void:
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
	
	_load_destroyed_nodes(_scene_state.saved_destroyed_nodes)
	# Element states go last, after the deferred set_state() calls of the Persist nodes
	# and the on-ready states of the freshly loaded level.
	_apply_element_states.call_deferred(_scene_state.saved_element_states.duplicate(true))
	
	CogitoGlobals.debug_log(true,"CSM","CSM: Loading scene state finished.")



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
	var prefab := load(node_data["filename"]) as PackedScene
	if not prefab or not prefab.can_instantiate():
		push_warning("Cannot instantiate saved object: " + str(node_data["filename"]))
		return null
	var new_object := prefab.instantiate()
	if not new_object:
		return null
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


func save_scene_state(level_name: String, slot: String) -> Error:
	var state := _capture_scene_state()
	var error := state.write_state(slot, level_name)
	if error == OK:
		_scene_state = state
	return error


func _capture_scene_state() -> CogitoSceneState:
	var state := CogitoSceneState.new()
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
			state.add_node_data_to_array(node_data)
	

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
			state.add_state_data_to_array(state_data)
	
	state.saved_element_states = _collect_element_states()
	state.saved_destroyed_nodes = _get_destroyed_nodes().duplicate(true)
			
	return state


#region ELEMENT STATES
## Returns a key that finds a node with element states again after a load: the persistent id of the nearest
## Persist node (with save()) above it or itself, and the path from there. Nodes outside of Persist nodes use their own id.
func get_element_state_key(node: Node) -> Dictionary:
	var persist_node := node
	while persist_node and !(persist_node.is_in_group("Persist") and persist_node.has_method("save")):
		persist_node = persist_node.get_parent()
	if persist_node:
		return {"cogito_id": CogitoPersistentId.of(persist_node), "path": str(persist_node.get_path_to(node))}
	return {"cogito_id": CogitoPersistentId.of(node), "path": "."}


## Returns the node of a key made by get_element_state_key(), or null.
func find_element_state_node(key: Dictionary) -> Node:
	var persist_node := CogitoPersistentId.find(get_tree(), str(key.get("cogito_id", "")))
	if !persist_node:
		return null
	var node := persist_node.get_node_or_null(NodePath(str(key.get("path", "."))))
	if node and node.is_queued_for_deletion():
		return null
	return node


## Remembers that a node of the current level was destroyed (e.g. burned out with BurnOutResult.DESTROY),
## so it is freed again when the scene state loads. Persist nodes with save() don't need this, the save leaves them out.
func register_destroyed_node(node: Node) -> void:
	if !is_instance_valid(node) or !node.is_inside_tree():
		return
	if node.is_in_group("Persist") and node.has_method("save"):
		return
	_get_destroyed_nodes().append(get_element_state_key(node))


# The destroyed nodes of the current level. The list starts empty in every newly loaded level.
func _get_destroyed_nodes() -> Array:
	var level_root := CogitoPersistentId.get_level_root(get_tree())
	var level_id := level_root.get_instance_id() if level_root else 0
	if level_id != _destroyed_nodes_level_id:
		_destroyed_nodes = []
		_destroyed_nodes_level_id = level_id
	return _destroyed_nodes


func _load_destroyed_nodes(saved_destroyed_nodes: Array) -> void:
	var destroyed := _get_destroyed_nodes()
	destroyed.clear()
	for key in saved_destroyed_nodes:
		destroyed.append(key)
		var node := find_element_state_node(key)
		if node:
			CogitoGlobals.debug_log(true,"CSM","Removing node that was destroyed: " + node.name)
			node.queue_free()


func _collect_element_states() -> Array:
	var entries : Array = []
	for node in get_tree().get_nodes_in_group(CogitoProperties.ELEMENT_STATE_GROUP):
		if node.is_queued_for_deletion() or !node.has_method("get_element_save_data"):
			continue
		if _is_part_of_player(node):
			continue # Saved with the player state.
		var entry := get_element_state_key(node)
		entry["data"] = node.get_element_save_data()
		entries.append(entry)
	return entries


func _apply_element_states(entries: Array) -> void:
	var actor_entries : Array = []
	for entry in entries:
		var node := find_element_state_node(entry)
		if !node or !node.has_method("apply_element_save_data"):
			CogitoGlobals.debug_log(true,"CSM","Element state of " + str(entry.get("cogito_id")) + "/" + str(entry.get("path")) + " has no node in the scene, skipped.")
			continue
		if node is CogitoActorElements:
			actor_entries.append([node, entry.get("data", {})]) # After the CogitoProperties they read.
			continue
		node.apply_element_save_data(entry.get("data", {}))
	for actor_entry in actor_entries:
		actor_entry[0].apply_element_save_data(actor_entry[1])


func _is_part_of_player(node: Node) -> bool:
	var parent := node
	while parent:
		if parent is CogitoPlayer:
			return true
		parent = parent.get_parent()
	return false
#endregion


# Function to transition to another scene via the loading screen.
func _new_loading_screen() -> CanvasLayer:
	var packed := load(CogitoGlobals.cogito_settings.loading_screen_scene_path) as PackedScene
	if not packed or not packed.can_instantiate():
		return null
	var screen := packed.instantiate()
	if screen is CanvasLayer and screen.has_method("request_scene"):
		return screen
	if screen:
		screen.free()
	return null


func load_next_scene(target: String, connector_name: String, passed_slot: String, load_mode: CogitoSceneLoadMode) -> Error:
	if load_mode == CogitoSceneLoadMode.LOAD_SAVE:
		return loading_saved_game(passed_slot)
	var screen = _new_loading_screen()
	if not screen:
		scene_load_failed(target, ERR_CANT_CREATE)
		return ERR_CANT_CREATE
	screen.next_scene_path = target
	screen.connector_name = connector_name
	screen.load_mode = load_mode
	var error: Error = screen.request_scene()
	if error != OK:
		screen.free()
		scene_load_failed(target, error)
		return error
	scene_load_mode = load_mode
	get_tree().root.add_child(screen)
	return OK


func scene_load_failed(target: String, error: Error) -> void:
	is_currently_loading = false
	slot_error("Cannot open level.", target, error)
	fade_in()
	var player := get_player()
	if player:
		player.resume()
		send_player_hint(null, last_slot_message)


func delete_save(slot: String) -> Error:
	var error := storage.recover(slot)
	if error != OK:
		return error
	var directory := cogito_state_dir.path_join(slot)
	if DirAccess.dir_exists_absolute(directory):
		error = OS.move_to_trash(ProjectSettings.globalize_path(directory))
		if error != OK:
			return storage.check(error, directory)
	var external_png := cogito_state_dir.path_join(cogito_player_state_prefix + slot + ".png")
	if FileAccess.file_exists(external_png):
		error = OS.move_to_trash(ProjectSettings.globalize_path(external_png))
	return storage.check(error, external_png)


func delete_temp_saves() -> Error:
	var error := storage.recover("temp")
	if error == OK:
		error = storage.remove_directory(cogito_state_dir.path_join("temp"))
	return error


## @deprecated: Use [code]CogitoPersistentId.find()[/code] instead.
func find_object_from_uid(uid: int) -> Node3D:
	for node in get_tree().get_nodes_in_group("Persist"):
		if node.get("uid") == uid:
			return node
	return null


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


## Capture temp, manual and automatic saves with the same directory transaction.
## Only a manual save promotes its slot in the existing Continue menu history.
func save_game(slot: String, update_history := true) -> Error:
	var player := get_player()
	var level := get_tree().current_scene
	if not player or not level or not storage.valid_slot(slot):
		return slot_error("Cannot save game.", slot, ERR_INVALID_PARAMETER)
	_current_scene_name = level.name
	_current_scene_path = level.scene_file_path
	var state := player.create_new_state()
	state.populate_save_data(player, slot)
	var scene := _capture_scene_state()
	var shot: Image = _screenshot_to_save if slot != "temp" else null
	if shot:
		state.player_state_screenshot_file = cogito_state_dir.path_join(slot).path_join("screenshot.png")
	var writer := _write_generation.bind(state, scene, shot)
	var skip := PackedStringArray([
		player_file(slot).get_file(), scene_file(slot, level.name).get_file(), "screenshot.png"
	])
	var promote := save_last_saved_slot.bind(slot) if update_history else Callable()
	var error := storage.recover("temp")
	if error == OK:
		var source := "temp" if DirAccess.dir_exists_absolute(cogito_state_dir.path_join("temp")) else ""
		error = storage.replace(slot, source, writer, skip, promote)
	if error != OK:
		return slot_error("Save failed.", slot, error)
	if update_history:
		_active_slot = slot
		is_loaded_from_start_new_game = false
	_player_state = state
	_scene_state = scene
	return OK


func _write_generation(directory: String, player: CogitoPlayerState, scene: CogitoSceneState, shot: Image) -> Error:
	var staging := directory.get_file()
	var error := storage.before("write player")
	if error == OK:
		error = player.write_state(staging)
	if error == OK:
		error = storage.before("write current scene")
	if error == OK:
		error = scene.write_state(staging, player.player_current_scene)
	if error == OK and shot:
		error = storage.before("write screenshot")
		if error == OK:
			var path := directory.path_join("screenshot.png")
			error = storage.check(shot.save_png(path), path)
	if error != OK:
		return error
	# Verify the freshly serialized resources before sealing staging. Ignore the
	# root resource cache as in normal v1 reads (external assets remain shared).
	var verified := _prepare_files(staging)
	if verified.status != SlotStatus.OK or not verified.scene:
		return storage.check(ERR_FILE_CORRUPT, directory + " " + verified.reason)
	return OK


func save_temp_game() -> Error:
	var error := save_game("temp", false)
	if error != OK and get_player():
		send_player_hint(null, last_slot_message)
	return error


func _save_autosave_state() -> Error:
	if not _screenshot_to_save:
		_screenshot_to_save = grab_screenshot(CogitoGlobals.screenshot_scale)
	var error := save_game(CogitoGlobals.cogito_settings.auto_save_name, false)
	if error != OK and get_player():
		send_player_hint(null, last_slot_message)
	return error


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


func _load_index(config: ConfigFile) -> Error:
	var error := config.load(saves_data_file_path)
	if error == ERR_FILE_NOT_FOUND:
		return OK
	if error != OK:
		return storage.check(error, saves_data_file_path)
	var slots: Variant = config.get_value("save", "slots", false)
	if not slots is Array:
		return storage.check(ERR_INVALID_DATA, saves_data_file_path)
	for slot: Variant in slots:
		if not slot is String or not storage.valid_slot(slot):
			return storage.check(ERR_INVALID_DATA, saves_data_file_path)
	return OK


func _update_index(slot: String, promote: bool) -> Error:
	var config := ConfigFile.new()
	var error := _load_index(config)
	if error != OK:
		return error
	var slots: Array = config.get_value("save", "slots", [])
	slots.erase(slot)
	if promote:
		slots.append(slot)
	config.set_value("save", "slots", slots)
	var pending := saves_data_file_path.get_base_dir().path_join(".saves-index.next")
	error = storage.before("write index")
	if error == OK:
		error = storage.check(config.save(pending), pending)
	if error == OK:
		var verified := ConfigFile.new()
		error = storage.check(verified.load(pending), pending)
		if error == OK and verified.encode_to_text() != config.encode_to_text():
			error = storage.check(ERR_FILE_CORRUPT, pending)
	if error == OK:
		error = storage.before("publish index")
	if error == OK:
		error = storage.check(DirAccess.rename_absolute(pending, saves_data_file_path), saves_data_file_path)
	if error != OK and FileAccess.file_exists(pending):
		storage.check(DirAccess.remove_absolute(pending), pending)
	return error


func save_last_saved_slot(slot: String) -> Error:
	return _update_index(slot, true)


func delete_from_saved_slots(slot: String) -> Error:
	return _update_index(slot, false)


func _saved_slots() -> Array:
	var config := ConfigFile.new()
	if _load_index(config) != OK:
		return []
	return config.get_value("save", "slots", [])


func get_last_saved_slot() -> String:
	var slots := _saved_slots()
	return "" if slots.is_empty() else slots.back()


func is_saved_slots_empty() -> bool:
	# Quick Load starts a new game for an empty history. A read error must
	# keep that action from clearing the current playthrough.
	var config := ConfigFile.new()
	return _load_index(config) == OK and config.get_value("save", "slots", []).is_empty()


func saved_slots_count() -> int:
	return _saved_slots().size()


func max_saved_slot_nubmer() -> int:
	var highest := 0
	for slot: String in _saved_slots():
		highest = maxi(highest, int(slot))
	return highest


func is_saved_slot_exist(slot: String) -> bool:
	return slot in _saved_slots()

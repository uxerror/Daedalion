extends Node
## Autoload interface and shared scene, player, slot and menu state.

## Emitted when a fade finishes.
signal fade_finished

## Emitted when GUI options change.
signal update_gui

## Emitted once the first scene of a new game is loaded and the player has
## received the starter items.
signal new_game_started

signal sit_requested(Node)
signal stand_requested
signal seat_move_requested(Node)

enum CogitoSceneLoadMode { TEMP, LOAD_SAVE, RESET }

enum SlotStatus { EMPTY, OK, BROKEN }


class PreparedSlot:
	var status := SlotStatus.BROKEN
	var reason := ""
	var player: CogitoPlayerState
	var slot: String
	var save_time: int
	var warnings: Array[Dictionary] = []
	var scene: CogitoSceneState


const SaveCodec := preload("res://addons/cogito/SceneManagement/save_codec.gd")
const SlotStorage := preload("res://addons/cogito/SceneManagement/cogito_slot_storage.gd")
const SaveIndex := preload("cogito_save_index.gd")
const SlotFiles := preload("cogito_slot_files.gd")
const SaveSlots := preload("cogito_save_slots.gd")
const PlayerPersistence := preload("cogito_player_persistence.gd")
const ScenePersistence := preload("cogito_scene_persistence.gd")
const SceneTransitions := preload("cogito_scene_transitions.gd")
const Fade := preload("cogito_fade.gd")
# Lookup keys added to the save data for a node and its parent.
const SAVE_ID_KEYS: Array[String] = ["cogito_id", "cogito_parent_id"]

# Empty until the player saves to or loads a named slot.
@export var _active_slot: String = ""
@export var _current_world_dict: Dictionary
## @deprecated: Use [method get_player] and [method register_player] instead.
@export var _current_player_node: Node
@export var _player_state: CogitoPlayerState
@export var _screenshot_to_save: Image
@export var _current_sittable_node: Node
# The loading screen and save slots write these two fields directly.
@warning_ignore("unused_private_class_variable")
@export var _current_scene_name: String
@warning_ignore("unused_private_class_variable")
@export var _current_scene_path: String
@export var _scene_state: CogitoSceneState
@export var _current_scene_root_node: Node
@export var scene_load_mode: CogitoSceneLoadMode
@export var cogito_state_dir: String = "user://saves/"
@export var fade_panel: Panel = null

var last_slot_message := ""
var saves_data_file_path: String = cogito_state_dir + "saves.data"
var is_currently_loading: bool = false
# Used by slot displays until the first manual save.
var is_loaded_from_start_new_game: bool = false
var is_starting_new_game: bool = false
var previous_menu = ""
var previous_menu_button_pressed = ""
var pause_menu
var game_menu
var save_load_menu

var _destroyed_nodes: Array = []
var _destroyed_nodes_level_id: int = 0
var _save_index := SaveIndex.new(self)
var _slot_files := SlotFiles.new(self)
var _slots := SaveSlots.new(self)
var _player_persistence := PlayerPersistence.new(self)
var _scene_persistence := ScenePersistence.new(self)
var _transitions := SceneTransitions.new(self)
var _fade := Fade.new(self)

@onready var storage := SlotStorage.new(cogito_state_dir)
@onready var cogito_scene_state_prefix: String = CogitoGlobals.scene_state_prefix
@onready var cogito_player_state_prefix: String = CogitoGlobals.player_state_prefix
@onready var default_fade_duration: float = CogitoGlobals.default_transition_duration


func _ready() -> void:
	if CogitoNet.dedicated_boot:
		return
	if not _network_cli():
		storage.recover_all()  # Individual failures are logged and retried before use.
		delete_temp_saves()
	instantiate_fade_panel()


func _reset_playthrough_state() -> void:
	var initial_world := CogitoGlobals.cogito_settings.get_new_game_world_dict()
	_current_world_dict = initial_world.duplicate(true)
	_destroyed_nodes = []
	_destroyed_nodes_level_id = 0
	_player_state = null
	_scene_state = null
	_current_sittable_node = null
	_current_player_node = null
	_current_scene_root_node = null
	_screenshot_to_save = null
	previous_menu = ""
	previous_menu_button_pressed = ""
	pause_menu = null
	save_load_menu = null
	game_menu = null
	_active_slot = ""
	is_loaded_from_start_new_game = true
	is_starting_new_game = true


func _network_cli() -> bool:
	var args := OS.get_cmdline_user_args()
	return "--host" in args or "--server" in args or "--join" in args


func _exit_tree() -> void:
	if not _network_cli():
		delete_temp_saves()


## Returns the registered player, or null before registration and after the player is freed.
func get_player() -> CogitoPlayer:
	if CogitoNet.is_dedicated():
		return null
	if is_instance_valid(_current_player_node):
		return _current_player_node
	return null


## Called by player controllers in their _ready() to become the current player.
func register_player(player: CogitoPlayer) -> void:
	_current_player_node = player


## Sets the mouse mode the current player plays with. Called when an interface or menu closes.
func restore_gameplay_mouse_mode() -> void:
	var player := get_player()
	Input.mouse_mode = player.gameplay_mouse_mode if player else Input.MOUSE_MODE_CAPTURED


func grab_screenshot(scale: float = 1.0) -> Image:
	if DisplayServer.get_name() == "headless":
		return null
	var image: Image = get_viewport().get_texture().get_image()
	if not image or image.is_empty():
		return null
	image.resize(
		int(image.get_width() * scale), int(image.get_height() * scale), Image.INTERPOLATE_LANCZOS
	)
	return image


func send_player_hint(hint_icon: Texture2D, hint_text: String):
	get_player().player_interaction_component.send_hint(hint_icon, hint_text)


func save_last_saved_slot(slot: String) -> Error:
	return _save_index.save_last_saved_slot(slot)


func delete_from_saved_slots(slot: String) -> Error:
	return _save_index.delete_from_saved_slots(slot)


func get_last_saved_slot() -> String:
	return _save_index.get_last_saved_slot()


func is_saved_slots_empty() -> bool:
	return _save_index.is_saved_slots_empty()


func saved_slots_count() -> int:
	return _save_index.saved_slots_count()


func max_saved_slot_nubmer() -> int:
	return _save_index.max_saved_slot_nubmer()


func is_saved_slot_exist(slot: String) -> bool:
	return _save_index.is_saved_slot_exist(slot)


func player_file(slot: String) -> String:
	return _slot_files.player_file(slot)


func scene_file(slot: String, level_name: String) -> String:
	return _slot_files.scene_file(slot, level_name)


func legacy_player_file(slot: String) -> String:
	return _slot_files.legacy_player_file(slot)


func legacy_scene_file(slot: String, level_name: String) -> String:
	return _slot_files.legacy_scene_file(slot, level_name)


func prepare_slot(slot: String) -> PreparedSlot:
	return _slot_files.prepare_slot(slot)


func write_state_resource(state: Resource, path: String) -> Error:
	return _slot_files.write_state_resource(state, path)


func slot_screenshot(state: CogitoPlayerState, placeholder: Texture2D) -> Texture2D:
	return _slot_files.slot_screenshot(state, placeholder)


func slot_error(message: String, detail: String, error := FAILED) -> Error:
	return _slots.slot_error(message, detail, error)


## Ties prefer the latest manual history entry, then a directory name, then autosave.
func find_latest_loadable_slot() -> PreparedSlot:
	return _slots.find_latest_loadable_slot()


## Called only after the threaded level was successfully instantiated. Until the
## temp generation is published both the current game and its menus remain live.
func activate_saved_slot(prepared: PreparedSlot) -> Error:
	return _slots.activate_saved_slot(prepared)


func apply_saved_game(prepared: PreparedSlot) -> void:
	_slots.apply_saved_game(prepared)


## Capture temp, manual and automatic saves with the same directory transaction.
## Only a manual save promotes its slot in the existing Continue menu history.
func save_game(slot: String, update_history := true) -> Error:
	return _slots.save_game(slot, update_history)


func save_temp_game() -> Error:
	return _slots.save_temp_game()


func _save_autosave_state() -> Error:
	return _slots.save_autosave_state()


func delete_save(slot: String) -> Error:
	return _slots.delete_save(slot)


func delete_temp_saves() -> Error:
	return _slots.delete_temp_saves()


func get_existing_player_state(slot: String) -> CogitoPlayerState:
	return _player_persistence.get_existing_player_state(slot)


func load_player_state(player: CogitoPlayer, slot: String) -> void:
	_player_persistence.load_player_state(player, slot)


func _apply_player_state(player: CogitoPlayer, state: CogitoPlayerState) -> void:
	_player_persistence.apply(player, state)


## Restores the selected level instance. Defaults to the current level.
func load_scene_state(level_name: String, slot: String, level_root: Node = null) -> void:
	_scene_persistence.load_scene_state(level_name, slot, level_root)


## Writes a snapshot of the selected level instance. Defaults to the current level.
func save_scene_state(level_name: String, slot: String, level_root: Node = null) -> Error:
	return _scene_persistence.save_scene_state(level_name, slot, level_root)


## Identifies an element by its nearest saveable Persist ancestor and a relative path.
## Elements outside a Persist node use their own persistent ID.
func get_element_state_key(node: Node) -> Dictionary:
	return _scene_persistence.get_element_state_key(node)


## Returns the node of a key made by get_element_state_key(), or null.
func find_element_state_node(key: Dictionary, level_root: Node = null) -> Node:
	return _scene_persistence.find_element_state_node(key, level_root)


## Records a destroyed level node so loading frees it again. The Persist snapshot
## already accounts for missing nodes with a save() method.
func register_destroyed_node(node: Node) -> void:
	if is_instance_valid(node) and node.has_meta(&"cogito_net_world"):
		var world: Node = node.get_meta(&"cogito_net_world")
		if world.multiplayer.is_server():
			world.get_parent().spawner.remove_world_object(node)
		return
	_scene_persistence.register_destroyed_node(node)


func _get_destroyed_nodes(level_root: Node = null) -> Array:
	return _scene_persistence.destroyed_nodes(level_root)


func is_part_of_player(node: Node) -> bool:
	return _scene_persistence.is_part_of_player(node)


## @deprecated: Use [code]CogitoPersistentId.find()[/code] instead.
func find_object_from_uid(uid: int, level_root: Node = null) -> Node3D:
	return _scene_persistence.find_object_from_uid(uid, level_root)


func load_next_scene(
	target: String, connector_name: String, passed_slot: String, load_mode: CogitoSceneLoadMode
) -> Error:
	return await _transitions.load_next_scene(target, connector_name, passed_slot, load_mode)


func loading_saved_game(slot: String, _current_scene_name_unused: String = "") -> Error:
	return await _transitions.loading_saved_game(slot)


func restart_after_death() -> Error:
	return await _transitions.restart_after_death()


## Without an explicit level, start at the configured first level.
func start_new_game(level_path := "") -> Error:
	return await _transitions.start_new_game(level_path)


func finish_transition() -> void:
	_transitions.finish_transition()


## The zone owns the transition from the outgoing snapshot through the fade and level change.
func transition_from_zone(target: String, connector_name: String) -> Error:
	return await _transitions.transition_from_zone(target, connector_name)


func _new_loading_screen() -> CanvasLayer:
	return _transitions.new_loading_screen()


## Commit the reset only once the replacement level has been instantiated.
func activate_new_game() -> Error:
	return _transitions.activate_new_game()


func scene_load_failed(target: String, error: Error, message := "Cannot open level.") -> void:
	_transitions.scene_load_failed(target, error, message)


func starting_a_new_game() -> void:
	_transitions.starting_a_new_game()
	new_game_started.emit()


func instantiate_fade_panel() -> void:
	_fade.instantiate_fade_panel()


func fade_in(fade_duration: float = default_fade_duration) -> void:
	await _fade.fade_in(fade_duration)
	fade_finished.emit()


func fade_out(fade_duration: float = default_fade_duration) -> void:
	await _fade.fade_out(fade_duration)
	fade_finished.emit()

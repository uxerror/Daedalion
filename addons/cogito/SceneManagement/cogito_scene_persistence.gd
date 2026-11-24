extends RefCounted
## Captures and restores level state, including destroyed nodes, attributes and elements.

const Manager := preload("cogito_scene_manager.gd")
const PersistNodes := preload("cogito_persist_nodes.gd")

var _manager: Manager
var _nodes: PersistNodes


func _init(manager: Manager) -> void:
	_manager = manager
	_nodes = PersistNodes.new(manager)


func load_scene_state(level_name: String, slot: String) -> void:
	var path := _manager.scene_file(slot, level_name)
	var legacy := _manager.legacy_scene_file(slot, level_name)
	if FileAccess.file_exists(path) or FileAccess.file_exists(legacy):
		var report := Manager.PreparedSlot.new()
		var resource := _manager._slot_files.read_state(path, legacy, "scene", report)
		_manager._scene_state = resource as CogitoSceneState
		if _manager._scene_state:
			apply()
			_manager._slot_files.show_save_warnings(report)
		else:
			push_warning("Cannot read level state: " + path)


func apply() -> void:
	_nodes.apply_nodes()
	_load_destroyed_nodes(_manager._scene_state.saved_destroyed_nodes)
	_manager._scene_state.restore_attributes()
	# Element states go last, after the deferred set_state() calls of the Persist nodes
	# and the on-ready states of the freshly loaded level.
	_apply_element_states.call_deferred(_manager._scene_state.saved_element_states.duplicate(true))

	CogitoGlobals.debug_log(true, "CSM", "CSM: Loading scene state finished.")


func save_scene_state(level_name: String, slot: String) -> Error:
	if _manager.is_currently_loading:
		return _manager._transitions.reject_busy()
	var state := capture()
	var error := state.write_state(slot, level_name)
	if error == OK:
		_manager._scene_state = state
	return error


func capture() -> CogitoSceneState:
	var state := CogitoSceneState.new()
	_nodes.capture_nodes(state)
	state.capture_attributes(_manager.get_tree())
	state.saved_element_states = _collect_element_states()
	state.saved_destroyed_nodes = destroyed_nodes().duplicate(true)

	return state


## Identifies an element by its nearest saveable Persist ancestor and a relative path.
## Elements outside a Persist node use their own persistent ID.
func get_element_state_key(node: Node) -> Dictionary:
	var persist_node := node
	while (
		persist_node
		and not (persist_node.is_in_group("Persist") and persist_node.has_method("save"))
	):
		persist_node = persist_node.get_parent()
	if persist_node:
		return {
			"cogito_id": CogitoPersistentId.of(persist_node),
			"path": str(persist_node.get_path_to(node)),
		}
	return {"cogito_id": CogitoPersistentId.of(node), "path": "."}


## Returns the node of a key made by get_element_state_key(), or null.
func find_element_state_node(key: Dictionary) -> Node:
	var persist_node := CogitoPersistentId.find(_manager.get_tree(), str(key.get("cogito_id", "")))
	if not persist_node:
		return null
	var node := persist_node.get_node_or_null(NodePath(str(key.get("path", "."))))
	if node and CogitoPersistentId.is_disappearing(node):
		return null
	return node


## Records a destroyed level node so loading frees it again. The Persist snapshot
## already accounts for missing nodes with a save() method.
func register_destroyed_node(node: Node) -> void:
	if not is_instance_valid(node) or !node.is_inside_tree() or is_part_of_player(node):
		return
	if node.is_in_group("Persist") and node.has_method("save"):
		return
	destroyed_nodes().append(get_element_state_key(node))


# The destroyed nodes of the current level. The list starts empty in every newly loaded level.
func destroyed_nodes() -> Array:
	var level_root := CogitoPersistentId.get_level_root(_manager.get_tree())
	var level_id := level_root.get_instance_id() if level_root else 0
	if level_id != _manager._destroyed_nodes_level_id:
		_manager._destroyed_nodes = []
		_manager._destroyed_nodes_level_id = level_id
	return _manager._destroyed_nodes


func _load_destroyed_nodes(saved_destroyed_nodes: Array) -> void:
	var destroyed := destroyed_nodes()
	destroyed.clear()
	for key in saved_destroyed_nodes:
		destroyed.append(key)
		var node := find_element_state_node(key)
		if node:
			CogitoGlobals.debug_log(true, "CSM", "Removing node that was destroyed: " + node.name)
			node.queue_free()


func _collect_element_states() -> Array:
	var entries: Array = []
	for node in _manager.get_tree().get_nodes_in_group(CogitoProperties.ELEMENT_STATE_GROUP):
		if CogitoPersistentId.is_disappearing(node) or !node.has_method("get_element_save_data"):
			continue
		if is_part_of_player(node):
			continue  # Saved with the player state.
		var entry := get_element_state_key(node)
		entry["data"] = node.get_element_save_data()
		entries.append(entry)
	return entries


func _apply_element_states(entries: Array) -> void:
	var actor_entries: Array = []
	for entry in entries:
		var node := find_element_state_node(entry)
		if not node or !node.has_method("apply_element_save_data"):
			var id := str(entry.get("cogito_id")) + "/" + str(entry.get("path"))
			CogitoGlobals.debug_log(
				true, "CSM", "Element state of " + id + " has no node in the scene, skipped."
			)
			continue
		if node is CogitoActorElements:
			actor_entries.append([node, entry.get("data", {})])  # After the CogitoProperties they read.
			continue
		node.apply_element_save_data(entry.get("data", {}))
	for actor_entry in actor_entries:
		actor_entry[0].apply_element_save_data(actor_entry[1])


func is_part_of_player(node: Node) -> bool:
	var parent := node
	while parent:
		if parent is CogitoPlayer:
			return true
		parent = parent.get_parent()
	return false


## @deprecated: Use [code]CogitoPersistentId.find()[/code] instead.
func find_object_from_uid(uid: int) -> Node3D:
	for node in _manager.get_tree().get_nodes_in_group("Persist"):
		if node.get("uid") == uid:
			return node
	return null

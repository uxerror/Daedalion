extends RefCounted
## Captures and restores level state, including destroyed nodes, attributes and elements.

const Manager := preload("cogito_scene_manager.gd")
const PersistNodes := preload("cogito_persist_nodes.gd")

var _manager: Manager
var _nodes := PersistNodes.new()


func _init(manager: Manager) -> void:
	_manager = manager


## Reads and applies one level file from a slot.
func load_scene_state(level_name: String, slot: String, level_root: Node = null) -> void:
	var path := _manager.scene_file(slot, level_name)
	var legacy := _manager.legacy_scene_file(slot, level_name)
	if FileAccess.file_exists(path) or FileAccess.file_exists(legacy):
		var report := Manager.PreparedSlot.new()
		var resource := _manager._slot_files.read_state(path, legacy, "scene", report)
		var state := resource as CogitoSceneState
		if not level_root or level_root == CogitoLevel.root_of(_manager):
			_manager._scene_state = state
		if state:
			apply(state, level_root)
			_manager._slot_files.show_save_warnings(report)
		else:
			push_warning("Cannot read level state: " + path)


## Applies a snapshot and binds deferred component restoration to the same root.
func apply(state: CogitoSceneState, level_root: Node = null) -> void:
	var context := _context(level_root)
	_nodes.apply_nodes(state, context)
	_load_destroyed_nodes(state.saved_destroyed_nodes, context)
	state.restore_attributes(context)
	# Element states go last, after the deferred set_state() calls of the Persist nodes
	# and the on-ready states of the freshly loaded level.
	_apply_element_states.call_deferred(
		state.saved_element_states.duplicate(true), weakref(context)
	)

	CogitoGlobals.debug_log(true, "CSM", "CSM: Loading scene state finished.")


## Rebuild saved parents before the network registry indexes the new level.
func restore_world_nodes(state: CogitoSceneState, root: Node) -> void:
	_nodes.apply_nodes(state, root, true)
	_load_destroyed_nodes(state.saved_destroyed_nodes, root)


## The authority calls this after registering runtime entities and before admitting avatars.
func restore_world_components(state: CogitoSceneState, root: Node) -> void:
	state.restore_attributes(root)
	_apply_element_states(state.saved_element_states, weakref(root))


## Captures one live level and writes its existing save format.
func save_scene_state(level_name: String, slot: String, level_root: Node = null) -> Error:
	if _manager.is_currently_loading:
		return _manager._transitions.reject_busy()
	var state := capture(level_root)
	var error := state.write_state(slot, level_name)
	if error == OK and (not level_root or level_root == CogitoLevel.root_of(_manager)):
		_manager._scene_state = state
	return error


# Bind the actual root before deferring restoration. Some offline tools have no current scene.
func _context(level_root: Node) -> Node:
	if level_root:
		return level_root
	var current := CogitoLevel.root_of(_manager)
	return current if current else _manager


## Captures the scene model without publishing it to a slot.
func capture(level_root: Node = null) -> CogitoSceneState:
	var context := _context(level_root)
	var state := CogitoSceneState.new()
	_nodes.capture_nodes(state, context)
	state.capture_attributes(_manager.get_tree(), context)
	state.saved_element_states = _collect_element_states(context)
	state.saved_destroyed_nodes = destroyed_nodes(context).duplicate(true)

	return state


## Identifies an element by its nearest saveable Persist ancestor and a relative path.
## Elements outside a Persist node use their own persistent ID.
func get_element_state_key(node: Node) -> Dictionary:
	var persist_node := node
	var root := CogitoLevel.hosted_root(node)
	while persist_node:
		if persist_node.is_in_group("Persist") and persist_node.has_method("save"):
			return {
				"cogito_id": CogitoPersistentId.of(persist_node),
				"path": str(persist_node.get_path_to(node)),
			}
		if persist_node == root:
			break
		persist_node = persist_node.get_parent()
	return {"cogito_id": CogitoPersistentId.of(node), "path": "."}


## Returns the node of a key made by get_element_state_key(), or null.
func find_element_state_node(key: Dictionary, level_root: Node = null) -> Node:
	var context := _context(level_root)
	var persist_node := CogitoPersistentId.find_in_level(context, str(key.get("cogito_id", "")))
	if not persist_node:
		return null
	var node := CogitoPersistentId.resolve_path(context, key.get("path", "."), persist_node)
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
	destroyed_nodes(node).append(get_element_state_key(node))


## The registry belongs to the root and is released with it. Without a scene the
## offline facade retains its historical empty-level registry.
func destroyed_nodes(context: Node = null) -> Array:
	const DESTROYED := &"cogito_destroyed_nodes"
	var level_root := CogitoLevel.root_of(context if context else _manager)
	var owner := level_root if level_root else _manager
	if not owner.has_meta(DESTROYED):
		owner.set_meta(DESTROYED, [])
	if not owner.is_in_group(CogitoLevel.HOSTED_ROOT):
		# Mirror the default registry through the writable legacy facade fields.
		var level_id := level_root.get_instance_id() if level_root else 0
		if level_id == _manager._destroyed_nodes_level_id:
			owner.set_meta(DESTROYED, _manager._destroyed_nodes)
		else:
			_manager._destroyed_nodes = owner.get_meta(DESTROYED)
			_manager._destroyed_nodes_level_id = level_id
	return owner.get_meta(DESTROYED)


func _load_destroyed_nodes(saved_destroyed_nodes: Array, context: Node) -> void:
	var destroyed := destroyed_nodes(context)
	destroyed.clear()
	for key in saved_destroyed_nodes:
		destroyed.append(key)
		var node := find_element_state_node(key, context)
		if node:
			CogitoGlobals.debug_log(true, "CSM", "Removing node that was destroyed: " + node.name)
			node.queue_free()


func _collect_element_states(context: Node) -> Array:
	var entries: Array = []
	for node in CogitoLevel.nodes_in_group(context, CogitoProperties.ELEMENT_STATE_GROUP):
		if CogitoPersistentId.is_disappearing(node) or !node.has_method("get_element_save_data"):
			continue
		if is_part_of_player(node):
			continue  # Saved with the player state.
		var entry := get_element_state_key(node)
		entry["data"] = node.get_element_save_data()
		entries.append(entry)
	return entries


func _apply_element_states(entries: Array, target: WeakRef) -> void:
	var context := target.get_ref() as Node
	if not context or not context.is_inside_tree() or CogitoPersistentId.is_disappearing(context):
		return
	if context != _manager and CogitoLevel.root_of(context) != context:
		return
	var actor_entries: Array = []
	for entry in entries:
		var node := find_element_state_node(entry, context)
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
func find_object_from_uid(uid: int, level_root: Node = null) -> Node3D:
	for node in CogitoLevel.nodes_in_group(_context(level_root), &"Persist"):
		if node.get("uid") == uid:
			return node
	return null

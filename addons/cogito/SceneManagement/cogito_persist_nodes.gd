extends RefCounted
## Captures and restores nodes in the Persist and save_object_state groups.

const Manager := preload("cogito_scene_manager.gd")

const NODE_RECORD_KEYS := [
	"filename", "parent", "pos_x", "pos_y", "pos_z", "rot_x", "rot_y", "rot_z"
]

var _manager: Manager


func _init(manager: Manager) -> void:
	_manager = manager


func capture_nodes(state: CogitoSceneState) -> void:
	var root := CogitoPersistentId.get_level_root(_manager.get_tree())
	if root and root.has_meta(CogitoPersistentId.LEVEL_IDS_META):
		state.known_persist_ids = root.get_meta(CogitoPersistentId.LEVEL_IDS_META).duplicate()
	var save_nodes := _manager.get_tree().get_nodes_in_group("Persist")
	if not save_nodes:
		CogitoGlobals.debug_log(true, "CSM", "No nodes in Persist group!")
	for node in save_nodes:
		if CogitoPersistentId.is_disappearing(node):
			continue
		# Only authored nodes can be restored in place without a scene file.
		if (
			node.scene_file_path.is_empty()
			and not CogitoPersistentId.of(node).begins_with("level:")
		):
			CogitoGlobals.debug_log(
				true, "CSM", "persistent node '%s' is not an instanced scene, skipped" % node.name
			)
			continue

		if not node.has_method("save"):
			CogitoGlobals.debug_log(
				true,
				"CSM",
				"persistent node '%s' is missing a save() function, skipped" % node.name
			)
			continue

		var node_data: Variant = node.save()
		node_data["cogito_id"] = CogitoPersistentId.of(node)
		node_data["cogito_parent_id"] = CogitoPersistentId.of(node.get_parent())
		if node is RigidBody3D:
			node_data["linear_velocity_x"] = node.linear_velocity.x
			node_data["linear_velocity_y"] = node.linear_velocity.y
			node_data["linear_velocity_z"] = node.linear_velocity.z
			node_data["angular_velocity_x"] = node.angular_velocity.x
			node_data["angular_velocity_y"] = node.angular_velocity.y
			node_data["angular_velocity_z"] = node.angular_velocity.z
		state.add_node_data_to_array(node_data)

	var state_nodes := _manager.get_tree().get_nodes_in_group("save_object_state")
	if not state_nodes:
		CogitoGlobals.debug_log(true, "CSM", "No nodes in save_object_state group!")
	for node in state_nodes:
		if CogitoPersistentId.is_disappearing(node):
			continue
		if not node.has_method("save"):
			CogitoGlobals.debug_log(
				true,
				"CSM",
				"persistent node '%s' is missing a save() function, skipped" % node.name
			)
			continue

		var state_data: Variant = node.save()
		state_data["cogito_id"] = CogitoPersistentId.of(node)
		state.add_state_data_to_array(state_data)


func apply_nodes() -> void:
	# A saved pickup without its item cannot be interacted with or saved again.
	_manager._scene_state.saved_nodes = _manager._scene_state.saved_nodes.filter(
		func(entry: Dictionary) -> bool:
			return not entry.has("slot_data") or entry.slot_data != null
	)
	if _manager._scene_state.saved_nodes.all(func(node_data): return node_data.has("cogito_id")):
		_load_persist_nodes_in_place(_manager._scene_state.saved_nodes)
	else:
		_load_persist_nodes_legacy(_manager._scene_state.saved_nodes)

	for state_data in _manager._scene_state.saved_states:
		var node_to_set: Node = _find_saved_node(state_data, "cogito_id", "node_path")
		if not node_to_set:
			var id := str(state_data.get("cogito_id", state_data.get("node_path")))
			CogitoGlobals.debug_log(
				true, "CSM", "Saved object " + id + " not found in the scene, skipped."
			)
			continue
		_restore_transform(node_to_set, state_data)
		_restore_properties(node_to_set, state_data, false)
		if node_to_set.has_method("set_state"):
			node_to_set.set_state()


## Updates matching nodes in place, respawns missing saved nodes and removes eligible live
## nodes omitted by the snapshot.
func _load_persist_nodes_in_place(saved_nodes: Array) -> void:
	var saved_ids := {}
	for node_data in saved_nodes:
		saved_ids[node_data["cogito_id"]] = true

	var live_nodes := {}
	for node in _manager.get_tree().get_nodes_in_group("Persist"):
		if CogitoPersistentId.is_disappearing(node):
			continue
		var id := CogitoPersistentId.of(node)
		if saved_ids.has(id):
			live_nodes[id] = node
		elif node.has_method("save") and _manager._scene_state.removes_missing_node(node, id):
			CogitoGlobals.debug_log(
				true, "CSM", "Removing node that is not in the save: " + node.name
			)
			node.queue_free()

	for node_data in saved_nodes:
		var node: Node = live_nodes.get(node_data["cogito_id"])
		if not node:
			node = _spawn_saved_node(node_data)
			if not node:
				continue
		_apply_saved_node_data(node, node_data)


## Saves made before persistent IDs require deleting and recreating the entire group.
func _load_persist_nodes_legacy(saved_nodes: Array) -> void:
	var save_nodes := _manager.get_tree().get_nodes_in_group("Persist")
	for node in save_nodes:
		CogitoGlobals.debug_log(true, "CSM", "Deleting existing node: " + node.name)
		node.queue_free()

	for node_data in saved_nodes:
		var new_object := _spawn_saved_node(node_data)
		if new_object:
			_apply_saved_node_data(new_object, node_data)


func _spawn_saved_node(node_data: Dictionary) -> Node:
	if str(node_data.get("filename", "")).is_empty():
		CogitoGlobals.debug_log(
			true,
			"CSM",
			(
				"Saved node %s is not in the level and has no scene file, skipped."
				% str(node_data.get("cogito_id"))
			)
		)
		return null
	var parent_node: Node = _find_saved_node(node_data, "cogito_parent_id", "parent")
	if not parent_node:
		CogitoGlobals.debug_log(
			true, "CSM", "Parent of saved node %s not found, skipped." % str(node_data["filename"])
		)
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
	CogitoGlobals.debug_log(true, "CSM", "Adding to scene: " + new_object.get_name())
	return new_object


func _apply_saved_node_data(new_object: Node, node_data: Dictionary) -> void:
	_restore_transform(new_object, node_data)
	if new_object is RigidBody3D:
		if node_data.has_all(["linear_velocity_x", "linear_velocity_y", "linear_velocity_z"]):
			new_object.linear_velocity = Vector3(
				node_data["linear_velocity_x"],
				node_data["linear_velocity_y"],
				node_data["linear_velocity_z"]
			)
		if node_data.has_all(["angular_velocity_x", "angular_velocity_y", "angular_velocity_z"]):
			new_object.angular_velocity = Vector3(
				node_data["angular_velocity_x"],
				node_data["angular_velocity_y"],
				node_data["angular_velocity_z"]
			)
	_restore_properties(new_object, node_data, true)

	if new_object.has_method("update_wieldable_data"):
		CogitoGlobals.debug_log(
			true,
			"CSM",
			"Setting charge of %s to %s" % [str(new_object), str(node_data["item_charge"])]
		)
		new_object.slot_data.inventory_item.charge_current = node_data["item_charge"]

	if new_object.has_method("set_state"):
		new_object.set_state.call_deferred()


func _restore_transform(node: Node, data: Dictionary) -> void:
	node.position = Vector3(data["pos_x"], data["pos_y"], data["pos_z"])
	node.rotation = Vector3(data["rot_x"], data["rot_y"], data["rot_z"])


func _restore_properties(node: Node, data: Dictionary, skip_item_charge: bool) -> void:
	for key in data.keys():
		if key == "inventory_data" and data[key] == null:
			continue  # Keep the inventory instantiated with the level.
		if key in NODE_RECORD_KEYS or key in Manager.SAVE_ID_KEYS:
			continue
		if skip_item_charge and key == "item_charge":
			continue
		node.set(key, data[key])


## Pre-ID entries identify nodes by their absolute path.
func _find_saved_node(data: Dictionary, id_key: String, legacy_path_key: String) -> Node:
	if data.has(id_key):
		return CogitoPersistentId.find(_manager.get_tree(), data[id_key])
	if data.has(legacy_path_key):
		return _manager.get_node_or_null(data[legacy_path_key])
	return null

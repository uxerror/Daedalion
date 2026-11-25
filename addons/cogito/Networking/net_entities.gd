extends RefCounted
## The object and component tables for one bound level instance. Wire keys never resolve paths.

## Root of the live level instance.
var root: Node
## Game-defined level key, shared by peers loading the same content.
var level_key: String
## Server-issued generation, zero until the client has its baseline.
var epoch := 0
## Registered roots indexed by persistent id.
var objects: Dictionary[String, Node] = {}
var _ids: Dictionary[Node, String] = {}
var _components := {}
var _owners: Dictionary[InteractionComponent, Node] = {}


## Index authored objects after their children have initialized. Reject every ambiguous binding.
func bind(level: Node, key: String, generation: int) -> void:
	root = level
	level_key = key
	epoch = generation
	var candidates := {}
	for node in root.find_children("*", "Node3D", true, false):
		if CogitoLevel.root_of(node) != root:
			continue
		if _needs_parent_address(node):
			candidates[node.get_parent()] = true
		if (
			node.has_method("net_state")
			or node.is_in_group("Persist")
			or node.is_in_group("save_object_state")
		):
			candidates[node] = true
	var seen := {}
	for node: Node in candidates:
		var id := CogitoPersistentId.of(node)
		if seen.has(id):
			push_error("Duplicate network entity '%s' in level '%s'" % [id, key])
			objects.erase(id)
		else:
			seen[id] = true
			objects[id] = node
	for id in objects.keys():
		var node := objects[id]
		if not node.has_method("net_state") and not _has_addressable_child(node):
			objects.erase(id)
			continue
		if node.has_method("net_state"):
			if not node.has_method("apply_net_state") or not node.has_signal("net_changed"):
				push_error("Incomplete network state adapter for '%s' in level '%s'" % [id, key])
				objects.erase(id)
				continue
		_ids[node] = id
		var components := {}
		for child in node.find_children("*", "InteractionComponent", true, false):
			# Nested objects own their own components.
			var parent := child.get_parent()
			while parent != node and not candidates.has(parent):
				parent = parent.get_parent()
			if parent == node:
				# A stateful component also has its own baseline row. Reject an ambiguous id.
				if (
					child.has_method("net_state")
					and objects.get(CogitoPersistentId.of(child)) != child
				):
					continue
				components[str(node.get_path_to(child))] = child
				_owners[child as InteractionComponent] = node
		_components[id] = components


func _needs_parent_address(node: Node) -> bool:
	return node is ReadableComponent or node is SpinnerInteraction or node is LockpickInteraction


func _has_addressable_child(node: Node) -> bool:
	for child in node.get_children():
		if _needs_parent_address(child):
			return true
	return false


## Reject a removed, queued or reparented object even if the content was present at bind.
func live_object(id: String) -> Node:
	var node: Variant = objects.get(id)
	if not is_instance_valid(node) or not node.is_inside_tree():
		return null
	if CogitoLevel.root_of(node) != root or CogitoPersistentId.is_disappearing(node):
		return null
	return node


## Persistent id of a registered object root in this instance.
func id_for(node: Node) -> String:
	var id: String = _ids.get(node, "")
	return id if live_object(id) == node else ""


## Return the scoped wire address of a live component.
func address(component: InteractionComponent) -> Dictionary:
	var node: Variant = _owners.get(component)
	if not is_instance_valid(node) or not is_instance_valid(component) or id_for(node).is_empty():
		return {}
	return {"entity_id": _ids[node], "component_key": str(node.get_path_to(component))}


## Only bound keys accepted at bind time can select a component.
func resolve(id: String, key: String) -> InteractionComponent:
	var node := live_object(id)
	if not node:
		return null
	var component: Variant = _components[id].get(key)
	if is_instance_valid(component) and node.is_ancestor_of(component):
		return component
	return null


## Match both the live level and its server generation.
func matches(key: String, generation: int) -> bool:
	return is_instance_valid(root) and level_key == key and epoch == generation and epoch > 0

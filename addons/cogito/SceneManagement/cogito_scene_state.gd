class_name CogitoSceneState
extends Resource

## Set of authored Persist IDs captured at level entry. Null denotes a pre-manifest save.
@export_storage var known_persist_ids: Variant
@export var saved_nodes : Array
@export var saved_states : Array
## Element states (CogitoProperties, CogitoElementArea, CogitoActorElements) of the scene.
## Entries: {"cogito_id", "path", "data"}, see CogitoSceneManager.get_element_state_key().
@export var saved_element_states : Array
## Nodes destroyed during play that aren't Persist nodes (e.g. burned out with BurnOutResult.DESTROY).
## Entries: {"cogito_id", "path"}. They get freed again when the scene state loads.
@export var saved_destroyed_nodes : Array


## Current and maximum values for scene components, including those on static objects.
@export var saved_attribute_states: Array[Dictionary] = []


func removes_missing_node(node: Node, id: String) -> bool:
	if known_persist_ids == null or known_persist_ids.has(id):
		return true
	var root := CogitoLevel.root_of(node)
	return not CogitoPersistentId.is_from_level(root, node)


func capture_attributes(tree: SceneTree, context: Node = null) -> void:
	saved_attribute_states.clear()
	if not context:
		context = tree.root
	var attributes := CogitoLevel.nodes_in_group(context, CogitoAttribute.SAVE_GROUP)
	for attribute: CogitoAttribute in attributes:
		if (
			CogitoPersistentId.is_disappearing(attribute)
			or CogitoSceneManager.is_part_of_player(attribute)
		):
			continue
		var entry := CogitoSceneManager.get_element_state_key(attribute)
		entry["max"] = attribute.value_max
		if not attribute.dont_save_current_value:
			entry["value"] = attribute.value_current
		saved_attribute_states.append(entry)


func restore_attributes(context: Node = null) -> void:
	for entry in saved_attribute_states:
		var attribute := CogitoSceneManager.find_element_state_node(entry, context) as CogitoAttribute
		if attribute:
			attribute.restore_attribute(entry.get("value", attribute.value_current), entry.max)


func clear_saved_nodes():
	saved_nodes.clear()


func clear_saved_states():
	saved_states.clear()


func add_node_data_to_array(node_data):
	saved_nodes.append(node_data)


func add_state_data_to_array(state_data):
	saved_states.append(state_data)


func write_state(slot: String, level_name: String) -> Error:
	return CogitoSceneManager.write_state_resource(self, CogitoSceneManager.scene_file(slot, level_name))

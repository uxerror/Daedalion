class_name CogitoSceneState
extends Resource

@export var saved_nodes : Array
@export var saved_states : Array
## Element states (CogitoProperties, CogitoElementArea, CogitoActorElements) of the scene.
## Entries: {"cogito_id", "path", "data"}, see CogitoSceneManager.get_element_state_key().
@export var saved_element_states : Array
## Nodes destroyed during play that aren't Persist nodes (e.g. burned out with BurnOutResult.DESTROY).
## Entries: {"cogito_id", "path"}. They get freed again when the scene state loads.
@export var saved_destroyed_nodes : Array


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

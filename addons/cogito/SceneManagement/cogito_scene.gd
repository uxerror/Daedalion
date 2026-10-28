extends Node

## List of connector nodes. These are used to place the Player in the correct position when they transition to this scene from a different scene. The Node name needs to match the passed string for this to work.
@export var connectors : Array[Node3D]
## Saves scene and player temp states
@export var save_temp_on_enter : bool = false

@export_category("Music Settings")
## Music played while this scene is active. If the next scene uses the same layers, they keep playing.
## Leave empty for no music.
@export var music_state : CogitoMusicState
## Music requested by NPCs while they chase, attack or search for the player. NPCs with their own
## combat_music_state use that instead. Leave empty for no combat music.
@export var combat_music_state : CogitoMusicState


func move_player_to_connector(connector_name:String):
	for node in connectors:
		if node.get_name() == connector_name:
			CogitoGlobals.debug_log(true, "CogitoScene.gd", "Connector found, moving player to " + node.get_name() )
			CogitoSceneManager._current_player_node.global_position = node.global_position
			CogitoSceneManager._current_player_node.body.global_rotation = node.global_rotation
			return
	
	CogitoGlobals.debug_log(true, "CogitoScene.gd",  "No connector with name " + connector_name + " found.")


func _enter_tree() -> void:
	CogitoSceneManager._current_scene_root_node = self
	CogitoGlobals.debug_log(true, "CogitoScene.gd", "Current scene root node set to " + CogitoSceneManager._current_scene_root_node.name )
	
	CogitoAudio.set_scene_music_state(music_state, combat_music_state)
	if save_temp_on_enter:
		save_temp.call_deferred()


func save_temp() -> void:
	var current_scene_statename = get_tree().get_current_scene().get_name()
	CogitoSceneManager.save_scene_state(current_scene_statename,"temp")
	CogitoSceneManager.save_player_state(CogitoSceneManager._current_player_node, "temp")


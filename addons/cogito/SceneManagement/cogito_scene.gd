extends Node

## Optional translated name for multiplayer travel messages.
@export var level_display_name: String
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


var _network_start := Transform3D.IDENTITY


## Uses the authored controller as the online spawn marker, including when opening a
## session in an already running level. A dedicated scene can provide just a Player marker.
func bind_network_players() -> void:
	var world := CogitoNet.player_world
	if not world or world.active_level() == self:
		return
	var marker := get_node_or_null("Player") as Node3D
	if not marker:
		for child in get_children():
			if child is CogitoPlayer:
				marker = child
				break
	if marker:
		if marker == CogitoSceneManager.get_player():
			CogitoSceneManager.register_player(null)
		if marker is CogitoPlayerAdvanced and marker.is_node_ready():
			# Opening a session in a running solo level replaces the original controller.
			var held: Variant = marker.player_interaction_component.carrying.carried_object
			if is_instance_valid(held):
				held.leave()
			var seat: CogitoSittable = marker.current_seat
			if is_instance_valid(seat) and seat.player_node == marker:
				seat._stand_up(false)
				seat.player_node = null
				seat.occupant_id = ""
				marker.current_seat = null
		_network_start = marker.transform
		marker.free()
	if is_node_ready():
		world.travel.bind_scene(self, _network_start, scene_file_path)
	else:
		var bind: Callable = world.travel.bind_scene.bind(self, _network_start, scene_file_path)
		ready.connect(bind, CONNECT_DEFERRED | CONNECT_ONE_SHOT)


func move_player_to_connector(connector_name:String):
	for node in connectors:
		if node.get_name() == connector_name:
			CogitoGlobals.debug_log(true, "CogitoScene.gd", "Connector found, moving player to " + node.get_name() )
			CogitoSceneManager.get_player().global_position = node.global_position
			CogitoSceneManager.get_player().body.global_rotation = node.global_rotation
			return
	
	CogitoGlobals.debug_log(true, "CogitoScene.gd",  "No connector with name " + connector_name + " found.")


func _enter_tree() -> void:
	if has_meta(&"network_level_key"):
		return
	if CogitoNet.is_online():
		if not CogitoNet.is_dedicated():
			CogitoAudio.set_scene_music_state(music_state, combat_music_state)
		bind_network_players()
		return
	if CogitoLevel.hosted_root(self):
		return
	CogitoSceneManager._current_scene_root_node = self
	CogitoGlobals.debug_log(true, "CogitoScene.gd", "Current scene root node set to " + CogitoSceneManager._current_scene_root_node.name )
	
	CogitoAudio.set_scene_music_state(music_state, combat_music_state)
	# Managed transitions take the snapshot after restore and connector placement.
	if save_temp_on_enter and not CogitoSceneManager.is_currently_loading:
		save_temp.call_deferred()


# A notification instead of _ready(), so scenes that extend this script and override _ready() still get it.
func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		# Every node of the level is ready now, so the Persist nodes placed in it get their ids before anything moves.
		CogitoPersistentId.stamp_level(self)


func save_temp() -> void:
	CogitoSceneManager.save_temp_game()

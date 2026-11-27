extends Area3D

### Level scene to transition to
@export var target_scene : PackedScene = null
## Level scene to transition to
@export_file("*.tscn") var target_scene_path : String
## Name of connector node the player should transition to in target scene. This node needs to exist in the target scene and has to be added to the connector array of the target scene cogito_scene script.
@export var target_connector : String


func _ready():
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	
	
func _on_body_entered(body: Node3D):
	if body is CogitoPlayerAdvanced and body.network_movement_only:
		var root := CogitoLevel.hosted_root(self)
		if root and root.has_meta(&"cogito_net_players") and multiplayer.is_server():
			root.get_meta(&"cogito_net_players").travel.enter(self, body)
		return
	if body is not CogitoPlayer:
		return
	
	transition_to_next_scene()

	
func _on_body_exited(body: Node3D):
	if body.has_meta(&"travel_arrival_zones"):
		var root := CogitoLevel.hosted_root(self)
		var guarded: PackedStringArray = body.get_meta(&"travel_arrival_zones")
		if root:
			guarded.erase(str(root.get_path_to(self)))
			body.set_meta(&"travel_arrival_zones", guarded)
	if body.has_meta(&"travel_spawn_zone"):
		var root := CogitoLevel.hosted_root(self)
		if root and str(root.get_path_to(self)) == body.get_meta(&"travel_spawn_zone"):
			body.remove_meta(&"travel_spawn_zone")
	if body is not CogitoPlayer:
		return


func transition_to_next_scene() -> Error:
	return await CogitoSceneManager.transition_from_zone(target_scene_path, target_connector)

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
	if body is not CogitoPlayer:
		return
	
	transition_to_next_scene()

	
func _on_body_exited(body: Node3D):
	if body is not CogitoPlayer:
		return


func transition_to_next_scene():
	if CogitoSceneManager.save_temp_game() != OK:
		return

	CogitoSceneManager.is_currently_loading = true
	
	CogitoSceneManager.fade_out()
	await CogitoSceneManager.fade_finished
	
	# CogitoSceneManager.load_next_scene(path_to_new_scene, target_connector, "temp", CogitoSceneManager.CogitoSceneLoadMode.TEMP)
	CogitoSceneManager.load_next_scene(target_scene_path, target_connector, "temp", CogitoSceneManager.CogitoSceneLoadMode.TEMP)

@icon("res://addons/cogito/Assets/Graphics/Editor/Icon_CogitoObject.svg")
class_name CogitoTurnwheel
extends AnimatableBody3D

## Publishes wheel pose and hold audio edges.
signal net_changed(event: StringName)

signal object_state_updated(interaction_text : String)

@export var audio_stream_player_3d: AudioStreamPlayer3D

## Name that will displayed when interacting. Leave blank to hide
@export var display_name : String

enum PromptPositionMode{
	ORIGIN, ## at the objects origin point. Recommended for smaller objects.
	MARKER, ## at the position of an assigned Marker3D node. Will throw an error if no marker is assigned. Recommended for big objects/doors.
	AABB_CENTER, ## at the center of the calculated AABoundingBox. Works well but has a slight performance impact. 
}
## This sets where interaction prompt gets displayed on the object.
@export var prompt_pos_mode : PromptPositionMode = PromptPositionMode.ORIGIN
@export var prompt_marker : Marker3D

## Define the axis the object will rotate.
@export var rotation_axis : Vector3 = Vector3(1,0,0)
## Rotation speed in radians per second.
@export var rotation_speed : float = 1
## Drag the nodes you want to get triggered in here from your scene hierarchy. Their interact func will be called when hold is complete.
@export var nodes_to_trigger : Array[Node]
## AudioStream to play while holding.
@export var hold_audio_stream : AudioStream

var has_been_turned: bool = false
var interaction_nodes : Array[Node]
var cogito_properties : CogitoProperties = null
var _net_motion: Tween
var _net_rotation := Quaternion.IDENTITY
var _has_net_rotation := false

func _ready():
	self.add_to_group("save_object_state")
	self.add_to_group("interactable")
	
	interaction_nodes = find_children("","InteractionComponent",true) #Grabs all attached interaction components
	
	if !audio_stream_player_3d:
		var players = find_children("", "AudioStreamPlayer3D")
		if len(players) > 0: audio_stream_player_3d = players[0]
	
	if audio_stream_player_3d:
		audio_stream_player_3d.stream = hold_audio_stream
	
	for node in interaction_nodes:
		if node and node.has_signal("is_being_held"):
			node.is_being_held.connect(_is_being_turned) 


func _is_being_turned(_time_remaining:float, _delta_time: float):
	if audio_stream_player_3d and !audio_stream_player_3d.playing:
		audio_stream_player_3d.play()
		
	if has_been_turned:
		self.rotate_object_local(rotation_axis * -1,rotation_speed * _delta_time)
	else:
		self.rotate_object_local(rotation_axis,rotation_speed * _delta_time)
	

func interact(_player_interaction_component):
	if audio_stream_player_3d: audio_stream_player_3d.stop()
	has_been_turned = !has_been_turned
	CogitoGlobals.debug_log(true,"cogito_turnwheel.gd", "Turnwheel has been turned: " + str(has_been_turned) )
	for node in nodes_to_trigger:
		node.interact(null)


## Commit a completed server hold with the instigator for authored links.
func net_complete(actor: PlayerInteractionComponent) -> void:
	has_been_turned = not has_been_turned
	var world: Node = get_meta(&"cogito_net_world")
	for target in nodes_to_trigger:
		world.activate_link(target, actor)


## Keep the commanded pose available while AnimatableBody3D synchronizes with physics.
func net_rotate(pose: Quaternion) -> void:
	_has_net_rotation = true
	_net_rotation = pose
	quaternion = pose


## Publish authority motion and present the same audio edge on a listen host.
func net_publish(event: StringName) -> void:
	present_net_event(event)
	net_changed.emit(event)


## Replicate the physical wheel pose independently of its links.
func net_state() -> Dictionary:
	return {"turned": has_been_turned, "rotation": _net_rotation if _has_net_rotation else quaternion}


## Snap a baseline or interpolate a live rotation.
func apply_net_state(state: Dictionary, silent: bool) -> void:
	has_been_turned = state.turned
	if _net_motion:
		_net_motion.kill()
	if silent:
		var sync := sync_to_physics
		sync_to_physics = false
		quaternion = state.rotation
		force_update_transform()
		reset_physics_interpolation()
		sync_to_physics = sync
	else:
		_net_motion = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		_net_motion.tween_property(self, ^"quaternion", state.rotation, 0.06)


## A departing observer can leave while another player is still holding the wheel.
func net_unbind() -> void:
	_has_net_rotation = false
	if _net_motion:
		_net_motion.kill()
		_net_motion = null
	present_net_event(&"stop")


## Loop the authored sound between the start and stop events.
func present_net_event(event: StringName) -> void:
	if not audio_stream_player_3d or not hold_audio_stream:
		return
	if event == &"start":
		if not audio_stream_player_3d.finished.is_connected(audio_stream_player_3d.play):
			audio_stream_player_3d.finished.connect(audio_stream_player_3d.play)
		audio_stream_player_3d.play()
	elif event == &"stop":
		if audio_stream_player_3d.finished.is_connected(audio_stream_player_3d.play):
			audio_stream_player_3d.finished.disconnect(audio_stream_player_3d.play)
		audio_stream_player_3d.stop()


func set_state():
	pass

func save():
	var state_dict = {
		"node_path" : self.get_path(),
		"has_been_turned" : has_been_turned,
		"pos_x" : position.x,
		"pos_y" : position.y,
		"pos_z" : position.z,
		"rot_x" : rotation.x,
		"rot_y" : rotation.y,
		"rot_z" : rotation.z,
		
	}
	return state_dict

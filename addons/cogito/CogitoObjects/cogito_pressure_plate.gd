@icon("res://addons/cogito/Assets/Graphics/Editor/Icon_CogitoObject.svg")
class_name CogitoPressureplate
extends Node3D

## Authoritative change observed by the bound level's replication endpoint.
signal net_changed(event: StringName)
signal object_state_updated(interaction_text: String) #used to display correct interaction prompts
signal plate_activated()
signal plate_deactivated()
signal damage_received(damage_value:float)


## Sets this pressure plate as active (can be activated etc)
@export var is_usable : bool = true
## Toggle if switchable can be interacted with repeatedly or not.
@export var allows_repeated_interaction : bool = true
@export var audio_stream_player_3d: AudioStreamPlayer3D
## Sound that plays when weighed down.
@export var activation_sound : AudioStream

## Nodes that will have their interact function called when this switch is used.
@export var objects_call_interact : Array[NodePath]
@export var objects_call_delay : float = 0.0

@export_group("Plate settings")
@export var plate_node : Node3D
@export var unweighted_plate_position : Vector3
@export var weighted_down_plate_position : Vector3
@export var tween_time : float = .3

var is_activated : bool = false
var cogito_properties : CogitoProperties = null
var player_interaction_component : PlayerInteractionComponent
var _sensor: Area3D
var _occupants: Array[PhysicsBody3D] = []
var _was_frozen := false

@onready var base: StaticBody3D = $Base


func _ready():
	add_to_group("save_object_state")
	if not audio_stream_player_3d:
		var players: Array[Node] = find_children("", "AudioStreamPlayer3D")
		if len(players) > 0: audio_stream_player_3d = players[0]
	
	if audio_stream_player_3d:
		audio_stream_player_3d.stream = activation_sound


func weigh_down():
	if is_inside_tree() and not multiplayer.is_server():
		return
	if audio_stream_player_3d: audio_stream_player_3d.play()
	
	is_activated = true
	if has_meta(&"cogito_net_world"):
		net_changed.emit(&"down")
	plate_activated.emit()
	
	if !objects_call_interact:
		return
	var instigator := player_interaction_component
	var needs_actor := is_instance_valid(instigator)
	var online := has_meta(&"cogito_net_world")
	var world: Node = get_meta(&"cogito_net_world") if online else null
	for nodepath in objects_call_interact:
		await CogitoLevel.delay(self, objects_call_delay)
		if nodepath != null:
			var object = get_node(nodepath)
			if not online:
				object.interact(player_interaction_component)
			elif is_instance_valid(world) and (not needs_actor or is_instance_valid(instigator)):
				world.activate_link(object, instigator)


func _physics_process(_delta: float) -> void:
	if _sensor or (is_inside_tree() and not multiplayer.is_server()):
		return
	if !is_activated and (plate_node.position - weighted_down_plate_position).length() <= 0.03:
		weigh_down()
	if is_activated and (plate_node.position - weighted_down_plate_position).length() > 0.03:
		weight_lifted()


func weight_lifted():
	if is_inside_tree() and not multiplayer.is_server():
		return
	is_activated = false
	if has_meta(&"cogito_net_world"):
		net_changed.emit(&"up")
	plate_deactivated.emit()


func set_state():
	if is_activated:
		plate_node.position = weighted_down_plate_position
	else:
		plate_node.position = unweighted_plate_position


func save():
	var state_dict = {
		"node_path" : self.get_path(),
		"is_activated" : is_activated,
		"is_usable" : is_usable,
		"pos_x" : position.x,
		"pos_y" : position.y,
		"pos_z" : position.z,
		"rot_x" : rotation.x,
		"rot_y" : rotation.y,
		"rot_z" : rotation.z,
		
	}
	return state_dict


func _on_plate_body_exited(body: Node) -> void:
	if _sensor:
		return
	if is_inside_tree() and not multiplayer.is_server():
		return
	if body is CogitoObject:
		CogitoGlobals.debug_log(true,"cogito_pressure_plate.gd", str(body) + " has exited.")
		weight_lifted()
	if body is CogitoPlayer:
		plate_node.constant_force = Vector3(0, 0, 0)


func _on_plate_body_entered(body: Node) -> void:
	if _sensor:
		return
	if is_inside_tree() and not multiplayer.is_server():
		return
	CogitoGlobals.debug_log(true,"cogito_pressure_plate.gd","Detected " + body.name)
	if body is CogitoPlayer:
		CogitoGlobals.debug_log(true,"cogito_pressure_plate.gd", "Player detected. applying force.")
		plate_node.add_constant_central_force(Vector3(0,-3,0))

## Use an overlap above the moving plate to count simultaneous authoritative occupants.
func net_bind_authority() -> void:
	net_bind_replica()
	_sensor = Area3D.new()
	_sensor.collision_layer = 0
	_sensor.collision_mask = 0xffffffff
	for source in plate_node.find_children("*", "CollisionShape3D", true, false):
		var shape := source as CollisionShape3D
		var copy := CollisionShape3D.new()
		copy.shape = shape.shape
		copy.transform = global_transform.affine_inverse() * shape.global_transform
		copy.position.y += 0.10
		_sensor.add_child(copy)
	_sensor.body_entered.connect(_net_enter)
	_sensor.body_exited.connect(_net_exit)
	add_child(_sensor)


func _net_enter(body: Node3D) -> void:
	if not is_usable or not body is PhysicsBody3D or is_ancestor_of(body):
		return
	# Offline only players (explicit force) and physics weights press the plate. A walking NPC
	# and its bone hitboxes never do, so an investigating NPC must not hold a lamp on.
	if (body is CharacterBody3D and not body is CogitoPlayer) or body.owner is CogitoNPC:
		return
	_occupants.append(body)
	if not is_activated:
		player_interaction_component = null
		if body is CogitoPlayer:
			player_interaction_component = body.player_interaction_component
		weigh_down()
		set_state()


func _net_exit(body: Node3D) -> void:
	_occupants.erase(body)
	if _occupants.is_empty() and is_activated and allows_repeated_interaction:
		weight_lifted()
		set_state()


## Restore the original offline solver when ending a session in a running scene.
func net_unbind() -> void:
	if _sensor:
		_sensor.queue_free()
		_sensor = null
	_occupants.clear()
	set_physics_process(true)
	if plate_node is RigidBody3D:
		plate_node.freeze = _was_frozen


## Disable the replica sensor including its independently simulated rigid body.
func net_bind_replica() -> void:
	set_physics_process(false)
	if plate_node is RigidBody3D:
		_was_frozen = plate_node.freeze
		plate_node.freeze = true


## State of the authoritative plate sensor.
func net_state() -> Dictionary:
	return {"pressed": is_activated}


## Position the plate without activating its targets.
func apply_net_state(state: Dictionary, _silent: bool) -> void:
	is_activated = state.pressed
	set_state()


## Only the downstroke has a configured sound.
func present_net_event(event: StringName) -> void:
	if event == &"down" and audio_stream_player_3d:
		audio_stream_player_3d.play()

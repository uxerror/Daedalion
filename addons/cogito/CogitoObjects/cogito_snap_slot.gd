@tool
extends Node3D
class_name CogitoSnapSlot

signal net_changed(event: StringName)
signal object_placed
signal object_removed
signal object_state_updated(interaction_text:String)

@onready var snap_area_3d: Area3D = $SnapArea3D
@onready var snap_shape: Node3D = $SnapShape
@onready var snap_position: Node3D = $SnapPosition

## PackedScene of the carryable object that this snapslot is expecting.
@export var expected_object : PackedScene

enum PromptPositionMode{
	ORIGIN, MARKER, AABB_CENTER, 
}
## This sets where interaction prompt gets displayed on the object. ORIGIN = at the objects origin point. Recommended for smaller objects. MARKER = at the position of an assigned Marker3D node. Recommended for big objects/doors. AABB_CENTER = at the center of the calculated AABoundingBox. Works well but has a slight performance impact. 
@export var prompt_pos_mode : PromptPositionMode = PromptPositionMode.ORIGIN
@export var prompt_marker : Marker3D

@export_group("Audio")
## Plays when object is snapped into place.
@export var object_placement_sound : AudioStream
## Plays when object is removed from the slot.
@export var object_removed_sound : AudioStream
## Audio that is played continuiosly while object is placed.
@export var active_sound_loop : AudioStream

@export_group("Interaction Settings")
## Is active or not. You might want to only activate this slot when another condition is met. Also used to deactivate after object is placed.
@export var is_active : bool = true
## Text that appears on the interaction prompt when an inventory item is expected.
@export var interaction_text_to_place : String = "Place"
## Text that appears on the interaction prompt when an object is placed that can be removed.
@export var interaction_text_to_remove : String = "Remove"
## Hint that is displayed if the player interacts while the snapslot is empty.
@export var expected_object_hint : String = "Looks like an object could fit here."
## Delay in seconds after slotting or removing an object. This is there to prevent immediate re-slotting of an object that can be removed.
@export var setter_delay : float = 0.8

var instanced_expected_object
var preloaded_expected_item
var spawned_object = null
var interaction_text = null
var interaction_nodes : Array[Node]
var cogito_properties : CogitoProperties = null
var player_interaction_component : PlayerInteractionComponent
## Stable MP2 address of the body occupying this slot.
@onready var snapped_id := ""


var is_holding_object : bool:
	set(value):
		is_holding_object = value
		
		if snap_shape:
			snap_shape.visible = !is_holding_object
		
		if has_meta(&"cogito_net_world"):
			interaction_text = interaction_text_to_remove if value else interaction_text_to_place
			return

		if is_holding_object:
			object_placed.emit()
			interaction_text = interaction_text_to_remove
			
			await get_tree().create_timer(setter_delay).timeout
			
			# Connect to body_exited signal, disconnect the body_entered signal.
			if !snap_area_3d.body_exited.is_connected(_on_body_exited_snap_area):
				snap_area_3d.body_exited.connect(_on_body_exited_snap_area)
			if snap_area_3d.body_entered.is_connected(_on_body_entered_snap_area):
				snap_area_3d.body_entered.disconnect(_on_body_entered_snap_area)
			
		else:
			object_removed.emit()
			interaction_text = interaction_text_to_place
			
			await get_tree().create_timer(setter_delay).timeout
			
			# Connect to body_entered signal, disconnect the body_exited signal.
			if snap_area_3d.body_exited.is_connected(_on_body_exited_snap_area):
				snap_area_3d.body_exited.disconnect(_on_body_exited_snap_area)
			if !snap_area_3d.body_entered.is_connected(_on_body_entered_snap_area):
				snap_area_3d.body_entered.connect(_on_body_entered_snap_area)
		
		object_state_updated.emit(interaction_text)



func _ready() -> void:
	set_state()
	
	if expected_object:
		instanced_expected_object = load(expected_object.resource_path).instantiate()
		CogitoGlobals.debug_log(true,"cogito_snap_slot.gd", "expected object cogito_name=" + instanced_expected_object.cogito_name)


func interact(interactor: Node3D):
	player_interaction_component = interactor
	


func place_item():
	#TODO PLACE ITEM LOGIC GOES HERE
	CogitoAudio.play_sound_3d_in(self, object_placement_sound, self.global_position)
	spawned_object = preloaded_expected_item.instantiate()
	
	is_holding_object = true
	
	CogitoLevel.spawn_parent(self).add_child(spawned_object)
	if spawned_object.is_class("RigidBody3D"):
		spawned_object.set_freeze_mode(0)
		spawned_object.freeze = true
	spawned_object.global_transform = snap_position.global_transform
	spawned_object.object_exits_tree.connect(remove_object)


func place_carryable(world_carryable: Node3D):
	if has_meta(&"cogito_net_world"):
		_snap_online(world_carryable)
		return
	if !world_carryable:
		return
	if !world_carryable.is_class("RigidBody3D"):
		CogitoGlobals.debug_log(true,"cogito_snap_slot.gd", "place_carryable(): body wasn't a RigidBody3D.")
		return
		
	CogitoAudio.play_sound_3d_in(self, object_placement_sound, self.global_position)
	if player_interaction_component and player_interaction_component.carrying.carried_object:
		player_interaction_component.carrying.carried_object.leave()
	is_holding_object = true
	world_carryable.set_freeze_mode(0)
	world_carryable.freeze = true
	world_carryable.global_transform = snap_position.global_transform


func remove_object():
	CogitoAudio.play_sound_3d_in(self, object_removed_sound, self.global_position)
	is_holding_object = false
	if spawned_object:
		spawned_object = null


func _on_body_entered_snap_area(body : Node3D):
	if has_meta(&"cogito_net_world"):
		_snap_online(body)
		return
	if !expected_object:
		return
	
	if !player_interaction_component:
		var local_player := CogitoLevel.local_player(self)
		if local_player:
			player_interaction_component = local_player.player_interaction_component
	
	if body is CogitoObject:
		CogitoGlobals.debug_log(true,"cogito_snap_slot.gd", "body is CogitoObject with cogito_name=" + body.cogito_name)
		if instanced_expected_object.cogito_name == body.cogito_name:
			CogitoGlobals.debug_log(true,"cogito_snap_slot.gd", "Expected object detected: " + body.cogito_name)
			place_carryable(body)
	pass


func _on_body_exited_snap_area(body: Node3D):
	if has_meta(&"cogito_net_world"):
		return
	if !expected_object:
		return
	if body is CogitoObject and instanced_expected_object.cogito_name == body.cogito_name:
		remove_object()


func set_state():
	add_to_group("interactable")
	add_to_group("save_object_state")
	
	if is_holding_object:
		if !snap_area_3d.body_exited.is_connected(_on_body_exited_snap_area):
			snap_area_3d.body_exited.connect(_on_body_exited_snap_area)
	else:
		if !snap_area_3d.body_entered.is_connected(_on_body_entered_snap_area):
			snap_area_3d.body_entered.connect(_on_body_entered_snap_area)

	
	interaction_text = interaction_text_to_place
	object_state_updated.emit(interaction_text)
	interaction_nodes = find_children("","InteractionComponent",true) #Grabs all attached interaction components


func save():
	var state_dict = {
		"node_path" : self.get_path(),
		"is_active" : is_active,
		"is_holding_object" : is_holding_object,
		"pos_x" : position.x,
		"pos_y" : position.y,
		"pos_z" : position.z,
		"rot_x" : rotation.x,
		"rot_y" : rotation.y,
		"rot_z" : rotation.z,
		
	}
	return state_dict


func _snap_online(body: Node3D) -> void:
	if not multiplayer.is_server() or not is_active or is_holding_object or not body is RigidBody3D:
		return
	if not body is CogitoObject or not instanced_expected_object:
		return
	var matches_scene := body.scene_file_path == expected_object.resource_path
	var matches_name: bool = (
		not body.cogito_name.is_empty() and body.cogito_name == instanced_expected_object.cogito_name
	)
	if not (matches_scene or matches_name) or body.has_meta(&"net_snap_slot"):
		return
	var world: Node = get_meta(&"cogito_net_world")
	var id: String = world.entities.id_for(body)
	if id.is_empty():
		return
	snapped_id = id
	body.set_meta(&"net_snap_slot", self)
	body.tree_exiting.connect(release_body.bind(body), CONNECT_ONE_SHOT)
	for component in body.get_children():
		if component is CogitoCarryableComponent and component.is_being_carried:
			component.leave()
	body.freeze = true
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.global_transform = snap_position.global_transform
	is_holding_object = true
	object_placed.emit()
	object_state_updated.emit(interaction_text)
	net_changed.emit(&"placed")
	present_net_event(&"placed")


## Re-grabbing or removing the same body vacates the slot once.
func release_body(body: Node3D) -> void:
	if body.get_meta(&"net_snap_slot", null) != self:
		return
	body.remove_meta(&"net_snap_slot")
	if body.tree_exiting.is_connected(release_body.bind(body)):
		body.tree_exiting.disconnect(release_body.bind(body))
	snapped_id = ""
	is_holding_object = false
	object_removed.emit()
	object_state_updated.emit(interaction_text)
	net_changed.emit(&"removed")
	present_net_event(&"removed")


## Restore slot occupancy independently of the body's snapshot stream.
func net_state() -> Dictionary:
	return {"occupied": is_holding_object, "object": snapped_id}


## Silent baseline and live state use the same side-effect-free visual update.
func apply_net_state(state: Dictionary, _silent: bool) -> void:
	snapped_id = state.object
	is_holding_object = state.occupied
	for component in interaction_nodes:
		component.interaction_text = interaction_text


## Reattach the authority's saved joint only after runtime bodies exist.
func restore_network_binding(body: Node) -> void:
	if not is_holding_object:
		return
	if not body is RigidBody3D or body.has_meta(&"net_snap_slot"):
		is_holding_object = false
		snapped_id = ""
		return
	body.set_meta(&"net_snap_slot", self)
	body.tree_exiting.connect(release_body.bind(body), CONNECT_ONE_SHOT)
	body.freeze = true


## Play a live placement or removal sound.
func present_net_event(event: StringName) -> void:
	var sound := object_placement_sound if event == &"placed" else object_removed_sound
	if sound:
		CogitoAudio.play_sound_3d_in(self, sound, global_position)


## Remove the slot's tree-exit subscription before the level or the session disappears.
func net_unbind() -> void:
	if not has_meta(&"cogito_net_world") or snapped_id.is_empty():
		return
	var world: Node = get_meta(&"cogito_net_world")
	var body: Node = world.entities.objects.get(snapped_id)
	if is_instance_valid(body) and body.has_meta(&"net_snap_slot"):
		body.remove_meta(&"net_snap_slot")
		if body.tree_exiting.is_connected(release_body.bind(body)):
			body.tree_exiting.disconnect(release_body.bind(body))


func _exit_tree() -> void:
	net_unbind()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(instanced_expected_object):
		instanced_expected_object.free()

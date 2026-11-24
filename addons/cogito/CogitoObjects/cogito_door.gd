@tool
@icon("res://addons/cogito/Assets/Graphics/Editor/Icon_CogitoDoor.svg")
class_name CogitoDoor
extends Node3D

## Authoritative change observed by the bound level's replication endpoint.
signal net_changed(event: StringName)
signal object_state_updated(interaction_text:String)
signal lock_state_updated(lock_interaction_text:String)
signal door_state_changed(is_open:bool)
signal lock_state_changed(is_locked:bool)
signal damage_received(damage_value:float)

const NET_MOTION := preload("../Networking/net_door_motion.gd")

enum DoorType {
  ROTATING,
  SLIDING,
  ANIMATED
}

#region Variables
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

@export_group("Audio")
@export var audio_player: AudioStreamPlayer3D
@export var open_sound : AudioStream
@export var close_sound : AudioStream
## Sound that plays when attempting to open while locked.
@export var rattle_sound : AudioStream
@export var unlock_sound : AudioStream
@export var lock_sound : AudioStream

@export_group("Door Settings")
## Start state of the door (usually closed).
@export var is_open : bool = false
## Text that appears on the interaction prompt when locked.
@export var interaction_text_when_locked : String = "DOOR_Unlock"
## Text that appears on the interaction prompt when locked.
@export var interaction_text_when_unlocked : String = "DOOR_Lock"
## Text that appears on the interaction prompt when closed.
@export var interaction_text_when_closed : String = "DOOR_Open"
## Text that appears on the interaction prompt when open.
@export var interaction_text_when_open : String = "DOOR_Close"
## Use this if you don't want the door mesh to be detected by the interaction raycast. Useful if you have doors that are controlled by other interactables.
@export var ignore_interaction_raycast: bool = false
@export var is_locked : bool = false
## Item resources that is needed to unlock the door.
@export var key : KeyItemPD
## Hint that is displayed if the player attempts to open the door but doesn't have the key item.
@export var key_hint : String
##Alternate item resource that can unlock this door
@export var lockpick : InventoryItemPD
## Other doors that should sync their state (locked, unlocked, open, closed) with this door. Useful for double-doors, etc.
@export var doors_to_sync_with : Array[NodePath]

## If higher than zero, the door will auto-close after this amount of time has passed.
@export var auto_close_time: float

## Use these if you don't have an animation.
@export_group("Door Parameters")

@export var door_type := DoorType.ROTATING:
	set(value):
		door_type = value
		notify_property_list_changed()

## Set this to true if the door should swing opposite the direction of the interactor
@export var bidirectional_swing : bool = false
## Rotation Y when the door is open. In degrees.
@export var open_rotation : Vector3 = Vector3.ZERO
## Rotation Y when the door is closed. In degrees.
@export var closed_rotation : Vector3 = Vector3.ZERO
## Local position of transform when closed
@export var closed_position : Vector3
## Local position of transform when open
@export var open_position : Vector3
## Force single rotation axis. Use this if your objects rotation seems to tilt.
enum ForcedRotationAxis {
  None,
  AxisX,
  AxisY,
  AxisZ,
}
@export var forced_rotation_axis : ForcedRotationAxis = ForcedRotationAxis.None

## Speed in which the door moves between open and closed position.
@export var door_speed : float = 1
## The stop tolerance if the door rotation reaches the target angle. If your door keeps "oversteering", increase this value.
@export var angle_tolerance : float = 1

# Aimation Parameters
@export var animation_player : NodePath
@export var opening_animation : String
@export var reverse_opening_anim_for_close : bool = true:
	set(value):
		reverse_opening_anim_for_close = value
		notify_property_list_changed()

@export var closing_animation : String

var anim_player : AnimationPlayer
var is_moving : bool = false
var target_rotation_vector : Vector3 = Vector3.ZERO
var interaction_text
var lock_interaction_text
var close_timer : Timer #Used for auto-close

var interaction_nodes : Array[Node]
var cogito_properties : CogitoProperties = null
var player_interaction_component : PlayerInteractionComponent
var _net_motion: NET_MOTION
#endregion


func _validate_property(property: Dictionary):
	if property.name in ["bidirectional_swing", "open_rotation", "closed_rotation", "forced_rotation_axis","angle_tolerance"] and door_type != DoorType.ROTATING:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	elif property.name in ["open_position", "closed_position"] and door_type != DoorType.SLIDING:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	elif property.name in ["animation_player", "opening_animation", "reverse_opening_anim_for_close", "closing_animation"] and door_type != DoorType.ANIMATED:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	elif property.name in ["closing_animation"] and reverse_opening_anim_for_close:
		property.usage = PROPERTY_USAGE_NO_EDITOR


func _ready():
	if !audio_player:
		var players: Array[Node] = find_children("", "AudioStreamPlayer3D")
		if len(players): audio_player = players[0]
		
	if !ignore_interaction_raycast:
		add_to_group("interactable")
	add_to_group("save_object_state")
	interaction_nodes = find_children("","InteractionComponent",true) #Grabs all attached interaction components
	
	if door_type == DoorType.ANIMATED:
		anim_player = get_node(animation_player)
		
	if is_open:
		interaction_text = interaction_text_when_open
	else:
		interaction_text = interaction_text_when_closed
	
	if is_locked:
		lock_interaction_text = interaction_text_when_locked
	else:
		lock_interaction_text = interaction_text_when_unlocked
	
	if multiplayer.is_server():
		object_state_updated.emit(interaction_text)
		lock_state_updated.emit(lock_interaction_text)


func interact(interactor: Node3D):
	if is_inside_tree() and not multiplayer.is_server():
		return
	player_interaction_component = interactor
	
	if is_open:
		close_door(interactor)
	else:
		if is_locked: door_rattle(interactor)
		else: open_door(interactor)


func door_rattle(interactor):
	if audio_player and rattle_sound:
		audio_player.stream = rattle_sound
		audio_player.play()
	if is_instance_valid(interactor):
		interactor.send_hint(null, tr("DOOR_locked_hint") )


func get_prompt_marker_pos() -> Vector3:
	if prompt_marker:
		return prompt_marker.transform.origin
	else:
		return self.transform.origin


func _physics_process(_delta):
	if door_type == DoorType.ROTATING:
		if is_moving:
			match forced_rotation_axis:
				ForcedRotationAxis.None:
					rotation = rotation.move_toward(target_rotation_vector, _delta * door_speed)
					if vectors_approx_equal(target_rotation_vector, rotation_degrees, angle_tolerance):
						is_moving = false
					
				ForcedRotationAxis.AxisX:
					rotation.x = lerp_angle( deg_to_rad(rotation_degrees.x), deg_to_rad(target_rotation_vector.x), clampf(_delta * door_speed,0.0,1.0) )
					if rotation_degrees.x == target_rotation_vector.x:
						is_moving = false
						
				ForcedRotationAxis.AxisY:
					rotation.y = lerp_angle( deg_to_rad(rotation_degrees.y), deg_to_rad(target_rotation_vector.y), clampf(_delta * door_speed,0.0,1.0) )
					if rotation_degrees.y == target_rotation_vector.y:
						is_moving = false
				ForcedRotationAxis.AxisZ:
					rotation.x = lerp_angle( deg_to_rad(rotation_degrees.z), deg_to_rad(target_rotation_vector.z), clampf(_delta * door_speed,0.0,1.0) )
					if rotation_degrees.z == target_rotation_vector.z:
						is_moving = false


func vectors_approx_equal( v1 : Vector3, v2 : Vector3, epsilon : float ) -> bool:
	var diff = v1 - v2
	return abs( diff.x ) < epsilon and abs( diff.y ) < epsilon and abs( diff.z ) < epsilon


func lock_unlock_switch():
	if is_inside_tree() and not multiplayer.is_server():
		return
	if is_locked:
		unlock_door()
		
	else: 
		lock_door()
	
	if has_meta(&"cogito_net_world"):
		return
	for nodepath in doors_to_sync_with:
		if nodepath != null:
			var object = get_node(nodepath)
			object.lock_unlock_switch()


func unlock_door(key_user: PlayerInteractionComponent = null):
	if has_meta(&"cogito_net_world") and not is_locked:
		return
	if is_inside_tree() and not multiplayer.is_server():
		return
	if audio_player and unlock_sound:
		audio_player.stream = unlock_sound
		audio_player.play()
	is_locked = false
	
#	Key Discard Logic
	if has_meta(&"cogito_net_world"):
		if key_user and key and key.discard_after_use:
			for slot in key_user.get_inventory().inventory_slots:
				if slot and key_user.matches_item(slot.inventory_item, key):
					key_user.get_inventory().remove_item_from_stack(slot)
					key_user.send_hint(null, tr(key.name) + " " + tr("HINT_SWITCH_item_used"))
					break
	elif key && key.discard_after_use:
		var inventory = player_interaction_component.get_inventory()
		for slot_data in inventory.inventory_slots:
			if slot_data != null and slot_data.inventory_item == key:
				player_interaction_component.send_hint(null, tr(key.name) + " " + tr("HINT_SWITCH_item_used") ) # Sends a hint with the key item name.
				inventory.remove_item_from_stack(slot_data)
	
	lock_interaction_text = interaction_text_when_unlocked	
	if has_meta(&"cogito_net_world"):
		net_changed.emit(&"unlock" if not is_locked else &"lock")
		_sync_lock()
	lock_state_changed.emit(is_locked)
	lock_state_updated.emit(lock_interaction_text)


func lock_door():
	if has_meta(&"cogito_net_world") and is_locked:
		return
	if is_inside_tree() and not multiplayer.is_server():
		return
	if audio_player and lock_sound:
		audio_player.stream = lock_sound
		audio_player.play()
		
	is_locked = true
	lock_interaction_text = interaction_text_when_locked
	if has_meta(&"cogito_net_world"):
		net_changed.emit(&"unlock" if not is_locked else &"lock")
		_sync_lock()
	lock_state_changed.emit(is_locked)
	lock_state_updated.emit(lock_interaction_text)



func open_door(interactor: Node3D):
	if has_meta(&"cogito_net_world") and is_open:
		return
	if is_inside_tree() and not multiplayer.is_server():
		return
	if audio_player and open_sound:
		audio_player.stream = open_sound
		audio_player.play()

	if has_meta(&"cogito_net_world"):
		is_open = true
		_net_motion.start(self, true, interactor)
	elif door_type == DoorType.ANIMATED:
		anim_player.play(opening_animation)
	elif door_type == DoorType.ROTATING:
		target_rotation_vector = open_rotation
		var swing_direction: int = 1

		if bidirectional_swing:
			var offset: Vector3 = interactor.global_transform.origin - global_transform.origin
			var offset_dot_product: float = offset.dot(global_transform.basis.x)
			swing_direction = -1 if offset_dot_product < 0 else 1

		target_rotation_vector = open_rotation * swing_direction
		is_moving = true
	else:
		var tween_door = get_tree().create_tween()
		tween_door.tween_property(self,"position", open_position, door_speed)
		
	for nodepath in doors_to_sync_with:
		if nodepath != null:
			var object = get_node(nodepath)
			object.open_door(interactor)
	
	is_open = true
	interaction_text = interaction_text_when_open
	object_state_updated.emit(interaction_text)
	if has_meta(&"cogito_net_world"):
		net_changed.emit(&"open")
	door_state_changed.emit(true)
	
	# Only used if there's an auto close time set.
	if auto_close_time > 0:
		close_timer = Timer.new()
		add_child(close_timer)
		close_timer.wait_time = auto_close_time
		close_timer.one_shot = true
		close_timer.start()
		close_timer.timeout.connect(on_auto_close_time)


func on_auto_close_time():
	if has_meta(&"cogito_net_world"):
		close_door(null)
		return
	close_door(player_interaction_component)


func close_door(_interactor: Node3D):
	if has_meta(&"cogito_net_world") and not is_open:
		return
	if is_inside_tree() and not multiplayer.is_server():
		return
	if is_instance_valid(close_timer): #If there's an auto_close_timer, destroy it.
		close_timer.queue_free()
	
	if audio_player and close_sound:
		audio_player.stream = close_sound
		audio_player.play()
	
	if has_meta(&"cogito_net_world"):
		is_open = false
		_net_motion.start(self, false)
	elif door_type == DoorType.ANIMATED:
		if reverse_opening_anim_for_close:
			anim_player.play_backwards(opening_animation)
		else:
			anim_player.play(closing_animation)
	elif door_type == DoorType.ROTATING:
		target_rotation_vector = closed_rotation
		is_moving = true
	else:
		# Sliding door close
		var tween_door = get_tree().create_tween()
		tween_door.tween_property(self,"position", closed_position, door_speed)
		
	for nodepath in doors_to_sync_with:
		if nodepath != null:
			var object = get_node(nodepath)
			object.close_door(_interactor)
		
	is_open = false
	interaction_text = interaction_text_when_closed
	object_state_updated.emit(interaction_text)
	if has_meta(&"cogito_net_world"):
		net_changed.emit(&"close")
	door_state_changed.emit(false)


func set_state():
	if is_open:
		if auto_close_time > 0:
			set_to_closed_position()
			interaction_text = interaction_text_when_closed
		else:
			set_to_open_position()
			interaction_text = interaction_text_when_open
	else:
		set_to_closed_position()
		interaction_text = interaction_text_when_closed
	if is_locked:
		lock_interaction_text = interaction_text_when_locked
	else:
		lock_interaction_text = interaction_text_when_unlocked
	
	lock_state_changed.emit(is_locked)
	object_state_updated.emit(interaction_text)
	lock_state_updated.emit(lock_interaction_text)


func set_to_open_position():
	if door_type == DoorType.SLIDING:
		position = open_position
	else:
		rotation_degrees = open_rotation


func set_to_closed_position():
	if door_type == DoorType.SLIDING:
		position = closed_position
	else:
		rotation_degrees = closed_rotation

#alternate interaction for locking/unlocking
func interact2(interactor: Node3D):
	if is_inside_tree() and not multiplayer.is_server():
		return
	player_interaction_component = interactor
	if not is_open:
		lock_unlock_switch()
	else:
		interactor.send_hint(null,"Can't lock an open door")

func save():
	var state_dict = {
		"node_path" : self.get_path(),
		"is_locked" : is_locked,
		"is_open" : is_open,
		"pos_x" : position.x,
		"pos_y" : position.y,
		"pos_z" : position.z,
		"rot_x" : rotation.x,
		"rot_y" : rotation.y,
		"rot_z" : rotation.z,
		
	}
	return state_dict

func _sync_lock() -> void:
	for path in doors_to_sync_with:
		var other := get_node_or_null(path) as CogitoDoor
		if other and other.is_locked != is_locked:
			if is_locked:
				other.lock_door()
			else:
				other.unlock_door()


## Replicate the destination so late observers can snap without replaying motion.
func net_state() -> Dictionary:
	if not _net_motion:
		_net_motion = NET_MOTION.new()
	return _net_motion.state(self)


## Apply only pose, collision and prompt data. Linked-door signals belong to authority.
func apply_net_state(state: Dictionary, silent: bool) -> void:
	var moved := is_open != bool(state.open)
	is_open = state.open
	is_locked = state.locked
	if moved or silent:
		_net_motion.apply(self, state, silent)
	interaction_text = interaction_text_when_open if is_open else interaction_text_when_closed
	lock_interaction_text = (
		interaction_text_when_locked if is_locked else interaction_text_when_unlocked
	)
	for component: InteractionComponent in interaction_nodes:
		if component is DualInteraction:
			component.press_interaction_text = interaction_text
			component.hold_interaction_text = lock_interaction_text
			component.interaction_text = (
				tr(interaction_text) + tr(component.interaction_text_joiner) + tr(lock_interaction_text)
			)
		elif component.has_method("can_start_hold"):
			component.interaction_text = lock_interaction_text
		else:
			component.interaction_text = interaction_text


## Stop an existing solo auto-close timer when taking over a loaded level as a replica.
func net_bind_replica() -> void:
	if is_instance_valid(close_timer):
		close_timer.stop()
		close_timer.queue_free()
		close_timer = null


## Drop the session destination before binding this door again.
func net_unbind() -> void:
	if _net_motion:
		_net_motion.stop()
		_net_motion = null


## Play the one-shot for a live authoritative transition.
func present_net_event(event: StringName) -> void:
	var sounds := {
		&"open": open_sound, &"close": close_sound, &"lock": lock_sound, &"unlock": unlock_sound
	}
	if audio_player and sounds.get(event):
		audio_player.stream = sounds[event]
		audio_player.play()

extends Node3D
class_name InteractionTargeting
## Part of PlayerInteractionComponent: tracks the interactable the player is looking at and keeps the interaction prompts up to date.

@onready var pic: PlayerInteractionComponent = get_parent()

var interactable: # Updated via signals from InteractionRayCast
	set = _set_interactable


func is_interaction_raycast_colliding() -> bool:
	if pic.interaction_raycast.is_colliding():
		return true
	else:
		return false


## Makes the target detection ignore this object, for example while it is carried.
func add_exception(object: CollisionObject3D) -> void:
	pic.interaction_raycast.add_exception(object)


func remove_exception(object: CollisionObject3D) -> void:
	pic.interaction_raycast.remove_exception(object)


## Drops the current target right away, for example when it is about to be freed.
func clear_interactable() -> void:
	# Through the raycast, so it forgets the target too and reports it as unseen.
	pic.interaction_raycast._set_interactable(null)


## How far away interactables can be targeted.
func get_reach() -> float:
	return pic.interaction_raycast.target_position.length()


## Helper function to always get raycast destination point
func get_interaction_raycast_tip(distance_offset: float) -> Vector3:
	var interaction_raycast := pic.interaction_raycast
	var destination_point = interaction_raycast.global_position + (interaction_raycast.target_position.z - distance_offset) * pic.player.get_aim_transform().basis.z
	if interaction_raycast.is_colliding():
		#if destination_point == interaction_raycast.get_collision_point():
		return interaction_raycast.get_collision_point()
	else:
		return destination_point


# Function to get a normalised vector3 in direction the player is looking.
func get_look_direction() -> Vector3:
	return -pic.player.get_aim_transform().basis.z.normalized()


func rebuild_interaction_prompts() -> void:
	# Ensure the drop prompt isn't cleared.
	if pic.carrying.is_carrying:
		return
	pic.nothing_detected.emit() # Clears the prompts
	if interactable != null:
		pic.interactive_object_detected.emit(interactable.interaction_nodes) # Builds the prompts


func _set_interactable(new_interactable) -> void:
	interactable = new_interactable
	# Ensure the drop prompt isn't cleared.
	if pic.carrying.is_carrying:
		return
	if interactable == null:
		pic.nothing_detected.emit()
	else:
		pic.interactive_object_detected.emit(interactable.interaction_nodes)

extends Node3D
class_name CarryHandler
## Part of PlayerInteractionComponent: holds the carried object and throws or drops it.
## Throw and drop settings are exported on PlayerInteractionComponent.

@onready var pic: PlayerInteractionComponent = get_parent()

var carried_object = null:  # Used for carryable handling.
	set = _set_carried_object

var is_carrying: bool:
	get: return carried_object != null


func start_carrying(_carried_object):
	carried_object = _carried_object


func stop_carrying():
	carried_object = null
	pic.targeting.rebuild_interaction_prompts() # Ensures the drop prompt gets deleted


func get_carryable_destination_point(distance_offset: float) -> Vector3:
	if !pic.carryable_position:
		print("PIC: Error, no carryable position reference set!")
		return pic.global_position

	var looking_vector = pic.targeting.get_look_direction()
	var pitch = atan2(looking_vector.y, Vector2(looking_vector.x, looking_vector.z).length())
	var look_down_factor = clamp(pitch, -PI / 2.0, 0.0) / (-PI / 2.0)
	var safe_distance_offset = look_down_factor

	var carried_object_parent = carried_object.get_parent()
	if carried_object_parent and carried_object_parent.has_method("get_aabb"):
		var aabb = carried_object.get_parent().get_aabb()
		var biggest_dimension = max(aabb.size.x,max(aabb.size.y, aabb.size.z))
		safe_distance_offset = biggest_dimension * 0.5 + look_down_factor

	var destination_point = pic.carryable_position.global_position + (distance_offset + safe_distance_offset) * looking_vector

	var interaction_raycast := pic.interaction_raycast
	if interaction_raycast.is_colliding():
		var collision_point = interaction_raycast.get_collision_point()

		if interaction_raycast.global_position.distance_squared_to(destination_point) < interaction_raycast.global_position.distance_squared_to(collision_point):
			return destination_point
		else:
			return collision_point

	return destination_point


func attempt_throw() -> void:
	if !is_carrying:
		return

	var carried_object_mass: float = get_carried_object_mass(carried_object)
	var throw_force: float = carried_object_mass * pic.throw_power_mass_multiplier
	throw_force = clamp(throw_force, 0, pic.max_throw_power)

	var stamina_attribute := pic.stamina_attribute
	if stamina_attribute and throw_force >= pic.throw_stamina_threshold:
		if stamina_attribute.value_current < pic.throw_stamina_drain:
			if pic.drop_when_cant_throw:
				drop_carried_object()
			return
		else:
			pic.player.decrease_attribute(stamina_attribute.attribute_name, pic.throw_stamina_drain)

	carried_object.throw(throw_force)


func drop_carried_object() -> void:
	if !is_carrying:
		return
	var carried_object_mass: float = get_carried_object_mass(carried_object)
	var drop_force: float = carried_object_mass * pic.drop_power_mass_multiplier
	drop_force = clamp(drop_force, 0, pic.max_drop_power)
	carried_object.throw(drop_force)


func get_carried_object_mass(carried_object) -> float:
	var carried_object_mass: float
	var carried_object_parent = carried_object.get_parent()
	if carried_object_parent is RigidBody3D:
		carried_object_mass = (carried_object_parent as RigidBody3D).mass
	elif carried_object_parent is PhysicalBone3D:
		carried_object_mass = (carried_object_parent as PhysicalBone3D).mass
	return carried_object_mass


func _set_carried_object(new_carried_object) -> void:
	carried_object = new_carried_object
	if carried_object != null:
		pic.started_carrying.emit(carried_object)

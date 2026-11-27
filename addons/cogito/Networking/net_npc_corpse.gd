extends RefCounted
## Build a single sleeping pelvis body using the authored ragdoll skin and drag component.

const Drag := preload("../CogitoNPC/cogito_body_drag.gd")


## Identify an authored ragdoll without running its scene.
static func is_ragdoll(scene: PackedScene) -> bool:
	var state := scene.get_state()
	for prop in state.get_node_property_count(0):
		if state.get_node_property_name(0, prop) == &"script":
			return state.get_node_property_value(0, prop) == preload("../Scripts/cogito_ragdoll.gd")
	return false


## The server and observers build the same prone model. Only MP4 authority simulates the body.
static func create(scene: PackedScene) -> RigidBody3D:
	var model := scene.instantiate() as Node3D
	var body := RigidBody3D.new()
	body.set_script(Drag)
	body.mass = 12.0
	body.collision_layer = 3
	body.collision_mask = 1
	var bounds := AABB(Vector3(-0.3, -0.22, -0.85), Vector3(0.6, 0.44, 1.7))
	body.set("custom_aabb", bounds)
	var shape := CollisionShape3D.new()
	var torso := BoxShape3D.new()
	torso.size = bounds.size
	shape.shape = torso
	body.angular_damp = 4.0
	body.linear_damp = 2.0
	body.add_child(shape)
	var grips := model.find_children("*", "CogitoCarryableComponent", true, false)
	if not grips.is_empty():
		var grip := grips[0] as CogitoCarryableComponent
		grip.owner = null
		grip.reparent(body, false)
		grip.owner = body
		grip.carry_distance_offset = -0.6
		grip.drop_distance = 3.5
	var skeleton := model.find_children("*", "Skeleton3D", true, false).front() as Skeleton3D
	for child in skeleton.get_children():
		if child is SkeletonModifier3D:
			child.free()
	model.set_script(null)
	model.rotation.x = -PI / 2
	model.position.z = 0.85
	body.add_child(model)
	return body

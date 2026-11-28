class_name NetNpcCorpse
extends CogitoRagdoll
## Network instance of the authored scene. Only the authority starts its joint solver.

const Codec := preload("net_corpse_codec.gd")
const SLEEP_CAP := 10.0

var bones: Array[PhysicalBone3D] = []
var anchor: PhysicalBone3D
var replica := false
var resting := false
var _elapsed := 0.0
var _awake_seconds := 0.0
var _started := false
var _presented := false
var _indices := PackedInt32Array()
var _offsets: Array[Transform3D] = []


## Identify an authored ragdoll without running its scene.
static func is_ragdoll(scene: PackedScene) -> bool:
	var state := scene.get_state()
	for prop in state.get_node_property_count(0):
		if state.get_node_property_name(0, prop) == &"script":
			return state.get_node_property_value(0, prop) == preload("../Scripts/cogito_ragdoll.gd")
	return false


static func create(scene: PackedScene, as_replica := false) -> NetNpcCorpse:
	var model := scene.instantiate() as CogitoRagdoll
	model.set_script(NetNpcCorpse)
	var corpse := model as NetNpcCorpse
	corpse.replica = as_replica
	corpse.make_persistent = false
	return corpse


func _ready() -> void:
	find_ragdoll_nodes()
	# Solo uses this signal to prepare its Persist snapshot on every skeleton update.
	skeleton.skeleton_updated.disconnect(_on_skeleton_ragdoll_skeleton_updated)
	for part in physical_bone_simulator_3d.get_children():
		if part is PhysicalBone3D:
			bones.append(part)
			_indices.append(skeleton.find_bone(part.bone_name))
			_offsets.append(part.body_offset.affine_inverse())
			if part.bone_name == "DEF-hips":
				anchor = part
	if not anchor:
		anchor = bones[0]
	if replica:
		set_physics_process(false)
		hide()
		physical_bone_simulator_3d.active = false
		for bone in bones:
			var rid := bone.get_rid()
			PhysicsServer3D.body_set_mode(rid, PhysicsServer3D.BODY_MODE_KINEMATIC)
			PhysicsServer3D.body_set_collision_layer(rid, 0)
			PhysicsServer3D.body_set_collision_mask(rid, 0)
	else:
		await CogitoLevel.delay(self, 0.05, false)
		if not _started:
			start_simulation()


func start_simulation() -> void:
	if not replica:
		super.start_simulation()
		_started = true


func frame_root() -> Transform3D:
	return Transform3D(global_basis.orthonormalized(), anchor.global_position)


func _physics_process(delta: float) -> void:
	_elapsed += delta
	if _elapsed + 0.000001 >= 0.05:
		resting = sample_rest(_elapsed)
		_elapsed = 0.0


## The cap uses simulated room time. Holding either grip keeps the assembly awake.
func sample_rest(delta: float) -> bool:
	if not _started or has_meta(&"net_carrier"):
		_awake_seconds = 0.0
		return false
	for bone in bones:
		if not PhysicsServer3D.body_get_state(bone.get_rid(), PhysicsServer3D.BODY_STATE_SLEEPING):
			_awake_seconds += delta
			if _awake_seconds < SLEEP_CAP:
				return false
			_sleep()
			break
	_awake_seconds = 0.0
	return true


func _sleep() -> void:
	for bone in bones:
		bone.linear_velocity = Vector3.ZERO
		bone.angular_velocity = Vector3.ZERO
		PhysicsServer3D.body_set_state(bone.get_rid(), PhysicsServer3D.BODY_STATE_SLEEPING, true)


## Place the joints before putting the whole assembly to sleep, including on an immediate save.
func restore_frame(root: Transform3D, bytes: PackedByteArray) -> void:
	if bytes.size() != bones.size() * Codec.STRIDE:
		return
	if _started:
		physical_bone_simulator_3d.physical_bones_stop_simulation()
	apply_frame(root, Codec.decode(bytes))
	# Seed the simulator's skeleton pose before sleeping: a sleeping body gets no
	# integration callback to update the skin on a listen host.
	skeleton.advance(0.0)
	start_simulation()
	for bone in bones:
		bone.force_update_transform()
	_sleep()
	resting = true


## Global body pose includes the authored body offset from the skeleton joint.
func apply_frame(root: Transform3D, poses: Array, following: Array = [], weight := 0.0) -> void:
	if replica:
		global_transform = root
		if not _presented:
			for bone in bones:
				PhysicsServer3D.body_set_collision_layer(bone.get_rid(), bone.collision_layer)
				PhysicsServer3D.body_set_collision_mask(bone.get_rid(), bone.collision_mask)
			_presented = true
			show()
	var inverse := skeleton.global_transform.affine_inverse()
	for i in bones.size():
		var local: Transform3D = poses[i]
		if not following.is_empty():
			local = local.interpolate_with(following[i], weight)
		var pose := root * local
		var bone := bones[i]
		bone.global_transform = pose
		bone.force_update_transform()
		PhysicsServer3D.body_set_state(bone.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, pose)
		skeleton.set_bone_global_pose(_indices[i], inverse * pose * _offsets[i])

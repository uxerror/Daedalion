extends RefCounted
## A room-bound door's collision trajectory in its stationary parent's coordinates.
## Each segment starts at its predecessor's evaluated pose. Fractional ticks preserve
## the authored duration and allow the renderer to sample between physics ticks.

const Rotation := preload("net_support_rotation.gd")

var body: AnimatableBody3D
var door: CogitoDoor
var key: int
var _curves: Dictionary[int, Rotation] = {}
var _segments: Array[Dictionary] = []
var _meshes: Array[Node] = []
var _sync: bool
var _server: bool
var _resting := false
var _visual_offset := false


static func accepts(node: CogitoDoor) -> bool:
	if not (node as Node3D) is AnimatableBody3D or node.door_type == CogitoDoor.DoorType.ANIMATED:
		return false
	var parent := node.get_parent_node_3d() if not node.top_level else null
	while parent:
		if parent is PhysicsBody3D and (not parent is StaticBody3D or parent is AnimatableBody3D):
			return false
		parent = parent.get_parent_node_3d() if not parent.top_level else null
	return true


func _init(node: CogitoDoor, identity: int) -> void:
	door = node
	body = (node as Node3D) as AnimatableBody3D
	key = identity
	_sync = body.sync_to_physics
	body.sync_to_physics = false
	# Install the pose immediately in the query space. A kinematic target in Jolt
	# otherwise becomes queryable on the next physics update, too late for replay.
	_server = body.multiplayer.is_server()
	if not _server:
		PhysicsServer3D.body_set_mode(body.get_rid(), PhysicsServer3D.BODY_MODE_STATIC)
		_meshes = body.find_children("*", "VisualInstance3D", true, false)
	hold()


func hold() -> void:
	_resting = false
	_curves.clear()
	_segments.clear()
	_segments.append(segment(0, body.transform, body.transform, 0))


func segment(tick: int, origin: Transform3D, end: Transform3D, duration: float) -> Dictionary:
	return {"tick": tick, "from": origin, "to": end, "duration": duration}


func start(tick: int, target: Vector3, seconds: float) -> void:
	var origin := pose(tick)
	var angles := body.rotation
	var prior := latest()
	if _curves.has(prior.tick):
		angles = _curves[prior.tick].angles_at(tick - prior.tick)
	var end := origin
	if door.door_type == CogitoDoor.DoorType.SLIDING:
		end.origin = target
	else:
		var turn := target * (PI / 180.0)
		end.basis = Basis.from_euler(turn, body.rotation_order).scaled_local(
			origin.basis.get_scale()
		)
	var row := segment(tick, origin, end, seconds * Engine.physics_ticks_per_second)
	if door.door_type == CogitoDoor.DoorType.SLIDING:
		# The idle tween writes its first target before the next Jolt step.
		# Its physical collider holds the start for one tick, for either sync mode.
		row.delay = 1
	else:
		row.angles = angles
		row.degrees = target
		row.step = door.door_speed / Engine.physics_ticks_per_second
		row.axis = int(door.forced_rotation_axis) - 1
		row.sync = _sync
		row.tolerance = door.angle_tolerance
	install(row)


func latest() -> Dictionary:
	return _segments.back()


## A join or save need only reconstruct the retained command window. Long-running
## angular motion gets a fresh initial value at the earliest required tick.
func baseline(tick: int) -> Dictionary:
	var row := latest()
	if not _curves.has(row.tick) or tick - row.tick <= 128:
		return row
	var at := tick - 128
	var start_pose := pose(at)
	var curve := _curves[row.tick]
	var angles := curve.angles_at(at - row.tick)
	if curve.settled(at - row.tick):
		return segment(at, start_pose, start_pose, 0)
	var rebased := row.duplicate()
	rebased.tick = at
	rebased.from = start_pose
	rebased.angles = angles
	return rebased


func install(row: Dictionary) -> void:
	if latest() == row:
		return
	_resting = false
	while not _segments.is_empty() and latest().tick >= row.tick:
		_curves.erase(latest().tick)
		_segments.pop_back()
	if row.has("degrees"):
		_curves[row.tick] = Rotation.new(row)
	_segments.append(row)
	# Keep the predecessor of the oldest replayable tick, including long idle gaps.
	while _segments.size() > 2 and _segments[1].tick < row.tick - 128:
		_curves.erase(_segments[0].tick)
		_segments.pop_front()


func pose(tick: float) -> Transform3D:
	var index := _segments.size() - 1
	while index > 0 and _segments[index].tick > tick:
		index -= 1
	var row := _segments[index]
	var elapsed: float = tick - row.tick - row.get("delay", 0)
	var start_pose: Transform3D = row.from
	if elapsed < 0:
		return start_pose
	if _curves.has(row.tick):
		var angles := _curves[row.tick].angles_at(elapsed)
		start_pose.basis = Basis.from_euler(angles, body.rotation_order).scaled_local(
			start_pose.basis.get_scale()
		)
		return start_pose
	if elapsed >= row.duration:
		return row.to
	var weight: float = elapsed / row.duration
	var end: Transform3D = row.to
	start_pose.origin = start_pose.origin.lerp(end.origin, weight)
	return start_pose


func world_pose(tick: float) -> Transform3D:
	var parent := body.get_parent_node_3d()
	return parent.global_transform * pose(tick) if parent and not body.top_level else pose(tick)


func displacement(tick: int, local_point: Vector3) -> Vector3:
	return world_pose(tick) * local_point - world_pose(tick - 1) * local_point


func _settled(tick: float) -> bool:
	var row := latest()
	var age: float = tick - row.tick
	return (
		_curves[row.tick].settled(age)
		if _curves.has(row.tick)
		else age > row.duration + row.get("delay", 0)
	)


func drive(tick: int) -> void:
	var settled := _settled(tick)
	if _resting and settled:
		return
	_resting = settled
	var evaluated := pose(tick)
	var rid := body.get_rid()
	var snap := false
	if _server:
		var physical: Transform3D = PhysicsServer3D.body_get_state(
			rid, PhysicsServer3D.BODY_STATE_TRANSFORM
		)
		snap = not physical.orthonormalized().is_equal_approx(world_pose(tick).orthonormalized())
		if snap:
			PhysicsServer3D.body_set_mode(rid, PhysicsServer3D.BODY_MODE_STATIC)
	if evaluated != body.transform:
		body.transform = evaluated
		body.force_update_transform()
	if _server:
		if snap:
			PhysicsServer3D.body_set_state(
				rid, PhysicsServer3D.BODY_STATE_TRANSFORM, body.global_transform
			)
			PhysicsServer3D.body_set_mode(rid, PhysicsServer3D.BODY_MODE_KINEMATIC)
		# Jolt integrates this target after the actor solve. The next solve therefore
		# sees the correct pose and normal kinematic contact velocity on rigid props.
		PhysicsServer3D.body_set_state(
			rid, PhysicsServer3D.BODY_STATE_TRANSFORM, world_pose(tick + 1)
		)


func present(visual: Transform3D) -> void:
	if _resting and not _visual_offset and visual == body.global_transform:
		return
	var offset := visual * body.global_transform.affine_inverse()
	_visual_offset = not offset.is_equal_approx(Transform3D.IDENTITY)
	for mesh: VisualInstance3D in _meshes:
		mesh.force_update_transform()
		RenderingServer.instance_set_transform(mesh.get_instance(), offset * mesh.global_transform)


func close() -> void:
	for mesh: VisualInstance3D in _meshes:
		RenderingServer.instance_set_transform(mesh.get_instance(), mesh.global_transform)
	PhysicsServer3D.body_set_mode(body.get_rid(), PhysicsServer3D.BODY_MODE_KINEMATIC)
	body.sync_to_physics = _sync

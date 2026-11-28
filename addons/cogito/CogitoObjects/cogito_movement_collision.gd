extends RefCounted
## One room's query geometry. Every sweep specifies its starting transform. The two
## layer-zero query bodies supply the prefab shapes to Jolt without moving a gameplay body.

const STAIRS := CogitoMovementStep.Stairs

var _space: PhysicsDirectSpaceState3D
var _actor: CogitoPlayerAdvanced
var _areas := PhysicsShapeQueryParameters3D.new()
var _head := PhysicsShapeQueryParameters3D.new()
var _standing: RID
var _crouching: RID
var _clearance := PhysicsShapeQueryParameters3D.new()
var _cast_offset: Transform3D
var _cast_motion: Vector3
var _params := PhysicsTestMotionParameters3D.new()
var _hit := PhysicsTestMotionResult3D.new()
var _mask: int
var _margin: float
var _snap: float
var _floor_cos: float
var _slides: int


class Volumes:
	var ladder_key: int
	var outward: Vector3
	var ladder_bounds: AABB
	var water_bounds: AABB
	var surface_height: float
	var in_water := false
	var submerged := false
	var depth := 0.0


class Contact:
	var pose: Transform3D
	var velocity: Vector3
	var floor_normal := Vector3.ZERO
	var wall_normal := Vector3.ZERO
	var ceiling := false
	var legacy := false
	var stair := Vector3.ZERO
	var stair_normal := Vector3.ZERO
	var step_up := false


## A replica with collisions disabled can supply the original movement mask explicitly.
func _init(actor: CogitoPlayerAdvanced, authored_mask := -1) -> void:
	_actor = actor
	_areas.collide_with_bodies = false
	_areas.collide_with_areas = true
	_areas.collision_mask = (
		CogitoPhysics.CollisionMask.ENVIRONMENT | CogitoPhysics.CollisionMask.WATER
	)
	_head.collide_with_bodies = false
	_head.collide_with_areas = true
	_head.shape = actor.swimming_head_shapecast.shape
	_head.collision_mask = actor.swimming_head_shapecast.collision_mask
	_head.margin = actor.swimming_head_shapecast.margin
	var world := actor.get_world_3d()
	_space = world.direct_space_state
	_mask = actor.initial_collision_mask if authored_mask < 0 else authored_mask
	_standing = _body(world.space, actor.standing_collision_shape)
	_crouching = _body(world.space, actor.crouching_collision_shape)
	var cast := actor.crouch_shapecast
	_clearance.shape = cast.shape
	_clearance.margin = cast.margin
	_clearance.collision_mask = cast.collision_mask
	_cast_offset = cast.transform
	_cast_motion = cast.target_position
	_margin = actor.safe_margin
	_snap = actor.floor_snap_length
	_floor_cos = cos(actor.floor_max_angle + 0.00001)
	_slides = actor.max_slides
	var excluded: Array[RID] = [actor.get_rid()]
	set_exclusions(excluded)


## Release RIDs while the room is still in the tree (including engine shutdown).
func close() -> void:
	PhysicsServer3D.free_rid(_standing)
	PhysicsServer3D.free_rid(_crouching)


func _body(space: RID, collider: CollisionShape3D) -> RID:
	var rid := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(rid, PhysicsServer3D.BODY_MODE_KINEMATIC)
	PhysicsServer3D.body_set_collision_layer(rid, 0)
	PhysicsServer3D.body_set_collision_mask(rid, 0)
	PhysicsServer3D.body_add_shape(rid, collider.shape.get_rid(), collider.transform)
	PhysicsServer3D.body_set_space(rid, space)
	return rid


func set_exclusions(bodies: Array[RID]) -> void:
	_params.exclude_bodies = bodies
	_clearance.exclude = bodies
	_areas.exclude = bodies
	_head.exclude = bodies


## Seed a new pose after a teleport or check the support on leaving legacy.
func support(pose: Transform3D, standing: bool) -> Contact:
	var result := Contact.new()
	result.pose = pose
	var body := _standing if standing else _crouching
	PhysicsServer3D.body_set_collision_mask(body, _mask)
	_params.margin = _margin
	# Authored teleports can place the hull inside several faces. Advanced owns
	# penetration recovery until this origin admits an ordinary support query.
	if _sweep(body, pose, Vector3.ZERO, true):
		result.legacy = _hit.get_collision_depth() > 2.0 * _margin
	if _sweep(body, pose, Vector3.DOWN * maxf(_snap, _margin), true):
		var normal := _hit.get_collision_normal()
		if normal.y >= _floor_cos:
			result.floor_normal = normal
			result.legacy = result.legacy or _dynamic_contact()
	PhysicsServer3D.body_set_collision_mask(body, 0)
	return result


## Only the simulation hull and head enter these queries, including during replay.
func volumes(pose: Transform3D, s: CogitoMovementState) -> Volumes:
	var result := Volumes.new()
	var hull := (
		_actor.standing_collision_shape if s.standing_shape else _actor.crouching_collision_shape
	)
	_areas.shape = hull.shape
	_areas.transform = pose * hull.transform
	var room_from_world := s.transform * pose.affine_inverse()
	var neck := _actor.neck.position
	var head_at := (
		pose.origin + s.body_basis * (neck + Basis(Vector3.UP, s.neck_yaw) * s.head_position)
	)
	_head.transform = Transform3D(_actor.swimming_head_shapecast.global_basis, head_at)
	result.submerged = not _space.intersect_shape(_head, 1).is_empty()
	for hit: Dictionary in _space.intersect_shape(_areas):
		var area := hit.collider as Area3D
		if area is Ladder or area is WaterArea:
			var shape := (
				area.shape_owner_get_owner(area.shape_find_owner(hit.shape)) as CollisionShape3D
			)
			if area is Ladder:
				var key := String(_actor.get_parent().get_path_to(shape)).hash()
				if result.ladder_key == 0 or key < result.ladder_key:
					result.ladder_key = key
					result.outward = area.outward(shape)
					result.ladder_bounds = _room_bounds(shape, room_from_world)
			else:
				var surface := head_at
				surface.y = area.surface_y(shape)
				var depth := surface.y - head_at.y
				if not result.in_water or depth > result.depth:
					result.depth = depth
					result.water_bounds = _room_bounds(shape, room_from_world)
					result.surface_height = (room_from_world * surface).y
				result.in_water = true
	return result


func _room_bounds(hull: CollisionShape3D, room_from_world: Transform3D) -> AABB:
	var box := hull.shape as BoxShape3D
	var local_bounds := (
		AABB(-box.size * 0.5, box.size) if box else hull.shape.get_debug_mesh().get_aabb()
	)
	return room_from_world * hull.global_transform * local_bounds


func blocked(pose: Transform3D) -> bool:
	_clearance.transform = pose * _cast_offset
	_clearance.motion = Vector3.ZERO
	if not _space.intersect_shape(_clearance, 1).is_empty():
		return true
	_clearance.motion = _clearance.transform.basis * _cast_motion
	return _space.cast_motion(_clearance)[0] < 1.0


func _sweep(body: RID, pose: Transform3D, motion: Vector3, recovery := false) -> bool:
	_params.from = pose
	_params.motion = motion
	_params.recovery_as_collision = recovery
	return PhysicsServer3D.body_test_motion(body, _params, _hit)


## Trial at the raised (or original, for descent) height, then slide along a wall
## before the downward probe. The caller keeps the actual horizontal travel for solve().
func _step_probe(
	body: RID,
	pose: Transform3D,
	forward: Vector3,
	height: Vector3,
	up: bool,
	profile: CogitoMovementProfile,
	result: Contact
) -> bool:
	if up:
		if _sweep(body, pose, height) and _hit.get_collision_normal().y < 0:
			return false
		pose.origin += height
	if _sweep(body, pose, forward, not up):
		var wall := _hit.get_collision_normal()
		if not up and not is_zero_approx(wall.y):
			return false
		pose.origin += wall * profile.wall_margin
		forward = forward.slide(wall)
		if _sweep(body, pose, forward, not up):
			return false
	pose.origin += forward
	if not _sweep(body, pose, -height, not up):
		return false
	var normal := _hit.get_collision_normal()
	var rise := STAIRS.rise(normal, _hit.get_remainder(), profile.step_max_slope_degree)
	if not up:
		rise = STAIRS.descent(
			normal, _hit.get_travel(), profile.step_down_margin, profile.step_max_slope_degree
		)
	if is_nan(rise):
		return false
	result.legacy = _dynamic_contact()
	result.stair = Vector3.UP * rise
	result.stair_normal = normal
	result.step_up = up
	return true


func _dynamic_contact() -> bool:
	var object := _hit.get_collider()
	if object is StaticBody3D:
		return (
			object is AnimatableBody3D
			or object.constant_linear_velocity != Vector3.ZERO
			or object.constant_angular_velocity != Vector3.ZERO
		)
	return object is PhysicsBody3D


func _stairs(
	body: RID,
	state: CogitoMovementState,
	profile: CogitoMovementProfile,
	dt: float,
	result: Contact
) -> void:
	var air := state.is_jumping_started or not state.on_floor
	var height := STAIRS.search_height(
		air,
		state.air_steps_enabled,
		profile.step_height_default,
		profile.step_height_in_air_default
	)
	var forward := state.main_velocity * dt
	if state.main_velocity.y >= 0:
		for i in profile.step_check_count:
			var candidate := STAIRS.candidate(height, i, profile.step_check_count)
			if _step_probe(body, result.pose, forward, candidate, true, profile, result):
				if air and not state.air_steps_enabled:
					result.stair = Vector3.ZERO
				return
	if state.on_floor and not state.is_jumping_started:
		_step_probe(body, result.pose, forward, height, false, profile, result)


## state.on_floor describes the previous solve. No CharacterBody contact cache is read.
func solve(
	origin: Transform3D, state: CogitoMovementState, profile: CogitoMovementProfile, dt: float
) -> Contact:
	var result := Contact.new()
	result.pose = origin
	result.velocity = state.requested_velocity
	var body := _standing if state.standing_shape else _crouching
	# Only a synchronous query sees the authored mask. A room physics step sees
	# two layer-zero, mask-zero bodies and cannot collide with them at world zero.
	PhysicsServer3D.body_set_collision_mask(body, _mask)
	_params.margin = 0.001  # PhysicsTestMotionParameters3D default used for Advanced's steps.
	if (
		state.mode
		not in [CogitoMovementState.Mode.LADDER_CLIMBING, CogitoMovementState.Mode.SWIMMING]
	):
		_stairs(body, state, profile, dt, result)
	result.pose.origin += result.stair
	var motion := result.velocity * dt
	_params.margin = _margin
	for i in _slides:
		var collided := _sweep(body, result.pose, motion, true)
		var travel := _hit.get_travel()
		# CharacterBody cancels small lateral recovery on its first grounded sweep.
		var along := motion.normalized()
		var projected := along * travel.dot(along)
		if i == 0 and (travel - projected).length() < _margin + 0.00001:
			travel = projected
		result.pose.origin += travel
		if not collided:
			break
		result.legacy = result.legacy or _dynamic_contact()
		var normal := _hit.get_collision_normal()
		var remainder := _hit.get_remainder()
		if normal.y >= _floor_cos:
			result.floor_normal = normal
			if result.velocity.y <= 0:
				result.velocity.y = 0
			if motion.slide(Vector3.UP).is_zero_approx():
				if travel.length() <= _margin + 0.00001:
					result.pose.origin -= travel
				break
		elif normal.y <= -_floor_cos:
			result.ceiling = true
			result.velocity.y = minf(0.0, result.velocity.y)
		else:
			result.wall_normal = normal
			var horizontal := normal.slide(Vector3.UP).normalized()
			if result.velocity.dot(horizontal) < 0:
				result.velocity = result.velocity.slide(horizontal)
		motion = remainder.slide(normal)
		if motion.dot(state.requested_velocity) <= 0.0 or motion.is_zero_approx():
			break
	if (
		result.floor_normal == Vector3.ZERO
		and state.on_floor
		and result.velocity.y <= 0
		and _sweep(body, result.pose, Vector3.DOWN * maxf(_snap, _margin), true)
	):
		var normal := _hit.get_collision_normal()
		if normal.y >= _floor_cos:
			result.legacy = result.legacy or _dynamic_contact()
			result.floor_normal = normal
			var travel := _hit.get_travel()
			if travel.length() > _margin:
				result.pose.origin.y += travel.y
	PhysicsServer3D.body_set_collision_mask(body, 0)
	return result

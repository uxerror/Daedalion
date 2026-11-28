extends RefCounted
## Value-only iteration against the owner's room. No actor movement or gameplay callbacks.

const Tick := preload("../CogitoObjects/cogito_movement_tick.gd")
const Collision := preload("../CogitoObjects/cogito_movement_collision.gd")
const MODE := CogitoMovementState.Mode
const ACTION := CogitoPlayerCommand.Action
const STAMINA := CogitoMovementStep.Stamina
const SUPPORTED := [
	MODE.IDLE,
	MODE.WALKING,
	MODE.SPRINTING,
	MODE.SNEAKING,
	MODE.SLIDING,
	MODE.JUMPING,
	MODE.AIR_CONTROL
]

var room: Collision
var profile: CogitoMovementProfile
var world_from_room := Transform3D.IDENTITY
var exclusions: Array[RID] = []
var _ledge := ShapeCast3D.new()
var _ledge_local: Transform3D
var _volume := PhysicsShapeQueryParameters3D.new()
var _space: PhysicsDirectSpaceState3D
var _actor: CogitoPlayerAdvanced


func _init(actor: CogitoPlayerAdvanced, tuning: CogitoMovementProfile, mask: int) -> void:
	_actor = actor
	profile = tuning
	room = Collision.new(actor, mask)
	_space = actor.get_world_3d().direct_space_state
	var authored := actor.ledge_climbing_shapecast
	_ledge_local = authored.transform
	_ledge_local.origin = actor.ledge_climbing_shapecast_initial_position
	_ledge.enabled = false
	_ledge.top_level = true
	_ledge.shape = authored.shape
	_ledge.margin = authored.margin
	_ledge.collision_mask = authored.collision_mask
	_ledge.max_results = authored.max_results
	actor.add_child(_ledge)
	_volume.collide_with_bodies = false
	_volume.collide_with_areas = true
	_volume.collision_mask = 0xffffffff
	prepare()


func prepare() -> void:
	var parent := _actor.get_parent_node_3d()
	if parent and not _actor.top_level:
		world_from_room = parent.global_transform
	exclusions.assign([_actor.get_rid()])
	var held: Node = _actor.player_interaction_component.carrying.carried_object
	if is_instance_valid(held) and held.get_parent() is PhysicsBody3D:
		exclusions.append(held.get_parent().get_rid())
	room.set_exclusions(exclusions)
	_volume.exclude = exclusions
	_ledge.clear_exceptions()
	for rid in exclusions:
		_ledge.add_exception_rid(rid)


func _legacy_volume(pose: Transform3D, standing: bool) -> bool:
	var hull := _actor.standing_collision_shape if standing else _actor.crouching_collision_shape
	_volume.transform = pose * hull.transform
	_volume.shape = hull.shape
	for overlap: Dictionary in _space.intersect_shape(_volume):
		if overlap.collider is Ladder or overlap.collider is WaterArea:
			return true
	return false


func advance(s: CogitoMovementState, raw: CogitoPlayerCommand, block: NetOwnerState) -> bool:
	var cmd := raw
	if block.input_blocked:
		cmd = CogitoPlayerCommand.new()
		cmd.yaw = s.body_yaw
		cmd.pitch = s.head_pitch
		cmd.neck_yaw = s.neck_yaw
		cmd.has_control = false
	var dt := 1.0 / block.rate
	var origin := world_from_room * s.transform
	if _legacy_volume(origin, s.standing_shape):
		return false
	var rotation := Basis.from_euler(Vector3(0, cmd.yaw, 0))
	s.body_basis = origin.basis * rotation
	s.body_yaw = cmd.yaw
	s.head_pitch = cmd.pitch
	s.neck_yaw = cmd.neck_yaw
	s.has_control = cmd.has_control
	if cmd.toggle_crouch and not s.posture_locked:
		for edge in cmd.edges:
			if edge == ACTION.CROUCH:
				s.try_crouch = not s.try_crouch
	s.cast_blocked = (s.cast_enabled or not s.standing_shape) and room.blocked(origin)
	var step := Tick.new()
	step.request(s, profile, cmd, dt)
	var hit := room.solve(origin, s, profile, dt)
	if hit.legacy or _legacy_volume(hit.pose, s.standing_shape):
		return false
	step.finish(s, profile, cmd, hit, dt, world_from_room.affine_inverse())
	if s.has_stamina:
		_advance_stamina(s, block, step.jump, hit.pose.origin.y, dt)
	return s.mode in SUPPORTED and not _captures_ledge(s, hit.pose)


func _captures_ledge(s: CogitoMovementState, pose: Transform3D) -> bool:
	if s.mode != MODE.JUMPING or not _actor.CAN_CLIMB_LEDGE or s.posture_locked:
		return false
	if s.posture == CogitoMovementState.Posture.CROUCHING or s.input_direction == Vector2.ZERO:
		return false
	var forward := -s.body_basis.z
	if s.direction.dot(forward) < 0.5:
		return false
	_ledge.global_transform = pose * _ledge_local
	return _actor.probe_ledge(_ledge, _ledge.position, forward, false, false)


func close() -> void:
	_ledge.free()
	room.close()


## Mirror the authority's fixed stamina timer against private movement values only.
func _advance_stamina(
	s: CogitoMovementState, b: NetOwnerState, jump: bool, height: float, dt: float
) -> void:
	if jump and not b.stamina_locked:
		s.stamina = maxf(0, s.stamina - b.jump_cost)
	if not s.regen_stopped:
		s.regen_remaining -= dt
		if s.regen_remaining <= 0.000001:
			s.regen_remaining = 0
			s.regen_stopped = true
			s.regen_active = s.stamina < b.value_max
	if s.regen_active:
		if not b.stamina_locked:
			s.stamina = minf(b.value_max, s.stamina + STAMINA.amount(b.stamina_regen_speed, dt))
		s.regen_active = s.stamina < b.value_max
	var sprint := s.mode == MODE.SPRINTING
	if sprint and STAMINA.spends_on_run(s.current_speed, profile.walking_speed, s.velocity):
		s.regen_remaining = 0
		s.regen_stopped = true
		s.regen_active = false
		var rate := b.run_exhaustion_speed
		if b.use_floor_slope_for_run_exhaustion:
			rate = STAMINA.run_rate(
				s.floor_normal,
				s.main_velocity,
				height,
				s.previous_y,
				b.step_slope_multiplier,
				rate,
				b.uphill_run_exhaustion_max_speed,
				b.downhill_run_exhaustion_max_speed
			)
		if not b.stamina_locked:
			s.stamina = maxf(0, s.stamina - STAMINA.amount(rate, dt))
	s.previous_y = height
	if s.regen_stopped and not s.regen_active and not sprint and s.stamina < b.value_max:
		s.regen_stopped = false
		s.regen_remaining = b.regenerate_after

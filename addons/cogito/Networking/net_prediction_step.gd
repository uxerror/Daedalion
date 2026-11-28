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
	MODE.AIR_CONTROL,
	MODE.LADDER_CLIMBING,
	MODE.SWIMMING,
	MODE.ROLLING,
	MODE.LEDGE_CLIMBING
]

var room: Collision
var profile: CogitoMovementProfile
var world_from_room := Transform3D.IDENTITY
var exclusions: Array[RID] = []
var suspend_reason := "unsupported_contact"
var _actor: CogitoPlayerAdvanced
var _step := Tick.new()
var _volume := Collision.Volumes.new()
var _contact := Collision.Contact.new()
var _blocked_command := CogitoPlayerCommand.new()


func _init(actor: CogitoPlayerAdvanced, tuning: CogitoMovementProfile, mask: int) -> void:
	_actor = actor
	profile = tuning
	room = Collision.new(actor, mask)
	prepare()


func prepare() -> void:
	var parent := _actor.get_parent_node_3d()
	if parent and not _actor.top_level:
		world_from_room = parent.global_transform
	exclusions.clear()
	exclusions.append(_actor.get_rid())
	for exception in _actor.get_collision_exceptions():
		if is_instance_valid(exception):
			exclusions.append(exception.get_rid())
	var held: Node = _actor.player_interaction_component.carrying.carried_object
	if is_instance_valid(held) and held.get_parent() is PhysicsBody3D:
		exclusions.append(held.get_parent().get_rid())
	room.set_exclusions(exclusions)


func advance(s: CogitoMovementState, raw: CogitoPlayerCommand, block: NetOwnerState) -> bool:
	room.boundary_collider_id = 0
	var cmd := raw
	if block.input_blocked:
		cmd = _blocked_command
		cmd.yaw = s.body_yaw
		cmd.pitch = s.head_pitch
		cmd.neck_yaw = s.neck_yaw
		cmd.has_control = false
	if not room.prepare_support(s, block.tick + raw.sequence - block.ack):
		suspend_reason = "dynamic_support"
		return false
	var dt := 1.0 / block.rate
	var origin := world_from_room * s.transform
	var rotation := Basis.from_euler(Vector3(0, cmd.yaw, 0))
	s.body_basis = origin.basis * rotation
	s.body_yaw = cmd.yaw
	s.head_pitch = cmd.pitch
	s.neck_yaw = cmd.neck_yaw
	s.has_control = cmd.has_control
	var fixed_posture := s.mode in [MODE.SWIMMING, MODE.LEDGE_CLIMBING]
	if cmd.toggle_crouch and not s.posture_locked and not fixed_posture:
		for edge in cmd.edges:
			if edge == ACTION.CROUCH:
				s.try_crouch = not s.try_crouch
	s.cast_blocked = (s.cast_enabled or not s.standing_shape) and room.blocked(origin)
	var step := _step
	var volume := room.volumes(origin, s, cmd, _volume)
	suspend_reason = "unsupported_contact"
	step.request(s, profile, cmd, dt, volume)
	if volume.moving_ledge and s.mode == MODE.LEDGE_CLIMBING:
		suspend_reason = "moving_ledge"
		if is_instance_valid(volume.observation.collider):
			room.boundary_collider_id = volume.observation.collider.get_instance_id()
		return false
	var hit := room.solve(origin, s, profile, dt, _contact)
	if hit.legacy:
		suspend_reason = "dynamic_support" if hit.dynamic_floor else "unsupported_contact"
		return false
	step.finish(s, profile, cmd, hit, dt, world_from_room.affine_inverse())
	if s.has_stamina:
		_advance_stamina(s, block, step.jump, hit.pose.origin.y, dt)
	return s.mode in SUPPORTED


func close() -> void:
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

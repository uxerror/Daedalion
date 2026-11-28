extends RefCounted
## Value phases for one authority command. The adapter commits effects only after
## its room accepts the requested motion (a dynamic collision can revoke this tick).

const Step := preload("cogito_movement_step.gd")
const MODE := CogitoMovementState.Mode
const STAGE := CogitoMovementState.LedgeStage
const POSTURE := CogitoMovementState.Posture
const ACTION := CogitoPlayerCommand.Action
const Collision := preload("cogito_movement_collision.gd")

var jump := false
var landed := false
var landing: CogitoMovementStep.Landing = CogitoMovementStep.Landing.NONE
var damage := 0
var ground_effects := false
var entered_ledge := false
var exited_ledge := false
var finished_roll := false
var entered_ladder := false
var left_volume_on_floor := false
var cadence_mode := MODE.UNDEFINED
var _enter_swim := false


func request(
	s: CogitoMovementState,
	p: CogitoMovementProfile,
	cmd: CogitoPlayerCommand,
	dt: float,
	volume: Collision.Volumes = null
) -> void:
	jump = false
	landed = false
	landing = Step.Landing.NONE
	damage = 0
	ground_effects = false
	entered_ledge = false
	exited_ledge = false
	finished_roll = false
	entered_ladder = false
	left_volume_on_floor = false
	cadence_mode = MODE.UNDEFINED
	_enter_swim = false
	s.input_direction = cmd.move
	s.jump_remaining = maxf(0, s.jump_remaining - dt)
	s.slide_remaining = maxf(0, s.slide_remaining - dt)
	s.jump_stopped = s.jump_remaining <= 0
	s.slide_stopped = s.slide_remaining <= 0
	s.ladder_ticks = maxi(0, s.ladder_ticks - 1)
	if volume:
		if volume.ledge and s.mode in [MODE.JUMPING, MODE.SWIMMING]:
			_start_ledge(s, p, volume)
			return
		if s.mode == MODE.LEDGE_CLIMBING:
			s.submerged = volume.submerged
			if cmd.is_held(ACTION.JUMP) or s.ledge_stage != STAGE.RISE:
				_ledge(s, p, volume.world_from_room)
				return
			_leave_ledge(s, p, true)
			s.ladder_contact = 0
		var aim := s.body_basis * Basis(Vector3.UP, s.neck_yaw) * Basis(Vector3.RIGHT, s.head_pitch)
		_volume_mode(s, p, volume, aim, dt)
		if s.mode == MODE.SWIMMING:
			_swim(s, p, cmd, aim, dt)
			return
		if s.mode == MODE.LADDER_CLIMBING:
			_posture(s, p, cmd)
			_climb(s, p, cmd, volume.outward, aim, dt)
			return
	if s.mode == MODE.ROLLING:
		Step.request_motion(s, cmd.has_control, dt, s)
		return
	_posture(s, p, cmd)
	var air := s.mode in [MODE.JUMPING, MODE.AIR_CONTROL]
	if not air and s.on_floor and not _enter_swim:
		_takeoff(s, p, cmd, dt)
		if jump and volume and volume.ledge and not volume.moving_ledge:
			_start_ledge(s, p, volume)
			return
	var axes := s.slide_vector if s.mode == MODE.SLIDING else cmd.move
	s.direction = (
		Step.air_heading(s.direction, s.body_basis, axes)
		if air
		else Step.heading(s.body_basis, axes)
	)
	s.current_speed = clampf(s.current_speed, p.min_speed, p.max_speed)
	Step.request_motion(s, cmd.has_control, dt, s)


func _start_ledge(s: CogitoMovementState, p: CogitoMovementProfile, v: Collision.Volumes) -> void:
	entered_ledge = true
	if s.mode == MODE.JUMPING:
		s.bunny_hop_speed = p.sprinting_speed
	s.mode = MODE.LEDGE_CLIMBING
	s.ledge_target = v.world_from_room.affine_inverse() * v.ledge.target
	s.ledge_key = v.ledge_key
	s.ledge_stage = STAGE.RISE
	s.main_velocity = Vector3.ZERO
	s.last_velocity = Vector3.ZERO
	s.gravity_vec = Vector3.ZERO
	s.direction = Vector3.ZERO
	s.was_jumping = false
	s.submerged = v.submerged
	s.requested_velocity = Vector3.UP * p.climb_speed


func _ledge(s: CogitoMovementState, p: CogitoMovementProfile, world: Transform3D) -> void:
	var center := world * (s.transform * p.crouching_center)
	var target := world * s.ledge_target
	s.requested_velocity = Vector3.UP * p.climb_speed
	if Step.Ledge.rising(center.y, target.y, p.standing_height, p.crouching_height):
		return
	if s.posture != POSTURE.CROUCHING:
		s.ledge_stage = STAGE.MIDDLE
		s.try_crouch = true
		s.posture = POSTURE.CROUCHING
		s.standing_shape = false
		s.crouching_shape = true
		s.requested_velocity = Vector3.ZERO
		return
	if s.ledge_stage != STAGE.FINAL:
		s.ledge_stage = STAGE.MIDDLE
		if Step.Ledge.below_lip(center.y, target.y, p.crouching_height, p.head_clearance):
			return
	s.ledge_stage = STAGE.FINAL
	var goal := Step.Ledge.destination(target, p.crouching_height)
	s.requested_velocity = center.direction_to(goal) * p.climb_speed


func _leave_ledge(s: CogitoMovementState, p: CogitoMovementProfile, stand: bool) -> void:
	exited_ledge = true
	s.mode = MODE.IDLE
	s.ledge_key = 0
	s.ledge_target = Vector3.ZERO
	s.ledge_stage = STAGE.RISE
	s.current_lerp_speed = p.lerp_speed
	if stand:
		s.try_crouch = false
		if not s.cast_blocked:
			_stand(s)


func _volume_mode(
	s: CogitoMovementState, p: CogitoMovementProfile, v: Collision.Volumes, aim: Basis, dt: float
) -> void:
	s.submerged = v.submerged
	s.swim_depth = v.depth
	var entered := v.ladder_key != 0 and s.ladder_contact != v.ladder_key
	s.ladder_contact = v.ladder_key
	if entered and Step.Climb.accepts(aim, v.outward):
		entered_ladder = true
		s.mode = MODE.LADDER_CLIMBING
		s.on_ladder = true
		s.last_velocity = Vector3.ZERO
		s.was_jumping = false
		s.ladder_ticks = ceili(p.ladder_cooldown / dt)
	if s.on_ladder and v.ladder_key != 0:
		if s.was_swimming and not v.submerged:
			_leave_swim(s, p)
		return
	if s.mode == MODE.LADDER_CLIMBING:
		s.on_ladder = false
		s.mode = MODE.AIR_CONTROL
		s.was_in_air = true
		s.current_lerp_speed = p.air_lerp_speed
	if s.mode == MODE.SWIMMING:
		if not v.submerged and (s.on_floor or not v.in_water):
			_leave_swim(s, p)
			left_volume_on_floor = s.on_floor
			s.mode = MODE.IDLE if s.on_floor else MODE.AIR_CONTROL
			s.current_lerp_speed = p.lerp_speed if s.on_floor else p.air_lerp_speed
	elif v.submerged:
		_enter_swim = true
		s.crouched_before_swim = s.posture == POSTURE.CROUCHING


func _start_swim(s: CogitoMovementState) -> void:
	s.was_swimming = true
	s.mode = MODE.SWIMMING
	s.try_crouch = true
	s.posture = POSTURE.CROUCHING
	s.standing_shape = false
	s.crouching_shape = true
	s.last_velocity = Vector3.ZERO
	s.gravity_vec = Vector3.ZERO
	s.direction = Vector3.ZERO


func _leave_swim(s: CogitoMovementState, p: CogitoMovementProfile) -> void:
	s.was_swimming = false
	if p.auto_stand_after_swim or not s.crouched_before_swim:
		s.try_crouch = false
		if not s.cast_blocked:
			_stand(s)


func _swim(
	s: CogitoMovementState,
	p: CogitoMovementProfile,
	cmd: CogitoPlayerCommand,
	aim: Basis,
	dt: float
) -> void:
	var rise := cmd.is_held(ACTION.JUMP)
	var dive := cmd.is_held(ACTION.CROUCH)
	if rise and cmd.move != Vector2.ZERO and not s.posture_locked:
		s.direction = Step.heading(s.body_basis, cmd.move)
	var heading := Step.Swim.heading(aim, cmd.move, rise, dive, s.on_floor, s.submerged)
	s.current_speed = Step.approach(s.current_speed, p.swimming_speed, dt, p.lerp_speed)
	var idle := cmd.move == Vector2.ZERO and not rise and not dive
	var sink := s.gravity * p.water_gravity * dt if idle and not s.on_floor else 0.0
	s.main_velocity = Step.Swim.velocity(
		s.main_velocity, heading, s.current_speed * s.speed_multiplier, dt * p.lerp_speed, sink
	)
	s.requested_velocity = s.main_velocity


func _climb(
	s: CogitoMovementState,
	p: CogitoMovementProfile,
	cmd: CogitoPlayerCommand,
	outward: Vector3,
	aim: Basis,
	dt: float
) -> void:
	s.direction = Step.Climb.heading(s.body_basis, aim, cmd.move)
	var sprint := p.can_sprint_on_ladder and cmd.is_held(ACTION.SPRINT)
	var speed := Step.Climb.speed(
		cmd.move, sprint, s.stamina, p.ladder_speed, p.ladder_sprint_speed
	)
	s.main_velocity = s.direction * speed * s.speed_multiplier
	if cmd.is_held(ACTION.JUMP) and Step.Climb.jumping(s.body_basis, cmd.move, outward):
		_takeoff(s, p, cmd, dt)
		if jump:
			s.on_ladder = false
			s.jump_target_speed = p.walking_speed
			s.main_velocity.y *= p.ladder_jump_scale
			s.direction = Step.heading(s.body_basis, cmd.move)
			Step.request_motion(s, cmd.has_control, dt, s)
			return
		s.requested_velocity = Vector3.ZERO
	else:
		s.requested_velocity = s.main_velocity


func _posture(s: CogitoMovementState, p: CogitoMovementProfile, cmd: CogitoPlayerCommand) -> void:
	if s.posture_locked:
		return
	s.try_crouch = Step.Posture.latch(s.try_crouch, cmd.toggle_crouch, cmd.is_held(ACTION.CROUCH))
	var crouch := Step.Posture.crouch_requested(s.try_crouch, s.cast_blocked)
	if crouch and s.posture != POSTURE.CROUCHING:
		s.posture = POSTURE.CROUCHING
		s.standing_shape = false
		s.crouching_shape = true
		if s.mode == MODE.SPRINTING:
			_start_slide(s, p)
		elif s.mode == MODE.WALKING:
			s.mode = MODE.SNEAKING
	elif not crouch and s.posture == POSTURE.CROUCHING:
		_stand(s)


func _stand(s: CogitoMovementState) -> void:
	s.posture = POSTURE.STANDING
	s.slide_remaining = 0
	s.slide_stopped = true
	if s.mode == MODE.SLIDING:
		s.mode = MODE.IDLE
	elif s.mode == MODE.SNEAKING:
		s.mode = MODE.WALKING


func _start_slide(s: CogitoMovementState, p: CogitoMovementProfile) -> void:
	s.mode = MODE.SLIDING
	Step.Slide.enter(s, s.input_direction, p.slide_duration, s)
	s.slide_stopped = false


func _takeoff(
	s: CogitoMovementState, p: CogitoMovementProfile, cmd: CogitoPlayerCommand, dt: float
) -> void:
	if not cmd.is_held(ACTION.JUMP) or (not s.jump_stopped and not s.on_ladder):
		return
	var crouched := s.posture == POSTURE.CROUCHING
	var affordable := Step.Stamina.jump_affordable(s.has_stamina, s.stamina, p.jump_cost)
	if (
		Step.Jump.eligibility(false, s.jump_allowed, affordable, crouched, p.can_crouch_jump)
		!= Step.Jump.Eligibility.READY
	):
		return
	s.jumped_from_slide = s.mode == MODE.SLIDING
	s.jumped_from_crouch = crouched
	s.jump_target_speed = p.crouching_speed if crouched else p.walking_speed
	s.main_velocity.y = Step.Jump.velocity(crouched, p.jump_velocity, p.crouch_jump_velocity)
	if s.jumped_from_slide:
		s.current_speed = Step.Slide.speed(s.slide_remaining, p.slide_duration, p.sliding_speed)
		s.jump_target_speed = s.current_speed
		s.main_velocity.y = Step.Jump.slide_velocity(p.jump_velocity, p.slide_jump_mod)
		s.slide_remaining = 0
		s.slide_stopped = true
		s.try_crouch = false
		if not s.cast_blocked:
			_stand(s)
	elif s.mode == MODE.SPRINTING:
		Step.Ground.sprint_takeoff(s, p, dt, s)
		s.jump_target_speed = s.bunny_hop_speed
	s.main_velocity += Step.platform_takeoff(s.support_velocity, p.platform_on_leave)
	s.was_sprinting = cmd.is_held(ACTION.SPRINT)
	s.was_jumping = true
	s.was_in_air = true
	s.is_jumping_started = true
	s.mode = MODE.JUMPING
	s.current_lerp_speed = p.air_lerp_speed
	s.jump_remaining = p.jump_cooldown
	s.jump_stopped = false
	jump = true


func finish(
	s: CogitoMovementState,
	p: CogitoMovementProfile,
	cmd: CogitoPlayerCommand,
	hit: Collision.Contact,
	dt: float,
	room_from_world: Transform3D
) -> void:
	s.is_in_air = not s.on_floor or s.is_jumping_started
	if hit.stair != Vector3.ZERO:
		s.head_offset = hit.stair
		s.head_position -= s.head_offset
		s.head_position.y = Step.approach(s.head_position.y, 0.0, dt, p.step_height_camera_lerp)
	else:
		s.head_offset = s.head_offset.lerp(Vector3.ZERO, dt * p.lerp_speed)
	if Step.Stairs.damp_momentum(
		hit.step_up, s.air_steps_enabled, s.is_in_air, s.direction, hit.stair_normal
	):
		s.main_velocity *= p.speed_clamp_after_jump_coefficient
		s.gravity_vec *= p.speed_clamp_after_jump_coefficient
	var volume_mode := s.mode in [MODE.LADDER_CLIMBING, MODE.SWIMMING]
	var climbing := s.mode == MODE.LEDGE_CLIMBING
	if not volume_mode and not climbing:
		s.main_velocity = Step.with_gravity(s.main_velocity, s.gravity_vec)
	s.transform = room_from_world * hit.pose
	s.velocity = hit.velocity
	s.is_jumping_started = false
	s.floor_normal = hit.floor_normal
	s.on_floor = hit.floor_normal != Vector3.ZERO
	s.wall_normal = hit.wall_normal
	s.on_wall = hit.wall_normal != Vector3.ZERO
	s.on_ceiling = hit.ceiling
	if climbing:
		s.eye_position.y = Step.Swim.eye_height(s.eye_position.y, s.submerged, dt * p.lerp_speed)
		var target := room_from_world.affine_inverse() * s.ledge_target
		var goal := Step.Ledge.destination(target, p.crouching_height)
		if s.ledge_stage == STAGE.FINAL and Step.Ledge.reached(hit.pose * p.crouching_center, goal):
			_leave_ledge(s, p, p.auto_stand_after_climb)
	elif _enter_swim:
		# Advanced observes the head after the ground/air solve. Swim input starts
		# on the first tick spent in the new state.
		_start_swim(s)
	elif volume_mode:
		s.eye_position.y = Step.Swim.eye_height(s.eye_position.y, s.submerged, dt * p.lerp_speed)
		if s.on_ladder and s.on_floor and s.ladder_ticks == 0:
			s.on_ladder = false
			s.mode = MODE.IDLE
			s.current_lerp_speed = p.lerp_speed
			left_volume_on_floor = true
	elif s.mode in [MODE.AIR_CONTROL, MODE.JUMPING]:
		_air(s, p, cmd, dt)
	elif s.mode == MODE.ROLLING and s.on_floor:
		s.roll_ticks = maxi(0, s.roll_ticks - 1)
		if s.roll_ticks == 0:
			finished_roll = true
			s.mode = MODE.IDLE
			if s.was_standing:
				s.try_crouch = false
				if not s.cast_blocked:
					_stand(s)
	elif s.on_floor:
		_ground(s, p, cmd, dt)
	else:
		s.was_sliding = s.mode == MODE.SLIDING
		s.was_in_air = true
		s.mode = MODE.AIR_CONTROL
		s.current_lerp_speed = p.air_lerp_speed
	if s.mode == MODE.ROLLING or finished_roll:
		s.eye_position.y = Step.Swim.eye_height(s.eye_position.y, s.submerged, dt * p.lerp_speed)
	if s.mode != MODE.ROLLING:
		s.roll_ticks = 0
	var crouched := s.posture == POSTURE.CROUCHING
	s.cast_enabled = crouched
	s.head_position.y = Step.Posture.head_height(
		s.head_position.y, crouched, p.crouching_depth, dt, p.lerp_speed
	)
	if not crouched and Step.Posture.tall_shape_ready(s.head_position.y, p.crouching_depth):
		s.standing_shape = true
		s.crouching_shape = false
	if climbing and exited_ledge:
		hit.attach(hit.floor_support, hit.pose.origin, dt)
	s.support_key = hit.support_key
	s.support_local = hit.support_local
	s.support_velocity = hit.support_velocity


func _air(
	s: CogitoMovementState, p: CogitoMovementProfile, cmd: CogitoPlayerCommand, dt: float
) -> void:
	Step.finish_air(s, s.on_ceiling, cmd.is_held(ACTION.SPRINT), p.sprinting_speed, dt, s)
	if s.on_floor:
		landed = true
		s.mode = MODE.IDLE
		s.current_lerp_speed = p.lerp_speed
		s.was_in_air = false
		var impact := Step.landing(
			s.last_velocity.y, p.landing_min_roll_velocity, p.landing_min_velocity
		)
		if Step.Roll.starts(impact, p.disable_roll_anim):
			_ground(s, p, cmd, dt)
	elif s.mode == MODE.JUMPING:
		s.current_speed = Step.Ground.speed(MODE.JUMPING, s, p, dt)
		if (
			s.on_wall
			and Step.Jump.hits_wall(s.direction, s.wall_normal, p.bunny_hop_wall_slide_angle)
		):
			s.bunny_hop_speed = p.sprinting_speed
	if not s.on_floor and s.main_velocity.y <= p.free_fall_min_velocity:
		s.mode = MODE.FREE_FALL


func _ground(
	s: CogitoMovementState, p: CogitoMovementProfile, cmd: CogitoPlayerCommand, dt: float
) -> void:
	s.main_velocity.y = 0
	s.gravity_vec = Vector3.ZERO
	if p.fall_damage > 0 and s.last_velocity.y <= p.fall_damage_threshold:
		damage = int(p.fall_damage * s.last_velocity.y / p.fall_damage_threshold)
	landing = Step.landing(s.last_velocity.y, p.landing_min_roll_velocity, p.landing_min_velocity)
	if Step.Roll.starts(landing, p.disable_roll_anim):
		s.was_standing = s.posture == POSTURE.STANDING
		s.is_sprinting_in_airborne = false
		s.mode = MODE.ROLLING
		s.roll_ticks = p.roll_duration_ticks
		s.try_crouch = true
		s.posture = POSTURE.CROUCHING
		s.standing_shape = false
		s.crouching_shape = true
		return
	var sprint := cmd.is_held(ACTION.SPRINT)
	var crouched := s.posture == POSTURE.CROUCHING
	if (
		s.was_sliding
		or Step.Slide.from_jump(
			s.was_jumping,
			s.jumped_from_slide,
			sprint,
			s.is_sprinting_in_airborne,
			crouched,
			s.jumped_from_crouch
		)
	):
		_start_slide(s, p)
	s.is_sprinting_in_airborne = false
	ground_effects = true
	match s.mode:
		MODE.IDLE:
			if not s.main_velocity.is_equal_approx(Vector3.ZERO):
				s.mode = MODE.SNEAKING if crouched else MODE.WALKING
		MODE.WALKING:
			if Step.Stamina.can_start_sprint(false, sprint, s.has_stamina, s.stamina):
				s.mode = MODE.SPRINTING
			else:
				cadence_mode = MODE.WALKING
				s.current_speed = Step.Ground.speed(s.mode, s, p, dt)
		MODE.SPRINTING:
			if (
				not sprint
				or Step.Stamina.sprint(s.has_stamina, s.stamina) != Step.Stamina.Sprint.ACTIVE
			):
				s.bunny_hop_speed = p.sprinting_speed
				s.mode = MODE.WALKING
			else:
				cadence_mode = MODE.SPRINTING
				if p.can_bunnyhop:
					s.bunny_hop_speed = p.sprinting_speed
				s.current_speed = Step.Ground.speed(s.mode, s, p, dt)
		MODE.SNEAKING:
			cadence_mode = MODE.SNEAKING
			s.current_speed = Step.Ground.speed(s.mode, s, p, dt)
		MODE.SLIDING:
			var action := Step.Slide.action(cmd.move, sprint, s.slide_stopped, not crouched)
			match action:
				Step.Slide.Action.IDLE:
					s.mode = MODE.IDLE
				Step.Slide.Action.SNEAK:
					s.mode = MODE.SNEAKING
				Step.Slide.Action.WALK:
					s.mode = MODE.WALKING
				Step.Slide.Action.CONTINUE:
					s.current_speed = Step.Slide.speed(
						s.slide_remaining, p.slide_duration, p.sliding_speed
					)
			if not sprint or cmd.move == Vector2.ZERO:
				s.slide_remaining = 0
				s.slide_stopped = true
	if s.mode in [MODE.WALKING, MODE.SNEAKING] and s.main_velocity.is_equal_approx(Vector3.ZERO):
		s.mode = MODE.IDLE

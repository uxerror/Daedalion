extends RefCounted
## Per-incarnation live adapter. The chart still receives its public transitions.
## Its physics callbacks sleep through a kernel commit, including transitions to legacy.

const Tick := preload("../CogitoObjects/cogito_movement_tick.gd")
const Collision := preload("../CogitoObjects/cogito_movement_collision.gd")
const MODE := CogitoMovementState.Mode
const POSTURE := CogitoMovementState.Posture
const EVENTS := {
	MODE.IDLE: &"idle",
	MODE.WALKING: &"walk",
	MODE.SPRINTING: &"sprint",
	MODE.SLIDING: &"slide",
	MODE.SNEAKING: &"sneak",
	MODE.ROLLING: &"roll",
	MODE.JUMPING: &"jump",
	MODE.AIR_CONTROL: &"airborne",
	MODE.FREE_FALL: &"fall",
}

var room: Collision
var profile: CogitoMovementProfile
var contacts: Collision.Contact
var pending_force := Vector3.ZERO
var force_requested := false
var solves := 0
var _chart_root: Node
var _fixed := false
var _teleported := false


func _init(actor: CogitoPlayerAdvanced, tuning: CogitoMovementProfile) -> void:
	profile = tuning
	room = Collision.new(actor)
	_chart_root = actor.state_chart.get_node("Root")


func _clock(actor: CogitoPlayerAdvanced, fixed: bool) -> void:
	_chart_root.process_mode = Node.PROCESS_MODE_DISABLED if fixed else Node.PROCESS_MODE_INHERIT
	if _fixed == fixed:
		return
	_fixed = fixed
	actor.jump_timer.paused = fixed
	actor.sliding_timer.paused = fixed
	var stamina := actor.stamina_attribute as CogitoStaminaAttribute
	if stamina:
		stamina.set_process(not fixed)
		stamina.regen_timer.paused = fixed


func invalidate() -> void:
	_teleported = true
	contacts = null
	pending_force = Vector3.ZERO
	force_requested = false


func unbind(actor: CogitoPlayerAdvanced) -> void:
	invalidate()
	_clock(actor, false)
	if room:
		room.close()
		room = null


func _supported(actor: CogitoPlayerAdvanced) -> bool:
	return (
		not actor.is_sitting
		and not actor.on_ladder
		and not actor.currently_tweening
		and not actor.is_body_in_water()
		and not actor.is_head_in_water()
		and actor.gravity_vector == Vector3.DOWN
		and (
			actor.current_moving_state
			in [
				MODE.IDLE,
				MODE.WALKING,
				MODE.SPRINTING,
				MODE.SNEAKING,
				MODE.SLIDING,
				MODE.JUMPING,
				MODE.AIR_CONTROL
			]
		)
	)


func advance(actor: CogitoPlayerAdvanced, dt: float) -> void:
	if force_requested:
		_clock(actor, false)
		_chart_root.process_mode = Node.PROCESS_MODE_DISABLED
		actor.velocity += pending_force
		actor._move_body()
		pending_force = Vector3.ZERO
		force_requested = false
		return
	if actor.current_moving_state == MODE.SITTING and not actor.is_sitting:
		# NetSeats has already committed the exit transform synchronously.
		var exit_seat := _chart_root.get_node("Moving/Grounded/Sitting/On Grounded") as Transition
		exit_seat.take()
	if actor.current_moving_state == MODE.SWIMMING and not actor.is_body_in_water():
		if not actor.is_head_in_water():
			actor._show_underwater_effect(false)
			actor._handle_swim_under_water_sounds()
			actor.state_chart.send_event("grounded" if actor.movement_grounded() else "airborne")
			if actor.AUTO_STAND_AFTER_SWIM or not actor.was_in_crouching_state_before_swim:
				actor.try_crouch = false
				actor.state_chart.send_event("stand_up")
	if not _supported(actor):
		_clock(actor, false)
		return
	if not room:
		room = Collision.new(actor)
	var excluded: Array[RID] = [actor.get_rid()]
	for exception in actor.get_collision_exceptions():
		if is_instance_valid(exception):
			excluded.append(exception.get_rid())
	var held: Node = actor.player_interaction_component.carrying.carried_object
	if is_instance_valid(held) and held.get_parent() is PhysicsBody3D:
		excluded.append(held.get_parent().get_rid())
	room.set_exclusions(excluded)
	var origin := actor.global_transform
	if _teleported or (not contacts and actor.is_on_floor()):
		var support := room.support(origin, not actor.standing_collision_shape.disabled)
		if support.legacy:
			_clock(actor, false)
			return
		if _teleported:
			contacts = support
			_teleported = false
	var s := actor.capture_movement_state()
	s.cast_blocked = (s.cast_enabled or not s.standing_shape) and room.blocked(origin)
	var tick := Tick.new()
	tick.request(s, profile, actor.current_command, dt)
	var hit := room.solve(origin, s, profile, dt)
	if hit.legacy:
		_clock(actor, false)
		return
	_clock(actor, true)
	var parent := actor.get_parent_node_3d()
	var room_from_world := Transform3D.IDENTITY
	if parent and not actor.top_level:
		room_from_world = parent.global_transform.affine_inverse()
	tick.finish(s, profile, actor.current_command, hit, dt, room_from_world)
	contacts = hit
	solves += 1
	actor.authority_solve_count += 1
	actor.transform = s.transform
	_publish(actor, s, tick)
	_effects(actor, tick, dt)
	if actor.current_moving_state == MODE.JUMPING and s.posture != POSTURE.CROUCHING:
		if actor._is_ledge_climbable():
			actor.bunny_hop_speed = profile.sprinting_speed
			actor.state_chart.send_event("ledge_climb")


func _timer(timer: Timer, remaining: float, duration: float) -> void:
	if remaining <= 0:
		timer.stop()
	else:
		timer.start(remaining)
		timer.wait_time = duration


func _publish(actor: CogitoPlayerAdvanced, s: CogitoMovementState, tick: Tick) -> void:
	actor.velocity = s.velocity
	actor._motion.requested_velocity = s.requested_velocity
	actor.main_velocity = s.main_velocity
	actor.last_velocity = s.last_velocity
	actor.direction = s.direction
	actor.input_direction = s.input_direction
	actor.gravity_vec = s.gravity_vec
	actor.head_offset = s.head_offset
	actor.is_in_air = s.is_in_air
	actor.is_jumping_started = s.is_jumping_started
	actor.jump_target_speed = s.jump_target_speed
	actor.jumped_from_crouch = s.jumped_from_crouch
	actor.jumped_from_slide = s.jumped_from_slide
	actor.was_jumping = s.was_jumping
	actor.was_sprinting = s.was_sprinting
	actor.is_sprinting_in_airborne = s.is_sprinting_in_airborne
	actor.was_standing = s.was_standing
	actor.bunny_hop_speed = s.bunny_hop_speed
	actor.try_crouch = s.try_crouch
	actor.state_chart.set_expression_property("is_crouch_shapecast_colliding", s.cast_blocked)
	if s.posture != int(actor.current_body_posture_state):
		actor.state_chart.send_event("crouch" if s.posture == POSTURE.CROUCHING else "stand_up")
	if tick.landed:
		actor.state_chart.send_event("grounded")
	if s.mode != int(actor.current_moving_state):
		actor.state_chart.send_event(EVENTS[s.mode])
	actor.current_speed = s.current_speed
	actor.current_lerp_speed = s.current_lerp_speed
	actor.was_in_air = s.was_in_air
	actor.was_sliding = s.was_sliding
	actor.slide_vector = s.slide_vector
	_timer(actor.jump_timer, s.jump_remaining, profile.jump_cooldown)
	_timer(actor.sliding_timer, s.slide_remaining, profile.slide_duration)
	if s.mode != MODE.ROLLING:
		actor.standing_collision_shape.disabled = not s.standing_shape
		actor.crouching_collision_shape.disabled = not s.crouching_shape
	actor.head.position = s.head_position
	actor.swimming_head_shapecast.global_position = actor.head.global_position


func _effects(actor: CogitoPlayerAdvanced, tick: Tick, dt: float) -> void:
	if tick.jump:
		if actor.stamina_attribute:
			actor.decrease_attribute("stamina", profile.jump_cost)
		actor.animationPlayer.play("jump")
		if actor.is_local_presentation:
			CogitoAudio.play_sound(actor.jump_sound)
	if tick.damage > 0:
		actor.decrease_attribute("health", tick.damage)
	if tick.landing == CogitoMovementStep.Landing.LAND:
		actor.animationPlayer.play("landing")
	if tick.ground_effects:
		actor._ground_eye(dt)
		actor._footstep_sounds_system()
		match tick.cadence_mode:
			MODE.WALKING:
				actor.wiggle_current_intensity = (
					actor.WIGGLE_ON_WALKING_INTENSITY * actor.HEADBOBBLE
				)
				actor.wiggle_index += actor.WIGGLE_ON_WALKING_SPEED * dt
			MODE.SPRINTING:
				actor.wiggle_current_intensity = (
					actor.WIGGLE_ON_SPRINTING_INTENSITY * actor.HEADBOBBLE
				)
				actor.wiggle_index += actor.WIGGLE_ON_SPRINTING_SPEED * dt
			MODE.SNEAKING:
				actor.wiggle_index += actor.WIGGLE_ON_CROUCHING_SPEED * dt
	elif actor.slide_audio_player:
		actor.slide_audio_player.stop()
	actor._handle_eyes_position_in_water(dt)
	var stamina := actor.stamina_attribute as CogitoStaminaAttribute
	if stamina and not actor.is_dead:
		stamina.advance_movement_tick(dt)

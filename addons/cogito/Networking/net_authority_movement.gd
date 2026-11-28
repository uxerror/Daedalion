extends RefCounted
## Per-incarnation live adapter. The chart still receives its public transitions.
## Its physics callbacks sleep through a kernel commit, including transitions to legacy.

const Tick := preload("../CogitoObjects/cogito_movement_tick.gd")
const Collision := preload("../CogitoObjects/cogito_movement_collision.gd")
const MovementAudio := preload("net_movement_audio.gd")
const Snapshot := preload("net_snapshot.gd")
const MODE := CogitoMovementState.Mode
const STAGE := CogitoMovementState.LedgeStage
const POSTURE := CogitoMovementState.Posture
const EVENTS := {
	MODE.IDLE: &"idle",
	MODE.LADDER_CLIMBING: &"climb_ladder",
	MODE.SWIMMING: &"swim",
	MODE.LEDGE_CLIMBING: &"ledge_climb",
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
var dynamic_support := false
var handoff_support := false
var handoff_velocity := Vector3.ZERO
var solves := 0
var committed_tick := -1
var modifier_generation := 0
var _local_audio: MovementAudio
var _modifier_bits := -1
var _modifier_speed := 1.0
var _committed_clearance := false
var _chart_root: Node
var _fixed := false
var _teleported := false
var _legacy_ledge := false


func _init(actor: CogitoPlayerAdvanced, tuning: CogitoMovementProfile) -> void:
	profile = tuning
	room = Collision.new(actor, -1, true)
	_chart_root = actor.state_chart.get_node("Root")
	if actor.is_local_presentation:
		_local_audio = MovementAudio.new(actor)


func _clock(actor: CogitoPlayerAdvanced, fixed: bool) -> void:
	_chart_root.process_mode = Node.PROCESS_MODE_DISABLED if fixed else Node.PROCESS_MODE_INHERIT
	if _fixed == fixed:
		return
	_fixed = fixed
	if not fixed:
		actor._motion.ladder_contact = 0
	actor.jump_timer.paused = fixed
	actor.sliding_timer.paused = fixed
	var stamina := actor.stamina_attribute as CogitoStaminaAttribute
	if stamina:
		stamina.set_process(not fixed)
		stamina.regen_timer.paused = fixed


func invalidate() -> void:
	if _local_audio:
		_local_audio.reset()
	committed_tick = -1
	dynamic_support = false
	handoff_support = false
	handoff_velocity = Vector3.ZERO
	_teleported = true
	contacts = null
	pending_force = Vector3.ZERO
	force_requested = false


## A new life can reuse the same CharacterBody, timers and stamina component.
func respawn(actor: CogitoPlayerAdvanced) -> void:
	invalidate()
	_modifier_bits = -1
	modifier_generation = 0
	actor.sliding_timer.stop()
	actor.jump_timer.stop()
	actor.on_ladder = false
	actor.ladder_direction = Vector3.ZERO
	actor.ladder_on_cooldown = false
	actor._motion.ladder_contact = 0
	actor._motion.ladder_ticks = 0
	actor._motion.submerged = false
	actor._motion.swim_depth = 0.0
	actor.was_in_swimming_state = false
	actor.was_in_crouching_state_before_swim = false
	actor.state_chart.set_expression_property("on_ladder", false)
	actor.slide_vector = Vector2.ZERO
	actor.was_sliding = false
	actor.jumped_from_slide = false
	actor.jumped_from_crouch = false
	actor.was_in_air = false
	actor.is_in_air = false
	actor.was_jumping = false
	actor.was_standing = false
	actor._motion.roll_ticks = 0
	actor._motion.support_key = 0
	actor._motion.support_local = Vector3.ZERO
	actor._motion.support_velocity = Vector3.ZERO
	actor._motion.ledge_key = 0
	actor._motion.ledge_target = Vector3.ZERO
	actor._motion.ledge_stage = STAGE.RISE
	actor.ledge_collider = null
	actor.ledge_position = Vector3.ZERO
	actor.is_in_ledge_climbing_final_stage = false
	actor.is_in_ledge_climbing_middle_stage = false
	_legacy_ledge = false
	actor.is_roll_animation_finished = false
	actor.reset_roll_presentation()
	actor.was_sprinting = false
	actor.is_sprinting_in_airborne = false
	actor.jump_target_speed = 0
	actor.bunny_hop_speed = profile.sprinting_speed
	actor.main_velocity = Vector3.ZERO
	actor.direction = Vector3.ZERO
	actor.input_direction = Vector2.ZERO
	actor._motion.requested_velocity = Vector3.ZERO
	actor.current_speed = profile.walking_speed
	actor.current_lerp_speed = profile.lerp_speed
	actor.head_offset = Vector3.ZERO
	actor.head.position.y = 0
	actor.standing_collision_shape.disabled = false
	actor.crouching_collision_shape.disabled = true
	actor.crouch_shapecast.enabled = false
	var stamina := actor.stamina_attribute as CogitoStaminaAttribute
	if stamina:
		stamina.regen_timer.stop()
		stamina.is_regenerating = false
		stamina.last_y = actor.global_position.y


## Preserve the authored capture if a chart tick enters climb during a dynamic solve.
func chart_ledge(actor: CogitoPlayerAdvanced) -> void:
	var body := actor.ledge_collider as PhysicsBody3D
	_legacy_ledge = room._moving_ledge(body)
	var motion := room._support_motion(body)
	var local := actor.transform * actor.global_transform.affine_inverse()
	actor._motion.ledge_target = local * actor.ledge_position
	var capture := Collision.Contact.new()
	capture.attach(motion, actor.ledge_position, 1.0 / Engine.physics_ticks_per_second)
	actor._motion.support_key = capture.support_key
	actor._motion.support_local = capture.support_local
	actor._motion.support_velocity = capture.support_velocity
	actor._motion.ledge_key = String(actor.get_parent().get_path_to(body)).hash() if body else 0
	actor._motion.ledge_stage = STAGE.RISE
	if actor.is_in_ledge_climbing_final_stage:
		actor._motion.ledge_stage = STAGE.FINAL
	elif actor.is_in_ledge_climbing_middle_stage:
		actor._motion.ledge_stage = STAGE.MIDDLE


func mode_eye(actor: CogitoPlayerAdvanced, active: bool) -> void:
	var parent := actor.head if active else actor._aim
	var pic := actor.player_interaction_component
	for marker: Node3D in [
		pic.interaction_raycast, pic.carryable_position, actor.item_drop_shapecast
	]:
		if marker.get_parent() != parent:
			marker.reparent(parent, false)


func unbind(actor: CogitoPlayerAdvanced) -> void:
	invalidate()
	_clock(actor, false)
	if room:
		room.close()
		room = null


func supports_volumes(actor: CogitoPlayerAdvanced) -> bool:
	return (
		not actor.is_sitting
		and not actor.currently_tweening
		and actor.gravity_vector == Vector3.DOWN
		and not (_legacy_ledge and actor.current_moving_state == MODE.LEDGE_CLIMBING)
		and (
			actor.current_moving_state
			in [
				MODE.IDLE,
				MODE.WALKING,
				MODE.SPRINTING,
				MODE.SNEAKING,
				MODE.SLIDING,
				MODE.JUMPING,
				MODE.AIR_CONTROL,
				MODE.LADDER_CLIMBING,
				MODE.ROLLING,
				MODE.LEDGE_CLIMBING,
				MODE.SWIMMING
			]
		)
	)


## True only for a committed static solve still in a supported mode at publication.
func owns_checkpoint(actor: CogitoPlayerAdvanced, server_tick: int) -> bool:
	return (
		committed_tick == server_tick
		and contacts != null
		and not actor.is_dead
		and supports_volumes(actor)
	)


## Sample at the post-simulation boundary, including ticks between pose publications.
func observe_modifiers(actor: CogitoPlayerAdvanced) -> void:
	var jump := not actor.actor_elements or actor.actor_elements.can_jump()
	var bits := int(jump) | (int(actor.is_movement_locked_by_elements()) << 1)
	bits |= int(actor.network_input_blocked) << 2
	var speed := actor.get_element_speed_multiplier()
	if bits != _modifier_bits or speed != _modifier_speed:
		modifier_generation += 1
		_modifier_bits = bits
		_modifier_speed = speed


func capture_checkpoint(actor: CogitoPlayerAdvanced, block: NetOwnerState) -> void:
	block.state = actor.capture_movement_state()
	block.modifier_generation = modifier_generation
	# The authored ShapeCast can still describe the previous physics frame.
	block.state.cast_blocked = _committed_clearance
	block.pending_force = pending_force
	block.force_requested = force_requested
	block.teleported = _teleported
	block.input_blocked = actor.network_input_blocked
	var stamina := actor.stamina_attribute as CogitoStaminaAttribute
	if stamina:
		block.stamina_locked = stamina.is_locked
		block.use_floor_slope_for_run_exhaustion = stamina.use_floor_slope_for_run_exhaustion
		block.value_max = stamina.value_max
		block.stamina_regen_speed = stamina.stamina_regen_speed
		block.run_exhaustion_speed = stamina.run_exhaustion_speed
		block.uphill_run_exhaustion_max_speed = stamina.uphill_run_exhaustion_max_speed
		block.downhill_run_exhaustion_max_speed = stamina.downhill_run_exhaustion_max_speed
		block.step_slope_multiplier = stamina.step_slope_multiplier
		block.regenerate_after = stamina.regenerate_after
		block.jump_cost = profile.jump_cost


func advance(actor: CogitoPlayerAdvanced, dt: float) -> void:
	dynamic_support = false
	handoff_support = false
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
	if actor.current_moving_state != MODE.LEDGE_CLIMBING:
		_legacy_ledge = false
	elif _legacy_ledge and is_instance_valid(actor.ledge_collider):
		if not room._moving_ledge(actor.ledge_collider as PhysicsBody3D):
			chart_ledge(actor)
	if _teleported and actor.current_moving_state in [MODE.LEDGE_CLIMBING, MODE.ROLLING]:
		actor.state_chart.send_event(
			"idle" if actor.current_moving_state == MODE.LEDGE_CLIMBING else "grounded"
		)
		_legacy_ledge = false
	if not supports_volumes(actor):
		_clock(actor, false)
		return
	if not room:
		room = Collision.new(actor, -1, true)
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
			dynamic_support = support.dynamic_floor
			_clock(actor, false)
			return
		if _teleported:
			actor._motion.ladder_contact = 0
			contacts = support
			_teleported = false
	var s := actor.capture_movement_state()
	if not room.prepare_support(s):
		_clock(actor, false)
		contacts = null
		return
	s.cast_blocked = (s.cast_enabled or not s.standing_shape) and room.blocked(origin)
	var tick := Tick.new()
	var volume := room.volumes(origin, s, actor.current_command)
	if solves == 0:
		# At spawn the chart samples its authored head cast before its first
		# posture update. Subsequent commands start from the committed head.
		volume.submerged = actor.is_head_in_water()
	tick.request(s, profile, actor.current_command, dt, volume)
	if volume.moving_ledge and s.mode == MODE.LEDGE_CLIMBING:
		_legacy_ledge = true
		_clock(actor, false)
		contacts = null
		if tick.entered_ledge:
			actor.bunny_hop_speed = s.bunny_hop_speed
			actor.ledge_position = volume.ledge.target
			actor.ledge_collider = volume.ledge.collider
			actor.state_chart.send_event("ledge_climb")
		return
	var hit := room.solve(origin, s, profile, dt)
	if hit.legacy:
		dynamic_support = hit.dynamic_floor
		if s.support_key:
			handoff_support = true
			handoff_velocity = s.support_velocity
			actor.global_position += hit.carried
		if actor.current_moving_state == MODE.LEDGE_CLIMBING:
			_legacy_ledge = true
		_clock(actor, false)
		return
	_clock(actor, true)
	var parent := actor.get_parent_node_3d()
	var room_from_world := Transform3D.IDENTITY
	if parent and not actor.top_level:
		room_from_world = parent.global_transform.affine_inverse()
	tick.finish(s, profile, actor.current_command, hit, dt, room_from_world)
	committed_tick = Engine.get_physics_frames()
	_committed_clearance = s.cast_blocked
	contacts = hit
	solves += 1
	actor.authority_solve_count += 1
	actor.transform = s.transform
	actor.ladder_direction = volume.outward
	if volume.ledge:
		actor.ledge_collider = volume.ledge.collider
	_publish(actor, s, tick)
	_effects(actor, tick, dt)


func _timer(timer: Timer, remaining: float, duration: float) -> void:
	if remaining <= 0:
		timer.stop()
	else:
		timer.start(remaining)
		timer.wait_time = duration


func _publish(actor: CogitoPlayerAdvanced, s: CogitoMovementState, tick: Tick) -> void:
	# Enter/exit volume chart states before publishing their integrated values.
	# Their authored entry callbacks initialize velocity and posture for offline play.
	var volume_mode := s.mode in [MODE.LADDER_CLIMBING, MODE.SWIMMING]
	if tick.exited_ledge:
		actor.state_chart.send_event("idle")
	if tick.entered_ledge:
		if tick.jump:
			actor.state_chart.send_event("jump")
		actor.state_chart.send_event("ledge_climb")
	if tick.entered_ladder and s.mode != MODE.LADDER_CLIMBING:
		actor.state_chart.set_expression_property("on_ladder", true)
		actor.state_chart.send_event("climb_ladder")
	actor.state_chart.set_expression_property("on_ladder", s.on_ladder)
	if tick.left_volume_on_floor:
		actor.state_chart.send_event("grounded")
	elif volume_mode and s.mode != int(actor.current_moving_state):
		actor.state_chart.send_event(EVENTS[s.mode])
	elif actor.current_moving_state in [MODE.LADDER_CLIMBING, MODE.SWIMMING] and not volume_mode:
		actor.state_chart.send_event("jump" if s.mode == MODE.JUMPING else "airborne")
	actor.on_ladder = s.on_ladder
	actor.ladder_on_cooldown = s.ladder_ticks > 0
	actor._motion.ledge_stage = s.ledge_stage
	actor._motion.ledge_key = s.ledge_key
	actor._motion.ledge_target = s.ledge_target
	actor.is_in_ledge_climbing_middle_stage = s.ledge_stage != STAGE.RISE
	actor.is_in_ledge_climbing_final_stage = s.ledge_stage == STAGE.FINAL
	if s.mode == MODE.LEDGE_CLIMBING:
		actor.ledge_position = (
			actor.global_transform * (s.transform.affine_inverse() * s.ledge_target)
		)
	else:
		actor.ledge_collider = null
	actor._motion.roll_ticks = s.roll_ticks
	actor._motion.ladder_ticks = s.ladder_ticks
	actor._motion.ladder_contact = s.ladder_contact
	actor._motion.submerged = s.submerged
	actor._motion.swim_depth = s.swim_depth
	actor.was_in_swimming_state = s.was_swimming
	actor.was_in_crouching_state_before_swim = s.crouched_before_swim
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
	if tick.finished_roll:
		actor.state_chart.send_event(CogitoMovementStep.Roll.exit_event(s.was_standing))
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
	actor.standing_collision_shape.disabled = not s.standing_shape
	actor.crouching_collision_shape.disabled = not s.crouching_shape
	if _step_eye(s.mode, tick):
		actor.eyes.position.y = s.eye_position.y
	actor.head.position = s.head_position
	actor.swimming_head_shapecast.global_position = actor.head.global_position


func _step_eye(mode: int, tick: Tick) -> bool:
	return (
		mode in [MODE.LADDER_CLIMBING, MODE.SWIMMING, MODE.LEDGE_CLIMBING, MODE.ROLLING]
		or tick.finished_roll
		or tick.exited_ledge
	)


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
	if _local_audio:
		_local_audio.observe_volumes(
			Snapshot.capture(actor, committed_tick, 0), actor.is_head_in_water()
		)
	if not _step_eye(actor.current_moving_state, tick):
		actor._handle_eyes_position_in_water(dt)
	var stamina := actor.stamina_attribute as CogitoStaminaAttribute
	if stamina and not actor.is_dead:
		stamina.advance_movement_tick(dt)

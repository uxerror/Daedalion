extends RefCounted
## Resume from one end-of-physics sample. Later ticks supply only the live command
## and collision observations. The two intervals have a static floor or unobstructed air.

const Step := preload("res://addons/cogito/CogitoObjects/cogito_movement_step.gd")
const ACTION := CogitoPlayerCommand.Action
const DT := 1.0 / 60.0

var state: CogitoMovementState
var profile: CogitoMovementProfile


func observe(lane: String, tick: int, actor: CogitoPlayerAdvanced) -> bool:
	var first := 28 if lane == "high_jump" else 65
	var last := 92 if lane == "high_jump" else 74
	if tick < first or tick > last:
		return true
	if tick == first:
		profile = actor.capture_movement_profile()
		var checkpoint := actor.capture_movement_state()
		var bytes := var_to_bytes(_fields(checkpoint))
		var decoded: Dictionary = bytes_to_var(bytes)
		state = CogitoMovementState.new()
		for field: StringName in decoded:
			state.set(field, decoded[field])
		return var_to_bytes(_fields(state)) == bytes

	var cmd := actor.current_command
	state.current_speed = clampf(state.current_speed, profile.min_speed, profile.max_speed)
	Step.request_motion(state, cmd.has_control, DT, state)
	# In these two intervals the solve preserves the requested velocity.
	state.velocity = state.requested_velocity
	state.main_velocity = Step.with_gravity(state.main_velocity, state.gravity_vec)
	if state.mode == CogitoMovementState.Mode.JUMPING:
		Step.finish_air(
			state,
			actor.is_on_ceiling(),
			cmd.is_held(ACTION.SPRINT),
			profile.sprinting_speed,
			DT,
			state
		)
		state.direction = Step.air_heading(state.direction, state.body_basis, cmd.move)
		state.current_speed = Step.Ground.speed(state.mode, state, profile, DT)
	elif state.mode == CogitoMovementState.Mode.SLIDING:
		state.slide_remaining -= DT
		state.direction = Step.heading(state.body_basis, state.slide_vector)
		state.current_speed = Step.Slide.speed(
			state.slide_remaining, profile.slide_duration, profile.sliding_speed
		)
		state.head_position.y = Step.Posture.head_height(
			state.head_position.y, true, profile.crouching_depth, DT, profile.lerp_speed
		)
	else:
		return false
	var actual := actor.capture_movement_state()
	for field: StringName in [
		&"main_velocity",
		&"velocity",
		&"requested_velocity",
		&"last_velocity",
		&"gravity_vec",
		&"direction",
		&"current_speed",
		&"bunny_hop_speed",
		&"is_sprinting_in_airborne",
		&"mode",
		&"slide_remaining",
		&"head_position",
	]:
		if var_to_bytes(state.get(field)) != var_to_bytes(actual.get(field)):
			printerr(
				lane, " tick ", tick, " ", field, ": ", state.get(field), " / ", actual.get(field)
			)
			return false
	return true


func _fields(record: CogitoMovementState) -> Dictionary:
	var values := {}
	for prop: Dictionary in record.get_property_list():
		if prop.usage & PROPERTY_USAGE_STORAGE and prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			values[prop.name] = record.get(prop.name)
	return values

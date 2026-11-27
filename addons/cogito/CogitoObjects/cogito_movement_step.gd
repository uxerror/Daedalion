class_name CogitoMovementStep
extends RefCounted
## Fixed-delta phases. Inputs are values observed at the corresponding chart callback.
## Keep the requested solver velocity across stair queries. A successful stair can
## damp the momentum carried into the following tick without changing that request.

enum Landing { NONE, LAND, HARD }


## Fill only the three motion outputs. Input and output may be the same scratch record.
static func request_motion(
	state: CogitoMovementState, control: bool, dt: float, out_state: CogitoMovementState
) -> void:
	var result := state.main_velocity
	var speed := state.current_speed * state.speed_multiplier
	var weight := dt * state.current_lerp_speed
	if state.direction and control:
		result.x = lerpf(result.x, state.direction.x * speed, weight)
		result.z = lerpf(result.z, state.direction.z * speed, weight)
	else:
		result.x = lerpf(result.x, 0.0, weight)
		result.z = lerpf(result.z, 0.0, weight)
	out_state.main_velocity = result
	out_state.last_velocity = result
	out_state.requested_velocity = with_gravity(result, state.gravity_vec)


static func with_gravity(momentum: Vector3, accumulator: Vector3) -> Vector3:
	return momentum + accumulator


static func gravity_delta(axis: Vector3, magnitude: float, dt: float) -> Vector3:
	return axis * magnitude * dt


## Post-solve air phase. Floor transitions, slide audio and water checks belong to the adapter.
static func finish_air(
	state: CogitoMovementState,
	ceiling: bool,
	sprint: bool,
	sprint_speed: float,
	dt: float,
	out_state: CogitoMovementState
) -> void:
	var momentum := state.main_velocity
	if ceiling:
		momentum.y = 0
	out_state.main_velocity = momentum
	out_state.gravity_vec = gravity_delta(state.gravity_vector, state.gravity, dt)
	var air_sprint := state.was_sprinting and sprint
	out_state.was_sprinting = air_sprint
	out_state.is_sprinting_in_airborne = air_sprint
	out_state.bunny_hop_speed = state.bunny_hop_speed if air_sprint else sprint_speed


static func air_heading(previous: Vector3, body_basis: Basis, axes: Vector2) -> Vector3:
	return heading(body_basis, axes) if axes != Vector2.ZERO else previous


static func heading(body_basis: Basis, axes: Vector2) -> Vector3:
	return (body_basis * Vector3(axes.x, 0, axes.y)).normalized()


static func approach(value: float, target: float, dt: float, rate: float) -> float:
	return lerpf(value, target, dt * rate)


static func landing(vertical_speed: float, roll_limit: float, landing_limit: float) -> Landing:
	if vertical_speed <= roll_limit:
		return Landing.HARD
	if vertical_speed <= landing_limit:
		return Landing.LAND
	return Landing.NONE


class Ground:
	static func speed(
		mode: CogitoMovementState.Mode,
		state: CogitoMovementState,
		profile: CogitoMovementProfile,
		dt: float
	) -> float:
		var target := profile.walking_speed
		match mode:
			CogitoMovementState.Mode.SPRINTING:
				target = state.bunny_hop_speed if profile.can_bunnyhop else profile.sprinting_speed
			CogitoMovementState.Mode.SNEAKING:
				target = profile.crouching_speed
			CogitoMovementState.Mode.JUMPING:
				target = state.jump_target_speed
		return CogitoMovementStep.approach(state.current_speed, target, dt, profile.lerp_speed)

	## The two scalar results retain float64 precision, even when out_state aliases state.
	static func sprint_takeoff(
		state: CogitoMovementState,
		profile: CogitoMovementProfile,
		dt: float,
		out_state: CogitoMovementState
	) -> void:
		var takeoff_speed := state.current_speed
		var hop := state.bunny_hop_speed
		if takeoff_speed < hop - 0.2:
			takeoff_speed = CogitoMovementStep.approach(takeoff_speed, hop, dt, profile.lerp_speed)
		elif profile.can_bunnyhop:
			hop = clampf(
				hop + profile.bunny_hop_acceleration, profile.sprinting_speed, profile.max_speed
			)
			takeoff_speed = hop
		else:
			takeoff_speed = profile.sprinting_speed
		out_state.bunny_hop_speed = hop
		out_state.current_speed = takeoff_speed


class Jump:
	enum Eligibility { READY, BLOCKED, EXHAUSTED }

	static func eligibility(
		sitting: bool, permitted: bool, affordable: bool, crouched: bool, crouch_jump: bool
	) -> Eligibility:
		if sitting or not permitted:
			return Eligibility.BLOCKED
		if not affordable:
			return Eligibility.EXHAUSTED
		return Eligibility.READY if not crouched or crouch_jump else Eligibility.BLOCKED

	static func velocity(crouched: bool, standing_speed: float, crouching_speed: float) -> float:
		return crouching_speed if crouched else standing_speed

	static func slide_velocity(standing_speed: float, multiplier: float) -> float:
		return standing_speed * multiplier

	static func hits_wall(direction: Vector3, normal: Vector3, limit_degrees: int) -> bool:
		return rad_to_deg(direction.angle_to(normal)) > limit_degrees


class Slide:
	enum Action { IDLE, WALK, SNEAK, CONTINUE }

	## A chart resume keeps both direction and Timer phase.
	static func enter(
		state: CogitoMovementState, axes: Vector2, duration: float, out_state: CogitoMovementState
	) -> void:
		out_state.slide_vector = state.slide_vector if state.was_sliding else axes
		out_state.slide_remaining = state.slide_remaining if state.was_sliding else duration
		out_state.was_sliding = false

	static func action(axes: Vector2, sprint: bool, stopped: bool, standing: bool) -> Action:
		if axes == Vector2.ZERO:
			return Action.IDLE
		if not sprint or stopped:
			return Action.WALK if standing else Action.SNEAK
		return Action.CONTINUE

	static func from_jump(
		jumping: bool,
		from_slide: bool,
		sprint: bool,
		air_sprint: bool,
		crouching: bool,
		from_crouch: bool
	) -> bool:
		return (
			jumping and not from_slide and sprint and air_sprint and crouching and not from_crouch
		)

	static func speed(remaining: float, duration: float, sliding_speed: float) -> float:
		return (remaining / duration + 0.5) * sliding_speed


class Posture:
	static func latch(previous: bool, toggle: bool, crouch_held: bool, pressed := false) -> bool:
		if toggle:
			return not previous if pressed else previous
		return crouch_held

	static func crouch_requested(latched: bool, clearance_blocked: bool) -> bool:
		return latched or clearance_blocked

	static func head_height(
		height: float, crouched: bool, depth: float, dt: float, rate: float
	) -> float:
		return CogitoMovementStep.approach(height, depth if crouched else 0.0, dt, rate)

	static func tall_shape_ready(height: float, crouching_depth: float) -> bool:
		return height > crouching_depth / 4


class Stairs:
	static func search_height(
		air: bool, air_steps: bool, ground: Vector3, airborne: Vector3
	) -> Vector3:
		return airborne if air and air_steps else ground

	static func candidate(height: Vector3, index: int, count: int) -> Vector3:
		return height - index * (height / count)

	static func along_wall(velocity: Vector3, dt: float, normal: Vector3) -> Vector3:
		return (velocity * dt).slide(normal)

	## Each sweep returns its own normal and either remainder (up) or travel (down).
	## NAN rejects the candidate and lets the adapter continue its ordered search.
	static func rise(normal: Vector3, remainder: Vector3, max_slope: float) -> float:
		if normal.angle_to(Vector3.UP) <= deg_to_rad(max_slope):
			return -remainder.y
		return NAN

	static func descent(normal: Vector3, travel: Vector3, margin: float, max_slope: float) -> float:
		if travel.y < -margin and normal.angle_to(Vector3.UP) <= deg_to_rad(max_slope):
			return travel.y
		return NAN

	static func damp_momentum(
		step_up: bool, air_steps: bool, airborne: bool, direction: Vector3, normal: Vector3
	) -> bool:
		return step_up and air_steps and (airborne or direction.dot(normal) > 0)


class Stamina:
	enum Sprint { ACTIVE, LOW, EMPTY }

	static func can_start_sprint(on_ladder: bool, held: bool, present: bool, value: float) -> bool:
		return not on_ladder and held and present and value > 5

	static func sprint(present: bool, value: float) -> Sprint:
		if present and not (value > 0):
			return Sprint.EMPTY
		if present and value <= 0.2:
			return Sprint.LOW
		return Sprint.ACTIVE

	static func jump_affordable(present: bool, value: float, cost: float) -> bool:
		return not present or value >= cost

	static func spends_on_run(speed: float, walk_speed: float, velocity: Vector3) -> bool:
		return speed > walk_speed and velocity.length() > 0.1

	static func run_rate(
		floor_normal: Vector3,
		momentum: Vector3,
		height: float,
		previous_y: float,
		step_multiplier: float,
		base: float,
		uphill: float,
		downhill: float
	) -> float:
		var slope := momentum.normalized().dot(floor_normal)
		if is_equal_approx(slope, 0.0):
			if is_equal_approx(height, previous_y):
				return base
			slope = clampf((previous_y - height) * step_multiplier, -1.0, 1.0)
		if slope < 0.0001:
			return lerpf(base, uphill, absf(slope))
		return lerpf(base, downhill, slope)

	static func amount(rate: float, dt: float) -> float:
		return rate * dt

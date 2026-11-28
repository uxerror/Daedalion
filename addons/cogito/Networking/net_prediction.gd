extends RefCounted
## Owner-local command clock. RPC arrival only replaces queued; replay writes value states.

signal measurement_event(kind: String, detail: String, sequence: int, collider_id: int)

const Solver := preload("net_prediction_step.gd")
const Channel := preload("net_command_channel.gd")
const Audio := preload("net_movement_audio.gd")
const CAPACITY := 128
const REPLAY_BUDGET := 24
const HALF_LIFE := 0.05
const OFFSET_CAP := 0.25
const SNAP_DISTANCE := 1.0
const EXACT_STATE_FIELDS := (
	NetOwnerState.FLAGS
	+ [
		"mode",
		"posture",
		"ladder_contact",
		"ladder_ticks",
		"roll_ticks",
		"ledge_stage",
		"ledge_key",
		"support_key",
	]
)
# Both operands here are already decoded at wire precision. Configuration changes
# and input discontinuities are server events, independent of the predicted pose.
const CHECKPOINT_FIELDS := (
	[
		"generation",
		"modifier_generation",
		"discontinuities",
		"disposition",
		"stamina_locked",
		"input_blocked",
		"use_floor_slope_for_run_exhaustion",
		"pending_force",
	]
	+ NetOwnerState.STAMINA_TUNING
)
const MOTION_EYE_MODES := [
	Solver.MODE.LADDER_CLIMBING,
	Solver.MODE.SWIMMING,
	Solver.MODE.LEDGE_CLIMBING,
	Solver.MODE.ROLLING,
]
const ANGLES := ["body_yaw", "neck_yaw", "head_pitch"]
const ANGLE_EPSILON := 0.001
const LENGTH_EPSILON := 0.01
const SPEED_EPSILON := 0.10
const FIELD_EPSILONS := {
	"velocity": SPEED_EPSILON,
	"main_velocity": SPEED_EPSILON,
	"last_velocity": SPEED_EPSILON,
	"requested_velocity": SPEED_EPSILON,
	"support_velocity": SPEED_EPSILON,
	"gravity_vec": SPEED_EPSILON,
	"current_speed": SPEED_EPSILON,
	"jump_target_speed": SPEED_EPSILON,
	"bunny_hop_speed": SPEED_EPSILON,
	"head_position": LENGTH_EPSILON,
	"previous_y": LENGTH_EPSILON,
	"head_offset": LENGTH_EPSILON,
	"support_local": LENGTH_EPSILON,
	"ledge_target": LENGTH_EPSILON,
	"direction": ANGLE_EPSILON,
	"floor_normal": ANGLE_EPSILON,
	"wall_normal": ANGLE_EPSILON,
	"gravity_vector": ANGLE_EPSILON,
	"body_basis": ANGLE_EPSILON,
	"input_direction": 0.001,
	"slide_vector": 0.001,
	"speed_multiplier": 0.001,
	"gravity": 0.1,
	"current_lerp_speed": 0.001,
	"stamina": 0.000001,
}

var minimum_revision := 0
var in_transfer := false
var active := false
var following_authority := false
var queued: NetOwnerState
var baseline: NetOwnerState
var state: CogitoMovementState
var solver: Solver
var newest := -1
var last_replay: Array[int] = []
var last_restore_tick := -1
var support_changed := false
var presented_support_key := 0
var presented_support_pose := Transform3D.IDENTITY
var hard_resets := 0
## Optional timing for the process measurement fixture, in microseconds per owner tick.
var measure_replay := false
var measured_resets := 0
var measured_resumes := 0
var measured_reasons := {}
var restore_samples := {}
var replay_step_times := PackedInt64Array()
var replay_usec := 0
var replay_steps := -1
var corrections := 0
var last_position_error := 0.0
var compared_post := false
var reasons := {}
var render_offset := Vector3.ZERO
var reason := ""
var _commands: Array[CogitoPlayerCommand] = []
var _posts: Array[CogitoMovementState] = []
var _post_valid := PackedByteArray()
var _working := CogitoMovementState.new()
var _wire := PackedByteArray()
var _sample_pool: Array[CogitoPlayerCommand] = [
	CogitoPlayerCommand.new(), CogitoPlayerCommand.new()
]
var _floor_sequence := -1
var _last_valid_ack := -1
var _boundary_sequence := -1
var _rig: Node3D
var _rig_rest: Vector3
var _rig_offset := Vector3.ZERO
var _actor: CogitoPlayerAdvanced
var _audio: Audio
var _camera_clearance := PhysicsShapeQueryParameters3D.new()
var _queries: Array[Node3D] = []
var _simulation_eye := Node3D.new()
var _eye_staged := false
var _debug := OS.get_environment("COGITO_PREDICTION_DEBUG") == "1"


func _init(actor: CogitoPlayerAdvanced, p: CogitoMovementProfile, mask: int, audio: Audio) -> void:
	_actor = actor
	_rig = actor.get_node("Rig")
	_rig_rest = _rig.position
	_audio = audio
	actor.head.add_child(_simulation_eye)
	solver = Solver.new(actor, p, mask)
	var sphere := SphereShape3D.new()
	sphere.radius = maxf(0.03, actor.camera.near * 2)
	_camera_clearance.shape = sphere
	_camera_clearance.collision_mask = mask
	var pic := actor.player_interaction_component
	_queries.assign([pic.interaction_raycast, pic.carryable_position, actor.item_drop_shapecast])
	_commands.resize(CAPACITY)
	_posts.resize(CAPACITY)
	_post_valid.resize(CAPACITY)
	for slot in CAPACITY:
		_commands[slot] = CogitoPlayerCommand.new()
		_posts[slot] = CogitoMovementState.new()
	reset()


## A sampler or custom gameplay consumer can retain a command beyond its physics tick.
func sample_command(sequence: int) -> CogitoPlayerCommand:
	for cmd in _sample_pool:
		# The pool and this loop variable own the two references.
		if cmd.get_reference_count() == 2:
			cmd.sequence = sequence
			cmd.move = Vector2.ZERO
			cmd.held = 0
			cmd.edges = PackedByteArray()
			cmd.has_control = true
			cmd.wield_generation = 0
			return cmd
	var fresh := CogitoPlayerCommand.new()
	fresh.sequence = sequence
	return fresh


func reset(crossing := false) -> void:
	minimum_revision = 0
	if active or following_authority:
		_hard_reset("scope")
	following_authority = false
	_suspend("")
	queued = null
	baseline = null
	for command in _commands:
		command.sequence = -1
	_post_valid.fill(0)
	newest = _actor.last_consumed_sequence
	_floor_sequence = newest
	_last_valid_ack = -1
	_boundary_sequence = newest if crossing else -1
	last_replay.clear()
	last_restore_tick = -1
	last_position_error = 0
	corrections = 0
	support_changed = false
	reasons.clear()


func close() -> void:
	# The actor is retiring. Its gameplay markers leave with their current parents,
	# including when the room has already taken the camera out of the tree.
	active = false
	render_offset = Vector3.ZERO
	_audio.reset()
	reset()
	solver.close()


func _present_predicted(enabled: bool) -> void:
	if active != enabled:
		active = enabled
		for node in _queries:
			node.reparent(_simulation_eye if enabled else _actor.camera, false)
		var socket := _actor.player_interaction_component.wieldable_container
		socket.reparent(_actor.camera if enabled else _actor.head, false)
		_audio.reset()


func _suspend(why: String, collider_id := 0, seq := -1) -> void:
	if measure_replay and why and (why != reason or active):
		measurement_event.emit(
			"suspend" if active else "wait", why, newest if seq < 0 else seq, collider_id
		)
		if active:
			measured_reasons[why] = int(measured_reasons.get(why, 0)) + 1
	presented_support_key = 0
	presented_support_pose = Transform3D.IDENTITY
	_eye_staged = false
	_simulation_eye.transform = Transform3D.IDENTITY
	if active:
		following_authority = why != "" and why != "travel"
		if following_authority:
			# Keep the current rendered eye (including any integrated swim height)
			# while PR2 starts following the published root and head.
			render_offset = _actor.head.global_basis * _actor.eyes.position
		_actor.reset_roll_presentation()
	if not following_authority:
		_clear_offsets()
	_post_valid.fill(0)
	_present_predicted(false)
	state = null
	if why and reason != why:
		reasons[why] = int(reasons.get(why, 0)) + 1
		if _debug:
			print("PR3 suspend ", why, " sequence=", newest)
	reason = why


func transfer(loading: bool, revision := 0) -> void:
	if loading == in_transfer:
		return
	in_transfer = loading
	queued = null
	if loading:
		if active or following_authority:
			_hard_reset("travel")
		following_authority = false
		_suspend("travel")
	else:
		# Commands sampled during loading belong to the retired source interval.
		reset()
		minimum_revision = revision
		_boundary_sequence = newest


func post_at(sequence: int) -> CogitoMovementState:
	var slot := posmod(sequence, CAPACITY)
	var command := _commands[slot]
	return _posts[slot] if _post_valid[slot] and command.sequence == sequence else null


func _problem(block: NetOwnerState, first: int) -> String:
	var problem := ""
	if not block.state:
		problem = "dynamic_support" if block.dynamic_support else "fallback"
	elif block.rate != Engine.physics_ticks_per_second:
		problem = "physics_rate"
	elif block.ack > newest or block.ack < _last_valid_ack:
		problem = "impossible_ack"
	elif block.force_requested or block.teleported or block.state.mode not in Solver.SUPPORTED:
		problem = "unsupported_mode"
	elif block.ack < _boundary_sequence:
		problem = "awaiting_boundary_ack"
	elif newest - first + 1 > CAPACITY:
		problem = "missing_history"
	elif newest - first + 1 > REPLAY_BUDGET:
		problem = "replay_budget"
	else:
		for seq in range(first, newest + 1):
			var cmd := _commands[posmod(seq, CAPACITY)]
			if not cmd or cmd.sequence != seq:
				problem = "missing_history"
				break
	return problem


func _miss(key: String, magnitude := 0.0) -> bool:
	if measure_replay:
		if not restore_samples.has(key):
			restore_samples[key] = []
		restore_samples[key].append(magnitude)
	return false


func _difference(a: Variant, b: Variant) -> float:
	match typeof(a):
		TYPE_FLOAT:
			return absf(a - b)
		TYPE_VECTOR2, TYPE_VECTOR3:
			return a.distance_to(b)
		TYPE_BASIS:
			# Axis chords also detect changes of scale, and work on non-unit bases.
			return maxf(a.x.distance_to(b.x), maxf(a.y.distance_to(b.y), a.z.distance_to(b.z)))
	return 0.0


func _stamina_gate(value: float, block: NetOwnerState) -> int:
	var gates := int(CogitoMovementStep.Stamina.sprint(true, value))
	gates |= int(CogitoMovementStep.Stamina.can_start_sprint(false, true, true, value)) << 2
	gates |= int(CogitoMovementStep.Stamina.jump_affordable(true, value, block.jump_cost)) << 3
	return gates | (int(value >= block.value_max) << 4)


func _matches(block: NetOwnerState, previous: NetOwnerState, post: CogitoMovementState) -> bool:
	if support_changed:
		return _miss("support_changed")
	if previous:
		for key: String in CHECKPOINT_FIELDS:
			if block.get(key) != previous.get(key):
				return _miss(key, _difference(block.get(key), previous.get(key)))
	if not post or not previous or not active:
		return _miss("seed")
	if block.disposition != NetOwnerState.Disposition.FRESH:
		return _miss("disposition")
	return _state_matches(block, post)


func _state_matches(block: NetOwnerState, post: CogitoMovementState) -> bool:
	var s := block.state
	if last_position_error > 0.02:
		return _miss("position", last_position_error)
	for key: String in EXACT_STATE_FIELDS:
		if post.get(key) != s.get(key):
			return _miss(key)
	if (
		post.stamina != s.stamina
		and _stamina_gate(post.stamina, block) != _stamina_gate(s.stamina, block)
	):
		return _miss("stamina_gate", absf(post.stamina - s.stamina))
	var basis_error := _difference(post.transform.basis, s.transform.basis)
	if basis_error > ANGLE_EPSILON:
		return _miss("basis", basis_error)
	# On the ground Advanced writes cosmetic head bob to Eyes. Only these modes
	# integrate the vertical eye offset. Head position is compared in every mode.
	var eye_error := absf(post.eye_position.y - s.eye_position.y)
	if s.mode in MOTION_EYE_MODES and eye_error > LENGTH_EPSILON:
		return _miss("eye_position", eye_error)
	return _continuous_matches(post, s, block.rate)


func _continuous_matches(post: CogitoMovementState, s: CogitoMovementState, rate: int) -> bool:
	for key: String in ANGLES:
		var difference := absf(angle_difference(post.get(key), s.get(key)))
		if difference > ANGLE_EPSILON:
			return _miss(key, difference)
	for key: String in FIELD_EPSILONS:
		var predicted: Variant = post.get(key)
		var authoritative: Variant = s.get(key)
		if predicted != authoritative:
			var distance := _difference(predicted, authoritative)
			if distance > FIELD_EPSILONS[key]:
				return _miss(key, distance)
	for key: String in NetOwnerState.TIMERS:
		var difference := absf(post.get(key) - s.get(key))
		if difference > 1.0 / rate:
			return _miss(key, difference)
	return true


## Called before Advanced samples the live input source. Keep current look on scene nodes.
func begin_tick() -> void:
	replay_usec = 0
	replay_steps = -1
	compared_post = false
	if measure_replay:
		replay_step_times.clear()
	solver.prepare()
	if not queued or in_transfer:
		return
	var block := queued
	queued = null
	var previous := baseline
	baseline = block
	if active and block.state and previous and previous.generation != block.generation:
		# A complete legacy excursion can fall between two delivered eligible poses.
		_suspend("mode_transition")
	var first := maxi(block.ack, _floor_sequence) + 1
	var problem := _problem(block, first)
	if block.ack <= newest:
		_last_valid_ack = maxi(_last_valid_ack, block.ack)
	if problem:
		_suspend(problem)
		return
	var post := post_at(block.ack)
	if not post and previous and previous.ack == block.ack:
		post = previous.state
	if active and not post and block.ack > _floor_sequence:
		_suspend("missing_history")
		return
	compared_post = active and post != null
	last_position_error = (
		post.transform.origin.distance_to(block.state.transform.origin) if active and post else 0.0
	)
	var matched := _matches(block, previous, post)
	support_changed = false
	if matched:
		_retire(block.ack)
		return
	if measure_replay and last_position_error > 0.02:
		measurement_event.emit("correction", str(last_position_error), block.ack, 0)
	var started := Time.get_ticks_usec() if measure_replay else 0
	var was_active := state != null
	var old_origin := _actor.position
	var old_eye := _actor.eyes.global_position
	state = _working
	state.copy_from(block.state)
	solver.profile.jump_cost = block.jump_cost
	last_restore_tick = block.tick
	last_replay.clear()
	for seq in range(first, newest + 1):
		var slot := posmod(seq, CAPACITY)
		var step_start := Time.get_ticks_usec() if measure_replay else 0
		if not solver.advance(state, _commands[slot], block):
			# After a failed resume, cover both the tested suffix and one more input
			# horizon. A single eligible pose can fall between two contacts with the prop.
			_boundary_sequence = seq if was_active else newest + (newest - block.ack)
			if measure_replay:
				replay_usec = Time.get_ticks_usec() - started
				replay_steps = seq - first + 1
				replay_step_times.append(Time.get_ticks_usec() - step_start)
			_suspend(solver.suspend_reason, solver.room.boundary_collider_id, seq)
			return
		_posts[slot].copy_from(state)
		_post_valid[slot] = 1
		last_replay.append(seq)
		if measure_replay:
			replay_step_times.append(Time.get_ticks_usec() - step_start)
	if measure_replay:
		replay_usec = Time.get_ticks_usec() - started
		replay_steps = last_replay.size()
	if was_active:
		corrections += 1
	if was_active or following_authority:
		_smooth_restore(old_origin, old_eye)
	_retire(block.ack)
	if following_authority and measure_replay:
		measured_resumes += 1
		measurement_event.emit("resume", reason, newest, 0)
	following_authority = false
	reason = ""
	_present_predicted(true)
	_eye_staged = true
	sync_eye()


func _hard_reset(detail: String) -> void:
	hard_resets += 1
	if measure_replay:
		measured_resets += 1
		measurement_event.emit("hard_reset", detail, newest, 0)


func fallback_snap(target: Vector3) -> bool:
	if following_authority and _actor.position.distance_to(target) > SNAP_DISTANCE:
		_clear_offsets()
		_hard_reset("fallback_distance")
		return true
	return false


func _clear_offsets() -> void:
	render_offset = Vector3.ZERO
	_rig_offset = Vector3.ZERO
	_rig.position = _rig_rest
	_actor.eyes.position = Vector3.ZERO


func _smooth_restore(old_origin: Vector3, old_eye: Vector3) -> void:
	var root_motion := solver.world_from_room.basis * (old_origin - state.transform.origin)
	var head_pose := _actor.head.transform
	head_pose.origin = state.head_position
	var target := solver.world_from_room * state.transform * _actor.body.transform
	target = target * _actor.neck.transform * head_pose
	var eye_height := state.eye_position.y if state.mode in MOTION_EYE_MODES else 0.0
	var eye_motion := old_eye - (target * (Vector3.UP * eye_height))
	if maxf(root_motion.length(), eye_motion.length()) > SNAP_DISTANCE:
		_hard_reset("distance")
		render_offset = Vector3.ZERO
		_rig_offset = Vector3.ZERO
	else:
		render_offset = eye_motion.limit_length(OFFSET_CAP)
		_rig_offset = (_rig_offset + root_motion).limit_length(OFFSET_CAP)


## Reconciliation precedes live input edges. Move only the gameplay queries in that interval.
func sync_eye() -> void:
	if _eye_staged:
		var head_pose := _actor.head.transform
		head_pose.origin = state.head_position
		var root_pose := solver.world_from_room * state.transform
		_simulation_eye.global_transform = (
			root_pose * _actor.body.transform * _actor.neck.transform * head_pose
		)


func aim_transform() -> Transform3D:
	sync_eye()
	return _simulation_eye.global_transform


func _retire(ack: int) -> void:
	for seq in range(maxi(_floor_sequence + 1, newest - CAPACITY + 1), ack + 1):
		var slot := posmod(seq, CAPACITY)
		_commands[slot].sequence = -1
		_post_valid[slot] = 0
	_floor_sequence = maxi(_floor_sequence, ack)


## The ordinary send path calls this once even if its packet policy drops the datagram.
func live(raw: CogitoPlayerCommand) -> void:
	if raw.sequence <= newest:
		return
	var contiguous := raw.sequence == newest + 1
	newest = raw.sequence
	var slot := posmod(newest, CAPACITY)
	var command := Channel.freeze(raw, _commands[slot], _wire)
	if not command:
		_commands[slot].sequence = -1
	_post_valid[slot] = 0
	if not active:
		return
	if not contiguous or not command or newest - _floor_sequence > CAPACITY:
		_suspend("missing_history")
		return
	var was_rolling := state.mode == Solver.MODE.ROLLING
	if not solver.advance(state, command, baseline):
		_boundary_sequence = newest
		_suspend(solver.suspend_reason, solver.room.boundary_collider_id)
		return
	_posts[slot].copy_from(state)
	_post_valid[slot] = 1
	_actor.transform = state.transform
	presented_support_key = state.support_key
	if presented_support_key:
		var world: Node = _actor.player_interaction_component.network_interactions.world
		presented_support_pose = world.supports[presented_support_key].world_pose(
			world.support_tick
		)
	_actor.velocity = state.velocity
	_actor.current_moving_state = state.mode as CogitoPlayerAdvanced.MovingState
	_actor.current_body_posture_state = state.posture as CogitoPlayerAdvanced.BodyPostureState
	_actor.head.position = state.head_position
	_eye_staged = false
	_simulation_eye.transform = Transform3D.IDENTITY
	_clip_offset()
	_display_offset()
	var roll_impact := (
		state.last_velocity.y if not was_rolling and state.mode == Solver.MODE.ROLLING else INF
	)
	_audio.observe_actor(newest, baseline.revision, state.submerged, roll_impact)


func _clip_offset() -> void:
	if render_offset.is_zero_approx():
		return
	var space := _actor.get_world_3d().direct_space_state
	_camera_clearance.transform = Transform3D(Basis.IDENTITY, _actor.head.global_position)
	_camera_clearance.exclude = solver.exclusions
	_camera_clearance.motion = Vector3.ZERO
	if not space.intersect_shape(_camera_clearance, 1).is_empty():
		render_offset = Vector3.ZERO
	else:
		_camera_clearance.motion = render_offset
		render_offset *= space.cast_motion(_camera_clearance)[0]


func render(delta: float) -> void:
	var decay := exp(-log(2.0) * delta / HALF_LIFE)
	render_offset *= decay
	_rig_offset *= decay
	_display_offset()


func _display_offset() -> void:
	_rig.position = _rig_rest + _actor.global_basis.inverse() * _rig_offset
	var local_offset := _actor.head.global_basis.inverse() * render_offset
	if active and state.mode in MOTION_EYE_MODES:
		local_offset.y += state.eye_position.y
	_actor.eyes.position = local_offset

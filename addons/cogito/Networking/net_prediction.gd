extends RefCounted
## Owner-local command clock. RPC arrival only replaces queued; replay writes value states.

const Solver := preload("net_prediction_step.gd")
const Channel := preload("net_command_channel.gd")
const Audio := preload("net_movement_audio.gd")
const Snapshot := preload("net_snapshot.gd")
const CAPACITY := 128
const REPLAY_BUDGET := 24
const HALF_LIFE := 0.05
const OFFSET_CAP := 0.25
const SNAP_DISTANCE := 1.0
const EXACT_STATE_FIELDS := [
	"mode",
	"posture",
	"input_direction",
	"slide_vector",
	"ladder_contact",
	"ladder_ticks",
	"body_basis",
	"requested_velocity",
	"main_velocity",
	"last_velocity",
	"direction",
	"gravity_vector",
	"gravity_vec",
	"floor_normal",
	"wall_normal",
	"head_offset",
]
const ADAPTER_FIELDS := [
	"stamina_locked", "input_blocked", "use_floor_slope_for_run_exhaustion", "pending_force"
]

var minimum_revision := 0
var in_transfer := false
var active := false
var queued: NetOwnerState
var baseline: NetOwnerState
var state: CogitoMovementState
var solver: Solver
var newest := -1
var last_replay: Array[int] = []
var last_restore_tick := -1
var corrections := 0
var last_position_error := 0.0
var reasons := {}
var render_offset := Vector3.ZERO
var reason := ""
var _commands: Array[CogitoPlayerCommand] = []
var _posts: Array[CogitoMovementState] = []
var _floor_sequence := -1
var _last_valid_ack := -1
var _boundary_sequence := -1
var _actor: CogitoPlayerAdvanced
var _audio: Audio
var _camera_clearance := PhysicsShapeQueryParameters3D.new()
var _queries: Array[Node3D] = []
var _simulation_eye := Node3D.new()
var _eye_staged := false
var _debug := OS.get_environment("COGITO_PREDICTION_DEBUG") == "1"


func _init(actor: CogitoPlayerAdvanced, p: CogitoMovementProfile, mask: int, audio: Audio) -> void:
	_actor = actor
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
	reset()


func reset(crossing := false) -> void:
	minimum_revision = 0
	_suspend("")
	queued = null
	baseline = null
	_commands.fill(null)
	_posts.fill(null)
	newest = _actor.last_consumed_sequence
	_floor_sequence = newest
	_last_valid_ack = -1
	_boundary_sequence = newest if crossing else -1
	last_replay.clear()
	last_restore_tick = -1
	last_position_error = 0
	corrections = 0
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


func _suspend(why: String) -> void:
	_eye_staged = false
	_simulation_eye.transform = Transform3D.IDENTITY
	if active:
		render_offset = Vector3.ZERO
		_actor.eyes.position = Vector3.ZERO
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
		_suspend("travel")
	else:
		# Commands sampled during loading belong to the retired source interval.
		reset()
		minimum_revision = revision
		_boundary_sequence = newest


func post_at(sequence: int) -> CogitoMovementState:
	var slot := posmod(sequence, CAPACITY)
	var command := _commands[slot]
	return _posts[slot] if command and command.sequence == sequence else null


func _problem(block: NetOwnerState, first: int) -> String:
	var problem := ""
	if not block.state:
		problem = "fallback"
	elif block.rate != Engine.physics_ticks_per_second:
		problem = "physics_rate"
	elif block.ack > newest or block.ack < _last_valid_ack:
		problem = "impossible_ack"
	elif block.force_requested or block.teleported or block.state.mode not in Solver.SUPPORTED:
		problem = "unsupported_mode"
	elif block.ack < _boundary_sequence:
		problem = "unsupported_contact"
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


func _matches(block: NetOwnerState, previous: NetOwnerState, post: CogitoMovementState) -> bool:
	if not post or not previous or not active:
		return false
	if (
		block.generation != previous.generation
		or block.modifier_generation != previous.modifier_generation
		or block.discontinuities != previous.discontinuities
		or block.disposition != previous.disposition
		or block.disposition != NetOwnerState.Disposition.FRESH
	):
		return false
	for key: String in ADAPTER_FIELDS + NetOwnerState.STAMINA_TUNING:
		if block.get(key) != previous.get(key):
			return false
	var s := block.state
	if (
		last_position_error > 0.02
		or post.velocity.distance_to(s.velocity) > 0.10
		or post.head_position.distance_to(s.head_position) > 0.01
		or post.eye_position.distance_to(s.eye_position) > 0.01
		or post.transform.basis != s.transform.basis
	):
		return false
	for key: String in (
		NetOwnerState.FLAGS + NetOwnerState.SCALARS + NetOwnerState.TIMERS + EXACT_STATE_FIELDS
	):
		if post.get(key) != s.get(key):
			return false
	return true


## Called before Advanced samples the live input source. Keep current look on scene nodes.
func begin_tick() -> void:
	solver.prepare()
	if not queued or in_transfer:
		return
	var block := queued
	queued = null
	var previous := baseline
	baseline = block
	if active and previous and previous.generation != block.generation:
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
	last_position_error = (
		post.transform.origin.distance_to(block.state.transform.origin) if post else 0.0
	)
	if _matches(block, previous, post):
		_retire(block.ack)
		return
	var old_state := state
	state = block.state.duplicate()
	solver.profile.jump_cost = block.jump_cost
	last_restore_tick = block.tick
	last_replay.clear()
	for seq in range(first, newest + 1):
		var slot := posmod(seq, CAPACITY)
		if not solver.advance(state, _commands[slot], block):
			_boundary_sequence = seq
			_suspend("unsupported_contact")
			return
		_posts[slot] = state.duplicate()
		last_replay.append(seq)
	if old_state:
		corrections += 1
		var motion := (
			solver.world_from_room.basis * (old_state.transform.origin - state.transform.origin)
		)
		motion += _actor.neck.global_basis * (old_state.head_position - state.head_position)
		render_offset = (
			(motion + render_offset).limit_length(OFFSET_CAP)
			if motion.length() <= SNAP_DISTANCE
			else Vector3.ZERO
		)
	_retire(block.ack)
	reason = ""
	_present_predicted(true)
	_eye_staged = true
	sync_eye()


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
		_commands[slot] = null
		_posts[slot] = null
	_floor_sequence = maxi(_floor_sequence, ack)


## The ordinary send path calls this once even if its packet policy drops the datagram.
func live(raw: CogitoPlayerCommand) -> void:
	if raw.sequence <= newest:
		return
	var contiguous := raw.sequence == newest + 1
	newest = raw.sequence
	var slot := posmod(newest, CAPACITY)
	var command := Channel.freeze(raw)
	_commands[slot] = command
	_posts[slot] = null
	if not active:
		return
	if not contiguous or not command or newest - _floor_sequence > CAPACITY:
		_suspend("missing_history")
		return
	if not solver.advance(state, command, baseline):
		_boundary_sequence = newest
		_suspend("unsupported_contact")
		return
	_posts[slot] = state.duplicate()
	_actor.transform = state.transform
	_actor.velocity = state.velocity
	_actor.current_moving_state = state.mode as CogitoPlayerAdvanced.MovingState
	_actor.current_body_posture_state = state.posture as CogitoPlayerAdvanced.BodyPostureState
	_actor.head.position = state.head_position
	_eye_staged = false
	_simulation_eye.transform = Transform3D.IDENTITY
	_clip_offset()
	_display_offset()
	_audio.observe(Snapshot.capture(_actor, newest, baseline.revision), true, state.submerged)


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
	render_offset *= exp(-log(2.0) * delta / HALF_LIFE)
	_display_offset()


func _display_offset() -> void:
	var local_offset := _actor.head.global_basis.inverse() * render_offset
	if state.mode in [CogitoMovementState.Mode.LADDER_CLIMBING, CogitoMovementState.Mode.SWIMMING]:
		local_offset.y += state.eye_position.y
	_actor.eyes.position = local_offset

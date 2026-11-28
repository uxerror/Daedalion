class_name NetOwnerState
extends RefCounted
## Independently decodable post-simulation checkpoint for one remote owner.

enum Disposition { FRESH, HELD, NEUTRAL, GAP }

const VERSION := 1
const HEADER_BYTES := 68
const ELIGIBLE_BYTES := 507
const ALIGNMENT := [
	"binding", "life", "revision", "generation", "tick", "ack", "last_fresh_tick", "discontinuities"
]
const VECTORS := [
	"requested_velocity",
	"velocity",
	"main_velocity",
	"last_velocity",
	"direction",
	"gravity_vector",
	"gravity_vec",
	"floor_normal",
	"wall_normal",
	"head_offset",
	"head_position",
	"eye_position"
]
const SCALARS := [
	"body_yaw",
	"neck_yaw",
	"head_pitch",
	"current_speed",
	"current_lerp_speed",
	"gravity",
	"jump_target_speed",
	"bunny_hop_speed",
	"speed_multiplier",
	"stamina",
	"previous_y"
]
const STAMINA_TUNING := [
	"value_max",
	"stamina_regen_speed",
	"run_exhaustion_speed",
	"uphill_run_exhaustion_max_speed",
	"downhill_run_exhaustion_max_speed",
	"step_slope_multiplier",
	"regenerate_after",
	"jump_cost"
]
const TIMERS := ["slide_remaining", "jump_remaining", "regen_remaining"]
const FLAGS := [
	"on_floor",
	"on_wall",
	"on_ceiling",
	"air_steps_enabled",
	"standing_shape",
	"crouching_shape",
	"cast_enabled",
	"cast_blocked",
	"try_crouch",
	"is_jumping_started",
	"is_in_air",
	"was_in_air",
	"was_jumping",
	"was_sprinting",
	"is_sprinting_in_airborne",
	"was_standing",
	"was_sliding",
	"jumped_from_slide",
	"jumped_from_crouch",
	"slide_stopped",
	"jump_stopped",
	"is_sitting",
	"on_ladder",
	"has_control",
	"jump_allowed",
	"posture_locked",
	"has_stamina",
	"regen_active",
	"regen_stopped"
]

var binding: int
var life: int
var revision: int
var generation: int
var tick: int
var ack := -1
var last_fresh_tick := -1
var discontinuities: int
var disposition := Disposition.NEUTRAL
var rate := 60
## Null denotes a legacy tick. Geometry and constant tuning come from the matched prefab.
var state: CogitoMovementState
var pending_force := Vector3.ZERO
var force_requested := false
var teleported := false
var input_blocked := false
var stamina_locked := false
var use_floor_slope_for_run_exhaustion := false
var value_max: float
var stamina_regen_speed: float
var run_exhaustion_speed: float
var uphill_run_exhaustion_max_speed: float
var downhill_run_exhaustion_max_speed: float
var step_slope_multiplier: float
var regenerate_after: float
var jump_cost: float


static func encode(checkpoint: NetOwnerState) -> PackedByteArray:
	var stream := StreamPeerBuffer.new()
	stream.put_u8(VERSION)
	stream.put_u8(int(checkpoint.disposition) | (128 if checkpoint.state else 0))
	stream.put_u16(checkpoint.rate)
	for field: String in ALIGNMENT:
		stream.put_64(checkpoint.get(field))
	if checkpoint.state:
		_write_state(stream, checkpoint)
	return stream.data_array


static func _write_state(stream: StreamPeerBuffer, checkpoint: NetOwnerState) -> void:
	var state_value := checkpoint.state
	stream.put_u8(state_value.mode)
	stream.put_u8(state_value.posture)
	var bits := 0
	for i in FLAGS.size():
		if state_value.get(FLAGS[i]):
			bits |= 1 << i
	stream.put_u32(bits)
	stream.put_u8(
		(
			int(checkpoint.force_requested)
			| (int(checkpoint.teleported) << 1)
			| (int(checkpoint.stamina_locked) << 2)
			| (int(checkpoint.use_floor_slope_for_run_exhaustion) << 3)
			| (int(checkpoint.input_blocked) << 4)
		)
	)
	_put_vector(stream, state_value.transform.origin)
	for basis: Basis in [state_value.transform.basis, state_value.body_basis]:
		for axis in 3:
			_put_vector(stream, basis[axis])
	for field: String in VECTORS:
		_put_vector(stream, state_value.get(field))
	for axes: Vector2 in [state_value.input_direction, state_value.slide_vector]:
		stream.put_float(axes.x)
		stream.put_float(axes.y)
	for field: String in SCALARS:
		stream.put_double(state_value.get(field))
	for field: String in TIMERS:
		stream.put_double(float(state_value.get(field)) * checkpoint.rate)
	_put_vector(stream, checkpoint.pending_force)
	for field: String in STAMINA_TUNING:
		stream.put_double(checkpoint.get(field))


## A malformed block has no usable prefix. Validate its full extent before reading the tail.
static func decode(data: PackedByteArray) -> NetOwnerState:
	if data.size() < HEADER_BYTES or data[0] != VERSION or (data[1] & 0x7c) != 0:
		return null
	var eligible := (data[1] & 128) != 0
	if data.size() != (ELIGIBLE_BYTES if eligible else HEADER_BYTES):
		return null
	var value := NetOwnerState.new()
	value.rate = data.decode_u16(2)
	value.disposition = (data[1] & 3) as Disposition
	for i in ALIGNMENT.size():
		value.set(ALIGNMENT[i], data.decode_s64(4 + 8 * i))
	if not value._valid_alignment():
		return null
	if eligible:
		var stream := StreamPeerBuffer.new()
		stream.data_array = data
		stream.seek(HEADER_BYTES)
		if not _read_state(stream, value):
			return null
	return value


func _valid_alignment() -> bool:
	return (
		rate > 0
		and binding > 0
		and life > 0
		and revision >= 0
		and generation > 0
		and tick >= 0
		and ack >= -1
		and last_fresh_tick >= -1
		and last_fresh_tick <= tick
		and (ack == -1) == (last_fresh_tick == -1)
		and discontinuities >= 0
		and (disposition == Disposition.NEUTRAL or ack >= 0)
		and (disposition not in [Disposition.FRESH, Disposition.GAP] or last_fresh_tick == tick)
	)


static func _read_state(stream: StreamPeerBuffer, value: NetOwnerState) -> bool:
	var s := CogitoMovementState.new()
	var mode_value := stream.get_u8()
	var posture_value := stream.get_u8()
	var bits := stream.get_u32()
	var adapter := stream.get_u8()
	if (
		mode_value >= CogitoMovementState.Mode.size()
		or posture_value >= CogitoMovementState.Posture.size()
	):
		return false
	if bits >> FLAGS.size() or adapter > 31:
		return false
	s.mode = mode_value as CogitoMovementState.Mode
	s.posture = posture_value as CogitoMovementState.Posture
	for i in FLAGS.size():
		s.set(FLAGS[i], (bits & (1 << i)) != 0)
	value.force_requested = (adapter & 1) != 0
	value.teleported = (adapter & 2) != 0
	value.input_blocked = (adapter & 16) != 0
	value.stamina_locked = (adapter & 4) != 0
	value.use_floor_slope_for_run_exhaustion = (adapter & 8) != 0
	var origin := _get_vector(stream)
	s.transform = Transform3D(_get_basis(stream), origin)
	s.body_basis = _get_basis(stream)
	var valid := s.transform.is_finite() and s.body_basis.is_finite()
	for field: String in VECTORS:
		var vector := _get_vector(stream)
		valid = valid and vector.is_finite()
		s.set(field, vector)
	s.input_direction = Vector2(stream.get_float(), stream.get_float())
	s.slide_vector = Vector2(stream.get_float(), stream.get_float())
	for field: String in SCALARS:
		var scalar := stream.get_double()
		valid = valid and is_finite(scalar)
		s.set(field, scalar)
	for field: String in TIMERS:
		var ticks := stream.get_double()
		valid = valid and is_finite(ticks) and ticks >= 0
		s.set(field, ticks / value.rate)
	value.pending_force = _get_vector(stream)
	for field: String in STAMINA_TUNING:
		var tuning := stream.get_double()
		valid = valid and is_finite(tuning)
		value.set(field, tuning)
	value.state = s
	return (
		valid
		and value.pending_force.is_finite()
		and s.input_direction.is_finite()
		and s.slide_vector.is_finite()
	)


static func _put_vector(stream: StreamPeerBuffer, vector: Vector3) -> void:
	stream.put_float(vector.x)
	stream.put_float(vector.y)
	stream.put_float(vector.z)


static func _get_vector(stream: StreamPeerBuffer) -> Vector3:
	return Vector3(stream.get_float(), stream.get_float(), stream.get_float())


static func _get_basis(stream: StreamPeerBuffer) -> Basis:
	return Basis(_get_vector(stream), _get_vector(stream), _get_vector(stream))

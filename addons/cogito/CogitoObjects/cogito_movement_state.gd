class_name CogitoMovementState
extends Resource
## Value-only checkpoint of the Advanced on-foot rules. duplicate() copies every stored field.

enum Mode {
	UNDEFINED,
	GROUNDED,
	IDLE,
	WALKING,
	SPRINTING,
	SLIDING,
	SNEAKING,
	SITTING,
	LADDER_CLIMBING,
	ROLLING,
	LEDGE_CLIMBING,
	AIRBORNE,
	AIR_CONTROL,
	JUMPING,
	FREE_FALL,
	SWIMMING,
}
enum LedgeStage { RISE, MIDDLE, FINAL }
enum Posture { UNDEFINED, CROUCHING, STANDING, SITTING }

## Motion.
@export_storage var transform: Transform3D
@export_storage var body_basis: Basis
@export_storage var body_yaw: float
@export_storage var neck_yaw: float
@export_storage var head_pitch: float
## Last on-foot solver request, before move_and_slide() resolves contacts.
@export_storage var requested_velocity: Vector3
@export_storage var velocity: Vector3
@export_storage var main_velocity: Vector3
@export_storage var last_velocity: Vector3
@export_storage var direction: Vector3
@export_storage var input_direction: Vector2
@export_storage var current_speed: float
@export_storage var current_lerp_speed: float
@export_storage var gravity: float
@export_storage var gravity_vector: Vector3
@export_storage var gravity_vec: Vector3

## Stable room entity hash and the rider origin (or climb target) in support coordinates.
@export_storage var support_key: int
@export_storage var support_local: Vector3
@export_storage var support_velocity: Vector3

## Previous solve and posture.
@export_storage var on_floor: bool
@export_storage var floor_normal: Vector3
@export_storage var on_wall: bool
@export_storage var wall_normal: Vector3
@export_storage var on_ceiling: bool
@export_storage var head_offset: Vector3
@export_storage var air_steps_enabled: bool
@export_storage var mode: Mode
@export_storage var posture: Posture
@export_storage var standing_shape: bool
@export_storage var crouching_shape: bool
@export_storage var cast_enabled: bool
@export_storage var cast_blocked: bool
@export_storage var try_crouch: bool
@export_storage var head_position: Vector3
@export_storage var eye_position: Vector3

## Mode memory (Timer values are seconds on the live clock).
@export_storage var jump_target_speed: float
@export_storage var is_jumping_started: bool
@export_storage var is_in_air: bool
@export_storage var was_in_air: bool
@export_storage var was_jumping: bool
@export_storage var was_sprinting: bool
@export_storage var is_sprinting_in_airborne: bool
@export_storage var was_standing: bool
@export_storage var roll_ticks: int
@export_storage var ledge_target: Vector3
@export_storage var ledge_stage: LedgeStage
@export_storage var ledge_key: int
@export_storage var was_sliding: bool
@export_storage var jumped_from_slide: bool
@export_storage var jumped_from_crouch: bool
@export_storage var bunny_hop_speed: float
@export_storage var slide_vector: Vector2
@export_storage var slide_remaining: float
@export_storage var jump_remaining: float
@export_storage var slide_stopped: bool
@export_storage var jump_stopped: bool
@export_storage var is_sitting: bool
@export_storage var on_ladder: bool

## The previous overlap distinguishes a new entry from remaining inside after jumping off.
@export_storage var ladder_contact: int
@export_storage var ladder_ticks: int
@export_storage var submerged: bool
@export_storage var was_swimming: bool
@export_storage var crouched_before_swim: bool

## Movement permissions and stamina on the observed frame.
@export_storage var has_control: bool
@export_storage var speed_multiplier: float
@export_storage var jump_allowed: bool
@export_storage var posture_locked: bool
@export_storage var has_stamina: bool
@export_storage var stamina: float
@export_storage var regen_active: bool
@export_storage var regen_stopped: bool
@export_storage var regen_remaining: float
@export_storage var previous_y: float

## Recomputed from the authored volume on every query, including the first restored tick.
var swim_depth: float


func copy_from(source: CogitoMovementState) -> void:
	transform = source.transform
	body_basis = source.body_basis
	body_yaw = source.body_yaw
	neck_yaw = source.neck_yaw
	head_pitch = source.head_pitch
	requested_velocity = source.requested_velocity
	velocity = source.velocity
	main_velocity = source.main_velocity
	last_velocity = source.last_velocity
	direction = source.direction
	input_direction = source.input_direction
	current_speed = source.current_speed
	current_lerp_speed = source.current_lerp_speed
	gravity = source.gravity
	gravity_vector = source.gravity_vector
	gravity_vec = source.gravity_vec
	support_key = source.support_key
	support_local = source.support_local
	support_velocity = source.support_velocity
	on_floor = source.on_floor
	floor_normal = source.floor_normal
	on_wall = source.on_wall
	wall_normal = source.wall_normal
	on_ceiling = source.on_ceiling
	head_offset = source.head_offset
	air_steps_enabled = source.air_steps_enabled
	mode = source.mode
	posture = source.posture
	standing_shape = source.standing_shape
	crouching_shape = source.crouching_shape
	cast_enabled = source.cast_enabled
	cast_blocked = source.cast_blocked
	try_crouch = source.try_crouch
	head_position = source.head_position
	eye_position = source.eye_position
	jump_target_speed = source.jump_target_speed
	is_jumping_started = source.is_jumping_started
	is_in_air = source.is_in_air
	was_in_air = source.was_in_air
	was_jumping = source.was_jumping
	was_sprinting = source.was_sprinting
	is_sprinting_in_airborne = source.is_sprinting_in_airborne
	was_standing = source.was_standing
	roll_ticks = source.roll_ticks
	ledge_target = source.ledge_target
	ledge_stage = source.ledge_stage
	ledge_key = source.ledge_key
	was_sliding = source.was_sliding
	jumped_from_slide = source.jumped_from_slide
	jumped_from_crouch = source.jumped_from_crouch
	bunny_hop_speed = source.bunny_hop_speed
	slide_vector = source.slide_vector
	slide_remaining = source.slide_remaining
	jump_remaining = source.jump_remaining
	slide_stopped = source.slide_stopped
	jump_stopped = source.jump_stopped
	is_sitting = source.is_sitting
	on_ladder = source.on_ladder
	ladder_contact = source.ladder_contact
	ladder_ticks = source.ladder_ticks
	submerged = source.submerged
	was_swimming = source.was_swimming
	crouched_before_swim = source.crouched_before_swim
	has_control = source.has_control
	speed_multiplier = source.speed_multiplier
	jump_allowed = source.jump_allowed
	posture_locked = source.posture_locked
	has_stamina = source.has_stamina
	stamina = source.stamina
	regen_active = source.regen_active
	regen_stopped = source.regen_stopped
	regen_remaining = source.regen_remaining
	previous_y = source.previous_y
	swim_depth = 0.0

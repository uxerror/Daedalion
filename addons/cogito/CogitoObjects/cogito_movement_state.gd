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

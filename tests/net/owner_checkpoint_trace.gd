extends RefCounted
## Shadow a live authority from one packet. Only the next commands, the static room
## and matched prefab tuning cross from the reference run after K.

const Tick := preload("res://addons/cogito/CogitoObjects/cogito_movement_tick.gd")
const Collision := preload("res://addons/cogito/CogitoObjects/cogito_movement_collision.gd")
const DT := 1.0 / 60
const LANES := {
	"ground": [158], "slide": [64, 78], "crouch": [90], "tired": [35, 132], "stairs": [55]
}

var state: CogitoMovementState
var profile: CogitoMovementProfile
var room: Collision
var body: StaminaBody
var stamina: CogitoStaminaAttribute
var first: int
var compared := 0
var pos_error := 0.0
var vel_error := 0.0
var eye_error := 0.0
var stamina_error := 0.0
var mismatches := {}
var start_mode: int
var start_clearance: bool


class StaminaBody:
	extends Node3D
	var state: CogitoMovementState
	var walking_speed: float
	var current_speed: float
	var velocity: Vector3
	var main_velocity: Vector3

	func _get(property: StringName) -> Variant:
		if property == &"WALKING_SPEED":
			return walking_speed
		return null

	func is_in_sprinting_state() -> bool:
		return state.mode == CogitoMovementState.Mode.SPRINTING

	func movement_floor_normal() -> Vector3:
		return state.floor_normal


func _init(actor: CogitoPlayerAdvanced, k: int) -> void:
	first = k
	var source := NetOwnerState.new()
	source.binding = 1
	source.life = 1
	source.generation = 1
	source.tick = k
	actor.authority_movement.capture_checkpoint(actor, source)
	var block := NetOwnerState.decode(NetOwnerState.encode(source))
	state = block.state
	profile = actor.capture_movement_profile()
	profile.jump_cost = block.jump_cost
	room = Collision.new(actor)
	body = StaminaBody.new()
	actor.get_parent().add_child(body)
	body.state = state
	body.walking_speed = profile.walking_speed
	stamina = CogitoStaminaAttribute.new()
	for key: String in NetOwnerState.STAMINA_TUNING:
		if key != "jump_cost":
			stamina.set(key, block.get(key))
	stamina.use_floor_slope_for_run_exhaustion = block.use_floor_slope_for_run_exhaustion
	stamina.is_locked = block.stamina_locked
	body.add_child(stamina)
	stamina.set_process(false)
	stamina.value_current = state.stamina
	stamina.is_regenerating = state.regen_active
	stamina.last_y = state.previous_y
	stamina.regen_timer.paused = true
	if not state.regen_stopped:
		stamina.regen_timer.start(state.regen_remaining)
		stamina.regen_timer.wait_time = block.regenerate_after
	start_mode = state.mode
	start_clearance = state.cast_blocked


func advance(cmd: CogitoPlayerCommand) -> void:
	var step := Tick.new()
	state.has_control = cmd.has_control
	state.body_yaw = cmd.yaw
	state.body_basis = state.transform.basis * Basis(Vector3.UP, cmd.yaw)
	if cmd.toggle_crouch and CogitoPlayerCommand.Action.CROUCH in cmd.edges:
		state.try_crouch = not state.try_crouch
	state.cast_blocked = (
		(state.cast_enabled or not state.standing_shape) and room.blocked(state.transform)
	)
	step.request(state, profile, cmd, DT)
	var hit := room.solve(state.transform, state, profile, DT)
	step.finish(state, profile, cmd, hit, DT, Transform3D.IDENTITY)
	body.transform = state.transform
	body.velocity = state.velocity
	body.main_velocity = state.main_velocity
	body.current_speed = state.current_speed
	if step.jump:
		stamina.subtract(profile.jump_cost)
	stamina.advance_movement_tick(DT)
	state.stamina = stamina.value_current
	state.regen_active = stamina.is_regenerating
	state.regen_remaining = stamina.regen_timer.time_left
	state.regen_stopped = stamina.regen_timer.is_stopped()
	state.previous_y = stamina.last_y


func compare_to(actual: CogitoMovementState) -> void:
	compared += 1
	pos_error = maxf(pos_error, state.transform.origin.distance_to(actual.transform.origin))
	vel_error = maxf(vel_error, state.velocity.distance_to(actual.velocity))
	eye_error = maxf(eye_error, absf(state.head_position.y - actual.head_position.y))
	stamina_error = maxf(stamina_error, absf(state.stamina - actual.stamina))
	for key: String in NetOwnerState.FLAGS + ["mode", "posture", "floor_normal", "wall_normal"]:
		if state.get(key) != actual.get(key):
			mismatches[key] = mismatches.get(key, 0) + 1
	for key: String in NetOwnerState.TIMERS:
		if ceili(state.get(key) / DT) != ceili(actual.get(key) / DT):
			mismatches[key] = mismatches.get(key, 0) + 1


func report(lane: String) -> void:
	var result := {
		"k": first,
		"n": compared,
		"pos": pos_error,
		"vel": vel_error,
		"eye": eye_error,
		"stamina": stamina_error,
		"mismatches": mismatches,
		"mode": start_mode,
		"blocked": start_clearance
	}
	print("PR2 TRACE ", lane, " ", JSON.stringify(result))
	room.close()
	body.free()

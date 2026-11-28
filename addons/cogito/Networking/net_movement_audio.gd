extends RefCounted
## One forward-only movement audio clock per presented network avatar.

signal slide_changed(playing: bool)

const Snapshot := preload("net_snapshot.gd")
const MODE := CogitoMovementState.Mode
const POSTURE := CogitoMovementState.Posture
const AIR := [MODE.AIRBORNE, MODE.AIR_CONTROL, MODE.JUMPING, MODE.FREE_FALL]
const GROUND := [
	MODE.GROUNDED,
	MODE.IDLE,
	MODE.WALKING,
	MODE.SPRINTING,
	MODE.SNEAKING,
	MODE.SLIDING,
	MODE.ROLLING
]
const STEP_PHASE := asin(0.9)

var _actor: CogitoPlayerAdvanced
var _previous := {}
var _phase := 0.0
var _slide: AudioStreamPlayer3D
var _sliding := false
var _volume_loop := false
var _previous_volume := {}
var _frames: Array[Dictionary] = [{}, {}]
var _slot := 0


func _init(actor: CogitoPlayerAdvanced) -> void:
	_actor = actor


func reset() -> void:
	_previous = {}
	_previous_volume = {}
	_phase = 0.0
	_set_sliding(false)
	if _volume_loop:
		_actor._set_underwater_audio(false)
		_actor._show_underwater_effect(false)
		_volume_loop = false


func observe_actor(tick: int, revision: int, submerged: bool, impact: float) -> void:
	_slot = 1 - _slot
	var frame := Snapshot.capture_into(_actor, tick, revision, _frames[_slot])
	observe(frame, true, submerged, impact)


## Feed accepted snapshots, or a single stream of forward predicted poses for a future owner.
func observe(
	frame: Dictionary, volume_effects := false, submerged := false, roll_impact := INF
) -> void:
	if _actor.is_dead or frame.sitting or frame.posture == POSTURE.SITTING:
		reset()
		return
	var last := _previous
	if volume_effects:
		observe_volumes(frame, submerged)
	if not last.is_empty() and frame.tick <= last.tick:
		return
	_previous = frame
	if is_finite(roll_impact) and (last.is_empty() or last.moving != MODE.ROLLING):
		_actor.animationPlayer.play(&"roll")
		_landing(roll_impact, frame.position)
	if last.is_empty() or Snapshot.discontinuous(last, frame):
		_phase = 0.0
		_set_sliding(false)
		return

	var mode: int = frame.moving
	var velocity: Vector3 = frame.velocity
	_set_sliding(mode == MODE.SLIDING)
	if mode == MODE.JUMPING and (last.moving in GROUND or last.moving == MODE.LADDER_CLIMBING):
		# Advanced can publish Jumping one tick before the upward impulse moves the body.
		if _actor.is_local_presentation:
			CogitoAudio.play_sound(_actor.jump_sound)
		else:
			CogitoAudio.play_sound_3d_attached(_actor.jump_sound, _actor)
	if not is_finite(roll_impact) and mode in GROUND and last.moving in AIR:
		_landing(last.velocity.y, frame.position)

	var dt := float(frame.tick - last.tick) / Engine.physics_ticks_per_second
	if mode != MODE.LADDER_CLIMBING and (not volume_effects or mode != MODE.SWIMMING):
		_cadence(mode, velocity, dt, frame.position)


func _landing(impact: float, position: Vector3) -> void:
	if impact < _actor.landing_threshold:
		_actor.set_landing_audio(impact)
		_surface("landing", _actor.LERP_SPEED, position)


func observe_volumes(frame: Dictionary, submerged: bool) -> void:
	var last := _previous_volume
	if not last.is_empty() and frame.tick <= last.tick:
		return
	_previous_volume = frame
	if _actor.is_local_presentation and submerged != _volume_loop:
		_volume_loop = submerged
		_actor._set_underwater_audio(submerged)
		_actor._show_underwater_effect(submerged)
	if last.is_empty() or Snapshot.discontinuous(last, frame):
		_phase = 0.0
		return
	if (frame.moving == MODE.SWIMMING) != (last.moving == MODE.SWIMMING):
		CogitoAudio.play_sound_3d_attached(_actor.swim_movement_sound, _actor)
		_phase = 0.0
	if frame.moving in [MODE.SWIMMING, MODE.LADDER_CLIMBING]:
		var dt := float(frame.tick - last.tick) / Engine.physics_ticks_per_second
		_cadence(frame.moving, frame.velocity, dt, frame.position)


func _cadence(mode: int, velocity: Vector3, dt: float, point: Vector3) -> void:
	var rate: float
	var volume: float
	match mode:
		MODE.LADDER_CLIMBING, MODE.WALKING:
			rate = _actor.WIGGLE_ON_WALKING_SPEED
			volume = _actor.walk_volume_db
		MODE.SPRINTING:
			rate = _actor.WIGGLE_ON_SPRINTING_SPEED
			volume = _actor.sprint_volume_db
		MODE.SNEAKING:
			rate = _actor.WIGGLE_ON_CROUCHING_SPEED
			volume = _actor.crouch_volume_db
		MODE.SWIMMING:
			rate = _actor.WIGGLE_ON_SWIMMING_SPEED
		_:
			return
	var speed := (
		velocity.length()
		if mode in [MODE.SWIMMING, MODE.LADDER_CLIMBING]
		else Vector2(velocity.x, velocity.z).length()
	)
	if speed < 0.2:
		return
	var next := _phase + rate * dt
	# Count a rising crossing even when two snapshots straddle the entire peak.
	var crossed := floori((next - STEP_PHASE) / TAU) > floori((_phase - STEP_PHASE) / TAU)
	_phase = fposmod(next, TAU)
	if crossed:
		if mode == MODE.SWIMMING:
			CogitoAudio.play_sound_3d_attached(_actor.swim_movement_sound, _actor)
		elif _actor.footstep_surface_detector:
			var feet := _actor.footstep_surface_detector
			feet.volume_db = volume
			if mode == MODE.LADDER_CLIMBING:
				if feet.generic_fallback_footstep_profile:
					feet._play_footstep(feet.generic_fallback_footstep_profile, "footstep")
			else:
				_surface("footstep", speed, point)


func _surface(kind: String, speed: float, point: Vector3) -> void:
	var detector := _actor.footstep_surface_detector
	if detector:
		# Smoothing can leave the visual body well above the floor on the impact tick.
		# Cast at the pose's feet, retaining the detector's authored offset and collision mask.
		var offset := detector.position
		detector.position += _actor.transform.basis.inverse() * (point - _actor.position)
		detector._play_interaction(kind, speed)
		detector.position = offset


func _set_sliding(active: bool) -> void:
	if active == _sliding:
		return
	if active:
		if not _slide:
			if _actor.is_local_presentation:
				_slide = _actor.slide_audio_player
			else:
				_slide = _actor.create_slide_audio_player()
			if not _slide:
				return
			_slide.finished.connect(_slide.play)
		_slide.play()
	else:
		_slide.stop()
	_sliding = active
	slide_changed.emit(active)

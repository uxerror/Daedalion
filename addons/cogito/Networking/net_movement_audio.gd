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


func _init(actor: CogitoPlayerAdvanced) -> void:
	_actor = actor


func reset() -> void:
	_previous = {}
	_phase = 0.0
	_set_sliding(false)


## Feed accepted snapshots, or a single stream of forward predicted poses for a future owner.
func observe(frame: Dictionary) -> void:
	if _actor.is_dead or frame.sitting or frame.posture == POSTURE.SITTING:
		reset()
		return
	var last := _previous
	if not last.is_empty() and frame.tick <= last.tick:
		return
	_previous = frame
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
	if mode in GROUND and last.moving in AIR and last.velocity.y < _actor.landing_threshold:
		_actor.set_landing_audio(last.velocity.y)
		_surface("landing", _actor.LERP_SPEED, frame.position)

	var dt := float(frame.tick - last.tick) / Engine.physics_ticks_per_second
	_cadence(mode, velocity, dt, frame.position)


func _cadence(mode: int, velocity: Vector3, dt: float, point: Vector3) -> void:
	var rate: float
	var volume: float
	match mode:
		MODE.WALKING:
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
		velocity.length() if mode == MODE.SWIMMING else Vector2(velocity.x, velocity.z).length()
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
			_actor.footstep_surface_detector.volume_db = volume
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

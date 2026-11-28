extends RefCounted
## A short server-tick timeline per avatar. All samples use server level coordinates.

enum Acceptance { REJECTED, ACCEPTED, RESET }

const DELAY := 0.1
const MAX_EXTRAPOLATION := 0.05
const TELEPORT_DISTANCE := 4.0

var _frames: Array[Dictionary] = []
var _arrival_usec := 0
var _render_tick := -1.0


## Optional mannequin clip phase for an online, tick-driven roll.
static func roll_phase(actor: CogitoPlayerAdvanced) -> float:
	if (
		not actor.authority_movement
		or actor.current_moving_state != CogitoPlayerAdvanced.MovingState.Rolling
	):
		return -1.0
	var duration := actor.authority_movement.profile.roll_duration_ticks
	return 1.0 - float(actor._motion.roll_ticks) / maxi(1, duration)


## Captures the simulated pose after movement. Revision changes force even a small teleport.
static func capture(actor: CogitoPlayerAdvanced, tick: int, revision: int) -> Dictionary:
	var frame := {
		"tick": tick,
		"revision": revision,
		"ack": actor.last_consumed_sequence,
		"position": actor.position,
		"velocity": actor.velocity,
		"yaw": actor.body.rotation.y,
		"pitch": actor.head.rotation.x,
		"neck": actor.neck.rotation.y,
		"height": actor.head.position.y,
		"moving": int(actor.current_moving_state),
		"posture": int(actor.current_body_posture_state),
		"sitting": actor.is_sitting,
	}
	var kernel := actor.authority_movement
	if kernel and kernel.contacts and kernel.contacts.floor_support and actor.movement_grounded():
		var support_motion := kernel.contacts.floor_support
		frame.support = support_motion.key
		frame.footing = support_motion.body.to_local(actor.global_position)
	var phase := roll_phase(actor)
	if phase >= 0:
		frame.roll_phase = phase
	if actor.is_sitting and actor.current_seat:
		var api := actor.player_interaction_component.network_interactions
		if api:
			frame.seat = api.world.entities.id_for(actor.current_seat)
			frame.basis = actor.transform.basis
	return frame


static func discontinuous(last: Dictionary, frame: Dictionary) -> bool:
	var previous: Vector3 = last.position
	return (
		last.revision != frame.revision
		or previous.distance_to(frame.position) > TELEPORT_DISTANCE
		or last.sitting != frame.sitting
	)


## Only an accepted reset replaces position and local look immediately.
func push(frame: Dictionary) -> Acceptance:
	var reset := _frames.is_empty()
	if not reset:
		var last := _frames.back() as Dictionary
		if frame.tick <= last.tick or frame.revision < last.revision:
			return Acceptance.REJECTED
		reset = discontinuous(last, frame)
	if reset:
		_frames.clear()
		_render_tick = -1.0
	if frame.has("owner_state"):
		frame = frame.duplicate()
		frame.erase("owner_state")
	_frames.append(frame)
	if _frames.size() > 32:
		_frames.pop_front()
	_arrival_usec = Time.get_ticks_usec()
	return Acceptance.RESET if reset else Acceptance.ACCEPTED


## Latest authoritative frame for owner smoothing and acknowledgement.
func latest() -> Dictionary:
	return _frames.back() if not _frames.is_empty() else {}


## Render about 100 ms behind the last observed server clock.
func presentation(rate: int) -> Dictionary:
	if _frames.is_empty():
		return {}
	var elapsed := (Time.get_ticks_usec() - _arrival_usec) / 1000000.0
	_render_tick = maxf(_render_tick, float(latest().tick) + (elapsed - DELAY) * rate)
	return at_tick(_render_tick, rate)


## Interpolates continuous fields on the shortest angular arc and holds discrete states.
func at_tick(tick: float, rate: int) -> Dictionary:
	if _frames.is_empty():
		return {}
	var before := _frames.front() as Dictionary
	if tick <= before.tick:
		return before
	for after in _frames:
		if tick < after.tick:
			var weight := (tick - float(before.tick)) / float(after.tick - before.tick)
			var pose := before.duplicate()
			var pos: Vector3 = before.position
			var vel: Vector3 = before.velocity
			pose.position = pos.lerp(after.position, weight)
			pose.velocity = vel.lerp(after.velocity, weight)
			if before.has("support"):
				if before.support == after.get("support", 0):
					var local: Vector3 = before.footing
					pose.footing = local.lerp(after.footing, weight)
				else:
					pose.erase("support")
					pose.erase("footing")
			pose.yaw = lerp_angle(before.yaw, after.yaw, weight)
			pose.neck = lerp_angle(before.neck, after.neck, weight)
			pose.pitch = lerpf(before.pitch, after.pitch, weight)
			pose.height = lerpf(before.height, after.height, weight)
			return pose
		before = after
	var extrapolated := before.duplicate()
	var elapsed := minf((tick - float(before.tick)) / rate, MAX_EXTRAPOLATION)
	extrapolated.position += extrapolated.velocity * elapsed
	return extrapolated

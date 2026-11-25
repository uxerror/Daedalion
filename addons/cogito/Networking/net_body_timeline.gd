extends RefCounted
## Interpolation clock for one kinematic replica, in server physics ticks.

const SNAPSHOT := preload("net_snapshot.gd")

var tick := -1
var resting := false
var _entry_tick := -1
var _frames: Array[Array] = []
var _arrival := 0
var _render := 0.0


## Ignore reordered datagrams. An interest baseline or rest pose resets playback immediately.
func push(stamp: int, row: Array) -> bool:
	if stamp <= tick:
		return false
	var snap: bool = row[4] or _entry_tick != row[5]
	_entry_tick = row[5]
	resting = row[6]
	if snap:
		_frames.clear()
		_render = stamp
	tick = stamp
	_arrival = Time.get_ticks_usec()
	_frames.append([stamp, row[1], row[2], row[3]])
	if _frames.size() > 16:
		_frames.pop_front()
	return snap


## Render from the same delayed clock and extrapolation ceiling as remote avatars.
func pose(rate: int) -> Transform3D:
	var elapsed := (Time.get_ticks_usec() - _arrival) / 1000000.0
	_render = maxf(_render, tick + (elapsed - SNAPSHOT.DELAY) * rate)
	var before := _frames.front() as Array
	for after in _frames:
		if after[0] > _render:
			var weight := inverse_lerp(float(before[0]), float(after[0]), _render)
			return (before[1] as Transform3D).interpolate_with(after[1], weight)
		before = after
	var result: Transform3D = before[1]
	var dt := clampf((_render - tick) / rate, 0.0, SNAPSHOT.MAX_EXTRAPOLATION)
	result.origin += (before[2] as Vector3) * dt
	var spin: Vector3 = before[3]
	if not spin.is_zero_approx():
		result.basis = result.basis.rotated(spin.normalized(), spin.length() * dt)
	return result

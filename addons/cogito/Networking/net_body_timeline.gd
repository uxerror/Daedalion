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
	if not snap and row.size() > 7 and not _frames.is_empty():
		var last: Transform3D = _frames.back()[1]
		snap = last.origin.distance_to(row[1].origin) > SNAPSHOT.TELEPORT_DISTANCE
	_entry_tick = row[5]
	resting = row[6]
	if snap:
		_frames.clear()
		_render = stamp
	tick = stamp
	_arrival = Time.get_ticks_usec()
	var joints: Array = NetNpcCorpse.Codec.decode(row[7]) if row.size() > 7 else []
	_frames.append([stamp, row[1], row[2], row[3], joints])
	if _frames.size() > 16:
		_frames.pop_front()
	return snap


func snap_corpse(corpse: NetNpcCorpse) -> void:
	var latest: Array = _frames.back()
	corpse.apply_frame(latest[1], latest[4])


## Render from the same delayed clock and extrapolation ceiling as remote avatars.
func pose(rate: int, corpse: NetNpcCorpse = null) -> Transform3D:
	var elapsed := (Time.get_ticks_usec() - _arrival) / 1000000.0
	_render = maxf(_render, tick + (elapsed - SNAPSHOT.DELAY) * rate)
	var previous := _frames.front() as Array
	for following in _frames:
		if following[0] > _render:
			var weight := inverse_lerp(float(previous[0]), float(following[0]), _render)
			var root := (previous[1] as Transform3D).interpolate_with(following[1], weight)
			if corpse:
				corpse.apply_frame(root, previous[4], following[4], weight)
			return root
		previous = following
	var result: Transform3D = previous[1]
	var dt := clampf((_render - tick) / rate, 0.0, SNAPSHOT.MAX_EXTRAPOLATION)
	result.origin += (previous[2] as Vector3) * dt
	var spin: Vector3 = previous[3]
	if not spin.is_zero_approx():
		result.basis = result.basis.rotated(spin.normalized(), spin.length() * dt)
	if corpse:
		corpse.apply_frame(result, previous[4])
	return result

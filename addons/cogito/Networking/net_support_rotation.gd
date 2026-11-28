extends RefCounted
## CogitoDoor's authored physics recurrence. Cache recent integer samples locally so
## repeated probes and rollback share the calculation. Only its initial values travel.

const HISTORY := 132

var _row: Dictionary
var _angles := PackedVector3Array()
var _last := 0
var _settled := -1


func _init(row: Dictionary) -> void:
	_row = row
	_angles.resize(HISTORY)
	_angles[0] = row.angles


func settled(age: float) -> bool:
	return _settled >= 0 and age >= _settled


func angles_at(age: float) -> Vector3:
	var tick := maxi(0, floori(age))
	var upper := maxi(tick, ceili(age))
	if settled(tick):
		return _angles[_settled % HISTORY]
	if tick <= _last - HISTORY:
		_last = 0
		_settled = -1
		_angles[0] = _row.angles
	while _last < upper and _settled < 0:
		_sample()
	var lower_angle := _angles[tick % HISTORY] if not settled(tick) else _angles[_settled % HISTORY]
	var next_angle := _angles[mini(upper, _last) % HISTORY]
	return lower_angle.lerp(next_angle, age - tick)


func _sample() -> void:
	var angles := _angles[_last % HISTORY]
	var next := angles
	var target: Vector3 = _row.degrees
	var axis: int = _row.axis
	var done: bool
	if axis < 0:
		# The authored free-axis callback moves radians towards the numeric
		# degree vector and checks the resulting degrees against its tolerance.
		next = angles.move_toward(target, _row.step)
		var observed := angles if _row.sync else next
		var diff := (target - observed * (180.0 / PI)).abs()
		done = diff[diff.max_axis_index()] < float(_row.tolerance)
	else:
		# The authored Z branch writes X from Z, including on an interrupted swing.
		next[0 if axis == 2 else axis] = lerp_angle(
			angles[axis], deg_to_rad(target[axis]), clampf(_row.step, 0, 1)
		)
		var observed := angles if _row.sync else next
		done = rad_to_deg(observed[axis]) == target[axis]
	_last += 1
	_angles[_last % HISTORY] = next
	if done or next == angles:
		_settled = _last

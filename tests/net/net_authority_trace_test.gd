extends GdUnitTestSuite
## Each child runs an actual listen session at one render per physics tick. Hashes
## pin the pre-PR1b authority rows (command, pose, eye, speed, mode, shapes, stamina).

const RUNNER := "res://tests/net/authority_trace_runner.tscn"
const SWITCH := "COGITO_AUTHORITY_MOVEMENT"
const APPROVED := {
	"ground": "8b728d86588fda6fc3cd9c54505e54e0cccd93a1748a379f5b7779a519168103",
	"crouch": "4e235b6e1ad1739e6fca0b07dc6b254ee43af050e59a231e824701196e1a14b8",
	"toggle_roof": "c2c8755b83be3a1692903e3e9e2b7caac7ecb830c133436af91570e72291c289",
	"stairs": "e7c57db06427ccd032db138fbb8c0e79bfa48d773861cbdaf4fe32517473897f",
	"slide": "5587e98eb3c33386d5226d6f8a1368b4ef540fb910dee0d5dee8e6f560de1760",
	"tired": "09226fb83f877fb2e20f8238396258d536d02ad79e7dce99d3aa903d646b79d3",
	"slope": "1c0dccd82ed80c05b32095179ab3ca740ea334a31fa029f0292b423acb63dedc",
	"wall": "00657d59cd93f0a7924e70c928f68996a87b729542b0813b1cabbb39ed23d03d",
}
# Same-command bound, then distance from the closest of the two adjacent legacy
# ticks or the current tick. Stair edges can put the two bodies on different treads.
const EFFECTS := {
	"ground": [4, 1, 1, 0, 5],
	"crouch": [4, 0, 0, 0, 4],
	"toggle_roof": [3, 0, 0, 0, 3],
	"stairs": [4, 0, 0, 0, 4],
	"slide": [2, 1, 1, 1, 3],
	"tired": [6, 0, 0, 0, 6],
	"slope": [2, 0, 0, 0, 2],
	"wall": [2, 0, 0, 0, 2],
}
const POSITION := {
	"ground": [0.09, 0.055],
	"crouch": [0.09, 0.02],
	"toggle_roof": [0.09, 0.085],
	"stairs": [0.24, 0.015],
	"slide": [0.16, 0.035],
	"tired": [0.12, 0.001],
	"slope": [0.07, 0.003],
	"wall": [0.07, 0.003],
}


func _trace_output(enabled: bool, volumes := false) -> String:
	var previous := OS.get_environment(SWITCH)
	OS.set_environment(SWITCH, "1" if enabled else "0")
	var output := []
	var args := [
		"--headless",
		"--path",
		ProjectSettings.globalize_path("res://"),
		"--fixed-fps",
		"60",
		"--quit-after",
		"3000",
		RUNNER
	]
	if volumes:
		args.append_array(["--", "--volumes"])
	var status := OS.execute(OS.get_executable_path(), args, output, true)
	OS.set_environment(SWITCH, previous)
	var log_text := "\n".join(output)
	assert_int(status).override_failure_message(log_text.right(2000)).is_zero()
	assert_bool("SCRIPT ERROR" in log_text).is_false()
	return log_text


func _run(enabled: bool) -> Dictionary:
	var log_text := _trace_output(enabled)
	var rows := {}
	var raw := {}
	var solves := 0
	var bad_counts := 0
	var summaries := 0
	var checkpoints := {}
	for line in log_text.split("\n"):
		if line.begins_with("TRACE "):
			var fields := line.split(" ", false, 2)
			rows.get_or_add(fields[1], []).append(JSON.parse_string(fields[2]))
			raw.get_or_add(fields[1], []).append(fields[2])
		elif line.begins_with("PR2 TRACE "):
			var fields := line.split(" ", false, 3)
			var report: Dictionary = JSON.parse_string(fields[3])
			checkpoints.get_or_add(fields[2], []).append(int(report.k))
			print(line)
			assert_int(int(report.n)).is_equal(60)
			assert_float(report.pos).is_less_equal(0.02)
			assert_float(report.vel).is_less_equal(0.10)
			assert_float(report.eye).is_less_equal(0.01)
			assert_float(report.stamina).is_less_equal(0.000001)
			assert_dict(report.mismatches).is_empty()
			if fields[2] == "crouch":
				assert_bool(report.blocked).is_true()
		elif line.begins_with("WRITERS "):
			var fields := line.split(" ")
			var expected := fields[3].to_int() if enabled else 0
			assert_int(fields[2].to_int()).is_equal(expected)
			summaries += 1
		elif line.begins_with("EFFECTS "):
			var fields := line.split(" ", false, 2)
			assert_str(fields[2]).is_equal(JSON.stringify(EFFECTS[fields[1]]))
			summaries += 1
		elif line.begins_with("SOLVES "):
			solves += 1
			bad_counts += int(not line.ends_with(" 1"))
	assert_int(summaries).is_equal(2 * APPROVED.size())
	assert_int(solves).is_equal(1442)
	assert_int(bad_counts).is_zero()
	assert_int(rows.size()).is_equal(APPROVED.size())
	if enabled:
		assert_dict(checkpoints).is_equal(preload("owner_checkpoint_trace.gd").LANES)
	if not enabled:
		for lane: String in raw:
			assert_str("\n".join(raw[lane]).sha256_text()).is_equal(APPROVED[lane])
	return rows


func _pos(row: Array) -> Vector3:
	return Vector3(row[1], row[2], row[3])


func _nearby_error(reference: Array, tick: int, col: int, actual: float) -> float:
	var closest := INF
	for j in range(maxi(0, tick - 2), mini(reference.size(), tick + 3)):
		closest = minf(closest, absf(actual - reference[j][col]))
	return closest


func _compare(lane: String, reference: Array, actual: Array) -> void:
	assert_int(actual.size()).is_equal(reference.size())
	var maximum := 0.0
	var adjacent := 0.0
	var stamina_error := 0.0
	var speed_error := 0.0
	var head_error := 0.0
	for i in actual.size():
		var pos := _pos(actual[i])
		var distance := pos.distance_to(_pos(reference[i]))
		maximum = maxf(maximum, distance)
		for j in range(maxi(0, i - 1), mini(reference.size(), i + 2)):
			distance = minf(distance, pos.distance_to(_pos(reference[j])))
		adjacent = maxf(adjacent, distance)
		stamina_error = maxf(stamina_error, absf(actual[i][9] - reference[i][9]))
		speed_error = maxf(speed_error, _nearby_error(reference, i, 5, actual[i][5]))
		head_error = maxf(head_error, _nearby_error(reference, i, 4, actual[i][4]))
		# Moving/posture transitions may shift a tick. The tall shape follows eye height.
		for col: int in [6, 7, 8, 10]:
			var matched := false
			for j in range(maxi(0, i - 2), mini(reference.size(), i + 3)):
				matched = matched or actual[i][col] == reference[j][col]
			if not matched:
				fail("Unexpected %s field %d at tick %d" % [lane, col, i])
				return
	print("PR1b ", lane, " max_m=", maximum, " adjacent_m=", adjacent, " stamina=", stamina_error)
	assert_float(maximum).is_less(POSITION[lane][0])
	assert_float(adjacent).is_less(POSITION[lane][1])
	assert_float(stamina_error).is_less(0.14)
	assert_float(speed_error).is_less(0.5 if lane == "slide" else 0.14)
	assert_float(head_error).is_less(0.12 if lane == "slide" else 0.005)


func test_approved_online_routes_and_one_solve_per_tick(_timeout := 90000) -> void:
	var legacy := _run(false)
	var kernel := _run(true)
	for lane: String in APPROVED:
		_compare(lane, legacy[lane], kernel[lane])
	assert_float(legacy.ground[20][3]).is_zero()
	assert_float(kernel.ground[20][3]).is_less(-0.001)
	assert_float(kernel.ground[155][2]).is_greater(kernel.ground[154][2])
	assert_float(kernel.crouch[20][4]).is_less(kernel.crouch[19][4])
	assert_bool(kernel.crouch[80][8]).is_true()
	assert_bool(kernel.toggle_roof[70][8]).is_true()
	assert_bool(kernel.slide[75][10]).is_true()
	assert_int(int(kernel.tired[132][6])).is_equal(CogitoMovementState.Mode.WALKING)
	assert_float(kernel.tired.back()[9]).is_greater(kernel.tired[156][9])


func _volume_rows(enabled: bool) -> Dictionary:
	var rows := {"ladder": [], "swim": []}
	for line in _trace_output(enabled, true).split("\n"):
		if line.begins_with("TRACE "):
			var fields := line.split(" ", false, 2)
			rows[fields[1]].append(JSON.parse_string(fields[2]))
	return rows


func test_ladder_and_swim_follow_the_legacy_chart_until_air_handoff(_timeout := 90000) -> void:
	var chart := _volume_rows(false)
	var kernel := _volume_rows(true)
	for lane: String in chart:
		assert_int(kernel[lane].size()).is_equal(chart[lane].size())
		# Jump-off at 80 and takeoff on the bank use PR3's same-tick jump.
		# PR7 samples the ledge before the solve to ascend on the capture tick.
		var end := 80 if lane == "ladder" else 153
		assert_int(kernel[lane].size()).is_greater(end)
		for i in end:
			var reference: Array = chart[lane][i]
			var actual: Array = kernel[lane][i]
			assert_vector(_pos(actual)).is_equal(_pos(reference))
			assert_int(int(actual[6])).is_equal(int(reference[6]))
		print("PR6 CHART ", lane, " matched_position_and_mode=", end)

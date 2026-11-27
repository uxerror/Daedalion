extends GdUnitTestSuite

const RUNNER := "res://tests/player/golden_runner.tscn"


func test_offline_trace_repeats_within_and_across_processes(_timeout := 90000) -> void:
	var digests: Array[String] = []
	for process_index in 2:
		var output := []
		var args := [
			"--headless",
			"--path",
			ProjectSettings.globalize_path("res://"),
			"--fixed-fps",
			"60",
			"--quit-after",
			"5500",
			RUNNER,
		]
		# Each child inherits the host process priority and runs two independent laps.
		var status := OS.execute(OS.get_executable_path(), args, output, true)
		var log_text := "\n".join(output)
		for line in log_text.split("\n"):
			if line.begins_with("GOLDEN PASS "):
				digests.append(line.trim_prefix("GOLDEN PASS "))
		assert_int(status).override_failure_message(log_text.right(3000)).is_zero()
		assert_bool("SCRIPT ERROR" in log_text).is_false()
	assert_int(digests.size()).is_equal(2)
	if digests.size() == 2:
		assert_str(digests[0]).is_equal(digests[1])

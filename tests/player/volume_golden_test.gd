extends GdUnitTestSuite


func test_offline_volume_routes_match_additional_digests() -> void:
	var output := []
	var args := [
		"--headless",
		"--path",
		ProjectSettings.globalize_path("res://"),
		"--fixed-fps",
		"60",
		"res://tests/player/volume_golden_runner.tscn"
	]
	var status := OS.execute(OS.get_executable_path(), args, output, true)
	var log_text := "\n".join(output)
	assert_int(status).override_failure_message(log_text.right(2000)).is_zero()
	assert_bool(log_text.contains("SCRIPT ERROR")).is_false()
	assert_int(log_text.count("VOLUME GOLDEN ")).is_equal(2)

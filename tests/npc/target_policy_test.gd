extends GdUnitTestSuite


func test_hysteresis_then_distance_and_stable_id() -> void:
	var policy := CogitoNpcTargetPolicy.new()
	var rows := {
		"b": {"score": 1.0, "visible": true, "distance": 4.0},
		"a": {"score": 1.0, "visible": true, "distance": 4.0},
	}
	assert_str(policy.choose(null, rows, "")).is_equal("a")
	rows.b.distance = 3.0
	assert_str(policy.choose(null, rows, "")).is_equal("b")
	assert_str(policy.choose(null, rows, "a")).is_equal("a")
	rows.b.score = 1.2
	assert_str(policy.choose(null, rows, "a")).is_equal("b")
	rows.b.visible = false
	assert_str(policy.choose(null, rows, "b")).is_equal("a")

extends GdUnitTestSuite


func test_numeric_group_displays_progress_by_flag_name() -> void:
	var group := MultiFlagGroup.new()
	var flag := NumericFlag.new()
	flag.flag_name = "keys"
	flag.expected = 5
	flag.specific_objective_text = "Keys "
	group.flags.append(flag)
	assert_array(group.get_numeric_descriptions({"keys": 3})).contains_exactly(["Keys (3 / 5)"])

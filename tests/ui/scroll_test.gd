extends GdUnitTestSuite

const SCROLLER := preload("res://addons/cogito/EasyMenus/Scripts/follow_focus_center.gd")


func test_small_stick_motions_accumulate_in_both_directions() -> void:
	var scroller: SCROLLER = auto_free(SCROLLER.new())
	var bar := scroller.get_v_scroll_bar()
	bar.max_value = 100
	scroller.scroll_vertical = 10
	scroller.gamepad_scroll = 0.125
	for i in 8:
		scroller._process(1.0 / 60)
	assert_int(scroller.scroll_vertical).is_equal(15)
	scroller.gamepad_scroll = -0.125
	for i in 8:
		scroller._process(1.0 / 60)
	assert_int(scroller.scroll_vertical).is_equal(10)

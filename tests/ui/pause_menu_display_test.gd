extends GdUnitTestSuite

const PAUSE_MENU := preload("res://addons/cogito/EasyMenus/Scenes/PauseMenu.tscn")
const OPTIONS := preload("res://addons/cogito/EasyMenus/Scenes/OptionsTabMenu.tscn")


# Opening the in-game menu must not resize or move the window (multi-monitor
# setups saw the window jump to the saved resolution across several screens).
func test_pause_menu_options_do_not_reapply_display() -> void:
	var menu: Node = auto_free(PAUSE_MENU.instantiate())
	var options: OptionsTabMenu = menu.get_node("Content/OptionsTabMenu")
	assert_bool(options.apply_display_on_load).is_false()


func test_display_reapplied_only_after_change_in_menu() -> void:
	var options: OptionsTabMenu = auto_free(OPTIONS.instantiate())
	options.apply_display_on_load = false
	options._window_on_open = [CogitoGameConfig.is_fullscreen(), get_window().size]
	assert_bool(options._should_apply_display()).is_false()
	options._window_on_open = [CogitoGameConfig.is_fullscreen(), get_window().size + Vector2i.ONE]
	assert_bool(options._should_apply_display()).is_true()
	options.apply_display_on_load = true
	options._window_on_open = [CogitoGameConfig.is_fullscreen(), get_window().size]
	assert_bool(options._should_apply_display()).is_true()

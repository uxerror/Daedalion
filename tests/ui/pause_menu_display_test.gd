extends GdUnitTestSuite

const PAUSE_MENU := preload("res://addons/cogito/EasyMenus/Scenes/PauseMenu.tscn")
const OPTIONS := preload("res://addons/cogito/EasyMenus/Scenes/OptionsTabMenu.tscn")
const CONFIG := preload("res://addons/cogito/Scripts/cogito_game_config.gd")


# Opening the in-game menu must not resize or move the window (multi-monitor
# setups saw the window jump to the saved resolution across several screens).
func test_pause_menu_options_do_not_reapply_display() -> void:
	var menu: Node = auto_free(PAUSE_MENU.instantiate())
	var options: OptionsTabMenu = menu.get_node("Content/OptionsTabMenu")
	assert_bool(options.apply_display_on_load).is_false()


# A window resized by hand (window manager drag) is not a menu change: closing the
# menu must not snap it back to the saved resolution and recentre it.
func test_display_reapplied_only_after_change_in_menu() -> void:
	var options: OptionsTabMenu = auto_free(OPTIONS.instantiate())
	options.apply_display_on_load = false
	assert_bool(options._should_apply_display()).is_false()
	options._mark_display_changed()
	assert_bool(options._should_apply_display()).is_true()
	options._display_applied()
	assert_bool(options._should_apply_display()).is_false()


func test_main_menu_applies_saved_display_only_on_first_load() -> void:
	var options: OptionsTabMenu = auto_free(OPTIONS.instantiate())
	options.apply_display_on_load = true
	assert_bool(options._should_apply_display()).is_true()
	options._display_applied()
	assert_bool(options._should_apply_display()).is_false()


# A saved windowed size as large as the monitor (3440x1440 on a 3440x1440 screen)
# plus its frame filled the whole work area: the title bar pressed against the panel and
# the resize edges sat on the screen boundary. Fall back to the largest preset that fits.
func test_windowed_size_fits_usable_screen_with_decorations() -> void:
	var usable := Rect2i(Vector2i(1920, 32), Vector2i(3440, 1408))
	var decorations := Vector2i(8, 32)
	var presets := [
		Vector2i(800, 600), Vector2i(1920, 1200), Vector2i(2560, 1080), Vector2i(3440, 1440)
	]
	assert_vector(CONFIG.fit_windowed(Vector2i(3440, 1440), usable, decorations, presets)).is_equal(
		Vector2i(2560, 1080)
	)
	assert_vector(CONFIG.fit_windowed(Vector2i(800, 600), usable, decorations, presets)).is_equal(
		Vector2i(800, 600)
	)
	var clamped := CONFIG.fit_windowed(Vector2i(3440, 1440), usable, decorations)
	assert_bool(usable.encloses(Rect2i(usable.position, clamped + decorations))).is_true()
	var position := CONFIG.centered_position(Vector2i(800, 600), usable, decorations)
	assert_bool(usable.encloses(Rect2i(position - Vector2i(4, 28), Vector2i(808, 632)))).is_true()

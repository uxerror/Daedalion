extends GdUnitTestSuite

const PROMPT := preload("res://addons/cogito/Scripts/cogito_prompt_ui.gd")


func test_behind_camera_marker_uses_half_pixel_center() -> void:
	var window: Window = auto_free(Window.new())
	window.size = Vector2i(801, 601)
	add_child(window)
	var camera := Camera3D.new()
	window.add_child(camera)
	var prompt := PROMPT.new()
	window.add_child(prompt)
	prompt.camera = camera
	var behind := -camera.project_position(Vector2(400.25, 300), 1.0)
	var marker := prompt._convert_3d_pos_to_2d_pos(behind)
	assert_float(marker.x).is_equal(801.0 - PROMPT.MARGIN)

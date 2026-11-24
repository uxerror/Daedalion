extends GdUnitTestSuite

const DebugLineScript := preload("res://addons/cogito/Scripts/debug_line.gd")


# A dedicated server has no Camera3D: the sight detection debug line must not
# error on every redraw, and timed-out lines must still be pruned.
func test_lines_expire_without_camera() -> void:
	var viewport: SubViewport = auto_free(SubViewport.new())
	add_child(viewport)
	assert_object(viewport.get_camera_3d()).is_null()
	var debug_line: Node2D = DebugLineScript.new()
	viewport.add_child(debug_line)
	debug_line.draw_3d_line(Vector3.ZERO, Vector3.ONE, Color.RED, 0.05)
	await get_tree().create_timer(0.3).timeout
	await get_tree().process_frame
	assert_int(debug_line.lines.size()).is_equal(0)

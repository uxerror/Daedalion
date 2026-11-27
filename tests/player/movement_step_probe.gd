extends MainLoop
## Standalone smoke for the step. Invoked with --script, without a SceneTree or physics world.


func _initialize() -> void:
	var state := CogitoMovementState.new()
	state.main_velocity = Vector3(3, -2, 0)
	state.direction = Vector3.FORWARD
	state.current_speed = 6.0
	state.speed_multiplier = 0.5
	state.current_lerp_speed = 30.0
	state.gravity_vec = Vector3.DOWN
	var result := CogitoMovementState.new()
	CogitoMovementStep.request_motion(state, true, 1.0 / 60.0, result)
	var expected := Vector3(1.5, -3, -1.5)
	if result.requested_velocity == expected and not Engine.get_main_loop() is SceneTree:
		print("MOVEMENT MAINLOOP PASS")


func _process(_delta: float) -> bool:
	return true

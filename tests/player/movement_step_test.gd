extends GdUnitTestSuite

const Step := preload("res://addons/cogito/CogitoObjects/cogito_movement_step.gd")
const DT := 1.0 / 60.0


func test_requested_motion_can_be_repeated_without_advancing_its_input() -> void:
	var state := CogitoMovementState.new()
	state.main_velocity = Vector3(1, 3, -2)
	state.direction = Vector3(0.6, 0, 0.8)
	state.current_speed = 6.0000000003
	state.current_lerp_speed = 12.0
	state.speed_multiplier = 0.7
	state.gravity_vec = Vector3(0, -0.125, 0)
	var original := state.main_velocity
	var a := CogitoMovementState.new()
	var b := CogitoMovementState.new()
	Step.request_motion(state, true, DT, a)
	Step.request_motion(state, true, DT, b)
	assert_vector(a.last_velocity).is_equal(b.last_velocity)
	assert_vector(a.main_velocity).is_equal(a.last_velocity)
	assert_vector(a.requested_velocity).is_equal(a.last_velocity + state.gravity_vec)
	assert_vector(b.requested_velocity).is_equal(a.requested_velocity)
	assert_vector(state.main_velocity).is_equal(original)
	assert_float(state.current_speed).is_equal(6.0000000003)
	Step.request_motion(state, false, DT, b)
	assert_vector(b.main_velocity).is_equal(Vector3(0.8, 3, -1.6))


func test_sprint_takeoff_keeps_scalar_precision_and_hop_cap() -> void:
	var state := CogitoMovementState.new()
	var profile := CogitoMovementProfile.new()
	var output := CogitoMovementState.new()
	state.bunny_hop_speed = 7.0
	state.current_speed = 6.9
	profile.can_bunnyhop = true
	profile.sprinting_speed = 7.0
	profile.bunny_hop_acceleration = 0.1000000001
	profile.max_speed = 7.15
	Step.Ground.sprint_takeoff(state, profile, DT, output)
	assert_float(output.current_speed).is_equal(7.0 + profile.bunny_hop_acceleration)
	assert_float(output.bunny_hop_speed).is_equal(output.current_speed)
	assert_float(state.bunny_hop_speed).is_equal(7.0)
	Step.Ground.sprint_takeoff(output, profile, DT, output)
	assert_float(output.current_speed).is_equal(profile.max_speed)


func test_jump_and_sprint_stamina_boundaries() -> void:
	assert_bool(Step.Stamina.jump_affordable(false, 0.0, 5.0)).is_true()
	assert_bool(Step.Stamina.jump_affordable(true, 5.0, 5.0)).is_true()
	assert_bool(Step.Stamina.jump_affordable(true, 4.99, 5.0)).is_false()
	assert_bool(Step.Stamina.can_start_sprint(false, true, false, 20.0)).is_false()
	assert_bool(Step.Stamina.can_start_sprint(false, true, true, 5.0)).is_false()
	assert_bool(Step.Stamina.can_start_sprint(false, true, true, 5.01)).is_true()
	assert_int(Step.Stamina.sprint(true, 0.2)).is_equal(Step.Stamina.Sprint.LOW)
	assert_int(Step.Stamina.sprint(true, 0.0)).is_equal(Step.Stamina.Sprint.EMPTY)
	assert_int(Step.Stamina.sprint(false, 0.0)).is_equal(Step.Stamina.Sprint.ACTIVE)
	var blocked := Step.Jump.eligibility(false, false, true, false, true)
	assert_int(blocked).is_equal(Step.Jump.Eligibility.BLOCKED)
	var crouched := Step.Jump.eligibility(false, true, true, true, false)
	assert_int(crouched).is_equal(Step.Jump.Eligibility.BLOCKED)


func test_stamina_on_flat_floor_slope_and_steps() -> void:
	var flat := Step.Stamina.run_rate(Vector3.UP, Vector3.FORWARD, 2, 2, 4, 3, 7, 1)
	var up_step := Step.Stamina.run_rate(Vector3.UP, Vector3.FORWARD, 2.125, 2, 4, 3, 7, 1)
	var down_step := Step.Stamina.run_rate(Vector3.UP, Vector3.FORWARD, 1.5, 2, 4, 3, 7, 1)
	var slope := Step.Stamina.run_rate(Vector3.UP, Vector3(0, -3, 4), 1, 1, 4, 3, 7, 1)
	assert_float(flat).is_equal(3.0)
	assert_float(up_step).is_equal(5.0)
	assert_float(down_step).is_equal(1.0)
	assert_float(slope).is_equal_approx(5.4, 0.000001)
	assert_float(Step.Stamina.amount(up_step, DT)).is_equal(5.0 * DT)


func test_stair_candidates_observe_slope_height_and_wall() -> void:
	var height := Step.Stairs.search_height(true, true, Vector3.UP, Vector3.UP * 0.25)
	assert_vector(Step.Stairs.candidate(height, 0, 2)).is_equal(height)
	assert_vector(Step.Stairs.candidate(height, 1, 2)).is_equal(Vector3.UP * 0.125)
	assert_float(Step.Stairs.rise(Vector3.UP, Vector3.DOWN * 0.25, 0)).is_equal(0.25)
	assert_bool(is_nan(Step.Stairs.rise(Vector3.RIGHT, Vector3.DOWN, 1))).is_true()
	var descent := Step.Stairs.descent(Vector3.UP, Vector3.DOWN * 0.25, 0.125, 1)
	assert_float(descent).is_equal(-0.25)
	var at_margin := Step.Stairs.descent(Vector3.UP, Vector3.DOWN * 0.125, 0.125, 1)
	assert_bool(is_nan(at_margin)).is_true()
	var along := Step.Stairs.along_wall(Vector3(3, 0, 6), 0.5, Vector3.RIGHT)
	assert_vector(along).is_equal(Vector3(0, 0, 3))


func test_slide_entry_resume_and_timeout() -> void:
	var state := CogitoMovementState.new()
	var next := CogitoMovementState.new()
	Step.Slide.enter(state, Vector2.UP, 1.5, next)
	assert_vector(next.slide_vector).is_equal(Vector2.UP)
	assert_float(next.slide_remaining).is_equal(1.5)
	next.was_sliding = true
	next.slide_remaining = DT
	Step.Slide.enter(next, Vector2.LEFT, 1.5, next)
	assert_vector(next.slide_vector).is_equal(Vector2.UP)
	assert_float(next.slide_remaining).is_equal(DT)
	var sliding := Step.Slide.action(Vector2.UP, true, false, false)
	assert_int(sliding).is_equal(Step.Slide.Action.CONTINUE)
	assert_int(Step.Slide.action(Vector2.UP, true, true, false)).is_equal(Step.Slide.Action.SNEAK)
	assert_float(Step.Jump.slide_velocity(4, 1.3)).is_equal(5.2)


func test_crouch_clearance_shape_threshold_and_landing() -> void:
	assert_bool(Step.Posture.latch(true, true, false)).is_true()
	assert_bool(Step.Posture.latch(true, true, false, true)).is_false()
	assert_bool(Step.Posture.latch(true, false, false)).is_false()
	assert_bool(Step.Posture.crouch_requested(false, true)).is_true()
	assert_bool(Step.Posture.tall_shape_ready(-0.25, -1)).is_false()
	assert_bool(Step.Posture.tall_shape_ready(-0.249, -1)).is_true()
	assert_int(Step.landing(-8.5, -8.5, -6)).is_equal(Step.Landing.HARD)
	assert_int(Step.landing(-6, -8.5, -6)).is_equal(Step.Landing.LAND)
	assert_int(Step.landing(-5.9, -8.5, -6)).is_equal(Step.Landing.NONE)


func test_runs_without_scene_tree() -> void:
	var output := []
	var args := [
		"--headless",
		"--path",
		ProjectSettings.globalize_path("res://"),
		"--script",
		"res://tests/player/movement_step_probe.gd",
	]
	var status := OS.execute(OS.get_executable_path(), args, output, true)
	var log_text := "\n".join(output)
	assert_int(status).is_zero()
	assert_bool("MOVEMENT MAINLOOP PASS" in log_text).override_failure_message(log_text).is_true()
	assert_bool("SCRIPT ERROR" in log_text).is_false()

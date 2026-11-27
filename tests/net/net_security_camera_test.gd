extends "memory_session_suite.gd"
## The Lobby archive button turns the security camera off for every peer.

const LOBBY := "res://addons/cogito/DemoScenes/COGITO_3_Lobby.tscn"
const BUTTON := "ARCHIVE/CameraButton"
const CAMERA := "ARCHIVE/SecurityCamera"


func _lobby(branch: Facade) -> Node3D:
	var host := CogitoLevelHost.new()
	branch.add_child(host)
	var level := host.load_level(LOBBY, &"lobby") as Node3D
	branch.player_world.bind_level(level, Transform3D(Basis.IDENTITY, Vector3.UP), "lobby")
	return level


# The GUI report: pressing the archive button online left the camera running on clients.
func test_archive_button_turns_camera_off_on_client(_timeout := 60000) -> void:
	var server := _branch(1)
	server.start_server({"save_dir": "user://net/lobby-camera"})
	var s_level := _lobby(server)
	var client := _branch(2)
	assert_int(client.join("memory", 1902)).is_equal(OK)
	var c_level := _lobby(client)
	_pump()
	await _ticks(10)
	var s_camera := s_level.get_node(CAMERA) as CogitoSecurityCamera
	var c_camera := c_level.get_node(CAMERA) as CogitoSecurityCamera
	assert_int(c_camera.current_state).is_equal(s_camera.current_state)
	assert_int(s_camera.current_state).is_not_equal(CogitoSecurityCamera.DetectorState.OFFLINE)
	var results: Array[Dictionary] = []
	client.player_world.interactions.result_received.connect(func(r: Dictionary): results.append(r))
	var target := s_level.get_node(BUTTON) as Node3D
	var actor := server.player_world.avatar_for(client.local_player_id()).actor
	actor.global_position = _spot_facing(s_level, target)
	actor.look_at(target.global_position)
	await _ticks(3)
	var comp := c_level.get_node(BUTTON + "/BasicInteraction") as InteractionComponent
	client.player_world.interactions.submit(comp, &"interact", null)
	_pump()
	await _ticks(20)
	assert_bool(results.is_empty()).is_false()
	assert_bool(results.back().ok).override_failure_message(str(results)).is_true()
	assert_int(s_camera.current_state).is_equal(CogitoSecurityCamera.DetectorState.OFFLINE)
	assert_int(c_camera.current_state).is_equal(CogitoSecurityCamera.DetectorState.OFFLINE)
	assert_float(c_camera.indicator_light.light_energy).is_equal(0.0)


# Stand on the floor where a player can see the wall button (its basis is authored lying).
func _spot_facing(level: Node3D, target: Node3D) -> Vector3:
	var space := level.get_world_3d().direct_space_state
	for dir: Vector3 in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]:
		var feet := target.global_position + dir * 0.9
		feet.y = target.global_position.y - 0.85
		var query := PhysicsRayQueryParameters3D.create(
			feet + Vector3.UP * 1.5, target.global_position
		)
		var hit := space.intersect_ray(query)
		if not hit.is_empty() and hit.collider == target:
			return feet
	return target.global_position

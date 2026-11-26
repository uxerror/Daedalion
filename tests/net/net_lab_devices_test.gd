extends "memory_session_suite.gd"

const LAB := "res://addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn"
const CONSOLE := "NavigationRegion3D/ROOM_SYSTEMIC_PROPERTIES/KSI_console_spinner/"
const SPINNER := CONSOLE + "CogitoSpinner/SpinnerInteraction"

var _server: Facade
var _client: Facade
var _s_level: Node3D
var _c_level: Node3D


func _lab(branch: Facade) -> Node3D:
	var host := CogitoLevelHost.new()
	branch.add_child(host)
	var level := host.load_level(LAB, &"lab") as Node3D
	branch.player_world.bind_level(level, Transform3D(Basis.IDENTITY, Vector3.UP), "lab")
	return level


func _open() -> void:
	_server = _branch(1)
	_server.start_server({"save_dir": "user://net/lab-devices"})
	_s_level = _lab(_server)
	_client = _branch(2)
	assert_int(_client.join("memory", 1902)).is_equal(OK)
	_c_level = _lab(_client)
	_pump()
	await _ticks(10)


# GUI report: on joining, the spinner knob was missing; it flew into place on the first spin.
# The baseline replaced the spinner's local knob pose with the interaction node's global pose.
func test_spinner_knob_keeps_its_authored_pose_on_join(_timeout := 60000) -> void:
	await _open()
	var server_knob := (_s_level.get_node(SPINNER) as SpinnerInteraction).rotating_object
	var client_knob := (_c_level.get_node(SPINNER) as SpinnerInteraction).rotating_object
	assert_bool(client_knob.transform.is_equal_approx(server_knob.transform)).is_true()


# GUI report: the knob turned but the meter digits linked to it stayed at 000%.
func test_spinner_meter_digits_follow_on_client(_timeout := 60000) -> void:
	await _open()
	var spinner := _c_level.get_node(SPINNER) as SpinnerInteraction
	var actor := _server.player_world.avatar_for(_client.local_player_id()).actor
	var knob := (_s_level.get_node(SPINNER) as SpinnerInteraction).get_parent() as Node3D
	actor.global_position = knob.global_position - knob.global_basis.z * 0.9 + Vector3.DOWN
	actor.look_at(knob.global_position)
	await _ticks(3)
	_client.player_world.interactions.submit(spinner, &"interact", null)
	_pump()
	await _ticks(5)
	_client.local_player().player_interaction_component.network_interactions.devices.spin(3)
	_pump()
	await _ticks(10)
	var server_meter := _s_level.get_node(CONSOLE + "MeterDisplay") as CogitoMeter
	var client_meter := _c_level.get_node(CONSOLE + "MeterDisplay") as CogitoMeter
	assert_float(server_meter.current_value).is_equal(3.0)
	assert_float(client_meter.current_value).is_equal(3.0)
	assert_str(client_meter.display_label.text).is_equal(server_meter.display_label.text)


# GUI report: shooting barrels showed no effects; their death impact and explosion
# spawned only on the server.
func test_destroyed_barrel_spawns_death_effects_on_client(_timeout := 60000) -> void:
	await _open()
	var barrel := _s_level.get_node("barrel2") as Node3D
	var mirror := _c_level.get_node("barrel2") as Node3D
	var child_count := _c_level.get_child_count()
	var actor := _server.player_world.avatar_for(_client.local_player_id()).actor
	var hitbox := barrel.get_node("HitboxComponent") as HitboxComponent
	for i in 3:
		hitbox.damage(1.0, actor, Vector3.FORWARD, barrel.global_position)
		_pump()
		await _ticks(2)
	await _ticks(5)
	assert_bool(is_instance_valid(mirror) and not mirror.is_queued_for_deletion()).is_false()
	var spawned := _c_level.get_children().slice(child_count - 1).filter(
		func(node: Node) -> bool: return node.scene_file_path.contains("/VFX/")
	)
	assert_int(spawned.size()).is_equal(2)

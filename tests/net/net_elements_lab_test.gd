extends "memory_session_suite.gd"

const LAB := "res://addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn"
const STANDS := "NavigationRegion3D/SYSTEMIC_PROPERTIES/"


func _lab(branch: Facade) -> Node3D:
	var host := CogitoLevelHost.new()
	branch.add_child(host)
	var level := host.load_level(LAB, &"lab") as Node3D
	branch.player_world.bind_level(level, Transform3D(Basis.IDENTITY, Vector3.UP), "lab")
	return level


func _press(client: Facade, level: Node, path: String) -> void:
	# Stand in reach in front of the console, like the GUI player.
	var server: Facade = _branches[0]
	var target := server.player_world.active_level().get_node(STANDS + path) as Node3D
	var actor := server.player_world.avatar_for(client.local_player_id()).actor
	var spot := target.global_position - target.global_basis.z
	spot.y = target.global_position.y - 1.0
	actor.global_position = spot
	actor.look_at(target.global_position)
	await _ticks(3)
	var comp := level.get_node(STANDS + path + "/BasicInteraction") as InteractionComponent
	client.player_world.interactions.submit(comp, &"interact", null)
	_pump()
	await _ticks(20)


# The GUI report: online the stand switches toggled but no fire/frost appeared on clients.
func test_laboratory_stand_switches_show_elements_on_client(_timeout := 60000) -> void:
	var server := _branch(1)
	server.start_server({"save_dir": "user://net/lab-stands"})
	var s_level := _lab(server)
	var client := _branch(2)
	assert_int(client.join("memory", 1902)).is_equal(OK)
	var c_level := _lab(client)
	_pump()
	await _ticks(10)
	var c_fire := c_level.get_node(STANDS + "StandFire/Campfire") as CogitoElementArea
	var s_fire := s_level.get_node(STANDS + "StandFire/Campfire") as CogitoElementArea
	var c_freezer := c_level.get_node(STANDS + "StandCold/Freezer") as CogitoElementArea
	assert_bool(c_fire.enabled).is_equal(s_fire.enabled)
	var before := c_fire.enabled
	await _press(client, c_level, "StandFire/Console/CampfireSwitch")
	assert_bool(s_fire.enabled).is_not_equal(before)
	assert_bool(c_fire.enabled).is_equal(s_fire.enabled)
	for node in c_fire.visuals:
		assert_bool(node.visible).is_equal(c_fire.enabled)
	var frost_before := c_freezer.enabled
	await _press(client, c_level, "StandCold/Console/FreezerSwitch")
	assert_bool(c_freezer.enabled).is_not_equal(frost_before)
	for node in c_freezer.visuals:
		assert_bool(node.visible).is_equal(c_freezer.enabled)

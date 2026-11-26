extends "memory_session_suite.gd"

const LAB := "res://addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn"
const CONSOLE := "NavigationRegion3D/ROOM_SYSTEMIC_PROPERTIES/KSI_console_spinner/"
const SPINNER := CONSOLE + "CogitoSpinner/SpinnerInteraction"
const RIFLE := "NavigationRegion3D/SHOOTING_RANGE/Pickup_LaserRifle"
const DOOR := "SlidingDoor/KSI_door_half"
const STAND := "NavigationRegion3D/SYSTEMIC_PROPERTIES/StandFire/"

var _previous: Node
var _server: Facade
var _client: Facade
var _host: CogitoLevelHost
var _level_root: Node3D
var _dir: String


func before_test() -> void:
	_previous = get_tree().current_scene
	_dir = create_temp_dir("restart-%d" % Time.get_ticks_usec())
	_boot()


func _boot() -> void:
	_host = CogitoLevelHost.new()
	add_child(_host)
	_level_root = _host.load_level(LAB, &"lab") as Node3D
	_level_root.get_node("Player").free()
	_level_root.reparent(get_tree().root)
	get_tree().current_scene = _level_root
	_server = _branch(1, _level_root)
	assert_int(_server.start_server({"save_dir": _dir})).is_equal(OK)
	_server.player_world.bind_level(_level_root, Transform3D(Basis.IDENTITY, Vector3.UP), "lab")


func _join(peer: int) -> Node3D:
	_client = _branch(peer)
	_client.join("lab-test", 1802)
	var host := CogitoLevelHost.new()
	_client.add_child(host)
	var root := host.load_level(LAB, &"lab") as Node3D
	root.get_node("Player").free()
	_client.player_world.bind_level(root, Transform3D(Basis.IDENTITY, Vector3.UP), "lab")
	_pump()
	return root


func after_test() -> void:
	super.after_test()
	get_tree().current_scene = _previous
	_level_root.free()
	_host.free()


func _press_console(actor: CogitoPlayer, path: String) -> void:
	var device := _level_root.get_node(STAND + "Console/" + path) as Node3D
	var spot := device.global_position - device.global_basis.z
	spot.y = device.global_position.y - 1.0
	actor.global_position = spot
	actor.look_at(device.global_position)
	await _ticks(3)
	_use(_client, STAND + "Console/" + path + "/BasicInteraction")
	await _ticks(12)


func test_laboratory_restart(_timeout := 90000) -> void:
	var mirror := _join(2)
	await _ticks(6)
	var id := _client.local_player_id()
	var actor := _server.player_world.avatar_for(id).actor
	actor.position = Vector3(0, 0.1, -10)
	await _ticks(6)
	var pickup := _level_root.get_node(RIFLE + "/ExtendedPickupInteraction") as InteractionComponent
	actor.global_position = pickup.global_position + Vector3(0, -0.5, 0.7)
	await _ticks(3)
	_use(_client, RIFLE + "/ExtendedPickupInteraction", &"press")
	assert_int(actor.inventory_data.find_slots("Laser Rifle").size()).is_equal(1)
	var door := _level_root.get_node(DOOR) as CogitoDoor
	actor.global_position = door.global_position + Vector3(0.8, 0.6, -0.7)
	await _ticks(3)
	_use(_client, DOOR + "/BasicInteraction")
	assert_bool(door.is_open).is_true()
	var spinner := _level_root.get_node(SPINNER) as SpinnerInteraction
	var knob := spinner.get_parent() as Node3D
	actor.global_position = knob.global_position - knob.global_basis.z * 0.9 + Vector3.DOWN
	actor.look_at(knob.global_position)
	await _ticks(3)
	_client.player_world.interactions.submit(mirror.get_node(SPINNER), &"interact")
	_pump()
	await _ticks(5)
	_client.local_player().player_interaction_component.network_interactions.devices.spin(3)
	_pump()
	await _ticks(10)
	var pose := spinner.rotating_object.transform
	var campfire := _level_root.get_node(STAND + "Campfire") as CogitoElementArea
	var initial := campfire.enabled
	await _press_console(actor, "CampfireSwitch")
	var enabled := campfire.enabled
	assert_bool(enabled).is_not_equal(initial)
	await _press_console(actor, "ResetButton")
	var generation: int = _level_root.get_node(STAND).net_state().generation
	assert_int(generation).is_greater(0)
	var barrel := _level_root.get_node("barrel2") as Node3D
	var hitbox := barrel.get_node("HitboxComponent") as HitboxComponent
	for i in 3:
		hitbox.damage(1.0, actor, Vector3.FORWARD, barrel.global_position)
		await _ticks(2)
	var journal := _client.player_world.quests.journal()
	assert_bool(journal.quests.is_empty()).is_false()
	var writer := _server.player_world.persistence
	var now := [100]
	writer.clock = func() -> int: return now[0]
	_client.disconnect_session()
	_pump()
	assert_bool(writer.lives.retained.has(id)).is_true()
	now[0] += writer.checkpoint_msec
	writer.poll(_server.player_world, Engine.get_physics_frames())
	assert_bool(writer.reap(_server.player_world, Time.get_ticks_msec() + 3000)).is_true()
	assert_int(writer.files.manifest.generation).is_equal(1)
	var timing := [
		writer.capture_usec / 1000.0,
		writer.commit_usec / 1000.0,
		(writer.capture_usec + writer.commit_usec) / 1000.0,
	]
	print("LAB CHECKPOINT capture_ms=%.3f commit_ms=%.3f total_ms=%.3f" % timing)
	after_test()
	_boot()
	mirror = _join(7)
	await _ticks(8)
	assert_str(_client.local_player_id()).is_equal(id)
	assert_dict(_client.player_world.quests.journal()).is_equal(journal)
	for root: Node3D in [_level_root, mirror]:
		var linked := root.get_node(STAND + "Campfire") as CogitoElementArea
		assert_bool(linked.enabled).is_equal(enabled)
		for visual in linked.visuals:
			assert_bool(visual.visible).is_equal(enabled)
		assert_int(root.get_node(STAND).net_state().generation).is_equal(generation)
		var restored := root.get_node(SPINNER) as SpinnerInteraction
		assert_bool(restored.rotating_object.transform.is_equal_approx(pose)).is_true()
		var meter := root.get_node(CONSOLE + "MeterDisplay") as CogitoMeter
		assert_float(meter.current_value).is_equal(3.0)
		assert_bool(meter.display_label.text.contains("3")).is_true()
		assert_bool(root.get_node(DOOR).is_open).is_true()
		assert_object(root.get_node_or_null("barrel2")).is_null()
		assert_object(root.get_node_or_null(RIFLE)).is_null()
	for restored: CogitoPlayer in [
		_server.player_world.avatar_for(id).actor, _client.local_player()
	]:
		assert_int(restored.inventory_data.find_slots("Laser Rifle").size()).is_equal(1)

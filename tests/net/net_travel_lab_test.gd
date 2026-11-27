extends "memory_session_suite.gd"

const LOBBY := "res://addons/cogito/DemoScenes/COGITO_3_Lobby.tscn"
const LAB := "res://addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn"
const TO_LAB := "MAIN_LOBBY/LAB_CONNECTOR/TransitionZone_LAB"
const TO_LOBBY := "CONNECTOR_TO_LOBBY/TransitionZone_LOBBY"
const CONSOLE := "NavigationRegion3D/ROOM_SYSTEMIC_PROPERTIES/KSI_console_spinner/"
const SPINNER := CONSOLE + "CogitoSpinner/SpinnerInteraction"

var _previous: Node
var _root: Node3D
var _server: Facade


func before_test() -> void:
	_previous = get_tree().current_scene
	_root = Node3D.new()
	get_tree().root.add_child(_root)
	get_tree().current_scene = _root
	_server = _branch(1, _root)
	_server.start_server({"save_dir": create_temp_dir("travel-lab")})
	assert_int(_server.player_world.travel.start(LOBBY)).is_equal(OK)


func after_test() -> void:
	super.after_test()
	get_tree().current_scene = _previous
	_root.free()
	await get_tree().process_frame
	await get_tree().process_frame


func _arrived(client: Facade, key: String) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		await _ticks(1)
		var endpoint: Node = _server.player_world.travel.levels.get(key)
		if endpoint and endpoint.world.ready_for_events(client.multiplayer.get_unique_id()):
			if endpoint.avatar_for(client.local_player_id()) and client.local_player():
				return true
	return false


func _walk_into(client: Facade, path: String) -> void:
	var endpoint: Node = _server.player_world.travel.endpoint_for(client.local_player_id())
	var actor: CogitoPlayer = endpoint.avatar_for(client.local_player_id()).actor
	var zone: Area3D = endpoint.active_level().get_node(path)
	actor.global_position = zone.global_position
	actor.velocity = Vector3.ZERO
	endpoint.mark_teleport(client.local_player_id())


func test_real_doors_keep_lab_console_quest_and_inventory(_timeout := 120000) -> void:
	var a := _branch(2)
	var b := _branch(3)
	a.join("memory", 2910)
	b.join("memory", 2911)
	assert_bool(await _arrived(a, LOBBY)).is_true()
	assert_bool(await _arrived(b, LOBBY)).is_true()
	var stayed := b.local_player()
	var travel: Node = _server.player_world.travel
	var epoch: int = travel.levels[LOBBY].world.entities.epoch
	var hints: Array[String] = []
	b.travel_notification.connect(func(event: Dictionary): hints.append(event.text))
	_walk_into(a, TO_LAB)
	assert_bool(await _arrived(a, LAB)).is_true()
	assert_object(b.local_player()).is_same(stayed)
	assert_int(travel.levels[LOBBY].world.entities.epoch).is_equal(epoch)
	assert_int(a.player_world.travel.levels.size()).is_equal(1)
	assert_int(travel.levels.size()).is_equal(2)
	var endpoint: Node = travel.levels[LAB]
	var actor: CogitoPlayerAdvanced = endpoint.avatar_for(a.local_player_id()).actor
	var spinner: SpinnerInteraction = endpoint.active_level().get_node(SPINNER)
	actor.global_position = spinner.global_position - spinner.global_basis.z * 0.9 + Vector3.DOWN
	await _ticks(4)
	var replica: Node = a.player_world.travel.levels[LAB]
	replica.interactions.submit(replica.active_level().get_node(SPINNER), &"interact")
	_pump()
	replica.interactions.devices.spin(3)
	await _ticks(8)
	var rifle_path := "NavigationRegion3D/SHOOTING_RANGE/Pickup_LaserRifle/ExtendedPickupInteraction"
	var pickup: Node3D = endpoint.active_level().get_node(rifle_path)
	actor.global_position = pickup.global_position + Vector3(0, -0.5, 0.7)
	await _ticks(4)
	replica.interactions.submit(replica.active_level().get_node(rifle_path), &"press")
	await _ticks(3)
	actor.player_currencies.credits.set_currency(37, 100)
	endpoint.quests.set_world_flags({"TravelLab": 1})
	_pump()
	assert_int(b.player_world.quests.journal().flags.TravelLab).is_equal(1)
	_walk_into(b, TO_LAB)
	assert_bool(await _arrived(b, LAB)).is_true()
	var meter: CogitoMeter = endpoint.active_level().get_node(CONSOLE + "MeterDisplay")
	assert_float(meter.current_value).is_equal(3.0)
	var observer: Node = b.player_world.travel.levels[LAB]
	var display: CogitoMeter = observer.active_level().get_node(CONSOLE + "MeterDisplay")
	assert_float(display.current_value).is_equal(3.0)
	_walk_into(a, TO_LOBBY)
	assert_bool(await _arrived(a, LOBBY)).is_true()
	assert_int(a.local_player().inventory_data.find_slots("Laser Rifle").size()).is_equal(1)
	assert_float(a.local_player().player_currencies.credits.value_current).is_equal(37.0)
	assert_int(travel.levels[LOBBY].world.entities.epoch).is_equal(epoch)
	assert_int(hints.size()).is_equal(2)
	assert_bool(endpoint.peer_in_level(2)).is_false()
	assert_bool(endpoint.peer_in_level(3)).is_true()

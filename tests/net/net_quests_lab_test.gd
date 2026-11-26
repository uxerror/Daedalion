extends "memory_session_suite.gd"

const LAB := "res://addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn"
const RANGE_PATH := "NavigationRegion3D/SHOOTING_RANGE/"
const TARGETS := RANGE_PATH + "TARGETS"
const RIFLE := RANGE_PATH + "Pickup_LaserRifle/ExtendedPickupInteraction"
const STATE := CogitoQuest.QuestState

var _previous: Node
var _host: CogitoLevelHost
var _server: Facade
var _level_root: Node3D


class RifleInput:
	extends CogitoPlayerInputSource
	var pitch := 0.0
	var firing := false

	func sample(actor: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
		var command := super.sample(actor, sequence)
		command.pitch = pitch
		command.yaw = 0.0
		if firing:
			command.held = 1 << CogitoPlayerCommand.Action.PRIMARY
		return command


func before_test() -> void:
	_previous = get_tree().current_scene
	_host = CogitoLevelHost.new()
	add_child(_host)
	_level_root = _host.load_level(LAB, &"lab") as Node3D
	_level_root.get_node("Player").free()
	_level_root.reparent(get_tree().root)
	get_tree().current_scene = _level_root
	_server = _branch(1, _level_root)
	_server.start_server({"save_dir": "user://net/quest-lab"})
	_server.player_world.bind_level(_level_root, Transform3D(Basis.IDENTITY, Vector3.UP), "lab")


func after_test() -> void:
	super.after_test()
	get_tree().current_scene = _previous
	_level_root.free()
	_host.free()


func _load_lab(branch: Facade, host: CogitoLevelHost) -> Node3D:
	var level := host.load_level(LAB, &"lab") as Node3D
	# The production bootstrap consumes the authored Player as a marker on entering the level.
	level.get_node("Player").free()
	branch.player_world.bind_level(level, Transform3D(Basis.IDENTITY, Vector3.UP), "lab")
	return level


func test_client_rifle_completes_five_authored_targets(_timeout := 90000) -> void:
	var client := _branch(2)
	client.join("memory", 1902)
	var client_host := CogitoLevelHost.new()
	client.add_child(client_host)
	var client_lab := _load_lab(client, client_host)
	var observer := _branch(3)
	observer.join("memory", 1903)
	# A different level still receives all six shared events.
	_level(observer, "elsewhere")
	_pump()
	var events: Array[StringName] = []
	observer.player_world.quests.notified.connect(
		func(event: StringName, _quest: CogitoQuest): events.append(event)
	)
	var actor := _server.player_world.avatar_for(client.local_player_id()).actor
	var input := RifleInput.new()
	client.local_player().input_source = input
	var starter := _level_root.get_node("TargetPractice_QuestStarter") as CogitoQuestUpdater
	actor.position = Vector3(0, 0.1, -10)
	await _ticks(6)
	assert_array(events).contains_exactly([&"start"])
	var pickup := _level_root.get_node(RIFLE) as InteractionComponent
	actor.global_position = pickup.global_position + Vector3(0, -0.5, 0.7)
	await _ticks(3)
	client.player_world.interactions.submit(client_lab.get_node(RIFLE), &"press")
	_pump()
	var inventory := client.player_world.inventory
	var rifles := inventory.local.data.find_slots("Laser Rifle")
	assert_int(rifles.size()).is_equal(1)
	if rifles.is_empty():
		return
	var stack: InventorySlotPD = rifles[0]
	inventory.submit("use", [stack.origin_index, inventory.local.id_of(stack)])
	_pump()
	for target: Node3D in _level_root.get_node(TARGETS).get_children():
		actor.position = target.position + Vector3(0, 0, 2)
		actor.position.y = 0.1
		actor.velocity = Vector3.ZERO
		_server.player_world.mark_teleport(client.local_player_id())
		await _ticks(6)
		var aim := actor.get_aim_transform().origin.direction_to(target.global_position)
		input.pitch = asin(aim.y)
		input.firing = true
		await _ticks(24)
		input.firing = false
	assert_int(_server.player_world.quests.world.flags.get("TargetsShot", 0)).is_equal(5)
	var journal := observer.player_world.quests.journal()
	var row: Dictionary = journal.quests[starter.quest_to_update.resource_path]
	assert_int(row.state).is_equal(STATE.Completed)
	assert_array(events).contains_exactly(
		[&"start", &"update", &"update", &"update", &"update", &"complete"]
	)

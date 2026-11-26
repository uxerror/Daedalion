extends "memory_session_suite.gd"

const TargetQuest := preload(
	"res://addons/cogito/QuestSystem/Quests/DemoSceneQuests/Demo_TargetPractice.tres"
)
const PersonalQuest := preload("personal_quest.tres")
const LaptopQuest := preload(
	"res://addons/cogito/QuestSystem/Quests/DemoSceneQuests/Demo_StealLaptop.tres"
)
const LaptopItem := preload("res://addons/cogito/InventoryPD/Items/Cogito_LaptopReal.tres")
const Grid := preload("res://addons/cogito/Networking/net_grid.gd")
const OP := CogitoQuestUpdater.UpdateType
const STATE := CogitoQuest.QuestState
const OBJECTIVE := CogitoQuestObjective.ObjectiveState

var _previous: Node
var _scene: Node3D
var _server: Facade
var _owner: Facade
var _other: Facade


func before_test() -> void:
	_previous = get_tree().current_scene
	_scene = preload("process_arena.tscn").instantiate()
	get_tree().root.add_child(_scene)
	get_tree().current_scene = _scene
	_server = _branch(1, _scene)
	_server.host({"save_dir": "user://net/mp8", "respawn_delay": 0.0})
	_server.player_world.bind_level(_scene, Transform3D(Basis.IDENTITY, Vector3.UP), "arena")
	_owner = _observer(2)
	_other = _observer(3)


func after_test() -> void:
	super.after_test()
	get_tree().current_scene = _previous
	_scene.free()


func _listen(branch: Facade) -> Array[StringName]:
	var events: Array[StringName] = []
	branch.player_world.quests.notified.connect(
		func(event: StringName, _quest: CogitoQuest): events.append(event)
	)
	return events


func _flag(key: String, value: Variant) -> WorldFlag:
	var flag := WorldFlag.new()
	flag.flag_name = key
	flag.value = value
	return flag


func test_one_shot_update_recipients_and_property_setter() -> void:
	var api := _server.player_world.quests
	var events := _listen(_owner)
	var other_events := _listen(_other)
	var host_events := _listen(_server)
	var original := TargetQuest.quest_objectives[0].objective_state
	var trigger: CogitoQuestUpdater = _server.player_world.active_level().get_node("Door/DoorQuest")
	var replica: CogitoQuestUpdater = _owner.player_world.active_level().get_node("Door/DoorQuest")
	replica.update_quest(_owner.local_player())
	assert_dict(api.world.quests).is_empty()
	trigger.world_flag = [_flag("TargetsShot", 1)]
	trigger.update_quest(_server.local_player())
	trigger.update_quest(_server.player_world.avatar_for(_owner.local_player_id()).actor)
	assert_int(api.world.flags.TargetsShot).is_equal(1)
	api.advance(TargetQuest, OP.Update, [_flag("TargetsShot", 4)])
	_pump()
	for received: Array in [events, other_events, host_events]:
		assert_array(received).contains_exactly([&"start", &"update", &"complete"])
	var row: Dictionary = _other.player_world.quests.journal().quests[TargetQuest.resource_path]
	assert_int(row.state).is_equal(STATE.Completed)
	assert_int(TargetQuest.quest_objectives[0].objective_state).is_equal(original)
	for branch in [_owner, _server]:
		var setter := CogitoWorldPropertySetter.new()
		branch.player_world.active_level().add_child(setter)
		setter.properties_to_set_ON = {"mp8_power": true}
		setter.on_void_signal()
		setter.on_bool_signal(true)
		if branch == _owner:
			assert_bool(api.world.flags.has("mp8_power")).is_false()
	_pump()
	assert_int(api.world.revision).is_equal(4)
	assert_bool(_other.player_world.quests.journal().flags.mp8_power).is_true()
	assert_int(other_events.size()).is_equal(3)


func test_owner_packets_takeover_respawn_and_silent_baselines() -> void:
	var api := _server.player_world.quests
	var owner_events := _listen(_owner)
	var host_events := _listen(_server)
	var other_events := _listen(_other)
	var cues: Array[AudioStream] = []
	var settings := CogitoGlobals.cogito_settings
	var on_sound := func(node: Node):
		var expected := [
			settings.quest_start_sound, settings.quest_complete_sound, settings.quest_failed_sound
		]
		if node is AudioStreamPlayer and node.stream in expected:
			cues.append(node.stream)
	CogitoAudio.child_entered_tree.connect(on_sound)
	var transport: MemoryPeer = _network[1]
	transport.capture = true
	var id := _owner.local_player_id()
	api.advance(PersonalQuest, OP.Start, [], id)
	api.advance(PersonalQuest, OP.Fail, [], id)
	_pump()
	assert_array(owner_events).contains_exactly([&"start", &"fail"])
	assert_array(host_events).is_empty()
	assert_array(other_events).is_empty()
	var packets := 0
	var bytes := 0
	var needle := PersonalQuest.resource_path.to_utf8_buffer().hex_encode()
	for i in transport.sent.size():
		if transport.sent[i].hex_encode().contains(needle):
			packets += 1
			bytes += transport.sent[i].size()
			assert_int(transport.destinations[i]).is_equal(2)
	assert_int(packets).is_equal(2)
	print("MP8 personal start + fail: %d RPC bytes in %d packets" % [bytes, packets])
	var players := _server.player_world
	var avatar := players.avatar_for(id)
	avatar.actor.decrease_attribute("health", 100)
	assert_str(players.death.try_respawn(id, avatar.lifetime)).is_empty()
	_pump()
	var saved := api.personal[id].capture()
	assert_array(cues).contains_exactly(
		[settings.quest_start_sound, settings.quest_complete_sound, settings.quest_failed_sound]
	)
	assert_int(saved.quests[PersonalQuest.resource_path].state).is_equal(STATE.Failed)
	assert_dict(_owner.player_world.quests.journal(true).quests).is_equal(saved.quests)
	assert_dict(_server.player_world.quests.journal(true).quests).is_empty()
	assert_dict(_other.player_world.quests.journal(true).quests).is_empty()
	for peer in [4, 5]:
		var replacement := _branch(peer)
		replacement.join("memory", 1802)
		var events := _listen(replacement)
		_level(replacement, "outside")
		_pump()
		assert_str(replacement.local_player_id()).is_equal(id)
		assert_dict(replacement.player_world.quests.journal(true).quests).is_equal(saved.quests)
		assert_dict(api.personal[id].capture()).is_equal(saved)
		assert_array(events).is_empty()
		var original_level := replacement.player_world.active_level()
		original_level.get_parent().get_parent().free()
		_level(replacement, "re-entry")
		_pump()
		assert_dict(replacement.player_world.quests.journal(true).quests).is_equal(saved.quests)
		assert_array(events).is_empty()
		replacement.disconnect_session()
		_pump()
	assert_int(cues.size()).is_equal(3)
	CogitoAudio.child_entered_tree.disconnect(on_sound)


func test_inventory_eligibility_latching_and_disconnected_uniqueness() -> void:
	var api := _server.player_world.quests
	var id := _owner.local_player_id()
	var actor := _server.player_world.avatar_for(id).actor
	var stack := InventorySlotPD.new()
	stack.inventory_item = LaptopItem
	stack.quantity = 1
	assert_int(Grid.insert(actor.inventory_data, stack, 1, false)).is_equal(1)
	var shared := api.evaluation_context(CogitoQuest.Scope.SHARED, _other.local_player_id())
	var own := api.evaluation_context(CogitoQuest.Scope.PERSONAL, id)
	var stranger := api.evaluation_context(CogitoQuest.Scope.PERSONAL, _other.local_player_id())
	var condition := LaptopQuest.quest_objectives[0].completion_flags[0]
	assert_bool(condition.meets_in_context({}, own)).is_true()
	assert_bool(condition.meets_in_context({}, stranger)).is_false()
	assert_bool(condition.meets_in_context({}, shared)).is_true()
	api.party_inventory_policy = func(_items: Array[InventoryItemPD], _ctx: CogitoQuestContext):
		return false
	assert_bool(api.evaluation_context(CogitoQuest.Scope.SHARED, id).holds(LaptopItem)).is_false()
	api.party_inventory_policy = Callable()
	api.advance(LaptopQuest, OP.Start)
	api.advance(LaptopQuest, OP.Update, [], _other.local_player_id())
	var key := LaptopQuest.quest_objectives[0].resource_path
	var row: Dictionary = api.world.quests[LaptopQuest.resource_path]
	assert_int(row.objectives[key]).is_equal(OBJECTIVE.Completed)
	var held := actor.inventory_data.find_slots(LaptopItem.name)[0]
	Grid.spend(actor.inventory_data, held, 1)
	api.advance(LaptopQuest, OP.Update)
	row = api.world.quests[LaptopQuest.resource_path]
	assert_int(row.objectives[key]).is_equal(OBJECTIVE.Completed)
	Grid.insert(actor.inventory_data, stack, 1, false)
	_owner.disconnect_session()
	_pump()
	var current := api.evaluation_context(CogitoQuest.Scope.SHARED, _other.local_player_id())
	assert_bool(condition.meets_in_context({}, current)).is_false()
	assert_bool(_server.player_world.inventory.owns(LaptopItem)).is_true()
	var level := _server.player_world.active_level()
	var pickup: PickupComponent = level.get_node("LooseItem/PickupComponent")
	pickup.slot_data = stack.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	pickup.slot_data.inventory_item.is_unique = true
	var result := _server.player_world.spawner.collect(
		pickup, _server.local_player().player_interaction_component, false
	)
	assert_bool(result.ok).is_false()
	api.advance(LaptopQuest, OP.Update, [_flag("LaptopDelivered", true)])
	_pump()
	assert_int(api.world.quests[LaptopQuest.resource_path].state).is_equal(STATE.Completed)
	var observed: Dictionary = _other.player_world.quests.journal().quests[
		LaptopQuest.resource_path
	]
	assert_int(observed.state).is_equal(STATE.Completed)


func test_public_quest_loot_uses_world_progress() -> void:
	var generator := LootGenerator.new()
	_server.player_world.active_level().add_child(generator)
	var table := LootTable.new()
	var entry := LootDropEntry.new()
	entry.droptype = LootDropEntry.DropType.QUEST
	entry.inventory_item = LaptopItem
	entry.quest_definition = TargetQuest
	table.drops = [entry]
	assert_array(generator.generate(table, 1)).is_empty()
	_server.player_world.quests.advance(TargetQuest, OP.Start)
	var rolled := generator.generate(table, 2)
	assert_int(rolled.size()).is_equal(1)
	assert_object(rolled[0].inventory_item).is_same(LaptopItem)
	assert_int(rolled[0].quantity_max).is_equal(1)


func _delivery_content(branch: Facade, fake: bool) -> void:
	var prefix := "res://addons/cogito/DemoScenes/DemoPrefabs/"
	var laptop_scene: PackedScene = load(prefix + ("laptop.tscn" if fake else "laptop_real.tscn"))
	var laptop := laptop_scene.instantiate() as RigidBody3D
	var fridge_scene: PackedScene = load(prefix + "kitchen_fridge_container.tscn")
	var fridge := fridge_scene.instantiate() as CogitoContainer
	var level := branch.player_world.active_level()
	laptop.name = "Laptop"
	laptop.freeze = true
	laptop.position = Vector3(45, 1, 5)
	fridge.name = "Fridge"
	fridge.position = Vector3(50, 0, 5)
	level.add_child(laptop)
	level.add_child(fridge)
	for object: Node in [laptop, fridge]:
		branch.player_world.world.entities.register_runtime(String(object.name), object)


func test_lobby_pickup_and_fridge_delivery(
	fake: bool, _test_parameters := [[false], [true]]
) -> void:
	for branch in [_server, _owner, _other]:
		_delivery_content(branch, fake)
	var actor := _server.player_world.avatar_for(_owner.local_player_id()).actor
	var events := _listen(_other)
	actor.position = Vector3(45, 0.1, 5.8)
	await _ticks(3)
	_use(_owner, "Laptop/PickupComponent")
	assert_array(events).contains_exactly([&"start", &"update"])
	var inventory := _owner.player_world.inventory
	var stacks := inventory.local.data.find_slots("Laptop" if fake else "CEOs Laptop")
	assert_int(stacks.size()).is_equal(1)
	if stacks.is_empty():
		return
	actor.position = Vector3(50.5, 0.1, 6.2)
	await _ticks(3)
	_use(_owner, "Fridge/BasicInteraction")
	var box := _owner.player_world.containers
	assert_object(box.local).is_not_null()
	if not box.local:
		return
	var stack := stacks[0]
	inventory.submit(
		"put",
		[stack.origin_index, inventory.local.id_of(stack), 0, 1, 0, box.token, box.local.revision]
	)
	_pump()
	inventory.submit("close", [box.token, box.local.revision])
	await _ticks(3)
	var expected := STATE.Failed if fake else STATE.Completed
	assert_int(_server.player_world.quests.state_of(LaptopQuest)).is_equal(expected)
	var last_event := &"fail" if fake else &"complete"
	assert_array(events).contains_exactly([&"start", &"update", last_event])


func test_party_and_group_needs_one_holder() -> void:
	var players := _server.player_world
	var actor := players.avatar_for(_owner.local_player_id()).actor
	var first := InventorySlotPD.new()
	first.inventory_item = LaptopItem
	var second := InventorySlotPD.new()
	second.inventory_item = preload("res://addons/cogito/InventoryPD/Items/Cogito_Laptop.tres")
	Grid.insert(actor.inventory_data, first, 1, false)
	Grid.insert(_server.local_player().inventory_data, second, 1, false)
	var group := MultiFlagGroup.new()
	for slot in [first, second]:
		var condition := InventoryFlag.new()
		condition.expected_item = slot.inventory_item
		group.flags.append(condition)
	var context := players.quests.evaluation_context(CogitoQuest.Scope.SHARED, "")
	assert_bool(group.meets_in_context({}, context)).is_false()
	Grid.insert(actor.inventory_data, second, 1, false)
	assert_bool(group.meets_in_context({}, context)).is_true()

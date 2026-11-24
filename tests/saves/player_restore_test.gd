extends "res://tests/saves/slot_fixture.gd"

const PISTOL := preload("res://addons/cogito/InventoryPD/Items/Cogito_Pistol.tres")
const DISPLAY := preload("res://addons/cogito/Components/UI/UI_AttributeDisplay.tscn")

# This runtime test probe is never edited as an objective resource in the inspector.
@warning_ignore("missing_tool")


class GroupCondition:
	extends SingleFlagGroup
	var checked_groups: Array[int] = []

	func meets_criteria(quest_flags: Dictionary) -> bool:
		checked_groups = [
			CogitoQuestManager.active.quests.size(),
			CogitoQuestManager.completed.quests.size(),
			CogitoQuestManager.failed.quests.size(),
		]
		return quest_flags.get("door_open", false)


var _player: CogitoPlayerAdvanced


func before_test() -> void:
	super()
	_player = (load(LEVEL) as PackedScene).instantiate()
	_player.inventory_data = _player.inventory_data.duplicate(true)
	get_tree().current_scene.add_child(_player)
	manager._current_scene_path = LEVEL
	await get_tree().process_frame


func after_test() -> void:
	CogitoQuestManager.reset_playthrough()
	super()


func _snapshot() -> CogitoPlayerState:
	var state := _player.create_new_state()
	state.populate_save_data(_player, "A")
	return state


func _stack(item: InventoryItemPD, index: int) -> InventorySlotPD:
	var stack := InventorySlotPD.new()
	stack.create(item, 1)
	stack.origin_index = index
	return stack


func test_magazines_and_equipped_ammo_survive_load() -> void:
	# External definitions reopen at defaults. The separate magazine rows must win.
	var guns: Array[WieldableItemPD] = []
	var inventory := _player.inventory_data
	for i in 2:
		var path := manager.cogito_state_dir.path_join("gun%d.tres" % i)
		assert_int(ResourceSaver.save(PISTOL.duplicate(), path)).is_equal(OK)
		var gun: WieldableItemPD = load(path)
		gun.current_ammo_type = i
		gun.charge_current = 3.0 + i
		guns.append(gun)
		inventory.inventory_slots[i] = _stack(gun, i)
	inventory.assigned_quickslots = [null, inventory.inventory_slots[1]]
	_player.player_interaction_component.equipped_wieldable_item = guns[1]
	var state := _snapshot()
	assert_int(state.write_state("A")).is_equal(OK)
	for gun in guns:
		gun.charge_current = 0
		gun.current_ammo_type = 1 - gun.current_ammo_type
	manager.load_player_state(_player, "A")
	await get_tree().process_frame
	for i in 2:
		assert_int(guns[i].current_ammo_type).is_equal(i)
		assert_float(guns[i].charge_current).is_equal(3.0 + i)
	var restored := _player.inventory_data
	assert_object(restored.assigned_quickslots[1]).is_same(restored.inventory_slots[1])
	var equipped := _player.player_interaction_component.equipped_wieldable_node
	assert_object(equipped.item_reference).is_same(guns[1])
	assert_int(equipped.current_ammo_type).is_equal(1)


func test_zero_health_refreshes_ui_without_damage_or_second_death() -> void:
	var health: CogitoHealthAttribute = _player.player_attributes.health
	var display: CogitoAttributeDisplay = DISPLAY.instantiate()
	_player.add_child(display)
	display.initiate_interface_ui(health)
	health.restore_attribute(0.0, 135.0)
	var state := _snapshot()
	state.player_attributes["removed_attribute"] = Vector2(1, 10)
	state.player_currencies["removed_currency"] = Vector2(1, 10)
	assert_int(state.write_state("A")).is_equal(OK)
	health.restore_attribute(100.0, 100.0)
	monitor_signals(health, false)
	var observed: Array[float] = []
	_player.player_state_loaded.connect(func() -> void: observed.append(health.value_current))
	for _repeat in 2:
		manager.load_player_state(_player, "A")
	assert_array(observed).contains_exactly([0.0, 0.0])
	assert_float(health.value_max).is_equal(135.0)
	assert_bool(_player.is_dead).is_true()
	assert_str(display.attribute_label_current.text).is_equal("0")
	assert_str(display.attribute_label_max.text).is_equal("135")
	await assert_no_health_effects(health)
	assert_bool(_player.player_hud.get_node("DeathScreen").visible).is_false()


func test_missing_stacks_quickslots_and_wieldable() -> void:
	var state := _snapshot()
	var lost := InventorySlotPD.new()
	state.player_inventory.inventory_slots = [null, lost]
	state.player_quickslots = [lost, null]
	state.saved_wieldable_charges = [null, {}, {"resource": null, "charge_current": 3}]
	state.interaction_component_state = [
		null, {"equipped_wieldable_item": null, "is_wielding": true}
	]
	manager._apply_player_state(_player, state)
	await get_tree().process_frame
	var inventory := _player.inventory_data
	assert_array(inventory.inventory_slots).contains_exactly([null, null])
	assert_object(inventory.assigned_quickslots[0]).is_null()
	assert_bool(_player.player_interaction_component.is_wielding).is_false()


func test_quest_groups_and_flags_restore_without_audio_or_transitions() -> void:
	var flag := BooleanFlag.new()
	flag.flag_name = "door_open"
	var condition := SingleFlagGroup.new()
	condition.flag = flag
	var objective := CogitoQuestObjective.new()
	var order := GroupCondition.new()
	objective.completion_flags = [order]
	var quest := CogitoQuest.new()
	quest.quest_objectives = [objective]
	var completed := CogitoQuest.new()
	var failed := CogitoQuest.new()
	var sound := AudioStreamGenerator.new()
	quest.audio_on_start = sound
	completed.audio_on_complete = sound
	failed.audio_on_fail = sound
	var legacy := _snapshot()
	legacy.player_active_quests = [quest]
	legacy.player_completed_quests = [completed]
	legacy.player_failed_quests = [failed]
	legacy.world_dictionary = {"door_open": true}
	legacy.player_active_quest_progression = {"old_counter": 7}
	var sounds: Array[Node] = []
	var observe_audio := func(node: Node) -> void: sounds.append(node)
	CogitoAudio.child_entered_tree.connect(observe_audio)
	manager._apply_player_state(_player, legacy)
	assert_array(order.checked_groups).contains_exactly([1, 1, 1])
	objective.completion_flags = [condition]
	assert_array(CogitoQuestManager.active.quests).contains_exactly([quest])
	assert_int(quest.quest_state).is_equal(CogitoQuest.QuestState.Active)
	assert_int(completed.quest_state).is_equal(CogitoQuest.QuestState.Completed)
	assert_int(failed.quest_state).is_equal(CogitoQuest.QuestState.Failed)
	assert_int(objective.objective_state).is_equal(CogitoQuestObjective.ObjectiveState.Completed)
	assert_dict(_player.saved_quest_progression).is_equal({"old_counter": 7})
	# A v2 snapshot preserves sticky progress even after its flag changes.
	manager._current_world_dict.door_open = false
	var saved := _snapshot()
	assert_int(saved.write_state("A")).is_equal(OK)
	legacy.world_dictionary.clear()
	manager._apply_player_state(_player, legacy)
	assert_int(objective.objective_state).is_equal(CogitoQuestObjective.ObjectiveState.Active)
	manager.load_player_state(_player, "A")
	var loaded := CogitoQuestManager.active.quests[0]
	assert_int(loaded.quest_state).is_equal(CogitoQuest.QuestState.Active)
	var progress := loaded.quest_objectives[0].objective_state
	assert_int(progress).is_equal(CogitoQuestObjective.ObjectiveState.Completed)
	assert_dict(manager._current_world_dict).is_equal({"door_open": false})
	CogitoAudio.child_entered_tree.disconnect(observe_audio)
	assert_array(sounds).is_empty()


func test_lost_ammo_before_selected_type_does_not_shift_magazine_again() -> void:
	var lost_path := manager.cogito_state_dir.path_join("removed_ammo.tres")
	assert_int(ResourceSaver.save(AmmoItemPD.new(), lost_path)).is_equal(OK)
	var gun := PISTOL.duplicate() as WieldableItemPD
	gun.ammo_types = [load(lost_path), PISTOL.ammo_types[0], PISTOL.ammo_types[1]]
	gun.current_ammo_type = 1
	gun.charge_current = 5
	_player.inventory_data.inventory_slots[0] = _stack(gun, 0)
	var state := _snapshot()
	assert_int(state.write_state("A")).is_equal(OK)
	assert_int(DirAccess.remove_absolute(lost_path)).is_equal(OK)
	manager.load_player_state(_player, "A")
	var restored := _player.inventory_data.inventory_slots[0].inventory_item as WieldableItemPD
	assert_object(restored.get_current_ammo()).is_same(PISTOL.ammo_types[0])
	assert_int(restored.current_ammo_type).is_zero()
	assert_float(restored.charge_current).is_equal(5.0)

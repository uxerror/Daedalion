extends "res://tests/saves/slot_fixture.gd"

const PISTOL: WieldableItemPD = preload("res://addons/cogito/InventoryPD/Items/Cogito_Pistol.tres")
const QUESTS := [
	preload("res://addons/cogito/QuestSystem/Quests/DemoSceneQuests/Demo_AccessArchive.tres"),
	preload("res://addons/cogito/QuestSystem/Quests/DemoSceneQuests/Demo_TargetPractice.tres"),
	preload("res://addons/cogito/QuestSystem/Quests/DemoSceneQuests/Demo_StealLaptop.tres"),
]
const LOOT := preload("res://addons/cogito/Components/LootTables/LootTable_Test.tres")

var item_path: String
var moved_path: String
var item_uid: int


func before_test() -> void:
	super()
	item_path = manager.cogito_state_dir.path_join("original.tres")
	moved_path = manager.cogito_state_dir.path_join("renamed.tres")
	item_uid = ResourceUID.create_id()
	var item := InventoryItemPD.new()
	item.name = "Move me"
	assert_int(ResourceSaver.save(item, item_path)).is_equal(OK)
	assert_int(ResourceSaver.set_uid(item_path, item_uid)).is_equal(OK)
	ResourceUID.add_id(item_uid, item_path)


func after_test() -> void:
	if ResourceUID.has_id(item_uid):
		ResourceUID.remove_id(item_uid)
	for path: String in [item_path, moved_path]:
		if FileAccess.file_exists(path):
			assert_int(DirAccess.remove_absolute(path)).is_equal(OK)
	super()


func add_stack(state: CogitoPlayerState) -> void:
	var stack := InventorySlotPD.new()
	stack.inventory_item = load(item_path)
	stack.quantity = 7
	stack.origin_index = 0
	state.player_inventory.inventory_slots = [stack]
	state.player_quickslots = [stack]


func rename_item() -> void:
	assert_int(DirAccess.rename_absolute(item_path, moved_path)).is_equal(OK)
	ResourceUID.set_id(item_uid, moved_path)


func test_legacy_player_fails_after_item_rename() -> void:
	var state := make_slot("legacy")
	add_stack(state)
	var path := manager.legacy_player_file("legacy")
	assert_int(ResourceSaver.save(state, path)).is_equal(OK)
	assert_array(Array(ResourceLoader.get_dependencies(path))).contains([item_path])
	state = null
	rename_item()
	assert_object(ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)).is_null()


func test_uid_wins_after_rename_even_if_old_path_reused() -> void:
	var state := make_slot("B")
	add_stack(state)
	assert_int(state.write_state("B")).is_equal(OK)
	state = null
	rename_item()
	var replacement := InventoryItemPD.new()
	replacement.name = "Replacement"
	assert_int(ResourceSaver.save(replacement, item_path)).is_equal(OK)
	var prepared := manager.prepare_slot("B")
	assert_int(prepared.status).is_equal(manager.SlotStatus.OK)
	assert_array(prepared.warnings).is_empty()
	var stack := prepared.player.player_inventory.inventory_slots[0]
	assert_str(stack.inventory_item.resource_path).is_equal(moved_path)
	assert_str(stack.inventory_item.name).is_equal("Move me")
	assert_int(stack.quantity).is_equal(7)
	assert_object(prepared.player.player_quickslots[0]).is_same(stack)


func test_unknown_uid_uses_original_path() -> void:
	var state := make_slot("B")
	add_stack(state)
	assert_int(state.write_state("B")).is_equal(OK)
	state = null
	ResourceUID.remove_id(item_uid)
	var prepared := manager.prepare_slot("B")
	assert_int(prepared.status).is_equal(manager.SlotStatus.OK)
	assert_array(prepared.warnings).is_empty()
	assert_str(prepared.player.player_quickslots[0].inventory_item.resource_path).is_equal(
		item_path
	)


func test_deleted_item_and_quest_leave_other_entries_intact() -> void:
	var state := make_slot("B")
	add_stack(state)
	var keep := InventorySlotPD.new()
	keep.inventory_item = PISTOL
	state.player_inventory.inventory_slots.append(keep)
	state.player_quickslots.append(keep)
	var quest_path := manager.cogito_state_dir.path_join("lost_quest.tres")
	assert_int(ResourceSaver.save(CogitoQuest.new(), quest_path)).is_equal(OK)
	state.player_active_quests = [load(quest_path), QUESTS[0]]
	assert_int(state.write_state("B")).is_equal(OK)
	assert_int(DirAccess.remove_absolute(item_path)).is_equal(OK)
	assert_int(DirAccess.remove_absolute(quest_path)).is_equal(OK)
	var prepared := manager.prepare_slot("B")
	assert_int(prepared.status).is_equal(manager.SlotStatus.OK)
	assert_array(prepared.player.player_active_quests).contains_exactly([QUESTS[0]])
	assert_object(prepared.player.player_inventory.inventory_slots[0]).is_null()
	assert_object(prepared.player.player_quickslots[0]).is_null()
	assert_object(prepared.player.player_inventory.inventory_slots[1].inventory_item).is_same(
		PISTOL
	)
	assert_object(prepared.player.player_quickslots[1].inventory_item).is_same(PISTOL)
	assert_array(prepared.warnings).has_size(2)
	var missing := {
		"path": item_path,
		"uid": ResourceUID.id_to_text(item_uid),
		"field": "player.player_inventory.inventory_slots[0].inventory_item",
	}
	assert_array(prepared.warnings).contains([missing])


func test_player_and_scene_data_round_trip() -> void:
	var state := make_slot("B")
	add_stack(state)
	var stack := state.player_quickslots[0]
	state.player_inventory.inventory_slots.append(stack)
	state.player_inventory.first_slot = stack
	state.player_inventory.grid = true
	state.player_position = Vector3(-1.5, 6.25, 0)
	state.player_transform = Transform3D(Basis.IDENTITY, state.player_position)
	state.saved_wieldable_charges = [
		{"resource": PISTOL, "charge_current": 3, "current_ammo_type": 1}
	]
	state.interaction_component_state = [{"equipped_wieldable_item": PISTOL, "is_wielding": true}]
	state.player_active_quests = [QUESTS[0]]
	state.player_completed_quests = [QUESTS[1]]
	state.player_failed_quests = [QUESTS[2]]
	state.player_active_quest_progression = {"key": 3}
	state.player_attributes = {"health": Vector2(87.5, 100)}
	state.player_currencies = {"coins": Vector2(47, 100)}
	state.world_dictionary = {&"flag": true, 12: Color.TEAL, "$res": 9223372036854775806}
	assert_int(state.write_state("B")).is_equal(OK)
	var digest := FileAccess.get_sha256(manager.player_file("B"))
	assert_int(state.write_state("B")).is_equal(OK)
	assert_str(FileAccess.get_sha256(manager.player_file("B"))).is_equal(digest)

	var scene := CogitoSceneState.new()
	scene.saved_nodes = [{"cogito_id": "persist:1", "slot_data": stack, "loot": LOOT}]
	scene.saved_states = [{"cogito_id": "level:Chest", "inventory_data": state.player_inventory}]
	scene.saved_element_states = [{"cogito_id": "persist:1", "path": ".", "data": {"burn": true}}]
	scene.saved_destroyed_nodes = [{"cogito_id": "level:Door", "path": "."}]
	assert_int(scene.write_state("B", state.player_current_scene)).is_equal(OK)

	var prepared := manager.prepare_slot("B")
	assert_int(prepared.status).is_equal(manager.SlotStatus.OK)
	assert_array(prepared.warnings).is_empty()
	var player := prepared.player as CogitoPlayerAdvancedState
	assert_vector(player.player_position).is_equal(state.player_position)
	assert_bool(player.player_transform == state.player_transform).is_true()
	assert_dict(player.world_dictionary).is_equal(state.world_dictionary)
	assert_dict(player.player_attributes).is_equal(state.player_attributes)
	assert_dict(player.player_currencies).is_equal(state.player_currencies)
	assert_array(player.player_active_quests).contains_exactly([QUESTS[0]])
	assert_array(player.player_completed_quests).contains_exactly([QUESTS[1]])
	assert_array(player.player_failed_quests).contains_exactly([QUESTS[2]])
	assert_dict(player.player_active_quest_progression).is_equal(
		state.player_active_quest_progression
	)
	assert_array(player.saved_wieldable_charges).is_equal(state.saved_wieldable_charges)
	assert_array(player.interaction_component_state).is_equal(state.interaction_component_state)
	var inventory := player.player_inventory
	assert_bool(inventory.grid).is_true()
	assert_object(inventory.inventory_slots[1]).is_same(inventory.first_slot)
	assert_object(inventory.first_slot).is_same(player.player_quickslots[0])
	assert_int(inventory.first_slot.quantity).is_equal(7)
	assert_int(inventory.first_slot.origin_index).is_equal(0)
	var chest: CogitoInventory = prepared.scene.saved_states[0].inventory_data
	assert_object(chest.first_slot).is_same(prepared.scene.saved_nodes[0].slot_data)
	assert_str(chest.first_slot.inventory_item.resource_path).is_equal(item_path)
	assert_object(prepared.scene.saved_nodes[0].loot).is_same(LOOT)
	assert_array(prepared.scene.saved_element_states).is_equal(scene.saved_element_states)
	assert_array(prepared.scene.saved_destroyed_nodes).is_equal(scene.saved_destroyed_nodes)


func test_legacy_slot_upgrades_all_visited_levels_on_next_save() -> void:
	var old := make_slot("B")
	add_stack(old)
	assert_int(ResourceSaver.save(old, manager.legacy_player_file("B"))).is_equal(OK)
	var scene := CogitoSceneState.new()
	assert_int(ResourceSaver.save(scene, manager.legacy_scene_file("B", "CogitoPlayer"))).is_equal(
		OK
	)
	scene.saved_nodes = [{"cogito_id": "level:Chest", "inventory_data": old.player_inventory}]
	assert_int(ResourceSaver.save(scene, manager.legacy_scene_file("B", "Visited"))).is_equal(OK)
	assert_int(await manager.loading_saved_game("B")).is_equal(OK)
	await get_tree().process_frame
	assert_int(manager.save_game("B")).is_equal(OK)
	var files := DirAccess.get_files_at(manager.cogito_state_dir.path_join("B"))
	(
		assert_array(Array(files))
		. contains_exactly(
			[
				"player_state.v2.json",
				"scene_CogitoPlayer.v2.json",
				"scene_Visited.v2.json",
			]
		)
	)
	var upgraded := manager.prepare_slot("B")
	assert_int(upgraded.status).is_equal(manager.SlotStatus.OK)
	assert_dict(upgraded.player.world_dictionary).is_equal(old.world_dictionary)
	assert_int(upgraded.player.player_quickslots[0].quantity).is_equal(7)
	var path := manager.scene_file("B", "Visited")
	var visited: CogitoSceneState = manager.SaveCodec.new().read(path, "scene")
	var chest: CogitoInventory = visited.saved_nodes[0].inventory_data
	var original_item := old.player_quickslots[0].inventory_item
	assert_object(chest.inventory_slots[0].inventory_item).is_same(original_item)


func test_unreadable_v2_never_falls_back_to_stale_legacy() -> void:
	make_slot("B")
	var path := manager.player_file("B")
	write_text(path, '{"format":"daedalion-save","version":3,"engine":"4.7","kind":"player"}')
	var newer := manager.prepare_slot("B")
	assert_int(newer.status).is_equal(manager.SlotStatus.BROKEN)
	assert_str(newer.reason).is_equal("Save from a newer version.")
	write_text(path, '{"format":')
	assert_int(manager.prepare_slot("B").status).is_equal(manager.SlotStatus.BROKEN)


func test_missing_pickup_loads_level_and_emits_one_hint() -> void:
	var state := make_slot("B")
	add_stack(state)
	assert_int(state.write_state("B")).is_equal(OK)
	var scene := CogitoSceneState.new()
	scene.saved_nodes = [{"cogito_id": "persist:1", "slot_data": state.player_quickslots[0]}]
	assert_int(scene.write_state("B", state.player_current_scene)).is_equal(OK)
	assert_int(DirAccess.remove_absolute(item_path)).is_equal(OK)
	var messages: Array[String] = []
	var observe := func(node: Node) -> void:
		if node is PlayerInteractionComponent:
			node.hint_prompt.connect(
				func(_icon: Texture2D, message: String) -> void: messages.append(message)
			)
	get_tree().node_added.connect(observe)
	assert_int(await manager.loading_saved_game("B")).is_equal(OK)
	await get_tree().process_frame
	get_tree().node_added.disconnect(observe)
	assert_array(messages).contains_exactly(["Some saved items could not be restored."])
	assert_array(manager._scene_state.saved_nodes).is_empty()
	assert_object(manager.get_player().inventory_data.inventory_slots[0]).is_null()


func test_local_resources_restore_storage_properties_and_external_flags() -> void:
	var state := make_slot("B")
	var animation := Animation.new()
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, ^"Lamp:visible")
	animation.track_insert_key(track, 0.5, true)
	var flag_path := manager.cogito_state_dir.path_join("archive.tres")
	var flag := BooleanFlag.new()
	flag.flag_name = "archive_open"
	assert_int(ResourceSaver.save(flag, flag_path)).is_equal(OK)
	var group := SingleFlagGroup.new()
	group.flag = load(flag_path)
	var typed: Dictionary[StringName, int] = {&"code": 42}
	state.world_dictionary = {
		"animation": animation,
		"flag_group": group,
		"codes": typed,
		"live_node": self,
	}
	assert_int(state.write_state("B")).is_equal(OK)
	var prepared := manager.prepare_slot("B")
	assert_int(prepared.status).is_equal(manager.SlotStatus.OK)
	var restored := prepared.player.world_dictionary
	assert_bool(restored.has("live_node")).is_false()
	assert_bool(typed.is_same_typed(restored.codes)).is_true()
	assert_dict(restored.codes).is_equal(typed)
	var restored_animation: Animation = restored.animation
	assert_int(restored_animation.get_track_count()).is_equal(1)
	assert_bool(restored_animation.track_get_path(0) == ^"Lamp:visible").is_true()
	assert_bool(restored_animation.track_get_key_value(0, 0)).is_true()
	var restored_group: SingleFlagGroup = restored.flag_group
	assert_object(restored_group.flag).is_same(group.flag)
	assert_int(DirAccess.remove_absolute(flag_path)).is_equal(OK)


func test_deleted_ammo_in_local_weapon_keeps_surviving_ammo() -> void:
	var ammo_path := manager.cogito_state_dir.path_join("ammo.tres")
	assert_int(ResourceSaver.save(AmmoItemPD.new(), ammo_path)).is_equal(OK)
	var weapon := WieldableItemPD.new()
	weapon.wieldable_scene = PISTOL.wieldable_scene
	weapon.ammo_types = [load(ammo_path), PISTOL.ammo_types[0]]
	weapon.current_ammo_type = 1
	var state := make_slot("B")
	add_stack(state)
	state.player_quickslots[0].inventory_item = weapon
	state.saved_wieldable_charges = [{"resource": weapon, "charge_current": 3}]
	assert_int(state.write_state("B")).is_equal(OK)
	assert_int(DirAccess.remove_absolute(ammo_path)).is_equal(OK)
	var prepared := manager.prepare_slot("B")
	assert_int(prepared.status).is_equal(manager.SlotStatus.OK)
	assert_array(prepared.warnings).has_size(1)
	var restored := prepared.player.player_quickslots[0].inventory_item as WieldableItemPD
	assert_array(restored.ammo_types).contains_exactly([PISTOL.ammo_types[0]])
	assert_object(restored.get_current_ammo()).is_same(PISTOL.ammo_types[0])
	assert_object(prepared.player.saved_wieldable_charges[0].resource).is_same(restored)


func test_invalid_and_future_scene_headers_mark_slot_broken() -> void:
	var state := make_slot("B")
	var path := manager.scene_file("B", state.player_current_scene)
	write_text(path, '{"format":"daedalion-save","kind":"scene","engine":"4.7","version":3}')
	assert_str(manager.prepare_slot("B").reason).is_equal("Save from a newer version.")
	write_text(path, '{"format":"daedalion-save","kind":"scene","engine":"4.7","version":2}')
	assert_int(manager.prepare_slot("B").status).is_equal(manager.SlotStatus.BROKEN)

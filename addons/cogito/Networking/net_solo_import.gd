extends RefCounted
## Convert read-only prepared solo data into the first generation of an empty world.

const Files := preload("../SceneManagement/cogito_world_files.gd")
const Stock := preload("net_stock.gd")
const Ledger := preload("net_quest_ledger.gd")


## The caller holds the target lock. prepare_files reads the source without startup recovery.
static func copy(slot: String, player_id: String, files: Files) -> Error:
	if not files.manifest.is_empty():
		return ERR_ALREADY_EXISTS
	if player_id.is_empty() or not CogitoSceneManager.storage.valid_slot(slot):
		return ERR_INVALID_PARAMETER
	var prepared := CogitoSceneManager._slot_files.prepare_files(slot)
	var player := prepared.player as CogitoPlayerAdvancedState
	if prepared.status != CogitoSceneManager.SlotStatus.OK or not player or prepared.warnings:
		return ERR_FILE_CORRUPT
	var key := ResourceUID.ensure_path(player.player_current_scene_path)
	var levels := _levels(slot, player.player_current_scene, key)
	var profile := _profile(player_id, key, player)
	if levels.is_empty() or profile.is_empty():
		return ERR_INVALID_DATA
	var ledger := Ledger.new()
	ledger.flags = player.world_dictionary.duplicate(true)
	_import_quests(ledger, player)
	var world := {"active": key, "tick": 0, "quests": ledger.capture(), "shared": {}}
	return files.commit(world, levels, {player_id: profile})


## Legacy .res rows predate stable IDs. Keep matching authored instances addressable on replicas.
static func identify_legacy(state: CogitoSceneState, root: Node, match_object: Callable) -> Error:
	var available := CogitoLevel.nodes_in_group(root, &"Persist")
	for i in state.saved_nodes.size():
		var row: Dictionary = state.saved_nodes[i]
		if row.has("cogito_id"):
			continue
		var parent := CogitoPersistentId.resolve_path(root, row.parent, root)
		if not parent:
			return ERR_DOES_NOT_EXIST
		var choices: Array[Node3D] = []
		for node in available:
			if node is Node3D and node.get_parent() == parent:
				if _matches_prefab(node.scene_file_path, row.filename):
					choices.append(node)
		var selected: Node3D
		if match_object.is_valid():
			selected = match_object.call(row, choices)
			if selected and selected not in choices:
				return ERR_INVALID_DATA
		elif not row.get("spawned_loot_item", false):
			var point := Vector3(row.pos_x, row.pos_y, row.pos_z)
			var nearest := INF
			for node in choices:
				var distance := point.distance_squared_to(node.position)
				if distance < nearest:
					selected = node
					nearest = distance
		row.cogito_parent_id = CogitoPersistentId.of(parent)
		row.cogito_id = "persist:import-%d" % i
		if selected:
			row.cogito_id = CogitoPersistentId.of(selected)
			available.erase(selected)
	return OK


# An authored variant can inherit the PackedScene named in a legacy row.
static func _matches_prefab(path: String, original: String) -> bool:
	if path == original:
		return true
	var scene := load(path) as PackedScene if not path.is_empty() else null
	while scene:
		scene = scene.get_state().get_node_instance(0)
		if scene and scene.resource_path == original:
			return true
	return false


## Translate generated solo IDs once when building the level. Replicas receive normal MP3/6 spawns.
static func bind_runtime(state: CogitoSceneState, players: Node) -> Error:
	var level: Node = players.active_level()
	var aliases := {}

	for row: Dictionary in state.saved_nodes:
		var id: String = row.get("cogito_id", "")
		if not id.begins_with("persist:"):
			continue
		var source := CogitoPersistentId.find_in_level(level, id) as Node3D
		if not source:
			return ERR_DOES_NOT_EXIST
		var target: Node3D = players.spawner.import_object(source)
		if not target:
			push_warning("Cannot map solo object %s (%s) to a network spawn" % [id, row.filename])
			return ERR_UNAVAILABLE
		aliases[id] = players.world.entities.id_for(target)
		players.world.publish(id, {"removed": true})
		source.queue_free()
	for entry: Dictionary in state.saved_attribute_states + state.saved_element_states:
		entry.cogito_id = aliases.get(entry.cogito_id, entry.cogito_id)
	return OK


static func _levels(slot: String, current: String, active_path: String) -> Dictionary:
	var manager := CogitoSceneManager
	var dir := manager.cogito_state_dir.path_join(slot)
	var names := {current: true}
	for file in DirAccess.get_files_at(dir):
		if file.begins_with("scene_") and file.ends_with(".v2.json"):
			names[file.trim_prefix("scene_").trim_suffix(".v2.json")] = true
		elif file.begins_with(manager.cogito_scene_state_prefix) and file.ends_with(".res"):
			names[file.trim_prefix(manager.cogito_scene_state_prefix).trim_suffix(".res")] = true
	var levels := {}
	for level_name: String in names:
		var path := manager.scene_file(slot, level_name)
		var legacy := manager.legacy_scene_file(slot, level_name)
		var state := CogitoSceneState.new()
		state.known_persist_ids = {}
		if FileAccess.file_exists(path) or FileAccess.file_exists(legacy):
			var report := manager.PreparedSlot.new()
			state = (
				manager._slot_files.read_state(path, legacy, "scene", report) as CogitoSceneState
			)
			if not state or report.warnings:
				return {}
		var key := active_path if level_name == current else level_name
		levels[key] = {
			"id": key,
			"path": active_path if level_name == current else "",
			# A legacy .res has its own user:// path. Embed the copied state in this world.
			"scene": state.duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL),
			"objects": {},
			"bodies": {},
			"containers": {},
			"imported": true,
		}
	return levels


static func _profile(id: String, key: String, player: CogitoPlayerAdvancedState) -> Dictionary:
	var model := Stock.new()
	model.data = player.player_inventory if player.player_inventory else CogitoInventory.new()
	player._restore_inventory(model.data)
	var equipped: Resource
	for entry: Dictionary in player.interaction_component_state:
		if entry.get("is_wielding", true):
			equipped = entry.get("equipped_wieldable_item")
	var equipped_id := 0
	for stack in model.data.inventory_slots:
		if not stack:
			continue
		var item := stack.inventory_item
		var definition := Stock.definition(item)
		if definition.is_built_in() and item.drop_scene:
			var template := Stock.pickup_template(load(item.drop_scene))
			if template and template.inventory_item.name == item.name:
				definition = template.inventory_item
		if (
			definition.resource_path.is_empty()
			or not Stock.load_definition(definition.resource_path)
		):
			return {}
		if item != definition:
			item.set_meta(&"cogito_item_definition", definition)
		if item == equipped:
			equipped_id = model.ensure_id(stack)
	var stock := model.capture()
	stock.equipped = equipped_id
	stock.money = player.player_currencies.duplicate(true)
	var health: Vector2 = player.player_attributes.get("health", Vector2.ONE)
	return {
		"id": id,
		"display_name": "",
		"last_seen": 0,
		"level": key,
		"pose": Transform3D(Basis.from_euler(player.player_rotation), player.player_position),
		"crouched": player.player_try_crouch,
		"dead": health.x <= 0,
		"pitch": player.head_transform.basis.get_euler().x,
		"neck": player.neck_transform.basis.get_euler().y,
		"stock": stock,
		"attributes": player.player_attributes.duplicate(true),
		"elements": player.element_state.duplicate(true),
		"progression": player.player_active_quest_progression.duplicate(true),
	}


static func _import_quests(ledger: Ledger, player: CogitoPlayerState) -> void:
	var groups := [
		player.player_active_quests, player.player_completed_quests, player.player_failed_quests
	]
	var states := [
		CogitoQuest.QuestState.Active,
		CogitoQuest.QuestState.Completed,
		CogitoQuest.QuestState.Failed
	]
	for i in groups.size():
		for definition: CogitoQuest in groups[i]:
			var working := Ledger.instance(definition, {"state": states[i]})
			var exact: Dictionary = player.quest_objective_states.get(definition, {})
			working.restore_objectives(exact, ledger.flags)
			ledger.quests[definition.resource_path] = Ledger.record(definition, working)

extends SceneTree
## Offline compatibility check. Copy the playtest slots into an isolated user://saves first.
## Run with --headless --script res://tests/saves/real_slot_check.gd.

var manager: Node
var quests: Node
var restored: Dictionary


func _initialize() -> void:
	run.call_deferred()


func snapshot() -> Dictionary:
	var player: Node3D = manager.get_player()
	var items: Array = []
	for stack: Resource in player.inventory_data.inventory_slots:
		if stack:
			var item: Resource = stack.inventory_item
			# The old .res owns its subresource paths. Local items in JSON have local IDs.
			(
				items
				. append(
					[
						"<local>" if item.is_built_in() else item.resource_path,
						item.name,
						stack.quantity,
						stack.origin_index,
					]
				)
			)
		else:
			items.append(null)
	var groups := {}
	for group: String in ["active", "completed", "failed"]:
		var paths := []
		for quest: Resource in quests.get(group).quests:
			paths.append([quest.resource_path, quest.quest_name])
		groups[group] = paths
	return {
		"position": player.global_position,
		"inventory": items,
		"quests": groups,
		"progression": player.saved_quest_progression.duplicate(true),
	}


func observe(node: Node) -> void:
	if node.has_signal("player_state_loaded"):
		node.connect("player_state_loaded", capture)


func capture() -> void:
	restored = snapshot()


func run() -> void:
	manager = root.get_node("CogitoSceneManager")
	quests = root.get_node("CogitoQuestManager")
	node_added.connect(observe)
	for number in range(1, 9):
		var slot: RefCounted = manager.prepare_slot(str(number))
		if slot.status != manager.SlotStatus.OK:
			printerr("slot ", number, " BROKEN ", slot.reason)
			quit(1)
			return
		print("slot ", number, " OK ", slot.player.player_current_scene)
	if await manager.loading_saved_game("1") != OK:
		quit(1)
		return
	await process_frame
	if restored.is_empty() or current_scene.name != &"Cogito04Laboratory":
		printerr("Laboratory did not finish loading")
		quit(1)
		return
	var before := snapshot()
	print("legacy snapshot ", JSON.stringify(before))
	if manager.save_game("v2check") != OK:
		quit(1)
		return
	restored.clear()
	if await manager.loading_saved_game("v2check") != OK:
		quit(1)
		return
	await process_frame
	print("v2 snapshot ", JSON.stringify(restored))
	var matched := not restored.is_empty() and before == restored
	print("REAL SAVE CHECK ", "PASS" if matched else "FAIL")
	quit(0 if matched else 1)

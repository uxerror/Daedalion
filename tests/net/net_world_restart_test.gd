extends "memory_session_suite.gd"

const Grid := preload("res://addons/cogito/Networking/net_grid.gd")
const Rifle := preload("res://addons/cogito/InventoryPD/Items/Cogito_LaserRifle.tres")
const Ledger := preload("res://addons/cogito/Networking/net_quest_ledger.gd")
const PersonalQuest := preload("personal_quest.tres")
const Arena := preload("process_arena.tscn")

var _dir: String
var _previous: Node
var _root: Node3D
var _server: Facade
var _events: Array[StringName] = []
var _restore_count := 0
var _now := 0


func before_test() -> void:
	_now = 0
	_dir = create_temp_dir("world-%d" % Time.get_ticks_usec())
	_previous = get_tree().current_scene
	_boot()


func _boot() -> void:
	_root = Arena.instantiate()
	get_tree().root.add_child(_root)
	get_tree().current_scene = _root
	_server = _branch(1, _root)
	_server.apply_shared_state = func(_state: Dictionary): _restore_count += 1
	assert_int(_server.start_server({"save_dir": _dir})).is_equal(OK)
	_server.player_world.persistence.clock = func() -> int: return _now
	_server.player_world.bind_level(_root, Transform3D(Basis.IDENTITY, Vector3.UP), "arena")


func _join(peer: int, port: int) -> Facade:
	var client := _branch(peer)
	assert_int(client.join("restart", port)).is_equal(OK)
	client.player_world.quests.notified.connect(
		func(event: StringName, _quest: CogitoQuest): _events.append(event)
	)
	_arena(client)
	_pump()
	return client


func _join_with_starter(peer: int, port: int) -> Facade:
	var settings := CogitoGlobals.cogito_settings
	var original := settings.new_game_starter_items
	var starter := InventorySlotPD.new()
	starter.inventory_item = Rifle
	settings.new_game_starter_items = [starter]
	var client := _join(peer, port)
	settings.new_game_starter_items = original
	return client


func after_test() -> void:
	super.after_test()
	get_tree().current_scene = _previous
	_root.free()


func _restart() -> void:
	after_test()
	_boot()


func test_offline_profiles_zero_players_death_and_blocked_pose() -> void:
	var a := _join_with_starter(2, 1901)
	var b := _join_with_starter(3, 1902)
	await _ticks(4)
	var ada := a.local_player_id()
	var ben := b.local_player_id()
	var players := _server.player_world
	var first := players.avatar_for(ada).actor
	var second := players.avatar_for(ben).actor
	var consumed := second.inventory_data.find_slots("Laser Rifle")[0]
	Grid.spend(second.inventory_data, consumed, 1)
	var weapon := first.inventory_data.find_slots("Laser Rifle")[0]
	first.inventory_data.assigned_quickslots[0] = weapon
	assert_str(players.avatar_for(ada).wield.equip(weapon)).is_empty()
	var gun := weapon.inventory_item as WieldableItemPD
	gun.charge_current = 3
	first.player_currencies.credits.value_current = 14
	second.player_currencies.credits.value_current = 29
	players.quests.advance(PersonalQuest, CogitoQuestUpdater.UpdateType.Start, [], ada)
	first.decrease_attribute("health", 1000)
	var buried := Vector3(6, -0.5, -12)
	second.position = buried
	second.cogito_properties.make_wet()
	a.disconnect_session()
	b.disconnect_session()
	_pump()
	assert_int(_server.players().size()).is_zero()
	var calls: Array[int] = []
	players.persistence.capture_shared = func() -> Dictionary:
		calls.append(_server.save_world())
		return {"mode": "co-op"}
	assert_int(_server.save_world()).is_equal(OK)
	assert_array(calls).contains_exactly([ERR_BUSY])
	_restart()
	# Save again before the first identity reconnects. Both private files must carry forward.
	assert_int(_server.save_world()).is_equal(OK)
	_restart()
	_events.clear()
	var sounds: Array[AudioStream] = []
	var settings := CogitoGlobals.cogito_settings
	var listen := func(node: Node):
		var cues := [
			settings.quest_start_sound, settings.quest_complete_sound, settings.quest_failed_sound
		]
		if node is AudioStreamPlayer and node.stream in cues:
			sounds.append(node.stream)
	CogitoAudio.child_entered_tree.connect(listen)
	a = _join_with_starter(8, 1901)
	b = _join_with_starter(9, 1902)
	CogitoAudio.child_entered_tree.disconnect(listen)
	assert_array(sounds).is_empty()
	assert_str(a.local_player_id()).is_equal(ada)
	assert_str(b.local_player_id()).is_equal(ben)
	first = _server.player_world.avatar_for(ada).actor
	second = _server.player_world.avatar_for(ben).actor
	assert_bool(first.is_dead).is_false()
	assert_bool(first.cogito_properties.is_wet).is_false()
	assert_bool(second.cogito_properties.is_wet).is_true()
	assert_bool(second.position.is_equal_approx(buried)).is_false()
	for actor in [first, second]:
		var at_marker: bool = (
			actor.position.is_equal_approx(_root.get_node("Respawn1").position)
			or actor.position.is_equal_approx(_root.get_node("Respawn2").position)
		)
		assert_bool(at_marker).is_true()
	assert_float(first.player_currencies.credits.value_current).is_equal(14.0)
	assert_float(second.player_currencies.credits.value_current).is_equal(29.0)
	assert_int(first.inventory_data.find_slots("Laser Rifle").size()).is_equal(1)
	assert_array(second.inventory_data.find_slots("Laser Rifle")).is_empty()
	var restored := _server.player_world.avatar_for(ada).wield.stack
	assert_object(restored).is_same(first.inventory_data.assigned_quickslots[0])
	assert_float(restored.inventory_item.charge_current).is_equal(3.0)
	(
		assert_bool(a.player_world.quests.journal(true).quests.has(PersonalQuest.resource_path))
		. is_true()
	)
	assert_dict(b.player_world.quests.journal(true).quests).is_empty()
	assert_array(_events).is_empty()
	assert_int(_restore_count).is_equal(2)


func test_saved_actor_releases_physical_claim(
	place: String, _test_parameters := [["seat"], ["carry"]]
) -> void:
	var client := _join(2, 1901)
	await _ticks(6)
	var id := client.local_player_id()
	_root.stage_physics(_server.player_world, place, id)
	await _ticks(8)
	var seat := _root.get_node("Seat") as CogitoSittable
	var box := _root.get_node("CarryBox") as RigidBody3D
	if place == "seat":
		_use(client, "Seat/BasicInteraction")
		assert_str(seat.occupant_id).is_equal(id)
	else:
		var grip := box.get_node("CarryableComponent") as CogitoCarryableComponent
		grip.attribute_check = InteractionComponent.AttributeCheck.NONE
		_use(client, "CarryBox/CarryableComponent", &"interact2")
		assert_bool(box.has_meta(&"net_carrier")).is_true()
	var pose := box.transform
	assert_int(_server.save_world()).is_equal(OK)
	_restart()
	box = _root.get_node("CarryBox")
	assert_bool(box.transform.is_equal_approx(pose)).is_true()
	assert_bool(box.has_meta(&"net_carrier")).is_false()
	client = _join(8, 1901)
	assert_bool(_server.player_world.avatar_for(id).actor.is_sitting).is_false()
	for level: Node in [_root, client.player_world.active_level()]:
		seat = level.get_node("Seat")
		assert_str(seat.occupant_id).is_empty()
		assert_bool(seat.is_occupied).is_false()


func test_live_npc_projectile_resumes_without_another_launch() -> void:
	var players := _server.player_world
	var guard := _root.get_node("Guard") as CogitoNPC
	var origin := Vector3(1, 8, -4)
	assert_bool(players.projectiles.launch_npc(guard, origin, Vector3.UP)).is_true()
	var flights := players.projectiles.capture()
	assert_int(flights.size()).is_equal(1)
	assert_int(_server.save_world()).is_equal(OK)
	_restart()
	assert_array(_server.player_world.projectiles.capture()).is_equal(flights)


func test_corpse_loot_and_container_restored_once() -> void:
	var a := _join(2, 1901)
	await _ticks(5)
	var actor := _server.player_world.avatar_for(a.local_player_id()).actor
	var guard := _root.get_node("Guard") as CogitoNPC
	for i in 2:
		guard.damage_received.emit(25.0, actor, Vector3.FORWARD, guard.position)
	await _ticks(5)
	var box := _root.get_node("SharedBox") as CogitoContainer
	box.inventory_data.inventory_slots.fill(null)
	var stock := InventorySlotPD.new()
	stock.inventory_item = Rifle
	Grid.insert(box.inventory_data, stock, 1, false)
	var world := _server.player_world.world
	assert_object(world.entities.live_object("runtime:1")).is_instanceof(CogitoBodyDrag)
	assert_object(world.entities.live_object("runtime:2")).is_instanceof(CogitoObject)
	assert_int(_server.save_world()).is_equal(OK)
	_restart()
	a = _join(8, 1901)
	await _ticks(4)
	for branch in [_server, a]:
		var entities: Variant = branch.player_world.world.entities
		var npc: CogitoNPC = branch.player_world.active_level().get_node("Guard")
		assert_bool(npc.network_state.dead).is_true()
		assert_bool(npc.can_process()).is_false()
		assert_object(entities.live_object("runtime:1")).is_instanceof(CogitoBodyDrag)
		assert_object(entities.live_object("runtime:2")).is_instanceof(CogitoObject)
		assert_object(entities.live_object("runtime:3")).is_null()
	box = _root.get_node("SharedBox") as CogitoContainer
	assert_int(box.inventory_data.find_slots("Laser Rifle").size()).is_equal(1)
	var extra := _server.player_world.spawner.spawn_item(stock, 1, Vector3.UP)
	assert_object(_server.player_world.world.entities.live_object("runtime:3")).is_same(extra)


func test_first_visit_unloaded_before_first_commit() -> void:
	var host := CogitoLevelHost.new()
	_server.add_child(host)
	var level := host.load_level(Arena.resource_path, &"once")
	_server.player_world.bind_level(level, Transform3D.IDENTITY, "once")
	host.unload_level(&"once")
	assert_int(_server.save_world()).is_equal(OK)
	var files := _server.player_world.persistence.files
	assert_bool(files.manifest.levels.has("once")).is_true()


func test_second_live_level_and_unloaded_level_carried_forward() -> void:
	var host := CogitoLevelHost.new()
	_server.add_child(host)
	var level := host.load_level(Arena.resource_path, &"other")
	_server.player_world.bind_level(level, Transform3D.IDENTITY, "other")
	var box := level.get_node("SharedBox") as CogitoContainer
	box.inventory_data.inventory_slots.fill(null)
	assert_int(_server.save_world()).is_equal(OK)
	var files := _server.player_world.persistence.files
	assert_int(files.scenes.size()).is_equal(2)
	var digest: String = files.manifest.levels.other
	var stock := InventorySlotPD.new()
	stock.inventory_item = Rifle
	Grid.insert(box.inventory_data, stock, 1, false)
	host.unload_level(&"other")
	await get_tree().process_frame
	await get_tree().process_frame
	assert_int(_server.save_world()).is_equal(OK)
	assert_str(files.manifest.levels.other).is_not_equal(digest)
	digest = files.manifest.levels.other
	assert_int(_server.save_world()).is_equal(OK)
	assert_str(files.manifest.levels.other).is_equal(digest)
	_restart()
	host = CogitoLevelHost.new()
	_server.add_child(host)
	level = host.load_level(Arena.resource_path, &"other")
	_server.player_world.bind_level(level, Transform3D.IDENTITY, "other")
	box = level.get_node("SharedBox") as CogitoContainer
	assert_int(box.inventory_data.find_slots("Laser Rifle").size()).is_equal(1)


func _poll_at(now: int) -> void:
	_now = now
	var players := _server.player_world
	players.persistence.poll(players, Engine.get_physics_frames())
	assert_bool(players.persistence.reap(players, Time.get_ticks_msec() + 3000)).is_true()


func test_autosave_only_dirty_zero_off_and_manual_resets_deadline() -> void:
	var players := _server.player_world
	var writer := players.persistence
	_poll_at(59999)
	assert_dict(writer.files.manifest).is_empty()
	_poll_at(60000)
	assert_int(writer.files.manifest.generation).is_equal(1)
	_poll_at(120000)
	assert_int(writer.files.manifest.generation).is_equal(1)
	_poll_at(125000)
	assert_int(_server.save_world()).is_equal(OK)
	players.quests.set_world_flags({"progress": true})
	_poll_at(180000)
	assert_int(writer.files.manifest.generation).is_equal(2)
	_poll_at(185000)
	assert_int(writer.files.manifest.generation).is_equal(3)
	players.get_parent().config.autosave_seconds = 0
	players.quests.set_world_flags({"progress": false})
	_poll_at(999999)
	assert_int(writer.files.manifest.generation).is_equal(3)
	assert_bool(writer.dirty).is_true()


func test_departure_burst_reconnect_and_takeover_before_publication() -> void:
	var a := _join_with_starter(2, 1901)
	var b := _join(3, 1902)
	var ada := a.local_player_id()
	var ben := b.local_player_id()
	var players := _server.player_world
	var writer := players.persistence
	assert_int(_server.save_world()).is_equal(OK)
	var actor := players.avatar_for(ada).actor
	actor.player_currencies.credits.value_current = 19
	actor.position = Vector3(9, 2, 4)
	players.quests.advance(PersonalQuest, CogitoQuestUpdater.UpdateType.Start, [], ada)
	a.disconnect_session()
	_pump()
	_poll_at(150)
	b.disconnect_session()
	_pump()
	_events.clear()
	a = _join(4, 1901)
	actor = players.avatar_for(ada).actor
	assert_vector(actor.position).is_equal(Vector3(9, 2, 4))
	assert_float(actor.player_currencies.credits.value_current).is_equal(19.0)
	actor.player_currencies.credits.value_current = 27
	# A second proof for Ada removes the stale incarnation synchronously on the same tick.
	var replacement := _join(5, 1901)
	assert_str(replacement.local_player_id()).is_equal(ada)
	actor = players.avatar_for(ada).actor
	assert_float(actor.player_currencies.credits.value_current).is_equal(27.0)
	assert_int(actor.inventory_data.find_slots("Laser Rifle").size()).is_equal(1)
	assert_array(_events).is_empty()
	_poll_at(249)
	assert_int(writer.files.manifest.generation).is_equal(1)
	_poll_at(250)
	assert_int(writer.files.manifest.generation).is_equal(2)
	assert_bool(writer.files.profiles.has(ben)).is_true()
	assert_float(writer.files.profiles[ada].stock.money.credits[0]).is_equal(27.0)
	assert_dict(writer.lives.retained).is_empty()


func test_fault_preserves_generation_and_retries_newest_departure(
	operation: String,
	_test_parameters := [["write profile"], ["publish staging"], ["after publish"]]
) -> void:
	var client := _join(2, 1901)
	var id := client.local_player_id()
	var players := _server.player_world
	var writer := players.persistence
	assert_int(_server.save_world()).is_equal(OK)
	var manifest := writer.files.directory.path_join("current/world.v2.json")
	var digest := FileAccess.get_sha256(manifest)
	players.avatar_for(id).actor.player_currencies.credits.value_current = 33
	client.disconnect_session()
	_pump()
	var results: Array[int] = []
	writer.save_finished.connect(func(err: Error, _generation: int): results.append(err))
	writer.files.storage.fail_before = func(op: String) -> bool: return op == operation
	_poll_at(250)
	assert_array(results).contains_exactly([ERR_CANT_CREATE])
	assert_str(FileAccess.get_sha256(manifest)).is_equal(digest)
	var verified := Facade.Persistence.Files._read(manifest.get_base_dir())
	assert_float(verified.profiles[id].stock.money.credits[0]).is_equal(10.0)
	assert_int(writer.files.manifest.generation).is_equal(1)
	for tick in 100:
		_poll_at(251 + tick)
	assert_int(results.size()).is_equal(1)
	_poll_at(1250)
	assert_int(results.size()).is_equal(2)
	assert_bool(writer.dirty).is_true()
	assert_int(writer.lives.retained.size()).is_equal(1)
	writer.files.storage.fail_before = Callable()
	_poll_at(3249)
	assert_int(results.size()).is_equal(2)
	_poll_at(3250)
	assert_array(results).contains_exactly([ERR_CANT_CREATE, ERR_CANT_CREATE, OK])
	assert_bool(writer.dirty).is_false()
	assert_dict(writer.lives.retained).is_empty()
	_restart()
	var restored: Dictionary = _server.player_world.persistence.files.profiles[id]
	assert_float(restored.stock.money.credits[0]).is_equal(33.0)


func test_orderly_close_captures_unannounced_last_tick() -> void:
	var client := _join(2, 1901)
	var id := client.local_player_id()
	assert_int(_server.save_world()).is_equal(OK)
	_server.player_world.avatar_for(id).actor.player_currencies.credits.value_current = 73
	assert_int(_server.disconnect_session()).is_equal(OK)
	_restart()
	var files := _server.player_world.persistence.files
	assert_int(files.manifest.generation).is_equal(2)
	assert_float(files.profiles[id].stock.money.credits[0]).is_equal(73.0)


func _request(command: String, body: String) -> void:
	var writer := _server.player_world.persistence
	var path := writer.files.directory.path_join(command + ".request")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(body)
	file.close()
	_poll_at(_now + 1000)
	assert_bool(FileAccess.file_exists(path)).is_false()


func test_running_list_rebind_and_connected_target_protection() -> void:
	var a := _join_with_starter(2, 1901)
	var b := _join(3, 1902)
	var ada := a.local_player_id()
	var ben := b.local_player_id()
	var players := _server.player_world
	var files := players.persistence.files
	players.avatar_for(ada).actor.player_currencies.credits.value_current = 39
	assert_int(_server.save_world()).is_equal(OK)
	_request("list", "")
	_request("rebind", ada + " " + ben + " force")
	assert_int(files.manifest.generation).is_equal(1)
	a.disconnect_session()
	_pump()
	_request("rebind", ada + " " + ben + " force")
	assert_bool(files.profiles.has(ada)).is_true()
	b.disconnect_session()
	_pump()
	_request("rebind", ada + " " + ben)
	assert_bool(files.profiles.has(ada)).is_true()
	_request("rebind", ada + " " + ben + " force")
	assert_bool(files.profiles.has(ada)).is_false()
	assert_str(files.profiles[ben].id).is_equal(ben)
	assert_str(files.profiles[ben].display_name).is_equal("Player")
	assert_int(files.profiles[ben].last_seen).is_greater(0)
	var again := _join(4, 1902)
	assert_str(again.local_player_id()).is_equal(ben)
	var actor := players.avatar_for(ben).actor
	assert_float(actor.player_currencies.credits.value_current).is_equal(39.0)
	assert_int(actor.inventory_data.find_slots("Laser Rifle").size()).is_equal(1)
	_join(5, 1901)
	assert_array(players.avatar_for(ada).actor.inventory_data.find_slots("Laser Rifle")).is_empty()


func test_publication_in_flight_coalesces_manual_leave_and_reconnect() -> void:
	var a := _join(2, 1901)
	var id := a.local_player_id()
	var players := _server.player_world
	var writer := players.persistence
	assert_int(_server.save_world()).is_equal(OK)
	players.avatar_for(id).actor.player_currencies.credits.value_current = 13
	writer.request_save()
	writer.poll(players, 100)
	# No owner-thread reap occurs during this tick, regardless of disk speed.
	for request in 10:
		assert_int(_server.save_world()).is_equal(ERR_BUSY)
	players.avatar_for(id).actor.player_currencies.credits.value_current = 28
	a.disconnect_session()
	_pump()
	_join(3, 1901)
	assert_float(players.avatar_for(id).actor.player_currencies.credits.value_current).is_equal(
		28.0
	)
	players.avatar_for(id).actor.player_currencies.credits.value_current = 48
	assert_bool(writer.reap(players, Time.get_ticks_msec() + 3000)).is_true()
	assert_float(writer.files.profiles[id].stock.money.credits[0]).is_equal(13.0)
	assert_float(writer.lives.retained[id].stock.money.credits[0]).is_equal(28.0)
	_poll_at(200)
	assert_float(writer.files.profiles[id].stock.money.credits[0]).is_equal(48.0)
	_poll_at(500)
	assert_int(writer.files.manifest.generation).is_equal(3)


func test_failed_final_flush_releases_claim_and_old_generation_reopens() -> void:
	var players := _server.player_world
	assert_int(_server.save_world()).is_equal(OK)
	players.quests.set_world_flags({"last": true})
	players.persistence.files.storage.fail_before = func(op: String) -> bool:
		return op == "after publish"
	assert_int(_server.disconnect_session()).is_equal(ERR_CANT_CREATE)
	_restart()
	assert_int(_server.player_world.persistence.files.manifest.generation).is_equal(1)
	assert_bool(_server.player_world.quests.world.flags.has("last")).is_false()


func test_rebind_refused_if_identity_returns_while_staging() -> void:
	var a := _join(2, 1901)
	var id := a.local_player_id()
	var players := _server.player_world
	var writer := players.persistence
	assert_int(_server.save_world()).is_equal(OK)
	a.disconnect_session()
	_pump()
	var path := writer.files.directory.path_join("rebind.request")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(id + " reassigned")
	file.close()
	writer.poll(players, 1)
	var returned := _join(3, 1901)
	assert_str(returned.local_player_id()).is_equal(id)
	assert_bool(writer.reap(players, Time.get_ticks_msec() + 3000)).is_true()
	assert_int(writer.last_error).is_equal(ERR_ALREADY_IN_USE)
	assert_int(writer.files.manifest.generation).is_equal(1)
	assert_bool(writer.files.profiles.has("reassigned")).is_false()
	_poll_at(1000)
	assert_int(writer.files.manifest.generation).is_equal(2)
	assert_bool(writer.files.profiles.has(id)).is_true()


func test_timed_out_shutdown_keeps_claim_until_worker_releases_it() -> void:
	var players := _server.player_world
	var writer := players.persistence
	assert_int(_server.save_world()).is_equal(OK)
	var gate := Semaphore.new()
	writer.files.storage.fail_before = func(op: String) -> bool:
		if op == "create staging":
			gate.wait()
		return false
	writer.shutdown_wait_msec = 5
	var err := _server.disconnect_session()
	var other := Facade.Persistence.Files.new()
	var claimed := other.open(_dir, "default")
	gate.post()
	assert_int(err).is_equal(ERR_TIMEOUT)
	assert_int(claimed).is_equal(ERR_BUSY)
	var deadline := Time.get_ticks_msec() + 3000
	while claimed == ERR_BUSY and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		claimed = other.open(_dir, "default")
	assert_int(claimed).is_equal(OK)
	other.close()

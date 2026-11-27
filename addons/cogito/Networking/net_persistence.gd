extends RefCounted
## One authority writer captures each generation at a single tick and acknowledges it after I/O.

## Last completed attempt. UI may read last_error when opened after an unattended failure.
signal save_finished(result: Error, generation: int)
## Consumed at the next safe point before teardown.
signal stop_requested

const Files := preload("../SceneManagement/cogito_world_files.gd")
const Import := preload("net_solo_import.gd")
const ProfileTools := preload("net_profile_tools.gd")
const Profiles := preload("net_profiles.gd")
const WorldWrite := preload("net_world_write.gd")
const Spawner := preload("net_spawner.gd")
const Reconnect := preload("net_reconnect_policy.gd")

var files := Files.new()
var operator := ProfileTools.new()
var lives := Profiles.new()
var levels := {}
var placement: Resource = Reconnect.new()
var capture_shared: Callable
var apply_shared: Callable
var match_legacy_object: Callable
var busy := false
var restore_error := OK
## Injectable monotonic clock. Configure intervals before the first level bind.
var clock: Callable = Time.get_ticks_msec
var checkpoint_msec := 250
var retry_initial_msec := 1000
var retry_cap_msec := 60000
var movement_threshold := 0.25
var attribute_threshold := 1.0
var dirty := false
var last_error := OK
var failure_message := ""
var capture_usec := 0
var commit_usec := 0
var shutdown_wait_msec := 3000
## Sequence of the most recently started capture, including an in-flight publication.
var capture_serial := 0
var _job: WorldWrite
var _saved_retained := {}
var _saved_unloaded := {}
var _manual := false
var _operator_save := false
var _autosave_at := 0
var _checkpoint_at := -1
var _retry_at := -1
var _retry_delay := 1000
var _move := PackedStringArray()
var _next_poll := 0
var _inbox_reports := {}
var _bound_first := false
var _active_key := ""
var _active_unloaded := false
var _prepared := {}
var _unpublished_levels := {}
var _legacy_holdings := {}
# Zero means the stationary room needs a snapshot. Positive serials identify the
# publication containing it, so failure or a concurrent mutation cannot lose a change.
var _frozen_capture := {}


## Install global state once before the first admission baseline.
func install(players: Node) -> void:
	if files.manifest.is_empty():
		return
	players.quests.world.restore(files.manifest.quests)
	lives.install(files.profiles, players)
	if apply_shared.is_valid():
		apply_shared.call(files.manifest.shared.duplicate(true))


## Called after bind marked the root, before it indexed authored objects or spawned actors.
func rebuild(key: String, root: Node) -> void:
	if not _bound_first and not files.manifest.is_empty() and key != files.manifest.active:
		restore_error = ERR_INVALID_DATA
		return
	_bound_first = true
	var saved := _saved_scene(key, root)
	if not saved.is_empty():
		var state: CogitoSceneState = saved.scene.duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL)
		if saved.get("imported", false):
			restore_error = Import.identify_legacy(state, root, match_legacy_object)
			if restore_error != OK:
				return
		_cache_remains(root)
		CogitoSceneManager._scene_persistence.restore_world_nodes(state, root)
		_prepared[key] = state


# Saved corpses written before MP10 name only their NPC; keep its archetypes past removal.
func _cache_remains(root: Node) -> void:
	var remains := {}
	for npc: CogitoNPC in root.find_children("*", "CogitoNPC", true, false):
		if npc.health:
			remains[CogitoPersistentId.of(npc)] = npc.health.spawn_on_death.duplicate()
	root.set_meta(Spawner.REMAINS_META, remains)


func _saved_scene(key: String, root: Node) -> Dictionary:
	if _unpublished_levels.has(key):
		return _unpublished_levels[key]
	if files.scenes.has(key):
		return files.scenes[key]
	# Solo slots index inactive rooms by authored root name.
	var imported: Dictionary = files.scenes.get(String(root.name), {})
	return imported if imported.get("imported", false) else {}


## Install spawner records exactly once per instance, then components and independent views.
func restore_level(key: String, players: Node) -> void:
	if restore_error != OK:
		return
	if players == players.get_parent().get_node("Players"):
		_active_key = key
		_active_unloaded = false
		_reset_timer(players)
	levels[key] = players
	var root: Node = players.active_level()
	var data := _saved_scene(key, root)
	if data.is_empty():
		mark_dirty()
		return
	# Offline imports can remove an authored pickup before the network registry binds.
	for node in root.find_children("*", "Node3D", true, false):
		if node.is_queued_for_deletion():
			players.world.publish(CogitoPersistentId.of(node), {"removed": true})
	var objects: Dictionary = data.objects
	var scene: CogitoSceneState = _prepared[key]
	_prepared.erase(key)
	if data.get("imported", false):
		restore_error = Import.bind_runtime(scene, players)
		if restore_error != OK:
			return
		# Solo rows supplied the adapter fields before registration. Refresh linked displays.
		objects = players.world.capture()
		for npc: CogitoNPC in players.npcs.tracked:
			objects.erase(players.world.entities.id_for(npc))
	restore_error = players.world.restore(objects)
	if restore_error == OK:
		restore_error = players.projectiles.restore(data.get("flights", []))
	if restore_error != OK:
		return
	players.bodies.restore(data.bodies)
	players.containers.restore(data.containers, data.get("loot_timers", {}))
	players.npcs.restore(data.get("perception", {}))
	CogitoSceneManager._scene_persistence.restore_world_components(scene, root)
	if data.get("imported", false):
		# Solo records encode death in the saved health attribute.
		for npc: CogitoNPC in players.npcs.tracked:
			npc.network_state.dead = npc.is_dead()
			var id: String = players.world.entities.id_for(npc)
			players.world.restore({id: npc.net_state()})


## A failed destination was never admitted. Resume publishing the surviving live rooms.
func discard_restore(key: String) -> void:
	_prepared.erase(key)
	evicted(key)
	restore_error = OK


## Last captured loose and container holdings for visited rooms without a live simulation.
func unloaded_holdings(item: String) -> int:
	var count := 0
	var saved := files.scenes.duplicate()
	saved.merge(_unpublished_levels, true)
	for key: String in saved:
		if not levels.has(key):
			var row: Dictionary = saved[key]
			if row.has("holdings"):
				count += int(row.holdings.get(item, 0))
			else:
				if not _legacy_holdings.has(key):
					_legacy_holdings[key] = Spawner.saved_holdings(row)
				count += int(_legacy_holdings[key].get(item, 0))
	return count


## Notify the writer about an authoritative mutation, including game-owned shared data.
func mark_dirty(key := "") -> void:
	dirty = true
	if _frozen_capture.has(key):
		_frozen_capture[key] = 0


## The live interval may have advanced bodies or timers since the last durable tick.
func freeze_level(key: String) -> void:
	_frozen_capture[key] = 0
	mark_dirty(key)


## Resume ordinary live capture before an actor enters this room.
func wake_level(key: String) -> void:
	_frozen_capture.erase(key)


## Bound the time from the FIRST departure, even under a continuous stream of leaves.
func checkpoint() -> void:
	mark_dirty()
	if _checkpoint_at < 0:
		_checkpoint_at = int(clock.call()) + checkpoint_msec


## Capture while the level and its registries still exist. Travel shares this queue.
func before_unload(players: Node) -> void:
	var key: String = players.world.entities.level_key
	if key == _active_key:
		_active_unloaded = true
	var previous := _saved_scene(key, players.active_level())
	var row := _capture_level(key, players)
	if previous.has("import_alias"):
		row.import_alias = previous.import_alias
	elif previous.get("imported", false) and previous.id != key:
		row.import_alias = previous.id
	_unpublished_levels[key] = row
	checkpoint()


## The exact empty-room snapshot has been accepted by the writer.
func evicted(key: String) -> void:
	if key == _active_key:
		_active_unloaded = true


## Capture before detach. pending supplies the next incarnation even after a successful write.
func departing(id: String, actor: CogitoPlayerAdvanced, players: Node) -> void:
	var row := lives.capture(id, actor, players)
	lives.retained[id] = row
	lives.pending[id] = row
	checkpoint()


## Startup failures must never publish a partially restored level.
func can_flush() -> bool:
	return restore_error == OK and not _active_key.is_empty()


## A synchronous caller needs a definitive result. Scheduled work stays queued while busy.
func save(players: Node, tick: int) -> Error:
	if _job:
		request_save()
		return ERR_BUSY
	return _save(players, tick, [], false)


## Menu and request-file callers get eventual completion through save_finished.
func request_save() -> void:
	_manual = true


func _save(players: Node, tick: int, move: PackedStringArray, background: bool) -> Error:
	if busy:
		return ERR_BUSY
	if restore_error != OK:
		return restore_error
	var level: Node = players.active_level()
	if not is_instance_valid(level) or CogitoPersistentId.is_disappearing(level):
		if not _active_unloaded:
			return ERR_UNCONFIGURED
	busy = true
	capture_serial += 1
	dirty = false
	_manual = false
	_checkpoint_at = -1
	_saved_retained = lives.retained.duplicate()
	_saved_unloaded = _unpublished_levels.duplicate()
	var started := Time.get_ticks_usec()
	var batch := _capture(players, tick, _saved_retained, _saved_unloaded)
	var removed := PackedStringArray()
	var err := OK
	if not move.is_empty():
		err = _validate_move(players, move, batch.profiles)
		if err == OK:
			ProfileTools.apply_move(move, batch.profiles, files.profiles)
			removed.append(move[0])
		else:
			_move.clear()
	var frozen := files.prepare(batch.world, batch.scenes, batch.profiles, batch.aliases, removed)
	capture_usec = Time.get_ticks_usec() - started
	if background and err == OK:
		_job = WorldWrite.new(files, frozen, move)
		_job.start()
	else:
		started = Time.get_ticks_usec()
		if err == OK:
			err = files.publish(frozen)
		commit_usec = Time.get_ticks_usec() - started
		_finish(players, frozen, err)
	return err


func _finish(players: Node, batch: Dictionary, err: Error) -> void:
	if err == OK:
		files.accept(batch)
		# Newer departures and unloads may have replaced a row during this publication.
		for id: String in _saved_retained:
			if is_same(lives.retained.get(id), _saved_retained[id]):
				lives.retained.erase(id)
		for id: String in _saved_unloaded:
			if is_same(_unpublished_levels.get(id), _saved_unloaded[id]):
				_unpublished_levels.erase(id)
	else:
		for key: String in _frozen_capture:
			if _frozen_capture[key] == capture_serial:
				_frozen_capture[key] = 0
	_saved_retained.clear()
	_saved_unloaded.clear()
	if _operator_save:
		print("NET SAVE ", error_string(err), " generation=", files.manifest.get("generation", 0))
		_operator_save = false
	_record_result(players, err)
	busy = false


## Install the completed generation on the owner thread before the next capture.
func reap(players: Node, deadline := 0) -> bool:
	if _job:
		if not _job.join(deadline):
			return false
		var completed := _job
		_job = null
		commit_usec = completed.elapsed_usec
		var err := completed.result
		if not completed.move.is_empty():
			if err == OK:
				err = _seal_move(players, completed)
			var generation: int = files.manifest.get("generation", 0) + int(err == OK)
			print("NET REBIND ", error_string(err), " generation=", generation)
		_finish(players, completed.batch, err)
	return true


func _seal_move(players: Node, completed: WorldWrite) -> Error:
	var move := completed.move
	# A login or a new departure during staging invalidates the proposed replacement.
	# Leave .writing ineligible. The next transaction or startup recovers it.
	for id in move.slice(0, 2):
		var connected: bool = not players.get_parent().for_id(id).is_empty()
		if connected or not is_same(_saved_retained.get(id), lives.retained.get(id)):
			_move.clear()
			return ERR_ALREADY_IN_USE
	var err := files.seal()
	if err == OK:
		lives.forget(move[0], players)
		lives.install_row(move[1], completed.batch.profiles[move[1]], players)
		_move.clear()
	return err


## Bypass automatic backoff once and bound the combined wait for both publications.
func flush(players: Node, tick: int) -> Error:
	var deadline := Time.get_ticks_msec() + shutdown_wait_msec
	if not reap(players, deadline):
		return ERR_TIMEOUT
	if not _move.is_empty() and _validate_move(players, _move, lives.retained) != OK:
		printerr("NET REBIND refused during shutdown")
		_move.clear()
	var err := _save(players, tick, _move.duplicate(), true)
	if err != OK:
		return err
	return last_error if reap(players, deadline) else ERR_TIMEOUT


## A job which outlives the final deadline retains exclusive ownership until it completes.
func close() -> void:
	if _job:
		_job.retire()
		_job = null
	else:
		files.close()


## Only synchronous callbacks inside a capture must defer teardown to the next safe point.
func in_capture() -> bool:
	return busy and _job == null


func _capture(players: Node, tick: int, retained: Dictionary, unloaded: Dictionary) -> Dictionary:
	var scenes := unloaded.duplicate()
	var aliases := PackedStringArray()
	for row: Dictionary in unloaded.values():
		if row.has("import_alias"):
			aliases.append(row.import_alias)
	for level_key: String in levels:
		if _frozen_capture.get(level_key, 0) > 0:
			continue
		if _frozen_capture.has(level_key):
			_frozen_capture[level_key] = capture_serial
		var endpoint: Node = levels[level_key]
		if CogitoPersistentId.is_disappearing(endpoint.active_level()):
			continue
		var saved := _saved_scene(level_key, endpoint.active_level())
		if saved.get("imported", false) and saved.id != level_key:
			aliases.append(saved.id)
		scenes[level_key] = _capture_level(level_key, endpoint)
	for key: String in scenes:
		if scenes[key].has("import_alias"):
			scenes[key] = scenes[key].duplicate()
			scenes[key].erase("import_alias")
	var profiles := retained.duplicate()
	for member: Dictionary in players.get_parent().records():
		var endpoint: Node = players.travel.endpoint_for(member.player_id)
		var avatar: Variant = endpoint.avatar_for(member.player_id) if endpoint else null
		if avatar:
			profiles[member.player_id] = lives.capture(member.player_id, avatar.actor, endpoint)
	var shared: Dictionary = files.manifest.get("shared", {})
	if capture_shared.is_valid():
		shared = capture_shared.call()
	var world := {
		"active": _active_key,
		"tick": tick,
		"quests": players.quests.world.capture(),
		"shared": shared
	}
	return {"world": world, "scenes": scenes, "profiles": profiles, "aliases": aliases}


func _reset_timer(players: Node) -> void:
	_autosave_at = int(clock.call()) + int(players.get_parent().config.autosave_seconds) * 1000


func _record_result(players: Node, err: Error) -> void:
	last_error = err
	failure_message = ""
	if err == OK:
		_retry_at = -1
		_retry_delay = retry_initial_msec
		_reset_timer(players)
	else:
		mark_dirty()
		if _retry_at < 0:
			_retry_delay = retry_initial_msec
		_retry_at = int(clock.call()) + _retry_delay
		_retry_delay = mini(_retry_delay * 2, retry_cap_msec)
		var reason := files.storage.last_failure
		if reason.is_empty():
			reason = error_string(err)
		failure_message = "World save failed (%s)" % reason
		printerr("NET SAVE ", failure_message)
		var local: CogitoPlayer = players.travel.local_actor()
		if local:
			local.player_interaction_component.hint_prompt.emit(null, failure_message)
	save_finished.emit(err, files.manifest.get("generation", 0))


func _capture_level(key: String, players: Node) -> Dictionary:
	var level: Node = players.active_level()
	var scene := CogitoSceneManager._scene_persistence.capture(level)
	# Spawner lifecycle records own runtime roots. Never recreate one through both factories.
	scene.saved_nodes = scene.saved_nodes.filter(_offline_root)
	scene.saved_states = scene.saved_states.filter(_offline_root)
	var row := {
		"id": key,
		"path": level.scene_file_path,
		"scene": scene,
		"objects": players.world.capture(),
		"perception": players.npcs.capture(),
		"flights": players.projectiles.capture(),
		"bodies": players.bodies.capture(),
		"containers": players.containers.capture(),
		"holdings": players.spawner.room_holdings(),
	}
	if CogitoLevel.uses_room_clock(level):
		row.loot_timers = players.containers.capture_timers()
	return row.duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL)


func _offline_root(row: Dictionary) -> bool:
	return not str(row.get("cogito_id", "")).begins_with("runtime:")


## Sample only admitted players at the deadline. Compare with the last accepted generation,
## including changes that happened while the worker was publishing the previous tick.
func _players_changed(players: Node) -> bool:
	for record in players.get_parent().records():
		var id: String = record.player_id
		var endpoint: Node = players.travel.endpoint_for(id)
		var avatar: Variant = endpoint.avatar_for(id) if endpoint else null
		var saved: Dictionary = files.profiles.get(id, {})
		if avatar and (saved.is_empty() or _life_changed(avatar.actor, saved)):
			return true
	return false


func _life_changed(actor: CogitoPlayerAdvanced, saved: Dictionary) -> bool:
	if actor.position.distance_to(saved.pose.origin) >= movement_threshold:
		return true
	if actor.is_dead != saved.dead or actor.is_in_crouching_state() != saved.get("crouched", false):
		return true
	for attr: CogitoAttribute in actor.player_attributes.values():
		var pair: Variant = saved.attributes.get(attr.attribute_name)
		if pair == null or pair[1] != attr.value_max:
			return true
		if absf(pair[0] - attr.value_current) >= attribute_threshold:
			return true
	return false


## One drain per physics tick on either topology. Backoff applies to all automatic requests.
func poll(players: Node, tick: int) -> void:
	if not can_flush():
		return
	var now := int(clock.call())
	var operator_due := now >= _next_poll
	if operator_due:
		_next_poll = now + 1000
		if _consume_stop(players):
			return
	if not reap(players) or busy or (operator_due and _operator_request(players, tick)):
		return
	if _manual:
		_save(players, tick, [], true)
		return
	if not _move.is_empty() and (_retry_at < 0 or now >= _retry_at):
		_process_move(players, tick)
		return
	if _retry_at >= 0:
		if now >= _retry_at:
			_save(players, tick, [], true)
		return
	var due: bool = players.get_parent().config.autosave_seconds > 0 and now >= _autosave_at
	if due and not dirty:
		dirty = _players_changed(players)
		_reset_timer(players)
	if (due and dirty) or (_checkpoint_at >= 0 and now >= _checkpoint_at):
		_save(players, tick, [], true)


func _consume_stop(players: Node) -> bool:
	var stop := files.directory.path_join("stop.request")
	if players.get_parent().local_id.is_empty() and FileAccess.file_exists(stop):
		var removed := DirAccess.remove_absolute(stop)
		if removed == OK:
			stop_requested.emit()
		else:
			_inbox_error("STOP", removed)
		return true
	return false


func _operator_request(players: Node, tick: int) -> bool:
	var path := files.directory.path_join("save.request")
	if not FileAccess.file_exists(path):
		if players.get_parent().local_id.is_empty() and _kick_request(players):
			return true
		return _profile_request(players, tick)
	var err := DirAccess.remove_absolute(path)
	if err == OK:
		_operator_save = true
		err = _save(players, tick, [], true)
	if err != OK:
		_operator_save = false
		_inbox_error("SAVE", err)
	return true


func _kick_request(players: Node) -> bool:
	var path := files.directory.path_join("kick.request")
	if not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		_inbox_error("KICK", FileAccess.get_open_error())
		return true
	var target := file.get_as_text().strip_edges() if file.get_length() <= 4096 else ""
	file.close()
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		_inbox_error("KICK", err)
	else:
		err = players.get_parent().get_parent().roster.kick(target)
		print("NET KICK ", error_string(err))
	return true


func _profile_request(players: Node, tick: int) -> bool:
	var list_path := files.directory.path_join("list.request")
	if FileAccess.file_exists(list_path):
		var removed := DirAccess.remove_absolute(list_path)
		if removed != OK:
			_inbox_error("LIST", removed)
			return false
		var records := files.profiles.duplicate()
		records.merge(lives.retained, true)
		for member in players.get_parent().records():
			var endpoint: Node = players.travel.endpoint_for(member.player_id)
			var avatar: Variant = endpoint.avatar_for(member.player_id) if endpoint else null
			if avatar:
				records[member.player_id] = lives.capture(member.player_id, avatar.actor, endpoint)
		ProfileTools.list_profiles(records)
		for row: Dictionary in players.get_parent().get_parent().roster.connected():
			print("NET CONNECTED ", JSON.stringify(row))
	var path := files.directory.path_join("rebind.request")
	if not _move.is_empty() or not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		_inbox_error("REBIND", FileAccess.get_open_error())
		return false
	var command := file.get_as_text() if file.get_length() <= 4096 else ""
	file.close()
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		_inbox_error("REBIND", err)
		return false
	_move = ProfileTools.parse_move(command)
	_process_move(players, tick)
	return true


# A read-only inbox may still be present on every poll. Limit diagnostics per request kind.
func _inbox_error(operation: String, err: Error) -> void:
	var now := int(clock.call())
	if now >= int(_inbox_reports.get(operation, 0)):
		printerr("NET ", operation, " request: ", error_string(err))
		_inbox_reports[operation] = now + retry_cap_msec


func _validate_move(players: Node, move: PackedStringArray, fresh: Dictionary) -> Error:
	for id in move.slice(0, 2):
		if not players.get_parent().for_id(id).is_empty():
			return ERR_ALREADY_IN_USE
	var records := files.profiles.duplicate()
	records.merge(fresh, true)
	return operator.validate(move, records)


func _process_move(players: Node, tick: int) -> void:
	var err := _validate_move(players, _move, lives.retained)
	if err == OK:
		err = _save(players, tick, _move.duplicate(), true)
	else:
		_move.clear()
	if err != OK:
		print("NET REBIND ", error_string(err), " generation=", files.manifest.get("generation", 0))

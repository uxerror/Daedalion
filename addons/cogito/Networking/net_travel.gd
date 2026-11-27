extends Node
## Session-level rendezvous. Gameplay RPCs stay on the endpoint of the receiving room.

## A local live hint, editable before the HUD displays it.
signal notice_received(event: Dictionary)
## Authority or owner receives the current transfer failure.
signal failed(player_id: String, reason: String)

const Residency := preload("net_level_residency.gd")
const Zone := preload("../Scripts/scene_transition_zone.gd")

var primary_key := ""
var levels := {}
var pending := {}
var managed := false
var loading := false
var residency := Residency.new()
var host := CogitoLevelHost.new()
var _serial := 0
var _grace := {}
var _evicting := {}
var _prepared := {}
var _client := {}
var _client_token := 0
var _overlay: CanvasLayer
var _policy := CogitoTravelPolicy.new()


func _ready() -> void:
	host.dedicated = _facade().is_dedicated()
	var config: Dictionary = _session().config
	if config.has("level_residency"):
		host.room_clock = config.level_residency != "stream" or _facade().travel_policy != null
	add_child(host)
	set_process(false)
	get_parent().get_parent().left.connect(_left)


func _session() -> Node:
	return get_parent().get_parent()


func _facade() -> Node:
	return _session().get_parent()


## Session-unique lifetime, subscription nonce or level epoch.
func next_serial() -> int:
	_serial += 1
	return _serial


## Find the owning endpoint without exposing foreign avatars to level-local gameplay.
func endpoint_for(id: String) -> Node:
	for endpoint: Node in levels.values():
		if endpoint.avatar_for(id):
			return endpoint
	return null


## Current presentation owner, including a listen host visiting a secondary level.
func local_actor() -> CogitoPlayerAdvanced:
	var endpoint := endpoint_for(_session().local_id)
	return endpoint.local_actor if endpoint else null


## Bind a game-selected scene. A running window scene becomes the first hosted world.
func bind_scene(root: Node, marker: Transform3D, key: String) -> void:
	if root.has_meta(&"cogito_net_players") or root.has_meta(&"network_level_key"):
		return
	if root == get_tree().current_scene and root.get_parent() == get_tree().root:
		root.set_meta(&"network_start", marker)
		managed = multiplayer.is_server()
		if managed and _session().config.level_residency == "preload_all":
			key = get_parent().persistence.files.manifest.get("active", key)
		host.adopt_level(root, key)
	get_parent().bind_level(root, marker, key)
	if not multiplayer.is_server() and host.level(key):
		host.present(key)


## Bootstrap the persistent server's first room. Clients receive their path on admission.
func start(path: String) -> Error:
	if levels.has(primary_key) and levels[primary_key].active_level().scene_file_path == path:
		return get_parent().persistence.restore_error
	managed = true
	var files: Variant = get_parent().persistence.files
	primary_key = files.manifest.get("active", path)
	loading = true
	var root := host.load_level(path, primary_key, true)
	if not _bind_installed(primary_key, root, true):
		residency.failure = "Cannot load starting level " + path
		return ERR_CANT_CREATE
	var err := finish_preload(root)
	if err != OK:
		return err
	for record: Dictionary in _session().records():
		admit(record.player_id)
	_track_empty(primary_key)
	return OK


## Open admission only after every configured room has bound its saved state.
func finish_preload(root: Node) -> Error:
	var config: Dictionary = _session().config
	if config.level_residency == "preload_all":
		var err: Error = residency.preload_rooms(self, root, config.preload_levels)
		if err != OK:
			get_parent().persistence.restore_error = err
			push_error(residency.failure)
			return err
	multiplayer.multiplayer_peer.refuse_new_connections = false
	return OK


func _install(key: String, packed: PackedScene) -> Node:
	loading = true
	return _bind_installed(key, host.install_level(packed, key, true))


func _bind_installed(key: String, root: Node, startup := false) -> Node:
	if not root:
		loading = false
		return null
	if not root.has_meta(&"cogito_net_players"):
		get_parent().bind_level(root, root.get_meta(&"network_start", Transform3D.IDENTITY), key)
	loading = false
	var writer: Variant = get_parent().persistence
	if writer and writer.restore_error != OK:
		host.unload_level(key, false)
		if not startup:
			writer.discard_restore(key)
		return null
	return root.get_meta(&"cogito_net_players", null)


## A game-owned bootstrap can bind the first loaded scene with its own durable key.
func adopt_key(root: Node, key: String) -> void:
	if levels.is_empty() and key != primary_key and host.level(primary_key) == root:
		host.rename_key(primary_key, key)
		primary_key = key


## Choose the saved room on takeover, reconnect and restart before creating any actor.
func admit(id: String) -> void:
	if not multiplayer.is_server() or primary_key.is_empty() or endpoint_for(id) or pending.has(id):
		return
	var players := get_parent()
	var key := primary_key
	var writer: Variant = players.persistence
	if writer and writer.lives.pending.has(id):
		key = writer.lives.pending[id].level
	if not managed and key == primary_key and levels.has(key):
		players._joined(id)
		return
	var path := key
	if levels.has(key):
		path = levels[key].active_level().scene_file_path
	elif writer and writer.files.scenes.has(key):
		path = writer.files.scenes[key].path
	pending[id] = _request("", key, path, "")
	_reuse(key)
	if id == _session().local_id and levels.has(key):
		_prepare(id, pending[id])


func _request(source: String, key: String, path: String, connector: String) -> Dictionary:
	return {
		"source": source,
		"key": key,
		"path": path,
		"connector": connector,
		"token": next_serial(),
		"stage": "prepare",
		"capture": 0,
		"attachments": {},
		"deadline": _now() + _session().config.travel_timeout_seconds * 1000,
	}


func _now() -> int:
	return get_parent().persistence.clock.call()


## Resolve game policy on the authority at each transfer.
func rules() -> CogitoTravelPolicy:
	var custom: CogitoTravelPolicy = _facade().travel_policy
	return custom if custom else _policy


## Only a server physics overlap selects the route. Simultaneous entries coalesce by identity.
func enter(zone: Area3D, actor: CogitoPlayerAdvanced) -> void:
	if not multiplayer.is_server() or not zone is Zone or not zone.overlaps_body(actor):
		return
	var source := CogitoLevel.hosted_root(actor)
	if not source or CogitoLevel.hosted_root(zone) != source:
		return
	if not source.has_meta(&"cogito_net_players"):
		return
	var zone_path := str(source.get_path_to(zone))
	var arrivals: PackedStringArray = actor.get_meta(&"travel_arrival_zones", PackedStringArray())
	if zone_path in arrivals or actor.get_meta(&"travel_spawn_zone", "") == zone_path:
		return
	var endpoint: Node = source.get_meta(&"cogito_net_players")
	if endpoint.travel != self or actor.is_dead or not endpoint.peer_for_actor(actor):
		return
	var path := Residency.scene_path(zone.target_scene_path)
	if path == source.scene_file_path:
		return
	var key := _key_for_path(path)
	var policy := rules()
	for member in policy.participants(actor, zone):
		if not is_instance_valid(member) or member.is_dead or not endpoint.peer_for_actor(member):
			continue
		var id: String = member.get_meta(&"net_player_id")
		if pending.has(id):
			continue
		var req := _request(endpoint.world.entities.level_key, key, path, zone.target_connector)
		req.attachments = policy.attachments(member)
		req.zone = zone_path
		req.input_blocked = member.network_input_blocked
		member.network_input_blocked = true
		pending[id] = req
		_reuse(key)


# A connector may be inside one or more reverse zones. Arm each only on actual exit.
func _guard_connector(actor: CogitoPlayerAdvanced) -> void:
	var shape := actor.standing_collision_shape
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape.shape
	query.transform = shape.global_transform
	query.collision_mask = 0xffffffff
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var root := CogitoLevel.hosted_root(actor)
	var guarded := PackedStringArray()
	for hit in actor.get_world_3d().direct_space_state.intersect_shape(query):
		if hit.collider is Zone:
			guarded.append(str(root.get_path_to(hit.collider)))
	if not guarded.is_empty():
		actor.set_meta(&"travel_arrival_zones", guarded)


func _key_for_path(path: String) -> String:
	for key: String in levels:
		if levels[key].active_level().scene_file_path == path:
			return key
	var files: Variant = get_parent().persistence.files
	for key: String in files.scenes:
		if files.scenes[key].path == path and not files.scenes[key].get("imported", false):
			return key
	return path


## Runs before the single MP9 writer polls. A request cannot consume an earlier in-flight save.
func advance() -> void:
	var writer: Variant = get_parent().persistence
	if not writer.save_finished.is_connected(_published):
		writer.save_finished.connect(_published)
	for id: String in pending.keys():
		var req: Dictionary = pending[id]
		if _now() >= req.deadline:
			_timeout(id, req)
		elif req.stage == "prepare":
			_prepare(id, req)
	_grace_tick()


func _resource(path: String) -> Variant:
	if not path.begins_with("res://") or not ResourceLoader.exists(path, "PackedScene"):
		return ERR_FILE_NOT_FOUND
	var status := ResourceLoader.load_threaded_get_status(path)
	if status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		return ResourceLoader.load_threaded_request(path, "PackedScene")
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return OK
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		return ResourceLoader.load_threaded_get(path)
	return ERR_CANT_OPEN


# Construct off-tree, then attach on a subsequent frame. PackedScene instantiation and tree
# callbacks run on the main thread. Allow occupied rooms to advance between these costs.
func _prepare_room(key: String, path: String) -> Variant:
	if _prepared.has(key):
		var job: Dictionary = _prepared[key]
		if Engine.get_process_frames() == job.frame:
			return OK
		_prepared.erase(key)
		loading = true
		var root := host.mount_level(job.root, key, true)
		root.set_meta(&"travel_mount_frame", Engine.get_process_frames())
		return _bind_installed(key, root)
	var result: Variant = _resource(path)
	if result is PackedScene:
		var root := host.prepare_level(result, key, true)
		if not root:
			return ERR_CANT_CREATE
		_prepared[key] = {"root": root, "frame": Engine.get_process_frames()}
		return OK
	return result


func _prepare(id: String, req: Dictionary) -> void:
	if id == _session().local_id and not req.source.is_empty():
		_show_loading()
	var target: Node = levels.get(req.key)
	if not target:
		var result: Variant = _prepare_room(req.key, req.path)
		if result is int and result == OK:
			return
		if result is Node:
			target = result
	if target:
		var mounted: int = target.active_level().get_meta(&"travel_mount_frame", -1)
		if mounted == Engine.get_process_frames():
			return
	if not target:
		if req.source.is_empty():
			_recover(id, req, "Cannot load travel destination")
		else:
			_fail(id, "Cannot load travel destination")
	elif req.source.is_empty():
		_offer(id, req)
	elif not _connector(req):
		_fail(id, "Missing destination connector")
	else:
		var source: Node = levels[req.source]
		var peer: int = source.peer_for_actor(source.avatar_for(id).actor)
		source.interactions.interrupt_actor(peer)
		source.containers.forget(peer)
		var writer: Variant = get_parent().persistence
		req.capture = writer.capture_serial + 1
		req.stage = "checkpoint"
		writer.request_save()


func _connector(req: Dictionary) -> Node3D:
	var root: Node = levels[req.key].active_level()
	if "connectors" in root:
		for marker: Node3D in root.connectors:
			if is_instance_valid(marker) and marker.name == req.connector:
				if not root.is_ancestor_of(marker):
					continue
				return marker
	return null


func _published(err: Error, _generation: int) -> void:
	var writer: Variant = get_parent().persistence
	for id: String in pending.keys():
		var req: Dictionary = pending[id]
		if req.stage == "checkpoint" and req.capture == writer.capture_serial:
			if err == OK:
				_offer(id, req)
			else:
				_fail(id, writer.failure_message)
	for key: String in _evicting.keys():
		if _evicting[key] == writer.capture_serial:
			_evicting.erase(key)
			if err == OK and not _occupied(key):
				_grace.erase(key)
				writer.evicted(key)
				host.unload_level(key, false)
			else:
				var root := host.level(key)
				if root:
					_pause_empty(key, false)
				_grace[key] = _now() + maxi(writer.retry_initial_msec, 1)


func _offer(id: String, req: Dictionary) -> void:
	var endpoint: Node = levels[req.key]
	var epoch: int = endpoint.world.entities.epoch
	var peer: int = _session().for_id(id).peer_id
	req.stage = "ready"
	req.deadline = _now() + _session().config.travel_timeout_seconds * 1000
	if peer == 1:
		if not req.source.is_empty():
			_show_loading()
		_commit(id, req, 0)
	else:
		# Detach observer streams while its client replaces its own level tree.
		var source: Node = levels.get(req.source)
		if source:
			source._ready_levels.erase(peer)
			source.world.forget(peer)
		_load_room.rpc_id(peer, req.token, primary_key, req.key, req.path, epoch)


@rpc("authority", "call_remote", "reliable", 0)
func _load_room(token: int, first: String, key: String, path: String, epoch: int) -> void:
	if token <= _client_token:
		return
	_client_token = token
	primary_key = first
	_client = {"key": key, "path": path, "epoch": epoch}
	_show_loading()
	set_process(true)


func _process(_delta: float) -> void:
	var key: String = _client.key
	var endpoint: Node = levels.get(key)
	if not endpoint:
		var result: Variant = _resource(_client.path)
		if result is int and result == OK:
			return
		if result is PackedScene:
			_retire_client_room(key)
			endpoint = _install(key, result)
	set_process(false)
	if endpoint:
		_present(key)
		_loaded.rpc_id(1, _client_token, key, _client.epoch, endpoint.world.binding())
	else:
		_loaded.rpc_id(1, _client_token, key, _client.epoch, 0)


func _retire_client_room(next: String) -> void:
	loading = true
	for key: String in levels.keys():
		if key == next:
			continue
		if host.level(key):
			host.unload_level(key, false)
		else:
			var root: Node = levels[key].active_level()
			levels[key].unbind_level()
			root.queue_free()
	loading = false


@rpc("any_peer", "call_remote", "reliable", 0)
func _loaded(token: int, key: String, epoch: int, binding: int) -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	var id: String = _session().for_peer(peer).get("player_id", "")
	var req: Dictionary = pending.get(id, {})
	if req.get("token") != token or req.stage != "ready" or req.key != key:
		return
	if levels[key].world.entities.epoch != epoch:
		return
	if binding <= 0:
		_recover(id, req, "Cannot install travel destination")
	else:
		_commit(id, req, binding)


func _commit(id: String, req: Dictionary, binding: int) -> void:
	var target: Node = levels[req.key]
	var peer: int = _session().for_id(id).peer_id
	var source: Node = levels.get(req.source)
	var pose: Variant
	residency.wake(req.key, target)
	if source:
		var actor: CogitoPlayerAdvanced = source.avatar_for(id).actor
		pose = rules().placement(actor, _connector(req), target)
		if pose == null or actor.is_dead:
			_recover(id, req, "Destination blocked or actor unavailable")
			return
		for observer: int in source._ready_levels:
			if source._visible(observer, id):
				_departed.rpc_id(observer, req.source, id, source.avatar_for(id).lifetime)
		rules().departing(actor, req.attachments, source)
		source._remove(id)
		var row: Dictionary = target.persistence.lives.pending[id].duplicate()
		row.erase("travel_zone")
		row.level = req.key
		row.pose = pose
		target.persistence.lives.pending[id] = row
	if peer == 1:
		_present(req.key)
	target._joined(id, pose, req.attachments)
	_guard_connector(target.avatar_for(id).actor)
	if peer != 1:
		target.accept_ready(peer, req.key, binding)
		_finished.rpc_id(peer, req.token)
	else:
		_hide_loading()
	pending.erase(id)
	if source:
		_notify(source, peer, id, target, false)
		_notify(target, peer, id, source, true)
		target.persistence.checkpoint()
		_track_empty(req.source)


@rpc("authority", "call_remote", "reliable", 0)
func _departed(key: String, id: String, life: int) -> void:
	var endpoint: Node = levels.get(key)
	var avatar: Variant = endpoint.avatar_for(id) if endpoint else null
	if avatar and avatar.lifetime == life:
		endpoint._remove(id)


func _present(key: String) -> void:
	host.present(key)
	var root: Node = levels[key].active_level()
	if "music_state" in root:
		CogitoAudio.set_scene_music_state(root.music_state, root.combat_music_state)


func _show_loading() -> void:
	if _overlay or _facade().menu.pending:
		return
	_overlay = CanvasLayer.new()
	_overlay.layer = 120
	add_child(_overlay)
	var panel := ColorRect.new()
	panel.color = Color.BLACK
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(panel)
	var label := Label.new()
	label.text = tr("Loading…")
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(label)
	panel.modulate.a = 0
	panel.create_tween().tween_property(panel, "modulate:a", 1.0, 0.15)


@rpc("authority", "call_remote", "reliable", 0)
func _finished(token: int) -> void:
	if token == _client_token:
		_hide_loading()


func _hide_loading() -> void:
	if _overlay:
		var layer := _overlay
		_overlay = null
		var fade := layer.create_tween()
		fade.tween_property(layer.get_child(0), "modulate:a", 0.0, 0.12)
		fade.tween_callback(layer.queue_free)


## Display name shared by travel notices and the pause roster.
func level_title(endpoint: Node) -> String:
	var root: Node = endpoint.active_level()
	if "level_display_name" in root and not root.level_display_name.is_empty():
		return root.level_display_name
	return root.scene_file_path.get_file().get_basename()


func _notify(endpoint: Node, except_peer: int, id: String, other: Node, arrived: bool) -> void:
	var title := level_title(other)
	var who: String = _session().for_id(id).display_name
	var room: String = endpoint.world.entities.level_key
	for member: Dictionary in _session().records():
		var peer: int = member.peer_id
		if peer != except_peer and endpoint.peer_in_level(peer):
			if peer == 1:
				_notice(room, who, title, arrived)
			else:
				_notice.rpc_id(peer, room, who, title, arrived)


@rpc("authority", "call_remote", "reliable", 0)
func _notice(room: String, who: String, title: String, arrived: bool) -> void:
	var endpoint: Node = levels.get(room)
	if endpoint and endpoint.local_actor:
		var pattern := tr("%s arrived from %s") if arrived else tr("%s left for %s")
		var event := {"text": pattern % [who, tr(title)], "arrived": arrived, "level": title}
		notice_received.emit(event)
		if not event.text.is_empty():
			endpoint.local_actor.player_interaction_component.hint_prompt.emit(null, event.text)


func _recover(id: String, req: Dictionary, reason: String) -> void:
	var peer: int = _session().for_id(id).peer_id
	_fail(id, reason)
	if peer != 1:
		if req.source.is_empty():
			_session().expire_peer(peer, reason)
		else:
			var source: Node = levels[req.source]
			var retry := _request("", req.source, source.active_level().scene_file_path, "")
			pending[id] = retry
			_offer(id, retry)


func _fail(id: String, reason: String) -> void:
	var req: Dictionary = pending[id]
	var source: Node = levels.get(req.source)
	if source and source.avatar_for(id):
		source.avatar_for(id).actor.network_input_blocked = req.get("input_blocked", false)
	pending.erase(id)
	_track_empty(req.key)
	var peer: int = _session().for_id(id).peer_id
	if peer == 1:
		_hide_loading()
	elif peer:
		_error.rpc_id(peer, id, reason)
	_error(id, reason)


@rpc("authority", "call_remote", "reliable", 0)
func _error(id: String, reason: String) -> void:
	failed.emit(id, reason)
	var actor := local_actor()
	if actor and id == _session().local_id:
		actor.player_interaction_component.hint_prompt.emit(null, reason)
	push_warning(reason)


func _timeout(id: String, req: Dictionary) -> void:
	var peer: int = _session().for_id(id).peer_id
	var awaiting: bool = req.stage == "ready" or req.source.is_empty()
	var source: Node = levels.get(req.source)
	if awaiting and source and source.avatar_for(id):
		source.avatar_for(id).actor.set_meta(&"travel_spawn_zone", req.zone)
	_fail(id, "Level travel timed out")
	if awaiting and peer != 1:
		_session().expire_peer(peer, "Level travel timed out")


func _left(id: String) -> void:
	if not multiplayer.is_server():
		return
	var endpoint := endpoint_for(id)
	var req: Dictionary = pending.get(id, {})
	if endpoint and req.has("zone"):
		endpoint.avatar_for(id).actor.set_meta(&"travel_spawn_zone", req.zone)
	pending.erase(id)
	if not req.is_empty():
		_track_empty(req.key)
	if endpoint:
		_track_empty(endpoint.world.entities.level_key)


func _occupied(key: String) -> bool:
	for req: Dictionary in pending.values():
		if req.key == key or req.source == key:
			return true
	for member: Dictionary in _session().records():
		if levels[key].avatar_for(member.player_id):
			return true
	return false


func _reuse(key: String) -> void:
	_grace.erase(key)
	if _evicting.erase(key) and host.level(key):
		_pause_empty(key, false)


func _track_empty(key: String) -> void:
	if _prepared.has(key):
		for req: Dictionary in pending.values():
			if req.key == key:
				return
		_prepared[key].root.free()
		_prepared.erase(key)
	if host.level(key) and not residency.frozen(key) and not _occupied(key):
		_grace[key] = _now() + _session().config.level_grace_seconds * 1000


# Ballistics runs on the session endpoint outside the paused scene tree.
func _pause_empty(key: String, pause: bool) -> void:
	var root := host.level(key)
	var flights: Node = levels[key].projectiles
	if pause:
		root.set_meta(&"travel_process_mode", root.process_mode)
		root.set_meta(&"travel_ballistics", flights.is_physics_processing())
		flights.set_physics_process(false)
		root.process_mode = Node.PROCESS_MODE_DISABLED
	else:
		root.process_mode = root.get_meta(&"travel_process_mode")
		flights.set_physics_process(root.get_meta(&"travel_ballistics"))


func _grace_tick() -> void:
	for key: String in _grace.keys():
		if not levels.has(key) or _occupied(key):
			_grace.erase(key)
		elif _now() >= _grace[key] and not _evicting.has(key):
			if _session().config.level_residency != "stream" or not rules().should_unload(key):
				_grace.erase(key)
				residency.freeze(key, levels[key])
				continue
			var writer: Variant = get_parent().persistence
			_pause_empty(key, true)
			_evicting[key] = writer.capture_serial + 1
			writer.request_save()


## Tear down level owners while their session RPC paths and local presentation still exist.
func shutdown() -> void:
	loading = true
	for job: Dictionary in _prepared.values():
		job.root.free()
	_prepared.clear()
	pending.clear()
	for endpoint: Node in levels.values():
		endpoint.persistence = null
		endpoint.clear()
	for key: StringName in host._levels.keys():
		host.unload_level(key, false)

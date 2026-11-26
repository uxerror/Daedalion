extends RefCounted
## Authority-owned coordinator. Capture and verified publication do not yield to another tick.

const Files := preload("../SceneManagement/cogito_world_files.gd")
const Import := preload("net_solo_import.gd")
const Profiles := preload("net_profiles.gd")
const Reconnect := preload("net_reconnect_policy.gd")

var files := Files.new()
var lives := Profiles.new()
var levels := {}
var placement: Resource = Reconnect.new()
var capture_shared: Callable
var apply_shared: Callable
var match_legacy_object: Callable
var busy := false
var restore_error := OK
var _next_poll := 0
var _bound_first := false
var _prepared := {}
var _unpublished_levels := {}


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
		CogitoSceneManager._scene_persistence.restore_world_nodes(state, root)
		_prepared[key] = state


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
	levels[key] = players
	var root: Node = players.active_level()
	var data := _saved_scene(key, root)
	if data.is_empty():
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
	players.containers.restore(data.containers)
	players.npcs.restore(data.get("perception", {}))
	CogitoSceneManager._scene_persistence.restore_world_components(scene, root)
	if data.get("imported", false):
		# Solo records encode death in the saved health attribute.
		for npc: CogitoNPC in players.npcs.tracked:
			npc.network_state.dead = npc.is_dead()
			var id: String = players.world.entities.id_for(npc)
			players.world.restore({id: npc.net_state()})


## Keep a first visit in memory if its host unloads it before the first manual commit.
func before_unload(players: Node) -> void:
	var key: String = players.world.entities.level_key
	if not files.scenes.has(key):
		_unpublished_levels[key] = _capture_level(key, players)


## All resources are frozen before staging starts. Only this authority can publish.
func save(players: Node, tick: int) -> Error:
	if busy:
		return ERR_BUSY
	if restore_error != OK:
		return restore_error
	var level: Node = players.active_level()
	if not is_instance_valid(level) or CogitoPersistentId.is_disappearing(level):
		return ERR_UNCONFIGURED
	busy = true
	var key: String = players.world.entities.level_key
	var scenes := _unpublished_levels.duplicate()
	var aliases := PackedStringArray()
	for level_key: String in levels:
		var endpoint: Node = levels[level_key]
		if CogitoPersistentId.is_disappearing(endpoint.active_level()):
			continue
		var saved := _saved_scene(level_key, endpoint.active_level())
		if saved.get("imported", false) and saved.id != level_key:
			aliases.append(saved.id)
		scenes[level_key] = _capture_level(level_key, endpoint)
	var profiles := lives.retained.duplicate(true)
	for member: Dictionary in players.get_parent().records():
		var avatar: Variant = players.avatar_for(member.player_id)
		if avatar:
			profiles[member.player_id] = lives.capture(member.player_id, avatar.actor, players)
	var shared: Dictionary = files.manifest.get("shared", {})
	if capture_shared.is_valid():
		shared = capture_shared.call()
	var world := {
		"active": key, "tick": tick, "quests": players.quests.world.capture(), "shared": shared
	}
	var err := files.commit(world, scenes, profiles, aliases)
	if err == OK:
		lives.retained.clear()
		_unpublished_levels.clear()
	busy = false
	return err


func _capture_level(key: String, players: Node) -> Dictionary:
	var level: Node = players.active_level()
	var scene := CogitoSceneManager._scene_persistence.capture(level)
	# Spawner lifecycle records own runtime roots. Never recreate one through both factories.
	scene.saved_nodes = scene.saved_nodes.filter(_offline_root)
	scene.saved_states = scene.saved_states.filter(_offline_root)
	return {
		"id": key,
		"path": level.scene_file_path,
		"scene": scene.duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL),
		"objects": players.world.capture(),
		"perception": players.npcs.capture(),
		"flights": players.projectiles.capture(),
		"bodies": players.bodies.capture(),
		"containers": players.containers.capture(),
	}


func _offline_root(row: Dictionary) -> bool:
	return not str(row.get("cogito_id", "")).begins_with("runtime:")


## A consumed operator request has one logged result; failures require another manual request.
func poll(players: Node, tick: int) -> void:
	var now := Time.get_ticks_msec()
	if now < _next_poll:
		return
	_next_poll = now + 1000
	var path := files.directory.path_join("save.request")
	if FileAccess.file_exists(path):
		var err := DirAccess.remove_absolute(path)
		if err == OK:
			err = save(players, tick)
		print("NET SAVE ", error_string(err), " generation=", files.manifest.get("generation", 0))

extends RefCounted
## Authority-only preload traversal and suspension of isolated server rooms.

const Zone := preload("../Scripts/scene_transition_zone.gd")

var failure := ""
var _sleeping := {}


## Resolve both scene paths and the UIDs authored by the demo connectors.
static func scene_path(value: String) -> String:
	if value.begins_with("uid://"):
		var id := ResourceUID.text_to_id(value)
		return ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""
	return value.simplify_path() if value.begins_with("res://") else value


## Walk the mounted rooms. A cycle or duplicate seed never binds or restores twice.
func preload_rooms(travel: Node, first: Node, seeds: Array) -> Error:
	var discover := "auto" in seeds
	var queue: Array = seeds.duplicate()
	if discover:
		queue.append_array(_targets(first))
	var visited := {first.scene_file_path: true}
	var index := 0
	while index < queue.size():
		var entry: String = queue[index]
		index += 1
		var path := scene_path(entry)
		if visited.has(path) or entry == "auto":
			continue
		visited[path] = true
		var key: String = travel._key_for_path(path)
		travel.loading = true
		var root: Node = travel.host.load_level(path, key, true)
		if not travel._bind_installed(key, root, true):
			var err: Error = travel.get_parent().persistence.restore_error
			if err == OK:
				err = ERR_CANT_CREATE
			failure = "Cannot preload level %s (%s)" % [entry, error_string(err)]
			return err
		travel._track_empty(key)
		if discover:
			queue.append_array(_targets(root))
	return OK


func _targets(root: Node) -> Array[String]:
	var paths: Array[String] = []
	for area in root.find_children("*", "Area3D", true, false):
		if area is Zone:
			paths.append(area.target_scene_path)
	return paths


## True from grace expiry through the next successful load acknowledgement.
func frozen(key: String) -> bool:
	return _sleeping.has(key)


## Keep bodies in their Jolt space so contacts, velocity and sleep state survive re-entry.
func freeze(key: String, endpoint: Node) -> void:
	var root: Node = endpoint.active_level()
	var modes := {root: root.process_mode}
	var collisions := {}
	var world := root.get_viewport().find_world_3d()
	var physics_active := PhysicsServer3D.space_is_active(world.space)
	var nav_active := NavigationServer3D.map_is_active(world.navigation_map)
	PhysicsServer3D.space_set_active(world.space, false)
	NavigationServer3D.map_set_active(world.navigation_map, false)
	var nodes := root.find_children("*", "", true, false)
	nodes.append(root)
	for node in nodes:
		if node.process_mode not in [Node.PROCESS_MODE_INHERIT, Node.PROCESS_MODE_DISABLED]:
			modes[node] = node.process_mode
		if node is CollisionObject3D and node.can_process():
			collisions[node] = node.disable_mode
			node.disable_mode = CollisionObject3D.DISABLE_MODE_KEEP_ACTIVE
	var services := [endpoint.projectiles, endpoint.interactions.devices]
	for service: Node in services:
		modes[service] = service.process_mode
	for node: Node in modes:
		node.process_mode = Node.PROCESS_MODE_DISABLED
	_sleeping[key] = {
		"modes": modes,
		"collisions": collisions,
		"frame": Engine.get_physics_frames(),
		"physics_active": physics_active,
		"nav_active": nav_active,
	}
	endpoint.persistence.freeze_level(key)


## Restore processing ownership and reactivate the same physics and navigation maps.
func wake(key: String, endpoint: Node) -> void:
	if not _sleeping.has(key):
		return
	var state: Dictionary = _sleeping[key]
	_sleeping.erase(key)
	for node in state.modes:
		if is_instance_valid(node):
			node.process_mode = state.modes[node]
	for body in state.collisions:
		if is_instance_valid(body):
			body.disable_mode = state.collisions[body]
	for npc: CogitoNPC in endpoint.npcs.tracked:
		if npc.network_state.swing_tick >= 0:
			npc.network_state.swing_tick += Engine.get_physics_frames() - int(state.frame)
	var world: World3D = endpoint.active_level().get_viewport().find_world_3d()
	NavigationServer3D.map_set_active(world.navigation_map, state.nav_active)
	PhysicsServer3D.space_set_active(world.space, state.physics_active)
	endpoint.persistence.wake_level(key)

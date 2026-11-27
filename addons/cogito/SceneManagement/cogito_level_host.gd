class_name CogitoLevelHost
extends Node
## Owns independently simulated levels. Offline gameplay does not create a host.

var _surfaces: Dictionary[StringName, SubViewportContainer] = {}
var _levels: Dictionary[StringName, Node] = {}
var _silent_bus: StringName


class LevelViewport:
	extends SubViewport

	func _enter_tree() -> void:
		CogitoLevel._hosted_worlds += 1

	func _exit_tree() -> void:
		CogitoLevel._hosted_worlds -= 1


## Loads a scene into a minimal, non-rendering viewport. Repeated keys return the live root.
func load_level(path: String, key: StringName, network := false) -> Node:
	if _levels.has(key):
		return level(key)
	if key == &"" or not ResourceLoader.exists(path, "PackedScene"):
		return null
	var scene := load(path) as PackedScene
	if not scene or not scene.can_instantiate():
		return null
	return install_level(scene, key, network)


## Install a prepared resource. Online sessions remove the solo marker before tree entry.
func install_level(scene: PackedScene, key: StringName, network := false) -> Node:
	if _levels.has(key):
		return level(key)
	var root := prepare_level(scene, key, network)
	return mount_level(root, key, network) if root else null


## Instantiate detached so other rooms can tick before the new world enters the scene tree.
func prepare_level(scene: PackedScene, key: StringName, network: bool) -> Node:
	var root := scene.instantiate()
	if not root:
		return null
	if network:
		root.set_meta(&"network_level_key", key)
		var marker := root.get_node_or_null("Player") as Node3D
		if not marker:
			for child in root.get_children():
				if child is CogitoPlayer:
					marker = child
					break
		if marker:
			root.set_meta(&"network_start", marker.transform)
			marker.free()
	return root


## Move an already-running scene into its own world before admitting network players.
func adopt_level(root: Node, key: StringName) -> void:
	root.set_meta(&"network_level_key", key)
	root.get_parent().remove_child(root)
	mount_level(root, key, true)


## Attach a previously prepared room to its isolated physics and presentation world.
func mount_level(root: Node, key: StringName, network: bool) -> Node:
	root.add_to_group(CogitoLevel.HOSTED_ROOT)
	if not root.is_node_ready():
		root.ready.connect(CogitoPersistentId.stamp_level.bind(root), CONNECT_ONE_SHOT)

	var viewport := LevelViewport.new()
	viewport.size = Vector2i(2, 2)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.audio_listener_enable_2d = false
	viewport.audio_listener_enable_3d = false
	_levels[key] = root
	viewport.add_child(root)
	if network:
		if not get_tree().node_added.is_connected(_route_audio):
			get_tree().node_added.connect(_route_audio)
		var surface := SubViewportContainer.new()
		surface.hide()
		surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_surfaces[key] = surface
		add_child(surface)
		surface.add_child(viewport)
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	else:
		add_child(viewport)
	return root


## Route window input, video and audio only to the room containing the local controller.
func present(key: StringName) -> void:
	for id: StringName in _surfaces:
		var surface := _surfaces[id]
		var viewport := level(id).get_viewport() as SubViewport
		if surface.visible != (id == key):
			surface.visible = id == key
			for player in level(id).find_children("*", "AudioStreamPlayer", true, false):
				_route_audio(player)
		surface.stretch = surface.visible
		if not surface.visible:
			viewport.size = Vector2i(2, 2)
		viewport.audio_listener_enable_2d = surface.visible
		viewport.audio_listener_enable_3d = surface.visible
		viewport.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if surface.visible else SubViewport.UPDATE_DISABLED
		)


# Non-spatial AudioStreamPlayers bypass viewport listeners, including authored autoplay.
func _route_audio(node: Node) -> void:
	if not node is AudioStreamPlayer:
		return
	var surface := node.get_viewport().get_parent() as SubViewportContainer
	if not surface or surface.get_parent() != self:
		return
	if surface.visible:
		if node.has_meta(&"level_audio_bus"):
			node.bus = node.get_meta(&"level_audio_bus")
			node.remove_meta(&"level_audio_bus")
	elif not node.has_meta(&"level_audio_bus"):
		if _silent_bus.is_empty():
			_silent_bus = StringName("CogitoLevel_%d" % get_instance_id())
			AudioServer.add_bus()
			var index := AudioServer.bus_count - 1
			AudioServer.set_bus_name(index, _silent_bus)
			AudioServer.set_bus_mute(index, true)
		node.set_meta(&"level_audio_bus", node.bus)
		node.bus = _silent_bus


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_route_audio):
		get_tree().node_added.disconnect(_route_audio)
	if not _silent_bus.is_empty():
		var index := AudioServer.get_bus_index(_silent_bus)
		if index >= 0:
			AudioServer.remove_bus(index)
		_silent_bus = &""


## Apply the durable key supplied by a game bootstrap during scene readiness.
func rename_key(old_key: StringName, key: StringName) -> void:
	_levels[key] = _levels[old_key]
	_levels.erase(old_key)
	if _surfaces.has(old_key):
		_surfaces[key] = _surfaces[old_key]
		_surfaces.erase(old_key)


## Releases the key immediately. Queued callbacks retain their world until frame end.
func unload_level(key: StringName, checkpoint := true) -> void:
	var root := level(key)
	if root:
		if root.has_meta(&"cogito_net_players"):
			var players: Node = root.get_meta(&"cogito_net_players")
			if checkpoint and players.persistence:
				players.persistence.before_unload(players)
		_levels.erase(key)
		var network := _surfaces.has(key)
		var owner_node: Node = _surfaces.get(key, root.get_parent())
		_surfaces.erase(key)
		owner_node.queue_free()
		if network and root.has_meta(&"cogito_net_players"):
			# Deferred scene callbacks keep a valid tree through frame end.
			root.get_meta(&"cogito_net_players").unbind_level()


## Looks up a live root by its host key.
func level(key: StringName) -> Node:
	return _levels.get(key)


## Returns the live level roots in load order.
func levels() -> Array[Node]:
	return _levels.values()

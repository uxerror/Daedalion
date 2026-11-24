class_name CogitoLevelHost
extends Node
## Owns independently simulated levels. Offline gameplay does not create a host.

var _levels: Dictionary[StringName, Node] = {}


class LevelViewport:
	extends SubViewport

	func _enter_tree() -> void:
		CogitoLevel._hosted_worlds += 1

	func _exit_tree() -> void:
		CogitoLevel._hosted_worlds -= 1


## Loads a scene into a minimal, non-rendering viewport. Repeated keys return the live root.
func load_level(path: String, key: StringName) -> Node:
	if _levels.has(key):
		return level(key)
	if key == &"" or not ResourceLoader.exists(path, "PackedScene"):
		return null
	var scene := load(path) as PackedScene
	if not scene or not scene.can_instantiate():
		return null
	var root := scene.instantiate()
	root.add_to_group(CogitoLevel.HOSTED_ROOT)
	root.ready.connect(CogitoPersistentId.stamp_level.bind(root), CONNECT_ONE_SHOT)

	var viewport := LevelViewport.new()
	viewport.size = Vector2i(2, 2)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.audio_listener_enable_2d = false
	viewport.audio_listener_enable_3d = false
	_levels[key] = root
	viewport.add_child(root)
	add_child(viewport)
	return root


## Releases the key immediately. Queued callbacks retain their world until frame end.
func unload_level(key: StringName) -> void:
	var root := level(key)
	if root:
		_levels.erase(key)
		root.get_parent().queue_free()


## Looks up a live root by its host key.
func level(key: StringName) -> Node:
	return _levels.get(key)


## Returns the live level roots in load order.
func levels() -> Array[Node]:
	return _levels.values()

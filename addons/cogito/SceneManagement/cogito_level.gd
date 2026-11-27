class_name CogitoLevel
extends RefCounted
## Resolves game content relative to its level instance.

## Assigned to the scene root before a hosted instance enters the tree.
const HOSTED_ROOT := &"CogitoLevelRoot"

# Updated by the hosting viewport on tree entry/exit, including when its host is freed.
static var _hosted_worlds: int = 0


## Returns the containing hosted level, or the current offline level for other nodes.
## CogitoScene registers the incoming offline root before SceneTree.current_scene changes.
static func root_of(node: Node) -> Node:
	var hosted := hosted_root(node)
	if hosted:
		return hosted
	return current_root(tree_of(node))


## Scene tree for a lookup. A detached context uses the running game's tree.
static func tree_of(node: Node) -> SceneTree:
	return node.get_tree() if node.is_inside_tree() else Engine.get_main_loop() as SceneTree


## The current offline level, also used by autoloads, menus and unparented player views.
static func current_root(tree: SceneTree) -> Node:
	var registered: Node = CogitoSceneManager._current_scene_root_node
	if is_instance_valid(registered) and registered.is_inside_tree():
		if not registered.is_queued_for_deletion():
			return registered
	return tree.current_scene


## Returns the nearest root installed by a level host, including across nested viewports.
static func hosted_root(node: Node) -> Node:
	if _hosted_worlds > 0:
		while node:
			if node.is_in_group(HOSTED_ROOT):
				return node
			node = node.get_parent()
	return null


## Marks a network scene loaded into a normal window as its own level instance.
static func mark_network_root(root: Node) -> bool:
	if hosted_root(root):
		return false
	root.add_to_group(HOSTED_ROOT)
	_hosted_worlds += 1
	return true


## Releases a mark owned by the network session when either the session or level exits.
static func unmark_network_root(root: Node) -> void:
	root.remove_from_group(HOSTED_ROOT)
	_hosted_worlds -= 1


## Returns group members in scene-tree order. Offline uses the native group array directly.
static func nodes_in_group(context: Node, group: StringName) -> Array[Node]:
	var tree := context.get_tree() if context.is_inside_tree() else tree_of(context)
	if _hosted_worlds == 0:
		return tree.get_nodes_in_group(group)
	return _members_of(root_of(context), tree.get_nodes_in_group(group))


static func _members_of(root: Node, members: Array[Node]) -> Array[Node]:
	var matches: Array[Node] = []
	for member in members:
		if root_of(member) == root:
			matches.append(member)
	return matches


## Returns the first matching member in this level, or null when the group is empty.
static func first_node_in_group(context: Node, group: StringName) -> Node:
	var tree := tree_of(context)
	if _hosted_worlds == 0:
		return tree.get_first_node_in_group(group)
	var root := root_of(context)
	for member in tree.get_nodes_in_group(group):
		if root_of(member) == root:
			return member
	return null


## The registered local player when it belongs to this level. Hosted levels may be empty.
static func local_player(context: Node) -> CogitoPlayer:
	var player := CogitoSceneManager.get_player()
	if player and _hosted_worlds > 0:
		if not player.is_inside_tree() or root_of(player) != root_of(context):
			return null
	return player


## Parent for runtime spawns. Pass tree_root_offline for legacy root-window children.
static func spawn_parent(context: Node, tree_root_offline: bool = false) -> Node:
	var hosted := hosted_root(context)
	if hosted:
		return hosted
	var tree := tree_of(context)
	return tree.root if tree_root_offline else tree.current_scene


## True for a level whose delayed operations follow the authority's simulation clock.
static func uses_room_clock(node: Node) -> bool:
	var root := hosted_root(node)
	return root != null and root.has_meta(&"cogito_room_clock")


## Wait in the simulation time of a resident room. Other roles keep SceneTreeTimer timing.
static func delay(node: Node, seconds: float, always := true) -> Signal:
	if uses_room_clock(node):
		var tween := node.create_tween()
		tween.tween_interval(seconds)
		return tween.finished
	return node.get_tree().create_timer(seconds, always).timeout

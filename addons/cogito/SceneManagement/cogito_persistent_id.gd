class_name CogitoPersistentId
extends RefCounted
## Identifies nodes in save data without depending on where the level sits in the scene tree.
## Nodes placed in the level are identified by their path from the level root, which stays the same between runs.
## Persist nodes placed in the level keep the id of where they were when the level loaded ("level:<path>"), even if they move later.
## Persist nodes created during play get a generated id ("persist:<number>") that is saved with them and restored on load.

const META_KEY := &"cogito_persistent_id"


## Returns the id of the node. Gives Persist nodes their id the first time.
static func of(node: Node) -> String:
	if node.has_meta(META_KEY):
		return node.get_meta(META_KEY)
	var level_root := get_level_root(node.get_tree())
	if node.is_in_group("Persist"):
		var id := _level_id(level_root, node)
		if id.is_empty():
			id = "persist:%d" % ResourceUID.create_id()
		node.set_meta(META_KEY, id)
		return id
	if level_root and level_root.is_ancestor_of(node):
		return str(level_root.get_path_to(node))
	if level_root == node:
		return "."
	return str(node.get_path()) # Outside the level, for example an autoload.


## Returns the node with this id, or null if there is none.
static func find(tree: SceneTree, id: String) -> Node:
	if id.is_empty():
		return null
	if id.begins_with("persist:") or id.begins_with("level:"):
		for node in tree.get_nodes_in_group("Persist"):
			# Skip nodes that a load is about to replace.
			if not node.is_queued_for_deletion() and of(node) == id:
				return node
		return null
	if id.begins_with("/"):
		return tree.root.get_node_or_null(NodePath(id))
	var level_root := get_level_root(tree)
	if level_root == null:
		return null
	return level_root.get_node_or_null(NodePath(id))


## Restores a saved id on a node that was recreated from a save.
static func restore(node: Node, id: String) -> void:
	if not id.is_empty():
		node.set_meta(META_KEY, id)


## Gives every Persist node placed in the level its "level:" id. CogitoScene calls this once the level is in the tree,
## so the ids match the level as it was loaded, before anything moves.
static func stamp_level(level_root: Node) -> void:
	for node in level_root.get_tree().get_nodes_in_group("Persist"):
		if not node.has_meta(META_KEY) and level_root.is_ancestor_of(node):
			var id := _level_id(level_root, node)
			if not id.is_empty():
				node.set_meta(META_KEY, id)


## True if the node comes from the level's scene files, false if it was added during play.
## Nodes from the level (also inside sub-scenes placed in it) have an owner chain that leads to the level root.
## Nodes inside objects spawned during play stop at the spawned object, which has no owner.
static func is_from_level(level_root: Node, node: Node) -> bool:
	if level_root == null or not level_root.is_ancestor_of(node):
		return false
	var owner_node := node.owner
	while owner_node != null and owner_node != level_root:
		owner_node = owner_node.owner
	return owner_node == level_root


static func _level_id(level_root: Node, node: Node) -> String:
	if is_from_level(level_root, node):
		return "level:" + str(level_root.get_path_to(node))
	return ""


## The root node of the current level. During a scene change the new level is set up before it becomes current_scene,
## so the root that CogitoScene registers when it enters the tree comes first.
static func get_level_root(tree: SceneTree) -> Node:
	var scene_root : Node = CogitoSceneManager._current_scene_root_node
	if is_instance_valid(scene_root) and scene_root.is_inside_tree() and not scene_root.is_queued_for_deletion():
		return scene_root
	if is_instance_valid(tree.current_scene):
		return tree.current_scene
	return null

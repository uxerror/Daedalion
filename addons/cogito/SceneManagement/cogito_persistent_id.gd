class_name CogitoPersistentId
extends RefCounted
## Identifies nodes in save data without depending on where the level sits in the scene tree.
## Nodes placed in the level are identified by their path from the level root, which stays the same between runs.
## Nodes in the "Persist" group get recreated when a save is loaded, so they get a generated id instead.
## That id is written to the save with them and restored on load.

const META_KEY := &"cogito_persistent_id"


## Returns the id of the node. Gives Persist nodes a generated id the first time.
static func of(node: Node) -> String:
	if node.has_meta(META_KEY):
		return node.get_meta(META_KEY)
	if node.is_in_group("Persist"):
		var id := "persist:%d" % ResourceUID.create_id()
		node.set_meta(META_KEY, id)
		return id
	var level_root := get_level_root(node.get_tree())
	if level_root and level_root.is_ancestor_of(node):
		return str(level_root.get_path_to(node))
	if level_root == node:
		return "."
	return str(node.get_path()) # Outside the level, for example an autoload.


## Returns the node with this id, or null if there is none.
static func find(tree: SceneTree, id: String) -> Node:
	if id.is_empty():
		return null
	if id.begins_with("persist:"):
		for node in tree.get_nodes_in_group("Persist"):
			# Skip nodes that a load is about to replace.
			if not node.is_queued_for_deletion() and node.get_meta(META_KEY, "") == id:
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


## The root node of the current level. During a scene change the new level is set up before it becomes current_scene,
## so the root that CogitoScene registers when it enters the tree comes first.
static func get_level_root(tree: SceneTree) -> Node:
	var scene_root : Node = CogitoSceneManager._current_scene_root_node
	if is_instance_valid(scene_root) and scene_root.is_inside_tree() and not scene_root.is_queued_for_deletion():
		return scene_root
	if is_instance_valid(tree.current_scene):
		return tree.current_scene
	return null

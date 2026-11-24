class_name CogitoPersistentId
extends RefCounted
## Identifies nodes in save data without depending on where the level sits in the scene tree.
## Nodes placed in the level are identified by their path from the level root, which stays the same between runs.
## Persist nodes placed in the level keep the id of where they were when the level loaded ("level:<path>"), even if they move later.
## Persist nodes created during play get a generated id ("persist:<number>") that is saved with them and restored on load.

const LEVEL_IDS_META := &"cogito_authored_persist_ids"
const META_KEY := &"cogito_persistent_id"


## Returns the id of the node. Gives Persist nodes their id the first time.
static func of(node: Node) -> String:
	if node.has_meta(META_KEY):
		return node.get_meta(META_KEY)
	var level_root := CogitoLevel.root_of(node)
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


## A child disappears with its queued ancestor, even during a same-frame save.
static func is_disappearing(node: Node) -> bool:
	while node:
		if node.is_queued_for_deletion():
			return true
		node = node.get_parent()
	return false


## Compatibility lookup in the current offline level. Game code should pass its context.
static func find(tree: SceneTree, id: String) -> Node:
	return find_in_level(tree.root, id)


## Resolves a persistent ID in the level containing context.
static func find_in_level(context: Node, id: String) -> Node:
	if id.is_empty():
		return null
	if id.begins_with("persist:") or id.begins_with("level:"):
		for node in CogitoLevel.nodes_in_group(context, &"Persist"):
			# Skip nodes that a load is about to replace.
			if not node.is_queued_for_deletion() and of(node) == id:
				return node
		return null
	var root := CogitoLevel.root_of(context)
	return resolve_path(context, NodePath(id), root)


## Resolves legacy paths within a level, including offline /root/<level>/... in a host.
## Relative paths start at relative_to. Absolute paths into other instances are rejected.
static func resolve_path(context: Node, path: NodePath, relative_to: Node) -> Node:
	var root := CogitoLevel.root_of(context)
	if path.is_absolute() and root and root.is_in_group(CogitoLevel.HOSTED_ROOT):
		# Old snapshots could put a runtime object's parent directly under the window.
		if path == ^"/root":
			return root
		if path.get_name_count() >= 2 and path.get_name(0) == &"root":
			if path.get_name(1) == root.name:
				relative_to = root
				path = path.slice(2) if path.get_name_count() > 2 else ^"."
	var tree := CogitoLevel.tree_of(context)
	if path.is_absolute():
		relative_to = tree.root
	var node := relative_to.get_node_or_null(path) if relative_to else null
	if node and tree.has_group(CogitoLevel.HOSTED_ROOT):
		if CogitoLevel.root_of(node) != root:
			return null
	return node


## Restores a saved id on a node that was recreated from a save.
static func restore(node: Node, id: String) -> void:
	if not id.is_empty():
		node.set_meta(META_KEY, id)


## Gives every Persist node placed in the level its "level:" id. CogitoScene calls this once the level is in the tree,
## so the ids match the level as it was loaded, before anything moves.
static func stamp_level(level_root: Node) -> void:
	if level_root.has_meta(LEVEL_IDS_META):
		return
	var known_ids := {}
	for node in CogitoLevel.nodes_in_group(level_root, &"Persist"):
		if not is_from_level(level_root, node):
			continue
		if not node.has_meta(META_KEY):
			node.set_meta(META_KEY, _level_id(level_root, node))
		if node.has_method("save"):
			known_ids[of(node)] = true
	level_root.set_meta(LEVEL_IDS_META, known_ids)


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
	return CogitoLevel.current_root(tree)

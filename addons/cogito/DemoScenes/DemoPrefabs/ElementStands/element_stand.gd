extends Node3D
## Shared script of the element demo stands. Connect buttons of the stand to its methods:
## reset_stand() puts the reset_nodes back the way they are in the stand scene (burned grass, charred crates,
## hurt dummies, dropped balls), release() lets go of frozen rigid bodies, cure_all() cures poison.

signal net_changed(event: StringName)

## Nodes restored by reset_stand(). They are taken from a fresh instance of this stand's scene,
## so they come back with the settings they have in the scene file.
@export var reset_nodes : Array[NodePath] = []
## Rigid bodies held in place (freeze = true) that release() lets fall.
@export var release_bodies : Array[NodePath] = []
## Objects with CogitoProperties that cure_all() cures of poison.
@export var cure_targets : Array[NodePath] = []


var _generation := 0


## The generation orders RESET against burnouts on the world lifecycle channel.
func net_state() -> Dictionary:
	return {"generation": _generation}


## A fresh level already has the authored objects. Live resets also replace missing ones.
func apply_net_state(fields: Dictionary, silent: bool) -> void:
	if not silent and int(fields.generation) != _generation:
		_replace_nodes()
	_generation = fields.generation


## Restores reset_nodes from the stand's scene file. Destroyed nodes are created again.
func reset_stand() -> void:
	if CogitoProperties.is_client_copy(self):
		return
	_replace_nodes()
	if has_meta(&"cogito_net_world"):
		_generation += 1
		net_changed.emit(&"")


func _replace_nodes() -> void:
	if scene_file_path.is_empty():
		push_warning(name + ": reset_stand() only works on an instanced stand scene.")
		return
	var fresh : Node = load(scene_file_path).instantiate()
	for path in reset_nodes:
		var fresh_node := fresh.get_node_or_null(path)
		if !fresh_node:
			continue
		var parent_path := NodePath(String(path).get_base_dir()) if String(path).contains("/") else NodePath(".")
		var parent := get_node_or_null(parent_path)
		if !parent:
			continue
		var index := -1
		var old := get_node_or_null(path)
		if old:
			if old.has_meta(&"net_carrier"):
				get_meta(&"cogito_net_world").get_parent().carry.release(old.get_meta(&"net_carrier"))
			index = old.get_index()
			old.name = String(old.name) + "_old" # Frees the name for the new node.
			parent.remove_child(old)
			old.queue_free()
		var owners := {}
		for node: Node in [fresh_node] + fresh_node.find_children("*", "", true, false):
			if node.owner and node.owner.is_ancestor_of(fresh_node):
				owners[node] = get_node(fresh.get_path_to(node.owner))
				node.owner = null
		fresh_node.get_parent().remove_child(fresh_node)
		parent.add_child(fresh_node)
		for node: Node in owners:
			node.owner = owners[node]
		if has_meta(&"cogito_net_world"):
			get_meta(&"cogito_net_world").restore_element_object(fresh_node)
		if index >= 0:
			parent.move_child(fresh_node, mini(index, parent.get_child_count() - 1))
	fresh.free()


## Releases the release_bodies (RigidBody3D freeze = false).
func release() -> void:
	if CogitoProperties.is_client_copy(self):
		return
	for path in release_bodies:
		var body := get_node_or_null(path) as RigidBody3D
		if body:
			body.freeze = false
			body.sleeping = false


## Cures poison on all cure_targets.
func cure_all() -> void:
	for path in cure_targets:
		var props := CogitoProperties.get_properties_of(get_node_or_null(path))
		if props:
			props.cure_poison()

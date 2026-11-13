extends Node3D
## Generic mesh look effect (used by the frozen and charred looks). Spawned by CogitoProperties as a child of the object:
## while in the tree it puts overlay_material on the object's meshes, and restores their previous overlays when it leaves.

## Material put into material_overlay of every MeshInstance3D of the parent.
@export var overlay_material : Material

var _previous_overlays : Dictionary = {} # MeshInstance3D -> Material


func _enter_tree() -> void:
	var parent := get_parent()
	if parent and overlay_material:
		_apply_overlay(parent)


func _exit_tree() -> void:
	for mesh in _previous_overlays:
		if is_instance_valid(mesh) and mesh.material_overlay == overlay_material:
			mesh.material_overlay = _previous_overlays[mesh]
	_previous_overlays.clear()


func _apply_overlay(node: Node) -> void:
	for child in node.get_children():
		if child == self:
			continue # Skip this effect's own nodes.
		if child is MeshInstance3D and !_previous_overlays.has(child):
			_previous_overlays[child] = child.material_overlay
			child.material_overlay = overlay_material
		_apply_overlay(child)

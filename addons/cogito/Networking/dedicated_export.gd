@tool
extends EditorExportPlugin
## Specialize PackedScenes before packing them. Godot's dedicated resource mode also
## replaces visual resources with placeholders. Collision and animation stay in the pack.

const Level := preload("../SceneManagement/cogito_scene.gd")
const Wieldable := preload("../Scripts/cogito_wieldable.gd")
const WieldProfile := preload("net_wield_profile.gd")


func _get_name() -> String:
	return "CogitoDedicatedScenes"


func _begin_customize_scenes(_platform: EditorExportPlatform, _features: PackedStringArray) -> bool:
	return get_export_preset().is_dedicated_server()


func _get_customization_configuration_hash() -> int:
	var profile_script: Script = WieldProfile
	return hash([get_script().source_code, profile_script.source_code])


func _customize_scene(scene: Node, path: String) -> Node:
	var authored: Script = scene.get_script()
	var changed := false
	var hud := scene.get_node_or_null("GUI/Panel/AspectRatioContainer/Player_HUD")
	if hud and scene.has_node("Body/Neck/Head/Eyes/Camera"):
		var bar := hud.get_node("InventoryInterface/QuickSlots")
		scene.set_meta(&"quickslot_count", bar.quickslot_containers.size())
		scene.set_meta(&"multiple_quickslot_binds", bar.allow_multiple_quickslot_binds)
		_discard(scene.get_node("GUI"))
		scene.set("player_hud", null)
		var view := scene.get_node("Body/Neck/Head/Eyes/Camera") as Camera3D
		if view:
			var aim := Node3D.new()
			aim.transform = view.transform
			view.replace_by(aim)
			aim.name = "Camera"
			aim.owner = scene
			view.queue_free()
		changed = true
	elif WieldProfile.derives_from(authored, Wieldable):
		var profile := WieldProfile.new()
		profile.read_authored(scene)
		var fields := {}
		for prop: Dictionary in profile.get_property_list():
			if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				fields[prop.name] = profile.get(prop.name)
		scene.set_meta(WieldProfile.EXPORT_META, fields)
		changed = true
	elif path.ends_with("/LightMeterAttribute.tscn"):
		_discard(scene.get_node("SubViewport"))
		changed = true
	elif WieldProfile.derives_from(authored, Level):
		var solo := scene.get_node_or_null("Player") as Node3D
		if solo:
			var marker := Marker3D.new()
			marker.transform = solo.transform
			_discard(solo)
			marker.name = "Player"
			scene.add_child(marker)
			marker.owner = scene
			changed = true
	if _bake_csg_collision(scene):
		changed = true
	for kind in ["Camera3D", "AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D"]:
		for child in scene.find_children("*", kind, true, false):
			if child.owner == scene:
				_discard(child)
				changed = true
	if changed:
		_clear_detached_references(scene, scene)
	return scene if changed else null


# Visual stripping turns a CSGMesh3D's mesh into a PlaceholderMesh, so the server would
# build no collision for it and players walk through ramps. Bake every colliding CSG
# root into a StaticBody3D with the same name and layers while the real mesh is loaded.
func _bake_csg_collision(scene: Node) -> bool:
	var roots: Array[CSGShape3D] = []
	for node in scene.find_children("*", "CSGShape3D", true, false):
		var csg := node as CSGShape3D
		if csg.owner == scene and csg.use_collision and not csg.get_parent() is CSGShape3D:
			roots.append(csg)
	for csg in roots:
		var body := StaticBody3D.new()
		body.collision_layer = csg.collision_layer
		body.collision_mask = csg.collision_mask
		body.collision_priority = csg.collision_priority
		var shape := csg.bake_collision_shape()
		if shape and not shape.get_faces().is_empty():
			var holder := CollisionShape3D.new()
			holder.name = "BakedCollision"
			holder.shape = shape
			body.add_child(holder)
		else:
			push_warning("CSG %s has no collision geometry" % scene.get_path_to(csg))
		for child in csg.get_children():
			if child is CSGShape3D:
				_discard(child)
		var parent := csg.get_parent()
		body.transform = csg.transform
		body.visible = csg.visible
		parent.add_child(body)
		parent.move_child(body, csg.get_index())
		for child in csg.get_children():
			child.reparent(body, false)
		_discard(csg)
		body.name = csg.name
		_own(body, scene)
	return not roots.is_empty()


func _own(node: Node, scene: Node) -> void:
	if node.owner == null or node.owner == node:
		node.owner = scene
	for child in node.get_children():
		if child.owner == null:
			_own(child, scene)


func _clear_detached_references(root: Node, node: Node) -> void:
	for prop: Dictionary in node.get_property_list():
		if prop.hint == PROPERTY_HINT_NODE_TYPE:
			var target: Variant = node.get(prop.name)
			if target is Node and target != root and not root.is_ancestor_of(target):
				node.set(prop.name, null)
	for child in node.get_children():
		_clear_detached_references(root, child)


# PackedScene's packer can still inspect exported Node references on their former
# owners. Keep detached objects alive until packing has serialized those properties.
func _discard(node: Node) -> void:
	node.get_parent().remove_child(node)
	node.queue_free()

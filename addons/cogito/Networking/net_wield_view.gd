extends RefCounted
## An owner's visual-only copy of the authored viewmodel. No gameplay method tracks run.

const ANIMATION := preload("net_animation.gd")
const PROFILE := preload("net_wield_profile.gd")

var model: Node3D
var animation: AnimationPlayer
var light: SpotLight3D
var camera: Camera3D
var _normal_fov := 75.0


## Release the view and its aim override during a switch or despawn.
func clear() -> void:
	if is_instance_valid(camera):
		camera.fov = _normal_fov
	camera = null
	if is_instance_valid(model):
		model.hide()
		model.queue_free()
	model = null
	animation = null
	light = null


## Install a local viewmodel or the remote mannequin's head-mounted light.
func equip(actor: CogitoPlayerAdvanced, item: WieldableItemPD, profile: PROFILE) -> void:
	var socket := actor.player_interaction_component.wieldable_container
	if actor.is_local_presentation:
		var authored := item.wieldable_scene.instantiate() as CogitoWieldable
		var mesh := authored.wieldable_mesh
		model = authored
		_strip_scripts(model)
		var players := model.find_children("*", "AnimationPlayer", true, false)
		if not players.is_empty():
			animation = players[0]
			ANIMATION.new().bind(animation)
		socket.add_child(model)
		if mesh:
			mesh.show()
		camera = actor.camera
		if camera:
			_normal_fov = camera.fov
		play(profile.equip_clip)
		light = model.get_node_or_null("SpotLight3D")
	elif profile.kind == &"light":
		light = SpotLight3D.new()
		model = light
		actor.head.add_child(light)
	if light:
		light.visible = false


func _strip_scripts(node: Node) -> void:
	node.set_script(null)
	if node is CSGShape3D:
		node.use_collision = false
	if node is CollisionObject3D:
		node.collision_layer = 0
		node.collision_mask = 0
	for child in node.get_children():
		_strip_scripts(child)


## Play the authored clip with its gameplay and nested playback tracks removed.
func play(clip: StringName) -> void:
	if animation and clip and animation.has_animation(clip):
		animation.stop()
		animation.play(clip)


## End a rejected input animation without invoking callbacks or spending anything.
func cancel() -> void:
	if animation and animation.is_playing():
		animation.seek(0, true)
		animation.stop()


## Apply visible authoritative state without invoking a wieldable action.
func state(on: bool, aiming: bool, profile: PROFILE) -> void:
	if light:
		light.visible = on
	if camera and profile:
		camera.fov = profile.ads_fov if aiming else _normal_fov

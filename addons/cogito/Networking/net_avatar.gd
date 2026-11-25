extends RefCounted
## One incarnation of an Advanced avatar. Only replicas have a pose timeline.

const WIELD := preload("net_wield.gd")
const INPUT := preload("net_input_source.gd")
const SNAPSHOT := preload("net_snapshot.gd")
const MOVING := CogitoPlayerAdvanced.MovingState
const PREFAB := "res://addons/cogito/PackedScenes/cogito_player_advanced.tscn"

## Controller instance in this peer's level.
var actor: CogitoPlayerAdvanced
## Unique server number for this spawn.
var lifetime: int
## Stack authority or public presentation for this incarnation.
var wield := WIELD.new()
## Server-issued forced-pose revision used by both wire channels.
var revision := 0
## Snapshot history on clients, including the server's last input acknowledgement.
var timeline: SNAPSHOT
## Receive buffer on a server simulating a remote owner.
var source: INPUT


class HeadLook:
	extends SkeletonModifier3D
	var head: Node3D
	var bone: int

	func _ready() -> void:
		bone = get_skeleton().find_bone("DEF-head")

	func _process_modification_with_delta(_delta: float) -> void:
		if bone >= 0:
			var skeleton := get_skeleton()
			var pose := skeleton.get_bone_global_pose(bone)
			pose.basis = pose.basis.rotated(Vector3.LEFT, head.rotation.x)
			skeleton.set_bone_global_pose(bone, pose)


## Set the role before any camera, HUD, state chart or input handler enters the tree.
func spawn(
	prefab: PackedScene, root: Node, id: String, start: Transform3D, local: bool, server: bool
) -> void:
	actor = prefab.instantiate()
	actor.name = "Player_" + id.sha256_text()
	actor.position = start.origin
	actor.get_node("Body").rotation.y = start.basis.get_euler().y
	# The dedicated avatar loses its HUD on tree entry. Read the authored bar size first.
	var bar := actor.player_hud.get_node("InventoryInterface/QuickSlots") as CogitoQuickslots
	actor.set_meta(&"quickslot_count", bar.quickslot_containers.size())
	actor.set_meta(&"multiple_quickslot_binds", bar.allow_multiple_quickslot_binds)
	actor.is_local_presentation = local
	actor.network_movement_only = true
	if server and not local:
		source = INPUT.new()
		actor.input_source = source
	if not local:
		# The solo light meter owns another camera in a SubViewport.
		actor.get_node("LightMeterAttribute").free()
		var skeleton := actor.get_node("Rig/Skeleton3D") as Skeleton3D
		var look := HeadLook.new()
		look.head = actor.get_node("Body/Neck/Head")
		skeleton.add_child(look)
		var mesh := skeleton.get_node("Mannequin") as MeshInstance3D
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if not server:
		timeline = SNAPSHOT.new()
		actor.get_node("StateChart").process_mode = Node.PROCESS_MODE_DISABLED
		actor.collision_layer = 0
		actor.collision_mask = 0
	if not server:
		actor.get_node("AutoPickUpZone").free()
	var ray := actor.get_node("Body/Neck/Head/Eyes/Camera/InteractionRaycast") as RayCast3D
	if not local:
		ray.enabled = false
		ray.process_mode = Node.PROCESS_MODE_DISABLED
	var template := actor.inventory_data
	root.add_child(actor)
	if server and template and template != actor.inventory_data:
		# Private mutable starter resources still match the level's authored key/item definition.
		for i in template.inventory_slots.size():
			var original := template.inventory_slots[i]
			var slot := actor.inventory_data.inventory_slots[i]
			if original and slot and original.inventory_item != slot.inventory_item:
				slot.inventory_item.set_meta(&"cogito_item_definition", original.inventory_item)
	if not server and not local:
		actor.set_physics_process(false)
		actor.input_source = null


## Received on the authority-only spawn or pose endpoint.
func receive(frame: Dictionary) -> void:
	var last := timeline.latest()
	if timeline.push(frame):
		var force_look: bool = (
			last.is_empty() or revision != frame.revision or last.sitting != frame.sitting
		)
		revision = frame.revision
		apply_pose(frame, 1.0, force_look)
		actor.reset_physics_interpolation()


## Updates visible pose only. The owner keeps its event-frequency look between resets.
func present(delta: float) -> void:
	var frame := timeline.latest()
	if not actor.is_local_presentation:
		frame = timeline.presentation(Engine.physics_ticks_per_second)
	if not frame.is_empty():
		var weight := 1.0 - exp(-22.0 * delta) if actor.is_local_presentation else 1.0
		apply_pose(frame, weight, false)


## Applies the snapshot to the body, animated rig and first-person eye height.
func apply_pose(frame: Dictionary, weight: float, force_look: bool) -> void:
	var local := actor.is_local_presentation
	actor.position = actor.position.lerp(frame.position, weight)
	actor.velocity = frame.velocity
	actor.current_moving_state = frame.moving
	actor.current_body_posture_state = frame.posture
	actor.is_sitting = frame.sitting
	actor.head.position.y = frame.height
	if not local or force_look:
		actor.body.rotation.y = frame.yaw
		actor.head.rotation.x = frame.pitch
		actor.neck.rotation.y = frame.neck
	var tree := actor.get_node("PlayerAnimationTree")
	if actor.is_in_crouching_state():
		tree.crouch_down()
	elif actor.current_moving_state in [MOVING.Jumping, MOVING.FreeFall]:
		tree.go_airborne()
	else:
		tree.standing_up()


## Release locally held objects and remove the name immediately so reconnect can reuse it.
func despawn() -> void:
	if not is_instance_valid(actor):
		return
	actor.player_interaction_component.release_held_actions()
	var carried: Variant = actor.player_interaction_component.carrying.carried_object
	if is_instance_valid(carried):
		carried.leave()
	var seat := actor.current_seat
	if is_instance_valid(seat) and seat.player_node == actor:
		seat._stand_up(false)
		seat.player_node = null
		seat.occupant_id = ""
		actor.current_seat = null
	if CogitoSceneManager.get_player() == actor:
		CogitoSceneManager.register_player(null)
	actor.input_source = null
	actor.queue_free()
	if actor.get_parent():
		actor.get_parent().remove_child(actor)

extends RefCounted
## One incarnation of an Advanced avatar. Only replicas have a pose timeline.

const MovementAudio := preload("net_movement_audio.gd")
const WIELD := preload("net_wield.gd")
const INPUT := preload("net_input_source.gd")
const SNAPSHOT := preload("net_snapshot.gd")
const MOVING := CogitoPlayerAdvanced.MovingState
const PREFAB := "res://addons/cogito/PackedScenes/cogito_player_advanced.tscn"

## Controller instance in this peer's level.
var actor: CogitoPlayerAdvanced
## Unique server number for this spawn.
var lifetime: int
## Public meter for nameplates and observer UI.
var health_fraction := 0.0
var attributes := preload("net_attributes.gd").new()
## Stack authority or public presentation for this incarnation.
var wield := WIELD.new()
## Server-issued forced-pose revision used by both wire channels.
var revision := 0
## Snapshot history on clients, including the server's last input acknowledgement.
var timeline: SNAPSHOT
## Receive buffer on a server simulating a remote owner.
var source: INPUT
var movement_audio: MovementAudio
var mode_generation := 0
var checkpoint_eligible := false
var _baseline: NetOwnerState
var _seated_pose := false


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
	prefab: PackedScene,
	root: Node,
	id: String,
	start: Transform3D,
	local: bool,
	server: bool,
	dedicated := false
) -> void:
	actor = prefab.instantiate()
	actor.name = "Player_" + id.sha256_text()
	actor.position = start.origin
	actor.get_node("Body").rotation.y = start.basis.get_euler().y
	# The dedicated avatar loses its HUD on tree entry. Read the authored bar size first.
	if actor.player_hud:
		var bar := actor.player_hud.get_node("InventoryInterface/QuickSlots") as CogitoQuickslots
		actor.set_meta(&"quickslot_count", bar.quickslot_containers.size())
		actor.set_meta(&"multiple_quickslot_binds", bar.allow_multiple_quickslot_binds)
	actor.is_local_presentation = local
	actor.network_movement_only = true
	actor.set_meta(&"net_player_id", id)
	var meter := actor.get_node_or_null("LightMeterAttribute")
	if meter is CogitoLightmeter:
		# A rendering owner samples real light for its own HUD, as offline. The meter is
		# presentation only; headless peers keep the server's light-zone value.
		if local and DisplayServer.get_name() != "headless":
			meter.set_meta(&"net_local_meter", true)
		elif meter.has_node("SubViewport"):
			meter.get_node("SubViewport").free()
		if actor.find_children("*", "CogitoVisibilityAttribute", false, false).is_empty():
			var visibility := (
				preload("../Components/Attributes/VisibilityAttribute.tscn").instantiate()
				as CogitoAttribute
			)
			# Internal stand-in: the offline prefab has no visibility meter on its HUD.
			visibility.attribute_visibility = CogitoAttribute.AttributeVisibility.Hidden
			actor.add_child(visibility)
			visibility.owner = actor
			actor.set_meta(&"net_fallback_visibility", true)
	if not server:
		for attr: CogitoAttribute in actor.find_children("*", "CogitoAttribute", false, false):
			if attr.has_meta(&"net_local_meter"):
				continue
			attr.network_frozen = true
			attr.set_block_signals(true)
			attr.process_mode = Node.PROCESS_MODE_DISABLED
	if dedicated:
		for player in actor.find_children("*", "AudioStreamPlayer3D", true, false):
			player.free()
	if server and not local:
		source = INPUT.new()
		actor.input_source = source
	if not local:
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
	if not dedicated and (not server or not local):
		movement_audio = MovementAudio.new(actor)
	if server and OS.get_environment("COGITO_AUTHORITY_MOVEMENT") == "1":
		var profile := actor.authority_movement_profile()
		if profile:
			actor.authority_movement = preload("net_authority_movement.gd").new(actor, profile)
	if not server:
		for attr: CogitoAttribute in actor.player_attributes.values():
			attr.set_block_signals(false)
			if attr.has_meta(&"net_local_meter"):
				continue
			for child in attr.find_children("*", "", true, false):
				child.process_mode = Node.PROCESS_MODE_DISABLED
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
func receive(frame: Dictionary, checkpoint: NetOwnerState = null) -> bool:
	var last := timeline.latest()
	if frame.revision < revision:
		return false
	if checkpoint and _baseline and checkpoint.generation < _baseline.generation:
		return false
	var result := timeline.push(frame)
	if result == SNAPSHOT.Acceptance.REJECTED:
		return false
	if checkpoint or revision != frame.revision:
		_baseline = checkpoint
	if result == SNAPSHOT.Acceptance.RESET:
		movement_audio.reset()
		var force_look: bool = (
			last.is_empty() or last.revision != frame.revision or last.sitting != frame.sitting
		)
		revision = frame.revision
		apply_pose(frame, 1.0, force_look)
		actor.reset_physics_interpolation()
	movement_audio.observe(timeline.latest())
	return true


## Latest validated private post-state, owned by this replica. Treat as read-only.
func latest_owner_baseline() -> NetOwnerState:
	return _baseline


func clear_baseline() -> void:
	_baseline = null


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
	actor.position = (
		frame.position if weight >= 1.0 else actor.position.lerp(frame.position, weight)
	)
	actor.velocity = frame.velocity
	actor.current_moving_state = frame.moving
	actor.current_body_posture_state = frame.posture
	actor.is_sitting = frame.sitting
	present_seat(frame.sitting)
	var api := actor.player_interaction_component.network_interactions
	if api:
		actor.current_seat = api.world.entities.live_object(frame.get("seat", "")) as CogitoSittable
		actor.transform.basis = frame.get("basis", Basis.IDENTITY)
		if actor.current_seat and actor.current_seat.look_marker_node:
			actor.sittable_look_marker = actor.current_seat.look_marker_node.global_position
			actor.sittable_look_angle = actor.current_seat.horizontal_look_angle
	# The owner gets 25 Hz frames; snapping the eye height to each one made crouching
	# visibly step. Arrivals leave it to present(), which follows the latest height.
	if not local or force_look:
		actor.head.position.y = frame.height
	elif weight < 1.0:
		actor.head.position.y = lerpf(actor.head.position.y, frame.height, weight)
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


## Switch the mannequin to the authored sitting clip while attached to a seat.
func present_seat(seated: bool) -> void:
	if _seated_pose == seated:
		return
	_seated_pose = seated
	var tree := actor.get_node("PlayerAnimationTree") as AnimationTree
	var animator := actor.get_node("AnimationPlayer") as AnimationPlayer
	tree.active = not seated
	if seated:
		animator.play(&"Sitting_Idle")
	else:
		animator.stop()


## Release locally held objects and remove the name immediately so reconnect can reuse it.
func despawn() -> void:
	clear_baseline()
	if not is_instance_valid(actor):
		return
	actor.player_interaction_component.release_held_actions()
	var carried: Variant = actor.player_interaction_component.carrying.carried_object
	if is_instance_valid(carried):
		if timeline:
			actor.player_interaction_component.network_interactions.get_parent().carry.clear_owner(
				actor.player_interaction_component
			)
		else:
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

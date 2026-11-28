extends RefCounted
## A door's authoritative destination and its interruptible presentation tween.

var _target: Vector3
var _has_target := false
var _clip: StringName
var _backwards := false
var _tween: Tween


## The initial translation/rotation comes from the authored or restored collision body.
func state(door: CogitoDoor) -> Dictionary:
	var target := _target
	if not _has_target:
		target = door.rotation_degrees
		if door.door_type == CogitoDoor.DoorType.SLIDING:
			target = door.position
	var data := {"open": door.is_open, "locked": door.is_locked, "target": target}
	if door.net_support:
		data.segment = door.net_support.latest()
	if door.door_type == CogitoDoor.DoorType.ANIMATED:
		var reverse := not door.is_open and door.reverse_opening_anim_for_close
		data.clip = _clip if _has_target else _clip_for(door, door.is_open)
		data.backwards = _backwards if _has_target else reverse
	return data


func _clip_for(door: CogitoDoor, opening: bool) -> StringName:
	if opening or door.reverse_opening_anim_for_close:
		return door.opening_animation
	return door.closing_animation


## Derive a destination from level-authored parameters and the server's instigator.
func start(door: CogitoDoor, opening: bool, actor: Node3D = null) -> void:
	var target := door.open_rotation if opening else door.closed_rotation
	if opening and door.bidirectional_swing and actor:
		if (actor.global_position - door.global_position).dot(door.global_basis.x) < 0:
			target = -target
	if door.door_type == CogitoDoor.DoorType.SLIDING:
		target = door.open_position if opening else door.closed_position
	elif door.forced_rotation_axis != CogitoDoor.ForcedRotationAxis.None:
		var axis := int(door.forced_rotation_axis) - 1
		var fixed := door.rotation_degrees
		fixed[axis] = target[axis]
		target = fixed
	var data := {
		"target": target,
		"clip": _clip_for(door, opening),
		"backwards": not opening and door.reverse_opening_anim_for_close,
	}
	apply(door, data, false)


## Both roles use the same motion. Baselines install the terminal collision transform immediately.
func apply(door: CogitoDoor, data: Dictionary, snap: bool) -> void:
	stop()
	_has_target = true
	_target = data.target
	door.is_moving = false
	if door.door_type == CogitoDoor.DoorType.ANIMATED:
		_clip = data.clip
		_backwards = data.backwards
		door.anim_player.play(_clip, -1, -1.0 if _backwards else 1.0, _backwards)
		if snap:
			var end := 0.0 if _backwards else door.anim_player.current_animation_length
			door.anim_player.seek(end, true, true)
			door.anim_player.pause()
		return
	var property := ^"rotation_degrees"
	var duration := door.rotation.distance_to(_target * (PI / 180.0)) / maxf(door.door_speed, 0.001)
	if door.door_type == CogitoDoor.DoorType.SLIDING:
		property = ^"position"
		duration = door.door_speed
	if door.net_support and data.has("segment"):
		var world: Node = door.get_meta(&"cogito_net_world")
		var owner: CogitoPlayerAdvanced = world.get_parent().local_actor
		if owner and owner.owner_prediction and door.net_support.latest() != data.segment:
			owner.owner_prediction.support_changed = true
		door.net_support.install(data.segment)
		door.net_support.drive(data.get("sample_tick", world.support_tick))
	elif door.net_support and not snap:
		var world: Node = door.get_meta(&"cogito_net_world")
		door.net_support.start(world.support_tick, _target, duration)
	elif snap:
		var body := (door as Node3D) as AnimatableBody3D
		var sync := body != null and body.sync_to_physics
		if sync:
			body.sync_to_physics = false
		door.set_indexed(property, _target)
		door.force_update_transform()
		door.reset_physics_interpolation()
		if sync:
			body.sync_to_physics = true
		if door.net_support:
			door.net_support.hold()
	else:
		_tween = door.create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		_tween.tween_property(door, property, _target, duration)


## Release motion owned by a previous destination.
func stop() -> void:
	if _tween:
		_tween.kill()
		_tween = null

extends Node
## Exclusive server carry grants. Private input refers to a grant, never a supplied body or impulse.

const MAX_ROTATION_INPUT := 48.0

var _serial := 0
var _grants := {}
var _local_token := 0
var _motion := Vector2.ZERO
var _throw_sequence := -1
var _throw_held := false


## Commit an already validated MP2 grab, including the authored pickup signal.
func grab(component: CogitoCarryableComponent, pic: PlayerInteractionComponent) -> Dictionary:
	var players := get_parent()
	var peer: int = players.peer_for_actor(pic.player)
	if pic.player.is_dead:
		return {"ok": false, "reason": "Player is dead"}
	if not multiplayer.is_server() or not peer or pic.player.is_sitting or pic.carrying.is_carrying:
		return {"ok": false, "reason": "Actor busy"}
	var body := component.get_parent()
	if body.has_meta(&"net_carrier") or component.is_being_carried or _grants.has(peer):
		return {"ok": false, "reason": "In use"}
	var wield: Variant = pic.player.get_meta(&"net_wield")
	var previous: InventorySlotPD
	if wield.stack and not component.is_carryable_while_wielding:
		previous = wield.stack
		wield.equip(previous)
	_serial += 1
	_grants[peer] = {"component": component, "token": _serial, "tick": -1, "stack": previous}
	component.player_interaction_component = pic
	body.set_meta(&"net_carrier", peer)
	body.set_meta(&"net_damage_owner", wield.player_id)
	if body.has_meta(&"net_snap_slot"):
		body.get_meta(&"net_snap_slot").release_body(body)
	var token := _serial
	component.carry_state_changed.connect(_changed.bind(peer))
	players.world.publish_holder(players.world.entities.id_for(body), wield.player_id)
	component.hold()
	component.was_interacted_with.emit(component.interaction_text, component.input_map_action)
	var address: Dictionary = players.world.entities.address(component)
	if _grants.get(peer, {}).get("token") == token:
		_notify(peer, token, address)
	return {"ok": true}


func _notify(peer: int, token: int, address: Dictionary) -> void:
	var entities: Variant = get_parent().world.entities
	if peer == 1:
		_local_token = token
		_motion = Vector2.ZERO
	elif get_parent().peer_in_level(peer):
		_owner.rpc_id(peer, entities.level_key, entities.epoch, token, address)


@rpc("authority", "call_remote", "reliable", 2)
func _owner(key: String, epoch: int, token: int, address: Dictionary) -> void:
	var players := get_parent()
	if not players.world.entities.matches(key, epoch) or not players.local_actor:
		return
	var pic: PlayerInteractionComponent = players.local_actor.player_interaction_component
	clear_owner(pic)
	if token > 0 and not pic.player.is_dead:
		var component: InteractionComponent = players.world.entities.resolve(
			address.entity_id, address.component_key
		)
		if component:
			_local_token = token
			pic.targeting.add_exception(component.get_parent())
			pic.carrying.start_carrying(component)


## Stack to resume when a saved carry grant expires on restart.
func holstered_stack(peer: int) -> InventorySlotPD:
	return _grants.get(peer, {}).get("stack")


## Remove local presentation without running the replica's physical leave/throw hooks.
func clear_owner(pic: PlayerInteractionComponent) -> void:
	_local_token = 0
	_motion = Vector2.ZERO
	var component: Variant = pic.carrying.carried_object
	if is_instance_valid(component):
		pic.targeting.remove_exception(component.get_parent())
		pic.carrying.stop_carrying()


func _changed(held: bool, peer: int) -> void:
	if held or not _grants.has(peer):
		return
	var grant: Dictionary = _grants[peer]
	_grants.erase(peer)
	var component: CogitoCarryableComponent = grant.component
	component.get_parent().remove_meta(&"net_carrier")
	component.carry_state_changed.disconnect(_changed.bind(peer))
	var world: Node = get_parent().world
	world.publish_holder(world.entities.id_for(component.get_parent()), "")
	var actor := component.player_interaction_component.player
	if grant.stack and grant.stack in actor.inventory_data.inventory_slots:
		var wield: Variant = actor.get_meta(&"net_wield")
		if actor.is_dead:
			# Keep the selection that was holstered for this grant until respawn.
			wield.stack = grant.stack
		else:
			wield.equip(grant.stack)
	_notify(peer, 0, {})


## Release once on avatar removal, level exit, seat entry or death.
func release(peer: int, restore_wield := true) -> void:
	if _grants.has(peer):
		if not restore_wield:
			_grants[peer].stack = null
		_grants[peer].component.leave()


## Collect local mouse or stick movement until the next physics input sample.
func rotate_input(motion: Vector2) -> void:
	_motion = (_motion + motion).limit_length(MAX_ROTATION_INPUT)


## Flush one bounded input sample from the owner.
func flush_rotation() -> void:
	if not _motion.is_zero_approx():
		input(&"rotate", _motion)
		_motion = Vector2.ZERO


## Consume the primary press as a throw, including the held frames of an automatic weapon.
func primary_pressed(sequence: int) -> void:
	_throw_sequence = sequence
	_throw_held = true
	input(&"throw")


## Remove the consumed trigger before owner prediction, weapon simulation or command encoding.
func filter_trigger(command: CogitoPlayerCommand) -> void:
	if not _throw_held and command.sequence != _throw_sequence:
		return
	var primary := CogitoPlayerCommand.Action.PRIMARY
	_throw_held = command.is_held(primary)
	command.held &= ~(1 << primary)
	var filtered := PackedByteArray()
	for edge in command.edges:
		if (edge & ~CogitoPlayerCommand.RELEASE) != primary:
			filtered.append(edge)
	command.edges = filtered


## Submit a discrete throw/drop, or bounded rotation for the active local grant.
func input(op: StringName, motion := Vector2.ZERO) -> void:
	if not _local_token:
		return
	if multiplayer.is_server():
		apply_input(1, _local_token, op, motion)
	else:
		_request.rpc_id(1, _local_token, op, motion)


@rpc("any_peer", "call_remote", "reliable", 2)
func _request(token: int, op: StringName, motion: Vector2) -> void:
	if multiplayer.is_server():
		apply_input(multiplayer.get_remote_sender_id(), token, op, motion)


## Validate ownership and input again at consumption. A consumed grant cannot throw twice.
func apply_input(peer: int, token: int, op: StringName, motion: Vector2) -> void:
	if not multiplayer.is_server() or get_parent().death.reject_dead_input(peer):
		return
	var grant: Dictionary = _grants.get(peer, {})
	if grant.get("token") != token:
		return
	var component: CogitoCarryableComponent = grant.component
	var pic := component.player_interaction_component
	if pic.player.is_dead or not pic.player.can_act() or pic.player.network_input_blocked:
		return
	if op == &"rotate" and component.enable_manual_rotating:
		if not motion.is_finite() or motion.length() > MAX_ROTATION_INPUT + 0.00001:
			return
		var tick := Engine.get_physics_frames()
		if grant.tick != tick and not motion.is_zero_approx():
			grant.tick = tick
			var aim := pic.player.get_aim_transform().basis
			var axis := (aim * Vector3(motion.y, motion.x, 0)).normalized()
			var angle := deg_to_rad(component.rotation_speed * motion.length())
			component.parent_object.global_rotate(axis, angle / Engine.physics_ticks_per_second)
	elif motion == Vector2.ZERO and op in [&"throw", &"drop"]:
		if op == &"throw":
			pic.carrying.attempt_throw()
		else:
			pic.carrying.drop_carried_object()
		get_parent().inventory.flush_actor(pic.player)


## Server collision query also works for headless avatars with a disabled targeting ray.
func clamp_anchor(pic: PlayerInteractionComponent, body: RigidBody3D, end: Vector3) -> Vector3:
	var eye := pic.player.get_aim_transform().origin
	var query := PhysicsRayQueryParameters3D.create(eye, end)
	query.exclude = [pic.player.get_rid(), body.get_rid()]
	query.collision_mask = pic.interaction_raycast.collision_mask | pic.player.collision_mask
	var hit := pic.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.get("position", end)

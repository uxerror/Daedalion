extends Node
## Exclusive, epoch-scoped input sessions. Only the admitted transport sender can drive its device.

const LOCK := preload("net_lockpick.gd")
const ACTIONS := preload("net_actions.gd")
const SPIN_BUDGET := 4
const POSE_INTERVAL := 3

var _sessions := {}
var _owners := {}
var _serial := 0
var _pending_cuts := {}
var _local_target: Node
var _local_token := 0
var _pending_steps := 0

@onready var _api: Node = get_parent()
@onready var _players: Node = _api.get_parent()


## Guard before attribute spending or replacing another actor's session.
func unavailable(peer: int, component: InteractionComponent) -> String:
	if _sessions.has(peer):
		return "Already active" if _sessions[peer].target == component else "Actor busy"
	if component is LockpickInteraction:
		for door in component.doors_to_unlock:
			if _owners.has(door):
				return "In use"
	if _owners.has(component) or _owners.has(component.get_parent()):
		return "In use"
	return ""


func _acquire(peer: int, target: Node, pic: PlayerInteractionComponent) -> Dictionary:
	_serial += 1
	var session := {"target": target, "pic": pic, "token": _serial, "peer": peer}
	_sessions[peer] = session
	if not target is CogitoCutsceneTrigger:
		_owners[target] = peer
	target.tree_exiting.connect(_target_exiting.bind(peer, _serial))
	return session


## Begin a validated spinner or lockpick. Lock state never enters a reply or baseline.
func open_device(component: InteractionComponent, pic: PlayerInteractionComponent) -> Dictionary:
	var peer: int = _players.peer_for_actor(pic.player)
	var session := _acquire(peer, component, pic)
	var address: Dictionary = _api.world.entities.address(component)
	if component is LockpickInteraction:
		for door in component.doors_to_unlock:
			_owners[door] = peer
		session.lock = LOCK.new()
		session.lock.begin(component, pic)
		address.count = _pick_count(pic, component)
	# This also prevents forged movement while a remote private view owns input.
	pic.player.network_input_blocked = true
	_send(peer, session.token, &"open", address)
	return {"ok": true}


## Begin an MP2a hold. Sample the absolute rotation from the pose at start.
func start_wheel(peer: int, component: HoldInteraction, pic: PlayerInteractionComponent) -> void:
	var wheel := component.get_parent() as CogitoTurnwheel
	var session := _acquire(peer, wheel, pic)
	session.hold = component
	session.initial = wheel.net_state().rotation
	session.direction = -1 if wheel.has_been_turned else 1
	session.elapsed = 0.0
	wheel.net_publish(&"start")


## Only a matched wheel hold can consume its own intermediate pose revisions.
func is_wheel(peer: int, component: InteractionComponent) -> bool:
	return _sessions.get(peer, {}).get("hold") == component


func _wheel_pose(session: Dictionary, elapsed: float) -> void:
	var wheel: CogitoTurnwheel = session.target
	var angle: float = session.direction * wheel.rotation_speed * elapsed
	wheel.net_rotate(session.initial * Quaternion(wheel.rotation_axis.normalized(), angle))


## Roll a cancelled hold back to its original pose, or install the completed rotation.
func finish_wheel(peer: int, complete: bool) -> void:
	var session: Dictionary = _sessions[peer]
	_wheel_pose(session, session.hold.hold_time if complete else 0.0)
	session.target.net_publish(&"stop")
	_erase(session)


## Server area callback. Delay owner presentation across the level-ready handshake.
func enter_cutscene(trigger: CogitoCutsceneTrigger, actor: CogitoPlayer) -> void:
	var peer: int = _players.peer_for_actor(actor)
	if not peer or not trigger.net_available():
		return
	if not _api.world.ready_for_events(peer):
		_pending_cuts[peer] = trigger
	else:
		if _sessions.has(peer):
			if _sessions[peer].target is CogitoCutsceneTrigger:
				return
			_release(peer)
		_api.interrupt_actor(peer)
		var session := _acquire(peer, trigger, actor.player_interaction_component)
		session.remaining = trigger.net_consume()
		actor.network_input_blocked = true
		_send(peer, session.token, &"cutscene", {"id": _api.world.entities.id_for(trigger)})


## Submit bounded device motion from the local indicator once per physics frame.
func spin(steps: int) -> void:
	_pending_steps = clampi(_pending_steps + steps, -SPIN_BUDGET, SPIN_BUDGET)


## The private minigame submits only the pressed pick angle or a release edge.
func tension(pressed: bool, angle: int) -> void:
	_input_for_owner(&"press" if pressed else &"relax", angle if pressed else 0)


## Close an owner interface, or ask to cancel a cancellable cutscene.
func dismiss() -> void:
	if _local_token:
		_input_for_owner(&"cancel", 0)


func _input_for_owner(action: StringName, value: int) -> void:
	if not _local_token:
		return
	var key: String = _api.world.entities.level_key
	var epoch: int = _api.world.entities.epoch
	if multiplayer.is_server():
		_accept(1, _local_token, action, value)
	else:
		_input_device.rpc_id(1, key, epoch, _local_token, action, value)


@rpc("any_peer", "call_remote", "reliable", 2)
func _input_device(key: String, epoch: int, token: int, action: StringName, value: Variant) -> void:
	if multiplayer.is_server() and _api.world.entities.matches(key, epoch):
		_accept(multiplayer.get_remote_sender_id(), token, action, value)


func _accept(peer: int, token: int, action: StringName, value: Variant) -> void:
	var session: Dictionary = _sessions.get(peer, {})
	if session.get("token") != token or not value is int:
		return
	var target: Node = session.target
	if not is_instance_valid(target) or not _live(session):
		_release(peer)
		return
	if action == &"cancel" and value == 0:
		if not target is CogitoCutsceneTrigger or target.allow_cancel:
			_release(peer)
	elif (
		target is SpinnerInteraction
		and target.rotation_speed > 0.0
		and action == &"spin"
		and value != 0
		and value >= -SPIN_BUDGET
		and value <= SPIN_BUDGET
	):
		var tick := Engine.get_physics_frames()
		if session.get("spin_tick") != tick:
			session.spin_tick = tick
			for step in absi(value):
				target.spin_step(signi(value))
				if target.get_parent().is_queued_for_deletion():
					break
			if not target.get_parent().is_queued_for_deletion():
				target.net_changed.emit(&"")
	elif target is LockpickInteraction:
		if action == &"press" and value >= -900 and value <= 900:
			session.lock.press(value)
		elif action == &"relax" and value == 0:
			session.lock.tension = false


func _live(session: Dictionary) -> bool:
	var target: Node3D = session.target
	var pic: PlayerInteractionComponent = session.pic
	if not is_instance_valid(target) or not is_instance_valid(pic) or pic.player.is_dead:
		return false
	if CogitoPersistentId.is_disappearing(target) or not _players.peer_in_level(session.peer):
		return false
	if target is CogitoCutsceneTrigger:
		return true
	if target is LockpickInteraction and (target.is_disabled or not target.net_has_locked_target()):
		return false
	var component: InteractionComponent = session.get("hold", target)
	return ACTIONS.geometry(pic.player, component.get_parent(), component).is_empty()


func _physics_process(delta: float) -> void:
	if _pending_steps:
		_input_for_owner(&"spin", _pending_steps)
		_pending_steps = 0
	if not multiplayer.is_server():
		return
	for peer: int in _pending_cuts.keys():
		if _api.world.ready_for_events(peer):
			var trigger: Variant = _pending_cuts[peer]
			_pending_cuts.erase(peer)
			if is_instance_valid(trigger):
				for body in trigger.get_overlapping_bodies():
					if body is CogitoPlayer and _players.peer_for_actor(body) == peer:
						enter_cutscene(trigger, body)
	for peer: int in _sessions.keys():
		var session: Dictionary = _sessions[peer]
		if not _live(session):
			_release(peer)
		elif session.has("remaining"):
			session.remaining -= delta
			if session.remaining <= 0:
				_release(peer)
		elif session.has("hold"):
			var elapsed := minf(session.elapsed + delta, session.hold.hold_time)
			if elapsed != session.elapsed:
				session.elapsed = elapsed
				_wheel_pose(session, elapsed)
				if Engine.get_physics_frames() % POSE_INTERVAL == 0:
					session.target.net_publish(&"")
		elif session.has("lock"):
			_pick_tick(session, delta)


func _pick_count(pic: PlayerInteractionComponent, pick: LockpickInteraction) -> int:
	var total := 0
	var seen := {}
	for slot in pic.get_inventory().inventory_slots:
		if (
			slot
			and not seen.has(slot)
			and pic.matches_item(slot.inventory_item, pick.required_lockpick_item)
		):
			seen[slot] = true
			total += slot.quantity
	return total


func _pick_tick(session: Dictionary, delta: float) -> void:
	var pick: LockpickInteraction = session.target
	var pic: PlayerInteractionComponent = session.pic
	var stack := LOCK.stack(pic, pick.required_lockpick_item)
	if not stack:
		_release(session.peer)
		return
	var lock: LOCK = session.lock
	var previous := lock.rotation
	var cue := lock.advance(delta)
	if cue == &"success":
		for door in pick.doors_to_unlock:
			if is_instance_valid(door) and not _api.world.entities.id_for(door).is_empty():
				door.unlock_door()
		pick.lockpick_success.emit()
		if pick.lockpick_success_hint:
			pic.send_hint(null, pick.lockpick_success_hint)
		_release(session.peer, &"success")
	elif cue == &"break":
		pic.get_inventory().remove_item_from_stack(stack)
		if pick.lockpick_item_breaks_hint:
			pic.send_hint(null, pick.lockpick_item_breaks_hint)
		if LOCK.stack(pic, pick.required_lockpick_item):
			_send(session.peer, session.token, cue, {"count": _pick_count(pic, pick)})
		else:
			_release(session.peer, &"broken")
	elif (previous != lock.rotation or cue) and Engine.get_physics_frames() % POSE_INTERVAL == 0:
		_send(session.peer, session.token, &"progress", {"turn": lock.rotation, "jam": cue != &""})


func _target_exiting(peer: int, token: int) -> void:
	if _sessions.get(peer, {}).get("token") == token:
		_release(peer)


func _erase(session: Dictionary) -> void:
	if is_instance_valid(session.target):
		session.target.tree_exiting.disconnect(_target_exiting.bind(session.peer, session.token))
	if session.target is LockpickInteraction:
		for door in session.target.doors_to_unlock:
			_owners.erase(door)
	_owners.erase(session.target)
	_sessions.erase(session.peer)
	if is_instance_valid(session.pic):
		session.pic.player.network_input_blocked = false


func _release(peer: int, event := &"close", notify := true) -> void:
	if not _sessions.has(peer):
		return
	var session: Dictionary = _sessions[peer]
	if session.has("hold") and is_instance_valid(session.target):
		finish_wheel(peer, false)
		return
	_erase(session)
	if notify:
		_send(peer, session.token, event, {})


## Release on despawn, disconnect or level teardown.
func forget(peer: int) -> void:
	_pending_cuts.erase(peer)
	if _sessions.has(peer):
		_release(peer, &"close", false)


func _send(peer: int, token: int, event: StringName, data: Dictionary) -> void:
	var key: String = _api.world.entities.level_key
	var epoch: int = _api.world.entities.epoch
	if peer == 1:
		_view(key, epoch, token, event, data)
	else:
		_view.rpc_id(peer, key, epoch, token, event, data)


@rpc("authority", "call_remote", "reliable", 2)
func _view(key: String, epoch: int, token: int, event: StringName, data: Dictionary) -> void:
	var actor: CogitoPlayer = _players.local_actor
	if not actor or not _api.world.entities.matches(key, epoch):
		return
	if actor.is_dead and event in [&"open", &"cutscene"]:
		return
	var pic := actor.player_interaction_component
	match event:
		&"open":
			_local_target = _api.world.entities.resolve(data.entity_id, data.component_key)
			_local_token = token
			if _local_target is SpinnerInteraction:
				_local_target.enter(pic)
			elif _local_target is LockpickInteraction:
				_local_target.open_net_interface(pic, data.count)
		&"cutscene":
			_api.close_view(pic)
			_local_target = _api.world.entities.live_object(data.id)
			_local_token = token
			if _local_target:
				_local_target.net_play(actor)
		_:
			if token != _local_token:
				return
			if event in [&"break", &"progress"] and _local_target is LockpickInteraction:
				_local_target.net_feedback(event, data)
			else:
				close_local(event)


## Restore only the local view that acquired input.
func close_local(event := &"close") -> void:
	var target := _local_target
	_local_target = null
	_local_token = 0
	_pending_steps = 0
	if is_instance_valid(target):
		if target is SpinnerInteraction:
			target.force_exit()
		elif target is LockpickInteraction:
			target.close_net_interface(event)
		elif target is CogitoCutsceneTrigger:
			target.net_stop()

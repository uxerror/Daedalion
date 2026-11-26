extends Node
## Reliable, actor-addressed interaction endpoint shared by both server topologies.

## Private response, including cached replies to explicit retries.
signal result_received(result: Dictionary)

const ACTIONS := preload("net_actions.gd")
const WORLD := preload("net_world_state.gd")
const AVATAR := preload("net_avatar.gd")
const SESSION := preload("net_session.gd")
const DEVICES := preload("net_devices.gd")
const UNSUPPORTED := ACTIONS.UNSUPPORTED
## Retries older than this many requests per peer get "Old request" instead of a cached reply.
const RESULT_CACHE := 64
const DOUBLE_PRESS_MSEC := 300

## Shared registry and authoritative revisions of this session branch.
var world: WORLD
## Actor-addressed device input and private presentation.
var devices := DEVICES.new()
var _session: SESSION
var _next_id := 0
var _results := {}
var _servicing := false
var _queued: Array[Array] = []
var _last_id := {}
var _holds := {}
var _views := {}
var _local_view: InteractionComponent
var _local_hold := {}
var _last_displayed := 0
var _captured_hints: Array
var _hint_actor: PlayerInteractionComponent
var _last_success := {}


func _ready() -> void:
	_session = get_parent().get_parent()
	devices.name = "Devices"
	add_child(devices)


## Clear per-level requests and holds when the registry is released.
func clear() -> void:
	_last_success.clear()
	_results.clear()
	_last_id.clear()
	_holds.clear()
	_views.clear()
	_local_hold.clear()


## A new connection gets its own sequence space.
func forget(peer: int) -> void:
	devices.forget(peer)
	_results.erase(peer)
	_last_id.erase(peer)
	_holds.erase(peer)
	_views.erase(peer)


## Text for a local HUD. No attribute check here can spend effects or address a player.
func prompt(pic: PlayerInteractionComponent, component: InteractionComponent) -> String:
	var address := world.entities.address(component)
	if address.is_empty() or component.is_disabled:
		return ""
	if not ACTIONS.supported(world.entities.objects[address.entity_id], component):
		return ""
	if component.attribute_check == InteractionComponent.AttributeCheck.HIDE_INTERACTION:
		if not component.attribute_passes(pic):
			return ""
	var choices := component.get_actions(pic)
	if choices.is_empty():
		return ""
	if component is DualInteraction or component is ExtendedPickupInteraction:
		return component.interaction_text
	return choices[0].text


## Select a bound component from the local ray. The authority re-queries every action.
func press(pic: PlayerInteractionComponent, input: String) -> void:
	var target: Node = pic.targeting.interactable
	var held := pic.carrying.is_carrying
	if held:
		target = pic.carrying.carried_object.get_parent()
	if not target or not pic.player.is_local_presentation or not "interaction_nodes" in target:
		return
	for component: InteractionComponent in target.interaction_nodes:
		if component.input_map_action != input or component.is_disabled:
			continue
		if (
			held
			and not (
				component is PickupComponent
				or component is ExtendedPickupInteraction
				or component is BackpackComponent
			)
		):
			continue
		if not ACTIONS.supported(target, component):
			pic.hint_prompt.emit(null, ACTIONS.hud_reason(UNSUPPORTED))
			return
		var choices := component.get_actions(pic)
		if not choices.is_empty():
			var action := choices[0]
			if component is DualInteraction or component is ExtendedPickupInteraction:
				_begin_hold(action)
			else:
				perform(action)
		return


## Context-menu entry point. Never call the client's Callable.
func perform(action: CogitoInteractionAction) -> void:
	if not action or not is_instance_valid(action.component):
		return
	if action.component is HoldInteraction and action.action_id != &"press":
		_begin_hold(action)
	else:
		submit(action.component, action.action_id)


func _begin_hold(action: CogitoInteractionAction) -> void:
	cancel_hold()
	_local_hold = make_request(action.component, action.action_id, "start")
	if not _local_hold.is_empty():
		dispatch(_local_hold)


## Finish this input's hold using the server-observed interval.
func release(input: String) -> void:
	if _local_hold.is_empty():
		return
	var component := world.entities.resolve(_local_hold.entity_id, _local_hold.component_key)
	if component and component.input_map_action == input:
		_end_hold("release")


## Cancel an outstanding hold when input ownership changes.
func cancel_hold() -> void:
	if not _local_hold.is_empty():
		_end_hold("cancel")


func _end_hold(phase: String) -> void:
	var local: CogitoPlayer = get_parent().local_actor
	if local and local.player_hud is CogitoPlayerHudManager:
		local.player_hud.hold_ui.stop_holding()
	var request := _local_hold.duplicate()
	_local_hold.clear()
	_next_id += 1
	request.request_id = _next_id
	request.phase = phase
	dispatch(request)


## Send only the code typed by the owner of a local keypad interface.
func submit_code(component: InteractionComponent, digits: String) -> void:
	submit(component, &"submit_code", digits)


## Send an immediate discrete action.
func submit(component: InteractionComponent, action: StringName, payload: Variant = null) -> void:
	var request := make_request(component, action)
	if not request.is_empty():
		if payload != null:
			request.payload = payload
		dispatch(request)


## Construct the wire address from a local registration, including its observed revision.
func make_request(
	component: InteractionComponent, action: StringName, phase := "act"
) -> Dictionary:
	var address := world.entities.address(component)
	if address.is_empty() or not world.entities.epoch:
		var local: CogitoPlayer = get_parent().local_actor
		if local:
			local.player_interaction_component.hint_prompt.emit(
				null, ACTIONS.hud_reason(UNSUPPORTED)
			)
		return {}
	_next_id += 1
	(
		address
		. merge(
			{
				"level_key": world.entities.level_key,
				"epoch": world.entities.epoch,
				"request_id": _next_id,
				"life": get_parent().local_actor.get_meta(&"inventory_life"),
				"expected_revision": world.revisions[address.entity_id],
				"action_id": String(action),
				"phase": phase,
			}
		)
	)
	return address


## A retry may dispatch the same envelope. The listen host enters the same sender-bound path.
func dispatch(request: Dictionary) -> void:
	if multiplayer.is_server():
		_server_request(1, request)
	else:
		_request.rpc_id(1, request)


@rpc("any_peer", "call_remote", "reliable", 2)
func _request(request: Dictionary) -> void:
	if multiplayer.is_server():
		_server_request(multiplayer.get_remote_sender_id(), request)


func _envelope(request: Dictionary) -> bool:
	if request.size() > 10:
		return false
	for key: String in ["level_key", "entity_id", "component_key", "action_id", "phase"]:
		if not request.get(key) is String or request[key].length() > 512:
			return false
	for key: String in ["request_id", "epoch", "expected_revision", "life"]:
		if not request.get(key) is int:
			return false
	return request.request_id > 0 and (request.size() == 9 or request.has("payload"))


func _server_request(peer: int, request: Dictionary) -> void:
	# A listen-host signal can synchronously submit another request during a commit.
	_queued.append([peer, request])
	if _servicing:
		return
	_servicing = true
	while not _queued.is_empty():
		var next: Array = _queued.pop_front()
		_commit_request(next[0], next[1])
	_servicing = false


func _commit_request(peer: int, request: Dictionary) -> void:
	var record := _session.for_peer(peer)
	if record.is_empty() or not _envelope(request):
		return
	if not world.entities.matches(request.level_key, request.epoch):
		_deliver(peer, _response(request, {"ok": false, "reason": "Wrong level epoch"}))
		return
	var avatar: AVATAR = get_parent().avatar_for(record.player_id)
	if avatar and avatar.lifetime != request.life:
		_deliver(peer, _response(request, {"ok": false, "reason": "Stale life"}))
		return
	var cache: Dictionary = _results.get_or_add(peer, {})
	if cache.has(request.request_id):
		_deliver(peer, cache[request.request_id])
		return
	if request.request_id <= int(_last_id.get(peer, 0)):
		_deliver(peer, _response(request, {"ok": false, "reason": "Old request"}))
		return
	_last_id[peer] = request.request_id
	var result := {"ok": false, "reason": "No avatar in level"}
	if avatar and get_parent().peer_in_level(peer):
		result = _evaluate(peer, avatar.actor.player_interaction_component, request)
	cache[request.request_id] = _response(request, result)
	for old_id: int in cache.keys():
		if old_id <= request.request_id - RESULT_CACHE:
			cache.erase(old_id)
	_deliver(peer, cache[request.request_id])


func _evaluate(peer: int, pic: PlayerInteractionComponent, request: Dictionary) -> Dictionary:
	var component := world.entities.resolve(request.entity_id, request.component_key)
	var why := _request_error(component, request)
	if not why.is_empty():
		return {"ok": false, "reason": why}
	var node := world.entities.objects[String(request.entity_id)]
	if request.phase == "dismiss" and _views.get(peer) == component:
		_views.erase(peer)
		return {"ok": true}
	return _evaluate_action(peer, pic, component, node, request)


func _evaluate_action(
	peer: int,
	pic: PlayerInteractionComponent,
	component: InteractionComponent,
	node: Node,
	request: Dictionary
) -> Dictionary:
	if devices.is_wheel(peer, component) and request.phase in ["release", "cancel"]:
		return _end_wheel(peer, pic, component, request)
	if node is CogitoTurnwheel and request.phase != "start":
		return {"ok": false, "reason": "No matching hold"}
	var busy := devices.unavailable(peer, component)
	if not busy.is_empty():
		return {"ok": false, "reason": busy}
	var phase := _hold_phase(peer, component, request)
	if phase.has("ok"):
		return phase
	var why := _actor_guard(peer, pic, component, request)
	if why.is_empty() and not (node is CogitoSittable and pic.player.current_seat == node):
		why = ACTIONS.geometry(pic.player, node, component)
	if not why.is_empty():
		return {"ok": false, "reason": why}
	return _act(peer, pic, component, node, phase.action_id, request)


func _end_wheel(
	peer: int, pic: PlayerInteractionComponent, component: InteractionComponent, request: Dictionary
) -> Dictionary:
	var phase := _hold_phase(peer, component, request)
	if phase.has("ok"):
		devices.finish_wheel(peer, false)
		return phase
	# Only the matched start envelope can finish a hold across its own pose revisions.
	var current := request.duplicate()
	current.expected_revision = world.revisions[request.entity_id]
	var why := _actor_guard(peer, pic, component, current)
	var wheel := component.get_parent() as CogitoTurnwheel
	if why.is_empty():
		why = ACTIONS.geometry(pic.player, wheel, component)
	var result := {"ok": false, "reason": why}
	if why.is_empty():
		result = _act(peer, pic, component, wheel, phase.action_id, current)
	devices.finish_wheel(peer, result.ok)
	return result


## Address, opt-in and payload checks that need no actor.
func _request_error(component: InteractionComponent, request: Dictionary) -> String:
	if not component:
		if world.is_removed(request.entity_id):
			return "Item already taken"
		return "Unknown entity or component"
	if not ACTIONS.supported(world.entities.objects[String(request.entity_id)], component):
		return UNSUPPORTED
	var key := StringName(request.action_id)
	if not ACTIONS.valid_payload(component, key, request.get("payload"), request.has("payload")):
		return "Invalid payload"
	return ""


func _actor_guard(
	peer: int, pic: PlayerInteractionComponent, component: InteractionComponent, request: Dictionary
) -> String:
	if request.expected_revision != world.revisions[request.entity_id]:
		return "Stale revision"
	if pic.player.is_dead:
		return "Player is dead"
	var seated_use: bool = pic.player.is_sitting and component.get_parent() is CogitoSittable
	if not pic.player.can_act() or (not seated_use and pic._is_interaction_blocked(component)):
		return "Posture blocks interaction"
	var private_view := (
		component is ReadableComponent
		or component is SpinnerInteraction
		or component is LockpickInteraction
		or component.get_parent() is CogitoKeypad
	)
	if _views.has(peer) and private_view:
		if _views[peer] != component:
			return "Another interface is open"
	var viewing := pic.player.is_showing_ui or _views.has(peer)
	var entering_code: bool = request.action_id == "submit_code" and _views.get(peer) == component
	if (
		(
			pic.carrying.is_carrying
			and pic.carrying.carried_object.get_parent() != component.get_parent()
		)
		or (viewing and not entering_code and not component.ignore_open_gui)
	):
		return "Actor busy"
	return ""


func _hold_phase(peer: int, component: InteractionComponent, request: Dictionary) -> Dictionary:
	var key: StringName = request.action_id
	var phase: String = request.phase
	if component is not HoldInteraction:
		if phase == "act":
			return {"action_id": key}
		return {"ok": false, "reason": "Invalid phase"}
	var dual := component is DualInteraction or component is ExtendedPickupInteraction
	if phase == "start" or (phase == "act" and dual and key == &"press"):
		return {"action_id": key}
	var held: Dictionary = _holds.get(peer, {})
	_holds.erase(peer)
	for field: String in ["entity_id", "component_key", "action_id", "expected_revision"]:
		if held.get(field) != request[field]:
			return {"ok": false, "reason": "No matching hold"}
	if phase == "cancel":
		return {"ok": true}
	return _release_key(component, key, phase, held.time)


func _release_key(
	component: HoldInteraction, key: StringName, phase: String, start: int
) -> Dictionary:
	if phase != "release":
		return {"ok": false, "reason": "Hold required"}
	var complete := Time.get_ticks_msec() - start >= component.hold_time * 1000
	if (component is DualInteraction or component is ExtendedPickupInteraction) and key == &"press":
		return {"action_id": &"hold" if complete else &"press"}
	if not complete:
		return {"ok": false, "reason": "Hold too short"}
	return {"action_id": key}


func _act(
	peer: int,
	pic: PlayerInteractionComponent,
	component: InteractionComponent,
	node: Node,
	key: StringName,
	request: Dictionary
) -> Dictionary:
	var action: CogitoInteractionAction = null
	for choice in component.get_actions(pic):
		if choice.action_id == key:
			if action:
				return {"ok": false, "reason": "Ambiguous action"}
			action = choice
	if not action or not action.enabled or component.is_disabled:
		return {"ok": false, "reason": "Disabled action"}
	if component.attribute_check and not component.attribute_passes(pic):
		var attr := pic.get_attribute(component.attribute_to_check)
		var hint := component.message_on_fail if component.message_on_fail else "Attribute required"
		var icon := attr.attribute_icon if attr else null
		return {"ok": false, "reason": hint, "hints": [[icon.resource_path if icon else "", hint]]}
	if request.phase == "start":
		_holds[peer] = request.duplicate()
		_holds[peer].time = Time.get_ticks_msec()
		if node is CogitoTurnwheel:
			devices.start_wheel(peer, component, pic)
		return {"ok": true}
	var why := ACTIONS.unavailable(node, component, key, pic)
	if not why.is_empty():
		return {"ok": false, "reason": why}
	_hint_actor = pic
	_captured_hints = []
	var quests: Node = get_parent().quests
	var previous: String = quests.signal_subject
	quests.signal_subject = pic.player.get_meta(&"net_player_id")
	var result := ACTIONS.commit(node, action, pic, request.get("payload"))
	quests.signal_subject = previous
	get_parent().inventory.flush_actor(pic.player)
	if result.get("view") in ["keypad", "read"]:
		_views[peer] = component
	elif result.get("view") == "code_ok":
		_views.erase(peer)
	result.hints = _captured_hints
	_hint_actor = null
	return result


## Capture existing actor-addressed hint text and resource references during a commit.
func route_hint(pic: PlayerInteractionComponent, icon: Texture2D, message: String) -> void:
	var hint := [icon.resource_path if icon else "", message]
	if pic == _hint_actor:
		_captured_hints.append(hint)
	elif pic.player.is_local_presentation:
		pic.hint_prompt.emit(icon, message)
	elif multiplayer.is_server():
		for record in _session.records():
			var avatar: AVATAR = get_parent().avatar_for(record.player_id)
			if avatar and avatar.actor == pic.player:
				_hint.rpc_id(record.peer_id, world.entities.level_key, world.entities.epoch, hint)
				return


@rpc("authority", "call_remote", "reliable", 2)
func _hint(key: String, epoch: int, hint: Array) -> void:
	var local: CogitoPlayer = get_parent().local_actor
	if local and world.entities.matches(key, epoch):
		var icon := load(hint[0]) as Texture2D if hint[0] else null
		local.player_interaction_component.hint_prompt.emit(icon, hint[1])


func _response(request: Dictionary, result: Dictionary) -> Dictionary:
	var response := result.duplicate()
	response.action_id = request.action_id
	for field: String in ["level_key", "epoch", "life", "request_id", "entity_id", "component_key"]:
		response[field] = request[field]
	return response


func _deliver(peer: int, response: Dictionary) -> void:
	if peer == 1:
		_result(response)
	else:
		_result.rpc_id(peer, response)


@rpc("authority", "call_remote", "reliable", 2)
func _result(result: Dictionary) -> void:
	if not world.entities.matches(result.level_key, result.epoch):
		return
	result_received.emit(result)
	if result.request_id <= _last_displayed:
		return
	_last_displayed = result.request_id
	var actor: CogitoPlayer = get_parent().local_actor
	if not actor or actor.is_dead or actor.get_meta(&"inventory_life") != result.life:
		return
	var pic := actor.player_interaction_component
	_present_hints(pic, result)
	var component := world.entities.resolve(result.entity_id, result.component_key)
	if component:
		if _local_hold.get("request_id") == result.request_id:
			if result.ok and component is HoldInteraction:
				pic.get_hud().start_hold(component)
			else:
				_local_hold.clear()
		var node := component.get_parent()
		match result.get("view", ""):
			"container":
				pic.get_hud().set_inventory_visibility(true, node)
			"read":
				_local_view = component
				component.open_net_interface(pic)
			"keypad":
				_local_view = component
				node.open_net_interface(pic, component)
			"code_ok":
				_local_view = null
				if node.keypad_ui.visible:
					node.close(pic)
			"wrong_code":
				node.clear_entered_code()
				CogitoAudio.play_sound(node.wrong_code_entered_sound)
	pic.targeting.rebuild_interaction_prompts()


func _present_hints(pic: PlayerInteractionComponent, result: Dictionary) -> void:
	var now := Time.get_ticks_msec()
	var action := [result.entity_id, result.component_key, result.action_id]
	if result.ok:
		_last_success = {"action": action, "time": now}
	elif _last_success.get("action") == action and now - _last_success.time <= DOUBLE_PRESS_MSEC:
		return
	for hint: Array in result.get("hints", []):
		_hint(result.level_key, result.epoch, hint)
	if not result.ok and not result.get("hints"):
		var message := ACTIONS.hud_reason(result.reason)
		if not message.is_empty():
			pic.hint_prompt.emit(null, message)


## An authority-triggered camera takes over from the actor's previous interaction.
func interrupt_actor(peer: int) -> void:
	_holds.erase(peer)
	_views.erase(peer)


## Tell the authority when the owner dismisses a private reader or keypad.
func dismiss_view() -> void:
	devices.dismiss()
	if is_instance_valid(_local_view):
		var request := make_request(_local_view, &"dismiss", "dismiss")
		_local_view = null
		if not request.is_empty():
			dispatch(request)


## Return the input router to gameplay before destroying a local session avatar.
func close_view(pic: PlayerInteractionComponent) -> void:
	devices.close_local()
	var component := _local_view
	_local_view = null
	if is_instance_valid(component):
		if component is ReadableComponent:
			component.close(pic)
		elif component.get_parent() is CogitoKeypad:
			component.get_parent().close(pic)


## True while the server holds a private interface grant for this actor.
func has_view(peer: int) -> bool:
	return _views.has(peer)

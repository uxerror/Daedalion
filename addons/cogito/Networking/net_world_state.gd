extends Node
## Reliable per-level object baselines, revisions and presentation events.

## Emitted on a replica after a live presentation event for this revision.
signal presented(entity: String, revision: int, event: StringName)

const ANIMATION := preload("net_animation.gd")
const ENTITIES := preload("net_entities.gd")
const CHUNK_SIZE := 32

## Identity bindings for this level.
var entities := ENTITIES.new()
## Last applied authoritative revision per entity.
var revisions := {}
var _animations: Array[ANIMATION] = []
var _states := {}
var _subscribers := {}
var _pending := {}
var _generation := 0
var _client_binding := 0
var _awaiting_avatar := false


## Bind once per live instance. The client learns the authority epoch from its baseline.
func bind(root: Node, key: String) -> void:
	_generation += 1
	_client_binding += 1
	entities.bind(root, key, _generation if multiplayer.is_server() else 0)
	for id in entities.objects:
		var node := entities.objects[id]
		node.set_meta(&"cogito_net_world", self)
		revisions[id] = 0
		if node.has_method("net_state"):
			_states[id] = node.net_state()
			if multiplayer.is_server():
				node.connect("net_changed", _changed.bind(id))
				if node.has_method("net_bind_authority"):
					node.net_bind_authority()
			else:
				var animation: AnimationPlayer
				if node is CogitoDoor:
					animation = node.anim_player
				elif node is CogitoSwitch:
					animation = node.animation_player
				if animation:
					var presentation := ANIMATION.new()
					presentation.bind(animation)
					_animations.append(presentation)
				if node.has_method("net_bind_replica"):
					node.net_bind_replica()


## Tombstone kept for late joiners and contested pickup replies.
func is_removed(id: String) -> bool:
	return _states.get(id, {}).get("removed", false)


## Client load nonce echoed by the baseline, including when reloading the same key.
func binding() -> int:
	return _client_binding


## Release subscriptions before another level reuses these authored ids.
func clear() -> void:
	for animation in _animations:
		animation.restore()
	_animations.clear()
	for id in entities.objects:
		var node: Variant = entities.objects[id]
		if not is_instance_valid(node):
			continue
		if node.has_method("net_unbind"):
			node.net_unbind()
		node.remove_meta(&"cogito_net_world")
		if node.has_signal(&"net_changed") and node.is_connected(&"net_changed", _changed.bind(id)):
			node.disconnect(&"net_changed", _changed.bind(id))
	_awaiting_avatar = false
	entities = ENTITIES.new()
	revisions.clear()
	_states.clear()
	_subscribers.clear()
	_pending.clear()


## Activate an authored link in this level, preserving its original instigator across delays.
func activate_link(target: Node, actor: PlayerInteractionComponent) -> void:
	if not multiplayer.is_server() or entities.id_for(target).is_empty():
		return
	if target is CogitoDoor:
		if not target.is_locked:
			target.interact(actor)
	elif target is CogitoButton or target is CogitoSwitch:
		if is_instance_valid(actor):
			target.interact(actor)
		elif not target.needs_item_to_operate:
			target.player_interaction_component = null
			if not target.allows_repeated_interaction:
				if target is CogitoSwitch and target.is_on:
					return
				if target is CogitoButton and target.has_been_used:
					return
			if target is CogitoSwitch:
				target.switch()
			elif not target.currency_check and target.cooldown <= 0:
				target.press()


## Private area events may start once this observer has installed its baseline.
func ready_for_events(peer: int) -> bool:
	return peer == 1 or (_subscribers.has(peer) and not _pending.has(peer))


## Remove a departed observer and any deltas waiting for its baseline acknowledgement.
func forget(peer: int) -> void:
	_subscribers.erase(peer)
	_pending.erase(peer)


## Capture a consistent baseline. Queue subsequent changes until channel 3 has caught up.
func subscribe(peer: int, nonce: int) -> void:
	if _subscribers.has(peer):
		return
	_subscribers[peer] = nonce
	_pending[peer] = []
	var chunk := []
	for id: String in _states:
		if not entities.live_object(id) and not _states[id].get("removed", false):
			continue
		chunk.append([id, revisions[id], _states[id]])
		if chunk.size() == CHUNK_SIZE:
			_baseline.rpc_id(peer, entities.level_key, entities.epoch, nonce, chunk, false)
			chunk = []
	_baseline.rpc_id(peer, entities.level_key, entities.epoch, nonce, chunk, true)


@rpc("authority", "call_remote", "reliable", 3)
func _baseline(key: String, epoch: int, nonce: int, rows: Array, last: bool) -> void:
	if not entities.root or key != entities.level_key or nonce != _client_binding:
		return
	if entities.epoch != 0 and entities.epoch != epoch:
		return
	for row: Array in rows:
		_apply(row[0], row[1], row[2], true)
	if last:
		entities.epoch = epoch
		_awaiting_avatar = true
		acknowledge_local_avatar()


## Spawn uses a different channel. Release private events only when the owner also exists.
func acknowledge_local_avatar() -> void:
	if _awaiting_avatar and get_parent().local_actor:
		_awaiting_avatar = false
		_ack.rpc_id(1, entities.level_key, entities.epoch, _client_binding)


@rpc("any_peer", "call_remote", "reliable", 2)
func _ack(key: String, epoch: int, nonce: int) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if not multiplayer.is_server() or not entities.matches(key, epoch):
		return
	if _subscribers.get(peer) != nonce or not _pending.has(peer):
		return
	for change: Array in _pending[peer]:
		_send_change(peer, change)
	_pending.erase(peer)
	get_parent().inventory.baseline(peer)
	get_parent().projectiles.baseline(peer)


func _changed(event: StringName, id: String) -> void:
	var node := entities.live_object(id)
	if not node:
		return
	var state: Dictionary = node.net_state()
	publish(id, state, event)


## Publish server-owned lifecycle records using the same baseline and acknowledgement as devices.
func publish(id: String, state: Dictionary, event: StringName = &"") -> void:
	revisions[id] = revisions.get(id, 0) + 1
	_states[id] = state
	_broadcast([id, revisions[id], state, event])


## Track physics independently of inventory eligibility. A falling pickup keeps its revision.
func publish_pose(id: String, pose: Transform3D) -> void:
	if _states.has(id) and not is_removed(id):
		_states[id].pose = pose
		_broadcast([id, revisions[id], pose])


func _broadcast(change: Array) -> void:
	for peer: int in _subscribers:
		if not get_parent().peer_in_level(peer):
			continue
		if _pending.has(peer):
			_pending[peer].append(change)
		else:
			_send_change(peer, change)


func _send_change(peer: int, change: Array) -> void:
	_delta.rpc_id(peer, entities.level_key, entities.epoch, change)


@rpc("authority", "call_remote", "reliable", 2)
func _delta(key: String, epoch: int, change: Array) -> void:
	if not entities.matches(key, epoch):
		return
	var observed: int = revisions.get(change[0], -1)
	if change[2] is Transform3D:
		var body := entities.live_object(change[0]) as Node3D
		if body and observed == change[1]:
			body.global_transform = change[2]
			_states[change[0]].pose = change[2]
		return
	if change[1] <= observed:
		return
	if _apply(change[0], change[1], change[2], false):
		var node := entities.objects[String(change[0])]
		if node.has_method("present_net_event"):
			node.present_net_event(change[3])
		presented.emit(change[0], change[1], change[3])


func _apply(id: String, revision: int, state: Dictionary, silent: bool) -> bool:
	var tombstone: bool = state.size() == 1 and state.get("removed", false)
	if state.has("quantity") or tombstone or id.begins_with("runtime:"):
		if get_parent().spawner.apply(id, state):
			revisions[id] = revision
			_states[id] = state
		return false
	var node := entities.live_object(id)
	if not node:
		return false
	node.apply_net_state(state, silent)
	revisions[id] = revision
	_states[id] = state
	var actor: CogitoPlayer = get_parent().local_actor
	if actor:
		var targeting := actor.player_interaction_component.targeting
		var pick_prompt: bool = (
			node is LockpickInteraction and targeting.interactable == node.get_parent()
		)
		if targeting.interactable == node or pick_prompt:
			targeting.rebuild_interaction_prompts()
	return true

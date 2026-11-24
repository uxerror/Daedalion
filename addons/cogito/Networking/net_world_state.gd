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
		if not entities.live_object(id):
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
		_ack.rpc_id(1, key, epoch, nonce)


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


func _changed(event: StringName, id: String) -> void:
	var node := entities.live_object(id)
	if not node:
		return
	var state: Dictionary = node.net_state()
	revisions[id] += 1
	_states[id] = state
	var change := [id, revisions[id], state, event]
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
	if not entities.matches(key, epoch) or change[1] <= revisions.get(change[0], -1):
		return
	if _apply(change[0], change[1], change[2], false):
		var node := entities.objects[String(change[0])]
		if node.has_method("present_net_event"):
			node.present_net_event(change[3])
		presented.emit(change[0], change[1], change[3])


func _apply(id: String, revision: int, state: Dictionary, silent: bool) -> bool:
	var node := entities.live_object(id)
	if not node:
		return false
	node.apply_net_state(state, silent)
	revisions[id] = revision
	_states[id] = state
	var actor: CogitoPlayer = get_parent().local_actor
	if actor:
		var targeting := actor.player_interaction_component.targeting
		if targeting.interactable == node:
			targeting.rebuild_interaction_prompts()
	return true

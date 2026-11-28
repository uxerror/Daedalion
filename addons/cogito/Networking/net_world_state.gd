extends Node
## Reliable per-level object baselines, revisions and presentation events.

## Emitted on a replica after a live presentation event for this revision.
signal presented(entity: String, revision: int, event: StringName)

const Config := preload("net_config.gd")
const ANIMATION := preload("net_animation.gd")
const ENTITIES := preload("net_entities.gd")
const Support := preload("net_support_motion.gd")
const Snapshot := preload("net_snapshot.gd")
const CHUNK_SIZE := 32

## Identity bindings for this level.
var entities := ENTITIES.new()
## Last applied authoritative revision per entity.
var revisions := {}
## Public carrier identities by body id. Empty hands have no map entry.
var holders: Dictionary[String, String] = {}
var supports: Dictionary[int, Support] = {}
var support_tick := 0
var _ambiguous := {}
var _sample_tick := -1
var _sample_frame := 0
var _sample_time := 0
var _render_tick := -1.0
var _animations: Array[ANIMATION] = []
var _states := {}
var _subscribers := {}
var _pending := {}
var _generation := 0
var _client_binding := 0
var _awaiting_avatar := false


func _ready() -> void:
	process_physics_priority = -100
	set_physics_process(false)


func bind_support(node: CogitoDoor, id: String) -> Support:
	var key := id.hash()
	if key == 0 or _ambiguous.has(key):
		return null
	if supports.has(key):
		var previous := supports[key]
		if previous.door == node:
			return previous
		_ambiguous[key] = true
		previous.door.net_support = null
		previous.close()
		_states[entities.id_for(previous.door)] = previous.door.net_state()
		supports.erase(key)
		return null
	var motion := Support.new(node, key)
	node.tree_exiting.connect(_remove_support.bind(node, key), CONNECT_ONE_SHOT)
	supports[key] = motion
	set_physics_process(true)
	return motion


func _remove_support(node: CogitoDoor, key: int) -> void:
	if supports.has(key) and supports[key].door == node:
		node.net_support.close()
		node.net_support = null
		supports.erase(key)
		set_physics_process(not supports.is_empty())


func observe_tick(tick: int) -> void:
	if tick > _sample_tick:
		_sample_tick = tick
		_sample_frame = Engine.get_physics_frames()
		_sample_time = Time.get_ticks_usec()


func _physics_process(_dt: float) -> void:
	if not entities.root.can_process():
		return
	if multiplayer.is_server():
		drive_supports(get_parent()._tick + 1)
	elif _sample_tick >= 0:
		var viewer: CogitoPlayerAdvanced = get_parent().local_actor
		if viewer and viewer.owner_prediction and viewer.owner_prediction.active:
			var prediction := viewer.owner_prediction
			drive_supports(
				prediction.baseline.tick + prediction.newest - prediction.baseline.ack + 1
			)
		else:
			drive_supports(_sample_tick + Engine.get_physics_frames() - _sample_frame)


func drive_supports(tick: int) -> void:
	support_tick = tick
	for key: int in supports:
		supports[key].drive(tick)


func present_supports() -> float:
	if supports.is_empty() or _sample_tick < 0:
		return -1
	var elapsed := (Time.get_ticks_usec() - _sample_time) / 1000000.0
	var rate := Engine.physics_ticks_per_second
	_render_tick = maxf(_render_tick, _sample_tick + (elapsed - Snapshot.DELAY) * rate)
	for key: int in supports:
		supports[key].present(visual_pose(key, _render_tick))
	return _render_tick


func visual_pose(key: int, remote_tick: float) -> Transform3D:
	var viewer: CogitoPlayerAdvanced = get_parent().local_actor
	if viewer and viewer.owner_prediction and viewer.owner_prediction.active:
		if viewer.owner_prediction.presented_support_key == key:
			return viewer.owner_prediction.presented_support_pose
	return supports[key].world_pose(remote_tick)


## Capture each adapter in its own coordinate space, including unobserved tombstones.
func capture() -> Dictionary:
	var records := _states.duplicate(true)
	for id: String in records:
		var node := entities.live_object(id)
		if not node:
			continue
		if node.has_method("net_state"):
			records[id] = node.net_state()
			if node is CogitoDoor and node.net_support:
				records[id].segment = node.net_support.baseline(support_tick)
				records[id].saved_tick = support_tick
		if node is CogitoSittable:
			records[id].occupant = ""
		if node is CogitoNPC:
			records[id].swing = -1
		if id.begins_with("runtime:") and get_parent().spawner.owns(id):
			records[id].pose = node.frame_root() if node is NetNpcCorpse else node.global_transform
	return records


## Install durable records before the first subscription. Runtime ids remain reserved.
func restore(records: Dictionary) -> Error:
	for id: String in records:
		if id.begins_with("runtime:"):
			get_parent().spawner.reserve_id(id)
		var row: Dictionary = records[id]
		var door := entities.live_object(id) as CogitoDoor
		if door and door.net_support and row.has("segment"):
			row = row.duplicate(true)
			row.segment.tick += support_tick - int(row.get("saved_tick", support_tick))
			row.erase("saved_tick")
		apply_state(id, 1, row, true)
		if door:
			_states[id] = door.net_state()
		if id.begins_with("runtime:") and not row.get("removed", false):
			if not entities.live_object(id):
				return ERR_CANT_CREATE
	for id: String in records:
		var node := entities.live_object(id)
		if node is CogitoNPC and node.network_state.dead:
			node.network_state.disable_simulation()
		if node is CogitoSnapSlot:
			node.restore_network_binding(entities.live_object(node.snapped_id))
			_states[id] = node.net_state()
	return OK


## Bind once per live instance. The client learns the authority epoch from its baseline.
func bind(root: Node, key: String) -> void:
	_generation = get_parent().travel.next_serial()
	_client_binding = _generation
	entities.registered.connect(_runtime_registered)
	entities.bind(root, key, _generation if multiplayer.is_server() else 0)
	var enabled := multiplayer.is_server() and Config.movement_enabled("COGITO_AUTHORITY_MOVEMENT")
	for id in entities.objects:
		var node := entities.objects[id]
		node.set_meta(&"cogito_net_world", self)
		# A room-mounted, unanimated switch (e.g. a Laboratory lamp) only
		# changes lights/meshes. A child of a moving mechanism has no such contract.
		if node is CogitoSwitch and node is AnimatableBody3D:
			if node.get_parent() == root and not node.animation_player:
				node.set_meta(&"cogito_fixed_switch_pose", node.global_transform)
		if enabled and node is CogitoDoor and Support.accepts(node):
			node.net_support = bind_support(node, id)
		revisions[id] = 0
		_watch_area(id, node)
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


func _runtime_registered(id: String, node: Node) -> void:
	node.set_meta(&"cogito_net_world", self)
	revisions.get_or_add(id, 0)
	_watch_area(id, node)
	get_parent().elements.track(id, node)
	if node is RigidBody3D or node is NetNpcCorpse:
		get_parent().bodies.track(id, node)


func _watch_area(id: String, node: Node) -> void:
	if node is CogitoElementArea and multiplayer.is_server() and entities.has_actions(id):
		node.enabled_changed.connect(_area_enabled.bind(id))


func _area_enabled(_enabled: bool, id: String) -> void:
	# An interactable area's MP2 guard changes immediately. MP7 supplies its visible state.
	publish(id, {})


## Replace an authored stand object under its original id after RESET.
func restore_element_object(node: Node) -> void:
	var id := CogitoPersistentId.of(node)
	_states[id] = {}
	holders.erase(id)
	revisions[id] = revisions.get(id, 0) + 1
	entities.register_runtime(id, node)


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
		if node is CogitoElementArea and node.enabled_changed.is_connected(_area_enabled.bind(id)):
			node.enabled_changed.disconnect(_area_enabled.bind(id))
		if node is CogitoDoor:
			var remove := _remove_support.bind(node, id.hash())
			if node.tree_exiting.is_connected(remove):
				node.tree_exiting.disconnect(remove)
		if node.has_method("net_unbind"):
			node.net_unbind()
		node.remove_meta(&"cogito_net_world")
		if node.has_signal(&"net_changed") and node.is_connected(&"net_changed", _changed.bind(id)):
			node.disconnect(&"net_changed", _changed.bind(id))
	supports.clear()
	_ambiguous.clear()
	set_physics_process(false)
	support_tick = 0
	_sample_tick = -1
	_render_tick = -1
	_awaiting_avatar = false
	entities = ENTITIES.new()
	revisions.clear()
	holders.clear()
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
	elif target is CogitoElementArea:
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
	if peer == 1:
		return get_parent().peer_in_level(peer)
	return _subscribers.has(peer) and not _pending.has(peer)


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
	var players := get_parent()
	var viewer: CogitoPlayer = (
		players.avatar_for(players.get_parent().for_peer(peer).player_id).actor
	)
	var chunk := []
	for id: String in _states:
		var node := entities.live_object(id)
		var state: Dictionary = _states[id]
		if node is CogitoNPC:
			if (
				not node.network_state.dead
				and not node.network_state.in_interest(viewer.global_position)
			):
				continue
			state = node.network_state.at_send_time(node.net_state())
		if not node and not state.get("removed", false):
			continue
		# Spawner specs carry a global pose; refresh it for objects that moved since spawn.
		# Authored adapters (the spinner's local knob pose) keep their own meaning.
		if node is Node3D and state.has("pose") and get_parent().spawner.owns(id):
			state = state.duplicate()
			state.pose = node.frame_root() if node is NetNpcCorpse else node.global_transform
		if node is CogitoDoor and node.net_support:
			state = node.net_state()
			state.segment = node.net_support.baseline(support_tick)
			state.sample_tick = support_tick
		var row := [id, revisions[id], state]
		if holders.has(id):
			row.append(holders[id])
		chunk.append(row)
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
		apply_state(row[0], row[1], row[2], true)
		if row.size() > 3:
			holders[row[0]] = row[3]
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
	if node is CogitoNPC:
		var old: Dictionary = _states.get(id, {})
		if old.get("health") != state.health or old.get("dead") != state.dead:
			get_parent().mark_world_dirty()
		# Active observers receive NPC state on the interest stream after baseline acknowledgement.
		revisions[id] = revisions.get(id, 0) + 1
		_states[id] = state
	else:
		publish(id, state, event)


## Publish server-owned lifecycle records using the same baseline and acknowledgement as devices.
func publish(id: String, state: Dictionary, event: StringName = &"") -> void:
	get_parent().mark_world_dirty()
	revisions[id] = revisions.get(id, 0) + 1
	_states[id] = state
	if state.get("removed", false):
		holders.erase(id)
	_broadcast([id, revisions[id], state, event])


## Invalidate requests observed before an exclusive grab or release, retaining the item's state.
func publish_holder(id: String, player_id: String) -> void:
	if id.is_empty() or is_removed(id):
		return
	_states.get_or_add(id, {})
	revisions[id] = revisions.get(id, 0) + 1
	_set_holder(id, player_id)
	_broadcast([id, revisions[id], player_id])


func _set_holder(id: String, player_id: String) -> void:
	if player_id.is_empty():
		holders.erase(id)
	else:
		holders[id] = player_id


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
	if change[1] <= observed:
		return
	if change[2] is String:
		_set_holder(change[0], change[2])
		revisions[change[0]] = change[1]
		return
	# A destroyed object's death effects play on its copy before the copy is removed.
	var dying: Node = entities.live_object(change[0]) if change[3] == &"death" else null
	if is_instance_valid(dying):
		for health in dying.find_children("*", "CogitoHealthAttribute", false, false):
			health.present_net_death(get_parent().spawner)
	if apply_state(change[0], change[1], change[2], false):
		var node := entities.objects[String(change[0])]
		if node.has_method("present_net_event"):
			node.present_net_event(change[3])
		presented.emit(change[0], change[1], change[3])


## Install authoritative fields. Return true for devices that accept a live presentation event.
func apply_state(id: String, revision: int, state: Dictionary, silent: bool) -> bool:
	if state.is_empty():
		revisions[id] = revision
		return false
	var tombstone: bool = state.size() == 1 and state.get("removed", false)
	if tombstone:
		holders.erase(id)
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
	if node is CogitoNPC:
		return false
	var actor: CogitoPlayer = get_parent().local_actor
	if actor:
		var targeting := actor.player_interaction_component.targeting
		var pick_prompt: bool = (
			node is LockpickInteraction and targeting.interactable == node.get_parent()
		)
		if targeting.interactable == node or pick_prompt:
			targeting.rebuild_interaction_prompts()
	return true

extends Node
## Reliable per-listener state shares the MP4 interest radius and level-ready barrier.

var tracked: Array[CogitoNPC] = []
var _seen := {}
var _untrack := {}


## Bind authored actors once. Runtime corpses use MP4's body registry directly.
func track(npc: CogitoNPC) -> void:
	tracked.append(npc)
	_untrack[npc] = _forget_npc.bind(npc)
	npc.tree_exiting.connect(_untrack[npc], CONNECT_ONE_SHOT)


## Forget bound actors and all per-observer samples on level exit.
func clear() -> void:
	for npc: CogitoNPC in _untrack:
		if is_instance_valid(npc) and npc.tree_exiting.is_connected(_untrack[npc]):
			npc.tree_exiting.disconnect(_untrack[npc])
	_untrack.clear()
	tracked.clear()
	_seen.clear()


func _forget_npc(npc: CogitoNPC) -> void:
	tracked.erase(npc)
	_untrack.erase(npc)


## Clear a departed observer's interest history.
func forget(peer: int) -> void:
	_seen.erase(peer)


## Called by the authoritative footstep clock, including on a server with no audio nodes.
func noise(actor: CogitoPlayer, magnitude: float) -> void:
	if not multiplayer.is_server():
		return
	var id: String = actor.get_meta(&"net_player_id", "")
	for npc in tracked:
		if npc.perception and not npc.network_state.dead:
			npc.perception.hear(id, actor.global_position, magnitude)


## Send a changed public revision and this listener's private presentation together.
func publish(peer: int, position: Vector3, id: String) -> void:
	var world: Variant = get_parent().world
	var entities: Variant = world.entities
	var seen: Dictionary = _seen.get_or_add(peer, {})
	var rows := []
	for npc in tracked:
		var key: String = entities.id_for(npc)
		if npc.network_state.in_interest(position):
			var current := [npc.net_state(), npc.network_state.listener(id), world.revisions[key]]
			if current != seen.get(key, []):
				var fields := npc.network_state.at_send_time(current[0])
				rows.append([key, [fields, current[1], current[2]]])
				seen[key] = current
		elif seen.erase(key):
			rows.append([key, []])
	if not rows.is_empty():
		_receive.rpc_id(peer, entities.level_key, entities.epoch, rows)


@rpc("authority", "call_remote", "reliable", 2)
func _receive(key: String, epoch: int, rows: Array) -> void:
	var entities: Variant = get_parent().world.entities
	if entities.matches(key, epoch):
		for row: Array in rows:
			var npc := entities.live_object(row[0]) as CogitoNPC
			if npc and npc.network_state:
				var fields: Array = row[1]
				if fields.is_empty():
					npc.hide()
					npc.network_state.present_listener(Vector3i.ZERO)
				else:
					get_parent().world.apply_state(row[0], fields[2], fields[0], true)
					npc.visible = not npc.network_state.dead
					npc.network_state.present_listener(fields[1])

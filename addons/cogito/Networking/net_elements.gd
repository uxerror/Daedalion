extends Node
## Reliable, change-driven element samples. Interest affects delivery only.

const State := preload("net_element_state.gd")
const Bodies := preload("net_bodies.gd")
const INTERVAL := 0.1
const CHUNK := 32

var _states: Dictionary[String, State] = {}
var _urgent := {}
var _seen := {}
var _exits := {}
var _clock := 0.0
var _elapsed := 0.0


## Register authored, reset and runtime objects using their level-registry identity.
func track(id: String, node: Node) -> void:
	if node is CogitoElementArea:
		_bind(id, node)
	for child in node.get_children():
		if child is CogitoProperties:
			_bind(id + "/" + String(child.name), child)


func _bind(id: String, component: Node3D) -> void:
	if _states.has(id):
		return
	var state := State.new(component)
	_states[id] = state
	_exits[id] = _untrack.bind(id)
	component.tree_exiting.connect(_exits[id], CONNECT_ONE_SHOT)
	if multiplayer.is_server():
		state.watch_flags(_flag_changed.bind(id))
	else:
		state.bind_replica()


func _flag_changed(id: String) -> void:
	_urgent[id] = true
	get_parent().mark_world_dirty()


func _untrack(id: String) -> void:
	_states[id].unwatch()
	_states.erase(id)
	_urgent.erase(id)
	_exits.erase(id)
	for seen: Dictionary in _seen.values():
		seen.erase(id)


## Release level-local references before another instance binds the same ids.
func clear() -> void:
	for id: String in _states.keys():
		var state := _states[id]
		state.anchor.tree_exiting.disconnect(_exits[id])
		state.unwatch()
		if state.props and state.props.network_replica:
			state.props.unbind_element_replica()
		if state.area and state.area.network_replica:
			state.area.unbind_element_replica()
	_states.clear()
	_exits.clear()
	_seen.clear()
	_urgent.clear()


## Re-entry after disconnect always needs a full, silent sample.
func forget(peer: int) -> void:
	_seen.erase(peer)


## Batch flag edges after physics and coalesce continuous buildup at ten samples per second.
func advance(delta: float, positions: Dictionary, peers: Array[int]) -> void:
	_clock += delta
	_elapsed += delta
	var periodic := _elapsed + 0.000001 >= INTERVAL
	if periodic:
		_elapsed = fmod(_elapsed + 0.000001, INTERVAL)
	elif _urgent.is_empty():
		return
	if peers.is_empty():
		_urgent.clear()
		return
	var sampled := {}
	var candidates := _states.keys() if periodic else _urgent.keys()
	_urgent.clear()
	for peer in peers:
		var seen: Dictionary = _seen.get_or_add(peer, {})
		var props := []
		var actors := []
		for id: String in candidates:
			var state := _states[id]
			if (
				state.anchor.global_position.distance_squared_to(positions[peer])
				> Bodies.INTEREST ** 2
			):
				seen.erase(id)
				continue
			if not sampled.has(id):
				state.sample(_clock)
				sampled[id] = true
			if seen.get(id, -1) == state.revision:
				continue
			var rows := actors if id.begins_with("avatar:") else props
			rows.append([id, state.revision, not seen.has(id), state.sampled])
			seen[id] = state.revision
		_send(peer, actors, true)
		_send(peer, props, false)


func _send(peer: int, rows: Array, actors: bool) -> void:
	var entities: Variant = get_parent().world.entities
	for offset in range(0, rows.size(), CHUNK):
		var chunk := rows.slice(offset, offset + CHUNK)
		if actors:
			_actor_states.rpc_id(peer, entities.level_key, entities.epoch, _clock, chunk)
		else:
			_world_states.rpc_id(peer, entities.level_key, entities.epoch, _clock, chunk)


# Share the avatar spawn channel and the MP3 lifecycle channel respectively.
@rpc("authority", "call_remote", "reliable", 0)
func _actor_states(key: String, epoch: int, now: float, rows: Array) -> void:
	_install(key, epoch, now, rows)


@rpc("authority", "call_remote", "reliable", 2)
func _world_states(key: String, epoch: int, now: float, rows: Array) -> void:
	_install(key, epoch, now, rows)


func _install(key: String, epoch: int, now: float, rows: Array) -> void:
	if not get_parent().world.entities.matches(key, epoch):
		return
	for row: Array in rows:
		var state: State = _states.get(row[0])
		if state and (row[2] or row[1] > state.revision):
			state.revision = row[1]
			state.apply(row[3], now, row[2])

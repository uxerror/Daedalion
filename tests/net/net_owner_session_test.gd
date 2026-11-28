extends "memory_session_suite.gd"

var _root: Node3D
var _previous: Node
var _server: Facade
var _owner: Facade
var _id: String


class WieldProbe:
	extends "res://addons/cogito/Networking/net_wield.gd"
	var acknowledgements: Array[int] = []

	func reconcile(ack: int, _accepted: int) -> void:
		acknowledgements.append(ack)


func before_test() -> void:
	_previous = get_tree().current_scene
	_root = Node3D.new()
	get_tree().root.add_child(_root)
	get_tree().current_scene = _root


func after_test() -> void:
	super.after_test()
	get_tree().current_scene = _previous
	_root.free()


func _join(number: int, port: int) -> Facade:
	var client := _branch(number)
	assert_int(client.join("memory", port)).is_equal(OK)
	_level(client)
	_pump()
	return client


func _start(listen: bool) -> void:
	_server = _branch(1, _root)
	var cfg := {"save_dir": create_temp_dir("owner-%d" % Time.get_ticks_usec())}
	var err := _server.host(cfg) if listen else _server.start_server(cfg)
	assert_int(err).is_equal(OK)
	_level(_server)
	_network[1].capture = true
	_owner = _join(2, 1861)
	_id = _owner.local_player_id()


func _wire_contains(peer: int, block: NetOwnerState) -> bool:
	var header := NetOwnerState.encode(block).slice(0, NetOwnerState.HEADER_BYTES).hex_encode()
	for i in _network[1].sent.size():
		if _network[1].destinations[i] == peer and header in _network[1].sent[i].hex_encode():
			return true
	return false


func _privacy(listen: bool) -> void:
	_start(listen)
	var view := _owner.player_world.avatar_for(_id)
	var spawn := view.latest_owner_baseline()
	assert_object(spawn).is_not_null()
	assert_int(spawn.life).is_equal(view.lifetime)
	assert_int(spawn.binding).is_equal(_owner.player_world.world.binding())
	var observer := _join(3, 1862)
	var remote := observer.player_world.avatar_for(_id)
	assert_bool(_wire_contains(2, spawn)).is_true()
	assert_bool(_wire_contains(3, spawn)).is_false()
	assert_object(remote.latest_owner_baseline()).is_null()
	if listen:
		var host_id := _server.local_player_id()
		assert_object(_server.player_world.avatar_for(host_id).latest_owner_baseline()).is_null()
		assert_object(_owner.player_world.avatar_for(host_id).latest_owner_baseline()).is_null()
	_server.player_world.renew_life(_id)
	_pump()
	var renewed := view.latest_owner_baseline()
	assert_int(renewed.life).is_greater(spawn.life)
	assert_int(renewed.generation).is_greater(spawn.generation)
	assert_object(renewed.state).is_null()
	assert_int(renewed.ack).is_equal(-1)
	assert_bool(_wire_contains(2, renewed)).is_true()
	assert_bool(_wire_contains(3, renewed)).is_false()
	await _ticks(36)
	var latest := view.latest_owner_baseline()
	assert_int(latest.tick).is_greater(renewed.tick)
	var enabled := OS.get_environment("COGITO_AUTHORITY_MOVEMENT") == "1"
	assert_bool(latest.state != null).is_equal(enabled)
	assert_bool(_wire_contains(2, latest)).is_true()
	assert_bool(_wire_contains(3, latest)).is_false()
	assert_int(remote.timeline.latest().tick).is_equal(latest.tick)
	assert_object(remote.latest_owner_baseline()).is_null()
	_server.player_world.mark_teleport(_id)
	await _ticks(5)
	var teleported := view.latest_owner_baseline()
	assert_int(teleported.revision).is_greater(latest.revision)
	assert_int(teleported.generation).is_greater(latest.generation)
	var takeover := _join(4, 1861)
	assert_object(view.latest_owner_baseline()).is_null()
	var replacement := takeover.player_world.avatar_for(_id)
	var next := replacement.latest_owner_baseline()
	assert_int(next.generation).is_greater(teleported.generation)
	assert_int(next.life).is_greater(teleported.life)
	takeover.disconnect_session()
	_pump()
	assert_object(replacement.latest_owner_baseline()).is_null()
	var reconnect := _join(5, 1861)
	assert_int(reconnect.player_world.avatar_for(_id).latest_owner_baseline().life).is_greater(
		next.life
	)


func test_private_spawn_poses_renewal_and_takeover_dedicated() -> void:
	await _privacy(false)


func test_private_spawn_poses_renewal_and_takeover_listen() -> void:
	await _privacy(true)


func _send(block: NetOwnerState, frame: Dictionary, life: int) -> void:
	frame.owner_state = NetOwnerState.encode(block)
	frame.tick = block.tick
	frame.revision = block.revision
	frame.ack = block.ack
	_owner.player_world._receive_pose(_id, life, frame, block.ack)


func test_newer_held_state_and_rejected_wield_ack() -> void:
	_start(false)
	await _ticks(16)
	var view := _owner.player_world.avatar_for(_id)
	var original := view.wield
	var recorder := WieldProbe.new()
	view.wield = recorder
	var block := NetOwnerState.decode(NetOwnerState.encode(view.latest_owner_baseline()))
	var frame := view.timeline.latest().duplicate()
	block.tick += 10
	block.ack = 40
	block.disposition = NetOwnerState.Disposition.FRESH
	block.last_fresh_tick = block.tick
	_send(block, frame, view.lifetime)
	block.tick += 1
	block.disposition = NetOwnerState.Disposition.HELD
	block.discontinuities += 1
	frame.position += Vector3.RIGHT
	_send(block, frame, view.lifetime)
	var held := view.latest_owner_baseline()
	assert_int(held.tick).is_equal(block.tick)
	assert_vector(view.timeline.latest().position).is_equal(frame.position)
	block.tick -= 1
	_send(block, frame, view.lifetime)
	block.tick += 5
	block.life -= 1
	_send(block, frame, view.lifetime)
	block.life = view.lifetime
	block.binding += 9
	_send(block, frame, view.lifetime)
	assert_object(view.latest_owner_baseline()).is_same(held)
	assert_array(recorder.acknowledgements).contains_exactly([40, 40])
	view.wield = original


func test_protocol_14_is_rejected_at_admission() -> void:
	_start(false)
	var old := _branch(3)
	var failures: Array[String] = []
	old.session_failed.connect(func(reason: String): failures.append(reason))
	assert_int(old.join("memory", 1863)).is_equal(OK)
	var session := old._session
	old.multiplayer.connected_to_server.disconnect(session._connected)
	var hello := func(): session._hello.rpc_id(1, 14, session.config.content_version, "")
	old.multiplayer.connected_to_server.connect(hello, CONNECT_ONE_SHOT)
	_pump()
	assert_array(failures).contains_exactly(["Protocol version mismatch"])
	assert_int(_server.players().size()).is_equal(1)
	assert_object(_owner.local_player()).is_not_null()

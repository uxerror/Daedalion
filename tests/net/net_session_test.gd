extends GdUnitTestSuite

const Facade := preload("res://addons/cogito/Networking/cogito_net.gd")
const Transport := preload("res://addons/cogito/Networking/enet_transport.gd")
const MemoryPeer := preload("memory_peer.gd")

var _network := {}
var _branches: Array[Facade] = []


class MemoryTransport:
	extends Transport
	var network: Dictionary
	var id: int

	func _init(peers: Dictionary, peer_id: int) -> void:
		network = peers
		id = peer_id

	func open_server(_config: Dictionary, _listen: bool) -> Error:
		_register()
		return OK

	func open_client(_address: String, _port: int) -> Error:
		_register()
		network[1].arrivals.append(id)
		network[id].arrivals.append(1)
		return OK

	func _register() -> void:
		var link := MemoryPeer.new()
		link.id = id
		link.network = network
		network[id] = link
		peer = link


class Walker:
	extends CogitoPlayerInputSource
	var frames := 0

	func sample(actor: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
		var command := super.sample(actor, sequence)
		command.move = Vector2.UP if frames < 60 else Vector2.ZERO
		command.pitch = 0.35
		frames += 1
		return command


func _branch(id: int) -> Facade:
	var branch := Facade.new()
	branch.name = "Branch%d" % id
	add_child(branch)
	get_tree().set_multiplayer(SceneMultiplayer.new(), branch.get_path())
	branch.transport_factory = func() -> Transport: return MemoryTransport.new(_network, id)
	_branches.append(branch)
	return branch


func _pump() -> void:
	# Bounded synchronous engine polls deliver path negotiation, RPCs and their replies.
	for tick in 12:
		for branch: Facade in _branches:
			if branch.is_online():
				branch.multiplayer.poll()


func after_test() -> void:
	for branch: Facade in _branches:
		branch.disconnect_session()
		get_tree().set_multiplayer(null, branch.get_path())
		branch.free()
	_branches.clear()
	_network.clear()


func test_listen_capacity_snapshot_and_departure() -> void:
	var server := _branch(1)
	var client := _branch(2)
	var full := _branch(3)
	var cfg := {"max_players": 2, "save_dir": "user://net/branch-listen"}
	assert_int(server.host(cfg)).is_equal(OK)
	assert_int(server.players().size()).is_equal(1)
	assert_int(client.join("memory", 1201, {"display_name": "Ada"})).is_equal(OK)
	_pump()
	assert_int(client.players().size()).is_equal(2)
	var id := client.local_player_id()
	assert_str(id).is_not_empty()
	assert_str(server.player_for_peer(2).get("player_id", "")).is_equal(id)
	var copy := client.player_for_id(id)
	assert_str(copy.get("display_name", "")).is_equal("Ada")
	copy.display_name = "Changed"
	assert_str(client.player_for_peer(2).get("display_name", "")).is_equal("Ada")
	var failures: Array[String] = []
	full.session_failed.connect(func(reason: String) -> void: failures.append(reason))
	assert_int(full.join("memory", 1202)).is_equal(OK)
	_pump()
	assert_array(failures).contains_exactly(["Server full"])
	assert_bool(full.is_online()).is_false()
	client.disconnect_session()
	_pump()
	assert_dict(server.player_for_id(id)).is_empty()
	assert_int(server.players().size()).is_equal(1)
	assert_int(client.get_child_count()).is_zero()


func test_dedicated_rejection_duplicate_and_reconnect() -> void:
	var server := _branch(1)
	var client := _branch(2)
	var returning := _branch(3)
	var failures: Array[String] = []
	var rejections: Array[String] = []
	returning.session_failed.connect(func(reason: String) -> void: failures.append(reason))
	server.peer_rejected.connect(func(_id: int, why: String) -> void: rejections.append(why))
	assert_int(server.start_server({"save_dir": "user://net/branch-dedicated"})).is_equal(OK)
	assert_str(server.local_player_id()).is_empty()
	assert_bool(server.is_dedicated()).is_true()
	assert_array(server.players()).is_empty()
	assert_int(client.join("memory", 1203)).is_equal(OK)
	_pump()
	var id := client.local_player_id()
	assert_str(id).is_not_empty()
	assert_int(returning.join("memory", 1203)).is_equal(OK)
	_pump()
	assert_int(returning.join("memory", 1204, {"content_version": "old"})).is_equal(OK)
	_pump()
	var expected := ["Identity already connected", "Content version mismatch"]
	assert_array(failures).contains_exactly(expected)
	assert_array(rejections).contains_exactly(failures)
	client.disconnect_session()
	_pump()
	server.disconnect_session()
	assert_int(server.start_server({"save_dir": "user://net/branch-dedicated"})).is_equal(OK)
	assert_int(returning.join("memory", 1203)).is_equal(OK)
	_pump()
	assert_str(returning.local_player_id()).is_equal(id)
	assert_int(server.player_for_id(id).get("peer_id", 0)).is_equal(3)


func test_two_clients_observe_the_same_join_and_leave() -> void:
	var server := _branch(1)
	var first := _branch(2)
	var second := _branch(3)
	assert_int(server.start_server({"save_dir": "user://net/branch-roster"})).is_equal(OK)
	assert_int(first.join("memory", 1205)).is_equal(OK)
	_pump()
	var joins: Array[String] = []
	var leaves: Array[String] = []
	first.player_joined.connect(func(id: String) -> void: joins.append(id))
	first.player_left.connect(func(id: String) -> void: leaves.append(id))
	assert_int(second.join("memory", 1206)).is_equal(OK)
	_pump()
	var second_id := second.local_player_id()
	assert_array(joins).contains_exactly([second_id])
	assert_array(first.players()).contains_exactly(server.players())
	assert_array(second.players()).contains_exactly(server.players())
	assert_int(first.players().size()).is_equal(2)
	second.disconnect_session()
	_pump()
	assert_array(leaves).contains_exactly([second_id])
	assert_dict(first.player_for_id(second_id)).is_empty()


func test_server_loss_clears_client_and_restores_offline_peer() -> void:
	var server := _branch(1)
	var client := _branch(2)
	var failures: Array[String] = []
	client.session_failed.connect(func(reason: String) -> void: failures.append(reason))
	var original := client.multiplayer.multiplayer_peer
	assert_int(server.start_server({"save_dir": "user://net/loss"})).is_equal(OK)
	assert_int(client.join("memory", 1210)).is_equal(OK)
	_pump()
	assert_str(client.local_player_id()).is_not_empty()
	server.disconnect_session()
	_pump()
	assert_array(failures).contains_exactly(["Server disconnected"])
	assert_int(client.mode()).is_equal(CogitoNet.Mode.OFFLINE)
	assert_bool(client.multiplayer.multiplayer_peer == original).is_true()
	assert_int(client.get_child_count()).is_zero()
	assert_array(client.players()).is_empty()


func test_roster_can_exceed_32_remote_players() -> void:
	var server := _branch(1)
	var config := {"max_players": 33, "save_dir": "user://net/large-roster"}
	assert_int(server.start_server(config)).is_equal(OK)
	for id in range(2, 35):
		var client := _branch(id)
		# Separate address scopes give each simulated process its own client identity.
		assert_int(client.join("memory", 1300 + id)).is_equal(OK)
	_pump()
	for branch: Facade in _branches:
		assert_int(branch.players().size()).is_equal(33)


func _level(branch: Facade, key: String = "arena") -> Node:
	var host := CogitoLevelHost.new()
	branch.add_child(host)
	var root := host.load_level("res://tests/player/movement_level.tscn", &"arena")
	branch.player_world.bind_level(root, Transform3D(Basis.IDENTITY, Vector3.UP), key)
	return root


func _ticks(count: int) -> void:
	for tick in count:
		await get_tree().physics_frame
		_pump()


func test_avatar_late_join_move_remove_and_reconnect(_timeout := 15000) -> void:
	var server := _branch(1)
	var first := _branch(2)
	var second := _branch(3)
	assert_int(server.start_server({"save_dir": "user://net/avatars"})).is_equal(OK)
	var world := _level(server)
	assert_int(first.join("memory", 1401)).is_equal(OK)
	_level(first)
	_pump()
	var id := first.local_player_id()
	var avatar := server.player_world.avatar_for(id)
	var old_name := avatar.actor.name
	assert_object(server.local_player()).is_null()
	assert_object(avatar.source).is_not_null()
	assert_bool(avatar.actor.is_local_presentation).is_false()
	assert_array(avatar.actor.find_children("*", "Camera3D", true, false)).is_empty()
	assert_object(avatar.actor.player_hud).is_null()
	var local_actor := first.local_player() as CogitoPlayerAdvanced
	assert_bool(local_actor.input_source is CogitoLocalInputSource).is_true()
	assert_object(CogitoSceneManager.get_player()).is_same(local_actor)
	var component := local_actor.player_interaction_component
	var event := InputEventAction.new()
	event.action = &"action_primary"
	event.pressed = true
	component.on_action_input(event)
	assert_bool(component.wieldables.primary_action_held).is_false()
	var calls: Array[bool] = []
	var act := func(_pic: PlayerInteractionComponent) -> void: calls.append(true)
	await component.perform_action(CogitoInteractionAction.new("Use", null, act))
	assert_array(calls).is_empty()
	await _ticks(10)
	var start := avatar.actor.position
	_network[2].drop_every_tenth_command = true
	local_actor.input_source = Walker.new()
	await _ticks(88)
	assert_float(start.z - avatar.actor.position.z).is_between(3.2, 4.6)
	assert_float(local_actor.position.distance_to(avatar.actor.position)).is_less(0.18)
	assert_int(first.player_world.avatar_for(id).timeline.latest().ack).is_greater(60)
	local_actor.head.rotation.x = 0.9
	server.player_world.avatar_for(id).actor.head.rotation.x = -0.1
	var past := first.player_world.avatar_for(id).timeline.latest().duplicate()
	past.tick += 1
	past.pitch = -0.1
	first.player_world.avatar_for(id).receive(past)
	first.player_world.avatar_for(id).present(0.1)
	assert_float(local_actor.head.rotation.x).is_equal_approx(0.9, 0.001)
	assert_int(second.join("memory", 1402)).is_equal(OK)
	_pump()
	assert_object(second.local_player()).is_null()
	_level(second)
	_pump()
	var remote := second.player_world.avatar_for(id).actor
	assert_object(remote.input_source).is_null()
	assert_bool(remote.is_physics_processing()).is_false()
	assert_float(remote.position.distance_to(avatar.actor.position)).is_less(0.05)
	assert_bool(second.local_player().name != old_name).is_true()
	first.disconnect_session()
	_pump()
	assert_object(server.player_world.avatar_for(id)).is_null()
	assert_object(second.player_world.avatar_for(id)).is_null()
	assert_bool(world.has_node(NodePath(old_name))).is_false()
	var again := _branch(4)
	assert_int(again.join("memory", 1401)).is_equal(OK)
	_level(again)
	_pump()
	var fresh := server.player_world.avatar_for(id)
	assert_str(again.local_player_id()).is_equal(id)
	assert_str(String(fresh.actor.name)).is_equal(String(old_name))
	assert_int(fresh.lifetime).is_greater(avatar.lifetime)
	assert_float(fresh.actor.position.z).is_zero()
	await _ticks(2)


func test_listen_local_role_spawn_policy_and_teleport() -> void:
	var server := _branch(1)
	var client := _branch(2)
	var changes: Array[bool] = []
	var observe := func(actor: CogitoPlayer) -> void: changes.append(actor != null)
	server.local_player_changed.connect(observe)
	server.spawn_policy = func(_root: Node, _id: String, origin: Transform3D) -> Transform3D:
		origin.origin.z = 7.0
		return origin
	assert_int(server.host({"save_dir": "user://net/listen-avatars"})).is_equal(OK)
	_level(server)
	var host := server.local_player() as CogitoPlayerAdvanced
	assert_bool(host.input_source is CogitoLocalInputSource).is_true()
	assert_float(host.position.z).is_equal(7.0)
	assert_int(client.join("memory", 1403)).is_equal(OK)
	_level(client)
	_pump()
	var remote := client.player_world.avatar_for(server.local_player_id()).actor
	assert_bool(remote.is_local_presentation).is_false()
	var local_actor := client.local_player() as CogitoPlayerAdvanced
	var authority := server.player_world.avatar_for(client.local_player_id()).actor
	await _ticks(8)
	authority.position.x += 1.0
	authority.head.rotation.x = -0.7
	server.player_world.mark_teleport(client.local_player_id())
	await _ticks(4)
	assert_float(absf(local_actor.position.x - authority.position.x)).is_less(0.01)
	assert_float(local_actor.head.rotation.x).is_equal_approx(-0.7, 0.001)
	server.disconnect_session()
	_pump()
	assert_array(changes).contains_exactly([true, false])


func test_wrong_level_receives_no_actors_and_silent_peer_stays_still() -> void:
	var server := _branch(1)
	var client := _branch(2)
	assert_int(server.start_server({"save_dir": "user://net/interest"})).is_equal(OK)
	_level(server)
	assert_int(client.join("memory", 1404)).is_equal(OK)
	_level(client, "other")
	_pump()
	var id := client.local_player_id()
	assert_str(id).is_not_empty()
	var actor := server.player_world.avatar_for(id).actor
	await _ticks(26)
	assert_float(Vector2(actor.position.x, actor.position.z).length()).is_zero()
	assert_int(actor.last_consumed_sequence).is_equal(-1)
	assert_object(client.local_player()).is_null()
	assert_object(client.player_world.avatar_for(id)).is_null()

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

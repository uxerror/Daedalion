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


func _arena(branch: Facade) -> Node3D:
	var host := CogitoLevelHost.new()
	branch.add_child(host)
	var level := host.load_level("res://tests/net/process_arena.tscn", &"arena") as Node3D
	var start := Transform3D(Basis.IDENTITY, Vector3(5.3, 0.1, -12.6))
	branch.player_world.bind_level(level, start, "arena")
	return level


func _observer(peer: int) -> Facade:
	var branch := _branch(peer)
	assert_int(branch.join("memory", 1800 + peer)).is_equal(OK)
	_arena(branch)
	_pump()
	return branch


func _use(branch: Facade, path: String, action := &"interact", payload: Variant = null) -> void:
	var component := branch.player_world.active_level().get_node(path) as InteractionComponent
	branch.player_world.interactions.submit(component, action, payload)
	_pump()

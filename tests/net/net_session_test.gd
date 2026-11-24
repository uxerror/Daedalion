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


func test_snapshot_tick_sends_one_batch_to_each_ready_peer() -> void:
	var server := _branch(1)
	assert_int(server.start_server({"save_dir": "user://net/batch"})).is_equal(OK)
	_level(server)
	for peer in [2, 3]:
		var client := _branch(peer)
		assert_int(client.join("memory", 1500 + peer)).is_equal(OK)
		_level(client)
		_pump()
	_network[1].pose_packets.clear()
	server.player_world._physics_process(1.0)
	_pump()
	assert_dict(_network[1].pose_packets).is_equal({2: 1, 3: 1})
	for client: Facade in _branches.slice(1):
		for record in server.players():
			var avatar := client.player_world.avatar_for(record.player_id)
			assert_int(avatar.timeline.latest().tick).is_equal(1)


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


func test_interaction_validation_and_private_results(_timeout := 15000) -> void:
	var server := _branch(1)
	assert_int(server.start_server({"save_dir": "user://net/validate"})).is_equal(OK)
	var level := _arena(server)
	var client := _observer(2)
	var api := client.player_world.interactions
	var client_root := client.player_world.active_level()
	var responses: Array[Dictionary] = []
	api.result_received.connect(func(result: Dictionary) -> void: responses.append(result))
	await _ticks(15)
	var door: CogitoDoor = level.get_node("Door")
	var actor := server.player_world.avatar_for(client.local_player_id()).actor
	var use: InteractionComponent = client_root.get_node("Door/Use")
	var start := actor.position
	var request := api.make_request(use, &"interact")
	request.epoch += 1
	api.dispatch(request)
	_pump()
	assert_array(responses).is_empty()
	request = api.make_request(use, &"interact")
	request.entity_id = "unknown"
	api.dispatch(request)
	_pump()
	assert_str(responses.back().reason).is_equal("Unknown entity or component")
	actor.position += Vector3.RIGHT * 20
	_use(client, "Door/Use")
	assert_str(responses.back().reason).is_equal("Out of reach")
	actor.position = start
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(5, 4, 0.1)
	shape.shape = box
	wall.add_child(shape)
	level.add_child(wall)
	wall.position = Vector3(5.5, 1.5, -13.3)
	await _ticks(3)
	_use(client, "Door/Use")
	assert_str(responses.back().reason).is_equal("Line of sight blocked")
	wall.free()
	await _ticks(2)
	door.get_node("Use").is_disabled = true
	_use(client, "Door/Use")
	assert_str(responses.back().reason).is_equal("Disabled action")
	door.get_node("Use").is_disabled = false
	door.is_locked = true
	door.key = KeyItemPD.new()
	door.key.discard_after_use = true
	_use(client, "Door/Use")
	assert_str(responses.back().reason).is_equal("Key required")
	assert_bool(door.is_open).is_false()
	assert_int(server.player_world.world.revisions["level:door"]).is_zero()
	for bad: Variant in ["", "1e10", "+123", "12345678901234567", {"result": true}]:
		_use(client, "Keypad/BasicInteraction", &"submit_code", bad)
		assert_str(responses.back().reason).is_equal("Invalid payload")
	_use(client, "Keypad/BasicInteraction", &"submit_code", "9999")
	assert_str(responses.back().reason).is_equal("Wrong code")
	assert_bool(level.get_node("Keypad").is_locked).is_true()
	assert_int(server.player_world.world.revisions["level:keypad"]).is_zero()
	var key := InventorySlotPD.new()
	key.inventory_item = door.key
	key.quantity = 1
	key.origin_index = 0
	actor.inventory_data.inventory_slots[0] = key
	var response_count := responses.size()
	_use(client, "Door/Use")
	assert_int(responses.size()).is_equal(response_count + 1)
	assert_bool(responses.back().ok).is_true()
	assert_bool(door.is_open).is_true()
	assert_bool(door.is_locked).is_false()
	assert_object(actor.inventory_data.inventory_slots[0]).is_null()
	assert_array(responses.back().hints).is_not_empty()


func test_concurrent_retry_replica_events_and_late_baseline(_timeout := 15000) -> void:
	var server := _branch(1)
	assert_int(server.start_server({"save_dir": "user://net/objects"})).is_equal(OK)
	var level := _arena(server)
	var first := _observer(2)
	var second := _observer(3)
	var replica := second.player_world.active_level()
	var replies: Array[Dictionary] = []
	var others: Array[Dictionary] = []
	var events: Array[String] = []
	var signals: Array[bool] = []
	first.player_world.interactions.result_received.connect(func(r: Dictionary): replies.append(r))
	second.player_world.interactions.result_received.connect(func(r: Dictionary): others.append(r))
	second.player_world.world.presented.connect(
		func(id: String, _rev: int, _event: StringName): events.append(id)
	)
	replica.get_node("Door").door_state_changed.connect(func(open: bool): signals.append(open))
	await _ticks(12)
	var a := first.player_world.interactions
	var b := second.player_world.interactions
	var request := a.make_request(
		first.player_world.active_level().get_node("Door/Use"), &"interact"
	)
	var stale := b.make_request(replica.get_node("Door/Use"), &"interact")
	a.dispatch(request)
	a.dispatch(request)
	b.dispatch(stale)
	_pump()
	assert_int(replies.size()).is_equal(2)
	assert_dict(replies[0]).is_equal(replies[1])
	assert_bool(replies[0].ok).is_true()
	assert_str(others[0].reason).is_equal("Stale revision")
	assert_array(events).contains_exactly(["level:door"])
	assert_array(signals).is_empty()
	assert_bool(replica.get_node("Door/Audio").playing).is_true()
	assert_bool(level.get_node("Door").is_open).is_true()
	assert_bool(replica.get_node("Door").is_open).is_true()
	_use(second, "Button/Use")
	_use(second, "Button/Use")
	assert_bool(others.back().ok).is_false()
	assert_int(server.player_world.world.revisions["level:button"]).is_equal(1)
	_use(first, "Switch/Use")
	_use(first, "Keypad/BasicInteraction", &"submit_code", "0420")
	await _ticks(5)
	assert_bool(level.get_node("LinkedDoor").is_open).is_true()
	assert_bool(level.get_node("KeyDoor").is_open).is_true()
	var late := _branch(4)
	assert_int(late.join("memory", 1804)).is_equal(OK)
	var quiet: Array[bool] = []
	late.player_world.world.presented.connect(
		func(_id: String, _rev: int, _event: StringName): quiet.append(true)
	)
	var baseline := _arena(late)
	_pump()
	assert_array(quiet).is_empty()
	assert_bool(baseline.get_node("Door/Audio").playing).is_false()
	assert_bool(baseline.get_node("Door").is_open).is_true()
	assert_vector(baseline.get_node("Door").position).is_equal(level.get_node("Door").open_position)
	assert_bool(baseline.get_node("Button").has_been_used).is_true()
	assert_bool(baseline.get_node("Switch").is_on).is_true()
	assert_bool(baseline.get_node("Keypad").is_locked).is_false()
	assert_bool(baseline.get_node("KeyDoor").is_locked).is_false()
	assert_dict(late.player_world.world.revisions).is_equal(server.player_world.world.revisions)


func test_hold_release_cancel_and_personal_interfaces(_timeout := 15000) -> void:
	var server := _branch(1)
	assert_int(server.host({"save_dir": "user://net/holds"})).is_equal(OK)
	var level := _arena(server)
	var client := _observer(2)
	var replica := client.player_world.active_level()
	var api := client.player_world.interactions
	await _ticks(12)
	var hold := replica.get_node("Door/Hold") as HoldInteraction
	api.perform(hold.get_actions(client.local_player().player_interaction_component)[0])
	_pump()
	api.cancel_hold()
	_pump()
	assert_bool(level.get_node("Door").is_open).is_false()
	api.perform(hold.get_actions(client.local_player().player_interaction_component)[0])
	_pump()
	api.release("interact2")
	_pump()
	assert_bool(level.get_node("Door").is_open).is_false()
	api.perform(hold.get_actions(client.local_player().player_interaction_component)[0])
	_pump()
	await get_tree().create_timer(0.36).timeout
	api.release("interact2")
	_pump()
	assert_bool(level.get_node("Door").is_open).is_true()
	_use(server, "Page/Read")
	assert_bool(level.get_node("Page/Read/ReadableUi").visible).is_true()
	assert_bool(replica.get_node("Page/Read/ReadableUi").visible).is_false()
	level.get_node("Page/Read").close(server.local_player().player_interaction_component)
	_use(server, "Keypad/BasicInteraction")
	assert_bool(level.get_node("Keypad/KeypadUi").visible).is_true()
	assert_bool(replica.get_node("Keypad/KeypadUi").visible).is_false()
	level.get_node("Keypad").close(server.local_player().player_interaction_component)

	var pic := client.local_player().player_interaction_component
	server.player_world.avatar_for(client.local_player_id()).actor.position = Vector3(
		4.7, 0.1, -12.6
	)
	await _ticks(3)
	pic.targeting.interactable = replica.get_node("Keypad")
	pic.start_interaction("interact")
	_pump()
	assert_bool(replica.get_node("Keypad/KeypadUi").visible).is_true()
	assert_bool(level.get_node("Keypad/KeypadUi").visible).is_false()
	replica.get_node("Keypad").entered_code = "0420"
	replica.get_node("Keypad").check_entered_code()
	_pump()
	assert_bool(replica.get_node("Keypad/KeypadUi").visible).is_false()
	assert_bool(level.get_node("KeyDoor").is_open).is_true()


func test_plate_counts_authority_bodies_and_ignores_replica_bodies() -> void:
	var server := _branch(1)
	assert_int(server.start_server({"save_dir": "user://net/plate"})).is_equal(OK)
	var level := _arena(server)
	var client := _observer(2)
	var replica := client.player_world.active_level()
	var plate: CogitoPressureplate = level.get_node("Plate")
	var copy: CogitoPressureplate = replica.get_node("Plate")
	var activations: Array[bool] = []
	copy.plate_activated.connect(func(): activations.append(true))
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, 0.2, 0.2)
	shape.shape = box
	body.add_child(shape)
	body.position = plate.position + Vector3.UP * 0.25
	var local_body := body.duplicate() as StaticBody3D
	replica.add_child(local_body)
	await _ticks(4)
	assert_bool(copy.is_activated).is_false()
	level.add_child(body)
	var weight := body.duplicate() as StaticBody3D
	level.add_child(weight)
	await _ticks(4)
	assert_bool(plate.is_activated).is_true()
	assert_bool(copy.is_activated).is_true()
	body.free()
	await _ticks(3)
	assert_bool(plate.is_activated).is_true()
	weight.free()
	await _ticks(4)
	assert_bool(copy.is_activated).is_false()
	assert_array(activations).is_empty()
	assert_int(server.player_world.world.revisions["level:plate"]).is_equal(2)
	# Authored server scripts can also unlock a panel without any local player.
	replica.get_node("Keypad").unlock_keypad()
	assert_bool(replica.get_node("Keypad").is_locked).is_true()
	level.get_node("Keypad").unlock_keypad()
	level.get_node("Keypad").unlock_keypad()
	_pump()
	assert_bool(replica.get_node("Keypad").is_locked).is_false()
	assert_bool(replica.get_node("KeyDoor").is_open).is_true()
	assert_int(server.player_world.world.revisions["level:keypad"]).is_equal(1)


func test_prompt_is_pure_and_only_authority_runs_auto_close() -> void:
	var server := _branch(1)
	assert_int(server.start_server({"save_dir": "user://net/preview"})).is_equal(OK)
	var level := _arena(server)
	var client := _observer(2)
	var replica := client.player_world.active_level()
	await _ticks(12)
	var door := level.get_node("Door") as CogitoDoor
	var copy := replica.get_node("Door") as CogitoDoor
	var profile := ConsumableEffect.new()
	profile.attribute_name = "health"
	profile.attribute_change_amount = -3.0
	for object: CogitoDoor in [door, copy]:
		var use := object.get_node("Use") as InteractionComponent
		use.attribute_check = InteractionComponent.AttributeCheck.HIDE_INTERACTION
		use.attribute_to_check = "health"
		use.min_value_to_pass = 1.0
		use.attribute_effects = [profile]
		object.auto_close_time = 0.15
	var pic := client.local_player().player_interaction_component
	var local_health := pic.get_attribute("health")
	var initial := local_health.value_current
	var hints := []
	pic.hint_prompt.connect(func(_icon: Texture2D, text: String): hints.append(text))
	pic.targeting.interactable = copy
	pic.targeting.rebuild_interaction_prompts()
	assert_array(hints).is_empty()
	assert_float(local_health.value_current).is_equal(initial)
	var actor := server.player_world.avatar_for(client.local_player_id()).actor
	var health := actor.player_interaction_component.get_attribute("health")
	var balance := health.value_current
	pic.start_interaction("interact")
	_pump()
	assert_bool(copy.is_open).is_true()
	assert_float(health.value_current).is_equal(balance - 3.0)
	assert_float(local_health.value_current).is_equal(initial)
	assert_object(door.close_timer).is_not_null()
	assert_object(copy.close_timer).is_null()
	await _ticks(17)
	assert_bool(copy.is_open).is_false()
	assert_int(client.player_world.world.revisions["level:door"]).is_equal(2)

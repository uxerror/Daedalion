extends "memory_session_suite.gd"

const A := "res://tests/net/travel_a.tscn"
const B := "res://tests/net/travel_b.tscn"
const SharedQuest := preload(
	"res://addons/cogito/QuestSystem/Quests/DemoSceneQuests/Demo_TargetPractice.tres"
)
const Dart := preload("res://addons/cogito/InventoryPD/Items/Cogito_Dart_Poison.tres")
const Spawner := preload("res://addons/cogito/Networking/net_spawner.gd")
const NetConfig := preload("res://addons/cogito/Networking/net_config.gd")
const PersonalQuest := preload("personal_quest.tres")

var _previous: Node
var _root: Node3D
var _server: Facade
var _now := 0
var _dir: String


class PartyPolicy:
	extends CogitoTravelPolicy
	var approved := false

	func participants(actor: CogitoPlayerAdvanced, _zone: Area3D) -> Array[CogitoPlayerAdvanced]:
		var members: Array[CogitoPlayerAdvanced] = []
		if approved:
			for member in CogitoLevel.nodes_in_group(actor, &"Player"):
				if member is CogitoPlayerAdvanced and not member.is_dead:
					members.append(member)
		return members


class PinWest:
	extends CogitoTravelPolicy

	func should_unload(key: String) -> bool:
		return key != A


func before_test() -> void:
	_now = 0
	_dir = create_temp_dir("mp10-%d" % Time.get_ticks_usec())
	_previous = get_tree().current_scene
	_root = Node3D.new()
	get_tree().root.add_child(_root)
	get_tree().current_scene = _root
	_server = _branch(1, _root)


func after_test() -> void:
	if _server.player_world and _server.player_world.persistence:
		var writer := _server.player_world.persistence
		assert_bool(writer.reap(_server.player_world, Time.get_ticks_msec() + 3000)).is_true()
	super.after_test()
	get_tree().current_scene = _previous
	_root.free()
	await get_tree().process_frame
	await get_tree().process_frame


func _boot(listen := false, options := {}) -> void:
	var cfg := {
		"save_dir": _dir,
		"autosave_seconds": 1,
		"level_grace_seconds": 3,
		"respawn_delay": 0,
	}
	cfg.merge(options, true)
	var err := _server.host(cfg) if listen else _server.start_server(cfg)
	assert_int(err).is_equal(OK)
	_server.player_world.persistence.clock = func() -> int: return _now
	assert_int(_server.player_world.travel.start(A)).is_equal(OK)


func _join(peer: int, port: int) -> Facade:
	var client := _branch(peer)
	assert_int(client.join("mp10", port, {"display_name": "Peer%d" % peer})).is_equal(OK)
	_pump()
	return client


func _room(client: Facade) -> Node:
	return _server.player_world.travel.endpoint_for(client.local_player_id())


func _arrive(client: Facade, key: String) -> bool:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		await _ticks(1)
		var endpoint := _room(client)
		var actor := client.local_player()
		if endpoint and actor and endpoint.world.entities.level_key == key:
			if endpoint.world.ready_for_events(client.multiplayer.get_unique_id()):
				return true
	return false


func _enter(client: Facade, offset := 0.0) -> void:
	var endpoint := _room(client)
	var actor: CogitoPlayer = endpoint.avatar_for(client.local_player_id()).actor
	actor.position = endpoint.active_level().get_node("Doorway").position + Vector3.FORWARD * offset
	actor.velocity = Vector3.ZERO
	endpoint.mark_teleport(client.local_player_id())


func test_resting_corpse_baseline_after_travel_and_reconnect() -> void:
	_boot()
	var client := _join(2, 2890)
	var stayed := _join(3, 2891)
	assert_bool(await _arrive(client, A)).is_true()
	assert_bool(await _arrive(stayed, A)).is_true()
	var west := _room(client)
	var guard := west.active_level().get_node("Guard") as CogitoNPC
	var actor: CogitoPlayer = west.avatar_for(client.local_player_id()).actor
	guard.damage_received.emit(200.0, actor, Vector3.FORWARD, guard.position)
	await _ticks(20)
	var corpse := west.world.entities.live_object("runtime:1") as NetNpcCorpse
	assert_object(corpse).is_not_null()
	# Save a recognizable mid-fall pose asleep, as for a world restored on restart.
	corpse.restore_frame(
		corpse.frame_root(), NetNpcCorpse.Codec.encode(corpse.bones, corpse.frame_root())
	)
	await _ticks(6)
	_enter(client)
	assert_bool(await _arrive(client, B)).is_true()
	_enter(client)
	assert_bool(await _arrive(client, A)).is_true()
	await _ticks(8)
	_check_rest_pose(client, corpse)
	var identity := client.local_player_id()
	client.disconnect_session()
	_pump()
	var returned := _join(4, 2890)
	assert_bool(await _arrive(returned, A)).is_true()
	assert_str(returned.local_player_id()).is_equal(identity)
	await _ticks(8)
	_check_rest_pose(returned, corpse)


func _check_rest_pose(client: Facade, corpse: NetNpcCorpse) -> void:
	var observer: Node = client.player_world.travel.levels[A]
	var copy := observer.world.entities.live_object("runtime:1") as NetNpcCorpse
	assert_bool(observer.bodies._timelines["runtime:1"].resting).is_true()
	for i in corpse.bones.size():
		var source := corpse.bones[i].global_transform
		var target := copy.bones[i].global_transform
		assert_float(target.origin.distance_to(source.origin)).is_less(0.02)
		var angle := target.basis.get_rotation_quaternion().angle_to(
			source.basis.get_rotation_quaternion()
		)
		assert_float(angle).is_less(deg_to_rad(3))


func test_concurrent_entries_grace_restore_and_old_packets() -> void:
	_boot()
	var a := _join(2, 2811)
	var b := _join(3, 2812)
	assert_bool(await _arrive(a, A)).is_true()
	assert_bool(await _arrive(b, A)).is_true()
	var source := _room(a)
	var travel := _server.player_world.travel
	var epoch: int = source.world.entities.epoch
	var old_life: int = source.avatar_for(b.local_player_id()).lifetime
	var previous_view = b.player_world.travel.levels[A].avatar_for(b.local_player_id())
	var old_block: NetOwnerState = previous_view.latest_owner_baseline()
	var server_root: Node3D = source.active_level()
	var guard: CogitoNPC = server_root.get_node("Guard")
	guard.health.value_current = 7.0
	server_root.get_node("Heat").enabled = true
	var crate: Node3D = server_root.get_node("Crate")
	crate.position = Vector3(-6, 1, -6)
	var pickup: Node3D = server_root.get_node("Pickup")
	var component: PickupComponent = pickup.find_children("*", "PickupComponent", true, false)[0]
	var stack := component.slot_data
	var item := stack.inventory_item.name
	var owner_actor: CogitoPlayer = source.avatar_for(a.local_player_id()).actor
	var pic := owner_actor.player_interaction_component
	assert_bool(source.spawner.collect(component, pic, false).ok).is_true()
	var runtime: Node3D = source.spawner.spawn_item(stack, 1, Vector3(1, 1, -4))
	var runtime_id: String = source.world.entities.id_for(runtime)
	_enter(a, 1)
	_enter(b, -1)
	assert_bool(await _arrive(a, B)).is_true()
	assert_bool(await _arrive(b, B)).is_true()
	var dest := _room(a)
	var client_dest: Node = b.player_world.travel.levels[B]
	var new_view = client_dest.avatar_for(b.local_player_id())
	var arrived: NetOwnerState = new_view.latest_owner_baseline()
	assert_object(previous_view.latest_owner_baseline()).is_null()
	assert_int(arrived.generation).is_greater(old_block.generation)
	assert_int(arrived.binding).is_not_equal(old_block.binding)
	var stale: Dictionary = new_view.timeline.latest().duplicate()
	stale.owner_state = NetOwnerState.encode(old_block)
	client_dest._receive_pose(b.local_player_id(), arrived.life, stale)
	assert_object(new_view.latest_owner_baseline()).is_same(arrived)
	var actor: CogitoPlayer = dest.avatar_for(a.local_player_id()).actor
	var other: CogitoPlayer = dest.avatar_for(b.local_player_id()).actor
	assert_float(actor.position.distance_to(other.position)).is_greater(1.25)
	assert_bool(dest.peer_in_level(2) and dest.peer_in_level(3)).is_true()
	_now = 2900
	_enter(a)
	assert_bool(await _arrive(a, A)).is_true()
	assert_object(_room(a).active_level()).is_same(server_root)
	assert_int(source.world.entities.epoch).is_equal(epoch)
	_enter(a)
	assert_bool(await _arrive(a, B)).is_true()
	_now += 3100
	var deadline := Time.get_ticks_msec() + 5000
	while travel.levels.has(A) and Time.get_ticks_msec() < deadline:
		await _ticks(1)
	assert_bool(travel.levels.has(A)).is_false()
	var saved_scene: Dictionary = source.persistence.files.scenes[A].duplicate()
	saved_scene.erase("holdings")
	assert_int(Spawner.saved_holdings(saved_scene).get(item, 0)).is_equal(1)
	_enter(b)
	assert_bool(await _arrive(b, A)).is_true()
	var restored := _room(b)
	assert_int(restored.world.entities.epoch).is_greater(epoch)
	assert_float(restored.active_level().get_node("Guard").health.value_current).is_equal(7.0)
	assert_bool(restored.active_level().get_node("Heat").enabled).is_true()
	assert_float(restored.active_level().get_node("Crate").position.x).is_equal_approx(-6, 0.1)
	assert_bool(restored.world.is_removed("level:Pickup")).is_true()
	assert_object(restored.world.entities.live_object(runtime_id)).is_not_null()
	# Eviction paused ballistics on the endpoint. A reloaded room must fly projectiles again.
	assert_bool(restored.projectiles.is_physics_processing()).is_true()
	assert_bool(restored.projectiles.can_process()).is_true()
	var drops := 0
	for id: String in restored.world.entities.objects:
		if id.begins_with("runtime:"):
			drops += 1
	assert_int(drops).is_equal(1)
	var current: CogitoPlayer = _room(a).avatar_for(a.local_player_id()).actor
	assert_int(current.inventory_data.find_slots(item).size()).is_equal(1)
	var replica: Node = b.player_world.travel.levels[A]
	var saved_id := b.local_player_id()
	var life: int = replica.avatar_for(saved_id).lifetime
	replica._spawn(A, -1, saved_id, life + 1, {})
	assert_int(replica.avatar_for(saved_id).lifetime).is_equal(life)
	var binding: Variant = restored.avatar_for(saved_id)
	var packets: int = binding.source._packets
	var cmd := CogitoPlayerCommand.new()
	cmd.sequence = 100
	var data: PackedByteArray = replica.command_channel.packet(cmd)
	replica._commands.rpc_id(1, old_life, binding.revision, data)
	_pump()
	assert_int(binding.source._packets).is_equal(packets)
	b.player_world.travel._loaded.rpc_id(1, 1, A, epoch, 1)
	_pump()
	assert_object(_room(b)).is_same(restored)


func test_listen_quorum_veto_seat_carry_and_private_respawn() -> void:
	_boot(true)
	var b := _join(2, 2822)
	assert_bool(await _arrive(b, A)).is_true()
	var source := _room(b)
	var gate: Area3D = source.active_level().get_node("Doorway")
	var rules := PartyPolicy.new()
	_server.travel_policy = rules
	var holder := _server.local_player() as CogitoPlayerAdvanced
	var rider: CogitoPlayerAdvanced = source.avatar_for(b.local_player_id()).actor
	var grip: CogitoCarryableComponent = source.active_level().get_node("Crate/CarryableComponent")
	var cart: CogitoVehicle = source.active_level().get_node("Cart")
	assert_bool(source.seats.use(cart, rider.player_interaction_component).ok).is_true()
	_enter(_server, -1)
	await _ticks(4)
	assert_object(_room(_server)).is_same(source)
	assert_dict(source.travel.pending).is_empty()
	assert_bool(source.carry.grab(grip, holder.player_interaction_component).ok).is_true()
	assert_bool(grip.is_being_carried).is_true()
	assert_bool(rider.is_sitting).is_true()
	rules.approved = true
	source.travel.enter(gate, holder)
	assert_bool(await _arrive(_server, B)).is_true()
	assert_bool(await _arrive(b, B)).is_true()
	var target := _room(b)
	assert_bool(grip.is_being_carried).is_false()
	assert_str(cart.occupant_id).is_empty()
	rider = target.avatar_for(b.local_player_id()).actor
	assert_object(rider.current_seat).is_same(target.active_level().get_node("Cart"))
	var carrying := _server.local_player().player_interaction_component.carrying
	assert_object(carrying.carried_object).is_null()
	target.seats.release(rider)
	rider.decrease_attribute("health", 1000)
	_pump()
	assert_bool(b.local_player().is_dead).is_true()
	assert_bool(_server.local_player().is_dead).is_false()
	b.player_world.travel.levels[B].death.request_respawn()
	_pump()
	assert_bool(rider.is_dead).is_false()
	assert_object(CogitoLevel.root_of(rider)).is_same(target.active_level())


# A guard hunting the listen host must not keep the freed host actor after it travels.
func test_npc_target_released_when_host_travels() -> void:
	_boot(true)
	var b := _join(2, 2826)
	assert_bool(await _arrive(b, A)).is_true()
	var source := _room(_server)
	var host := _server.local_player() as CogitoPlayerAdvanced
	var guard: CogitoNPC = source.active_level().get_node("Guard")
	guard.attention_target = host
	_enter(_server)
	assert_bool(await _arrive(_server, B)).is_true()
	await _ticks(2)
	assert_bool(guard.attention_target == host).is_false()
	(
		assert_bool(is_instance_valid(guard.attention_target) or guard.attention_target == null)
		. is_true()
	)
	var data: Dictionary = guard.save()
	assert_bool(String(data.attention_target_id).begins_with("player:")).is_false()
	assert_int(_server.save_world()).is_equal(OK)


func test_failed_preparation_and_checkpoint_keep_source_and_release_guard() -> void:
	_boot()
	var a := _join(2, 2832)
	assert_bool(await _arrive(a, A)).is_true()
	var source := _room(a)
	var actor := a.local_player()
	var gate: Area3D = source.active_level().get_node("Doorway")
	var failures: Array[String] = []
	_server.travel_failed.connect(func(_id: String, message: String): failures.append(message))
	gate.target_scene_path = "res://tests/net/no-room.tscn"
	_enter(a, -1)
	await _ticks(10)
	assert_int(failures.size()).is_equal(1)
	gate.target_scene_path = B
	var writer: Facade.Persistence = source.persistence
	writer.files.storage.fail_before = func(op: String): return op == "publish staging"
	source.travel.enter(gate, source.avatar_for(a.local_player_id()).actor)
	var deadline := Time.get_ticks_msec() + 5000
	while failures.size() < 2 and Time.get_ticks_msec() < deadline:
		await _ticks(1)
	assert_int(failures.size()).is_equal(2)
	assert_object(a.local_player()).is_same(actor)
	assert_dict(source.travel.pending).is_empty()
	writer.files.storage.fail_before = Callable()
	writer.request_save()
	_now = 2000
	source.travel.enter(gate, source.avatar_for(a.local_player_id()).actor)
	assert_bool(await _arrive(a, B)).is_true()
	assert_bool(writer.files.profiles.has(a.local_player_id())).is_true()


func test_slow_ack_timeout_and_disconnect_reconnect_at_source(
	expire: bool, _test_parameters := [[false], [true]]
) -> void:
	_boot()
	var a := _join(2, 2842)
	var b := _join(3, 2843)
	assert_bool(await _arrive(a, A)).is_true()
	assert_bool(await _arrive(b, A)).is_true()
	var id := a.local_player_id()
	var source := _room(a)
	var stayed := b.local_player()
	_enter(a, -1)
	a.player_world.travel.process_mode = Node.PROCESS_MODE_DISABLED
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		if source.travel.pending.get(id, {}).get("stage") == "ready":
			break
		await _ticks(1)
	assert_str(source.travel.pending.get(id, {}).get("stage", "")).is_equal("ready")
	var token: int = source.travel.pending[id].token
	a.player_world.travel._loaded.rpc_id(1, token, B, -1, 1)
	_pump()
	assert_str(source.travel.pending[id].stage).is_equal("ready")
	assert_object(_room(a)).is_same(source)
	if expire:
		_now += 31000
		source.travel.advance()
	else:
		a.disconnect_session()
	_pump()
	assert_dict(source.travel.pending).is_empty()
	assert_object(b.local_player()).is_same(stayed)
	var hints: Array[String] = []
	b.travel_notification.connect(func(event: Dictionary): hints.append(event.text))
	var returned := _join(4, 2842)
	assert_bool(await _arrive(returned, A)).is_true()
	await _ticks(12)
	assert_object(_room(returned)).is_same(source)
	assert_str(returned.local_player_id()).is_equal(id)
	assert_array(hints).is_empty()


func test_live_notifications_shared_and_private_quest_interest() -> void:
	_boot()
	var a := _join(2, 2852)
	var b := _join(3, 2853)
	assert_bool(await _arrive(a, A)).is_true()
	assert_bool(await _arrive(b, A)).is_true()
	var hud: Array[String] = []
	var left := func(event: Dictionary):
		hud.append(event.text)
		event.text = ""
	b.travel_notification.connect(left)
	_enter(a)
	assert_bool(await _arrive(a, B)).is_true()
	var shared_events: Array[StringName] = []
	var own_events: Array[StringName] = []
	a.player_world.quests.notified.connect(
		func(event: StringName, _quest: CogitoQuest): own_events.append(event)
	)
	b.player_world.quests.notified.connect(
		func(event: StringName, _quest: CogitoQuest): shared_events.append(event)
	)
	var session := _room(a)
	var id := a.local_player_id()
	var additions: Array[WorldFlag] = []
	session.quests.advance(SharedQuest, CogitoQuestUpdater.UpdateType.Start, additions, id)
	session.quests.advance(PersonalQuest, CogitoQuestUpdater.UpdateType.Start, additions, id)
	_pump()
	assert_array(own_events).contains_exactly([&"start", &"start"])
	assert_array(shared_events).contains_exactly([&"start"])
	var context: CogitoQuestContext = session.quests.evaluation_context(SharedQuest.scope, id)
	assert_int(context.party.size()).is_equal(2)
	var late := _join(4, 2854)
	var late_hints: Array[String] = []
	late.travel_notification.connect(func(event: Dictionary): late_hints.append(event.text))
	assert_bool(await _arrive(late, A)).is_true()
	assert_array(late_hints).is_empty()
	assert_array(hud).contains_exactly(["Peer2 left for East"])
	_enter(a)
	assert_bool(await _arrive(a, A)).is_true()
	assert_array(hud).contains_exactly(["Peer2 left for East", "Peer2 arrived from East"])
	assert_array(late_hints).contains_exactly(["Peer2 arrived from East"])


func test_eviction_failure_keeps_empty_room_until_retry() -> void:
	_boot()
	var a := _join(2, 2862)
	assert_bool(await _arrive(a, A)).is_true()
	var source := _room(a)
	var writer: Facade.Persistence = source.persistence
	_enter(a)
	assert_bool(await _arrive(a, B)).is_true()
	writer.files.storage.fail_before = func(op: String) -> bool: return op == "write profile"
	_now = 4000
	var deadline := Time.get_ticks_msec() + 4000
	while writer.last_error == OK and Time.get_ticks_msec() < deadline:
		await _ticks(1)
	assert_int(writer.last_error).is_not_equal(OK)
	assert_object(source.travel.levels[A]).is_same(source)
	writer.files.storage.fail_before = Callable()
	_enter(a)
	assert_bool(await _arrive(a, A)).is_true()
	assert_object(_room(a)).is_same(source)


func test_empty_boot_eviction_cli_and_first_join() -> void:
	var args := PackedStringArray(["--level-grace-seconds", "0", "--travel-timeout-seconds", "2"])
	var config := NetConfig.parse_cli(args)
	assert_int(config.level_grace_seconds).is_zero()
	assert_int(config.travel_timeout_seconds).is_equal(2)
	assert_bool(NetConfig.parse_cli(["--travel-timeout-seconds", "0"]).has("reason")).is_true()
	_boot()
	var travel := _server.player_world.travel
	_now = 4000
	var deadline := Time.get_ticks_msec() + 5000
	while travel.levels.has(A) and Time.get_ticks_msec() < deadline:
		await _ticks(1)
	assert_bool(travel.levels.has(A)).is_false()
	var a := _join(2, 2882)
	assert_bool(await _arrive(a, A)).is_true()


func test_unmatched_seat_preserves_offline_posture_and_host_view() -> void:
	_boot(true)
	var b := _join(2, 2872)
	assert_bool(await _arrive(b, A)).is_true()
	var source := _room(b)
	var actor := _server.local_player() as CogitoPlayerAdvanced
	var ambience := AudioStreamPlayer.new()
	source.active_level().add_child(ambience)
	assert_str(ambience.bus).is_equal("Master")
	var cart: CogitoVehicle = source.active_level().get_node("Cart")
	cart.set_meta(CogitoPersistentId.META_KEY, "level:SourceOnly")
	assert_bool(source.seats.use(cart, actor.player_interaction_component).ok).is_true()
	assert_bool(await _arrive(_server, B)).is_true()
	var target := _room(_server)
	actor = _server.local_player()
	assert_bool(actor.is_sitting).is_true()
	assert_object(actor.current_seat).is_null()
	assert_str(cart.occupant_id).is_empty()
	var hidden: SubViewport = source.active_level().get_viewport()
	var visible: SubViewport = target.active_level().get_viewport()
	assert_int(hidden.render_target_update_mode).is_equal(SubViewport.UPDATE_DISABLED)
	assert_bool(hidden.audio_listener_enable_3d).is_false()
	assert_bool(AudioServer.is_bus_mute(AudioServer.get_bus_index(ambience.bus))).is_true()
	assert_int(visible.render_target_update_mode).is_equal(SubViewport.UPDATE_ALWAYS)
	assert_bool(visible.audio_listener_enable_3d).is_true()
	assert_object(_room(b)).is_same(source)


func test_split_rooms_send_gameplay_packets_only_to_the_local_observer() -> void:
	_boot()
	var a := _join(2, 2892)
	var b := _join(3, 2893)
	assert_bool(await _arrive(a, A)).is_true()
	assert_bool(await _arrive(b, A)).is_true()
	_enter(a)
	assert_bool(await _arrive(a, B)).is_true()
	var room := _room(a)
	var root: Node3D = room.active_level()
	var id := a.local_player_id()
	var life: int = room.avatar_for(id).lifetime
	var actor: CogitoPlayerAdvanced = room.avatar_for(id).actor
	var weapon: Variant = room.wield_profile(Dart.resource_path)
	var stack := InventorySlotPD.new()
	stack.inventory_item = Dart
	var bus: MemoryPeer = _network[1]
	var peers: Array[int] = room.observers()
	assert_array(peers).contains_exactly([2])
	bus.capture = true
	room.bodies.forget(2)
	room.npcs.forget(2)
	room.bodies.advance(0.1, {2: actor.global_position}, peers)
	room.elements.forget(2)
	root.get_node("Heat").enabled = true
	room.elements.advance(0.1, {2: actor.global_position}, peers)
	var guard: CogitoNPC = root.get_node("Guard")
	room.combat.npc_event(guard, &"hit", guard.global_position)
	assert_bool(room.projectiles.launch(id, life, stack, weapon, actor.global_transform)).is_true()
	var pic := actor.player_interaction_component
	var grip: CogitoCarryableComponent = root.get_node("Crate/CarryableComponent")
	assert_bool(room.carry.grab(grip, pic).ok).is_true()
	assert_bool(room.seats.use(root.get_node("Cart"), pic).ok).is_true()
	room.inventory.baseline(2)
	room.death.die(actor)
	bus.capture = false
	assert_int(bus.sent.size()).is_greater(6)
	for peer in bus.destinations:
		assert_int(peer).is_equal(2)
	_pump()
	assert_bool(a.local_player().is_dead).is_true()
	assert_bool(b.local_player().is_dead).is_false()
	assert_bool(_room(b).active_level().get_node("Heat").enabled).is_false()


func test_connector_inside_return_zone_requires_leaving_and_entering_again() -> void:
	_boot()
	var a := _join(2, 2902)
	var b := _join(3, 2903)
	assert_bool(await _arrive(a, A)).is_true()
	assert_bool(await _arrive(b, A)).is_true()
	_enter(a)
	assert_bool(await _arrive(a, B)).is_true()
	var target := _room(a)
	var root: Node3D = target.active_level()
	var gate: Area3D = root.get_node("Doorway")
	root.get_node("Entry").position = gate.position + Vector3.FORWARD
	_enter(b)
	assert_bool(await _arrive(b, B)).is_true()
	await _ticks(12)
	var actor: CogitoPlayerAdvanced = target.avatar_for(b.local_player_id()).actor
	assert_bool(gate.overlaps_body(actor)).is_true()
	assert_dict(target.travel.pending).is_empty()
	actor.position = Vector3(6, 1, 0)
	await _ticks(4)
	_enter(b)
	assert_bool(await _arrive(b, A)).is_true()


func test_residency_config_and_invalid_preload() -> void:
	assert_str(NetConfig.parse_cli([]).level_residency).is_equal("stream")
	var cli := NetConfig.parse_cli(["--level-residency", "keep_visited"])
	assert_str(cli.level_residency).is_equal("keep_visited")
	assert_bool(NetConfig.parse_cli(["--level-residency", "all"]).has("reason")).is_true()
	var bad := NetConfig.server_config({"preload_levels": [123]}, false)
	assert_bool(bad.has("reason")).is_true()
	var config := {
		"save_dir": _dir,
		"level": A,
		"level_residency": "preload_all",
		"preload_levels": ["res://missing-preload.tscn"],
	}
	var reasons: Array[String] = []
	_server.session_failed.connect(func(reason: String): reasons.append(reason))
	assert_int(_server.start_server(config)).is_not_equal(OK)
	assert_bool(_server.is_online()).is_false()
	assert_str(reasons[0]).contains("missing-preload.tscn")
	var directory := _dir.path_join("worlds/default")
	assert_bool(DirAccess.dir_exists_absolute(directory.path_join("current"))).is_false()


func test_preload_completes_before_ready(
	listen: bool, seeds: Array, _test_parameters := [[false, [B, B]], [true, ["auto"]]]
) -> void:
	var ready_rooms: Array[int] = []
	var at_ready := func(): ready_rooms.append(_server.player_world.travel.levels.size())
	_server.session_ready.connect(at_ready)
	_boot(listen, {"level": A, "level_residency": "preload_all", "preload_levels": seeds})
	assert_array(ready_rooms).contains_exactly([2])
	var room: Node = _server.player_world.travel.levels[B]
	assert_str(room.active_level().scene_file_path).is_equal(B)
	assert_int(_server.player_world.travel.host.levels().size()).is_equal(2)


func test_empty_resident_freezes_and_resumes(
	mode: String, _test_parameters := [["keep_visited"], ["stream"]]
) -> void:
	if mode == "stream":
		_server.travel_policy = PinWest.new()
	_boot(false, {"level_residency": mode})
	var travel: Node = _server.player_world.travel
	var root: Node3D = travel.host.level(A)
	var body: RigidBody3D = root.get_node("Crate")
	var guard: CogitoNPC = root.get_node("Guard")
	var timer := Timer.new()
	timer.process_mode = Node.PROCESS_MODE_ALWAYS
	guard.add_child(timer)
	timer.one_shot = true
	timer.start(2)
	var props: CogitoProperties = body.get_node("CogitoProperties")
	var pulses: Array[int] = []
	props.damage_timer.one_shot = true
	props.damage_timer.timeout.connect(func(): pulses.append(1))
	props.damage_timer.start(0.7)
	var links: Array[int] = []
	CogitoLevel.delay(root, 0.7).connect(func(): links.append(1))
	body.position.y = 100
	body.sleeping = false
	await _ticks(4)
	_now = 2999
	travel.advance()
	assert_bool(travel.residency.frozen(A)).is_false()
	_now = 3000
	travel.advance()
	assert_bool(travel.residency.frozen(A)).is_true()
	var pose := body.global_transform
	var rid := body.get_rid()
	var transform_state := PhysicsServer3D.BODY_STATE_TRANSFORM
	var server_pose: Transform3D = PhysicsServer3D.body_get_state(rid, transform_state)
	var npc_pose := guard.global_transform
	var remaining := timer.time_left
	var burn_left := props.damage_timer.time_left
	_now += 300000
	await _ticks(60)
	var held_pose: Transform3D = PhysicsServer3D.body_get_state(rid, transform_state)
	assert_that(held_pose).is_equal(server_pose)
	assert_that(body.global_transform).is_equal(pose)
	assert_that(guard.global_transform).is_equal(npc_pose)
	assert_float(timer.time_left).is_equal(remaining)
	assert_float(props.damage_timer.time_left).is_equal(burn_left)
	assert_array(links).is_empty()
	assert_array(pulses).is_empty()
	assert_bool(guard.can_process()).is_false()
	var epoch: int = travel.levels[A].world.entities.epoch
	var client := _join(2, 2982)
	assert_bool(await _arrive(client, A)).is_true()
	assert_object(travel.host.level(A)).is_same(root)
	assert_int(travel.levels[A].world.entities.epoch).is_equal(epoch)
	assert_bool(travel.residency.frozen(A)).is_false()
	await _ticks(6)
	assert_float(body.position.y).is_less(pose.origin.y)
	assert_float(timer.time_left).is_between(0.0, remaining)
	assert_bool(timer.is_stopped()).is_false()
	var deadline := Time.get_ticks_msec() + 2000
	while (pulses.is_empty() or links.is_empty()) and Time.get_ticks_msec() < deadline:
		await _ticks(1)
	assert_array(pulses).contains_exactly([1])
	assert_array(links).contains_exactly([1])


func test_frozen_rows_copied_until_dirty_and_rebuilt_once() -> void:
	var options := {"level": A, "level_residency": "preload_all", "preload_levels": ["auto", B]}
	_boot(false, options)
	var travel: Node = _server.player_world.travel
	var east: Node = travel.levels[B]
	var root: Node = east.active_level()
	var component: PickupComponent = root.find_children("*", "PickupComponent", true, false)[0]
	var drop: Node3D = east.spawner.spawn_item(component.slot_data, 1, Vector3.UP * 3)
	var id: String = east.world.entities.id_for(drop)
	_now = Time.get_ticks_msec() + 4000
	travel.advance()
	assert_bool(travel.residency.frozen(B)).is_true()
	assert_int(_server.save_world()).is_equal(OK)
	var writer: Facade.Persistence = east.persistence
	var saved: Dictionary = writer.files.scenes[B]
	assert_int(_server.save_world()).is_equal(OK)
	assert_bool(is_same(saved, writer.files.scenes[B])).is_true()
	var guard: CogitoNPC = east.active_level().get_node("Guard")
	guard.health.value_current = 9
	east.mark_world_dirty()
	writer.files.storage.fail_before = func(op: String) -> bool: return op == "write world_scene"
	assert_int(_server.save_world()).is_not_equal(OK)
	writer.files.storage.fail_before = Callable()
	assert_int(_server.save_world()).is_equal(OK)
	assert_bool(is_same(saved, writer.files.scenes[B])).is_false()
	assert_int(_server.disconnect_session()).is_equal(OK)
	await get_tree().process_frame
	_boot(false, options)
	east = _server.player_world.travel.levels[B]
	var restored: CogitoNPC = east.active_level().get_node("Guard")
	assert_float(restored.health.value_current).is_equal(9.0)
	assert_object(east.world.entities.live_object(id)).is_not_null()
	var ids: Array = east.world.entities.objects.keys().filter(
		func(key: String) -> bool: return key.begins_with("runtime:")
	)
	assert_array(ids).contains_exactly([id])


func test_lab_loot_deadline_and_ballistic_step_survive_frozen_restart(_timeout := 60000) -> void:
	var path := "res://addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn"
	var fridge_path := "NavigationRegion3D/BASE_FLOOR/kitchenFridgeContainer2"
	var options := {"level": A, "level_residency": "preload_all", "preload_levels": [path]}
	_boot(false, options)
	await _ticks(3)
	var room: Node = _server.player_world.travel.levels[path]
	var fridge: LootableContainer = room.active_level().get_node(fridge_path)
	fridge.timer.start(12.5)
	var npc: CogitoNPC = room.active_level().get_node("CogitoNPC")
	assert_bool(room.projectiles.launch_npc(npc, Vector3.UP * 30, Vector3.RIGHT)).is_true()
	_now = Time.get_ticks_msec() + 4000
	room.travel.advance()
	var flights: Array = room.projectiles.capture()
	var left := fridge.timer.time_left
	await _ticks(45)
	assert_array(room.projectiles.capture()).contains_exactly(flights)
	assert_float(fridge.timer.time_left).is_equal(left)
	assert_int(_server.disconnect_session()).is_equal(OK)
	await get_tree().process_frame
	_boot(false, options)
	room = _server.player_world.travel.levels[path]
	fridge = room.active_level().get_node(fridge_path)
	assert_float(fridge.timer.time_left).is_equal_approx(left, 0.001)
	assert_array(room.projectiles.capture()).contains_exactly(flights)
	await _ticks(3)
	var moved: Array = room.projectiles.capture()
	assert_int(moved.size()).is_equal(1)
	assert_float(moved[0].row.pos.x).is_greater(flights[0].row.pos.x)
	assert_float(fridge.timer.time_left).is_less(left)
	assert_int(_server.disconnect_session()).is_equal(OK)

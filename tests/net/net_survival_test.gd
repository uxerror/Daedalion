extends "memory_session_suite.gd"

const Attributes := preload("res://addons/cogito/Networking/net_attributes.gd")
const Arena := preload("process_arena.tscn")

var _server: Facade
var _owner: Facade
var _other: Facade
var _level_root: Node3D
var _previous: Node
var _id: String
var _victim: CogitoPlayerAdvanced
var _shooter: CogitoPlayerAdvanced
var _policy := CountingPolicy.new()


class TaggedPolicy:
	extends CogitoRespawnPolicy

	func select(
		_id_arg: String, _level_arg: Node, candidates: Array[CogitoRespawnPoint]
	) -> Transform3D:
		for point in candidates:
			if point.tag == &"clinic":
				return point.transform
		return Transform3D.IDENTITY

	func restore_attributes(actor: CogitoPlayer) -> void:
		super.restore_attributes(actor)
		actor.player_attributes.health.value_current = 42.0


class CountingPolicy:
	extends CogitoRespawnPolicy
	var deaths: Array[String] = []
	var automatic := false

	func on_death(id: String) -> void:
		deaths.append(id)

	func auto_respawn(_id: String) -> bool:
		return automatic


func before_test() -> void:
	_previous = get_tree().current_scene
	_level_root = Arena.instantiate()
	get_tree().root.add_child(_level_root)
	get_tree().current_scene = _level_root
	_server = _branch(1)
	_policy = CountingPolicy.new()
	_server.respawn_policy = _policy
	_server.start_server({"save_dir": "user://net/survival", "respawn_delay": 0.0})
	_server.player_world.bind_level(_level_root, Transform3D(Basis.IDENTITY, Vector3.UP), "arena")
	_owner = _observer(2)
	_other = _observer(3)
	_id = _owner.local_player_id()
	_victim = _server.player_world.avatar_for(_id).actor
	_shooter = _server.player_world.avatar_for(_other.local_player_id()).actor
	await _ticks(4)


func after_test() -> void:
	super.after_test()
	get_tree().current_scene = _previous
	_level_root.free()


func test_private_meters_public_fraction_and_silent_replica() -> void:
	var server := _server.player_world
	var replica := _owner.local_player()
	var observed := _other.player_world.avatar_for(_id)
	assert_that(Attributes.capture(replica)).is_equal(Attributes.capture(_victim))
	var transport: MemoryPeer = _network[1]
	transport.capture = true
	_victim.player_attributes.strength.set_attribute(7, 11)
	_victim.player_attributes.health.value_current = 40
	# Non-urgent meters are paced by wall time (NetAttributes.INTERVAL_MSEC); after a heavy suite
	# the engine catches up with bursts of physics frames, so a fixed tick count can be too short.
	var deadline := Time.get_ticks_msec() + 3 * Attributes.INTERVAL_MSEC
	await _ticks(12)
	while Time.get_ticks_msec() < deadline:
		await _ticks(1)
	assert_float(replica.player_attributes.strength.value_current).is_equal(7.0)
	assert_float(replica.player_attributes.strength.value_max).is_equal(11.0)
	assert_float(observed.health_fraction).is_equal(0.4)
	var private_packets := 0
	for i in transport.sent.size():
		if transport.sent[i].hex_encode().contains("strength".to_ascii_buffer().hex_encode()):
			private_packets += 1
			assert_int(transport.destinations[i]).is_equal(2)
	assert_int(private_packets).is_greater(0)
	var deaths: Array[int] = []
	replica.player_attributes.health.death.connect(func(): deaths.append(1))
	replica.player_attributes.health.apply_replica_value(0, 100)
	var stamina: CogitoStaminaAttribute = replica.stamina_attribute
	stamina.apply_replica_value(5, 60)
	stamina.is_regenerating = true
	await _ticks(10)
	assert_float(stamina.value_current).is_equal(5.0)
	var hud := replica.player_hud as CogitoPlayerHudManager
	assert_float(hud.fixed_stamina_bar.attribute_bar.value_current).is_equal(5.0)
	assert_float(hud.fixed_stamina_bar.attribute_bar.max_value).is_equal(60.0)
	assert_array(deaths).is_empty()
	assert_bool(replica.is_dead).is_false()
	assert_bool(server.avatar_for(_id).actor.is_dead).is_false()


func test_per_attribute_rate_and_urgent_health() -> void:
	var stream := Attributes.new()
	stream.changes(_victim, 10)
	_victim.stamina_attribute.subtract(3)
	_victim.player_attributes.health.subtract(3)
	assert_array(stream.changes(_victim, 11).keys()).contains_exactly(["health"])
	assert_bool(stream.changes(_victim, 109).is_empty()).is_true()
	assert_array(stream.changes(_victim, 110).keys()).contains_exactly(["stamina"])


func test_zones_overlap_and_per_player_oxygen() -> void:
	var hazard := _level_root.get_node("Hazard")
	var zone := _level_root.get_node("AttributeZone")
	for actor: CogitoPlayer in [_victim, _shooter]:
		hazard._on_body_entered(actor)
		zone._on_body_entered(actor)
	hazard._process(1)
	zone._process(0.1)
	assert_float(_victim.player_attributes.health.value_current).is_equal(77.0)
	assert_float(_shooter.player_attributes.health.value_current).is_equal(77.0)
	zone._on_body_exited(_victim)
	hazard._process(1)
	zone._process(1)
	assert_float(_victim.player_attributes.health.value_current).is_equal(75.0)
	assert_float(_shooter.player_attributes.health.value_current).is_equal(74.0)
	_victim.position = Vector3(10, 1, 0)
	await _ticks(12)
	assert_bool(_victim.is_head_in_water()).is_true()
	assert_float(_victim.player_attributes.oxygen.value_current).is_less(
		_shooter.player_attributes.oxygen.value_current
	)


func test_damage_policy_and_single_death() -> void:
	var players := _server.player_world
	players.get_parent().config.friendly_fire = false
	assert_bool(_victim.decrease_attribute("health", 2, _shooter)).is_false()
	var body := _level_root.get_node("CarryBox")
	body.set_meta(&"net_damage_owner", _other.local_player_id())
	assert_bool(_victim.decrease_attribute("health", 2, body)).is_false()
	assert_bool(_victim.decrease_attribute("health", 2, _victim)).is_true()
	assert_bool(_victim.decrease_attribute("health", 2)).is_true()
	players.death.damage_policy = func(_attacker: String, who: String, _source: Node):
		return who == _id
	players.combat.hit(_victim, 99, _shooter, Vector3.ZERO, Vector3.ZERO)
	_pump()
	_victim._on_death()
	assert_array(_policy.deaths).contains_exactly([_id])
	assert_bool(_victim.decrease_attribute("strength", 2)).is_false()
	assert_bool(_owner.local_player().is_dead).is_true()
	assert_bool(_other.player_world.avatar_for(_id).actor.is_dead).is_true()
	assert_bool(_other.local_player().is_dead).is_false()
	assert_bool(_owner.local_player().player_hud.get_node("DeathScreen").visible).is_true()
	assert_bool(_other.local_player().player_hud.get_node("DeathScreen").visible).is_false()
	assert_bool(get_tree().paused).is_false()
	assert_int(Input.mouse_mode).is_equal(Input.MOUSE_MODE_VISIBLE)


func test_sender_bound_respawn_deadline_and_stale_life() -> void:
	var players := _server.player_world
	var death := players.death
	InputRouter.push(_owner.local_player().on_input)
	players.get_parent().config.respawn_delay = 0.35
	var life: int = players.avatar_for(_id).lifetime
	_victim.decrease_attribute("health", 100, _shooter)
	_pump()
	var screen := _owner.local_player().player_hud.get_node("DeathScreen") as CogitoDeathScreen
	assert_bool(screen.load_button.disabled).is_true()
	var rejected: Array[String] = []
	var forged: Array[String] = []
	_other.player_world.death.respawn_rejected.connect(func(why: String): forged.append(why))
	_owner.player_world.death.respawn_rejected.connect(func(why: String): rejected.append(why))
	_owner.player_world.death.request_respawn()
	_other.player_world.death._request.rpc_id(1, life)
	_pump()
	assert_array(rejected).contains_exactly(["Respawn delay"])
	assert_array(forged).contains_exactly(["Stale life"])
	assert_bool(_victim.is_dead).is_true()
	var first := _level_root.get_node("Respawn1") as CogitoRespawnPoint
	_shooter.global_position = first.global_position
	var second := _level_root.get_node("Respawn2") as CogitoRespawnPoint
	var stop := Time.get_ticks_msec() + 1000
	while screen.load_button.disabled and Time.get_ticks_msec() < stop:
		await get_tree().process_frame
	assert_bool(screen.load_button.disabled).is_false()
	screen.load_button.pressed.emit()
	_pump()
	assert_bool(_victim.is_dead).is_false()
	assert_vector(_victim.position).is_equal(second.position)
	assert_bool(screen.visible).is_false()
	assert_bool(InputRouter.is_input_active(_owner.local_player())).is_true()
	if DisplayServer.get_name() != "headless":
		assert_int(Input.mouse_mode).is_equal(Input.MOUSE_MODE_CAPTURED)
	var remote := _owner.player_world.avatar_for(_id)
	assert_int(remote.lifetime).is_greater(life)
	assert_vector(remote.actor.position).is_equal(second.position)
	for key: String in ["health", "oxygen", "stamina", "sanity"]:
		assert_float(remote.actor.player_attributes[key].value_current).is_equal(
			_victim.player_attributes[key].value_max
		)
	var stale := remote.timeline.latest().duplicate()
	stale.tick += 100
	stale.position = Vector3.ZERO
	_owner.player_world._receive_pose(_id, life, stale)
	assert_vector(remote.actor.position).is_equal(second.position)
	assert_str(death.try_respawn(_id, life)).is_equal("Stale life")
	assert_str(death.try_respawn(_id, remote.lifetime)).is_equal("Player is alive")


func test_dead_reconnect_preserves_deadline_and_automatic_policy() -> void:
	var players := _server.player_world
	var stack := InventorySlotPD.new()
	stack.inventory_item = preload("res://addons/cogito/InventoryPD/Items/Cogito_LaserRifle.tres")
	var Grid := preload("res://addons/cogito/Networking/net_grid.gd")
	Grid.insert(_victim.inventory_data, stack, 1, false)
	var equipped := _victim.inventory_data.find_slots("Laser Rifle")[0]
	players.avatar_for(_id).wield.equip(equipped)
	var carryable: CogitoCarryableComponent = _level_root.get_node("CarryBox/CarryableComponent")
	carryable.attribute_check = InteractionComponent.AttributeCheck.NONE
	var releases: Array[bool] = []
	carryable.carry_state_changed.connect(func(held: bool): releases.append(held))
	players.carry.grab(carryable, _victim.player_interaction_component)
	assert_object(players.avatar_for(_id).wield.stack).is_null()
	_victim.saved_quest_progression = {"clinic": 2}
	players.get_parent().config.respawn_delay = 2.0
	_victim.decrease_attribute("health", 100)
	_pump()
	var deadline: float = players.death._deadlines[_id]
	_owner.disconnect_session()
	_pump()
	var again := _branch(4)
	again.join("memory", 1802)
	_arena(again)
	_pump()
	assert_str(again.local_player_id()).is_equal(_id)
	assert_bool(again.local_player().is_dead).is_true()
	assert_float(players.death._deadlines[_id]).is_equal(deadline)
	assert_array(_policy.deaths).contains_exactly([_id])
	assert_array(releases).contains_exactly([true, false])
	_policy.automatic = true
	players.death._deadlines[_id] = Time.get_ticks_msec()
	await _ticks(3)
	assert_bool(again.local_player().is_dead).is_false()
	assert_object(players.avatar_for(_id).wield.stack).is_same(equipped)
	assert_int(players.avatar_for(_id).actor.saved_quest_progression.clinic).is_equal(2)
	assert_array(_policy.deaths).contains_exactly([_id])


func test_immediate_respawn_disabled_points_and_fallback() -> void:
	var players := _server.player_world
	var point := _level_root.get_node("Respawn1") as CogitoRespawnPoint
	var second := _level_root.get_node("Respawn2") as CogitoRespawnPoint
	for pass_index in 3:
		point.enabled = pass_index == 0
		second.enabled = pass_index < 2
		var expected := players.join_transform(_id).origin
		if second.enabled:
			expected = point.position if point.enabled else second.position
		_victim.decrease_attribute("health", 100)
		_pump()
		_owner.player_world.death.request_respawn()
		_pump()
		assert_bool(_victim.is_dead).is_false()
		assert_vector(_victim.position).is_equal(expected)


func test_vehicle_release_and_command_rejection_once() -> void:
	var players := _server.player_world
	_level_root.stage_physics(players, "vehicle", _id)
	await _ticks(8)
	_use(_owner, "Vehicle/BasicInteraction")
	var vehicle := _level_root.get_node("Vehicle") as CogitoVehicle
	assert_bool(vehicle.is_occupied).is_true()
	var exits: Array[int] = []
	vehicle.player_stand_up.connect(func(): exits.append(1))
	_victim.decrease_attribute("health", 999)
	_pump()
	var position := _victim.position
	var results: Array[String] = []
	_owner.player_world.interactions.result_received.connect(
		func(reply: Dictionary): results.append(reply.reason)
	)
	_use(_owner, "Vehicle/BasicInteraction")
	var avatar := players.avatar_for(_id)
	var attack := _victim.neutral_command(_victim.last_consumed_sequence + 1)
	attack.move = Vector2.UP
	attack.add_edge(CogitoPlayerCommand.Action.PRIMARY)
	var movement_rejections: Array[String] = []
	_owner.player_world.death.gameplay_rejected.connect(
		func(why: String): movement_rejections.append(why)
	)
	var packet := _owner.player_world.command_channel.packet(attack)
	_owner.player_world._commands.rpc_id(1, avatar.lifetime, avatar.revision, packet)
	await _ticks(8)
	assert_vector(_victim.position).is_equal(position)
	assert_str(vehicle.occupant_id).is_empty()
	assert_array(exits).contains_exactly([1])
	assert_array(results).contains_exactly(["Player is dead"])
	assert_array(movement_rejections).contains_exactly(["Player is dead"])
	assert_object(avatar.source.sample(_victim, 0)).is_null()


func test_impact_damage_and_light_zones_use_server_occupant() -> void:
	var box := _level_root.get_node("CarryBox") as CogitoObject
	box.rigid_body = box.find_rigid_body()
	box.damage_dealt_when_airborne = 3.0
	box.damage_scales_with_mass = false
	box.damage_scales_with_velocity = false
	box.physics_frame_velocity_scalar = 4.0
	box.set_meta(&"net_damage_owner", _other.local_player_id())
	var config: Dictionary = _server.player_world.get_parent().config
	config.friendly_fire = false
	box._on_body_entered(_victim)
	assert_float(_victim.player_attributes.health.value_current).is_equal(80.0)
	config.friendly_fire = true
	box._on_body_entered(_victim)
	assert_float(_victim.player_attributes.health.value_current).is_equal(77.0)
	var zone := preload("res://addons/cogito/Components/LightzoneComponent.gd").new()
	_level_root.add_child(zone)
	zone._on_body_entered(_victim)
	zone._on_body_entered(_shooter)
	zone._on_body_exited(_shooter)
	assert_float(_victim.visibility_attribute.value_current).is_equal(1.0)
	assert_float(_victim.player_attributes.lightmeter.value_current).is_equal(20.0)
	var deadline := Time.get_ticks_msec() + 1000
	while _owner.local_player().player_attributes.lightmeter.value_current == 0:
		if Time.get_ticks_msec() >= deadline:
			break
		await _ticks(1)
	assert_float(_owner.local_player().player_attributes.lightmeter.value_current).is_equal(20.0)
	assert_float(_other.local_player().player_attributes.lightmeter.value_current).is_zero()


func test_game_policy_selects_tag_and_restores_custom_health() -> void:
	var chosen := _level_root.get_node("Respawn2") as CogitoRespawnPoint
	chosen.tag = &"clinic"
	_server.player_world.death.policy = TaggedPolicy.new()
	var presentation: Node = _owner.player_world.death
	presentation.screen_scene = preload("res://addons/cogito/PackedScenes/death_screen.tscn")
	_victim.decrease_attribute("health", 100.0)
	_pump()
	var screen: Control = presentation._screen
	assert_bool(screen.visible).is_true()
	assert_bool(_owner.local_player().player_hud.get_node("DeathScreen").visible).is_false()
	presentation.present(_owner.local_player(), true, 0)
	assert_object(presentation._screen).is_same(screen)
	_owner.player_world.death.request_respawn()
	_pump()
	assert_bool(screen.is_queued_for_deletion()).is_true()
	assert_float(_owner.local_player().player_attributes.health.value_current).is_equal(42.0)
	assert_vector(_owner.local_player().position).is_equal(chosen.position)

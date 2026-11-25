extends "memory_session_suite.gd"

const GRID := preload("res://addons/cogito/Networking/net_grid.gd")
const ACTION := CogitoPlayerCommand.Action

var _server: Facade
var _owner: Facade
var _other: Facade
var _actor: CogitoPlayerAdvanced
var _sequence := 1000


func _open() -> void:
	_server = _branch(1)
	_server.start_server({"save_dir": "user://net/wield"})
	_arena(_server)
	_owner = _observer(2)
	_other = _observer(3)
	_actor = _server.player_world.avatar_for(_owner.local_player_id()).actor
	_actor.position = Vector3(-24, 0.1, -3)
	_actor.inventory_data.inventory_slots.fill(null)


func _grant(asset: String, count := 1) -> InventorySlotPD:
	var origin := InventorySlotPD.new()
	origin.inventory_item = load("res://addons/cogito/InventoryPD/Items/Cogito_%s.tres" % asset)
	assert_int(GRID.insert(_actor.inventory_data, origin, count, false)).is_equal(count)
	_server.player_world.inventory.flush_actor(_actor)
	_pump()
	return _actor.inventory_data.find_slots(origin.inventory_item.name)[0]


func _equip(slot: InventorySlotPD, wrong := false) -> void:
	_server.player_world.inventory.flush_actor(_actor)
	_pump()
	var api := _owner.player_world.inventory
	var replica := api.local.data.inventory_slots[slot.origin_index]
	var id := api.local.id_of(replica)
	var request := api.make_request("use", [slot.origin_index, id + int(wrong)])
	api.dispatch(request)
	api.dispatch(request)
	_pump()


func _tick(edge: int, delta := 1.0 / 60, held := 0, stale := false) -> void:
	var wield := _server.player_world.avatar_for(_owner.local_player_id()).wield
	var command := CogitoPlayerCommand.new()
	_sequence += 1
	command.sequence = _sequence
	command.wield_generation = wield.generation - int(stale)
	command.held = held
	if edge >= 0:
		command.add_edge(edge)
	_actor.current_command = command
	wield.tick(delta)
	_pump()


func test_hitscan_rate_empty_private_ammo_and_reload(_timeout := 20000) -> void:
	_open()
	var rifle := _grant("LaserRifle")
	var ammo := _grant("LaserAmmo", 2)
	var item := rifle.inventory_item as WieldableItemPD
	item.charge_current = 3
	_server.player_world.inventory.flush_actor(_actor)
	_pump()
	_equip(rifle, true)
	var wield := _server.player_world.avatar_for(_owner.local_player_id()).wield
	assert_object(wield.stack).is_null()
	_tick(ACTION.PRIMARY)
	assert_float(item.charge_current).is_equal(3.0)
	_equip(rifle)
	assert_object(wield.stack).is_same(rifle)
	var observer := _other.player_world.avatar_for(_owner.local_player_id())
	assert_str(observer.wield.public_item.get_file()).is_equal("Cogito_LaserRifle.tres")
	assert_array(observer.actor.inventory_data.find_slots(item.name)).is_empty()
	var own := _owner.player_world.inventory.local
	var private_item := own.equipped_stack().inventory_item as WieldableItemPD
	assert_object(private_item).is_not_same(item)
	var hits: Array[Node3D] = []
	var target := _server.player_world.active_level().get_node("West")
	target.get_node("Hitbox").got_hit.connect(func(who: Node3D): hits.append(who))
	await _ticks(3)
	_tick(ACTION.PRIMARY, 0.01, 0, true)
	assert_array(hits).is_empty()
	_tick(-1, 0.01, 1 << ACTION.SECONDARY)
	assert_bool(observer.wield.aiming).is_true()
	_tick(ACTION.PRIMARY, 0.01, 0, true)
	assert_bool(observer.wield.aiming).is_true()
	var hp: float = _actor.player_attributes.health.value_current
	for i in 10:
		_tick(ACTION.PRIMARY, 0.01)
	assert_int(hits.size()).is_equal(1)
	assert_float(private_item.charge_current).is_equal(2.0)
	for i in 50:
		_tick(-1, 0.02, 1 << ACTION.PRIMARY)
	assert_array(hits).contains_exactly([_actor, _actor, _actor])
	assert_float(target.get_node("Health").value_current).is_equal(97.0)
	assert_float(_actor.player_attributes.health.value_current).is_equal(hp)
	assert_float(private_item.charge_current).is_zero()
	_tick(ACTION.RELOAD)
	assert_bool(own.snapshot.reloading).is_true()
	_tick(-1, wield.profile.reload_seconds * 0.5)
	assert_int(ammo.quantity).is_equal(2)
	assert_float(private_item.charge_current).is_zero()
	_equip(rifle)
	_tick(-1, 5)
	assert_bool(own.snapshot.reloading).is_false()
	assert_int(ammo.quantity).is_equal(2)
	_equip(rifle)
	_tick(ACTION.RELOAD)
	_tick(-1, wield.profile.reload_seconds + 0.01)
	assert_int(ammo.quantity).is_zero()
	assert_float(private_item.charge_current).is_equal(100.0)


func test_melee_guards_light_and_consumable_are_actor_relative(_timeout := 20000) -> void:
	_open()
	var axe := _grant("Pickaxe")
	var light := _grant("Flashlight")
	var drink := _grant("HealthExtension")
	_equip(axe)
	await _ticks(3)
	var target := _server.player_world.active_level().get_node("West/Health")
	_actor.network_input_blocked = true
	_tick(ACTION.PRIMARY)
	_actor.network_input_blocked = false
	_actor.is_sitting = true
	_tick(ACTION.PRIMARY)
	_actor.is_sitting = false
	_actor.is_showing_ui = true
	_tick(ACTION.PRIMARY)
	_actor.is_showing_ui = false
	_actor.is_dead = true
	_tick(ACTION.PRIMARY)
	_actor.is_dead = false
	_actor.player_interaction_component.carrying.carried_object = target.get_parent()
	_tick(ACTION.PRIMARY)
	_actor.player_interaction_component.carrying.carried_object = null
	assert_float(target.value_current).is_equal(100.0)
	_tick(ACTION.PRIMARY)
	assert_float(target.value_current).is_equal(97.0)
	_equip(light)
	_tick(ACTION.PRIMARY, 5.0)
	var observer := _other.player_world.avatar_for(_owner.local_player_id())
	assert_bool(observer.wield.light_on).is_true()
	_tick(-1, 1)
	assert_float(light.inventory_item.charge_current).is_equal(96.0)
	var other := _server.player_world.avatar_for(_other.local_player_id()).actor
	var previous_max: float = _actor.player_attributes.health.value_max
	var untouched: float = other.player_attributes.health.value_max
	_actor.player_attributes.health.value_current = 20.0
	_equip(drink)
	_tick(ACTION.PRIMARY, 5.0)
	assert_float(_actor.player_attributes.health.value_max).is_equal(previous_max + 50)
	assert_float(_owner.local_player().player_attributes.health.value_max).is_equal(
		previous_max + 50
	)
	assert_float(other.player_attributes.health.value_max).is_equal(untouched)
	assert_float(_owner.local_player().player_attributes.health.value_current).is_equal(70.0)
	assert_int(drink.quantity).is_zero()


func test_projectiles_are_cosmetic_on_replica_and_pickups_are_unique(_timeout := 20000) -> void:
	_open()
	var darts := _grant("Dart", 2)
	var pistol := _grant("Pistol")
	var ids: Array[int] = []
	var impacts: Array[int] = []
	var shots := _other.player_world.projectiles
	shots.launched.connect(
		func(id: int, visual: Node3D):
			ids.append(id)
			assert_bool(visual is CollisionObject3D).is_false()
			assert_array(visual.find_children("*", "CollisionObject3D", true, false)).is_empty()
	)
	shots.ended.connect(
		func(id: int, hit: bool):
			if hit:
				impacts.append(id)
	)
	var level := _server.player_world.active_level()
	var hits: Array[Node3D] = []
	level.get_node("West/Hitbox").got_hit.connect(func(who: Node3D): hits.append(who))
	_equip(darts)
	await _ticks(3)
	for i in 2:
		_tick(ACTION.PRIMARY, 5.0)
		if i == 0:
			var late := _observer(4)
			assert_int(late.player_world.projectiles._flights.size()).is_equal(1)
		await _ticks(12)
		assert_int(hits.size()).is_equal(i + 1)
		var object := _server.player_world.world.entities.live_object("runtime:%d" % (i + 1))
		assert_object(object).is_not_null()
		if object:
			var pickup := object.get_node("PickupComponent")
			var pic := _actor.player_interaction_component
			assert_bool(_server.player_world.spawner.collect(pickup, pic, false).ok).is_true()
			assert_bool(_server.player_world.spawner.collect(pickup, pic, false).ok).is_false()
	assert_array(impacts).contains_exactly(ids)
	assert_int(ids.size()).is_equal(2)
	assert_int(ids[0]).is_not_equal(ids[1])
	_equip(pistol)
	_tick(ACTION.PRIMARY, 5.0)
	await _ticks(12)
	assert_array(hits).contains_exactly([_actor, _actor, _actor])
	assert_int(ids.size()).is_equal(3)
	assert_float(pistol.inventory_item.charge_current).is_equal(9.0)


func test_pistol_ammo_quickslot_and_predicted_rejection(_timeout := 15000) -> void:
	_open()
	var pistol := _grant("Pistol")
	var stones := _grant("StoneBullets", 3)
	var own := _owner.player_world.inventory.local
	var local_item := (
		own.data.inventory_slots[pistol.origin_index].inventory_item as WieldableItemPD
	)
	var actor := _owner.local_player() as CogitoPlayerAdvanced
	var submenu := local_item.get_quickslot_set(actor.player_interaction_component)
	assert_bool(submenu.activate(1, actor)).is_true()
	_pump()
	assert_int(local_item.current_ammo_type).is_equal(1)
	assert_float(local_item.charge_current).is_zero()
	assert_bool(own.snapshot.reloading).is_true()
	_tick(-1, 5.0)
	assert_float(local_item.charge_current).is_equal(3.0)
	assert_int(stones.quantity).is_zero()
	assert_int(own.data.find_slots(local_item.ammo_types[0].name)[0].quantity).is_equal(10)
	# The owner predicts before finding out that the server has blocked this actor.
	var remote := _owner.player_world.avatar_for(_owner.local_player_id()).wield
	var cmd := CogitoPlayerCommand.new()
	cmd.sequence = _sequence + 1
	cmd.add_edge(ACTION.PRIMARY)
	remote.predict(cmd, 1.0)
	assert_int(remote._pending_sequence).is_equal(cmd.sequence)
	assert_float(local_item.charge_current).is_equal(3.0)
	_actor.network_input_blocked = true
	_tick(ACTION.PRIMARY)
	var authority := _server.player_world.avatar_for(_owner.local_player_id()).wield
	remote.reconcile(_sequence, authority.accepted_sequence)
	assert_int(remote._pending_sequence).is_equal(-1)
	assert_bool(remote._view.animation.is_playing()).is_false()
	assert_float(pistol.inventory_item.charge_current).is_equal(3.0)


func test_rifle_activates_mp2_button_with_shooter_on_authority(_timeout := 15000) -> void:
	_open()
	var level := _server.player_world.active_level()
	var button := level.get_node("Button") as CogitoButton
	# The shipped generic_button scene wires this exact signal to its MP2 adapter.
	button.damage_received.connect(button._on_damage_received)
	var rifle := _grant("LaserRifle")
	_equip(rifle)
	await _ticks(3)
	var aim := _actor.get_aim_transform()
	button.global_position = aim.origin - aim.basis.z * 1.5
	await _ticks(2)
	_tick(ACTION.PRIMARY)
	assert_bool(button.has_been_used).is_true()
	var observed := _other.player_world.active_level().get_node("Button") as CogitoButton
	assert_bool(observed.has_been_used).is_true()
	assert_float(rifle.inventory_item.charge_current).is_equal(99.0)


func test_poison_dart_applies_element_only_to_authoritative_target(_timeout := 15000) -> void:
	_open()
	var level := _server.player_world.active_level()
	var target := level.get_node("West") as CogitoStaticInteractable
	target.cogito_properties.material_properties = 0
	var replica := _other.player_world.active_level().get_node("West") as CogitoStaticInteractable
	_equip(_grant("Dart_Poison"))
	await _ticks(2)
	_tick(ACTION.PRIMARY)
	await _ticks(9)
	assert_float(target.get_node("Health").value_current).is_equal(100.0)
	assert_bool(target.cogito_properties.is_poisoned).is_true()
	assert_bool(replica.cogito_properties.is_poisoned).is_false()
	assert_float(replica.get_node("Health").value_current).is_equal(100.0)


func test_owner_viewmodel_stays_visible_when_firing_after_equip(_timeout := 15000) -> void:
	_open()
	var slot := _grant("LaserRifle")
	_equip(slot)
	var view: Variant = _owner.player_world.avatar_for(_owner.local_player_id()).wield._view
	var mesh: Node3D = view.model.get_node("LaserRifleMesh")
	for frame in 120:
		if not view.animation.is_playing():
			break
		await get_tree().process_frame
	assert_bool(view.animation.is_playing()).is_false()
	assert_bool(mesh.visible).is_true()
	var profile: Variant = _owner.player_world.avatar_for(_owner.local_player_id()).wield.profile
	view.play(profile.fire_clip)
	await get_tree().process_frame
	assert_bool(mesh.visible).is_true()
	view.cancel()
	assert_bool(mesh.visible).is_true()

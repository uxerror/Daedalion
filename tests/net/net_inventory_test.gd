extends "memory_session_suite.gd"


func _stack(asset: String, quantity: int) -> InventorySlotPD:
	var stack := InventorySlotPD.new()
	stack.inventory_item = load("res://addons/cogito/InventoryPD/Items/Cogito_%s.tres" % asset)
	stack.quantity = quantity
	return stack


func _retry(client: Facade, op: String, args: Array) -> void:
	var api := client.player_world.inventory
	var request := api.make_request(op, args)
	api.dispatch(request)
	api.dispatch(request)
	_pump()


func test_private_inventory_transactions_and_reconnect(_timeout := 15000) -> void:
	var server := _branch(1)
	server.start_server({"save_dir": "user://net/private-inventory"})
	_arena(server)
	var observer := _observer(3)
	var transport: MemoryPeer = _network[1]
	transport.capture = true
	var starters := CogitoGlobals.cogito_settings.new_game_starter_items.duplicate()
	CogitoGlobals.cogito_settings.new_game_starter_items.assign([_stack("HealthPotion", 3)])
	var client := _observer(2)
	CogitoGlobals.cogito_settings.new_game_starter_items.assign(starters)
	var api := client.player_world.inventory
	var model := api.local
	var id := client.local_player_id()
	var actor := server.player_world.avatar_for(id).actor
	var other := server.player_world.avatar_for(observer.local_player_id()).actor
	var original := model.id_of(model.data.inventory_slots[0])
	assert_int(original).is_greater(0)
	_retry(client, "bind", [0, original, 0])
	_retry(client, "move", [0, original, 1, 1, 0])
	assert_int(model.data.inventory_slots[0].quantity).is_equal(2)
	var split := model.id_of(model.data.inventory_slots[1])
	assert_int(split).is_not_equal(original)
	_retry(client, "move", [1, split, 0, 1, 0])
	assert_int(model.data.inventory_slots[0].quantity).is_equal(3)
	_retry(client, "unbind", [0])
	assert_object(model.data.assigned_quickslots[0]).is_null()
	_retry(client, "move", [0, original, 2, 3, 0])
	assert_int(model.id_of(model.data.inventory_slots[2])).is_equal(original)
	var other_hp: float = other.player_attributes.health.value_current
	actor.player_attributes.health.value_current = 20
	_retry(client, "use", [2, original])
	assert_float(actor.player_attributes.health.value_current).is_equal(30.0)
	assert_float(client.local_player().player_attributes.health.value_current).is_equal(30.0)
	assert_float(other.player_attributes.health.value_current).is_equal(other_hp)
	assert_int(model.data.inventory_slots[2].quantity).is_equal(2)
	var stale := api.make_request("use", [2, original])
	stale.revision -= 1
	model.data.inventory_slots[2].quantity = 77
	api.dispatch(stale)
	_pump()
	assert_int(model.data.inventory_slots[2].quantity).is_equal(2)
	for invalid: Array in [[99, original], [-1, original], [2, original + 200], [2, "1"]]:
		_retry(client, "use", invalid)
	for amount: int in [0, -1, 3]:
		_retry(client, "move", [2, original, 3, amount, 0])
	assert_int(actor.inventory_data.inventory_slots[2].quantity).is_equal(2)
	var private_packets := 0
	var needle := "Cogito_HealthPotion.tres".to_ascii_buffer().hex_encode()
	for i in transport.sent.size():
		if transport.sent[i].hex_encode().contains(needle):
			private_packets += 1
			assert_int(transport.destinations[i]).is_equal(2)
	assert_int(private_packets).is_greater(0)
	_retry(client, "bind", [2, original, 1])
	actor.player_currencies.credits.value_current = 17
	client.disconnect_session()
	_pump()
	var returning := _branch(4)
	returning.join("memory", 1802)
	_arena(returning)
	_pump()
	assert_str(returning.local_player_id()).is_equal(id)
	var restored := returning.player_world.inventory.local
	assert_int(restored.data.inventory_slots[2].quantity).is_equal(2)
	assert_int(restored.id_of(restored.data.assigned_quickslots[1])).is_equal(original)
	assert_object(restored.data.inventory_slots[0]).is_null()
	assert_float(returning.local_player().player_currencies.credits.value_current).is_equal(17.0)


func test_combine_swap_and_wieldable_use(_timeout := 15000) -> void:
	var host := _branch(1)
	host.host({"save_dir": "user://net/inventory-host"})
	_arena(host)
	var api := host.player_world.inventory
	var inv := host.local_player().inventory_data
	for asset: String in ["DiamondKey_A", "DiamondKey_B", "Pistol"]:
		preload("res://addons/cogito/Networking/net_grid.gd").insert(
			inv, _stack(asset, 1), 1, false
		)
	inv.inventory_updated.emit(inv)
	await _ticks(2)
	var a := inv.find_slots("Diamond Half A")[0]
	var b := inv.find_slots("Diamond Half B")[0]
	var a_id := api.local.id_of(a)
	var b_id := api.local.id_of(b)
	_retry(host, "move", [a.origin_index, a_id, b.origin_index, 1, 0])
	assert_int(api.local.id_of(inv.inventory_slots[0])).is_equal(b_id)
	_retry(host, "combine", [a.origin_index, a_id, b.origin_index])
	assert_int(inv.find_slots("Diamond Key").size()).is_equal(1)
	var gun := inv.find_slots("Foam Pistol")[0]
	var responses: Array[Dictionary] = []
	api.result_received.connect(func(reply: Dictionary): responses.append(reply))
	var revision := api.local.revision
	_retry(host, "use", [gun.origin_index, api.local.id_of(gun)])
	assert_str(responses.back().reason).is_equal("Weapons await MP3b")
	assert_int(api.local.revision).is_equal(revision)
	assert_bool(gun.inventory_item.is_being_wielded).is_false()


func _near(server: Facade, who: Facade, pos: Vector3) -> void:
	var avatar := server.player_world.avatar_for(who.local_player_id())
	avatar.actor.position = pos
	avatar.actor.velocity = Vector3.ZERO
	server.player_world.mark_teleport(who.local_player_id())


func test_pickup_race_partial_drop_and_container_conflict(_timeout := 15000) -> void:
	var server := _branch(1)
	server.start_server({"save_dir": "user://net/shared-stock"})
	var level := _arena(server)
	var a := _observer(2)
	var b := _observer(3)
	_near(server, a, Vector3(30.3, 0.1, 0.6))
	_near(server, b, Vector3(31.7, 0.1, 0.6))
	var actor := server.player_world.avatar_for(a.local_player_id()).actor
	var slot := _stack("LockpickItem", 9)
	slot.origin_index = 0
	actor.inventory_data.inventory_slots.assign([slot])
	actor.inventory_data.inventory_size = Vector2i.ONE
	var pickup: PickupComponent = level.get_node("LooseItem/PickupComponent")
	pickup.slot_data = _stack("LockpickItem", 2)
	await _ticks(3)
	_use(a, "LooseItem/PickupComponent")
	assert_int(slot.quantity).is_equal(10)
	assert_int(pickup.slot_data.quantity).is_equal(1)
	var path := "LooseItem/PickupComponent"
	for client in [a, b]:
		var remaining: PickupComponent = client.player_world.active_level().get_node(path)
		assert_int(remaining.slot_data.quantity).is_equal(1)
	var b_api := b.player_world.interactions
	var win := b_api.make_request(b.player_world.active_level().get_node(path), &"interact")
	var a_api := a.player_world.interactions
	var lose := a_api.make_request(a.player_world.active_level().get_node(path), &"interact")
	var replies: Array[Dictionary] = []
	a_api.result_received.connect(func(reply: Dictionary): replies.append(reply))
	b_api.dispatch(win)
	_pump()
	a_api.dispatch(lose)
	_pump()
	assert_bool(replies.back().ok).is_false()
	assert_int(b.local_player().inventory_data.inventory_slots[0].quantity).is_equal(1)
	var late := _observer(4)
	await _ticks(2)
	for peer in [server, a, b, late]:
		assert_object(peer.player_world.active_level().get_node_or_null("LooseItem")).is_null()
	var own := a.player_world.inventory.local
	_retry(a, "drop", [0, own.id_of(own.data.inventory_slots[0]), 2])
	assert_int(slot.quantity).is_equal(8)
	for peer in [server, a, b, late]:
		var node: Node = peer.player_world.world.entities.live_object("runtime:1")
		assert_object(node).is_not_null()
		if node:
			assert_int(node.get_node("PickupComponent").slot_data.quantity).is_equal(2)
			assert_bool(node.freeze).is_equal(peer != server)
	var world := server.player_world.world
	var version: int = world.revisions["runtime:1"]
	var falling := world.entities.live_object("runtime:1") as Node3D
	falling.position.y += 0.5
	var pose := falling.global_transform
	server.player_world.spawner._physics_process(0.2)
	_pump()
	assert_int(world.revisions["runtime:1"]).is_equal(version)
	var replica := a.player_world.world.entities.live_object("runtime:1") as Node3D
	assert_bool(replica.global_transform.is_equal_approx(pose)).is_true()
	_near(server, a, Vector3(30.3, 0.1, -0.5))
	_near(server, b, Vector3(31.7, 0.1, -0.5))
	await _ticks(2)
	_use(a, "SharedBox/BasicInteraction")
	_use(b, "SharedBox/BasicInteraction")
	var box_a := a.player_world.containers
	var box_b := b.player_world.containers
	var put := [
		0, own.id_of(own.data.inventory_slots[0]), 0, 3, 0, box_a.token, box_a.local.revision
	]
	_retry(a, "put", put)
	assert_int(box_b.local.data.inventory_slots[0].quantity).is_equal(3)
	var box_id := box_a.local.id_of(box_a.local.data.inventory_slots[0])
	var args := [0, box_id, 0, 3, 0, box_a.token, box_a.local.revision]
	var stale := a.player_world.inventory.make_request("take", args)
	args = args.duplicate()
	args[5] = box_b.token
	var transfers: Array[Dictionary] = []
	b.player_world.inventory.result_received.connect(
		func(reply: Dictionary): transfers.append(reply)
	)
	_retry(b, "take", args)
	assert_str(transfers.back().reason).is_empty()
	a.player_world.inventory.dispatch(stale)
	_pump()
	assert_object(box_a.local.data.inventory_slots[0]).is_null()
	assert_int(slot.quantity).is_equal(5)
	assert_int(b.local_player().inventory_data.inventory_slots[0].quantity).is_equal(4)
	a.local_player().player_hud.set_inventory_visibility(false)
	b.local_player().player_hud.set_inventory_visibility(false)


func test_container_grid_take_all_and_owner_quickslot_ui(_timeout := 15000) -> void:
	var server := _branch(1)
	server.start_server({"save_dir": "user://net/container-ui"})
	var level := _arena(server)
	var a := _observer(2)
	var b := _observer(3)
	var actor := server.player_world.avatar_for(a.local_player_id()).actor
	var box: CogitoContainer = level.get_node("SharedBox")
	box.inventory_data.inventory_slots[0] = _stack("HealthPotion", 2)
	_near(server, a, Vector3(30.3, 0.1, -0.5))
	_near(server, b, Vector3(31.7, 0.1, -0.5))
	await _ticks(2)
	_use(a, "SharedBox/BasicInteraction")
	_use(b, "SharedBox/BasicInteraction")
	var grant := a.player_world.containers
	var model := grant.local
	var id := model.id_of(model.data.inventory_slots[0])
	_retry(a, "external_move", [0, id, 1, 2, 0, grant.token, model.revision])
	assert_int(model.id_of(model.data.inventory_slots[1])).is_equal(id)
	var requester_hints: Array[String] = []
	var viewer_hints: Array[String] = []
	a.local_player().player_interaction_component.hint_prompt.connect(
		func(_icon: Texture2D, msg: String): requester_hints.append(msg)
	)
	b.local_player().player_interaction_component.hint_prompt.connect(
		func(_icon: Texture2D, msg: String): viewer_hints.append(msg)
	)
	var inv := actor.inventory_data
	inv.inventory_slots.assign([_stack("Battery", 1)])
	inv.inventory_size = Vector2i.ONE
	inv.inventory_updated.emit(inv)
	await _ticks(2)
	_retry(a, "take_all", [grant.token, model.revision])
	assert_array(requester_hints).contains_exactly(["Inventory full"])
	assert_array(viewer_hints).is_empty()
	inv.inventory_slots.fill(null)
	inv.inventory_updated.emit(inv)
	await _ticks(2)
	_retry(a, "take_all", [grant.token, model.revision])
	assert_object(b.player_world.containers.local.data.inventory_slots[1]).is_null()
	assert_int(inv.inventory_slots[0].quantity).is_equal(2)
	var ui := (a.local_player().player_hud as CogitoPlayerHudManager).inventory_interface
	var replica := a.player_world.inventory.local.data
	ui.on_inventory_button_press(replica, 0, "inventory_move_item", ui.inventory_ui)
	assert_object(ui.grabbed_slot_data).is_not_same(replica.inventory_slots[0])
	ui.network_cursor.bind_slot(ui, 1)
	_pump()
	assert_object(replica.assigned_quickslots[1]).is_same(replica.inventory_slots[0])
	a.local_player().player_hud.set_inventory_visibility(false)
	_pump()
	actor.player_attributes.health.value_current = 10
	ui.quick_slots.inventory_set.activate(1, a.local_player())
	_pump()
	assert_int(replica.inventory_slots[0].quantity).is_equal(1)
	assert_float(actor.player_attributes.health.value_current).is_equal(20.0)
	b.local_player().player_hud.set_inventory_visibility(false)


func test_vendor_buys_and_sells_at_authored_price() -> void:
	var server := _branch(1)
	server.start_server({"save_dir": "user://net/trade"})
	var level := _arena(server)
	var client := _observer(2)
	var actor := server.player_world.avatar_for(client.local_player_id()).actor
	var vendor: Node = level.get_node("Vendor")
	var check: CurrencyCheck = vendor.currency_check
	var purchased: Array[Node] = []
	check.transaction_success.connect(func(who: Node): purchased.append(who))
	var wallet: CogitoCurrency = actor.player_currencies[check.currency_name]
	wallet.value_current = 20
	_near(server, client, Vector3(35.4, 0.1, 1.5))
	await _ticks(3)
	var button := "Vendor/GenericButton/BasicInteraction"
	var stock: int = vendor.amount_remaining
	_use(client, button)
	assert_int(vendor.amount_remaining).is_equal(stock - 1)
	assert_float(wallet.value_current).is_equal(15.0)
	assert_int(client.local_player().inventory_data.find_slots("Health Potion").size()).is_equal(1)
	vendor.cogito_button.cooldown = 0
	_use(client, button, &"sell")
	assert_int(vendor.amount_remaining).is_equal(stock)
	assert_float(wallet.value_current).is_equal(20.0)
	assert_array(purchased).contains_exactly([actor, actor])
	assert_array(client.local_player().inventory_data.find_slots("Health Potion")).is_empty()


func test_loot_bag_generated_without_players_and_late_join() -> void:
	var server := _branch(1)
	server.start_server({"save_dir": "user://net/zero-loot"})
	var level := _arena(server)
	assert_array(server.players()).is_empty()
	var table := LootTable.new()
	var entry := LootDropEntry.new()
	entry.inventory_item = _stack("HealthPotion", 1).inventory_item
	entry.droptype = LootDropEntry.DropType.GUARANTEED
	entry.quantity_min = 2
	entry.quantity_max = 2
	table.drops.append(entry)
	var source: LootComponent = level.get_node("LootSource")
	source.loot_table = table
	source._spawn_loot_container()
	var bag := server.player_world.world.entities.live_object("runtime:1") as LootDropContainer
	assert_object(bag).is_not_null()
	assert_int(bag.inventory_data.inventory_slots[0].quantity).is_equal(2)
	var client := _observer(2)
	assert_object(client.player_world.world.entities.live_object("runtime:1")).is_not_null()
	bag._on_despawn_timer_timeout()
	await _ticks(2)
	assert_object(client.player_world.world.entities.live_object("runtime:1")).is_null()


func test_paid_button_charges_only_actor_and_rejects_insufficient_funds() -> void:
	var server := _branch(1)
	server.start_server({"save_dir": "user://net/button-wallet"})
	var level := _arena(server)
	var a := _observer(2)
	var b := _observer(3)
	var button: CogitoButton = level.get_node("Button")
	button.allows_repeated_interaction = true
	var check := CurrencyCheck.new()
	check.currency_cost = 5
	button.add_child(check)
	button.currency_check = check
	var actor := server.player_world.avatar_for(a.local_player_id()).actor
	var wallet: CogitoCurrency = actor.player_currencies.credits
	wallet.value_current = 6
	_near(server, a, Vector3(7.3, 0.1, -12.1))
	await _ticks(2)
	_use(a, "Button/Use")
	assert_float(wallet.value_current).is_equal(1.0)
	assert_float(a.local_player().player_currencies.credits.value_current).is_equal(1.0)
	assert_float(b.local_player().player_currencies.credits.value_current).is_equal(10.0)
	var replies: Array[Dictionary] = []
	a.player_world.interactions.result_received.connect(
		func(reply: Dictionary): replies.append(reply)
	)
	_use(a, "Button/Use")
	assert_bool(replies.back().ok).is_false()
	assert_float(wallet.value_current).is_equal(1.0)


func test_offline_inventory_uses_original_resource_and_owner_synchronously() -> void:
	var actor := CogitoPlayerAdvanced.new()
	auto_free(actor)
	var wallet := CogitoCurrency.new()
	actor.add_child(wallet)
	wallet.value_max = 100
	actor.player_currencies.credits = wallet
	var inv := CogitoInventory.new()
	inv.owner = actor
	var coins := _stack("Coins", 2)
	coins.inventory_item = coins.inventory_item.duplicate()
	coins.inventory_item.hint_text_on_use = ""
	inv.inventory_slots.assign([coins])
	inv.assigned_quickslots.assign([coins])
	coins.origin_index = 0
	inv.use_slot_data(0)
	assert_float(wallet.value_current).is_equal(5.0)
	assert_int(coins.quantity).is_equal(1)
	assert_object(inv.assigned_quickslots[0]).is_same(coins)
	assert_int(CogitoNet.get_child_count()).is_zero()

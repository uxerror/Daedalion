extends GdUnitTestSuite

const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
const FIXTURES := preload("res://tests/fixtures/element_fixtures.gd")
const HUD := preload("res://addons/cogito/Components/UI/UI_ElementStatus.tscn")
const E = CogitoProperties.Element
const F = CogitoProperties.ElementalProperties
const S = CogitoElementStatusHud.Status

var _world: FIXTURES.PlayerWorld
var _forward_strength: float


class FakeItem:
	extends InventoryItemPD
	var used := 0

	func use(_target) -> bool:
		used += 1
		return false


class Actor:
	extends Node3D

	func can_act() -> bool:
		return false


func before_test() -> void:
	_world = auto_free(FIXTURES.PlayerWorld.new())
	get_tree().root.add_child(_world)
	_forward_strength = Input.get_action_strength("forward")
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(400, 1, 400)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0, -0.5, 0)
	_world.add_child(floor_body)
	await _frames()


func after_test() -> void:
	await _frames()
	_world.restore()
	if _forward_strength > 0.0:
		Input.action_press("forward", _forward_strength)
	else:
		Input.action_release("forward")


func _spawn_npc() -> CogitoNPC:
	var npc: CogitoNPC = FIXTURES.make_npc()
	npc.position = Vector3(100, 0.1, 100)
	_world.add_child(npc)
	await _physics_frames(10)
	return npc


func _make_properties(
	flags: int, pos: Vector3, settings := {}, with_actor := false
) -> CogitoProperties:
	var h := FIXTURES.Holder.new()
	h.position = pos
	var properties: CogitoProperties = PROPS.instantiate()
	properties.elemental_properties = flags
	properties.is_logging = false
	for key in settings:
		properties.set(key, settings[key])
	h.add_child(properties)
	h.cogito_properties = properties
	if with_actor:
		var a := CogitoActorElements.new()
		a.name = "CogitoActorElements"
		h.add_child(a)
	_world.add_child(h)
	return properties


func _actor_of(properties: CogitoProperties) -> CogitoActorElements:
	return properties.get_parent().get_node("CogitoActorElements")


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _frames(count := 2) -> void:
	for _frame in count:
		await get_tree().process_frame


func _physics_frames(count := 2) -> void:
	for _frame in count:
		await get_tree().physics_frame


func _flat_speed(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


func _cold_zone(pos: Vector3) -> CogitoElementArea:
	var area := CogitoElementArea.new()
	area.element = E.COLD
	area.amount_per_second = 2.0
	area.collision_mask = 0xFFFFFFFF
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6, 6, 6)
	shape.shape = box
	area.add_child(shape)
	area.position = pos
	_world.add_child(area)
	return area


func test_chill_freeze_and_struggle() -> void:
	var properties := _make_properties(
		0, Vector3(-50, 0, 0), {"chill_time": 60.0, "freeze_time": 60.0}, true
	)
	await _frames()
	var a := _actor_of(properties)
	(
		assert_bool(
			(
				a.properties == properties
				and a.speed_multiplier == 1.0
				and a.can_jump()
				and a.can_act()
			)
		)
		. override_failure_message("actor elements found sibling properties, normal by default")
		. is_true()
	)
	var changes := []
	a.movement_changed.connect(func(m): changes.append(m))
	properties.apply_element(E.COLD, 1.0)
	(
		assert_bool(
			properties.is_chilled and is_equal_approx(a.speed_multiplier, 0.6) and changes == [0.6]
		)
		. override_failure_message("chilled -> speed 0.6, movement_changed")
		. is_true()
	)
	(
		assert_bool(a.can_jump() and a.can_act())
		. override_failure_message("chilled actor can still jump and act")
		. is_true()
	)
	properties.apply_element(E.WATER, 1.0)
	properties.apply_element(E.COLD, 1.0)
	(
		assert_bool(properties.is_frozen and a.speed_multiplier == 0.0 and !a.can_jump())
		. override_failure_message("frozen -> speed 0, can't jump")
		. is_true()
	)
	(
		assert_bool(!a.can_act())
		. override_failure_message("frozen blocks actions (frozen_blocks_actions)")
		. is_true()
	)
	a.frozen_blocks_actions = false
	(
		assert_bool(a.can_act())
		. override_failure_message("frozen_blocks_actions off -> can act")
		. is_true()
	)
	a.frozen_blocks_actions = true
	var level_before := properties.get_element_level(E.COLD)
	a.struggle()
	(
		assert_bool(is_equal_approx(level_before - properties.get_element_level(E.COLD), 0.2))
		. override_failure_message("struggle removes 0.2 COLD")
		. is_true()
	)
	var presses := 1
	while properties.is_frozen and presses < 20:
		a.struggle()
		presses += 1
	(
		assert_bool(!properties.is_frozen and properties.is_wet and presses <= 7)
		. override_failure_message("struggling thaws after %d presses, actor wet again" % presses)
		. is_true()
	)
	(
		assert_bool(a.speed_multiplier == 1.0 and a.can_jump())
		. override_failure_message("thawed actor moves normally")
		. is_true()
	)
	(
		assert_bool(!a.struggle())
		. override_failure_message("struggle() does nothing when not frozen")
		. is_true()
	)


func test_shock_stun_and_cooldown(_timeout := 10000) -> void:
	var s := _make_properties(F.CONDUCTIVE, Vector3(-55, 0, 0), {}, true)
	await _frames()
	var actor := _actor_of(s)
	var stun_events := [0, 0]
	actor.stunned.connect(func(): stun_events[0] += 1)
	actor.stun_ended.connect(func(): stun_events[1] += 1)
	s.apply_element(E.SHOCK, 1.0)
	(
		assert_bool(
			(
				actor.is_stunned
				and !actor.can_act()
				and !actor.can_jump()
				and actor.speed_multiplier == 0.0
			)
		)
		. override_failure_message("SHOCK stuns: can't act, jump or move")
		. is_true()
	)
	await _wait(0.65)
	(
		assert_bool(
			(
				!actor.is_stunned
				and actor.can_act()
				and actor.speed_multiplier == 1.0
				and stun_events == [1, 1]
			)
		)
		. override_failure_message("stun ends after ~0.5 s")
		. is_true()
	)
	s.apply_element(E.SHOCK, 0.5)
	(
		assert_bool(!actor.is_stunned)
		. override_failure_message("second SHOCK within cooldown doesn't stun")
		. is_true()
	)
	await _wait(1.6)
	(
		assert_bool(!actor.is_processing())
		. override_failure_message("actor elements stop processing when idle")
		. is_true()
	)
	s.apply_element(E.SHOCK, 0.5)
	(
		assert_bool(actor.is_stunned and stun_events[0] == 2)
		. override_failure_message("SHOCK after cooldown stuns again")
		. is_true()
	)
	await _wait(0.65)


func test_shock_damage_stuns_a_nonconductor() -> void:
	var d := _make_properties(0, Vector3(-60, 0, 0), {}, true)
	await _frames()
	var actor := _actor_of(d)
	(
		assert_bool(d.apply_element(E.SHOCK, 1.0) == 0.0 and !actor.is_stunned)
		. override_failure_message("dry actor gets no SHOCK buildup")
		. is_true()
	)
	CogitoProperties.deal_elemental_damage(d.get_parent(), 5.0, E.SHOCK)
	assert_bool(actor.is_stunned).override_failure_message("SHOCK damage stuns").is_true()


func test_item_use_requires_an_owner_who_can_act() -> void:
	var inventory := CogitoInventory.new()
	var item := FakeItem.new()
	var slot := InventorySlotPD.new()
	slot.inventory_item = item
	inventory.inventory_slots = [slot]
	var owner_actor := Actor.new()
	_world.add_child(owner_actor)
	inventory.owner = owner_actor
	inventory.use_slot_data(0)
	(
		assert_bool(item.used == 0)
		. override_failure_message("inventory: owner that can't act uses no items")
		. is_true()
	)
	inventory.owner = self
	inventory.use_slot_data(0)
	(
		assert_bool(item.used == 1)
		. override_failure_message("inventory: owner without can_act() still uses items")
		. is_true()
	)


func test_player_burns_douses_and_conducts_shock(_timeout := 20000) -> void:
	var player := await _world.spawn_player(Vector3(0, 1, 0))
	var props := CogitoProperties.get_properties_of(player)
	(
		assert_bool(
			props != null and props == player.cogito_properties and props.get_parent() == player
		)
		. override_failure_message("player has CogitoProperties found via get_properties_of")
		. is_true()
	)
	(
		assert_bool(player.actor_elements != null and player.actor_elements.properties == props)
		. override_failure_message("player has CogitoActorElements")
		. is_true()
	)
	(
		assert_bool(
			(
				props.heat_radius == 0.0
				and props.fuel == 4.0
				and props.burn_out_result == CogitoProperties.BurnOutResult.NOTHING
			)
		)
		. override_failure_message("player actor settings: no heat, fuel 4, burns out to nothing")
		. is_true()
	)
	var health: CogitoAttribute = player.player_attributes["health"]
	health.value_current = health.value_max
	var typed := []
	player.elemental_damage_received.connect(
		func(amount, element, _src): typed.append([amount, element])
	)

	# Burning
	var neighbour := _make_properties(F.FLAMMABLE, Vector3(0.9, 0.5, 0))
	await _frames()
	var h0 := health.value_current
	props.apply_element(E.FIRE, 1.0)
	assert_bool(props.is_on_fire).override_failure_message("FIRE ignites the player").is_true()
	(
		assert_bool(props.get_node_or_null("HeatSensor") == null)
		. override_failure_message("burning player radiates no heat (heat_radius 0)")
		. is_true()
	)
	await _wait(2.2)
	(
		assert_bool(health.value_current < h0 - 5.0)
		. override_failure_message(
			"burning player loses health: %s -> %s" % [h0, health.value_current]
		)
		. is_true()
	)
	(
		assert_bool(typed.size() > 0 and typed[0][1] == E.FIRE)
		. override_failure_message("player got typed FIRE damage")
		. is_true()
	)
	(
		assert_bool(!neighbour.is_on_fire)
		. override_failure_message("burning player doesn't ignite a flammable body next to it")
		. is_true()
	)
	await _wait(2.5)
	(
		assert_bool(!props.is_on_fire)
		. override_failure_message("player fire goes out by itself after its fuel")
		. is_true()
	)
	(
		assert_bool((props.elemental_properties & F.FLAMMABLE) != 0)
		. override_failure_message("player stays flammable after burning out")
		. is_true()
	)
	props.apply_element(E.FIRE, 1.0)
	assert_bool(props.is_on_fire).override_failure_message("player can catch fire again").is_true()
	props.apply_element(E.WATER, 1.0)
	(
		assert_bool(!props.is_on_fire and props.is_wet)
		. override_failure_message("water douses and wets the player")
		. is_true()
	)

	# Wet player
	props.apply_element(E.FIRE, 1.0)
	assert_bool(!props.is_on_fire).override_failure_message("wet player doesn't ignite").is_true()
	props.apply_element(E.WATER, 1.0)
	health.value_current = health.value_max
	var h1 := health.value_current
	var dealt := CogitoProperties.deal_elemental_damage(player, 10.0, E.SHOCK)
	(
		assert_bool(
			is_equal_approx(dealt, 15.0) and is_equal_approx(h1 - health.value_current, 15.0)
		)
		. override_failure_message("wet player takes x1.5 SHOCK: %s" % (h1 - health.value_current))
		. is_true()
	)
	(
		assert_bool(player.actor_elements.is_stunned and !player.can_act())
		. override_failure_message("SHOCK stuns the player")
		. is_true()
	)
	await _wait(0.6)
	(
		assert_bool(player.can_act())
		. override_failure_message("player can act again after the stun")
		. is_true()
	)
	props.make_dry()


func test_radiated_heat_ignites_player(_timeout := 10000) -> void:
	var player := await _world.spawn_player(Vector3(0, 1, 0))
	var props := player.cogito_properties
	var grass := _make_properties(
		F.FLAMMABLE, Vector3(1.0, 0.5, 0), {"heat_radius": 2.0, "heat_per_second": 3.0}
	)
	await _frames()
	grass.set_on_fire()
	var elapsed := 0.0
	while elapsed < 3.0 and !props.is_on_fire:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	(
		assert_bool(props.is_on_fire)
		. override_failure_message("burning grass with heat_radius ignites the player")
		. is_true()
	)
	grass.extinguish(false)
	props.extinguish(false)


func test_poison_damages_player(_timeout := 10000) -> void:
	var player := await _world.spawn_player(Vector3(0, 1, 0))
	var props := player.cogito_properties
	var health: CogitoAttribute = player.player_attributes["health"]
	health.value_current = health.value_max
	var h2 := health.value_current
	props.apply_element(E.POISON, 1.0)
	assert_bool(props.is_poisoned).override_failure_message("player poisoned").is_true()
	await _wait(2.2)
	(
		assert_bool(health.value_current <= h2 - 3.9)
		. override_failure_message("poison damages player health: %s" % (h2 - health.value_current))
		. is_true()
	)
	props.cure_poison()


func test_player_movement_and_struggle(_timeout := 12000) -> void:
	var player := await _world.spawn_player(Vector3(0, 1, 0))
	var props := player.cogito_properties
	var health: CogitoAttribute = player.player_attributes["health"]
	health.value_current = health.value_max
	await _physics_frames(5)
	Input.action_press("forward")
	await _wait(0.8)
	var v_normal := _flat_speed(player.velocity)
	props.apply_element(E.COLD, 1.0)
	assert_bool(props.is_chilled).override_failure_message("player chilled").is_true()
	await _wait(0.8)
	var v_chilled := _flat_speed(player.velocity)
	(
		assert_bool(v_normal > 3.0 and absf(v_chilled - v_normal * 0.6) < 0.4)
		. override_failure_message(
			"chilled player walks at ~0.6 speed: %.2f -> %.2f" % [v_normal, v_chilled]
		)
		. is_true()
	)
	props.apply_element(E.WATER, 1.0)
	props.apply_element(E.COLD, 1.0)
	assert_bool(props.is_frozen).override_failure_message("player frozen").is_true()
	await _wait(0.8)
	(
		assert_bool(_flat_speed(player.velocity) < 0.2)
		. override_failure_message(
			"frozen player doesn't move: %.2f" % _flat_speed(player.velocity)
		)
		. is_true()
	)
	assert_bool(!player._can_jump()).override_failure_message("frozen player can't jump").is_true()
	assert_bool(!player.can_act()).override_failure_message("frozen player can't act").is_true()
	Input.action_release("forward")
	# Isolate command edges from passive thaw during the physics ticks below.
	props.freeze_time = 0.0
	# Struggle: new movement presses
	var cold := props.get_element_level(E.COLD)
	var press_event := InputEventAction.new()
	press_event.action = &"left"
	press_event.pressed = true
	player.on_input(press_event)
	await _physics_frames(2)
	(
		assert_bool(props.get_element_level(E.COLD) < cold - 0.1)
		. override_failure_message("movement press while frozen struggles")
		. is_true()
	)
	var held := props.get_element_level(E.COLD)
	var release_event := InputEventAction.new()
	release_event.action = &"left"
	release_event.pressed = false
	player.on_input(release_event)
	await _physics_frames(2)
	(
		assert_bool(is_equal_approx(props.get_element_level(E.COLD), held))
		. override_failure_message("key release doesn't struggle")
		. is_true()
	)
	var n := 1
	while props.is_frozen and n < 20:
		player.on_input(press_event)
		await _physics_frames(2)
		n += 1
	(
		assert_bool(!props.is_frozen and props.is_wet)
		. override_failure_message("player struggled free after %d presses, wet again" % n)
		. is_true()
	)


func test_cold_zone_refreshes_an_object_freeze() -> void:
	_cold_zone(Vector3(-120, 0, 0))
	var subject := _make_properties(0, Vector3(-120, 0, 0), {"freeze_time": 60.0})
	(
		assert_bool(subject.frozen_absorbs_cold and !subject.freeze_immune)
		. override_failure_message("frozen_absorbs_cold defaults to true, freeze_immune to false")
		. is_true()
	)
	await _frames()
	subject.apply_element(E.WATER, 1.0)
	await _wait(1.0)
	(
		assert_bool(subject.is_frozen)
		. override_failure_message("object frozen in the cold zone")
		. is_true()
	)
	subject.reduce_element(E.COLD, 0.5)
	var lowered := subject.get_element_level(E.COLD)
	await _wait(0.6)
	(
		assert_bool(subject.get_element_level(E.COLD) > lowered + 0.5)
		. override_failure_message(
			(
				"object in a cold zone refreshes its freeze (old behaviour): %.2f -> %.2f"
				% [lowered, subject.get_element_level(E.COLD)]
			)
		)
		. is_true()
	)


func test_routed_input_frees_player_in_active_cold_zone(_timeout := 16000) -> void:
	var player := await _world.spawn_player(Vector3(100, 1, 0))
	var props := player.cogito_properties
	var actor := player.actor_elements
	(
		assert_bool(!props.frozen_absorbs_cold)
		. override_failure_message(
			"player: frozen_absorbs_cold is off (set by CogitoActorElements)"
		)
		. is_true()
	)
	var zone := _cold_zone(Vector3(100, 1, 0))
	props.apply_element(E.WATER, 1.0)
	await _wait(1.0)
	(
		assert_bool(props.is_frozen)
		. override_failure_message("player frozen by the cold zone")
		. is_true()
	)
	await _wait(0.5)
	(
		assert_bool(
			props.is_frozen and props.get_element_level(E.COLD) <= props.buildup_threshold + 0.001
		)
		. override_failure_message(
			"cold zone doesn't refresh the player's freeze: %.2f" % props.get_element_level(E.COLD)
		)
		. is_true()
	)
	(
		assert_bool(InputRouter.is_input_active(player))
		. override_failure_message("player owns the input")
		. is_true()
	)
	var presses := 0
	while props.is_frozen and presses < 12:
		var down := InputEventAction.new()
		down.action = &"forward"
		down.pressed = true
		Input.parse_input_event(down)
		await _frames(2)
		var up := InputEventAction.new()
		up.action = &"forward"
		up.pressed = false
		Input.parse_input_event(up)
		await _frames(2)
		presses += 1
	(
		assert_bool(!props.is_frozen and presses <= 6)
		. override_failure_message(
			"player struggled free in %d presses inside the cold zone" % presses
		)
		. is_true()
	)
	assert_bool(zone.enabled).override_failure_message("the cold zone stayed on").is_true()
	# Immunity: chilled, not frozen again
	await _wait(1.2)
	(
		assert_bool(!props.is_frozen and props.is_chilled and props.freeze_immune)
		. override_failure_message("after thawing: chilled and freeze-immune, not frozen again")
		. is_true()
	)
	(
		assert_bool(is_equal_approx(actor.speed_multiplier, actor.chilled_speed_multiplier))
		. override_failure_message("walking out chilled at x0.6")
		. is_true()
	)
	await _wait(2.5)
	(
		assert_bool(!props.freeze_immune)
		. override_failure_message("freeze immunity ended after refreeze_immunity_time")
		. is_true()
	)
	await _wait(0.5)
	(
		assert_bool(props.is_frozen)
		. override_failure_message("player can be frozen again after the immunity")
		. is_true()
	)


func test_burning_npc_panics_and_recovers() -> void:
	var npc := await _spawn_npc()
	var props := npc.cogito_properties
	(
		assert_bool(
			(
				npc.actor_elements != null
				and props != null
				and props.get_parent() == npc
				and npc.actor_elements.properties == props
			)
		)
		. override_failure_message("NPC has CogitoProperties and CogitoActorElements")
		. is_true()
	)
	(
		assert_bool(CogitoProperties.get_properties_of(npc) == props)
		. override_failure_message("get_properties_of finds the NPC's properties")
		. is_true()
	)
	(
		assert_bool(npc.current_behaviour == CogitoNPC.BehaviourState.Idle)
		. override_failure_message("NPC starts idle")
		. is_true()
	)
	assert_bool(npc.can_act()).override_failure_message("NPC can act normally").is_true()

	# Burning NPC panics
	var start := npc.global_position
	props.apply_element(E.FIRE, 1.0)
	await _physics_frames(2)
	(
		assert_bool(props.is_on_fire and npc.is_panicking())
		. override_failure_message("burning NPC panics")
		. is_true()
	)
	assert_bool(!npc.can_act()).override_failure_message("panicking NPC can't attack").is_true()
	npc.state_chart.send_event("chase")
	npc.state_chart.send_event("alerted")
	await _physics_frames(2)
	(
		assert_bool(npc.is_panicking())
		. override_failure_message("detection events don't end the panic")
		. is_true()
	)
	await _wait(1.0)
	var moved := Vector2(npc.global_position.x - start.x, npc.global_position.z - start.z).length()
	(
		assert_bool(moved > 1.0)
		. override_failure_message("panicking NPC runs around: %.2f m" % moved)
		. is_true()
	)
	(
		assert_bool(is_equal_approx(npc.move_speed, npc.sprint_speed))
		. override_failure_message("panic runs at sprint speed")
		. is_true()
	)
	props.apply_element(E.WATER, 1.0)
	await _physics_frames(2)
	(
		assert_bool(!props.is_on_fire and npc.current_behaviour == CogitoNPC.BehaviourState.Idle)
		. override_failure_message("fire out -> NPC back to idle")
		. is_true()
	)
	(
		assert_bool(npc.can_act())
		. override_failure_message("NPC can act again after the panic")
		. is_true()
	)
	props.make_dry()


func test_chilled_and_frozen_npc_movement(_timeout := 15000) -> void:
	var npc := await _spawn_npc()
	var props := npc.cogito_properties
	props.apply_element(E.COLD, 1.0)
	(
		assert_bool(props.is_chilled and is_equal_approx(npc.get_speed_multiplier(), 0.6))
		. override_failure_message("chilled NPC speed multiplier 0.6")
		. is_true()
	)
	npc.move_speed = 2.0
	var target := npc.global_position + Vector3(20, 0, 0)
	for i in 30:
		await get_tree().physics_frame
		npc.move_npc_towards(target, get_physics_process_delta_time())
	(
		assert_bool(absf(_flat_speed(npc.velocity) - 1.2) < 0.1)
		. override_failure_message(
			"chilled NPC moves at 0.6 x move_speed: %.2f" % _flat_speed(npc.velocity)
		)
		. is_true()
	)

	# Frozen NPC can't move or attack and struggles free by itself
	props.apply_element(E.WATER, 1.0)
	props.apply_element(E.COLD, 1.0)
	(
		assert_bool(props.is_frozen and npc.get_speed_multiplier() == 0.0 and !npc.can_act())
		. override_failure_message("frozen NPC can't move or attack")
		. is_true()
	)
	for i in 30:
		await get_tree().physics_frame
		npc.move_npc_towards(target, get_physics_process_delta_time())
	(
		assert_bool(_flat_speed(npc.velocity) < 0.05)
		. override_failure_message("frozen NPC stands still")
		. is_true()
	)
	var thawed_at := -1.0
	var elapsed := 0.0
	while elapsed < 8.0:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if !props.is_frozen:
			thawed_at = elapsed
			break
	(
		assert_bool(thawed_at > 0.0 and thawed_at < 5.0 and props.is_wet)
		. override_failure_message("frozen NPC struggles free by itself in %.1f s" % thawed_at)
		. is_true()
	)


func test_shock_stuns_npc() -> void:
	var npc := await _spawn_npc()
	await _wait(0.1)
	CogitoProperties.deal_elemental_damage(npc, 0.5, E.SHOCK)
	(
		assert_bool(
			npc.actor_elements.is_stunned and !npc.can_act() and npc.get_speed_multiplier() == 0.0
		)
		. override_failure_message("SHOCK stuns the NPC")
		. is_true()
	)
	await _wait(0.6)
	assert_bool(npc.can_act()).override_failure_message("NPC recovers from the stun").is_true()


func test_poison_ticks_leave_npc_idle() -> void:
	var npc := await _spawn_npc()
	var props := npc.cogito_properties
	props.apply_element(E.POISON, 1.0)
	await _wait(1.2)
	(
		assert_bool(npc.current_behaviour == CogitoNPC.BehaviourState.Idle)
		. override_failure_message("poison ticks don't alert the NPC")
		. is_true()
	)
	props.cure_poison()


func test_hud_tracks_buildup_states_and_rebinding() -> void:
	var hud: CogitoElementStatusHud = HUD.instantiate()
	_world.add_child(hud)
	await _frames()
	(
		assert_bool(
			(
				!hud.is_overlay_visible()
				and hud.mouse_filter == Control.MOUSE_FILTER_IGNORE
				and hud.overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE
			)
		)
		. override_failure_message("HUD: unbound, overlay hidden, ignores the mouse")
		. is_true()
	)
	var properties := _make_properties(
		F.FLAMMABLE, Vector3(-80, 0, 0), {"chill_time": 10.0, "poison_time": 10.0}
	)
	await _frames()
	hud.bind(properties)
	for s in S.values():
		if hud.is_status_visible(s):
			(
				assert_bool(false)
				. override_failure_message("HUD: nothing shown without states (%s)" % S.keys()[s])
				. is_true()
			)
	(
		assert_bool(hud._timer.is_stopped())
		. override_failure_message("HUD: no update timer while nothing is active")
		. is_true()
	)
	properties.apply_element(E.COLD, 0.5)
	(
		assert_bool(
			(
				hud.is_status_visible(S.CHILLED)
				and !hud.is_status_active(S.CHILLED)
				and is_equal_approx(hud.get_status_value(S.CHILLED), 0.5)
			)
		)
		. override_failure_message("HUD: cold buildup shows dimmed chill icon with half bar")
		. is_true()
	)
	(
		assert_bool(!hud._timer.is_stopped())
		. override_failure_message("HUD: update timer runs while levels are non-zero")
		. is_true()
	)
	(
		assert_bool(!hud.is_overlay_visible())
		. override_failure_message("HUD: no overlay for buildup only")
		. is_true()
	)
	properties.apply_element(E.COLD, 0.5)
	(
		assert_bool(hud.is_status_active(S.CHILLED))
		. override_failure_message("HUD: chilled icon active")
		. is_true()
	)
	(
		assert_bool(hud.get_overlay_status() == S.CHILLED and hud.is_overlay_visible())
		. override_failure_message("HUD: chill overlay")
		. is_true()
	)
	var v0 := hud.get_status_value(S.CHILLED)
	await _wait(0.6)
	(
		assert_bool(hud.get_status_value(S.CHILLED) < v0)
		. override_failure_message(
			(
				"HUD: chill bar follows the decaying level: %.2f -> %.2f"
				% [v0, hud.get_status_value(S.CHILLED)]
			)
		)
		. is_true()
	)
	properties.apply_element(E.POISON, 1.0)
	(
		assert_bool(hud.is_status_active(S.POISON) and hud.get_overlay_status() == S.POISON)
		. override_failure_message("HUD: poison icon, poison overlay beats chill")
		. is_true()
	)
	properties.cure_poison()
	properties.apply_element(E.FIRE, 3.0)  # melts the chill and ignites
	(
		assert_bool(hud.is_status_active(S.FIRE) and !hud.is_status_visible(S.CHILLED))
		. override_failure_message("HUD: fire icon, chill gone")
		. is_true()
	)
	(
		assert_bool(
			(
				hud.get_overlay_status() == S.FIRE
				and is_equal_approx(hud.get_status_value(S.FIRE), 1.0)
			)
		)
		. override_failure_message("HUD: fire overlay, full bar for a fire without fuel")
		. is_true()
	)
	properties.apply_element(E.WATER, 1.0)
	(
		assert_bool(!hud.is_status_visible(S.FIRE) and hud.is_status_active(S.WET))
		. override_failure_message("HUD: doused -> fire hidden, wet shown")
		. is_true()
	)
	await _wait(0.45)
	(
		assert_bool(!hud.is_overlay_visible() and hud.get_overlay_status() == -1)
		. override_failure_message("HUD: overlay fades out and hides")
		. is_true()
	)
	properties.apply_element(E.COLD, 1.0)
	(
		assert_bool(
			(
				properties.is_frozen
				and hud.is_status_active(S.FROZEN)
				and !hud.is_status_visible(S.WET)
				and !hud.is_status_visible(S.CHILLED)
			)
		)
		. override_failure_message("HUD: frozen icon replaces wet and chill")
		. is_true()
	)
	(
		assert_bool(hud.get_overlay_status() == S.FROZEN)
		. override_failure_message("HUD: frozen overlay")
		. is_true()
	)
	properties.reduce_element(E.COLD, 0.5)
	await _wait(0.15)
	(
		assert_bool(absf(hud.get_status_value(S.FROZEN) - 0.5) < 0.05)
		. override_failure_message(
			"HUD: frozen bar shows the remaining ice: %.2f" % hud.get_status_value(S.FROZEN)
		)
		. is_true()
	)
	properties.thaw()
	(
		assert_bool(!hud.is_status_visible(S.FROZEN) and hud.is_status_active(S.WET))
		. override_failure_message("HUD: thawed -> wet again")
		. is_true()
	)
	# Stun flash through actor elements
	var c := _make_properties(F.CONDUCTIVE, Vector3(-85, 0, 0), {}, true)
	await _frames()
	hud.bind(c, _actor_of(c))
	c.apply_element(E.SHOCK, 1.0)
	(
		assert_bool(
			(
				hud.is_status_active(S.SHOCK)
				and hud.get_overlay_status() == S.SHOCK
				and hud.is_overlay_visible()
			)
		)
		. override_failure_message("HUD: shock icon and stun flash")
		. is_true()
	)
	await _wait(0.8)
	(
		assert_bool(!hud.is_overlay_visible())
		. override_failure_message("HUD: stun flash ends")
		. is_true()
	)


func test_player_hud_binds_to_its_properties() -> void:
	var player := await _world.spawn_player(Vector3(0, 1, 0))
	var fp_hud := player.player_hud as CogitoPlayerHudManager
	(
		assert_bool(
			(
				fp_hud != null
				and fp_hud.element_status_hud != null
				and fp_hud.element_status_hud.properties == player.cogito_properties
			)
		)
		. override_failure_message("player HUD element status bound to the player's properties")
		. is_true()
	)

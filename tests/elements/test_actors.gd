extends Node3D
## E4a: elements on the player, NPCs and HUD (CogitoActorElements, CogitoPlayerAdvanced, CogitoNPC panic, CogitoElementStatusHud).

const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
const PLAYER := preload("res://addons/cogito/PackedScenes/cogito_player_advanced.tscn")
const NPC := preload("res://addons/cogito/CogitoNPC/cogito_npc.tscn")
const HUD := preload("res://addons/cogito/Components/UI/UI_ElementStatus.tscn")
const E = CogitoProperties.Element
const F = CogitoProperties.ElementalProperties
const S = CogitoElementStatusHud.Status
var fails := 0

class Holder extends StaticBody3D:
	signal damage_received(amount)
	var cogito_properties : CogitoProperties
	var taken := 0.0
	func _init():
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3.ONE * 0.5
		shape.shape = box
		add_child(shape)
		damage_received.connect(func(a, _s = null, _d = Vector3.ZERO, _p = Vector3.ZERO): taken += a)

class FakeItem extends InventoryItemPD:
	var used := 0
	func use(_target) -> bool:
		used += 1
		return false

class Actor extends Node3D:
	func can_act() -> bool:
		return false

func make(flags: int, pos: Vector3, setup := Callable(), with_actor := false) -> CogitoProperties:
	var h := Holder.new()
	h.position = pos
	var p : CogitoProperties = PROPS.instantiate()
	p.elemental_properties = flags
	p.is_logging = false
	if setup.is_valid():
		setup.call(p)
	h.add_child(p)
	h.cogito_properties = p
	if with_actor:
		var a := CogitoActorElements.new()
		a.name = "CogitoActorElements"
		h.add_child(a)
	add_child(h)
	return p

func actor_of(p: CogitoProperties) -> CogitoActorElements:
	return p.get_parent().get_node("CogitoActorElements")

func check(cond: bool, msg: String):
	if !cond:
		fails += 1
		print("FAIL: ", msg)
	else:
		print("ok: ", msg)

func wait(sec: float):
	await get_tree().create_timer(sec).timeout

func frames(n := 2):
	for i in n: await get_tree().process_frame

func physics_frames(n := 2):
	for i in n: await get_tree().physics_frame

func flat_speed(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


func _ready():
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(400, 1, 400)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0, -0.5, 0)
	add_child(floor_body)
	await frames()
	await test_actor_elements()
	await test_player()
	await test_cold_zone()
	await test_npc()
	await test_hud()
	Engine.time_scale = 1.0
	print("RESULT fails=", fails)
	get_tree().quit()


func test_actor_elements() -> void:
	# --- Chill and freeze
	var p := make(0, Vector3(-50, 0, 0), func(p): p.chill_time = 60.0; p.freeze_time = 60.0, true)
	await frames()
	var a := actor_of(p)
	check(a.properties == p and a.speed_multiplier == 1.0 and a.can_jump() and a.can_act(), "actor elements found sibling properties, normal by default")
	var changes := []
	a.movement_changed.connect(func(m): changes.append(m))
	p.apply_element(E.COLD, 1.0)
	check(p.is_chilled and is_equal_approx(a.speed_multiplier, 0.6) and changes == [0.6], "chilled -> speed 0.6, movement_changed")
	check(a.can_jump() and a.can_act(), "chilled actor can still jump and act")
	p.apply_element(E.WATER, 1.0)
	p.apply_element(E.COLD, 1.0)
	check(p.is_frozen and a.speed_multiplier == 0.0 and !a.can_jump(), "frozen -> speed 0, can't jump")
	check(!a.can_act(), "frozen blocks actions (frozen_blocks_actions)")
	a.frozen_blocks_actions = false
	check(a.can_act(), "frozen_blocks_actions off -> can act")
	a.frozen_blocks_actions = true
	var before := p.get_element_level(E.COLD)
	a.struggle()
	check(is_equal_approx(before - p.get_element_level(E.COLD), 0.2), "struggle removes 0.2 COLD")
	var presses := 1
	while p.is_frozen and presses < 20:
		a.struggle()
		presses += 1
	check(!p.is_frozen and p.is_wet and presses <= 7, "struggling thaws after %d presses, actor wet again" % presses)
	check(a.speed_multiplier == 1.0 and a.can_jump(), "thawed actor moves normally")
	check(!a.struggle(), "struggle() does nothing when not frozen")

	# --- Shock stun
	var s := make(F.CONDUCTIVE, Vector3(-55, 0, 0), Callable(), true)
	await frames()
	var sa := actor_of(s)
	var stun_events := [0, 0]
	sa.stunned.connect(func(): stun_events[0] += 1)
	sa.stun_ended.connect(func(): stun_events[1] += 1)
	s.apply_element(E.SHOCK, 1.0)
	check(sa.is_stunned and !sa.can_act() and !sa.can_jump() and sa.speed_multiplier == 0.0, "SHOCK stuns: can't act, jump or move")
	await wait(0.65)
	check(!sa.is_stunned and sa.can_act() and sa.speed_multiplier == 1.0 and stun_events == [1, 1], "stun ends after ~0.5 s")
	s.apply_element(E.SHOCK, 0.5)
	check(!sa.is_stunned, "second SHOCK within cooldown doesn't stun")
	await wait(1.6)
	check(!sa.is_processing(), "actor elements stop processing when idle")
	s.apply_element(E.SHOCK, 0.5)
	check(sa.is_stunned and stun_events[0] == 2, "SHOCK after cooldown stuns again")
	await wait(0.65)
	# SHOCK damage stuns even when the buildup does nothing (dry, non-conductive actor).
	var d := make(0, Vector3(-60, 0, 0), Callable(), true)
	await frames()
	var da := actor_of(d)
	check(d.apply_element(E.SHOCK, 1.0) == 0.0 and !da.is_stunned, "dry actor gets no SHOCK buildup")
	CogitoProperties.deal_elemental_damage(d.get_parent(), 5.0, E.SHOCK)
	check(da.is_stunned, "SHOCK damage stuns")

	# --- Item use blocked when the owner can't act
	var inv := CogitoInventory.new()
	var item := FakeItem.new()
	var slot := InventorySlotPD.new()
	slot.inventory_item = item
	inv.inventory_slots = [slot]
	var owner_actor := Actor.new()
	add_child(owner_actor)
	inv.owner = owner_actor
	inv.use_slot_data(0)
	check(item.used == 0, "inventory: owner that can't act uses no items")
	inv.owner = self
	inv.use_slot_data(0)
	check(item.used == 1, "inventory: owner without can_act() still uses items")


func test_player() -> void:
	var player : CogitoPlayerAdvanced = PLAYER.instantiate()
	player.position = Vector3(0, 1, 0)
	add_child(player)
	await physics_frames(10)
	var props := CogitoProperties.get_properties_of(player)
	check(props != null and props == player.cogito_properties and props.get_parent() == player, "player has CogitoProperties found via get_properties_of")
	check(player.actor_elements != null and player.actor_elements.properties == props, "player has CogitoActorElements")
	check(props.heat_radius == 0.0 and props.fuel == 4.0 and props.burn_out_result == CogitoProperties.BurnOutResult.NOTHING, "player actor settings: no heat, fuel 4, burns out to nothing")
	var health : CogitoAttribute = player.player_attributes["health"]
	health.value_current = health.value_max
	var typed := []
	player.elemental_damage_received.connect(func(amount, element, _src): typed.append([amount, element]))

	# Burning
	var neighbour := make(F.FLAMMABLE, Vector3(0.9, 0.5, 0))
	await frames()
	var h0 := health.value_current
	props.apply_element(E.FIRE, 1.0)
	check(props.is_on_fire, "FIRE ignites the player")
	check(props.get_node_or_null("HeatSensor") == null, "burning player radiates no heat (heat_radius 0)")
	await wait(2.2)
	check(health.value_current < h0 - 5.0, "burning player loses health: %s -> %s" % [h0, health.value_current])
	check(typed.size() > 0 and typed[0][1] == E.FIRE, "player got typed FIRE damage")
	check(!neighbour.is_on_fire, "burning player doesn't ignite a flammable body next to it")
	Engine.time_scale = 4.0
	await wait(2.5)
	Engine.time_scale = 1.0
	check(!props.is_on_fire, "player fire goes out by itself after its fuel")
	check(props.elemental_properties & F.FLAMMABLE, "player stays flammable after burning out")
	props.apply_element(E.FIRE, 1.0)
	check(props.is_on_fire, "player can catch fire again")
	props.apply_element(E.WATER, 1.0)
	check(!props.is_on_fire and props.is_wet, "water douses and wets the player")

	# Wet player
	props.apply_element(E.FIRE, 1.0)
	check(!props.is_on_fire, "wet player doesn't ignite")
	props.apply_element(E.WATER, 1.0)
	health.value_current = health.value_max
	var h1 := health.value_current
	var dealt := CogitoProperties.deal_elemental_damage(player, 10.0, E.SHOCK)
	check(is_equal_approx(dealt, 15.0) and is_equal_approx(h1 - health.value_current, 15.0), "wet player takes x1.5 SHOCK: %s" % (h1 - health.value_current))
	check(player.actor_elements.is_stunned and !player.can_act(), "SHOCK stuns the player")
	await wait(0.6)
	check(player.can_act(), "player can act again after the stun")
	props.make_dry()

	# Heat from a burning neighbour ignites the player (default heat_collision_mask includes the player layer).
	await wait(1.6) # Stun cooldown
	var grass := make(F.FLAMMABLE, Vector3(1.0, 0.5, 0), func(p): p.heat_radius = 2.0; p.heat_per_second = 3.0)
	await frames()
	grass.set_on_fire()
	var t := 0.0
	while t < 3.0 and !props.is_on_fire:
		await get_tree().process_frame
		t += get_process_delta_time()
	check(props.is_on_fire, "burning grass with heat_radius ignites the player")
	grass.extinguish(false)
	props.extinguish(false)

	# Poison
	health.value_current = health.value_max
	var h2 := health.value_current
	props.apply_element(E.POISON, 1.0)
	check(props.is_poisoned, "player poisoned")
	await wait(2.2)
	check(health.value_current <= h2 - 3.9, "poison damages player health: %s" % (h2 - health.value_current))
	props.cure_poison()

	# Movement: the player reads speed_multiplier
	health.value_current = health.value_max
	await physics_frames(5)
	Input.action_press("forward")
	await wait(0.8)
	var v_normal := flat_speed(player.velocity)
	props.apply_element(E.COLD, 1.0)
	check(props.is_chilled, "player chilled")
	await wait(0.8)
	var v_chilled := flat_speed(player.velocity)
	check(v_normal > 3.0 and absf(v_chilled - v_normal * 0.6) < 0.4, "chilled player walks at ~0.6 speed: %.2f -> %.2f" % [v_normal, v_chilled])
	props.apply_element(E.WATER, 1.0)
	props.apply_element(E.COLD, 1.0)
	check(props.is_frozen, "player frozen")
	await wait(0.8)
	check(flat_speed(player.velocity) < 0.2, "frozen player doesn't move: %.2f" % flat_speed(player.velocity))
	check(!player._can_jump(), "frozen player can't jump")
	check(!player.can_act(), "frozen player can't act")
	Input.action_release("forward")
	# Struggle: new movement presses
	var cold := props.get_element_level(E.COLD)
	var ev := InputEventAction.new()
	ev.action = &"left"
	ev.pressed = true
	player.on_input(ev)
	check(props.get_element_level(E.COLD) < cold - 0.1, "movement press while frozen struggles")
	var held := props.get_element_level(E.COLD)
	var echo := InputEventAction.new()
	echo.action = &"left"
	echo.pressed = false
	player.on_input(echo)
	check(is_equal_approx(props.get_element_level(E.COLD), held), "key release doesn't struggle")
	var n := 1
	while props.is_frozen and n < 20:
		player.on_input(ev)
		n += 1
	check(!props.is_frozen and props.is_wet, "player struggled free after %d presses, wet again" % n)
	player.set_meta("test_done", true)


func cold_zone(pos: Vector3) -> CogitoElementArea:
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
	add_child(area)
	return area


func test_cold_zone() -> void:
	# --- A plain object keeps the old behaviour: cold in the zone refreshes its freeze.
	var obj_area := cold_zone(Vector3(-120, 0, 0))
	var o := make(0, Vector3(-120, 0, 0), func(p): p.freeze_time = 60.0)
	check(o.frozen_absorbs_cold and !o.freeze_immune, "frozen_absorbs_cold defaults to true, freeze_immune to false")
	await frames()
	o.apply_element(E.WATER, 1.0)
	await wait(1.0)
	check(o.is_frozen, "object frozen in the cold zone")
	o.reduce_element(E.COLD, 0.5)
	var lowered := o.get_element_level(E.COLD)
	await wait(0.6)
	check(o.get_element_level(E.COLD) > lowered + 0.5, "object in a cold zone refreshes its freeze (old behaviour): %.2f -> %.2f" % [lowered, o.get_element_level(E.COLD)])
	obj_area.queue_free()
	o.get_parent().queue_free()

	# --- The player frozen inside a cold zone can struggle free.
	var player : CogitoPlayerAdvanced = PLAYER.instantiate()
	player.position = Vector3(100, 1, 0)
	add_child(player)
	await physics_frames(10)
	var props := player.cogito_properties
	var actor := player.actor_elements
	check(!props.frozen_absorbs_cold, "player: frozen_absorbs_cold is off (set by CogitoActorElements)")
	var zone := cold_zone(Vector3(100, 1, 0))
	props.apply_element(E.WATER, 1.0)
	await wait(1.0)
	check(props.is_frozen, "player frozen by the cold zone")
	await wait(0.5)
	check(props.is_frozen and props.get_element_level(E.COLD) <= props.buildup_threshold + 0.001, "cold zone doesn't refresh the player's freeze: %.2f" % props.get_element_level(E.COLD))
	check(InputRouter.is_input_active(player), "player owns the input")
	var presses := 0
	while props.is_frozen and presses < 12:
		var down := InputEventAction.new()
		down.action = &"forward"
		down.pressed = true
		Input.parse_input_event(down)
		await frames(2)
		var up := InputEventAction.new()
		up.action = &"forward"
		up.pressed = false
		Input.parse_input_event(up)
		await frames(2)
		presses += 1
	check(!props.is_frozen and presses <= 6, "player struggled free in %d presses inside the cold zone" % presses)
	check(zone.enabled, "the cold zone stayed on")
	# Immunity: chilled, not frozen again
	await wait(1.2)
	check(!props.is_frozen and props.is_chilled and props.freeze_immune, "after thawing: chilled and freeze-immune, not frozen again")
	check(is_equal_approx(actor.speed_multiplier, actor.chilled_speed_multiplier), "walking out chilled at x0.6")
	await wait(2.5)
	check(!props.freeze_immune, "freeze immunity ended after refreeze_immunity_time")
	await wait(0.5)
	check(props.is_frozen, "player can be frozen again after the immunity")
	zone.queue_free()
	player.queue_free()
	await frames(2)


func test_npc() -> void:
	Engine.time_scale = 1.0
	var npc : CogitoNPC = NPC.instantiate()
	npc.position = Vector3(100, 0.1, 100)
	add_child(npc)
	await physics_frames(10)
	var props := npc.cogito_properties
	check(npc.actor_elements != null and props != null and props.get_parent() == npc and npc.actor_elements.properties == props, "NPC has CogitoProperties and CogitoActorElements")
	check(CogitoProperties.get_properties_of(npc) == props, "get_properties_of finds the NPC's properties")
	check(npc.current_behaviour == CogitoNPC.BehaviourState.Idle, "NPC starts idle")
	check(npc.can_act(), "NPC can act normally")

	# Burning NPC panics
	var start := npc.global_position
	props.apply_element(E.FIRE, 1.0)
	await physics_frames(2)
	check(props.is_on_fire and npc.is_panicking(), "burning NPC panics")
	check(!npc.can_act(), "panicking NPC can't attack")
	npc.state_chart.send_event("chase")
	npc.state_chart.send_event("alerted")
	await physics_frames(2)
	check(npc.is_panicking(), "detection events don't end the panic")
	await wait(1.0)
	var moved := Vector2(npc.global_position.x - start.x, npc.global_position.z - start.z).length()
	check(moved > 1.0, "panicking NPC runs around: %.2f m" % moved)
	check(is_equal_approx(npc.move_speed, npc.sprint_speed), "panic runs at sprint speed")
	props.apply_element(E.WATER, 1.0)
	await physics_frames(2)
	check(!props.is_on_fire and npc.current_behaviour == CogitoNPC.BehaviourState.Idle, "fire out -> NPC back to idle")
	check(npc.can_act(), "NPC can act again after the panic")
	props.make_dry()

	# Chilled NPC moves slower
	props.apply_element(E.COLD, 1.0)
	check(props.is_chilled and is_equal_approx(npc.get_speed_multiplier(), 0.6), "chilled NPC speed multiplier 0.6")
	npc.move_speed = 2.0
	var target := npc.global_position + Vector3(20, 0, 0)
	for i in 30:
		await get_tree().physics_frame
		npc.move_npc_towards(target, get_physics_process_delta_time())
	check(absf(flat_speed(npc.velocity) - 1.2) < 0.1, "chilled NPC moves at 0.6 x move_speed: %.2f" % flat_speed(npc.velocity))

	# Frozen NPC can't move or attack and struggles free by itself
	props.apply_element(E.WATER, 1.0)
	props.apply_element(E.COLD, 1.0)
	check(props.is_frozen and npc.get_speed_multiplier() == 0.0 and !npc.can_act(), "frozen NPC can't move or attack")
	for i in 30:
		await get_tree().physics_frame
		npc.move_npc_towards(target, get_physics_process_delta_time())
	check(flat_speed(npc.velocity) < 0.05, "frozen NPC stands still")
	var thawed_at := -1.0
	var t := 0.0
	while t < 8.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		if !props.is_frozen:
			thawed_at = t
			break
	check(thawed_at > 0.0 and thawed_at < 5.0 and props.is_wet, "frozen NPC struggles free by itself in %.1f s" % thawed_at)

	# Stunned NPC
	await wait(0.1)
	CogitoProperties.deal_elemental_damage(npc, 0.5, E.SHOCK)
	check(npc.actor_elements.is_stunned and !npc.can_act() and npc.get_speed_multiplier() == 0.0, "SHOCK stuns the NPC")
	await wait(0.6)
	check(npc.can_act(), "NPC recovers from the stun")

	# Damage ticks of its own states don't alert the NPC
	props.apply_element(E.POISON, 1.0)
	await wait(1.2)
	check(npc.current_behaviour == CogitoNPC.BehaviourState.Idle, "poison ticks don't alert the NPC")
	props.cure_poison()


func test_hud() -> void:
	var hud : CogitoElementStatusHud = HUD.instantiate()
	add_child(hud)
	await frames()
	check(!hud.is_overlay_visible() and hud.mouse_filter == Control.MOUSE_FILTER_IGNORE and hud.overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE, "HUD: unbound, overlay hidden, ignores the mouse")
	var p := make(F.FLAMMABLE, Vector3(-80, 0, 0), func(p): p.chill_time = 10.0; p.poison_time = 10.0)
	await frames()
	hud.bind(p)
	for s in S.values():
		if hud.is_status_visible(s):
			check(false, "HUD: nothing shown without states (%s)" % S.keys()[s])
	check(hud._timer.is_stopped(), "HUD: no update timer while nothing is active")
	p.apply_element(E.COLD, 0.5)
	check(hud.is_status_visible(S.CHILLED) and !hud.is_status_active(S.CHILLED) and is_equal_approx(hud.get_status_value(S.CHILLED), 0.5), "HUD: cold buildup shows dimmed chill icon with half bar")
	check(!hud._timer.is_stopped(), "HUD: update timer runs while levels are non-zero")
	check(!hud.is_overlay_visible(), "HUD: no overlay for buildup only")
	p.apply_element(E.COLD, 0.5)
	check(hud.is_status_active(S.CHILLED), "HUD: chilled icon active")
	check(hud.get_overlay_status() == S.CHILLED and hud.is_overlay_visible(), "HUD: chill overlay")
	var v0 := hud.get_status_value(S.CHILLED)
	await wait(0.6)
	check(hud.get_status_value(S.CHILLED) < v0, "HUD: chill bar follows the decaying level: %.2f -> %.2f" % [v0, hud.get_status_value(S.CHILLED)])
	p.apply_element(E.POISON, 1.0)
	check(hud.is_status_active(S.POISON) and hud.get_overlay_status() == S.POISON, "HUD: poison icon, poison overlay beats chill")
	p.cure_poison()
	p.apply_element(E.FIRE, 3.0) # melts the chill and ignites
	check(hud.is_status_active(S.FIRE) and !hud.is_status_visible(S.CHILLED), "HUD: fire icon, chill gone")
	check(hud.get_overlay_status() == S.FIRE and is_equal_approx(hud.get_status_value(S.FIRE), 1.0), "HUD: fire overlay, full bar for a fire without fuel")
	p.apply_element(E.WATER, 1.0)
	check(!hud.is_status_visible(S.FIRE) and hud.is_status_active(S.WET), "HUD: doused -> fire hidden, wet shown")
	await wait(0.45)
	check(!hud.is_overlay_visible() and hud.get_overlay_status() == -1, "HUD: overlay fades out and hides")
	p.apply_element(E.COLD, 1.0)
	check(p.is_frozen and hud.is_status_active(S.FROZEN) and !hud.is_status_visible(S.WET) and !hud.is_status_visible(S.CHILLED), "HUD: frozen icon replaces wet and chill")
	check(hud.get_overlay_status() == S.FROZEN, "HUD: frozen overlay")
	p.reduce_element(E.COLD, 0.5)
	await wait(0.15)
	check(absf(hud.get_status_value(S.FROZEN) - 0.5) < 0.05, "HUD: frozen bar shows the remaining ice: %.2f" % hud.get_status_value(S.FROZEN))
	p.thaw()
	check(!hud.is_status_visible(S.FROZEN) and hud.is_status_active(S.WET), "HUD: thawed -> wet again")
	# Stun flash through actor elements
	var c := make(F.CONDUCTIVE, Vector3(-85, 0, 0), Callable(), true)
	await frames()
	hud.bind(c, actor_of(c))
	c.apply_element(E.SHOCK, 1.0)
	check(hud.is_status_active(S.SHOCK) and hud.get_overlay_status() == S.SHOCK and hud.is_overlay_visible(), "HUD: shock icon and stun flash")
	await wait(0.8)
	check(!hud.is_overlay_visible(), "HUD: stun flash ends")
	# Bound player: the HUD in the player scene binds itself
	for child in get_children():
		if child is CogitoPlayerAdvanced:
			var fp_hud := child.player_hud as CogitoPlayerHudManager
			check(fp_hud != null and fp_hud.element_status_hud != null and fp_hud.element_status_hud.properties == child.cogito_properties, "player HUD element status bound to the player's properties")

extends "memory_session_suite.gd"

const Arena := preload("process_arena.tscn")
const ELEMENT := CogitoProperties.Element
const Dart := preload("res://addons/cogito/InventoryPD/Items/Cogito_Dart_Poison.tres")
const Profile := preload("res://addons/cogito/Networking/net_wield_profile.gd")
const STATUS := CogitoElementStatusHud.Status

var _previous: Node
var _level_root: Node3D
var _server: Facade
var _owner: Facade
var _actor: CogitoPlayerAdvanced


func before_test() -> void:
	_previous = get_tree().current_scene
	_level_root = Arena.instantiate()
	get_tree().root.add_child(_level_root)
	get_tree().current_scene = _level_root
	_server = _branch(1)
	_server.start_server({"save_dir": "user://net/mp7", "friendly_fire": false})
	_server.player_world.bind_level(_level_root, Transform3D.IDENTITY, "arena")
	_owner = _observer(2)
	_actor = _server.player_world.avatar_for(_owner.local_player_id()).actor
	await _ticks(10)


func after_test() -> void:
	super.after_test()
	get_tree().current_scene = _previous
	_level_root.free()


func _props(branch: Facade, path: String) -> CogitoProperties:
	return branch.player_world.active_level().get_node(path + "/CogitoProperties")


func test_switch_and_reset_rebind_destroyed_grass_and_body() -> void:
	var stand: Node3D = _level_root.get_node("FireStand")
	var mirror: Node3D = _owner.player_world.active_level().get_node("FireStand")
	_actor.position = stand.position + Vector3(-0.6, 0.91, 2.5)
	await _ticks(3)
	_use(_owner, "FireStand/Console/CampfireSwitch/BasicInteraction")
	await _ticks(8)
	assert_bool(mirror.get_node("Campfire").enabled).is_true()
	assert_bool(mirror.get_node("Campfire/Flames").visible).is_true()
	assert_bool(mirror.get_node("Campfire")._timer.is_stopped()).is_true()
	var exits := []
	mirror.get_node("Grass1").tree_exiting.connect(func(): exits.append(true))
	var grass := _props(_server, "FireStand/Grass1")
	grass.set_on_fire()
	grass.burn_out()
	await _ticks(8)
	assert_array(exits).has_size(1)
	assert_bool(mirror.has_node("Grass1")).is_false()
	var late := _observer(3)
	await _ticks(8)
	assert_bool(late.player_world.active_level().has_node("FireStand/Grass1")).is_false()
	var previous_body: int = mirror.get_node("CrateA").get_instance_id()
	_actor.position = stand.position + Vector3(0.6, 0.91, 2.5)
	await _ticks(3)
	_use(_owner, "FireStand/Console/ResetButton/BasicInteraction")
	await _ticks(8)
	assert_array(exits).has_size(1)
	assert_int(mirror.get_node("CrateA").get_instance_id()).is_not_equal(previous_body)
	for peer in [_server, _owner, late]:
		var restored := _props(peer, "FireStand/Grass1")
		assert_bool(restored.is_on_fire).is_false()
		var world: Variant = peer.player_world.world
		assert_str(world.entities.id_for(restored.get_parent())).is_not_empty()
		assert_bool(world.is_removed(world.entities.id_for(restored.get_parent()))).is_false()


func test_heat_spreads_outside_interest_and_reentry_is_silent() -> void:
	var path := "FireStand/Grass2"
	var remote := _props(_owner, path)
	var ignitions := []
	remote.has_ignited.connect(func(): ignitions.append(1))
	_actor.position = Vector3(200, 2, 0)
	await _ticks(9)
	var source := _props(_server, "FireStand/Grass1")
	var target := _props(_server, path)
	source.set_on_fire()
	for frame in 120:
		if target.is_on_fire:
			break
		await _ticks(1)
	assert_bool(target.is_on_fire).is_true()
	assert_bool(remote.is_on_fire).is_false()
	var crate := _props(_server, "FireStand/CrateA")
	crate.set_on_fire()
	crate.burn_out()
	_actor.position = Vector3.ZERO
	await _ticks(10)
	assert_bool(_props(_owner, "FireStand/CrateA").is_charred).is_true()
	assert_bool(remote.is_on_fire).is_true()
	assert_array(ignitions).is_empty()
	assert_bool(remote.damage_timer.is_stopped()).is_true()
	assert_bool(remote.has_node("HeatSensor")).is_false()
	assert_float(remote.fuel_remaining).is_less(target.fuel)
	assert_int(remote.replica_deadlines[0]).is_greater(0)
	assert_bool(remote.spawned_effects.any(_is_fire_effect)).is_true()


func test_water_extinguishes_and_wet_target_conducts_only_on_authority() -> void:
	var local := _props(_server, "FireStand/CrateB")
	var remote := _props(_owner, "FireStand/CrateB")
	local.set_on_fire()
	await _ticks(8)
	assert_bool(remote.is_on_fire).is_true()
	local.apply_element(ELEMENT.WATER, 2)
	local.apply_element(ELEMENT.SHOCK, 2)
	await _ticks(8)
	assert_bool(remote.is_on_fire).is_false()
	assert_bool(remote.is_wet and remote.is_electric).is_true()
	assert_float(remote.apply_element(ELEMENT.COLD, 2)).is_zero()
	assert_bool(remote.is_frozen).is_false()
	assert_bool(remote.is_processing()).is_false()
	assert_bool(remote.reaction_timer.is_stopped()).is_true()


func test_owner_hud_movement_lock_and_authoritative_struggle() -> void:
	var observer := _observer(3)
	var avatar := _owner.local_player() as CogitoPlayerAdvanced
	var other := observer.player_world.avatar_for(_owner.local_player_id()).actor
	var huds := avatar.find_children("*", "CogitoElementStatusHud", true, false)
	var hud := huds[0] as CogitoElementStatusHud
	assert_array(other.find_children("*", "CogitoElementStatusHud", true, false)).is_empty()
	assert_array(_actor.find_children("*", "CogitoElementStatusHud", true, false)).is_empty()
	_actor.cogito_properties.make_wet()
	_actor.cogito_properties.apply_element(ELEMENT.COLD, 1.1)
	await _ticks(10)
	for player: CogitoPlayerAdvanced in [_actor, avatar, other]:
		assert_bool(player.is_movement_locked_by_elements()).is_true()
		assert_bool(player.can_act()).is_false()
	assert_bool(hud.is_status_active(STATUS.FROZEN)).is_true()
	assert_int(hud.get_overlay_status()).is_equal(STATUS.FROZEN)
	assert_bool(avatar.actor_elements.struggle()).is_false()
	for press in 6:
		_actor.actor_elements.struggle()
	await _ticks(8)
	assert_bool(_actor.is_movement_locked_by_elements()).is_false()
	assert_bool(avatar.is_movement_locked_by_elements()).is_false()
	assert_bool(hud.is_status_active(STATUS.FROZEN)).is_false()


func test_poison_ticks_once_and_policy_receives_environment_provenance() -> void:
	var props := _actor.cogito_properties
	var remote := _owner.local_player()
	var hits := []
	var replica_hits := []
	var attackers := []
	var deny := [false]
	_server.player_world.death.damage_policy = func(
		attacker: String, _victim: String, source: Node
	):
		if source == _actor:
			attackers.append(attacker)
		return not deny[0]
	_actor.elemental_damage_received.connect(
		func(amount, element, _source):
			if element == ELEMENT.POISON:
				hits.append(amount)
	)
	remote.elemental_damage_received.connect(
		func(_amount, _element, _source): replica_hits.append(1)
	)
	props.apply_element(ELEMENT.POISON, 2)
	props.set_process(false)
	var hp: float = _actor.player_attributes.health.value_current
	props._process(2.0)
	props.set_process(false)
	assert_array(hits).is_equal([2.0, 2.0])
	assert_array(attackers).is_equal(["", ""])
	assert_float(_actor.player_attributes.health.value_current).is_equal(hp - 4)
	deny[0] = true
	props._process(1.0)
	props.set_process(false)
	await _ticks(8)
	assert_array(hits).has_size(2)
	assert_array(replica_hits).is_empty()
	assert_float(remote.player_attributes.health.value_current).is_equal(hp - 4)
	assert_float(CogitoProperties.deal_elemental_damage(remote, 9, ELEMENT.POISON)).is_zero()


func test_npc_panic_and_freeze_are_only_simulated_by_server() -> void:
	var npc: CogitoNPC = _level_root.get_node("Guard")
	var remote: CogitoNPC = _owner.player_world.active_level().get_node("Guard")
	var reactions := []
	remote.cogito_properties.has_ignited.connect(func(): reactions.append(1))
	npc.cogito_properties.set_on_fire()
	await _ticks(12)
	assert_bool(npc.is_panicking()).is_true()
	assert_bool(remote.cogito_properties.is_on_fire).is_true()
	assert_bool(remote.cogito_properties.spawned_effects.size() > 0).is_true()
	assert_bool(remote.state_chart._frozen).is_true()
	npc.cogito_properties.apply_element(ELEMENT.WATER, 2.0)
	npc.cogito_properties.apply_element(ELEMENT.COLD, 2.0)
	await _ticks(12)
	assert_bool(npc.actor_elements.is_movement_locked()).is_true()
	assert_bool(remote.actor_elements.is_movement_locked()).is_true()
	assert_array(reactions).is_empty()


func test_protected_player_hit_rejects_dart_damage_and_optional_exposure() -> void:
	var observer := _observer(3)
	var victim := _server.player_world.avatar_for(observer.local_player_id()).actor
	_actor.position = Vector3(-20, 0.91, 5)
	victim.position = Vector3(-20, 0.91, 1)
	victim.cogito_properties.material_properties = CogitoProperties.MaterialProperties.SOFT
	var hp: float = victim.player_attributes.health.value_current
	var hits := []
	victim.elemental_damage_received.connect(func(amount, _kind, _src): hits.append(amount))
	var projectiles := _server.player_world.projectiles
	var impacts := []
	projectiles.ended.connect(func(_id, impact): impacts.append(impact))
	var stack := InventorySlotPD.new()
	stack.inventory_item = Dart
	var profile := Profile.new()
	profile.configure(Dart)
	var shooter := _owner.local_player_id()
	var life := _server.player_world.avatar_for(shooter).lifetime
	await _ticks(2)
	for expose: bool in [false, true]:
		if expose:
			projectiles.element_contact_policy = func(target, instigator, allowed):
				return target == victim and instigator == _actor and not allowed
		var aim := Transform3D(Basis.IDENTITY, _actor.position + Vector3.UP * 0.45)
		assert_bool(projectiles.launch(shooter, life, stack, profile, aim)).is_true()
		await _ticks(16)
		assert_bool(victim.cogito_properties.is_poisoned).is_equal(expose)
		assert_float(victim.player_attributes.health.value_current).is_equal(hp)
	assert_array(hits).is_empty()
	assert_array(impacts).is_equal([true, true])
	await _ticks(70)
	assert_array(hits).is_equal([2.0])


func test_drop_ball_and_reset_restore_authoritative_body() -> void:
	var stand: Node3D = _level_root.get_node("ColdStand")
	var mirror: Node3D = _owner.player_world.active_level().get_node("ColdStand")
	_actor.position = stand.position + Vector3(-0.35, 0.91, 2.5)
	var start: Vector3 = mirror.get_node("Ball").global_position
	await _ticks(4)
	_use(_owner, "ColdStand/Console/DropButton/BasicInteraction")
	await _ticks(42)
	assert_bool(stand.get_node("Ball").freeze).is_false()
	assert_float(mirror.get_node("Ball").global_position.y).is_less(start.y - 0.3)
	_actor.position = stand.position + Vector3(1.0, 0.91, 2.5)
	await _ticks(4)
	_use(_owner, "ColdStand/Console/ResetButton/BasicInteraction")
	await _ticks(10)
	assert_bool(stand.get_node("Ball").freeze).is_true()
	assert_vector(mirror.get_node("Ball").global_position).is_equal_approx(
		start, Vector3.ONE * 0.04
	)


func _pool(branch: Facade) -> FluidArea3D:
	var water := FluidArea3D.new()
	water.name = "TestPool"
	water.position = Vector3(-29, 1, 12)
	water.collision_layer = 0
	water.collision_mask = 16
	water.shock_amount_per_second = 8.0
	water.shock_damage_per_second = 0.0
	var box := BoxShape3D.new()
	box.size = Vector3(5, 3, 3)
	var collider := CollisionShape3D.new()
	collider.shape = box
	water.add_child(collider)
	branch.player_world.active_level().add_child(water)
	branch.player_world.world.entities.register_runtime("test-pool", water)
	return water


func test_charged_swimming_volume_stuns_wet_player_until_server_unlocks() -> void:
	var second := _observer(3)
	var source := _server.player_world.avatar_for(second.local_player_id()).actor
	var water := _pool(_server)
	var mirror := _pool(_owner)
	_pool(second)
	_actor.position = water.position + Vector3.RIGHT
	source.position = water.position + Vector3.LEFT
	source.cogito_properties.make_wet()
	source.cogito_properties.make_electric()
	var local_actor := _owner.local_player()
	var local_stuns := []
	local_actor.actor_elements.stunned.connect(func(): local_stuns.append(1))
	for frame in 45:
		await _ticks(1)
		if local_actor.actor_elements.is_stunned:
			break
	assert_bool(water.is_electric and mirror.is_electric).is_true()
	assert_bool(_actor.cogito_properties.is_wet and _actor.cogito_properties.is_electric).is_true()
	(
		assert_bool(_actor.actor_elements.is_stunned and local_actor.actor_elements.is_stunned)
		. is_true()
	)
	assert_bool(mirror.monitoring).is_false()
	assert_bool(mirror._timer.is_stopped()).is_true()
	_actor.position += Vector3.RIGHT * 6
	await _ticks(44)
	assert_bool(local_actor.actor_elements.is_movement_locked()).is_false()
	assert_array(local_stuns).is_empty()


func test_continuous_levels_are_coalesced_and_settled_prop_is_quiet() -> void:
	var target := _props(_server, "FireStand/Grass4")
	var mirror := _props(_owner, "FireStand/Grass4")
	var updates := []
	mirror.replica_updated.connect(func(): updates.append(1))
	await _ticks(18)
	assert_array(updates).is_empty()
	for frame in 36:
		target.apply_element(ELEMENT.POISON, 0.02)
		await _ticks(1)
	assert_int(updates.size()).is_between(1, 7)
	var value := mirror.get_element_level(ELEMENT.POISON)
	assert_float(value * 32.0).is_equal(roundf(value * 32.0))
	target.cure_poison()
	await _ticks(9)
	updates.clear()
	await _ticks(18)
	assert_array(updates).is_empty()


func test_actor_destroy_burnout_uses_damage_veto_and_preserves_respawn_binding() -> void:
	var props := _actor.cogito_properties
	props.burn_out_result = CogitoProperties.BurnOutResult.DESTROY
	_server.player_world.death.damage_policy = func(_id, _victim, _source): return false
	props.set_on_fire()
	props.burn_out()
	assert_bool(_actor.is_dead).is_false()
	_server.player_world.death.damage_policy = Callable()
	props.set_on_fire()
	props.burn_out()
	await _ticks(8)
	assert_bool(_actor.is_dead).is_true()
	assert_bool(_owner.local_player().is_dead).is_true()
	assert_object(_server.player_world.avatar_for(_owner.local_player_id()).actor).is_same(_actor)


func _is_fire_effect(effect: Node) -> bool:
	return effect.get_meta(CogitoProperties.VFX_KIND_META) == &"fire"

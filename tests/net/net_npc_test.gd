extends "memory_session_suite.gd"

const Arena := preload("process_arena.tscn")
const BEHAVIOUR := CogitoNPC.BehaviourState

var _server: Facade
var _a: Facade
var _b: Facade
var _level_root: Node3D
var _previous: Node
var _guard: CogitoNPC
var _ada: CogitoPlayerAdvanced
var _ben: CogitoPlayerAdvanced


class CountingPolicy:
	extends CogitoNpcTargetPolicy
	var calls := 0

	func choose(npc: CogitoNPC, candidates: Dictionary, current: String) -> String:
		calls += 1
		return super.choose(npc, candidates, current)


class IgnorePolicy:
	extends CogitoNpcTargetPolicy
	var calls := 0

	func choose(_npc: CogitoNPC, _candidates: Dictionary, _current: String) -> String:
		calls += 1
		return ""


func before_test() -> void:
	_previous = get_tree().current_scene
	_level_root = Arena.instantiate()
	get_tree().root.add_child(_level_root)
	get_tree().current_scene = _level_root
	_server = _branch(1)
	_server.npc_target_policy = CountingPolicy.new()
	var directory := create_temp_dir("npcs-%d" % Time.get_ticks_usec())
	_server.start_server({"save_dir": directory, "friendly_fire": false})
	_server.player_world.bind_level(_level_root, Transform3D.IDENTITY, "arena")
	_guard = _level_root.get_node("Guard")
	_a = _observer(2)
	_b = _observer(3)
	_ada = _server.player_world.avatar_for(_a.local_player_id()).actor
	_ben = _server.player_world.avatar_for(_b.local_player_id()).actor
	await _ticks(6)


func after_test() -> void:
	super.after_test()
	get_tree().current_scene = _previous
	_level_root.free()


func _stage() -> void:
	_guard.rotation.y = 0
	_guard.sight_detection.buildup_to_investigation_rate = 60
	_guard.sight_detection.buildup_to_aggro_rate = 60
	_ada.position = Vector3(25, 0.91, 21)
	_ben.position = Vector3(31, 0.91, 21)


func test_replica_has_no_gameplay_and_death_is_silent_for_late_join() -> void:
	var replica: CogitoNPC = _a.player_world.active_level().get_node("Guard")
	assert_bool(replica.can_process()).is_false()
	assert_bool(replica.state_chart._frozen).is_true()
	assert_bool(replica.nav_agent.avoidance_enabled).is_false()
	assert_bool(replica.sight_detection.can_process()).is_false()
	for timer: Timer in replica.find_children("*", "Timer", true, false):
		assert_bool(timer.can_process()).is_false()
	assert_object(replica.perception).is_null()
	assert_bool(replica.health.network_frozen).is_true()
	var deaths: Array[int] = []
	_guard.health.death.connect(func(): deaths.append(1))
	_guard.damage_received.emit(25.0, _ada, Vector3.FORWARD, _guard.position)
	_guard.damage_received.emit(25.0, _ada, Vector3.FORWARD, _guard.position)
	await _ticks(12)
	assert_int(deaths.size()).is_equal(1)
	assert_bool(replica.network_state.dead).is_true()
	assert_bool(replica.visible).is_false()
	var id := _server.player_world.world.entities.id_for(_guard)
	assert_int(_a.player_world.world.revisions[id]).is_equal(
		_server.player_world.world.revisions[id]
	)
	var corpse := _server.player_world.world.entities.live_object("runtime:1") as RigidBody3D
	for tick in 240:
		if corpse.sleeping:
			break
		await _ticks(1)
	assert_bool(corpse.sleeping).is_true()
	var late := _observer(4)
	await _ticks(6)
	var late_guard: CogitoNPC = late.player_world.active_level().get_node("Guard")
	assert_bool(late_guard.network_state.dead).is_true()
	for branch in [_server, _a, _b, late]:
		var entities: Variant = branch.player_world.world.entities
		var proxy: Node3D = entities.live_object("runtime:1")
		assert_object(proxy).is_instanceof(CogitoBodyDrag)
		assert_float(proxy.global_position.distance_to(corpse.global_position)).is_less(0.04)
		assert_object(entities.live_object("runtime:2")).is_instanceof(CogitoObject)
		assert_object(entities.live_object("runtime:3")).is_null()


func test_global_policy_and_npc_override() -> void:
	assert_object(_guard.perception.policy).is_same(_server.npc_target_policy)
	assert_int((_server.npc_target_policy as CountingPolicy).calls).is_greater(0)
	var custom := IgnorePolicy.new()
	_guard.net_unbind()
	_guard.target_policy = custom
	_guard.net_bind_authority()
	_stage()
	await _ticks(15)
	assert_int(custom.calls).is_greater(0)
	assert_str(_guard.perception.target_id).is_empty()


func test_hidden_first_visible_second_search_and_reacquire() -> void:
	_stage()
	var a := _a.local_player_id()
	var b := _b.local_player_id()
	await _ticks(30)
	var memory := _guard.perception
	assert_float(memory.candidates[a].sight).is_equal(0.0)
	assert_float(memory.candidates[b].sight).is_greater(0.0)
	assert_str(memory.target_id).is_equal(b)
	assert_int(_guard.network_state.listener(a).z).is_equal(0)
	assert_int(_guard.network_state.listener(b).z).is_equal(1)
	var last := memory.last_known
	_ben.decrease_attribute("health", 500, _guard)
	await _ticks(4)
	assert_bool(memory.candidates.has(b)).is_false()
	assert_str(memory.target_id).is_empty()
	assert_vector(memory.last_known).is_equal_approx(last, Vector3.ONE * 0.05)
	assert_int(_guard.current_behaviour).is_equal(BEHAVIOUR.Searching)
	_ada.position = _guard.position - _guard.global_basis.z * 3.5
	await _ticks(30)
	assert_str(memory.target_id).is_equal(a)


# Laboratory has lamp light zones, so the server fallback meter of a player outside them
# reads zero. Offline the prefab has no visibility attribute and the NPC sees the player.
func test_fallback_meter_does_not_hide_a_player_outside_light_zones() -> void:
	_stage()
	var b := _b.local_player_id()
	assert_bool(_ben.has_meta(&"net_fallback_visibility")).is_true()
	_ben.visibility_attribute.value_current = 0
	_level_root.add_child(preload("res://addons/cogito/Components/LightzoneComponent.gd").new())
	await _ticks(30)
	assert_bool(_guard.perception.candidates[b].visible).is_true()
	assert_str(_guard.perception.target_id).is_equal(b)


func test_one_authoritative_shot_one_mp5_hit_and_one_event_per_listener(
	projectile: bool, _test_parameters := [[false], [true]]
) -> void:
	_stage()
	if projectile:
		_guard.weapon.attack_type = NpcWieldable.AttackType.Projectile
	_guard.weapon.firing_cooldown = 100
	await _ticks(25)
	var health: CogitoHealthAttribute = _ben.player_attributes.health
	var health_before := health.value_current
	var hits: Array[int] = []
	var events: Array[StringName] = []
	health.damage_taken.connect(func(): hits.append(1))
	_b.player_world.combat.npc_presented.connect(
		func(_npc: CogitoNPC, event: StringName, _point: Vector3): events.append(event)
	)
	_guard.weapon.firing_cooldown = 0
	_guard.weapon.npc_do_attack(_guard)
	_guard.weapon.npc_do_attack(_guard)
	await _ticks(7)
	assert_int(hits.size()).is_equal(1)
	assert_float(health.value_current).is_equal(health_before - _guard.weapon.npc_wieldable_damage)
	assert_int(events.count(&"fire")).is_equal(1)
	var observed: CogitoNPC = _b.player_world.active_level().get_node("Guard")
	await _ticks(20)
	assert_array(observed.find_children("*", "OmniLight3D", true, false)).is_empty()
	for effect: GPUParticles3D in observed.find_children("*", "GPUParticles3D", true, false):
		assert_bool(effect.emitting).is_false()
	# Keep this chase at a fixed phase so a fresh live bark cannot mask a baseline replay.
	_guard.state_chart.freeze()
	var late := _branch(4)
	late.join("memory", 1804)
	var late_events: Array[StringName] = []
	late.player_world.combat.npc_presented.connect(
		func(_npc: CogitoNPC, event: StringName, _point: Vector3): late_events.append(event)
	)
	_arena(late)
	_pump()
	await _ticks(4)
	var replica: CogitoNPC = late.player_world.active_level().get_node("Guard")
	assert_str(replica.network_state.target_id).is_equal(_b.local_player_id())
	assert_array(late_events).is_empty()


func test_departed_target_last_known_and_listener_interest_reentry(
	drop_link: bool, _test_parameters := [[false], [true]]
) -> void:
	_stage()
	var viewer: CogitoNPC = _b.player_world.active_level().get_node("Guard")
	viewer.combat_music_state = CogitoMusicState.new()
	var bystander: CogitoNPC = _a.player_world.active_level().get_node("Guard")
	bystander.combat_music_state = viewer.combat_music_state
	await _ticks(33)
	assert_bool(_requested_music(viewer)).is_true()
	assert_bool(_requested_music(bystander)).is_false()
	assert_bool(_requested_music(_guard)).is_false()
	_ada.position = Vector3(-100, 0.8, -100)
	await _ticks(6)
	assert_bool(bystander.visible).is_false()
	_ada.position = Vector3(25, 0.91, 21)
	await _ticks(7)
	assert_bool(bystander.visible).is_true()
	assert_str(bystander.network_state.target_id).is_equal(_b.local_player_id())
	var last := _guard.perception.last_known
	var id := _b.local_player_id()
	if drop_link:
		_b.disconnect_session()
		_pump()
	else:
		_server.player_world._release_subscription(3)
	await _ticks(3)
	assert_bool(_guard.perception.candidates.has(id)).is_false()
	assert_vector(_guard.perception.last_known).is_equal_approx(last, Vector3.ONE * 0.05)
	assert_int(_guard.current_behaviour).is_equal(BEHAVIOUR.Searching)


func _requested_music(npc: CogitoNPC) -> bool:
	for request: Dictionary in CogitoAudio._music_requests:
		if request.source == npc:
			return true
	return false


func test_cutscene_visibility_zone_and_new_life_clear_attention() -> void:
	_stage()
	var id := _b.local_player_id()
	var memory := _guard.perception
	# Stealth needs a zone-driven visibility attribute on the prefab, as offline.
	var meter := (
		preload("res://addons/cogito/Components/Attributes/VisibilityAttribute.tscn").instantiate()
		as CogitoVisibilityAttribute
	)
	_ben.add_child(meter)
	_ben.visibility_attribute = meter
	_ben.remove_meta(&"net_fallback_visibility")
	_guard.sight_detection.minimum_visibility = 1
	meter.value_start = 0
	meter.value_current = 0
	await _ticks(6)
	assert_bool(memory.candidates[id].visible).is_false()
	var light := Area3D.new()
	_level_root.add_child(light)
	meter.sample_zone(light, true)
	await _ticks(8)
	assert_bool(memory.candidates[id].visible).is_true()
	assert_float(memory.candidates[id].sight).is_greater(0.0)
	_ben.network_input_blocked = true
	await _ticks(2)
	assert_bool(memory.candidates.has(id)).is_false()
	_ben.network_input_blocked = false
	meter.sample_zone(light, false)
	_server.player_world.renew_life(id)
	await _ticks(2)
	assert_float(memory.candidates[id].sight).is_equal(0.0)
	assert_str(memory.target_id).is_empty()


func test_knockback_and_hit_event_run_once() -> void:
	var hits: Array[StringName] = []
	_a.player_world.combat.npc_presented.connect(
		func(_npc: CogitoNPC, event: StringName, _point: Vector3): hits.append(event)
	)
	var replica: CogitoNPC = _a.player_world.active_level().get_node("Guard")
	var health_before := _guard.health.value_current
	var investigate := _guard.find_child("InvestigateState", true, false)
	investigate.bark(investigate.investigate_bark)
	_guard.damage_received.emit(1.0, _ada, Vector3.RIGHT, _guard.global_position)
	replica.damage_received.emit(1.0, null, Vector3.RIGHT, replica.global_position)
	await _ticks(6)
	assert_int(hits.count(&"bark")).is_equal(1)
	assert_int(hits.count(&"hit")).is_equal(1)
	assert_float(_guard.knockback_timer).is_greater(0.0)
	assert_float(replica.knockback_timer).is_equal(0.0)
	assert_float(_guard.health.value_current).is_equal(health_before - 1.0)
	assert_float(replica.health.value_current).is_equal(health_before - 1.0)


func test_footsteps_without_audio_build_only_the_emitters_suspicion() -> void:
	assert_object(_ada.footstep_surface_detector).is_null()
	_ada.position = _guard.position + Vector3.RIGHT * 2
	_guard.hearing_detection.suspicion_threshold_before_investigating = 2
	_ada.main_velocity = Vector3.RIGHT * 8
	for step in 4:
		_ada.can_play_footstep = true
		_ada.wiggle_vector.y = 1
		_ada._footstep_sounds_system()
	var memory := _guard.perception
	assert_float(memory.candidates[_a.local_player_id()].hearing).is_greater(0.0)
	assert_float(memory.candidates[_b.local_player_id()].hearing).is_equal(0.0)
	assert_object(_guard.attention_target).is_instanceof(CogitoPoint)
	assert_vector(_guard.attention_target.global_position).is_equal_approx(
		_ada.global_position, Vector3.ONE * 0.001
	)

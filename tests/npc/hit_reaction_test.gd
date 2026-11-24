extends GdUnitTestSuite
## An NPC reacts to every hit, whatever it is doing.

const FIXTURES := preload("res://tests/fixtures/element_fixtures.gd")
const B := CogitoNPC.BehaviourState
const BLASTER := preload("res://addons/cogito/Wieldables/NPC_blaster.tscn")

var _level: Node3D
var _npc: CogitoNPC
var _player: CogitoPlayerAdvanced
var _previous_player: Node
var _previous_scene: Node


func before_test() -> void:
	_previous_player = CogitoSceneManager._current_player_node
	_previous_scene = get_tree().current_scene
	_level = Node3D.new()
	get_tree().root.add_child(_level)
	get_tree().current_scene = _level
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	shape.shape = box
	ground.add_child(shape)
	ground.position.y = -0.5
	_level.add_child(ground)
	_npc = FIXTURES.make_npc()
	_npc.response_to_player = "Hostile"
	_level.add_child(_npc)
	_player = FIXTURES.PLAYER.instantiate()
	_player.inventory_data = _player.inventory_data.duplicate(true)
	_level.add_child(_player)
	# Behind the NPC and out of its sight cone.
	_player.global_position = _npc.global_position - _npc.global_basis.z * 4.0
	await _frames(5)


func after_test() -> void:
	InputRouter.remove(_player.on_input)
	get_tree().current_scene = _previous_scene
	_level.free()
	CogitoSceneManager._current_player_node = _previous_player


func _frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _enter(state: CogitoNPC.BehaviourState) -> void:
	var far := _npc.global_position + Vector3(0, 0, 10)
	match state:
		B.Patrolling:
			_npc.state_chart.send_event("patrol")
		B.Alerted:
			_npc.sight_detection.generate_attention_target(far)
			_npc.state_chart.send_event("alerted")
		B.Investigating:
			_npc.state_chart.send_event("patrol")
			await _frames(1)
			_npc.sight_detection.generate_attention_target(far)
			_npc.state_chart.send_event("investigate")
		B.Searching:
			_npc.sight_detection.generate_attention_target(far)
			_npc.state_chart.send_event("alerted")
			await _frames(1)
			_npc.attention_target = _player
			_npc.state_chart.send_event("chase")
			await _frames(1)
			_npc.state_chart.send_event("search")
	await _frames(2)
	assert_int(_npc.current_behaviour).is_equal(state)


func _projectile(shooter: Node3D, from: Vector3) -> CogitoProjectile:
	var projectile: CogitoProjectile = auto_free(CogitoProjectile.new())
	projectile.shooter = shooter
	projectile.throw_point = from
	return projectile


func _hit(object: Node3D) -> void:
	_npc.damage_received.emit(1.0, object, Vector3.FORWARD, _npc.global_position)
	await _frames(2)


func test_hostile_npc_chases_the_player_that_shot_it_in_every_calm_state(
	state: int,
	_test_parameters := [[B.Idle], [B.Patrolling], [B.Alerted], [B.Investigating], [B.Searching]]
) -> void:
	if state != B.Idle:
		await _enter(state)
	await _hit(_projectile(_player, _player.global_position))
	assert_int(_npc.current_behaviour).is_equal(B.Chasing)
	assert_object(_npc.attention_target).is_same(_player)


func test_unknown_hit_alerts_again_in_busy_states(
	state: int, _test_parameters := [[B.Alerted], [B.Investigating], [B.Searching]]
) -> void:
	await _enter(state)
	var from := _npc.global_position + Vector3(5, 0, 0)
	await _hit(_projectile(null, from))
	assert_int(_npc.current_behaviour).is_equal(B.Alerted)
	assert_vector(_npc.attention_target.global_position).is_equal_approx(from, Vector3.ONE * 0.01)


func test_projectile_without_throw_point_does_not_send_npc_to_world_origin() -> void:
	var projectile := _projectile(null, Vector3.ZERO)
	_level.add_child(projectile)
	projectile.global_position = _npc.global_position + Vector3(2, 1, 0)
	await _hit(projectile)
	assert_int(_npc.current_behaviour).is_equal(B.Alerted)
	assert_vector(_npc.attention_target.global_position).is_not_equal(Vector3.ZERO)


func test_neutral_npc_is_alerted_at_the_shooter() -> void:
	_npc.response_to_player = "Neutral"
	await _hit(_projectile(_player, _player.global_position))
	assert_int(_npc.current_behaviour).is_equal(B.Alerted)
	assert_vector(_npc.attention_target.global_position).is_equal_approx(
		_player.global_position, Vector3.ONE * 0.01
	)


func test_npc_ignores_its_own_shots() -> void:
	await _hit(_projectile(_npc, _npc.global_position))
	assert_int(_npc.current_behaviour).is_equal(B.Idle)


func test_attacker_of_resolves_shooter_wielder_and_direct_attackers() -> void:
	assert_object(_npc.attacker_of(_projectile(_player, Vector3.ZERO))).is_same(_player)
	assert_object(_npc.attacker_of(_player)).is_same(_player)
	var wieldable: CogitoWieldable = auto_free(CogitoWieldable.new())
	wieldable.player_interaction_component = _player.player_interaction_component
	assert_object(_npc.attacker_of(wieldable)).is_same(_player)
	assert_object(_npc.attacker_of(_projectile(null, Vector3.ZERO))).is_null()


func test_npc_draws_its_weapon_when_a_chase_starts_without_investigating() -> void:
	_npc.free()
	_npc = FIXTURES.make_npc()
	_npc.response_to_player = "Hostile"
	var blaster: NpcWieldable = BLASTER.instantiate()
	_npc.add_child(blaster)
	_npc.weapon = blaster
	_level.add_child(_npc)
	await _frames(5)
	var raised := _npc.get_node(^"StateChart/Root/BodyPosture/UpperBody/RaisedWeapon")
	assert_bool(raised.active).is_false()
	assert_bool(blaster.wieldable_mesh.visible).is_false()
	await _hit(_projectile(_player, _player.global_position))
	assert_int(_npc.current_behaviour).is_equal(B.Chasing)
	assert_bool(raised.active).is_true()
	# The equip animation shows the mesh.
	if blaster.animation_player.is_playing():
		await blaster.animation_player.animation_finished
	assert_bool(blaster.wieldable_mesh.visible).is_true()

extends GdUnitTestSuite

const CHASE := preload("res://addons/cogito/CogitoNPC/npc_states/npc_state_chase.gd")
const WANDER := preload("res://addons/cogito/CogitoNPC/npc_states/npc_state_move_to_random_pos.gd")


func test_chase_uses_full_weapon_range() -> void:
	var chase: CHASE = auto_free(CHASE.new())
	chase.npc = auto_free(CogitoNPC.new())
	chase.npc.weapon = auto_free(NpcWieldable.new())
	chase.npc.weapon.npc_wieldable_range = 4.75
	assert_float(float(chase.get_wieldable_range())).is_equal(4.75)


func test_wander_destination_is_relative_to_host() -> void:
	var host: Node3D = auto_free(Node3D.new())
	add_child(host)
	host.position = Vector3(100, 7, -35)
	var wander: WANDER = auto_free(WANDER.new())
	wander.Host = host
	var destination: Vector3 = wander.pick_destination()
	var distance := destination.distance_to(host.position)
	assert_float(distance).is_between(0.0, wander.max_distance_from_host)


func test_wander_respects_submeter_radius() -> void:
	var wander: WANDER = auto_free(WANDER.new())
	wander.max_distance_from_host = 0.25
	var offset := wander.random_position(Vector3.RIGHT)
	assert_float(offset.length()).is_between(0.000001, 0.25)

extends GdUnitTestSuite
## Online corpses: one synced body everywhere, plus a local limb ragdoll on rendering peers.

const CORPSE := preload("res://addons/cogito/Networking/net_npc_corpse.gd")
const RAGDOLL := preload("res://addons/cogito/CogitoNPC/mannequin_ragdoll.tscn")


func _bones(body: Node) -> Array[PhysicalBone3D]:
	var result: Array[PhysicalBone3D] = []
	for bone in body.find_children("*", "PhysicalBone3D", true, false):
		result.append(bone as PhysicalBone3D)
	return result


func test_authority_corpse_has_no_bone_physics() -> void:
	var body := CORPSE.create(RAGDOLL)
	assert_array(_bones(body)).is_empty()
	assert_int(body.find_children("*", "CogitoCarryableComponent", true, false).size()).is_equal(1)
	body.free()


func test_cosmetic_limbs_fall_while_the_pelvis_follows_the_body() -> void:
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 1, 20)
	shape.shape = box
	ground.add_child(shape)
	ground.position.y = -0.5
	add_child(ground)
	var body := auto_free(CORPSE.create(RAGDOLL, true)) as RigidBody3D
	body.position.y = 0.3
	add_child(body)
	var bones := _bones(body)
	assert_array(bones).is_not_empty()
	var grips := body.find_children("*", "CogitoCarryableComponent", true, false)
	assert_int(grips.size()).is_equal(1)
	assert_object(grips[0].get_parent()).is_same(body)
	var hand: PhysicalBone3D
	for bone in bones:
		assert_int(bone.collision_layer).is_equal(0)
		assert_object(bone.get_script()).is_null()
		if bone.bone_name == "DEF-hand.L":
			hand = bone
	await get_tree().physics_frame
	await get_tree().physics_frame
	for bone in bones:
		assert_bool(bone.is_simulating_physics()).is_equal(not bone.bone_name in CORPSE.PELVIS)
	var start := hand.global_position.y
	for i in 60:
		await get_tree().physics_frame
	assert_float(hand.global_position.y).is_less(start - 0.05)
	ground.free()

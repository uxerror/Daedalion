extends GdUnitTestSuite

const Rag := preload("res://addons/cogito/CogitoNPC/mannequin_ragdoll.tscn")
const Bodies := preload("res://addons/cogito/Networking/net_bodies.gd")
const Timeline := preload("res://addons/cogito/Networking/net_body_timeline.gd")

var _level: Node3D
var _previous: Node


func before_test() -> void:
	_previous = get_tree().current_scene
	_level = Node3D.new()
	get_tree().root.add_child(_level)
	get_tree().current_scene = _level


func after_test() -> void:
	get_tree().current_scene = _previous
	_level.free()


func _spawn(replica: bool) -> NetNpcCorpse:
	var corpse := NetNpcCorpse.create(Rag, replica)
	corpse.position = Vector3(3, 4, 5)
	_level.add_child(corpse)
	return corpse


func test_full_authored_authority_and_quantized_replica() -> void:
	var server := _spawn(false)
	for tick in 12:
		await get_tree().physics_frame
	var root := server.frame_root()
	var bytes := NetNpcCorpse.Codec.encode(server.bones, root)
	assert_int(server.bones.size()).is_equal(40)
	assert_array(server.find_children("*", "RigidBody3D", true, false)).is_empty()
	assert_int(bytes.size()).is_equal(640)
	var decoded := NetNpcCorpse.Codec.decode(bytes)
	for i in server.bones.size():
		var packed := root * decoded[i]
		var source := server.bones[i].global_transform
		assert_float(source.origin.distance_to(packed.origin)).is_less(0.001)
		var angle := packed.basis.get_rotation_quaternion().angle_to(
			source.basis.get_rotation_quaternion()
		)
		assert_float(angle).is_less(deg_to_rad(0.5))
	var client := _spawn(true)
	client.apply_frame(root, decoded)
	await get_tree().physics_frame
	for i in server.bones.size():
		var original := root * decoded[i]
		var part := client.bones[i]
		assert_bool(server.bones[i].is_simulating_physics()).is_true()
		assert_bool(part.is_simulating_physics()).is_false()
		assert_float(part.global_position.distance_to(original.origin)).is_less(0.002)
		var joint := client.skeleton.get_bone_global_pose(client.skeleton.find_bone(part.bone_name))
		var visible_pose := client.skeleton.global_transform * joint * part.body_offset
		assert_float(visible_pose.origin.distance_to(original.origin)).is_less(0.002)
		var angle := visible_pose.basis.get_rotation_quaternion().angle_to(
			original.basis.get_rotation_quaternion()
		)
		assert_float(angle).is_less(deg_to_rad(0.5))


func test_replica_grip_query_follows_interpolated_pose() -> void:
	var client := _spawn(true)
	var root := client.frame_root()
	var bytes := NetNpcCorpse.Codec.encode(client.bones, root)
	var stream := Timeline.new()
	var row := ["corpse", root, Vector3.ZERO, Vector3.ZERO, true, 1, false, bytes]
	stream.push(1, row)
	row[1].origin += Vector3.RIGHT * 2
	row[4] = false
	stream.push(13, row)
	stream.pose(60, client)
	var centre := client.anchor.global_position
	assert_float(centre.x).is_between(root.origin.x + 0.98, root.origin.x + 1.05)
	await get_tree().physics_frame
	var query := PhysicsRayQueryParameters3D.create(centre + Vector3.UP, centre, 2)
	var hit := _level.get_world_3d().direct_space_state.intersect_ray(query)
	assert_object(hit.get("collider")).is_same(client.anchor)
	var actions := client.anchor.get("interaction_nodes") as Array
	assert_int(actions.size()).is_equal(1)


func test_awake_stream_final_rest_silence_and_subscription_baselines() -> void:
	var corpse := _spawn(false)
	var stream := Bodies.new()
	_level.add_child(stream)
	stream.track("runtime:1", corpse)
	for tick in 10:
		await get_tree().physics_frame
	var root := corpse.frame_root()
	var sample := {"runtime:1": [root, Vector3.ZERO, Vector3.ZERO, false, true]}
	assert_bool(stream.batch_for(2, root.origin, sample).reliable).is_true()
	var traffic := 0
	for tick in 20:
		var batch := stream.batch_for(2, root.origin, sample)
		assert_bool(batch.reliable).is_false()
		traffic += var_to_bytes(batch.rows.front()).size()
	var far_traffic := 0
	var viewer := root.origin + Vector3.RIGHT * 60
	sample["runtime:1"][4] = false
	stream.batch_for(9, viewer, sample)
	for tick in 20:
		stream._batch_number += 1
		var batch := stream.batch_for(9, viewer, sample)
		for row: Array in batch.rows:
			far_traffic += var_to_bytes(row).size()
	assert_int(far_traffic * 4).is_equal(traffic)
	assert_bool(corpse.sample_rest(0.05)).is_false()
	assert_bool(corpse.sample_rest(NetNpcCorpse.SLEEP_CAP)).is_true()
	sample["runtime:1"][3] = true
	assert_bool(stream.batch_for(2, root.origin, sample).reliable).is_true()
	for tick in 20:
		assert_array(stream.batch_for(2, root.origin, sample).rows).is_empty()
	print("CORPSE row bytes/s near=", traffic, " far=", far_traffic, " rest=0")
	for peer in [2, 3]:
		stream.forget(peer)
		var fresh := stream.batch_for(peer, root.origin, sample)
		assert_bool(fresh.reliable).is_true()
		assert_int(fresh.rows[0][7].size()).is_equal(640)
	# Hips can stay fixed while a limb wakes and settles between far transmissions.
	assert_bool(stream.batch_for(9, viewer, sample).reliable).is_true()
	stream._batch_number += 1
	sample["runtime:1"][3] = false
	assert_array(stream.batch_for(9, viewer, sample).rows).is_empty()
	sample["runtime:1"][3] = true
	assert_bool(stream.batch_for(9, viewer, sample).reliable).is_true()
	assert_array(stream.batch_for(9, viewer, sample).rows).is_empty()
	stream.batch_for(2, root.origin + Vector3.RIGHT * 100, sample)
	assert_bool(stream.batch_for(2, root.origin, sample).reliable).is_true()

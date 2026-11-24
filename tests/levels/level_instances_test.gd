extends GdUnitTestSuite

const LEVEL_A := "res://tests/levels/level_a.tscn"
const LEVEL_B := "res://tests/levels/level_b.tscn"
const BULLET := preload("res://addons/cogito/PackedScenes/projectile_pistol.tscn")

var host: CogitoLevelHost


func before_test() -> void:
	host = auto_free(CogitoLevelHost.new())
	add_child(host)


func test_groups_ids_and_host_lifetime() -> void:
	var orphans := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var a := host.load_level(LEVEL_A, &"a")
	var b := host.load_level(LEVEL_B, &"b")
	assert_array(host.levels()).contains_exactly([a, b])
	assert_object(host.load_level(LEVEL_A, &"a")).is_same(a)
	assert_object(CogitoLevel.root_of(a.get_node("Crate/Shape"))).is_same(a)
	var crates := CogitoLevel.nodes_in_group(a, &"test_crates")
	assert_array(crates).contains_exactly([a.get_node("Crate")])
	assert_object(CogitoLevel.first_node_in_group(b, &"test_crates")).is_same(b.get_node("Crate"))
	assert_object(CogitoLevel.first_node_in_group(a, &"Player")).is_null()
	for root in [a, b]:
		var crate: Node = root.get_node("Crate")
		assert_str(CogitoPersistentId.of(crate)).is_equal("level:Crate")
		assert_object(CogitoPersistentId.find_in_level(root, "level:Crate")).is_same(crate)
		var legacy := "/root/%s/Crate" % root.name
		assert_object(CogitoPersistentId.find_in_level(root, legacy)).is_same(crate)
	assert_object(CogitoPersistentId.find_in_level(a, str(b.get_path()))).is_null()
	assert_object(CogitoPersistentId.find_in_level(a, "/root")).is_same(a)
	var npc_scene := load("res://addons/cogito/CogitoNPC/cogito_npc.tscn") as PackedScene
	var preview := npc_scene.instantiate() as CogitoNPC
	preview.sight_detection.show_detection_line = false
	a.add_child(preview)
	var viewport := a.get_parent() as SubViewport
	assert_int(viewport.render_target_update_mode).is_equal(SubViewport.UPDATE_DISABLED)
	assert_bool(viewport.audio_listener_enable_3d).is_false()
	host.unload_level(&"a")
	assert_object(host.level(&"a")).is_null()
	assert_object(host.level(&"b")).is_same(b)
	await get_tree().process_frame
	assert_bool(is_instance_valid(viewport)).is_false()
	assert_bool(is_instance_valid(a)).is_false()
	host.unload_level(&"b")
	await get_tree().process_frame
	assert_array(host.levels()).is_empty()
	assert_float(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)).is_equal(orphans)


func test_physics_navigation_and_perception() -> void:
	var a := host.load_level(LEVEL_A, &"a") as Node3D
	var b := host.load_level(LEVEL_B, &"b") as Node3D
	assert_bool(a.get_world_3d().space != b.get_world_3d().space).is_true()
	assert_bool(a.get_world_3d().navigation_map != b.get_world_3d().navigation_map).is_true()
	var area: CogitoElementArea = a.get_node("Element")
	var other_area: CogitoElementArea = b.get_node("Element")
	var crate: RigidBody3D = a.get_node("Crate")
	crate.position.x = 10
	var npc_a: CogitoNPC = a.get_node("NPC")
	var npc_b: CogitoNPC = b.get_node("NPC")
	var target: CogitoPlayer = b.get_node("Target")
	# Put the target in the interior of both coincident sight cones.
	var cone := npc_b.sight_detection.cone_collider
	var center := Vector3.ZERO
	var points := (cone.shape as ConvexPolygonShape3D).points
	for point in points:
		center += point
	target.global_position = cone.to_global(center / points.size())
	var noise := ObjectNoise.new(true)
	noise.set_parameters(ObjectNoise.NoiseType.Footstep, 4, 2, 512)
	b.add_child(noise)
	noise.global_position = npc_b.global_position
	for frame in 5:
		await get_tree().physics_frame
	assert_array(area.get_overlapping_bodies()).is_empty()
	assert_array(other_area.get_overlapping_bodies()).contains_exactly([b.get_node("Crate")])
	assert_array(npc_b.sight_detection.nodes_inside_cone).contains([target])
	assert_bool(npc_b.sight_detection.check_if_player_in_los()).is_true()
	assert_array(npc_a.sight_detection.nodes_inside_cone).is_empty()
	assert_bool(npc_a.sight_detection.check_if_player_in_los()).is_false()
	assert_float(npc_b.hearing_detection.current_suspicion).is_greater(0.0)
	assert_float(npc_a.hearing_detection.current_suspicion).is_zero()


func test_scene_save_and_deferred_restore_are_local() -> void:
	var a := host.load_level(LEVEL_A, &"a")
	var b := host.load_level(LEVEL_B, &"b")
	var manager := CogitoSceneManager
	var slot := "mp0b-%d" % Time.get_ticks_usec()
	var crate_a: RigidBody3D = a.get_node("Crate")
	var crate_b: RigidBody3D = b.get_node("Crate")
	crate_a.position.x = 7
	crate_b.position.x = 12
	manager.register_destroyed_node(a.get_node("Removable"))
	assert_array(manager._get_destroyed_nodes(b)).is_empty()
	assert_int(manager.save_scene_state("LevelA", slot, a)).is_equal(OK)
	var path := manager.scene_file(slot, "LevelA")
	var state := manager.SaveCodec.new().read(path, "scene") as CogitoSceneState
	for row: Dictionary in state.saved_nodes:
		assert_str(row.cogito_id).is_not_equal("level:OnlyB")
	assert_bool(state.known_persist_ids.has("level:OnlyB")).is_false()
	var saved_crates := state.saved_nodes.filter(
		func(row: Dictionary) -> bool: return row.cogito_id == "level:Crate"
	)
	assert_int(saved_crates.size()).is_equal(1)
	assert_float(saved_crates[0].pos_x).is_equal(7.0)
	assert_array(state.saved_destroyed_nodes).contains_exactly(
		[{"cogito_id": "Removable", "path": "."}]
	)
	var health_a: CogitoHealthAttribute = crate_a.get_node("Health")
	var health_b: CogitoHealthAttribute = crate_b.get_node("Health")
	var saved_health := health_a.value_current
	health_a.restore_attribute(2.0, 100.0)
	health_b.restore_attribute(3.0, 100.0)
	var element_a: CogitoElementArea = a.get_node("Element")
	var element_b: CogitoElementArea = b.get_node("Element")
	element_a.enabled = true
	element_b.enabled = true
	crate_a.position.x = 9
	manager.load_scene_state("LevelA", slot, a)
	await get_tree().process_frame
	assert_float(crate_a.position.x).is_equal(7.0)
	assert_float(crate_b.position.x).is_equal(12.0)
	assert_float(health_a.value_current).is_equal(saved_health)
	assert_float(health_b.value_current).is_equal(3.0)
	assert_bool(element_a.enabled).is_false()
	assert_bool(element_b.enabled).is_true()
	assert_bool(a.has_node("Removable")).is_false()
	assert_bool(b.has_node("OnlyB") and b.has_node("Removable")).is_true()
	assert_array(manager._get_destroyed_nodes(b)).is_empty()
	assert_int(DirAccess.remove_absolute(path)).is_equal(OK)
	assert_int(DirAccess.remove_absolute(path.get_base_dir())).is_equal(OK)


func test_weapon_and_sound_spawn_in_shooters_level() -> void:
	var a := host.load_level(LEVEL_A, &"a")
	var b := host.load_level(LEVEL_B, &"b")
	var weapon := NpcWieldable.new()
	var muzzle := Node3D.new()
	muzzle.name = "Bullet_Point"
	weapon.add_child(muzzle)
	muzzle.owner = weapon
	muzzle.unique_name_in_owner = true
	weapon.wieldable_mesh = muzzle
	weapon.pool_size = 2
	weapon.projectile_prefab = BULLET
	a.add_child(weapon)
	weapon.fire_projectile(Vector3.FORWARD)
	var projectile := a.get_node("projectile_pistol") as CogitoProjectile
	assert_object(projectile.get_parent()).is_same(a)
	assert_bool(b.has_node("projectile_pistol")).is_false()
	var drop := Node3D.new()
	drop.name = "Drop"
	var prefab := PackedScene.new()
	assert_int(prefab.pack(drop)).is_equal(OK)
	drop.free()
	projectile.spawn_on_death = [prefab]
	projectile.die()
	assert_bool(a.has_node("Drop")).is_true()
	assert_bool(b.has_node("Drop")).is_false()
	var sound := CogitoAudio.play_sound_3d_in(weapon, AudioStreamGenerator.new(), Vector3.ONE)
	assert_object(sound.get_parent()).is_same(a)
	assert_object(CogitoLevel.spawn_parent(weapon, true)).is_same(a)
	host.unload_level(&"a")
	await get_tree().process_frame
	assert_bool(is_instance_valid(weapon)).is_false()


func test_decal_recycling_stays_in_its_level() -> void:
	var a := host.load_level(LEVEL_A, &"a")
	var b := host.load_level(LEVEL_B, &"b")
	var wall_a := a.get_node("Crate") as Node3D
	var wall_b := b.get_node("Crate") as Node3D
	var decal := Node3D.new()
	decal.name = "Decal"
	var prefab := PackedScene.new()
	assert_int(prefab.pack(decal)).is_equal(OK)
	decal.free()
	for index in BulletDecalPool.MAX_BULLET_DECALS:
		BulletDecalPool.spawn_bullet_decal(prefab, Vector3.ZERO, Vector3.UP, wall_a, Basis())
	var oldest := wall_a.get_node("Decal")
	BulletDecalPool.spawn_bullet_decal(prefab, Vector3.ZERO, Vector3.UP, wall_b, Basis())
	assert_object(oldest.get_parent()).is_same(wall_a)
	assert_bool(wall_b.has_node("Decal")).is_true()


func test_pending_restore_does_not_follow_a_reused_key() -> void:
	var a := host.load_level(LEVEL_A, &"a")
	var element: CogitoElementArea = a.get_node("Element")
	element.enabled = true
	var persistence := CogitoSceneManager._scene_persistence
	persistence.apply(persistence.capture(a), a)
	host.unload_level(&"a")
	var replacement := host.load_level(LEVEL_A, &"a")
	await get_tree().process_frame
	var fresh_element: CogitoElementArea = replacement.get_node("Element")
	assert_bool(fresh_element.enabled).is_false()
	assert_array(CogitoSceneManager._get_destroyed_nodes(replacement)).is_empty()


func test_single_level_group_fast_path() -> void:
	var tree := get_tree()
	var root := Node3D.new()
	tree.root.add_child(root)
	var previous := tree.current_scene
	tree.current_scene = root
	const GROUP := &"mp0b_benchmark"
	for index in 128:
		var member := Node.new()
		root.add_child(member)
		member.add_to_group(GROUP)
	var members := tree.get_nodes_in_group(GROUP)
	var first := tree.get_first_node_in_group(GROUP)
	assert_array(CogitoLevel.nodes_in_group(root, GROUP)).contains_exactly(members)
	assert_object(CogitoLevel.first_node_in_group(root, GROUP)).is_same(first)
	assert_object(CogitoLevel.spawn_parent(root)).is_same(root)
	assert_object(CogitoLevel.spawn_parent(root, true)).is_same(tree.root)
	assert_object(CogitoLevel.root_of(CogitoAudio)).is_same(root)
	var detached := Node.new()
	assert_object(CogitoLevel.root_of(detached)).is_same(root)
	assert_object(CogitoLevel.spawn_parent(detached)).is_same(root)
	assert_array(CogitoLevel.nodes_in_group(detached, GROUP)).contains_exactly(members)
	detached.free()
	const ITERATIONS := 10000
	var count := 0
	var native_us: Array[int] = []
	var scoped_us: Array[int] = []
	for round_index in 5:
		for offset in 2:
			var begin := Time.get_ticks_usec()
			if (round_index + offset) % 2 == 0:
				for iteration in ITERATIONS:
					count += root.get_tree().get_nodes_in_group(GROUP).size()
				native_us.append(Time.get_ticks_usec() - begin)
			else:
				for iteration in ITERATIONS:
					count += CogitoLevel.nodes_in_group(root, GROUP).size()
				scoped_us.append(Time.get_ticks_usec() - begin)
	assert_int(count).is_equal(128 * ITERATIONS * 10)
	native_us.sort()
	scoped_us.sort()
	print(
		(
			"MP0b benchmark: 128 members, 10000 calls, median of 5: native=%d us scoped=%d us"
			% [native_us[2], scoped_us[2]]
		)
	)
	tree.current_scene = previous
	root.free()

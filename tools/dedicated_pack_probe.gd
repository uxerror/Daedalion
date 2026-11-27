extends SceneTree
## Load an exported dedicated pack over the project and check that level collision did
## not depend on stripped visuals. Usage: godot --headless --path . -s THIS -- PCK

const LEVELS := [
	"res://addons/cogito/DemoScenes/COGITO_3_Lobby.tscn",
	"res://addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn",
]


func _initialize() -> void:
	_run()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or not ProjectSettings.load_resource_pack(args[0], true):
		printerr("PACK PROBE cannot load pack")
		quit(1)
		return
	var failures := 0
	var baked := 0
	for path: String in LEVELS:
		var level := (load(path) as PackedScene).instantiate()
		for node in level.find_children("*", "CSGShape3D", true, false):
			if (node as CSGShape3D).use_collision and not node.get_parent() is CSGShape3D:
				printerr("PACK PROBE colliding CSG left: ", path, " ", level.get_path_to(node))
				failures += 1
		for holder in level.find_children("BakedCollision", "CollisionShape3D", true, false):
			var shape := (holder as CollisionShape3D).shape as ConcavePolygonShape3D
			if not shape or shape.get_faces().is_empty():
				printerr("PACK PROBE empty baked shape: ", level.get_path_to(holder))
				failures += 1
			baked += 1
		level.free()
	if baked == 0:
		printerr("PACK PROBE no baked CSG collision found")
		failures += 1
	failures += await _ray_hits_ramp()
	print("PACK PROBE baked=%d failures=%d" % [baked, failures])
	quit(1 if failures else 0)


# The NPC area ramp is a stripped CSGMesh3D (3 m prism, ceiling at 5.5 m): a ray from
# 2 m above its centre must stop on its slope.
func _ray_hits_ramp() -> int:
	var level := (load(LEVELS[1]) as PackedScene).instantiate()
	root.add_child(level)
	current_scene = level
	for i in 3:
		await physics_frame
	var ramp := level.get_node("NavigationRegion3D/NPC_AREA/Ramp2") as Node3D
	var top := ramp.global_position + Vector3.UP * 2.0
	var query := PhysicsRayQueryParameters3D.create(top, ramp.global_position + Vector3.DOWN)
	var hit: Dictionary = level.get_world_3d().direct_space_state.intersect_ray(query)
	var ok: bool = not hit.is_empty() and hit.collider == ramp
	if not ok:
		printerr("PACK PROBE ray missed the ramp: ", hit)
	level.queue_free()
	return 0 if ok else 1

extends Node
## Compare the deterministic segment to the physical RID of two authored idle tweens.
## The calling test runs idle and physics at a fixed 60 Hz.

const Door := preload("res://addons/cogito/CogitoObjects/cogito_door.gd")
const Support := preload("res://addons/cogito/Networking/net_support_motion.gd")


func _door(sync: bool) -> CogitoDoor:
	var body := AnimatableBody3D.new()
	body.sync_to_physics = sync
	body.set_script(Door)
	var door := (body as Node3D) as CogitoDoor
	door.door_type = CogitoDoor.DoorType.SLIDING
	door.door_speed = 3.0
	door.open_position = Vector3(0, 2.614, 0)
	add_child(body)
	return door


func _ready() -> void:
	var doors: Array[CogitoDoor] = [_door(true), _door(false)]
	var sample := _door(true)
	var motion := Support.new(sample, 1)
	await get_tree().physics_frame
	await get_tree().physics_frame
	for door in doors:
		door.open_door(null)
	motion.start(0, sample.open_position, sample.door_speed)
	var worst := 0.0
	for tick in range(1, 184):
		await get_tree().physics_frame
		var predicted := motion.pose(tick).origin
		for door in doors:
			var physical: Transform3D = PhysicsServer3D.body_get_state(
				door.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM
			)
			worst = maxf(worst, physical.origin.distance_to(predicted))
	motion.close()
	print("PR8 SLIDING RID maximum error=", worst)
	get_tree().quit(int(worst > 0.000002))

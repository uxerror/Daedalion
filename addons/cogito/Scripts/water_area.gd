extends FluidArea3D
class_name WaterArea

func _ready() -> void:
	super()
	add_to_group("water_area")


## World height of the authored surface at this observation, including parent transforms.
func surface_y(hull: CollisionShape3D) -> float:
	var box := hull.shape as BoxShape3D
	if box:
		return (hull.global_transform * (Vector3.UP * box.size.y * 0.5)).y
	return to_global(Vector3.UP * (surface_height - position.y)).y

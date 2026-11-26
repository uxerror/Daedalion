class_name CogitoReconnectPolicy
extends Resource
## Placement after a disk restart, in level-local coordinates.


## Prefer the saved pose in the same level if the actor fits; otherwise use MP5 selection.
func select(actor: CogitoPlayerAdvanced, record: Dictionary, players: Node) -> Transform3D:
	var id: String = record.id
	var level: Node = players.active_level()
	if not record.dead and record.level == players.world.entities.level_key:
		var pose: Transform3D = record.pose
		var collider := actor.standing_collision_shape
		if record.get("crouched", false):
			collider = actor.crouching_collision_shape
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = collider.shape
		# The controller rotates its Body child. Its root collision shape remains upright.
		var position_only := Transform3D(Basis.IDENTITY, pose.origin)
		query.transform = level.global_transform * position_only * collider.transform
		query.exclude = [actor.get_rid()]
		query.collision_mask = actor.collision_mask
		if actor.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
			return pose
	return players.death.respawn_transform(id, level)

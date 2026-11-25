class_name CogitoRespawnPolicy
extends Resource
## Game hooks for server-approved respawns. Transforms are relative to the level root.


## Select the first free point by path, or the point with the greatest clearance.
func select(player_id: String, level: Node, candidates: Array[CogitoRespawnPoint]) -> Transform3D:
	var players: Node = level.get_meta(&"cogito_net_players")
	candidates.sort_custom(func(a: Node, b: Node): return str(a.get_path()) < str(b.get_path()))
	var best: CogitoRespawnPoint
	var best_distance := -1.0
	for point in candidates:
		if not point.enabled:
			continue
		var distance := INF
		for record: Dictionary in players.get_parent().records():
			var avatar: Variant = players.avatar_for(record.player_id)
			if (
				avatar
				and record.player_id != player_id
				and CogitoLevel.root_of(avatar.actor) == level
			):
				distance = minf(
					distance, point.global_position.distance_to(avatar.actor.global_position)
				)
		if distance > best_distance:
			best = point
			best_distance = distance
		if distance >= 1.0:
			break
	if not best:
		return players.join_transform(player_id)
	if level is Node3D:
		return level.global_transform.affine_inverse() * best.global_transform
	return best.global_transform


## Called once on the authoritative transition to dead. Retain all possessions by default.
func on_death(_player_id: String) -> void:
	pass


## Set the four survival meters to their current maxima. Preserve custom progression.
func restore_attributes(avatar: CogitoPlayer) -> void:
	for key: String in ["health", "oxygen", "stamina", "sanity"]:
		var attr: CogitoAttribute = avatar.player_attributes.get(key)
		if attr:
			attr.apply_replica_value(attr.value_max, attr.value_max)


## Override to request automatic respawn when the server deadline has elapsed.
func auto_respawn(_player_id: String) -> bool:
	return false

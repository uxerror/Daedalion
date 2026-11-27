class_name CogitoTravelPolicy
extends Resource
## Authority hooks for independent travel. The coordinator verifies every participant.


## Return the actors to move through this zone. An empty array declines the request.
func participants(actor: CogitoPlayerAdvanced, _zone: Area3D) -> Array[CogitoPlayerAdvanced]:
	return [actor]


## Snapshot the same Advanced seated posture as offline TEMP before releasing the source.
func attachments(actor: CogitoPlayerAdvanced) -> Dictionary:
	if not actor.is_sitting:
		return {}
	if not actor.current_seat:
		return {"posture": actor.get_meta(&"travel_seated_posture", null)}
	var posture := CogitoPlayerAdvancedState.new()
	posture.save_sitting_state(actor)
	return {"posture": posture}


## Called after readiness and placement validation, while the source actor still owns its body.
## Leave the physical object in this world. A weapon holstered for the grip stays holstered.
func departing(actor: CogitoPlayerAdvanced, _state: Dictionary, players: Node) -> void:
	players.carry.release(players.peer_for_actor(actor), false)


## Resolve the saved seat in the destination, preserving TEMP posture even without a match.
func arrived(actor: CogitoPlayerAdvanced, state: Dictionary, players: Node) -> void:
	var posture: CogitoPlayerAdvancedState = state.get("posture")
	if not posture:
		return
	posture.load_sitting_state(actor)
	var seat := actor.current_seat
	actor.current_seat = null
	if seat:
		players.seats.use(seat, actor.player_interaction_component)
	if not actor.current_seat:
		actor.set_meta(&"travel_seated_posture", posture)
		actor.state_chart.send_event("sit")


## Prefer the connector, then nearby horizontal offsets, then the level's respawn selection.
## Each candidate is checked in the destination physics space at the time of commitment.
func placement(actor: CogitoPlayerAdvanced, connector: Node3D, players: Node) -> Variant:
	var root: Node3D = players.active_level()
	var start := root.global_transform.affine_inverse() * connector.global_transform
	var id: String = actor.get_meta(&"net_player_id")
	var candidates: Array[Transform3D] = [start]
	for radius: float in [1.5, 3.0]:
		for index in 8:
			var offset := Vector3.RIGHT.rotated(Vector3.UP, index * TAU / 8.0) * radius
			candidates.append(start.translated(offset))
	candidates.append(players.death.respawn_transform(id, root))
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = actor.standing_collision_shape.shape
	query.collision_mask = actor.initial_collision_mask
	var space := root.get_world_3d().direct_space_state
	for candidate in candidates:
		query.transform = root.global_transform * Transform3D(Basis.IDENTITY, candidate.origin)
		query.transform *= actor.standing_collision_shape.transform
		if (
			players._clear_position(candidate.origin, id)
			and space.intersect_shape(query, 1).is_empty()
		):
			return candidate
	return null

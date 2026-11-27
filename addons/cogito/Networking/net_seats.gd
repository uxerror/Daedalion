extends RefCounted
## Seat claims and exits are synchronous with the MP2 commit on the authoritative actor.


## Called after normal MP2 checks, or by an authored auto-seat's server overlap.
func use(seat: CogitoSittable, pic: PlayerInteractionComponent) -> Dictionary:
	var actor := pic.player as CogitoPlayerAdvanced
	var players: Node = pic.network_interactions.get_parent()
	var peer: int = players.peer_for_actor(actor)
	if actor.is_dead:
		return {"ok": false, "reason": "Player is dead"}
	if not peer or not players.multiplayer.is_server():
		return {"ok": false, "reason": "Unavailable"}
	if actor.current_seat == seat:
		release(actor)
		return {"ok": true}
	var reason := _blocked(seat, actor)
	if reason:
		return {"ok": false, "reason": reason}
	players.carry.release(peer)
	if actor.current_seat:
		_vacate(actor.current_seat)
	else:
		actor.original_position = actor.global_transform
		actor.original_neck_basis = actor.neck.global_basis
	actor.displacement_position = seat.global_position - actor.global_position
	if actor.has_meta(&"travel_seated_posture"):
		actor.remove_meta(&"travel_seated_posture")
	actor.current_seat = seat
	actor.is_sitting = true
	actor.is_ejected = false
	actor.velocity = Vector3.ZERO
	actor.current_command = actor.neutral_command(actor.last_consumed_sequence)
	actor.collision_mask = 0
	actor.global_transform = seat.sit_position_node.global_transform
	actor.state_chart.send_event("sit")
	seat.player_node = actor
	seat.occupant_id = actor.get_meta(&"net_wield").player_id
	if seat is CogitoVehicle:
		var target: Node = seat.vehicle_node if seat.vehicle_node else seat
		target.set_meta(&"net_driver", seat)
	seat.tree_exiting.connect(release.bind(actor, true), CONNECT_ONE_SHOT)
	seat._sit_down()
	actor.body.rotation.y = 0
	actor.neck.rotation.y = _center(actor, seat)
	clamp_look(actor)
	players.mark_teleport(seat.occupant_id)
	return {"ok": true}


func _blocked(seat: CogitoSittable, actor: CogitoPlayerAdvanced) -> String:
	if seat.is_occupied or not seat.sit_position_node or seat.has_meta(&"net_carrier"):
		return "In use"
	if seat is CogitoVehicle:
		var target: Node = seat.vehicle_node if seat.vehicle_node else seat
		if target.has_meta(&"net_driver"):
			return "In use"
	if seat._is_fallen() or (seat.disable_on_crouch and actor.is_in_crouching_state()):
		return "Posture blocks interaction"
	if seat.disable_on_jump and actor.is_in_air:
		return "Posture blocks interaction"
	if seat.sit_area_behaviour != CogitoSittable.SitAreaBehaviour.NONE:
		var area := seat.get_node_or_null(seat.sit_area_node_path) as Area3D
		if not area or not area.overlaps_body(actor):
			return "Out of reach"
	return ""


## Free the occupied seat exactly once, including on death or level shutdown.
func release(actor: CogitoPlayerAdvanced, seat_exiting := false) -> void:
	var seat := actor.current_seat
	if not seat and actor.has_meta(&"travel_seated_posture"):
		actor.remove_meta(&"travel_seated_posture")
		actor._stand_up_finished()
		return
	if not is_instance_valid(seat) or seat.player_node != actor:
		return
	var id := seat.occupant_id
	actor.current_seat = null
	if actor.neck.is_inside_tree():
		var pose := actor.original_position if seat_exiting else _exit_pose(actor, seat)
		actor.global_transform = pose
		actor._stand_up_finished()
	else:
		actor.is_sitting = false
	actor.velocity = Vector3.ZERO
	_vacate(seat, not seat_exiting and seat.is_inside_tree())
	actor.player_interaction_component.network_interactions.get_parent().mark_teleport(id)


func _exit_pose(actor: CogitoPlayerAdvanced, seat: CogitoSittable) -> Transform3D:
	var exit_pose := actor.original_position
	match seat.placement_on_leave:
		CogitoSittable.PlacementOnLeave.TRANSFORM, CogitoSittable.PlacementOnLeave.AUTO:
			var marker := seat.get_node_or_null(seat.leave_node_path) as Node3D
			if marker and marker.is_inside_tree():
				exit_pose = marker.global_transform
		CogitoSittable.PlacementOnLeave.DISPLACEMENT:
			exit_pose.origin = seat.global_position - actor.displacement_position
	return exit_pose


func _vacate(seat: CogitoSittable, play_sound := true) -> void:
	var cleanup := release.bind(seat.player_node, true)
	if seat.tree_exiting.is_connected(cleanup):
		seat.tree_exiting.disconnect(cleanup)
	if seat is CogitoVehicle:
		var target: Node = seat.vehicle_node if seat.vehicle_node else seat
		target.remove_meta(&"net_driver")
		seat.velocity = Vector3.ZERO
		seat.rotation_momentum = 0
	seat.player_node = null
	seat.occupant_id = ""
	seat._stand_up(play_sound)


func _center(actor: CogitoPlayerAdvanced, seat: CogitoSittable) -> float:
	if not seat.look_marker_node:
		return 0
	var direction := seat.look_marker_node.global_position - actor.neck.global_position
	direction = actor.global_basis.inverse() * direction
	return atan2(-direction.x, -direction.z)


## Clamp composed yaw as well as pitch, including input with forged body/neck decomposition.
func clamp_look(actor: CogitoPlayerAdvanced) -> void:
	var seat := actor.current_seat
	if not seat:
		return
	var center := _center(actor, seat)
	var offset := wrapf(actor.body.rotation.y + actor.neck.rotation.y - center, -PI, PI)
	var limit := deg_to_rad(seat.horizontal_look_angle)
	actor.body.rotation.y = 0
	actor.neck.rotation.y = center + clampf(offset, -limit, limit)
	limit = deg_to_rad(seat.vertical_look_angle)
	actor.head.rotation.x = clampf(actor.head.rotation.x, -limit, limit)
	actor.sittable_look_angle = seat.horizontal_look_angle
	if seat.look_marker_node:
		actor.sittable_look_marker = seat.look_marker_node.global_position

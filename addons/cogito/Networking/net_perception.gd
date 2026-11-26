extends RefCounted
## This memory belongs to one server NPC. Discard a player's row when its life changes.

const BEHAVIOUR := CogitoNPC.BehaviourState
## Set COGITO_NPC_DEBUG=1 on the server to print each candidate row once per second.
const DEBUG_ENV := "COGITO_NPC_DEBUG"

var candidates := {}
var target_id := ""
var last_known := Vector3.ZERO
var search_id := ""
var npc: CogitoNPC
var players: Node
var policy: CogitoNpcTargetPolicy
var _saved_candidates := {}
var _point: CogitoPoint
var _debug := OS.has_environment(DEBUG_ENV)


func _init(owner_npc: CogitoNPC, world_players: Node) -> void:
	npc = owner_npc
	players = world_players
	policy = npc.target_policy if npc.target_policy else players.npc_target_policy


## Keep suspicion timers by durable identity. Recompute visibility from the next live actor.
func capture() -> Dictionary:
	var rows := _saved_candidates.duplicate(true)
	for id: String in candidates:
		var row := {}
		for field: String in ["sight", "hearing", "memory", "quiet", "last_known"]:
			row[field] = candidates[id][field]
		rows[id] = row
	return {"rows": rows, "target": target_id, "search": search_id, "point": last_known}


## Resume the search without invoking a detection, firing or alert callback.
func restore(data: Dictionary) -> void:
	last_known = data.point
	target_id = data.target
	search_id = data.search
	_saved_candidates = data.rows.duplicate(true)
	if not search_id.is_empty():
		attention_point(last_known)


## Evaluate every candidate independently, before chase/attack callbacks run this physics tick.
func advance(delta: float) -> void:
	var remaining := {}
	for record: Dictionary in players.get_parent().records():
		var id: String = record.player_id
		var actor := eligible_actor(id)
		if not actor:
			continue
		var avatar: Variant = players.avatar_for(id)
		var row: Dictionary = candidates.get(id, {})
		if row.get("life", -1) != avatar.lifetime:
			if id == search_id:
				search_id = ""
			row = {
				"sight": 0.0,
				"hearing": 0.0,
				"memory": 0.0,
				"quiet": 0.0,
				"last_known": Vector3.ZERO,
				"life": avatar.lifetime,
			}
		if _saved_candidates.has(id):
			row.merge(_saved_candidates[id], true)
			_saved_candidates.erase(id)
		_sample(row, actor, delta)
		remaining[id] = row
	candidates = remaining
	var selected := policy.choose(npc, candidates, target_id)
	if not candidates.has(selected):
		selected = ""
	_select(selected)


func _sample(row: Dictionary, actor: CogitoPlayerAdvanced, delta: float) -> void:
	var sight := npc.sight_detection
	row.distance = npc.global_position.distance_to(actor.global_position)
	row.actor = actor
	row.visible = false
	row.visibility = 0.0
	if sight and npc.response_to_player == "Hostile" and actor in sight.nodes_inside_cone:
		# Same scale as offline SightDetection: the raw attribute value, or fully visible
		# when the player prefab has no visibility attribute. The server's fallback meter
		# only feeds the HUD light meter and must not add stealth the offline game lacks.
		var meter := actor.visibility_attribute
		if actor.has_meta(&"net_fallback_visibility"):
			meter = null
		row.visibility = 100.0 if not meter else meter.value_current
		if row.visibility >= sight.minimum_visibility:
			var query := PhysicsRayQueryParameters3D.create(
				npc.head.global_position, actor.head.global_position
			)
			query.exclude = [npc.get_rid()]
			if npc.head is CollisionObject3D:
				query.exclude = [npc.get_rid(), npc.head.get_rid()]
			var hit := npc.get_world_3d().direct_space_state.intersect_ray(query)
			row.visible = hit.get("collider") == actor
			if row.visible:
				row.point = hit.position
	if _debug and Engine.get_physics_frames() % 60 == 0:
		_trace(row, actor)
	if sight and row.visible:
		# As offline: slow build-up only while idle or patrolling, fast once alerted.
		var rate := sight.buildup_to_aggro_rate
		if npc.in_state([BEHAVIOUR.Patrolling, BEHAVIOUR.Idle]):
			rate = sight.buildup_to_investigation_rate
		if sight.visibility_modifier_curve:
			rate *= sight.visibility_modifier_curve.sample(row.visibility)
		rate *= clampf(sight.get_distance_modifier_to(actor), 0.0, 1.0)
		row.sight = minf(sight.aggro_threshold, row.sight + rate * delta)
		row.memory = sight.delay_before_suspicion_decays
		row.last_known = actor.global_position
	elif sight:
		row.memory -= delta
		if row.memory <= 0:
			row.sight = maxf(0, row.sight - sight.suspicion_decay_rate * delta)
	var hearing := npc.hearing_detection
	row.quiet -= delta
	if hearing and row.quiet <= 0:
		row.hearing = maxf(0, row.hearing - hearing.suspicion_decay_rate * delta)
	row.score = float(row.sight) / maxf(0.001, sight.aggro_threshold) if sight else 0.0
	if hearing:
		row.score += (
			0.25 * row.hearing / maxf(0.001, hearing.suspicion_threshold_before_investigating)
		)


func _trace(row: Dictionary, actor: CogitoPlayerAdvanced) -> void:
	var sight := npc.sight_detection
	print(
		(
			(
				"NPC %s state=%d target=%s player=%s dist=%.1f cone=%s visible=%s"
				+ " visibility=%.0f sight=%.2f hearing=%.2f"
			)
			% [
				npc.name,
				npc.current_behaviour,
				target_id.left(8),
				String(actor.get_meta(&"net_player_id", "")).left(8),
				row.distance,
				sight != null and actor in sight.nodes_inside_cone,
				row.visible,
				row.visibility,
				row.sight,
				row.hearing,
			]
		)
	)


func _select(selected: String) -> void:
	var combat := npc.in_state([BEHAVIOUR.Chasing, BEHAVIOUR.Attacking])
	var old := target_id
	target_id = selected
	var row: Dictionary = candidates.get(selected, {})
	if not row.get("visible", false):
		if not row.is_empty():
			last_known = row.last_known
			if not combat:
				investigate(last_known)
		if combat:
			search_id = selected if not selected.is_empty() else old
			if not candidates.has(search_id):
				search_id = ""
			attention_point(last_known)
			if npc.current_behaviour == BEHAVIOUR.Attacking:
				npc.state_chart.send_event("chase")
			if npc.current_behaviour == BEHAVIOUR.Chasing:
				npc.state_chart.send_event("search")
		elif npc.current_behaviour == BEHAVIOUR.Investigating and not _has_suspicion():
			npc.state_chart.send_event("patrol")
		return
	last_known = row.last_known
	if combat or row.sight >= npc.sight_detection.aggro_threshold:
		npc.attention_target = row.actor
		search_id = selected
		if not combat and not npc.is_panicking():
			npc.state_chart.send_event("chase")
	elif row.sight >= npc.sight_detection.investigation_threshold:
		investigate(last_known)


func _has_suspicion() -> bool:
	for row: Dictionary in candidates.values():
		if row.sight > 0 or row.hearing > 0:
			return true
	return false


## End a search without erasing independent suspicion of other players.
func end_search(reset: bool) -> void:
	if reset and candidates.has(search_id):
		candidates[search_id].sight = 0.0
		candidates[search_id].hearing = 0.0
	search_id = ""


## A hit from an eligible player raises that player's suspicion immediately.
func threatened(actor: CogitoPlayer) -> void:
	var id: String = actor.get_meta(&"net_player_id", "")
	if candidates.has(id) and npc.sight_detection:
		candidates[id].sight = npc.sight_detection.aggro_threshold
		candidates[id].last_known = actor.global_position
		if (
			not candidates[id].visible
			and not npc.in_state([BEHAVIOUR.Chasing, BEHAVIOUR.Attacking])
		):
			attention_point(actor.global_position)
			npc.state_chart.send_event("alerted")


## Stimulus delivered by the actor's server movement, without an audio player or renderer.
func hear(id: String, point: Vector3, magnitude: float) -> void:
	var hearing := npc.hearing_detection
	if (
		not hearing
		or not candidates.has(id)
		or magnitude <= hearing.ignore_sounds_under_x_magnitude
	):
		return
	if npc.global_position.distance_to(point) > hearing.hearing_radius + magnitude:
		return
	var row: Dictionary = candidates[id]
	var threshold := hearing.suspicion_threshold_before_investigating
	row.hearing = minf(threshold, row.hearing + hearing.noise_suspicion_curve.sample(magnitude))
	row.quiet = hearing.delay_before_suspicion_decays
	row.last_known = point
	if row.hearing >= threshold:
		investigate(point)


func investigate(point: Vector3) -> void:
	if npc.in_state([BEHAVIOUR.Idle, BEHAVIOUR.Patrolling, BEHAVIOUR.Alerted]):
		attention_point(point)
		if npc.current_behaviour == BEHAVIOUR.Idle:
			npc.state_chart.send_event("patrol")
		npc.state_chart.send_event("investigate")


## Reuse one hidden waypoint, owned by the NPC, across alerts and searches.
func attention_point(point: Vector3) -> void:
	if not is_instance_valid(_point):
		_point = CogitoPoint.new(null, false)
		npc.add_child(_point)
		_point.top_level = true
	_point.global_position = point
	npc.attention_target = _point


## Resolve one live, eligible identity in the same level, including during attention restore.
func eligible_actor(id: String) -> CogitoPlayerAdvanced:
	var avatar: Variant = players.avatar_for(id)
	if not avatar:
		return null
	var actor: CogitoPlayerAdvanced = avatar.actor
	if not is_instance_valid(actor) or actor.is_queued_for_deletion():
		return null
	if not players.peer_in_level(avatar.wield.owner_peer):
		return null
	if actor.is_dead or actor.network_input_blocked or not policy.eligible(npc, actor):
		return null
	return actor


## Current exact visible target, including a final life check immediately before damage.
func target() -> CogitoPlayerAdvanced:
	var row: Dictionary = candidates.get(target_id, {})
	if not row.get("visible", false):
		return null
	var avatar: Variant = players.avatar_for(target_id)
	if not avatar or avatar.lifetime != row.life:
		return null
	return eligible_actor(target_id)

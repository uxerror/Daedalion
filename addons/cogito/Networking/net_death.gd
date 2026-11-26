extends Node
## Server-owned life transitions and private, sender-bound respawn requests.

## Private acknowledgement of an invalid request, for custom death screens.
signal respawn_rejected(reason: String)
## Private reason for discarded movement, combat or carry input, once per dead incarnation.
signal gameplay_rejected(reason: String)

const Attributes := preload("net_attributes.gd")

var policy := CogitoRespawnPolicy.new()
var screen_scene: PackedScene
var damage_policy: Callable
var _deadlines := {}
var _profiles := {}
var _screen: Control


## Team or game hook. An empty attacker ID denotes the environment or an NPC.
func can_damage(attacker_player_id: String, victim_player_id: String, source: Node) -> bool:
	if damage_policy.is_valid():
		return damage_policy.call(attacker_player_id, victim_player_id, source)
	var config: Dictionary = get_parent().get_parent().config
	return attacker_player_id in ["", victim_player_id] or config.friendly_fire


## Resolve provenance on the server, including child hitboxes and carried or thrown bodies.
func allows_damage(victim: CogitoPlayer, source: Node, environment := false) -> bool:
	if not multiplayer.is_server() or victim.is_dead:
		return false
	var origin := source if not environment else null
	var attacker := ""
	while origin:
		if origin.has_meta(&"net_damage_owner"):
			attacker = origin.get_meta(&"net_damage_owner")
			break
		if origin is CogitoPlayer:
			attacker = origin.get_meta(&"net_player_id", "")
			break
		origin = origin.get_parent()
	return can_damage(attacker, victim.get_meta(&"net_player_id"), source)


## Retain the private session profile across disconnects. Deadlines stay on the server clock.
func detach(id: String, actor: CogitoPlayer) -> void:
	if multiplayer.is_server():
		var profile := {"attributes": Attributes.capture(actor)}
		if actor.is_dead:
			profile.equipped = actor.get_meta(&"net_wield").stack
			profile.quests = actor.saved_quest_progression.duplicate(true)
		_profiles[id] = profile
	if actor.is_local_presentation:
		close_screen()


## Restore a known life silently, including a zero-health join without a second penalty.
func attach(id: String, actor: CogitoPlayerAdvanced) -> void:
	if _profiles.has(id):
		var profile: Dictionary = _profiles[id]
		Attributes.apply(actor, profile.attributes)
		if profile.has("equipped"):
			actor.get_meta(&"net_wield").stack = profile.equipped
			actor.saved_quest_progression = profile.quests
	var health: CogitoAttribute = actor.player_attributes.get("health")
	if _deadlines.has(id) or (health and health.value_current <= 0):
		_deadlines.get_or_add(id, Time.get_ticks_msec())
		_freeze(actor)
		present(actor, true, remaining(id))


## The persistent life supersedes the connection-scoped death record on a new admission.
func forget(id: String) -> void:
	_profiles.erase(id)
	_deadlines.erase(id)


## Seconds until the server will accept a request.
func remaining(id: String) -> float:
	return maxf(0, (float(_deadlines.get(id, 0)) - Time.get_ticks_msec()) / 1000.0)


func _freeze(actor: CogitoPlayerAdvanced) -> void:
	actor.is_dead = true
	actor.velocity = Vector3.ZERO
	actor.main_velocity = Vector3.ZERO
	actor.current_command = actor.neutral_command(actor.last_consumed_sequence)
	actor.current_command.has_control = false
	actor.state_chart.process_mode = Node.PROCESS_MODE_DISABLED
	for attr: CogitoAttribute in actor.player_attributes.values():
		attr.set_meta(&"living_process_mode", attr.process_mode)
		attr.network_frozen = true
		attr.process_mode = Node.PROCESS_MODE_DISABLED


## Commit exactly one transition while this actor is the current live binding.
func die(actor: CogitoPlayerAdvanced) -> void:
	var id: String = actor.get_meta(&"net_player_id")
	var players := get_parent()
	var avatar: Variant = players.avatar_for(id)
	if not multiplayer.is_server() or actor.is_dead or not avatar or avatar.actor != actor:
		return
	var peer: int = players.peer_for_actor(actor)
	var delay: float = players.get_parent().config.respawn_delay
	_deadlines[id] = Time.get_ticks_msec() + ceil(delay * 1000.0)
	actor.is_dead = true
	actor.player_interaction_component.on_death()
	players.interactions.interrupt_actor(peer)
	players.interactions.devices.forget(peer)
	players.containers.forget(peer)
	actor.network_input_blocked = false
	avatar.wield.suspend()
	players.inventory.flush_actor(actor)
	_freeze(actor)
	players.mark_teleport(id)
	players.publish_vitals(id, Attributes.capture(actor))
	present(actor, true, remaining(id))
	policy.on_death(id)


## Owner presentation is idempotent for repeated baselines.
func present(actor: CogitoPlayerAdvanced, dead: bool, seconds: float) -> void:
	actor.is_dead = dead
	var rig := actor.get_node("Rig") as Node3D
	if dead and not rig.has_meta(&"living_rotation"):
		rig.set_meta(&"living_rotation", rig.rotation)
		rig.rotate_x(PI / 2)
	elif not dead and rig.has_meta(&"living_rotation"):
		rig.rotation = rig.get_meta(&"living_rotation")
		rig.remove_meta(&"living_rotation")
	if not actor.is_local_presentation:
		return
	if not dead:
		close_screen()
	elif not is_instance_valid(_screen):
		var players := get_parent()
		var wheels := actor.find_children("*", "CogitoQuickslotWheel", true, false)
		for wheel: CogitoQuickslotWheel in wheels:
			wheel.close(false)
		for menu: CogitoPauseMenu in actor.find_children("*", "CogitoPauseMenu", false, false):
			if not menu.is_queued_for_deletion():
				menu.close_pause_menu()
		players.interactions.close_view(actor.player_interaction_component)
		if actor.player_hud.is_inventory_visible():
			actor.player_hud.set_inventory_visibility(false)
		if screen_scene:
			_screen = screen_scene.instantiate()
			actor.player_hud.add_child(_screen)
		else:
			_screen = actor.player_hud.get_node("DeathScreen")
		_screen.open_online(actor, seconds, request_respawn)


## Release the local input owner when the avatar respawns or leaves.
func close_screen() -> void:
	if is_instance_valid(_screen):
		_screen.close_online()
		if screen_scene:
			_screen.queue_free()
	_screen = null


## Drop gameplay from a dead actor and bound feedback even for a continuous input stream.
func reject_dead_input(peer: int) -> bool:
	var players := get_parent()
	var id: String = players.get_parent().for_peer(peer).get("player_id", "")
	var avatar: Variant = players.avatar_for(id)
	if not avatar or not avatar.actor.is_dead:
		return false
	if avatar.actor.get_meta(&"rejected_dead_life", 0) != avatar.lifetime:
		avatar.actor.set_meta(&"rejected_dead_life", avatar.lifetime)
		if peer == 1:
			gameplay_rejected.emit("Player is dead")
		else:
			_dead_input.rpc_id(peer, avatar.lifetime)
	return true


@rpc("authority", "call_remote", "reliable", 0)
func _dead_input(life: int) -> void:
	var local: CogitoPlayer = get_parent().local_actor
	if local and local.get_meta(&"inventory_life") == life:
		gameplay_rejected.emit("Player is dead")


## The client submits only its observed incarnation. The transport selects the identity.
func request_respawn() -> void:
	var actor: CogitoPlayer = get_parent().local_actor
	if not actor:
		return
	var life: int = actor.get_meta(&"inventory_life")
	if multiplayer.is_server():
		_request_for(1, life)
	else:
		_request.rpc_id(1, life)


@rpc("any_peer", "call_remote", "reliable", 0)
func _request(life: int) -> void:
	if multiplayer.is_server():
		_request_for(multiplayer.get_remote_sender_id(), life)


func _request_for(peer: int, life: int) -> void:
	var players := get_parent()
	if not players.peer_in_level(peer):
		return
	var id: String = players.get_parent().for_peer(peer).player_id
	var reason := try_respawn(id, life)
	if reason:
		if peer == 1:
			respawn_rejected.emit(reason)
		else:
			_rejected.rpc_id(peer, reason)


@rpc("authority", "call_remote", "reliable", 0)
func _rejected(reason: String) -> void:
	respawn_rejected.emit(reason)


## Server entry point for requests and automatic policies. Empty string means accepted.
func try_respawn(id: String, life: int) -> String:
	var players := get_parent()
	var avatar: Variant = players.avatar_for(id)
	if not multiplayer.is_server() or not avatar or avatar.lifetime != life:
		return "Stale life"
	var actor: CogitoPlayerAdvanced = avatar.actor
	if not actor.is_dead or not _deadlines.has(id):
		return "Player is alive"
	if remaining(id) > 0:
		return "Respawn delay"
	var level: Node = CogitoLevel.root_of(actor)
	var start := respawn_transform(id, level)
	_deadlines.erase(id)
	for attr: CogitoAttribute in actor.player_attributes.values():
		attr.network_frozen = false
		attr.process_mode = attr.get_meta(&"living_process_mode", Node.PROCESS_MODE_INHERIT)
		if attr.has_method("reset_after_respawn"):
			attr.reset_after_respawn()
	policy.restore_attributes(actor)
	# A new life starts without the burning, poison or frost the player died with.
	if actor.cogito_properties:
		actor.cogito_properties.reset_element_state()
	if actor.actor_elements:
		actor.actor_elements.reset_element_state()
	actor.is_dead = false
	actor.position = start.origin
	actor.basis = Basis.IDENTITY
	actor.body.rotation = Vector3.UP * start.basis.get_euler().y
	actor.head.rotation.x = 0
	actor.neck.rotation = Vector3.ZERO
	actor.velocity = Vector3.ZERO
	actor.last_velocity = Vector3.ZERO
	actor.gravity_vec = Vector3.ZERO
	actor.try_crouch = false
	actor.is_jumping_started = false
	actor.state_chart.process_mode = Node.PROCESS_MODE_INHERIT
	actor.resume()
	actor.state_chart.send_event("grounded")
	actor.state_chart.send_event("idle")
	actor.state_chart.send_event("stand_up")
	actor.reset_physics_interpolation()
	players.renew_life(id)
	present(actor, false, 0)
	return ""


## Use the same enabled level markers for respawn and blocked reconnect placement.
func respawn_transform(id: String, level: Node) -> Transform3D:
	var points: Array[CogitoRespawnPoint] = []
	for point: CogitoRespawnPoint in level.find_children("*", "CogitoRespawnPoint", true, false):
		if point.enabled and CogitoLevel.root_of(point) == level:
			points.append(point)
	return policy.select(id, level, points)


## Called on the server tick so an automatic game policy shares all normal validation.
func check_automatic(id: String, life: int) -> void:
	if remaining(id) <= 0 and policy.auto_respawn(id):
		try_respawn(id, life)

extends RefCounted
## Install server state without entering the gameplay chart or invoking weapon equip/use hooks.

const BEHAVIOUR := CogitoNPC.BehaviourState

var npc: CogitoNPC
var players: Node
var dead := false
var target_id := ""
var running := false
var upper := &"Neutral"
var swing_tick := -1
## Last state the authority announced; compared each tick to detect changes.
var published := {}
var _previous_listener := Vector3i(-1, -1, -1)
var _original := {}
var _areas := {}


func _init(actor: CogitoNPC, session_players: Node) -> void:
	npc = actor
	players = session_players
	_original = {
		"mode": npc.process_mode,
		"layer": npc.collision_layer,
		"mask": npc.collision_mask,
		"avoidance": npc.nav_agent.avoidance_enabled,
		"visible": npc.visible,
		"animation": npc.animation_tree.process_mode,
		"priority": npc.process_physics_priority,
	}
	for area: Area3D in npc.find_children("*", "Area3D", true, false):
		_areas[area] = [area.monitoring, area.monitorable]


## Keep authoritative timers, chart, collisions and avoidance out of the replica simulation.
func disable_simulation() -> void:
	npc.state_chart.freeze()
	npc.process_mode = Node.PROCESS_MODE_DISABLED
	npc.animation_tree.process_mode = (
		Node.PROCESS_MODE_DISABLED if dead else Node.PROCESS_MODE_ALWAYS
	)
	if npc.weapon:
		npc.weapon.animation_player.process_mode = npc.animation_tree.process_mode
	npc.collision_layer = 0
	npc.collision_mask = 0
	npc.nav_agent.avoidance_enabled = false
	npc.health.network_frozen = true
	for area: Area3D in _areas:
		area.set_deferred("monitoring", false)
		area.set_deferred("monitorable", false)
	for timer: Timer in npc.find_children("*", "Timer", true, false):
		timer.stop()


## Publish the death before spawning dependent loot and a separately addressed corpse.
func die() -> void:
	if dead or not players.multiplayer.is_server():
		return
	dead = true
	target_id = ""
	swing_tick = -1
	npc.velocity = Vector3.ZERO
	disable_simulation()
	npc.hide()
	present_listener(Vector3i.ZERO)
	npc.net_changed.emit(&"")
	npc.health.death.emit()
	players.spawner.spawn_npc_remains(npc)
	players.combat.npc_event(npc, &"death", npc.global_position)


## Release presentation and restore a surviving level's authored processing on disconnect.
func restore() -> void:
	CogitoAudio.release_music_state(npc)
	npc.process_physics_priority = _original.priority
	if npc.sight_detection:
		npc.sight_detection.set_physics_process(true)
	if npc.hearing_detection:
		npc.hearing_detection.set_process(true)
	if dead:
		return
	npc.health.network_frozen = false
	npc.process_mode = _original.mode
	npc.animation_tree.process_mode = _original.animation
	npc.collision_layer = _original.layer
	npc.collision_mask = _original.mask
	npc.nav_agent.avoidance_enabled = _original.avoidance
	if npc.weapon:
		npc.weapon.animation_player.process_mode = Node.PROCESS_MODE_INHERIT
	npc.visible = _original.visible
	for area: Area3D in _areas:
		area.set_deferred("monitoring", _areas[area][0])
		area.set_deferred("monitorable", _areas[area][1])
	npc.state_chart.thaw()
	if not npc.state_chart._state.active:
		npc.state_chart._enter_initial_state.call_deferred()


## Replicated durable fields. A subclass of CogitoNPC may extend its MP2 state dictionary.
func capture() -> Dictionary:
	var health := npc.health
	return {
		"behaviour": npc.current_behaviour,
		"target": target_id,
		"upper": upper,
		"running": running,
		"swing": swing_tick,
		"weapon_visible": npc.weapon != null and npc.weapon.wieldable_mesh.visible,
		"health": health.value_current / maxf(0.001, health.value_max),
		"dead": dead,
	}


func apply(fields: Dictionary) -> void:
	if fields.is_empty():
		return
	npc.current_behaviour = fields.behaviour
	target_id = fields.target
	upper = fields.upper
	running = fields.running
	if fields.dead:
		npc.hide()
		npc.animation_tree.process_mode = Node.PROCESS_MODE_DISABLED
		if npc.weapon:
			npc.weapon.animation_player.process_mode = Node.PROCESS_MODE_DISABLED
	npc.health.set_block_signals(true)
	npc.health.apply_replica_value(fields.health * npc.health.value_max, npc.health.value_max)
	npc.health.set_block_signals(false)
	dead = fields.dead
	var playback: AnimationNodeStateMachinePlayback = npc.animation_tree.get(
		"parameters/UpperBodyState/playback"
	)
	if playback and playback.get_current_node() != upper:
		playback.start(upper)
	if fields.swing >= 0 and swing_tick != fields.swing and not dead:
		npc.animation_tree.set(
			"parameters/UpperBodyState/RaisedFists/attack/request",
			AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE
		)
		npc.animation_tree.advance(fields.get("swing_age", 0.0))
	swing_tick = fields.swing
	if npc.weapon:
		npc.weapon.wieldable_mesh.visible = fields.weapon_visible


## Add elapsed time only to transmitted poses so the swing clock never dirties an idle batch.
func at_send_time(fields: Dictionary) -> Dictionary:
	if swing_tick < 0:
		return fields
	var sample := fields.duplicate()
	var frames := Engine.get_physics_frames() - swing_tick
	sample.swing_age = float(frames) / Engine.physics_ticks_per_second
	return sample


## Install locomotion velocity without moving the character controller.
func motion(linear: Vector3) -> void:
	npc.velocity = linear
	var local := npc.global_basis.inverse() * linear
	var speed := npc.sprint_speed if running else npc.walk_speed * 2.0
	var blend := Vector2(local.x, -local.z) / maxf(0.001, speed)
	npc.animation_tree.set("parameters/Movement/blend_position", blend.limit_length(1.0))


## The same MP4 radius gates initial state, interest transitions and live NPC cosmetics.
func in_interest(point: Vector3) -> bool:
	return npc.global_position.distance_squared_to(point) <= players.bodies.INTEREST ** 2


## Listener-specific durable values, quantized so an idle listener generates no traffic.
func listener(id: String) -> Vector3i:
	var memory := npc.perception
	if dead or not memory or not memory.candidates.has(id):
		return Vector3i.ZERO
	var row: Dictionary = memory.candidates[id]
	if row.distance > players.bodies.INTEREST:
		return Vector3i.ZERO
	var sight := npc.sight_detection
	var hearing := npc.hearing_detection
	var looking := roundi(100 * row.sight / maxf(0.001, sight.aggro_threshold)) if sight else 0
	var noise := 0
	if hearing:
		var threshold := maxf(0.001, hearing.suspicion_threshold_before_investigating)
		noise = roundi(100 * row.hearing / threshold)
	var combat := id == target_id and npc.in_state([BEHAVIOUR.Chasing, BEHAVIOUR.Attacking])
	if npc.current_behaviour == BEHAVIOUR.Searching and memory.search_id == id:
		combat = true
	return Vector3i(looking, noise, int(combat))


func present_listener(value: Vector3i) -> void:
	if value == _previous_listener:
		return
	_previous_listener = value
	var detector := npc.sight_detection
	var ear := npc.hearing_detection
	var sight := detector.sight_suspicion_indicator if detector else null
	var hearing := ear.noise_suspicion_indicator if ear else null
	if sight:
		var threshold := detector.investigation_threshold / maxf(0.001, detector.aggro_threshold)
		sight.is_investigating = value.x >= 100 * threshold
		sight.update(value.x, 100)
		sight.visible = value.x > 0
	if hearing:
		hearing.update(value.y, 100)
		hearing.visible = value.y > 0
	var music := npc.combat_music_state
	if value.z and not music:
		music = CogitoAudio.get_scene_combat_music_state()
	if value.z and music:
		CogitoAudio.push_music_state(music, npc)
	else:
		CogitoAudio.release_music_state(npc)

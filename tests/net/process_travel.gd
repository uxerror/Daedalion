extends Node
## Drives real demo doors using test-only files. All travel and gameplay use normal endpoints.

const LOBBY := "res://addons/cogito/DemoScenes/COGITO_3_Lobby.tscn"
const TO_LAB := "MAIN_LOBBY/LAB_CONNECTOR/TransitionZone_LAB"
const TO_LOBBY := "CONNECTOR_TO_LOBBY/TransitionZone_LOBBY"

var _control := OS.get_environment("COGITO_TEST_CONTROL")
var _order := 0
var _sample_time := 0
var _baseline_time := 0
var _measurements: Array[float] = []
var _previous_tick := 0
var _max_gap := 0


func _ready() -> void:
	if CogitoNet.is_server():
		var err: Error = CogitoNet.player_world.travel.start(CogitoNet.starting_level(LOBBY))
		if err != OK:
			push_error("Cannot start travel fixture")
			get_tree().quit(2)


func _physics_process(_delta: float) -> void:
	if not CogitoNet.is_online():
		return
	var travel: Node = CogitoNet.player_world.travel
	if _previous_tick:
		var tick := Time.get_ticks_usec()
		_max_gap = maxi(_max_gap, tick - _previous_tick)
		_previous_tick = tick
	var path := _control.path_join("order-%d" % (_order + 1))
	if FileAccess.file_exists(path):
		_order += 1
		var cmd: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		_apply(cmd, travel)
	var now := Time.get_ticks_msec()
	if _baseline_time and now >= _baseline_time:
		_measurements.append(1000.0 * Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS))
		_baseline_time = now + 1050 if _measurements.size() < 5 else 0
		if not _baseline_time:
			var report := {"physics_ms": _measurements, "cross_gap_ms": _max_gap / 1000.0}
			print("NET TICK ", JSON.stringify(report))
	if now >= _sample_time:
		_sample_time = now + 100
		_sample(travel)


func _apply(cmd: Dictionary, travel: Node) -> void:
	if cmd.op == "measure":
		_measurements.clear()
		_previous_tick = 0
		_baseline_time = Time.get_ticks_msec() + 3100
	elif cmd.op == "interact":
		var endpoint: Node = travel.endpoint_for(CogitoNet.local_player_id())
		var component: Node = endpoint.active_level().get_node("GenericSwitch/BasicInteraction")
		endpoint.interactions.submit(component, &"interact")
	else:
		for record in CogitoNet.players():
			if record.display_name != cmd.who:
				continue
			var endpoint: Node = travel.endpoint_for(record.player_id)
			var root: Node3D = endpoint.active_level()
			var actor: CogitoPlayer = endpoint.avatar_for(record.player_id).actor
			if cmd.op == "cross":
				_previous_tick = Time.get_ticks_usec()
				_max_gap = 0
				var zone := root.get_node(TO_LAB if root.scene_file_path == LOBBY else TO_LOBBY)
				actor.global_position = zone.global_position
			elif cmd.op == "stage":
				actor.global_position = root.get_node("GenericSwitch").global_position
				actor.global_position += Vector3(0, -0.8, 0.75)
			actor.velocity = Vector3.ZERO
			endpoint.mark_teleport(record.player_id)


func _sample(travel: Node) -> void:
	var actors := {}
	for record in CogitoNet.players():
		var endpoint: Node = travel.endpoint_for(record.player_id)
		if not endpoint:
			continue
		var p: Vector3 = endpoint.avatar_for(record.player_id).actor.position
		actors[record.display_name] = [endpoint.world.entities.level_key, p.x, p.y, p.z]
	var surface := ""
	var local := CogitoNet.local_player()
	if local:
		surface = CogitoLevel.root_of(local).scene_file_path
	var switch_on := false
	var lobby: Node = travel.levels.get(LOBBY)
	if lobby:
		switch_on = lobby.active_level().get_node("GenericSwitch").is_on
	var data := {
		"actors": actors,
		"local": surface,
		"levels": travel.levels.size(),
		"order": _order,
		"switch": switch_on,
	}
	print("NET POS ", JSON.stringify(data))

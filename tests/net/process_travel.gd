extends Node
## Drives real demo doors using test-only files. All travel and gameplay use normal endpoints.

const LOBBY := "res://addons/cogito/DemoScenes/COGITO_3_Lobby.tscn"
const LAB := "res://addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn"
const TO_LAB := "MAIN_LOBBY/LAB_CONNECTOR/TransitionZone_LAB"
const TO_LOBBY := "CONNECTOR_TO_LOBBY/TransitionZone_LOBBY"

var _control := OS.get_environment("COGITO_TEST_CONTROL")
var _order := 0
var _sample_time := 0
var _baseline_time := 0
var _measurements: Array[float] = []
var _previous_tick := 0
var _max_gap := 0
var _watch_snapshots := false
var _last_snapshot := 0
var _snapshot_gap := 0
var _snapshot_count := 0
var _route: PredictionRoute


class PredictionRoute:
	extends CogitoPlayerInputSource
	const ACTION := CogitoPlayerCommand.Action
	const MODE := CogitoPlayerAdvanced.MovingState
	var ticks := 0
	var start_y: float
	var rise := 0.0
	var returned := false
	var sliding := false
	var slide_jump := false
	var requested_slide := false

	func sample(actor: CogitoPlayer, seq: int) -> CogitoPlayerCommand:
		var cmd := super.sample(actor, seq)
		var player := actor as CogitoPlayerAdvanced
		var mode := player.current_moving_state
		if ticks == 0:
			start_y = actor.position.y
		if rise < 0.55:
			rise = maxf(rise, actor.position.y - start_y)
			cmd.move = Vector2.UP
		elif not returned:
			cmd.move = Vector2.DOWN
			returned = actor.position.z > 0 and absf(actor.position.y - start_y) < 0.03
		elif not slide_jump:
			cmd.move = Vector2.DOWN
			cmd.held = 1 << ACTION.SPRINT
			requested_slide = requested_slide or mode == MODE.Sprinting
			if requested_slide:
				cmd.held |= 1 << ACTION.CROUCH
			if mode == MODE.Sliding and not sliding:
				sliding = true
				cmd.add_edge(ACTION.JUMP)
			if sliding:
				cmd.held |= 1 << ACTION.JUMP
				slide_jump = mode == MODE.Jumping
		cmd.toggle_crouch = false
		cmd.yaw = 0
		cmd.pitch = 0
		ticks += 1
		return cmd


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
	if _watch_snapshots:
		var endpoint: Node = travel.endpoint_for(CogitoNet.local_player_id())
		var arrival: int = endpoint.avatar_for(CogitoNet.local_player_id()).timeline._arrival_usec
		if arrival > _last_snapshot:
			if _last_snapshot:
				_snapshot_gap = maxi(_snapshot_gap, arrival - _last_snapshot)
			_snapshot_count += 1
			_last_snapshot = arrival
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
	if cmd.op == "lane":
		var root: Node3D = travel.levels[LOBBY].active_level()
		var lane := preload("../player/golden_level.tscn").instantiate() as Node3D
		# Give the delayed server-pose path a landing before it turns to descend.
		var top: CollisionShape3D = lane.get_node("Obstacles/Step3")
		var landing := top.shape.duplicate() as BoxShape3D
		landing.size.z += 4
		top.shape = landing
		top.position.z -= 2
		lane.position.y = 50
		root.add_child(lane)
		var chair: CogitoSittable = root.get_node("CogitoSittable2")
		chair.position = Vector3(4, 50.1, 0)
		chair.sit_area_behaviour = CogitoSittable.SitAreaBehaviour.NONE
	elif cmd.op == "route":
		_route = PredictionRoute.new()
		CogitoNet.local_player().input_source = _route
	elif cmd.op == "chair":
		var endpoint: Node = travel.endpoint_for(CogitoNet.local_player_id())
		var interaction: Node = endpoint.active_level().get_node("CogitoSittable2/BasicInteraction")
		endpoint.interactions.submit(interaction, &"interact")
	elif cmd.op == "watch":
		_watch_snapshots = true
	elif cmd.op == "report":
		_watch_snapshots = false
		print("NET SNAPSHOTS ", _snapshot_count, " gap_ms=", _snapshot_gap / 1000.0)
	elif cmd.op == "measure":
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
			elif cmd.op == "lane_start":
				actor.position = Vector3(-4, 51, 0)
			elif cmd.op == "chair_start":
				actor.position = Vector3(4, 51, 1.1)
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
		"lab_frozen": travel.residency.frozen(LAB),
		"order": _order,
		"switch": switch_on,
	}
	var player := local as CogitoPlayerAdvanced
	data.seated = player != null and player.is_sitting
	data.predicting = (
		player != null and player.owner_prediction != null and player.owner_prediction.active
	)
	data.controller = player != null and player.owner_prediction != null
	if _route:
		data.route = [_route.ticks, _route.rise, _route.returned, _route.sliding, _route.slide_jump]
		data.route_rest = (
			player != null
			and player.current_moving_state == CogitoPlayerAdvanced.MovingState.Idle
			and player.velocity.length() < 0.01
		)
	if player and player.owner_prediction:
		data.suspensions = player.owner_prediction.reasons
	print("NET POS ", JSON.stringify(data))

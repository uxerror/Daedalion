extends Node
## Process control is out-of-band. Commands, poses and acknowledgements take the game path.

const Level := preload("res://tests/player/movement_level.tscn")
const Probe := preload("latency_probe.gd")
const Schedule := preload("packet_schedule.gd")

var probe: Probe
var generation := 0
var peer_id: int
var rtt := -1
var pending := ""
var settled_ticks := 0


func _ready() -> void:
	var level := Level.instantiate()
	add_child(level)
	CogitoNet.player_world.bind_level(level, Transform3D(Basis.IDENTITY, Vector3.UP), "arena")


func _physics_process(_delta: float) -> void:
	if not CogitoNet.is_online() or CogitoNet.players().is_empty():
		return
	if not probe:
		var record: Dictionary = CogitoNet.players()[0]
		var avatar := CogitoNet.player_world.avatar_for(record.player_id)
		if not avatar:
			return
		peer_id = record.peer_id if CogitoNet.is_server() else 1
		probe = Probe.new()
		probe.attach(CogitoNet, record.player_id)
		probe.phase_complete.connect(_complete)
	var file := OS.get_environment("COGITO_TEST_CONTROL").path_join("trial-%d" % (generation + 1))
	if FileAccess.file_exists(file):
		generation += 1
		var trial: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(file))
		pending = trial.action
		settled_ticks = 0
		if rtt != int(trial.rtt):
			rtt = int(trial.rtt)
			var peer := multiplayer.multiplayer_peer
			if peer.has_method("configure"):
				peer.configure(peer_id, 1, Schedule.profile(rtt))
				peer.schedule.reset_stats()
	if pending.is_empty():
		return
	var actor := probe.avatar.actor
	if actor.current_moving_state == CogitoPlayerAdvanced.MovingState.Idle:
		settled_ticks += 1
	else:
		settled_ticks = 0
	if settled_ticks >= 20:
		probe.arm(pending)
		pending = ""
		print("NET ARMED ", generation)


func _complete(result: Dictionary) -> void:
	var stamps := result.duplicate()
	var peer := multiplayer.multiplayer_peer
	if peer.has_method("configure"):
		var mode := MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		if CogitoNet.is_server():
			mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
		stamps.delivered_ms = peer.schedule.mean_delay_ms(peer_id, 1, mode)
	print("NET LATENCY ", JSON.stringify(stamps))

extends SceneTree
## Standalone headless probe. Use an empty XDG_DATA_HOME and pin the process to one CPU.

const ROOMS := [
	"res://addons/cogito/DemoScenes/COGITO_3_Lobby.tscn",
	"res://addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn",
	"res://tests/net/travel_a.tscn",
]

var _now := 0


func _initialize() -> void:
	_run.call_deferred()


func _memory() -> Array[int]:
	var file := FileAccess.open("/proc/self/status", FileAccess.READ)
	while file and not file.eof_reached():
		var line := file.get_line()
		if line.begins_with("VmRSS:"):
			return [OS.get_static_memory_usage(), line.trim_prefix("VmRSS:").to_int() * 1024]
	return [OS.get_static_memory_usage(), -1]


func _measure(count: int, frozen: bool) -> void:
	await create_timer(3.1).timeout
	var samples: Array[float] = []
	for i in 5:
		if i:
			await create_timer(1.05).timeout
		samples.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000)
	print("RESIDENCY ", [count, frozen, _memory(), samples])


func _run() -> void:
	var net := root.get_node("CogitoNet")
	var suite: Script = load("res://tests/net/memory_session_suite.gd")
	net.transport_factory = func(): return suite.MemoryTransport.new({}, 1)
	var config := {"level_residency": "keep_visited", "autosave_seconds": 0}
	if net.start_server(config) != OK:
		quit(1)
		return
	var travel: Node = net.player_world.travel
	net.player_world.persistence.clock = func() -> int: return _now
	print("RESIDENCY empty ", _memory())
	for i in ROOMS.size():
		var path: String = ROOMS[i]
		for key: String in travel.levels:
			travel.residency.wake(key, travel.levels[key])
			travel._track_empty(key)
		if i == 0:
			if travel.start(path) != OK:
				quit(1)
				return
		else:
			var room: Node = travel._install(path, load(path))
			if not room:
				quit(1)
				return
			travel._track_empty(path)
		await _measure(i + 1, false)
		_now += 61000
		travel.advance()
		for key: String in travel.levels:
			assert(travel.residency.frozen(key))
		await _measure(i + 1, true)
	quit(0 if net.disconnect_session() == OK else 1)

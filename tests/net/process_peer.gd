extends Node
## Process fixture. Python coordinates peers using stdout records and a graceful stop file.

const ProcessTravel := preload("process_travel.gd")

var _args := {}
var _admitted := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for index in range(0, args.size(), 2):
		_args[args[index]] = args[index + 1]
	if OS.has_environment("COGITO_FILE_BUS"):
		CogitoNet.transport_factory = func(): return preload("file_transport.gd").new()
	if _args["--role"] in ["menu", "export-client"]:
		var driver := preload("process_menu.gd").new()
		driver.args = _args
		get_tree().root.add_child.call_deferred(driver)
		set_process(false)
		return
	CogitoNet.session_ready.connect(_admitted_session)
	CogitoNet.session_failed.connect(_failed)
	CogitoNet.player_joined.connect(_roster_changed)
	CogitoNet.player_left.connect(_roster_changed)
	var port := int(_args["--port"])
	if _args["--role"] == "authority":
		var config := {
			"port": port,
			"world": _args.get("--world", "default"),
			"autosave_seconds": int(_args.get("--autosave-seconds", "60")),
			"save_dir": _args["--save-dir"],
			"friendly_fire": _args.get("--friendly-fire", "true") == "true",
			"respawn_delay": 1.5,
		}
		if _args.get("--travel") == "preload":
			config.level_residency = "preload_all"
			config.level = ProcessTravel.LOBBY
			config.preload_levels = ["auto"]
			config.level_grace_seconds = 0
		if CogitoNet.start_server(config) == OK:
			print("NET READY port=%d" % port)
		else:
			get_tree().quit(1)
	elif _args["--role"] == "host":
		var config := {
			"port": port,
			"world": _args.get("--world", "default"),
			"autosave_seconds": int(_args.get("--autosave-seconds", "60")),
			"bind": "127.0.0.1",
			"display_name": "Host",
			"max_players": 2,
			"respawn_delay": 1.5,
			"save_dir": _args["--save-dir"],
		}
		if CogitoNet.host(config) == OK:
			print("NET READY port=%d" % port)
		else:
			get_tree().quit(1)
	else:
		var credentials := {"display_name": _args["--name"]}
		if _args.has("--content"):
			credentials.content_version = _args["--content"]
		CogitoNet.join(_args.get("--address", "127.0.0.1"), port, credentials)


func _admitted_session() -> void:
	if _args.has("--travel"):
		add_child.call_deferred(ProcessTravel.new())
	elif _args["--role"] == "authority":
		_start_dedicated_arena.call_deferred()
	else:
		add_child.call_deferred(preload("process_arena.tscn").instantiate())
	_admitted = true
	_roster_changed("")


func _start_dedicated_arena() -> void:
	var path := CogitoNet.starting_level("res://tests/net/process_arena.tscn")
	if CogitoNet.player_world.travel.start(path) != OK:
		_invariant_failed("Cannot start dedicated arena")


func _roster_changed(_id: String) -> void:
	if not _admitted or not CogitoNet.is_online() or CogitoNet.is_dedicated():
		return
	var roster := CogitoNet.players()
	var local_id := CogitoNet.local_player_id()
	var local := CogitoNet.player_for_peer(multiplayer.get_unique_id())
	if local.get("player_id", "") != local_id or local_id.is_empty():
		_invariant_failed("Missing local player")
		return
	for record: Dictionary in roster:
		if CogitoNet.player_for_id(record.player_id) != CogitoNet.player_for_peer(record.peer_id):
			_invariant_failed("Roster indices disagree")
			return
	print("NET STATE ", JSON.stringify({"local": local_id, "roster": roster}))


func _failed(reason: String) -> void:
	_admitted = false
	print("NET FAILED ", JSON.stringify(reason))


func _invariant_failed(reason: String) -> void:
	push_error(reason)
	get_tree().quit(2)


func _process(_delta: float) -> void:
	if FileAccess.file_exists(_args["--stop"]):
		_admitted = false
		CogitoNet.disconnect_session()
		get_tree().quit()

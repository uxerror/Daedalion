extends Control
## The normal build also accepts --server. Its menu must never enter the dedicated tree.

const NET_CONFIG := preload("../Networking/net_config.gd")

## The command-line session starts once; returning to the menu shows the normal menu.
static var _network_started := false


func _enter_tree() -> void:
	var args := OS.get_cmdline_user_args()
	var wants_network := ("--host" in args or "--join" in args) and not _network_started
	if CogitoNet.dedicated_boot or wants_network:
		var menu := get_node("MainMenu")
		remove_child(menu)
		menu.free()
		if not CogitoNet.dedicated_boot:
			_network_started = true
			_start_network_demo.call_deferred(args)


func _start_network_demo(args: PackedStringArray) -> void:
	var port: int = NET_CONFIG.DEFAULT_PORT
	var port_index := args.find("--port")
	if port_index >= 0:
		port = int(args[port_index + 1]) if port_index + 1 < args.size() else 0
	CogitoNet.session_failed.connect(_failed)
	var load_level := get_tree().change_scene_to_file.bind(NET_CONFIG.DEMO_LEVEL)
	CogitoNet.session_ready.connect(load_level, CONNECT_DEFERRED | CONNECT_ONE_SHOT)
	if "--host" in args:
		CogitoNet.host({"port": port, "bind": "0.0.0.0"})
	else:
		var index := args.find("--join") + 1
		CogitoNet.join(args[index] if index < args.size() else "", port)


func _failed(reason: String) -> void:
	printerr("Multiplayer startup failed: ", reason)
	get_tree().quit(1)

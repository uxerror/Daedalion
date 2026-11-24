extends Control
## The normal build also accepts --server. Its menu must never enter the dedicated tree.

const NET_CONFIG := preload("../Networking/net_config.gd")


func _enter_tree() -> void:
	var args := OS.get_cmdline_user_args()
	if CogitoNet.dedicated_boot or "--host" in args or "--join" in args:
		var menu := get_node("MainMenu")
		remove_child(menu)
		menu.free()
		if not CogitoNet.dedicated_boot:
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

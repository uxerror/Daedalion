extends Control
## Both the CLI and EasyMenus use the same level startup and session lifecycle.

const NetConfig := preload("../Networking/net_config.gd")

static var _network_started := false


func _ready() -> void:
	if CogitoNet.dedicated_boot:
		return
	var menu := CogitoGlobals.cogito_settings.main_menu_scene.instantiate()
	add_child(menu)
	var args := OS.get_cmdline_user_args()
	if not _network_started and ("--host" in args or "--join" in args):
		_network_started = true
		_start_network_demo.call_deferred(args)


func _start_network_demo(args: PackedStringArray) -> void:
	if "--host" in args:
		var config := NetConfig.parse_cli(args, true)
		if config.has("reason"):
			_failed(config.reason)
		elif CogitoNet.menu.host(config) != OK:
			_failed(CogitoNet.menu.status)
	else:
		var index := args.find("--join") + 1
		var address := args[index] if index < args.size() else ""
		var port := NetConfig.DEFAULT_PORT
		var port_index := args.find("--port")
		if port_index >= 0:
			port = int(args[port_index + 1]) if port_index + 1 < args.size() else 0
		CogitoNet.session_failed.connect(_startup_failed)
		if CogitoNet.menu.join(address, port, CogitoNet.menu.player_name()) != OK:
			_failed(CogitoNet.menu.status)


func _startup_failed(reason: String) -> void:
	if CogitoNet.menu.return_message.is_empty():
		_failed(reason)


func _failed(reason: String) -> void:
	printerr("Multiplayer startup failed: ", reason)
	get_tree().quit(1)

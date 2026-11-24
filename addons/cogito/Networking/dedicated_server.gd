extends Node
## Simulation-only main scene for standard and dedicated-feature builds.

const NetConfig := preload("net_config.gd")


func _ready() -> void:
	var config := NetConfig.parse_cli(OS.get_cmdline_user_args())
	if config.has("reason"):
		push_error("CogitoNet: " + String(config.reason))
		get_tree().quit(1)
		return
	if CogitoNet.start_server(config) != OK:
		get_tree().quit(1)
		return
	print("NET READY port=%d" % config.port)

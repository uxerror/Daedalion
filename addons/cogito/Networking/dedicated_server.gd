extends Node
## Simulation-only main scene for standard and dedicated-feature builds.

const ProfileTools := preload("net_profile_tools.gd")
const NetConfig := preload("net_config.gd")


func _ready() -> void:
	var config := NetConfig.parse_cli(OS.get_cmdline_user_args())
	if config.has("reason"):
		push_error("CogitoNet: " + String(config.reason))
		get_tree().quit(1)
		return
	if not config.profile_command.is_empty():
		var tools := ProfileTools.new()
		tools.has_progress = CogitoNet.profile_has_progress
		var err := tools.stopped(config)
		print("NET PROFILE COMMAND ", error_string(err))
		get_tree().quit(0 if err == OK else 1)
		return
	if CogitoNet.start_server(config) != OK:
		get_tree().quit(1)
		return
	_load_level.call_deferred(CogitoNet.starting_level(config.level), config.port)


func _load_level(path: String, port: int) -> void:
	var err: Error = CogitoNet.player_world.travel.start(path)
	if err == OK:
		print("NET READY port=%d" % port)
	else:
		push_error("Cannot load dedicated level %s (%s)" % [path, error_string(err)])
		get_tree().quit(1)

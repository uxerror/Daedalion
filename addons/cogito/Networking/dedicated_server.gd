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
	_load_level.call_deferred(CogitoNet.starting_level(config.level), config.port)


func _load_level(path: String, port: int) -> void:
	var tree := get_tree()
	var err := tree.change_scene_to_file(path)
	if err != OK:
		push_error("Cannot load dedicated level %s (%s)" % [path, error_string(err)])
		tree.quit(1)
		return
	tree.scene_changed.connect(_level_ready.bind(tree, port), CONNECT_ONE_SHOT | CONNECT_DEFERRED)


static func _level_ready(tree: SceneTree, port: int) -> void:
	if not CogitoNet.player_world or not CogitoNet.player_world.active_level():
		push_error("Dedicated scene did not bind its multiplayer level")
		tree.quit(1)
		return
	print("NET READY port=%d" % port)

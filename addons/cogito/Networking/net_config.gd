extends RefCounted
## Session configuration shared by programmatic startup and the dedicated CLI.

const WorldFiles := preload("../SceneManagement/cogito_world_files.gd")
const PROTOCOL_VERSION := 13
const DEMO_LEVEL := "res://addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn"
const ENET_CEILING := 4095
const DEFAULT_PORT := 7777
const DEFAULT_SAVE_DIR := "user://net/server"
const CLI_FLAGS := [
	"--config",
	"--bind",
	"--port",
	"--max-players",
	"--save-dir",
	"--world",
	"--autosave-seconds",
	"--level-grace-seconds",
	"--travel-timeout-seconds",
	"--profile-command",
	"--import-slot",
	"--import-player",
	"--level",
	"--friendly-fire",
	"--respawn-delay",
]


## Reads the template version only when an online session needs it.
static func content_version() -> String:
	var plugin := ConfigFile.new()
	if plugin.load("res://addons/cogito/plugin.cfg") != OK:
		return ""
	return plugin.get_value("plugin", "version", "")


## Returns a printable rejection reason, or an empty string for a compatible client.
static func version_error(protocol: int, content: String, expected: String) -> String:
	if protocol != PROTOCOL_VERSION:
		return "Protocol version mismatch"
	if content != expected:
		return "Content version mismatch"
	return ""


## Returns the validated settings, or a dictionary containing a reason.
static func server_config(input: Dictionary, listen: bool) -> Dictionary:
	var limit := ENET_CEILING + int(listen)
	var config := {
		"bind": "127.0.0.1",
		"port": DEFAULT_PORT,
		"max_players": limit,
		"save_dir": DEFAULT_SAVE_DIR,
		"content_version": content_version(),
		"display_name": "Host",
		"level": DEMO_LEVEL,
		"world": "default",
		"autosave_seconds": 60,
		"level_grace_seconds": 60,
		"travel_timeout_seconds": 30,
		"import_slot": "",
		"profile_command": "",
		"import_player": "",
		"friendly_fire": true,
		"respawn_delay": 10.0,
	}
	for key: Variant in input:
		if key == "respawn_delay" and input[key] is int:
			continue
		if not config.has(key) or typeof(input[key]) != typeof(config[key]):
			return {"reason": "Invalid configuration key or type: %s" % key}
	config.merge(input, true)
	config.respawn_delay = float(config.respawn_delay)
	return _validate(config, limit)


static func _validate(config: Dictionary, limit: int) -> Dictionary:
	var persistence_error := _validate_persistence(config)
	if not persistence_error.is_empty():
		return {"reason": persistence_error}
	if config.bind != "*" and not String(config.bind).is_valid_ip_address():
		return {"reason": "Invalid bind address"}
	if config.port < 1 or config.port > 65535:
		return {"reason": "Port must be in 1..65535"}
	if config.max_players < 1 or config.max_players > limit:
		return {"reason": "max_players must be in 1..%d" % limit}
	var save_dir: String = config.save_dir
	if save_dir.strip_edges().is_empty() or String(config.content_version).is_empty():
		return {"reason": "Missing save_dir or content_version"}
	return config


static func _validate_persistence(config: Dictionary) -> String:
	if not is_finite(config.respawn_delay) or config.respawn_delay < 0:
		return "Expected finite nonnegative respawn_delay"
	if not WorldFiles.valid_name(config.world):
		return "Invalid world directory name"
	if config.level_grace_seconds < 0 or config.travel_timeout_seconds < 1:
		return "Invalid travel grace or readiness timeout"
	if config.autosave_seconds < 0:
		return "Expected nonnegative autosave_seconds"
	return ""


## Parses the arguments after --. CLI values override the [server] section in any order.
static func parse_cli(args: PackedStringArray, listen := false) -> Dictionary:
	var overrides := {}
	var path := ""
	var index := 0
	while index < args.size():
		var flag := args[index]
		index += 1
		if flag == "--server" or (listen and flag == "--host"):
			continue
		if flag not in CLI_FLAGS:
			return {"reason": "Unknown server option: " + flag}
		if index == args.size() or args[index].begins_with("--"):
			return {"reason": "Missing value for " + flag}
		var value := args[index]
		index += 1
		if flag == "--config":
			path = value
		else:
			var key := flag.trim_prefix("--").replace("-", "_")
			var parsed: Variant = _cli_value(key, value)
			if parsed == null:
				return {"reason": "Invalid value for " + flag}
			overrides[key] = parsed
	var config := {}
	if not path.is_empty():
		var file := ConfigFile.new()
		if file.load(path) != OK or not file.has_section("server"):
			return {"reason": "Cannot read [server] from " + path}
		for key: String in file.get_section_keys("server"):
			config[key] = file.get_value("server", key)
	config.merge(overrides, true)
	if listen and not config.has("bind"):
		config.bind = "0.0.0.0"
	return server_config(config, listen)


static func _cli_value(key: String, value: String) -> Variant:
	match key:
		"friendly_fire":
			if value in ["true", "false"]:
				return value == "true"
		"respawn_delay":
			if value.is_valid_float():
				return value.to_float()
		"port", "max_players", "autosave_seconds", "level_grace_seconds", "travel_timeout_seconds":
			if value.is_valid_int():
				return value.to_int()
		_:
			return value
	return null

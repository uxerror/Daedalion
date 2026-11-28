extends RefCounted
## Session configuration shared by programmatic startup and the dedicated CLI.

const WorldFiles := preload("../SceneManagement/cogito_world_files.gd")
const PROTOCOL_VERSION := 19
## Keep equal to `version` in addons/cogito/plugin.cfg (net_core_test checks it).
const CONTENT_VERSION := "1.3.1"
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
	"--level-residency",
	"--level-grace-seconds",
	"--preload-levels",
	"--travel-timeout-seconds",
	"--profile-command",
	"--import-slot",
	"--import-player",
	"--level",
	"--friendly-fire",
	"--respawn-delay",
]

static var owner_prediction := OS.get_environment("COGITO_OWNER_PREDICTION") == "1"


## Default content version: the bundled plugin.cfg `version` (a test keeps them equal).
## Not read from plugin.cfg at run time: exports omit non-resource files unless a preset
## lists them, and an exported client would then announce "" and be refused.
static func content_version() -> String:
	return CONTENT_VERSION


## Returns a printable rejection reason, or an empty string for a compatible client.
static func version_error(protocol: int, content: String, expected: String) -> String:
	if protocol != PROTOCOL_VERSION:
		return "Protocol version mismatch"
	if content != expected:
		return "Content version mismatch"
	return ""


## Labels must fit the public roster and operator request on a single line.
static func valid_display_name(value: String) -> bool:
	if value.strip_edges().is_empty() or value.length() > 64:
		return false
	for index in value.length():
		if value.unicode_at(index) < 32 or value.unicode_at(index) == 127:
			return false
	return true


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
		"level_residency": "stream",
		"preload_levels": [],
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
	var persistence_error := _validate_residency(config)
	if persistence_error.is_empty():
		persistence_error = _validate_persistence(config)
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


static func _validate_residency(config: Dictionary) -> String:
	if config.level_residency not in ["stream", "keep_visited", "preload_all"]:
		return "Expected level_residency stream, keep_visited or preload_all"
	for path: Variant in config.preload_levels:
		if not path is String:
			return "Expected scene paths in preload_levels"
		if path != "auto" and not path.begins_with("res://") and not path.begins_with("uid://"):
			return "Invalid preload_levels entry: " + path
	return ""


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
		"preload_levels":
			# Comma-separated scene paths or UIDs; "auto" follows transition zones.
			var paths: Array = []
			for entry in value.split(",", false):
				paths.append(entry.strip_edges())
			return paths
		_:
			return value
	return null

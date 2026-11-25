extends RefCounted
## Session configuration shared by programmatic startup and the dedicated CLI.

const PROTOCOL_VERSION := 6
const DEMO_LEVEL := "res://addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn"
const ENET_CEILING := 4095
const DEFAULT_PORT := 7777
const DEFAULT_SAVE_DIR := "user://net/server"


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
	}
	for key: Variant in input:
		if not config.has(key) or typeof(input[key]) != typeof(config[key]):
			return {"reason": "Invalid configuration key or type: %s" % key}
	config.merge(input, true)
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


## Parses the arguments after --. CLI values override the [server] section in any order.
static func parse_cli(args: PackedStringArray) -> Dictionary:
	var overrides := {}
	var path := ""
	var index := 0
	while index < args.size():
		var flag := args[index]
		index += 1
		if flag == "--server":
			continue
		if flag not in ["--config", "--bind", "--port", "--max-players", "--save-dir", "--level"]:
			return {"reason": "Unknown server option: " + flag}
		if index == args.size() or args[index].begins_with("--"):
			return {"reason": "Missing value for " + flag}
		var value := args[index]
		index += 1
		if flag == "--config":
			path = value
		elif flag in ["--port", "--max-players"]:
			if not value.is_valid_int():
				return {"reason": "Expected integer for " + flag}
			overrides[flag.trim_prefix("--").replace("-", "_")] = value.to_int()
		else:
			overrides[flag.trim_prefix("--").replace("-", "_")] = value
	var config := {}
	if not path.is_empty():
		var file := ConfigFile.new()
		if file.load(path) != OK or not file.has_section("server"):
			return {"reason": "Cannot read [server] from " + path}
		for key: String in file.get_section_keys("server"):
			config[key] = file.get_value("server", key)
	config.merge(overrides, true)
	return server_config(config, false)

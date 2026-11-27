extends RefCounted
## Player-facing session lifecycle. The facade also exposes host/join for custom bootstraps.

## Translated progress or failure for the current menu.
signal status_changed(message: String)

const NetConfig := preload("net_config.gd")
const WorldFiles := preload("../SceneManagement/cogito_world_files.gd")

var save_dir := NetConfig.DEFAULT_SAVE_DIR
var preferences_path := "user://net/recent_servers.cfg"
var status := ""
var pending := false
var return_message := ""
var _net: Node
var _playing := false
var _launcher: WeakRef


func _init(facade: Node) -> void:
	_net = facade
	_net.session_failed.connect(_failed)
	_net.session_ready.connect(_admitted)
	_net.local_player_changed.connect(_local_player)


## IPv4/IPv6 or normalized DNS host, without an embedded port or URL.
static func address_key(address: String) -> String:
	var value := address.strip_edges().to_lower()
	if value.is_valid_ip_address():
		return value
	if value.is_empty() or value.length() > 253 or value.replace(".", "").is_valid_int():
		return ""
	for part in value.split("."):
		if part.is_empty() or part.length() > 63 or part.begins_with("-") or part.ends_with("-"):
			return ""
		for letter in part:
			if not letter in "abcdefghijklmnopqrstuvwxyz0123456789-":
				return ""
	return value


func _preferences() -> ConfigFile:
	var file := ConfigFile.new()
	if FileAccess.file_exists(preferences_path):
		file.load(preferences_path)
	return file


func _write_preferences(file: ConfigFile) -> Error:
	var suffix := Crypto.new().generate_random_bytes(8).hex_encode()
	var pending_path := preferences_path + "." + suffix + ".tmp"
	var err := DirAccess.make_dir_recursive_absolute(preferences_path.get_base_dir())
	if err == OK:
		err = file.save(pending_path)
	if err == OK:
		err = DirAccess.rename_absolute(pending_path, preferences_path)
	if err != OK and FileAccess.file_exists(pending_path):
		DirAccess.remove_absolute(pending_path)
	return err


## Last player label and at most ten public endpoints. Credentials live in Identity.
func player_name() -> String:
	return _preferences().get_value("player", "name", "Player")


## Most recent public endpoints first.
func recent_servers() -> Array:
	return _preferences().get_value("recent", "servers", [])


func _remember(label: String, address: String, port: int) -> Error:
	var file := _preferences()
	var recent: Array = file.get_value("recent", "servers", [])
	var row := {"address": address, "port": port}
	recent.erase(row)
	recent.push_front(row)
	file.set_value("recent", "servers", recent.slice(0, 10))
	file.set_value("player", "name", label)
	return _write_preferences(file)


## Remove a public endpoint without changing its stored identity.
func forget_server(address: String, port: int) -> Error:
	var file := _preferences()
	var recent: Array = file.get_value("recent", "servers", [])
	recent.erase({"address": address_key(address), "port": port})
	file.set_value("recent", "servers", recent)
	return _write_preferences(file)


## Snapshot of committed directory listings without taking a writer lock or running recovery.
func worlds() -> Array[Dictionary]:
	return WorldFiles.list_worlds(save_dir)


## Existing manual slots from the offline save history.
func solo_slots() -> Array:
	return CogitoSceneManager.saved_slots()


func _begin() -> void:
	_reset()
	return_message = ""
	pending = true
	var scene: Node = _net.get_tree().current_scene
	_launcher = weakref(scene) if scene and scene.multiplayer == _net.multiplayer else null


## Validate, remember this endpoint and start a cancellable direct join.
func join(address: String, port: int, label: String) -> Error:
	if _net.is_online():
		return ERR_ALREADY_IN_USE
	address = address_key(address)
	label = label.strip_edges()
	if not NetConfig.valid_display_name(label):
		return _invalid("Name rejected")
	if address.is_empty() or port < 1 or port > 65535:
		return _invalid("Invalid server address or port")
	if _remember(label, address, port) != OK:
		return _invalid("Cannot save multiplayer preferences")
	_begin()
	_status("Connecting…")
	var err: Error = _net.join(address, port, {"display_name": label})
	if err == OK:
		_net.multiplayer.connected_to_server.connect(_authenticating, CONNECT_ONE_SHOT)
	return err


func _authenticating() -> void:
	if pending:
		_status("Authenticating…")


## Start listening and load the committed or configured initial level. The optional intent
## ("new" or "continue") is checked under the world lock. import_slot uses the MP9 copy.
func host(config: Dictionary, intent := "") -> Error:
	if _net.is_online():
		return ERR_ALREADY_IN_USE
	var settings := config.duplicate()
	settings.merge({"bind": "0.0.0.0", "save_dir": save_dir, "display_name": player_name()})
	if not WorldFiles.valid_name(settings.get("world", "default")):
		return _invalid("Invalid world directory name")
	_begin()
	var err: Error = _net.host(settings, intent)
	if err == OK:
		var path: String = _net.starting_level(settings.get("level", NetConfig.DEMO_LEVEL))
		err = _net.player_world.travel.start(path)
		if err != OK:
			_net.disconnect_session()
			_failed("Cannot load starting level " + path)
	return err


func _invalid(reason: String) -> Error:
	_status(readable(reason))
	return ERR_INVALID_PARAMETER


func _admitted() -> void:
	if pending:
		_status("Loading…")


func _local_player(actor: CogitoPlayer) -> void:
	if pending and actor:
		pending = false
		_playing = true
		_status("Ready")
		_retire_launcher.call_deferred(_launcher)


func _retire_launcher(launcher: WeakRef) -> void:
	if _playing and _net.is_online() and launcher == _launcher and launcher:
		var scene: Node = launcher.get_ref()
		if scene and scene == _net.get_tree().current_scene:
			_net.get_tree().unload_current_scene()


func _failed(reason: String) -> void:
	if pending or _playing:
		var was_playing := _playing
		_reset()
		_status(readable(reason))
		if was_playing or reason == "Kicked by host":
			return_message = status
			_return_to_menu()


func _reset() -> void:
	pending = false
	_playing = false
	_launcher = null
	if _net.multiplayer.connected_to_server.is_connected(_authenticating):
		_net.multiplayer.connected_to_server.disconnect(_authenticating)


## Abort pending connection/admission/loading. The current menu can immediately retry.
func cancel() -> void:
	if pending:
		_reset()
		_net.disconnect_session()
		_status("")


## Flush the authority, discard session-owned levels and return to the configured menu.
func leave() -> void:
	_reset()
	var err: Error = _net.disconnect_session()
	return_message = "" if err == OK else tr("World save failed") + " (" + error_string(err) + ")"
	_return_to_menu()


func _return_to_menu() -> void:
	var tree: SceneTree = _net.get_tree()
	tree.paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	CogitoSceneManager._reset_playthrough_state()
	tree.change_scene_to_packed(CogitoGlobals.cogito_settings.main_menu_scene)


func _status(message: String) -> void:
	status = tr(message) if not message.is_empty() else ""
	status_changed.emit(status)


## Translate protocol reasons at the client, keeping backend-specific details on failures.
func readable(reason: String) -> String:
	var messages := {
		"Connection failed":
		"Connection failed or timed out. Check the address, port and firewall.",
		"Handshake timed out":
		"Connection failed or timed out. Check the address, port and firewall.",
		"Protocol version mismatch": "Version mismatch. Use the same game build as the server.",
		"Content version mismatch": "Version mismatch. Use the same game build as the server.",
		"Name rejected": "Enter a player name of 1–64 printable characters.",
		"Server full": "Server full. Try again after a player leaves.",
		"Cannot import solo save": "Cannot import this save. Choose another solo slot.",
	}
	if reason.begins_with("Cannot connect to "):
		return tr("Connection failed or timed out. Check the address, port and firewall.")
	var level_errors := [
		"Cannot load starting level ",
		"Cannot restore starting level ",
		"Cannot rebuild saved level ",
	]
	for prefix: String in level_errors:
		if reason.begins_with(prefix):
			return (
				tr("Cannot load world level %s. Check the world files.")
				% reason.trim_prefix(prefix)
			)
	if reason.begins_with("Cannot bind "):
		return tr("Cannot listen on this port. Choose another port.")
	if reason.begins_with("max_players must"):
		return tr("Invalid player capacity")
	if reason.begins_with("Cannot open world "):
		return tr("World could not be opened. Check the save directory.")
	return tr(messages.get(reason, reason))

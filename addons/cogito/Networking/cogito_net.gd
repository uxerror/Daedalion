extends Node
## Public session facade. The offline singleton has no children, transport or frame callbacks.

## The local session can now read its initial roster.
signal session_ready
## Setup, admission or the established connection failed.
signal session_failed(reason: String)
## A record became visible in the local roster.
signal player_joined(player_id: String)
## A record left the local roster.
signal player_left(player_id: String)
## Emitted after local avatar creation and with null on removal.
signal local_player_changed(actor: CogitoPlayer)
## The authority refused this connection.
signal peer_rejected(peer_id: int, reason: String)

enum Mode { OFFLINE, LISTEN_HOST, CLIENT, DEDICATED }

const NetConfig := preload("net_config.gd")
const Identity := preload("net_identity.gd")
const Transport := preload("enet_transport.gd")
const Session := preload("net_session.gd")
const NET_PLAYERS := preload("net_players.gd")
const DEDICATED_SCENE := "res://addons/cogito/Networking/dedicated_server.tscn"

## Optional replacement for the built-in client and server identity provider.
var identity_provider: Identity
## Optional zero-argument factory returning a Transport subclass.
var transport_factory: Callable
## True before other Cogito autoloads initialize during a dedicated boot.
var dedicated_boot := false

## Server game hook (level_root, player_id, authored_transform) -> level-local Transform3D.
var spawn_policy: Callable:
	set(value):
		spawn_policy = value
		if player_world:
			player_world.spawn_policy = value
## Set before opening a session. Defaults to the level-scoped CogitoRespawnPolicy.
var respawn_policy: CogitoRespawnPolicy
## Default target selection resource for server NPCs without a per-NPC override.
var npc_target_policy: CogitoNpcTargetPolicy
## Optional owner-only Control implementing open_online(actor, seconds, request) and close_online().
var death_screen_scene: PackedScene
## Optional server damage filter (attacker_id, victim_id, source) -> bool.
var damage_policy: Callable
## Number of authoritative pose updates per second, capped at the physics tick rate.
var snapshot_hz := 25:
	set(value):
		snapshot_hz = maxi(1, value)
		if player_world:
			player_world.snapshot_hz = snapshot_hz
## Online-only level, spawn and pose endpoint.
var player_world: NET_PLAYERS

var _mode := Mode.OFFLINE
var _session: Session
var _previous_peer: MultiplayerPeer
var _previous_relay: bool


func _enter_tree() -> void:
	dedicated_boot = (
		OS.has_feature("dedicated_server")
		or "--server" in OS.get_cmdline_user_args()
		or DEDICATED_SCENE in OS.get_cmdline_args()
		or ProjectSettings.get_setting("application/run/main_scene") == DEDICATED_SCENE
	)
	if dedicated_boot:
		_select_dedicated_scene.call_deferred()


func _select_dedicated_scene() -> void:
	var scene := get_tree().current_scene
	if scene == null or scene.scene_file_path != DEDICATED_SCENE:
		var err := get_tree().change_scene_to_file(DEDICATED_SCENE)
		if err != OK:
			_report("Cannot load dedicated scene", err)
			get_tree().quit(1)


## Opens a server and admits its local host. The host counts toward max_players.
func host(config: Dictionary) -> Error:
	return _serve(config, Mode.LISTEN_HOST)


## Opens a server with an initially empty roster.
func start_server(config: Dictionary) -> Error:
	return _serve(config, Mode.DEDICATED)


func _serve(input: Dictionary, role: Mode) -> Error:
	if is_online():
		return _report("Session already open", ERR_ALREADY_IN_USE)
	var listen := role == Mode.LISTEN_HOST
	var config := NetConfig.server_config(input, listen)
	if config.has("reason"):
		return _report(config.reason, ERR_INVALID_PARAMETER)
	var provider := _provider()
	var err := provider.open_server(config.save_dir)
	if err != OK:
		return _report("Cannot open server identity store", err)
	var scope := ("host/" + ProjectSettings.globalize_path(config.save_dir)).sha256_text()
	var profile := provider.load_client(scope, {}) if listen else {}
	if listen and profile.is_empty():
		return _report("Cannot read host identity", ERR_FILE_CANT_READ)
	var adapter := _transport()
	err = adapter.open_server(config, listen)
	if err != OK:
		return _report("Cannot bind %s:%d" % [config.bind, config.port], err)
	_attach(role, adapter.peer, provider, config, scope, profile)
	if listen:
		err = _session.admit_host()
	if err == OK:
		var message := "Listening on %s:%d" % [config.bind, config.port]
		CogitoGlobals.debug_log(true, "CogitoNet", message)
		session_ready.emit()
	else:
		disconnect_session()
		_report("Cannot admit local host", err)
	return err


## Opens a client connection. Wait for session_ready before using the roster.
func join(address: String, port: int, credentials: Dictionary = {}) -> Error:
	if is_online():
		return _report("Session already open", ERR_ALREADY_IN_USE)
	address = address.strip_edges().to_lower()
	var config := {
		"content_version": credentials.get("content_version", NetConfig.content_version()),
		"display_name": credentials.get("display_name", "Player"),
	}
	if address.is_empty() or port < 1 or port > 65535:
		return _report("Invalid server address or port", ERR_INVALID_PARAMETER)
	if not (config.content_version is String and config.display_name is String):
		return _report("Invalid client settings", ERR_INVALID_PARAMETER)
	var provider := _provider()
	var scope := ("%s/%d" % [address, port]).sha256_text()
	var profile := provider.load_client(scope, credentials)
	if profile.is_empty():
		return _report("Cannot read client identity", ERR_FILE_CANT_READ)
	var adapter := _transport()
	var err := adapter.open_client(address, port)
	if err != OK:
		return _report("Cannot connect to %s:%d" % [address, port], err)
	_attach(Mode.CLIENT, adapter.peer, provider, config, scope, profile)
	return OK


func _provider() -> Identity:
	return identity_provider if identity_provider != null else Identity.new()


func _transport() -> Transport:
	return transport_factory.call() if transport_factory.is_valid() else Transport.new()


func _attach(
	role: Mode,
	peer: MultiplayerPeer,
	provider: Identity,
	config: Dictionary,
	scope: String,
	profile: Dictionary
) -> void:
	var api := multiplayer as SceneMultiplayer
	_previous_peer = api.multiplayer_peer
	_previous_relay = api.server_relay
	_mode = role
	_session = Session.new()
	_session.name = "Session"
	_session.process_mode = Node.PROCESS_MODE_ALWAYS
	_session.identity = provider
	_session.scope = scope
	_session.config = config
	_session.profile = profile
	add_child(_session)
	_session.ready_for_play.connect(session_ready.emit)
	_session.failed.connect(_session_failure)
	_session.joined.connect(player_joined.emit)
	_session.left.connect(player_left.emit)
	_session.rejected.connect(_peer_rejected)
	player_world = NET_PLAYERS.new()
	player_world.name = "Players"
	player_world.spawn_policy = spawn_policy
	player_world.snapshot_hz = snapshot_hz
	if npc_target_policy:
		player_world.npc_target_policy = npc_target_policy
	if respawn_policy:
		player_world.death.policy = respawn_policy
	player_world.death.screen_scene = death_screen_scene
	player_world.death.damage_policy = damage_policy
	player_world.local_changed.connect(local_player_changed.emit)
	_session.add_child(player_world)
	_session.attach(api)
	api.server_relay = false
	api.multiplayer_peer = peer
	var scene := get_tree().current_scene
	if scene and scene.multiplayer == api and scene.has_method("bind_network_players"):
		scene.call_deferred("bind_network_players")


func _peer_rejected(peer_id: int, reason: String) -> void:
	push_warning("CogitoNet rejected peer %d: %s" % [peer_id, reason])
	peer_rejected.emit(peer_id, reason)


func _session_failure(reason: String) -> void:
	disconnect_session()
	_report(reason, ERR_CONNECTION_ERROR)


func _report(reason: String, err: Error) -> Error:
	push_warning("CogitoNet: %s (%s)" % [reason, error_string(err)])
	CogitoGlobals.debug_log(true, "CogitoNet", reason)
	session_failed.emit(reason)
	return err


# Closing the window must tell the server at once; otherwise the identity stays
# connected until the ENet timeout and an immediate rejoin is rejected.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		disconnect_session()


## Closes the session, drops all records and restores the branch's original offline peer.
func disconnect_session() -> void:
	if _session == null:
		return
	var api := multiplayer as SceneMultiplayer
	var peer := api.multiplayer_peer
	var old_records := _session.records()
	player_world.clear()
	player_world = null
	_session.detach()
	if _mode == Mode.CLIENT and peer != null and 1 in api.get_peers():
		peer.disconnect_peer(1, true)
	api.multiplayer_peer = null
	if peer != null:
		peer.close()
	api.server_relay = _previous_relay
	api.multiplayer_peer = _previous_peer
	remove_child(_session)
	_session.queue_free()
	_session = null
	_previous_peer = null
	_mode = Mode.OFFLINE
	for record: Dictionary in old_records:
		player_left.emit(record.player_id)


## Returns the selected role, including CLIENT while admission is pending.
func mode() -> Mode:
	return _mode


## Offline play and both server roles own the simulation.
func is_server() -> bool:
	return _mode != Mode.CLIENT


## True from successful transport setup until disconnect.
func is_online() -> bool:
	return _mode != Mode.OFFLINE


## True for a running server without a local player.
func is_dedicated() -> bool:
	return _mode == Mode.DEDICATED


## Returns a copy of the complete admitted roster.
func players() -> Array[Dictionary]:
	var empty: Array[Dictionary] = []
	return _session.records() if _session else empty


## Returns an admitted record or an empty dictionary.
func player_for_peer(peer_id: int) -> Dictionary:
	return _session.for_peer(peer_id) if _session else {}


## Returns an admitted record or an empty dictionary.
func player_for_id(player_id: String) -> Dictionary:
	return _session.for_id(player_id) if _session else {}


## Returns the durable local identity once admitted, or the empty string.
func local_player_id() -> String:
	return _session.local_id if _session else ""


## The admitted local network avatar, or null before spawn, offline and on dedicated.
func local_player() -> CogitoPlayer:
	return player_world.local_actor if player_world else null

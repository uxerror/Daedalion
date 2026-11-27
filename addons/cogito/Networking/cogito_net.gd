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

## Live local travel hint. A listener can change event.text or clear it to suppress the HUD.
signal travel_notification(event: Dictionary)
## The authority or the travelling client could not complete a transfer.
signal travel_failed(player_id: String, reason: String)

enum Mode { OFFLINE, LISTEN_HOST, CLIENT, DEDICATED }

const Persistence := preload("net_persistence.gd")
const ReconnectPolicy := preload("net_reconnect_policy.gd")
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
## Authority rules for validating a party and transferring held or seated state.
var travel_policy: CogitoTravelPolicy
## Optional placement policy for the first admission of a saved life.
var reconnect_policy: ReconnectPolicy
## Optional legacy solo importer (saved_row, matching_authored_nodes) -> selected node or null.
var match_legacy_object: Callable
## Optional server callbacks () -> Dictionary and (Dictionary) -> void.
var capture_shared_state: Callable
var apply_shared_state: Callable
## Optional (target_profile) -> bool for operator rebind protection.
var profile_has_progress: Callable
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
	if not config.profile_command.is_empty():
		return _report("Profile commands require the dedicated CLI", ERR_INVALID_PARAMETER)
	var provider := _provider()
	var err := provider.open_server(config.save_dir)
	if err != OK:
		return _report("Cannot open server identity store", err)
	var scope := ("host/" + ProjectSettings.globalize_path(config.save_dir)).sha256_text()
	var profile := provider.load_client(scope, {}) if listen else {}
	if listen and profile.is_empty():
		return _report("Cannot read host identity", ERR_FILE_CANT_READ)
	return _serve_world(config, role, provider, scope, profile)


func _serve_world(
	config: Dictionary, role: Mode, provider: Identity, scope: String, profile: Dictionary
) -> Error:
	var listen := role == Mode.LISTEN_HOST
	var persistence := Persistence.new()
	var err := persistence.files.open(config.save_dir, config.world)
	if err != OK:
		return _report("Cannot open world " + config.world, err)
	if reconnect_policy:
		persistence.placement = reconnect_policy
	persistence.match_legacy_object = match_legacy_object
	persistence.capture_shared = capture_shared_state
	persistence.operator.has_progress = profile_has_progress
	persistence.apply_shared = apply_shared_state
	var adapter := _transport()
	err = adapter.open_server(config, listen)
	if err != OK:
		persistence.close()
		return _report("Cannot bind %s:%d" % [config.bind, config.port], err)
	_attach(role, adapter.peer, provider, config, scope, profile)
	player_world.persistence = persistence
	persistence.stop_requested.connect(_stop_requested.bind(_session), CONNECT_DEFERRED)
	persistence.install(player_world)
	if not persistence.files.manifest.is_empty():
		adapter.peer.refuse_new_connections = true
	if listen:
		err = _session.admit_host()
	if err == OK and not config.import_slot.is_empty():
		var owner_id: String = _session.local_id if listen else config.import_player
		err = import_solo(config.import_slot, owner_id)
	if err == OK:
		var message := "Listening on %s:%d" % [config.bind, config.port]
		CogitoGlobals.debug_log(true, "CogitoNet", message)
		session_ready.emit()
	else:
		disconnect_session()
		_report("Cannot initialize host or import slot", err)
	return err


func _failed_world(key: String, err: Error) -> void:
	disconnect_session()
	_report("Cannot rebuild saved level " + key, err)


## Publish the whole world from either server topology.
func save_world() -> Error:
	return player_world.save_world() if player_world else ERR_UNCONFIGURED


## Scene for CLI bootstrap. A committed world selects its last active scene.
func starting_level(fallback: String) -> String:
	if player_world and player_world.persistence:
		var files := player_world.persistence.files
		if not files.manifest.is_empty():
			return files.scenes[files.manifest.active].path
	return fallback


## Explicit copy into an empty, bound-to-no-level world. Never recovers or writes the input slot.
func import_solo(slot: String, player_id: String) -> Error:
	if not player_world or not player_world.persistence or player_world.active_level():
		return ERR_UNCONFIGURED
	var persistence := player_world.persistence
	if persistence.busy:
		return ERR_BUSY
	if persistence.can_flush() or persistence.restore_error != OK:
		return ERR_UNCONFIGURED
	persistence.busy = true
	var err := preload("net_solo_import.gd").copy(slot, player_id, persistence.files)
	if err == OK:
		persistence.install(player_world)
		multiplayer.multiplayer_peer.refuse_new_connections = true
	persistence.busy = false
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
	if role != Mode.CLIENT:
		var defaults := CogitoGlobals.cogito_settings.get_new_game_world_dict()
		player_world.quests.world.flags = defaults.duplicate(true)
		_session.joined.connect(_quest_baseline)
	_session.joined.connect(player_joined.emit)
	_session.add_child(player_world)
	player_world.travel.notice_received.connect(travel_notification.emit)
	player_world.travel.failed.connect(travel_failed.emit)
	_session.left.connect(player_left.emit)
	_session.attach(api)
	api.server_relay = false
	api.multiplayer_peer = peer
	var scene := get_tree().current_scene
	if scene and scene.multiplayer == api and scene.has_method("bind_network_players"):
		scene.call_deferred("bind_network_players")


func _quest_baseline(id: String) -> void:
	player_world.quests.baseline(_session.for_id(id).peer_id)


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


func _stop_requested(expected: Session) -> void:
	if _session != expected:
		return
	var err := disconnect_session()
	print("NET STOP ", error_string(err))
	get_tree().quit(0 if err == OK else 1)


func _close_if_current(expected: Session) -> void:
	if _session == expected:
		disconnect_session()


## Flush the last active tick before releasing actors and the writer claim. One final
## attempt bypasses backoff, including for motion or custom state without a dirty event.
func disconnect_session() -> Error:
	if _session == null:
		return OK
	var persistence := player_world.persistence
	if persistence and persistence.in_capture():
		# A game callback inside capture must unwind before its nodes or lock are released.
		_close_if_current.call_deferred(_session)
		return ERR_BUSY
	var err := OK
	if persistence and persistence.can_flush():
		err = persistence.flush(player_world, Engine.get_physics_frames())
		if err != OK:
			printerr("NET FINAL SAVE ", error_string(err))
	player_world.travel.shutdown()
	player_world.persistence = null
	var api := multiplayer as SceneMultiplayer
	var peer := api.multiplayer_peer
	var old_records := _session.records()
	player_world.clear()
	if persistence:
		persistence.close()
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
	return err


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
	return player_world.travel.local_actor() if player_world else null

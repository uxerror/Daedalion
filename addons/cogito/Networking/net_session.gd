extends Node
## Online-only endpoint. All control messages use reliable channel zero on both branches.

signal ready_for_play
signal failed(reason: String)
signal joined(player_id: String)
signal left(player_id: String)
signal rejected(peer_id: int, reason: String)

const NetConfig := preload("net_config.gd")
const Identity := preload("net_identity.gd")
const HANDSHAKE_MS := 10000

var identity: Identity
var config: Dictionary
var scope: String
var profile: Dictionary
var local_id := ""
var _api: SceneMultiplayer
var _by_peer := {}
var _by_id := {}
var _pending := {}
var _watchdog: Timer
var _client_deadline := 0


## Connects to the branch's API before its transport starts emitting events.
func attach(api: SceneMultiplayer) -> void:
	_api = api
	_api.peer_connected.connect(_peer_connected)
	_api.peer_disconnected.connect(_peer_disconnected)
	_api.connected_to_server.connect(_connected)
	_api.connection_failed.connect(_connection_failed)
	_api.server_disconnected.connect(_server_disconnected)
	_watchdog = Timer.new()
	_watchdog.wait_time = 0.25
	add_child(_watchdog)
	_watchdog.timeout.connect(_check_deadlines)
	if not profile.is_empty():
		_client_deadline = Time.get_ticks_msec() + HANDSHAKE_MS
		_watchdog.start()


## Detaches callbacks before replacing the peer, including on a failed handshake.
func detach() -> void:
	_api.peer_connected.disconnect(_peer_connected)
	_api.peer_disconnected.disconnect(_peer_disconnected)
	_api.connected_to_server.disconnect(_connected)
	_api.connection_failed.disconnect(_connection_failed)
	_api.server_disconnected.disconnect(_server_disconnected)
	_watchdog.stop()


## Applies the same provider and roster rules to the listen host's local connection.
func admit_host() -> Error:
	var nonce := Crypto.new().generate_random_bytes(32)
	var claim: String = profile.player_id
	var reply := identity.respond(profile, nonce, not identity.is_known(claim))
	local_id = identity.authenticate(claim, nonce, reply)
	if local_id.is_empty() or identity.save_client(scope, profile, local_id) != OK:
		return ERR_CANT_CREATE
	_client_deadline = 0
	_watchdog.stop()
	_add_player(local_id, 1, config.display_name)
	return OK


## Returns detached records so callers cannot mutate admission state.
func records() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in _by_peer.values():
		result.append(record.duplicate())
	return result


## Looks up the identity bound to this live connection.
func for_peer(peer_id: int) -> Dictionary:
	return _by_peer.get(peer_id, {}).duplicate()


## Looks up the current connection for a durable identity.
func for_id(player_id: String) -> Dictionary:
	return _by_id.get(player_id, {}).duplicate()


func _peer_connected(peer_id: int) -> void:
	if _api.is_server():
		_pending[peer_id] = {"deadline": Time.get_ticks_msec() + HANDSHAKE_MS}
		_watchdog.start()


func _connected() -> void:
	_hello.rpc_id(1, NetConfig.PROTOCOL_VERSION, config.content_version, profile.player_id)


@rpc("any_peer", "call_remote", "reliable", 0)
func _hello(protocol: int, content: String, claim: String) -> void:
	var sender := _api.get_remote_sender_id()
	if not _api.is_server() or not _pending.has(sender):
		return
	var pending: Dictionary = _pending[sender]
	if pending.has("nonce") or pending.has("rejected"):
		return
	var reason := NetConfig.version_error(protocol, content, config.content_version)
	if not reason.is_empty():
		_reject(sender, reason)
	elif claim.length() > 256:
		_reject(sender, "Invalid identity")
	else:
		pending.claim = claim
		pending.nonce = Crypto.new().generate_random_bytes(32)
		_challenge.rpc_id(sender, pending.nonce, not identity.is_known(claim))


@rpc("authority", "call_remote", "reliable", 0)
func _challenge(nonce: PackedByteArray, enrolling: bool) -> void:
	if local_id.is_empty() and nonce.size() == 32:
		_answer.rpc_id(1, identity.respond(profile, nonce, enrolling), config.display_name)


@rpc("any_peer", "call_remote", "reliable", 0)
func _answer(reply: Dictionary, display_name: String) -> void:
	var sender := _api.get_remote_sender_id()
	var pending: Dictionary = _pending.get(sender, {})
	if not _api.is_server() or not pending.has("nonce") or pending.has("rejected"):
		return
	if _by_id.has(pending.claim):
		_reject(sender, "Identity already connected")
		return
	if _by_peer.size() >= config.max_players:
		_reject(sender, "Server full")
		return
	var id := identity.authenticate(pending.claim, pending.nonce, reply)
	if id.is_empty() or _by_id.has(id):
		_reject(sender, "Identity verification failed")
		return
	_pending.erase(sender)
	var record := {"player_id": id, "peer_id": sender, "display_name": display_name.left(64)}
	for peer_id: int in _by_peer:
		if peer_id != 1:
			_player_added.rpc_id(peer_id, record)
	var snapshot := records()
	snapshot.append(record)
	_welcome.rpc_id(sender, id, snapshot)
	_add_player(id, sender, record.display_name)


@rpc("authority", "call_remote", "reliable", 0)
func _welcome(id: String, snapshot: Array[Dictionary]) -> void:
	if not local_id.is_empty():
		return
	if identity.save_client(scope, profile, id) != OK:
		failed.emit("Cannot save client identity")
		return
	local_id = id
	_watchdog.stop()
	for record: Dictionary in snapshot:
		_add_player(record.player_id, record.peer_id, record.display_name)
	ready_for_play.emit()


@rpc("authority", "call_remote", "reliable", 0)
func _player_added(record: Dictionary) -> void:
	_add_player(record.player_id, record.peer_id, record.display_name)


func _add_player(id: String, peer_id: int, display_name: String) -> void:
	var record := {"player_id": id, "peer_id": peer_id, "display_name": display_name.left(64)}
	_by_peer[peer_id] = record
	_by_id[id] = record
	joined.emit(id)


func _peer_disconnected(peer_id: int) -> void:
	_pending.erase(peer_id)
	if not _api.is_server() or not _by_peer.has(peer_id):
		return
	var id: String = _by_peer[peer_id].player_id
	for other: int in _by_peer:
		if other != 1 and other != peer_id:
			_player_removed.rpc_id(other, id)
	_player_removed(id)


@rpc("authority", "call_remote", "reliable", 0)
func _player_removed(id: String) -> void:
	if _by_id.has(id):
		_by_peer.erase(_by_id[id].peer_id)
		_by_id.erase(id)
		left.emit(id)


func _reject(peer_id: int, reason: String) -> void:
	_pending[peer_id] = {"rejected": true, "deadline": Time.get_ticks_msec() + 2000}
	_denied.rpc_id(peer_id, reason)
	rejected.emit(peer_id, reason)


@rpc("authority", "call_remote", "reliable", 0)
func _denied(reason: String) -> void:
	failed.emit(reason)


func _check_deadlines() -> void:
	var now := Time.get_ticks_msec()
	if not _api.is_server():
		if now >= _client_deadline:
			failed.emit("Handshake timed out")
		return
	for peer_id: int in _pending.keys():
		var pending: Dictionary = _pending[peer_id]
		if now < pending.deadline:
			continue
		if pending.has("rejected"):
			_pending.erase(peer_id)
			_api.disconnect_peer(peer_id)
		else:
			_reject(peer_id, "Handshake timed out")
	if _pending.is_empty():
		_watchdog.stop()


func _connection_failed() -> void:
	failed.emit("Connection failed")


func _server_disconnected() -> void:
	failed.emit("Server disconnected")

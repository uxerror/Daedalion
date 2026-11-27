extends Node
## Public pause roster. A client subscribes only while it has a visible roster.

## Latest snapshot delivered to a subscribed local menu.
signal updated(rows: Array[Dictionary])

var rows: Array[Dictionary] = []
var _watchers := {}
var _next_update := 0


func _ready() -> void:
	set_process(false)
	get_parent().left.connect(_departed)


## Enable or disable public roster delivery for this screen.
func watch(open: bool) -> void:
	if multiplayer.is_server():
		_set_watch(1, open)
	elif 1 in multiplayer.get_peers():
		_subscribe.rpc_id(1, open)


@rpc("any_peer", "call_remote", "reliable", 0)
func _subscribe(open: bool) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if multiplayer.is_server() and not get_parent().for_peer(sender).is_empty():
		_set_watch(sender, open)


func _set_watch(peer: int, open: bool) -> void:
	if open:
		_watchers[peer] = true
	else:
		_watchers.erase(peer)
	set_process(not _watchers.is_empty())


func _departed(_id: String) -> void:
	for peer: int in _watchers.keys():
		if get_parent().for_peer(peer).is_empty():
			_set_watch(peer, false)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if now < _next_update:
		return
	_next_update = now + 1000
	var snapshot := connected()
	for peer: int in _watchers.keys():
		if peer == 1:
			_receive(snapshot)
		elif peer in multiplayer.get_peers():
			_receive.rpc_id(peer, snapshot)


## Current public identity, room title and server-measured RTT. -1 means unavailable.
func connected() -> Array[Dictionary]:
	var snapshot: Array[Dictionary] = get_parent().records()
	var travel: Node = get_parent().get_node("Players").travel
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	for row in snapshot:
		var room: Node = travel.endpoint_for(row.player_id)
		row.level = travel.level_title(room) if room else ""
		row.ping = 0 if row.peer_id == 1 else -1
		if enet and row.peer_id != 1 and row.peer_id in multiplayer.get_peers():
			var remote := enet.get_peer(row.peer_id)
			if remote:
				row.ping = roundi(remote.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
	return snapshot


@rpc("authority", "call_remote", "reliable", 0)
func _receive(snapshot: Array[Dictionary]) -> void:
	rows = snapshot
	updated.emit(rows.duplicate(true))


## Authority-only. An ID wins over a name. Ambiguous names require an explicit ID.
func kick(target: String) -> Error:
	if not multiplayer.is_server():
		return ERR_UNAUTHORIZED
	var member: Dictionary = get_parent().for_id(target)
	if member.is_empty():
		for row: Dictionary in get_parent().records():
			if row.display_name == target:
				if not member.is_empty():
					return ERR_DUPLICATE_SYMBOL
				member = row
	if member.is_empty():
		return ERR_DOES_NOT_EXIST
	if member.peer_id == 1:
		return ERR_UNAUTHORIZED
	get_parent().expire_peer(member.peer_id, "Kicked by host")
	return OK

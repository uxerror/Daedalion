extends MultiplayerPeerExtension
## A lossless reliable queue for exercising real SceneMultiplayer RPCs without OS sockets.

var network: Dictionary
var id: int
var arrivals: Array[int] = []
var departures: Array[int] = []
var packets: Array[Dictionary] = []
var drop_every_tenth_command := false
var _command_count := 0
var _target: int
var _channel: int
var _transfer := TRANSFER_MODE_RELIABLE
var _status := CONNECTION_CONNECTED


func _get_connection_status() -> ConnectionStatus:
	return _status


func _get_unique_id() -> int:
	return id


func _is_server() -> bool:
	return id == 1


func _poll() -> void:
	for other: int in arrivals:
		peer_connected.emit(other)
	arrivals.clear()
	for other: int in departures:
		if other == 1:
			_status = CONNECTION_DISCONNECTED
		peer_disconnected.emit(other)
	departures.clear()


func _set_target_peer(peer_id: int) -> void:
	_target = peer_id


func _put_packet_script(buffer: PackedByteArray) -> Error:
	if drop_every_tenth_command and _channel == 1 and _transfer == TRANSFER_MODE_UNRELIABLE_ORDERED:
		_command_count += 1
		if _command_count % 10 == 0:
			return OK
	for other: int in network:
		if other != id and (_target == other or (_target <= 0 and other != -_target)):
			network[other].packets.append({"source": id, "data": buffer.duplicate()})
	return OK


func _get_packet_script() -> PackedByteArray:
	return packets.pop_front().data


func _get_available_packet_count() -> int:
	return packets.size()


func _get_packet_peer() -> int:
	return packets[0].source


func _get_max_packet_size() -> int:
	return 65535


func _get_packet_channel() -> int:
	return 0


func _get_packet_mode() -> TransferMode:
	return TRANSFER_MODE_RELIABLE


func _set_transfer_channel(channel: int) -> void:
	_channel = channel


func _get_transfer_channel() -> int:
	return _channel


func _set_transfer_mode(value: TransferMode) -> void:
	_transfer = value


func _get_transfer_mode() -> TransferMode:
	return _transfer


func _close() -> void:
	if _status == CONNECTION_DISCONNECTED:
		return
	_status = CONNECTION_DISCONNECTED
	network.erase(id)
	for other: int in network:
		if id == 1 or other == 1:
			var queue: Array[Dictionary] = network[other].packets
			for index in range(queue.size() - 1, -1, -1):
				if queue[index].source == id:
					queue.remove_at(index)
			network[other].departures.append(id)
	packets.clear()


func _disconnect_peer(other: int, _force: bool) -> void:
	if id != 1 and other == 1:
		_close()
	elif network.has(other):
		network[other]._close()

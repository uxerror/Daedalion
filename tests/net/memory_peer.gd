extends MultiplayerPeerExtension
## An in-process packet queue for exercising real SceneMultiplayer RPCs without OS sockets.

const Schedule := preload("packet_schedule.gd")

var network: Dictionary
var id: int
var arrivals: Array[int] = []
var departures: Array[int] = []
var packets: Array = []
var schedule: Schedule

var drop_every_tenth_command := false
var pose_packets := {}
## Opt-in capture of actual serialized outbound RPC packets for privacy assertions.
var capture := false
var sent: Array[PackedByteArray] = []
var destinations: Array[int] = []
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
	if schedule:
		schedule.poll(Engine.get_physics_frames(), packets)
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
	if capture:
		sent.append(buffer.duplicate())
		destinations.append(_target)
	if drop_every_tenth_command and _channel == 1 and _transfer == TRANSFER_MODE_UNRELIABLE_ORDERED:
		_command_count += 1
		if _command_count % 10 == 0:
			return OK
	if _channel == 1 and _transfer == TRANSFER_MODE_UNRELIABLE:
		pose_packets[_target] = pose_packets.get(_target, 0) + 1
	for other: int in network:
		if other != id and (_target == other or (_target <= 0 and other != -_target)):
			network[other]._receive([id, _channel, _transfer, buffer.duplicate()])
	return OK


func configure(source: int, channel: int, options: Dictionary) -> void:
	if not schedule:
		schedule = Schedule.new(id, 1000.0 / Engine.physics_ticks_per_second)
	schedule.configure(source, channel, options)


func _receive(packet: Array) -> void:
	if schedule:
		schedule.enqueue(packet, Engine.get_physics_frames(), packets)
	else:
		packets.append(packet)


func _get_packet_script() -> PackedByteArray:
	return packets.pop_front()[3]


func _get_available_packet_count() -> int:
	return packets.size()


func _get_packet_peer() -> int:
	return packets[0][0]


func _get_max_packet_size() -> int:
	return 65535


func _get_packet_channel() -> int:
	return packets[0][1]


func _get_packet_mode() -> TransferMode:
	return packets[0][2]


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
			if network[other].schedule:
				network[other].schedule.forget(id)
			var queue: Array = network[other].packets
			for index in range(queue.size() - 1, -1, -1):
				if queue[index][0] == id:
					queue.remove_at(index)
			network[other].departures.append(id)
	packets.clear()


func _disconnect_peer(other: int, _force: bool) -> void:
	if id != 1 and other == 1:
		_close()
	elif network.has(other):
		network[other]._close()

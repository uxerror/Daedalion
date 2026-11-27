extends "res://addons/cogito/Networking/enet_transport.gd"
## Socket-free process transport for the same SceneMultiplayer endpoints as the ENet harness.

const Schedule := preload("packet_schedule.gd")

static var _connections := 0


class FilePeer:
	extends MultiplayerPeerExtension

	var schedule: Schedule
	var directory: String
	var id: int
	var target := 0
	var channel := 0
	var mode := TRANSFER_MODE_RELIABLE
	var status := CONNECTION_CONNECTED
	var links := {}
	var outgoing := {}
	var incoming: Array = []
	var serial := 0
	var received_bytes := 0

	func _init(folder: String, number: int) -> void:
		directory = folder
		id = number
		var options := {}
		for key: String in ["delay_ms", "jitter_ms", "loss", "dup", "seed"]:
			var value := OS.get_environment("COGITO_FILE_" + key.to_upper())
			if not value.is_empty():
				options[key] = value.to_float()
		if not options.is_empty():
			schedule = Schedule.new(id, 0.001, options)
		FileAccess.open(_presence(id), FileAccess.WRITE).close()

	## The process fixture can select a particular inbound direction/channel after admission.
	func configure(source: int, transfer_channel_id: int, options: Dictionary) -> void:
		if not schedule:
			schedule = Schedule.new(id, 0.001)
		schedule.configure(source, transfer_channel_id, options)

	func _presence(number: int) -> String:
		return directory.path_join("%d.live" % number)

	func _get_connection_status() -> ConnectionStatus:
		return status

	func _get_unique_id() -> int:
		return id

	func _is_server() -> bool:
		return id == 1

	func _poll() -> void:
		if status != CONNECTION_CONNECTED:
			return
		_flush()
		var files := DirAccess.get_files_at(directory)
		for file in files:
			if file.ends_with(".live"):
				var other := file.to_int()
				if other != id and (id == 1 or other == 1) and not links.has(other):
					links[other] = true
					peer_connected.emit(other)
			elif file.begins_with("%d-" % id) and file.ends_with(".pkt"):
				var path := directory.path_join(file)
				var reader := FileAccess.open(path, FileAccess.READ)
				var batch: Array = reader.get_var(false)
				if schedule:
					var now := Time.get_ticks_usec()
					for packet: Array in batch:
						schedule.enqueue(packet, now, incoming)
				else:
					incoming.append_array(batch)
				reader.close()
				DirAccess.remove_absolute(path)
		if schedule:
			schedule.poll(Time.get_ticks_usec(), incoming)
		for number: int in links.keys():
			if not FileAccess.file_exists(_presence(number)):
				links.erase(number)
				if schedule:
					schedule.forget(number)
				if number == 1:
					status = CONNECTION_DISCONNECTED
				peer_disconnected.emit(number)

	func _flush() -> void:
		for other: int in outgoing:
			serial += 1
			var path := directory.path_join("%d-%d-%012d.pkt" % [other, id, serial])
			var writer := FileAccess.open(path + ".tmp", FileAccess.WRITE)
			writer.store_var(outgoing[other])
			writer.close()
			DirAccess.rename_absolute(path + ".tmp", path)
		outgoing.clear()

	func _set_target_peer(number: int) -> void:
		target = number

	func _put_packet_script(buffer: PackedByteArray) -> Error:
		for other: int in links:
			if other == target or (target <= 0 and other != -target):
				var batch: Array = outgoing.get_or_add(other, [])
				batch.append([id, channel, mode, buffer.duplicate()])
		return OK

	func _get_packet_script() -> PackedByteArray:
		var packet: PackedByteArray = incoming.pop_front()[3]
		received_bytes += packet.size()
		return packet

	func _get_available_packet_count() -> int:
		return incoming.size()

	func _get_packet_peer() -> int:
		return incoming[0][0]

	func _get_packet_channel() -> int:
		return incoming[0][1]

	func _get_packet_mode() -> TransferMode:
		return incoming[0][2]

	func _get_max_packet_size() -> int:
		return 65535

	func _set_transfer_channel(value: int) -> void:
		channel = value

	func _get_transfer_channel() -> int:
		return channel

	func _set_transfer_mode(value: TransferMode) -> void:
		mode = value

	func _get_transfer_mode() -> TransferMode:
		return mode

	func _close() -> void:
		_flush()
		DirAccess.remove_absolute(_presence(id))
		status = CONNECTION_DISCONNECTED

	func _disconnect_peer(number: int, _force: bool) -> void:
		_flush()
		if number == 1:
			_close()
		else:
			DirAccess.remove_absolute(_presence(number))


func open_server(_config: Dictionary, _listen: bool) -> Error:
	peer = FilePeer.new(OS.get_environment("COGITO_FILE_BUS"), 1)
	return OK


func open_client(_address: String, _port: int) -> Error:
	var id := OS.get_environment("COGITO_FILE_ID").to_int()
	peer = FilePeer.new(OS.get_environment("COGITO_FILE_BUS"), id + (_connections << 16))
	_connections += 1
	return OK

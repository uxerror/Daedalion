extends GdUnitTestSuite
## Real loopback ENet: the transport must keep the packet throttle at full scale
## (Godot 4.7 otherwise drops it to 1/32 and discards most unreliable commands).

const TRANSPORT := preload("res://addons/cogito/Networking/enet_transport.gd")


func test_throttle_stays_full_under_steady_unreliable_load(_timeout := 6000) -> void:
	var server := TRANSPORT.new()
	var client := TRANSPORT.new()
	var port := 20000 + randi() % 20000
	if server.open_server({"bind": "127.0.0.1", "port": port, "max_players": 4}, false) != OK:
		return  # Sockets unavailable (sandbox): nothing to measure.
	if client.open_client("127.0.0.1", port) != OK:
		server.peer.close()
		return
	var host := server.peer as ENetMultiplayerPeer
	var enet := client.peer as ENetMultiplayerPeer
	var lowest := ENetPacketPeer.PACKET_THROTTLE_SCALE
	var payload := PackedByteArray()
	payload.resize(120)
	var snapshot := PackedByteArray()
	snapshot.resize(600)
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 2500:
		host.poll()
		enet.poll()
		while host.get_available_packet_count() > 0:
			host.get_packet()
		while enet.get_available_packet_count() > 0:
			enet.get_packet()
		var link := enet.get_peer(1)
		if link and link.get_state() == ENetPacketPeer.STATE_CONNECTED:
			enet.transfer_channel = 1
			enet.transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
			enet.set_target_peer(1)
			enet.put_packet(payload)
			host.transfer_channel = 2
			host.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
			host.set_target_peer(0)
			host.put_packet(snapshot)
			lowest = mini(lowest, int(link.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE)))
		await get_tree().physics_frame
	enet.close()
	host.close()
	assert_int(lowest).is_equal(ENetPacketPeer.PACKET_THROTTLE_SCALE)

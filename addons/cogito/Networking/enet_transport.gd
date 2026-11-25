extends RefCounted
## Transport adapter. Alternate factories return an adapter with these two methods and peer.

const NetConfig := preload("net_config.gd")
const CHANNEL_COUNT := 4

## Open transport to install on the session's SceneMultiplayer.
var peer: MultiplayerPeer


## Opens a UDP listener. One spare handshake slot lets full games send a reason.
func open_server(config: Dictionary, listen: bool) -> Error:
	var enet := ENetMultiplayerPeer.new()
	enet.set_bind_ip(config.bind)
	var slots := mini(config.max_players - int(listen) + 1, NetConfig.ENET_CEILING)
	var err := enet.create_server(config.port, slots, CHANNEL_COUNT)
	_unlimit(enet, err)
	peer = enet
	return err


## Opens a UDP client for the matching control and gameplay channels.
func open_client(address: String, port: int) -> Error:
	var enet := ENetMultiplayerPeer.new()
	if address == "127.0.0.1":
		enet.set_bind_ip(address)
	var err := enet.create_client(address, port, CHANNEL_COUNT)
	_unlimit(enet, err)
	peer = enet
	return err


# Without an explicit unlimited bandwidth announcement, Godot 4.7's ENet host can
# drop a peer's packet throttle limit to 1/32 for whole bandwidth intervals, which
# silently discards most unreliable command/snapshot packets (see net_session.gd
# _disable_throttle for the RTT-driven half of the same problem).
func _unlimit(enet: ENetMultiplayerPeer, err: Error) -> void:
	if err == OK and enet.host:
		enet.host.bandwidth_limit(0, 0)

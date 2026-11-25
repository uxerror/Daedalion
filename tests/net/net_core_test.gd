extends GdUnitTestSuite

const NetConfig := preload("res://addons/cogito/Networking/net_config.gd")
const Identity := preload("res://addons/cogito/Networking/net_identity.gd")
const SERVER_DIR := "user://net/core-test"


func test_offline_has_local_authority_and_no_work() -> void:
	assert_int(CogitoNet.mode()).is_equal(CogitoNet.Mode.OFFLINE)
	assert_bool(CogitoNet.is_server()).is_true()
	assert_bool(CogitoNet.is_online()).is_false()
	assert_bool(CogitoNet.is_dedicated()).is_false()
	assert_int(CogitoNet.get_child_count(true)).is_zero()
	assert_bool(CogitoNet.is_processing()).is_false()
	assert_bool(CogitoNet.is_physics_processing()).is_false()
	assert_bool(CogitoNet.multiplayer.multiplayer_peer is OfflineMultiplayerPeer).is_true()
	assert_array(CogitoNet.players()).is_empty()
	assert_str(CogitoNet.local_player_id()).is_empty()
	assert_object(CogitoNet.local_player()).is_null()


func test_cli_overrides_config_independent_of_argument_order() -> void:
	var file := ConfigFile.new()
	file.set_value("server", "port", 7000)
	file.set_value("server", "max_players", 100)
	file.set_value("server", "content_version", "test-release")
	var path := "user://mp0-server.cfg"
	assert_int(file.save(path)).is_equal(OK)
	var args := PackedStringArray(["--port", "8000", "--server", "--config", path])
	var config := NetConfig.parse_cli(args)
	assert_int(config.port).is_equal(8000)
	assert_int(config.max_players).is_equal(100)
	assert_str(config.content_version).is_equal("test-release")
	assert_str(config.bind).is_equal("127.0.0.1")


func test_invalid_config_fails_before_opening_transport() -> void:
	for args: PackedStringArray in [
		PackedStringArray(["--port"]),
		PackedStringArray(["--port", "2.5"]),
		PackedStringArray(["--port", "65536"]),
		PackedStringArray(["--max-players", "0"]),
		PackedStringArray(["--save-dir", "--port"]),
		PackedStringArray(["--bind", "invalid-ip"]),
		PackedStringArray(["--unknown"]),
	]:
		assert_bool(NetConfig.parse_cli(args).has("reason")).is_true()
	assert_bool(NetConfig.server_config({"port": "1"}, true).has("reason")).is_true()
	assert_bool(NetConfig.server_config({"max_players": 4097}, true).has("reason")).is_true()


func test_transport_ceiling_allows_a_local_listen_host() -> void:
	assert_int(NetConfig.server_config({}, false).max_players).is_equal(4095)
	assert_int(NetConfig.server_config({}, true).max_players).is_equal(4096)
	assert_int(NetConfig.server_config({"max_players": 65}, true).max_players).is_equal(65)


func test_protocol_and_content_are_checked_separately() -> void:
	var version := NetConfig.content_version()
	assert_str(version).is_not_empty()
	assert_str(NetConfig.version_error(NetConfig.PROTOCOL_VERSION, version, version)).is_empty()
	assert_str(NetConfig.version_error(0, version, version)).is_equal("Protocol version mismatch")
	var reason := NetConfig.version_error(NetConfig.PROTOCOL_VERSION, "old", version)
	assert_str(reason).is_equal("Content version mismatch")


func test_identity_registration_restart_replay_and_forgery() -> void:
	var identity := Identity.new()
	assert_int(identity.open_server(SERVER_DIR)).is_equal(OK)
	var scope := "test-identity"
	var profile := identity.load_client(scope, {})
	var nonce := Crypto.new().generate_random_bytes(32)
	var reply := identity.respond(profile, nonce, true)
	assert_bool(reply.has("key")).is_false()
	var player_id := identity.authenticate("unknown", nonce, reply)
	assert_str(player_id).is_not_empty()
	assert_str(player_id).is_not_equal("unknown")
	assert_int(identity.save_client(scope, profile, player_id)).is_equal(OK)
	var restarted := Identity.new()
	assert_int(restarted.open_server(SERVER_DIR)).is_equal(OK)
	profile = restarted.load_client(scope, {})
	assert_str(profile.player_id).is_equal(player_id)
	var fresh := Crypto.new().generate_random_bytes(32)
	var proof := restarted.respond(profile, fresh, false)
	assert_array(proof.keys()).contains_exactly(["proof"])
	assert_str(restarted.authenticate(player_id, fresh, proof)).is_equal(player_id)
	assert_str(restarted.authenticate(player_id, nonce, proof)).is_empty()
	var other := restarted.respond({}, fresh, true)
	assert_str(restarted.authenticate(player_id, fresh, other)).is_empty()


func test_damage_and_respawn_configuration() -> void:
	var defaults := NetConfig.server_config({}, true)
	assert_bool(defaults.friendly_fire).is_true()
	assert_float(defaults.respawn_delay).is_equal(10.0)
	var cli := NetConfig.parse_cli(["--friendly-fire", "false", "--respawn-delay", "0"])
	assert_bool(cli.friendly_fire).is_false()
	assert_float(cli.respawn_delay).is_zero()
	for delay: Variant in [-1, INF, NAN, "1"]:
		(
			assert_bool(NetConfig.server_config({"respawn_delay": delay}, false).has("reason"))
			. is_true()
		)
	assert_bool(NetConfig.parse_cli(["--friendly-fire", "sometimes"]).has("reason")).is_true()

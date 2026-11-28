extends "memory_session_suite.gd"

const Probe := preload("latency_probe.gd")
const Schedule := preload("packet_schedule.gd")
const ORDERED := MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
const UNORDERED := MultiplayerPeer.TRANSFER_MODE_UNRELIABLE

var _server: Probe
var _owner: Probe
var _world: Node3D
var _previous_scene: Node
var _previous_fps: int


func before_test() -> void:
	_previous_fps = Engine.max_fps
	Engine.max_fps = 60
	_previous_scene = get_tree().current_scene
	_world = Node3D.new()
	get_tree().root.add_child(_world)
	get_tree().current_scene = _world
	var authority_root := Node.new()
	var client_root := Node.new()
	_world.add_child(authority_root)
	_world.add_child(client_root)
	var authority := _branch(1, authority_root)
	var client := _branch(2, client_root)
	assert_int(authority.start_server({"save_dir": "user://net/latency"})).is_equal(OK)
	_level(authority)
	assert_int(client.join("memory", 1743)).is_equal(OK)
	_level(client)
	_pump()
	_server = Probe.new()
	_owner = Probe.new()
	_server.attach(authority, client.local_player_id())
	_owner.attach(client, client.local_player_id())


func after_test() -> void:
	super.after_test()
	Engine.max_fps = _previous_fps
	get_tree().current_scene = _previous_scene
	_world.free()


func _profile(rtt: int) -> void:
	_network[1].configure(2, 1, Schedule.profile(rtt))
	_network[2].configure(1, 1, Schedule.profile(rtt))


func _measure(rtt: int) -> void:
	_profile(rtt)
	for action: String in ["walk", "jump", "crouch"]:
		await _ticks(85)
		_server.arm(action)
		_owner.arm(action)
		await _owner.phase_complete
		var stamps := _owner.stamps.duplicate()
		assert_int(_server.stamps.seq).is_equal(stamps.seq)
		assert_int(stamps.pose_tick).is_greater_equal(_server.stamps.capture_tick)
		assert_int(_server.stamps.capture_tick).is_greater_equal(_server.stamps.consume_tick)
		if stamps.predicted:
			assert_int(stamps.render_us).is_greater_equal(stamps.sample_us)
		else:
			assert_int(stamps.render_us).is_greater_equal(stamps.arrival_us)
		assert_int(stamps.arrival_us).is_greater_equal(stamps.sample_us)
		stamps.merge(_server.stamps)
		stamps.up_ms = _network[1].schedule.mean_delay_ms(2, 1, ORDERED)
		stamps.down_ms = _network[2].schedule.mean_delay_ms(1, 1, UNORDERED)
		var options := Schedule.profile(rtt)
		var lower_ms := float(options.delay_ms) - float(options.jitter_ms)
		assert_float(minf(stamps.up_ms, stamps.down_ms) + 0.001).is_greater_equal(lower_ms)
		print("PR0 MEMORY ", rtt, " ", JSON.stringify(stamps))


func _expect_prediction() -> bool:
	return (
		preload("res://addons/cogito/Networking/net_config.gd").owner_prediction
		and OS.get_environment("COGITO_AUTHORITY_MOVEMENT") == "1"
	)


func _sample_undelivered(action: String) -> Vector3:
	var tick: int = _owner.avatar.timeline.latest().tick
	var start := _owner.avatar.actor.position
	_network[1].configure(2, 1, {"delay_ms": 250})
	_network[2].configure(1, 1, {"delay_ms": 250})
	_owner.arm(action, 1)
	await _owner.physics_finished
	assert_int(_owner.driver.remaining).is_zero()
	assert_int(_owner.stamps.sample_tick).is_equal(Engine.get_physics_frames())
	assert_int(_owner.avatar.timeline.latest().tick).is_equal(tick)
	assert_int(_server.avatar.source._latest_received).is_less(_owner.stamps.seq)
	return _owner.avatar.actor.position - start


func test_owner_walk_and_stop_on_sample_tick(_timeout := 6000) -> void:
	await _ticks(85)
	var displacement := await _sample_undelivered("walk")
	if _expect_prediction():
		assert_float(-displacement.z).is_greater(0.001)
		var speed := _owner.avatar.actor.velocity.length()
		var pose: int = _owner.avatar.timeline.latest().tick
		await _owner.physics_finished
		assert_float(_owner.avatar.actor.velocity.length()).is_less(speed)
		assert_int(_owner.avatar.timeline.latest().tick).is_equal(pose)
		assert_int(_server.avatar.source._latest_received).is_less(_owner.stamps.seq)
	else:
		assert_vector(displacement).is_equal(Vector3.ZERO)
	print("PR3 SAME TICK walk ", displacement, " predicted=", _expect_prediction())
	await _owner.phase_complete


func test_owner_jump_on_sample_tick() -> void:
	await _ticks(85)
	var displacement := await _sample_undelivered("jump")
	if _expect_prediction():
		assert_float(displacement.y).is_greater(0)
	else:
		assert_vector(displacement).is_equal(Vector3.ZERO)
	print("PR3 SAME TICK jump ", displacement)


func test_owner_crouch_on_sample_tick() -> void:
	await _ticks(85)
	var height := _owner.avatar.actor.head.position.y
	await _sample_undelivered("crouch")
	var change := _owner.avatar.actor.head.position.y - height
	if _expect_prediction():
		assert_float(change).is_less(0)
	else:
		assert_float(change).is_zero()
	print("PR3 SAME TICK crouch ", change)


func test_owner_latency_0_ms(_timeout := 15000) -> void:
	await _measure(0)


func test_owner_latency_16_ms(_timeout := 15000) -> void:
	await _measure(16)


func test_owner_latency_100_ms(_timeout := 15000) -> void:
	await _measure(100)


func test_owner_latency_150_ms(_timeout := 15000) -> void:
	await _measure(150)

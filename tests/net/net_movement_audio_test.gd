extends "memory_session_suite.gd"

const Footsteps := preload("../player/golden_footsteps.gd")
const Avatar := preload("res://addons/cogito/Networking/net_avatar.gd")
const Stone := preload(
	"res://addons/cogito/DynamicFootstepSystem/FootstepProfiles/stone_footstep_profile.tres"
)
const MODE := CogitoMovementState.Mode

var _server: Facade
var _owner: Facade
var _observer_branch: Facade
var _authority: Avatar
var _id: String
var _ears: Array[Recorder] = []


class Driver:
	extends CogitoPlayerInputSource
	var move := Vector2.ZERO
	var held := 0

	func sample(actor: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
		var cmd := super.sample(actor, sequence)
		cmd.move = move
		cmd.held = held
		return cmd


class Recorder:
	extends RefCounted
	var actor: CogitoPlayerAdvanced
	var feet: Footsteps
	var jumps := 0
	var strokes := 0
	var noises := 0
	var slides := []

	func _init(avatar: Avatar) -> void:
		actor = avatar.actor
		var detector := actor.footstep_surface_detector
		var exports := {}
		for prop in detector.get_property_list():
			if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and prop.usage & PROPERTY_USAGE_STORAGE:
				exports[prop.name] = detector.get(prop.name)
		detector.set_script(Footsteps)
		for key: String in exports:
			detector.set(key, exports[key])
		feet = detector as Footsteps
		feet._ready()
		CogitoLevel.root_of(actor).child_entered_tree.connect(_noise)
		actor.child_entered_tree.connect(_spatial)
		if actor.is_local_presentation:
			CogitoAudio.child_entered_tree.connect(_owner_jump)
		avatar.movement_audio.slide_changed.connect(slides.append)

	func _noise(node: Node) -> void:
		if node is ObjectNoise:
			noises += 1

	func _owner_jump(node: Node) -> void:
		if node is AudioStreamPlayer and node.stream == actor.jump_sound:
			jumps += 1

	func _spatial(node: Node) -> void:
		if node is AudioStreamPlayer3D:
			if node.stream == actor.jump_sound:
				jumps += 1
			if node.stream == actor.swim_movement_sound:
				strokes += 1


func _mount(branch: Facade) -> void:
	var host: CogitoLevelHost = branch.player_world.travel.host
	var room := host.load_level("res://tests/player/golden_level.tscn", &"arena", true)
	var surface := FootstepSurface.new()
	surface.footstep_profile = Stone
	room.get_node("Obstacles").add_child(surface)
	surface.owner = room
	var start := Transform3D(Basis.IDENTITY, Vector3(0, 1, 12))
	branch.player_world.bind_level(room, start, "arena")
	host.present(&"arena")


func _stage(listen: bool, spawn_at_stairs := false) -> void:
	_ears.clear()
	_server = _branch(1)
	var config := {
		"save_dir": create_temp_dir("audio-%d" % Time.get_ticks_usec()), "respawn_delay": 0
	}
	var err := _server.host(config) if listen else _server.start_server(config)
	assert_int(err).is_equal(OK)
	_mount(_server)
	_observer_branch = _branch(3)
	assert_int(_observer_branch.join("memory", 1913)).is_equal(OK)
	_mount(_observer_branch)
	_pump()
	if spawn_at_stairs:
		_server.spawn_policy = func(
			_root: Node, _player_id: String, _start: Transform3D
		) -> Transform3D:
			return Transform3D(Basis.IDENTITY, Vector3(-4, 1, 0))
	_owner = _branch(2)
	assert_int(_owner.join("memory", 1912)).is_equal(OK)
	_mount(_owner)
	_pump()
	await _ticks(30)
	_id = _owner.local_player_id()
	_authority = _server.player_world.avatar_for(_id)
	if listen:
		var host := _server.player_world.avatar_for(_server.local_player_id())
		assert_object(host.movement_audio).is_null()
		_ears.append(Recorder.new(_authority))
	else:
		assert_object(_authority.movement_audio).is_null()
		(
			assert_array(_authority.actor.find_children("*", "AudioStreamPlayer3D", true, false))
			. is_empty()
		)
	for peer in [_owner, _observer_branch]:
		var ear := Recorder.new(peer.player_world.avatar_for(_id))
		assert_int(ear.actor.collision_layer | ear.actor.collision_mask).is_zero()
		_ears.append(ear)


func after_test() -> void:
	_ears.clear()
	super.after_test()


func _walk_and_jump(listen: bool) -> void:
	await _stage(listen)
	var driver := Driver.new()
	_owner.player_world.local_actor.input_source = driver
	var start := _authority.actor.position
	driver.move = Vector2.UP
	await _ticks(120)
	assert_float(start.z - _authority.actor.position.z).is_greater(5.0)
	var expected := roundi(2.0 * _authority.actor.WIGGLE_ON_WALKING_SPEED / TAU)
	for ear in _ears:
		assert_int(ear.feet.footsteps).is_between(expected - 1, expected + 1)
		assert_float(ear.feet.volume_db).is_equal(ear.actor.walk_volume_db)
		assert_int(ear.feet.footsteps).is_equal(_ears[0].feet.footsteps)
		assert_object(ear.feet.last_result.collider).is_same(
			CogitoLevel.root_of(ear.actor).get_node("Floor")
		)
		assert_object(ear.feet.stream).is_same(ear.feet.generic_fallback_footstep_profile)
		assert_int(ear.jumps).is_zero()
	driver.move = Vector2.ZERO
	driver.held = 1 << CogitoPlayerCommand.Action.JUMP
	await _ticks(6)
	driver.held = 0
	await _ticks(120)
	for ear in _ears:
		assert_int(ear.jumps).is_equal(1)
		assert_int(ear.feet.landings).is_equal(1)
		assert_int(ear.noises).is_zero()


func test_dedicated_owner_and_spatial_observer(_timeout := 20000) -> void:
	await _walk_and_jump(false)


func test_listen_remote_and_both_clients(_timeout := 20000) -> void:
	await _walk_and_jump(true)


# Publish controlled contacts through the normal authority capture and both replica endpoints.
func _pose(mode: int, velocity: Vector3, height := 0.81) -> void:
	_authority.actor.current_moving_state = mode as CogitoPlayerAdvanced.MovingState
	_authority.actor.velocity = velocity
	_authority.actor.position.y = height
	_server.player_world._physics_process(1.0 / Engine.physics_ticks_per_second)
	_pump()


func test_surface_modes_strokes_and_slide_edges() -> void:
	await _stage(true)
	_server.player_world.snapshot_hz = Engine.physics_ticks_per_second
	for mode: int in [MODE.SPRINTING, MODE.SNEAKING]:
		for tick in 100:
			_pose(mode, Vector3.RIGHT * 3)
		for ear in _ears:
			var volume := (
				ear.actor.sprint_volume_db if mode == MODE.SPRINTING else ear.actor.crouch_volume_db
			)
			assert_float(ear.feet.volume_db).is_equal(volume)
	for tick in 6:
		_pose(MODE.SLIDING, Vector3.RIGHT)
	_pose(MODE.LADDER_CLIMBING, Vector3.UP)
	for tick in 120:
		_pose(MODE.SWIMMING, Vector3.RIGHT)
	for ear in _ears:
		assert_array(ear.slides).is_equal([true, false])
		assert_int(ear.strokes).is_equal(_ears[0].strokes)
		assert_int(ear.strokes).is_greater(0)
		assert_int(ear.jumps).is_zero()
		assert_int(ear.feet.landings).is_zero()


func test_stairs_ledge_landing_and_discontinuities() -> void:
	await _stage(true, true)
	var driver := Driver.new()
	_owner.player_world.local_actor.input_source = driver
	driver.move = Vector2.UP
	await _ticks(55)
	driver.move = Vector2.ZERO
	assert_float(_authority.actor.position.y).is_greater(1.1)
	for ear in _ears:
		assert_object(ear.feet.stream).is_same(Stone)
		assert_int(ear.jumps).is_zero()
		assert_int(ear.feet.footsteps).is_greater(0)
	# Continue on the flat floor for the isolated threshold and reset cases.
	_authority.actor.position = Vector3(0, 0.81, 6)
	_server.player_world.mark_teleport(_id)
	_server.player_world.snapshot_hz = Engine.physics_ticks_per_second
	_pose(MODE.WALKING, Vector3.RIGHT)
	_pose(MODE.WALKING, Vector3(2, 5, 0), 1.01)
	_pose(MODE.AIR_CONTROL, Vector3.DOWN, 1.02)
	_pose(MODE.IDLE, Vector3.ZERO)
	for ear in _ears:
		assert_int(ear.jumps).is_zero()
		assert_int(ear.feet.landings).is_zero()
	_pose(MODE.FREE_FALL, Vector3.DOWN * 5, 1.1)
	_pose(MODE.IDLE, Vector3.ZERO)
	for ear in _ears:
		assert_int(ear.feet.landings).is_equal(1)
		assert_float(ear.actor.landing_volume).is_equal_approx(-20, 0.001)
		assert_float(ear.actor.landing_pitch).is_equal_approx(0.75, 0.001)
	_pose(MODE.FREE_FALL, Vector3.DOWN * 8, 1.1)
	_server.player_world.mark_teleport(_id)
	_pose(MODE.IDLE, Vector3.ZERO)
	_pose(MODE.FREE_FALL, Vector3.DOWN * 8, 6.0)
	_pose(MODE.IDLE, Vector3.ZERO)
	_pose(MODE.FREE_FALL, Vector3.DOWN * 8, 1.1)
	_authority.actor.is_sitting = true
	_pose(MODE.SITTING, Vector3.ZERO)
	_authority.actor.is_sitting = false
	_pose(MODE.IDLE, Vector3.ZERO)
	_pose(MODE.FREE_FALL, Vector3.DOWN * 8, 1.1)
	_server.player_world.death.die(_authority.actor)
	_pump()
	var reason := _server.player_world.death.try_respawn(_id, _authority.lifetime)
	assert_str(reason).is_empty()
	_pump()
	_pose(MODE.IDLE, Vector3.ZERO)
	for ear in _ears:
		assert_int(ear.feet.landings).is_equal(1)
		assert_int(ear.jumps).is_zero()


func test_hidden_listen_room_is_silent_and_reopens_silently() -> void:
	await _stage(true)
	_server.player_world.snapshot_hz = Engine.physics_ticks_per_second
	var host: CogitoLevelHost = _server.player_world.travel.host
	host.present(&"")
	_pose(MODE.JUMPING, Vector3.UP)
	_pose(MODE.FREE_FALL, Vector3.DOWN * 5, 1.1)
	host.present(&"arena")
	_pose(MODE.IDLE, Vector3.ZERO)
	assert_int(_ears[0].jumps).is_zero()
	assert_int(_ears[0].feet.landings).is_zero()
	assert_int(_ears[1].jumps).is_equal(1)
	assert_int(_ears[1].feet.landings).is_equal(1)

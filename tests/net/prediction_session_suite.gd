extends "memory_session_suite.gd"

const AudioTest := preload("net_movement_audio_test.gd")
const Grid := preload("res://addons/cogito/Networking/net_grid.gd")
const Rifle := preload("res://addons/cogito/InventoryPD/Items/Cogito_LaserRifle.tres")
const Config := preload("res://addons/cogito/Networking/net_config.gd")
const Avatar := preload("res://addons/cogito/Networking/net_avatar.gd")
const Channel := preload("res://addons/cogito/Networking/net_command_channel.gd")
const Shadow := preload("owner_checkpoint_trace.gd")
const ACTION := CogitoPlayerCommand.Action

var _root: Node3D
var _previous: Node
var _previous_switch: bool
var _server: Facade
var _client: Facade
var _owner: Avatar
var _authority: Avatar
var _driver: Driver
var _channel: ChannelProbe
var _ear: AudioTest.Recorder
var _shots := 0
var _entries: Array[Node3D] = []


class Driver:
	extends CogitoPlayerInputSource
	var walking := false
	var reverse := false
	var held := 0
	var turn := 0.0
	var tap := false
	var samples := 0
	var commands := {}

	func sample(actor: CogitoPlayer, seq: int) -> CogitoPlayerCommand:
		samples += 1
		var cmd := super.sample(actor, seq)
		cmd.yaw += turn
		if walking:
			cmd.move = Vector2.DOWN if reverse else Vector2.UP
		cmd.held = held
		cmd.toggle_crouch = false
		if tap:
			cmd.add_edge(ACTION.JUMP)
			cmd.add_edge(ACTION.PRIMARY)
			tap = false
		commands[seq] = cmd
		return cmd


class ChannelProbe:
	extends Channel
	var packets := 0
	var mute := 0

	func packet(command: CogitoPlayerCommand) -> PackedByteArray:
		packets += 1
		var encoded := super.packet(command)
		if mute > 0:
			mute -= 1
			return PackedByteArray()
		return encoded


func before_test() -> void:
	_previous = get_tree().current_scene
	_root = Node3D.new()
	get_tree().root.add_child(_root)
	get_tree().current_scene = _root
	_previous_switch = Config.owner_prediction
	Config.owner_prediction = true
	var previous_env := OS.get_environment("COGITO_AUTHORITY_MOVEMENT")
	OS.set_environment("COGITO_AUTHORITY_MOVEMENT", "1")
	_server = _branch(1, _root)
	(
		assert_int(_server.start_server({"save_dir": create_temp_dir("pr3"), "respawn_delay": 0.0}))
		. is_equal(OK)
	)
	_level(_server)
	_client = _branch(2)
	assert_int(_client.join("memory", 1951)).is_equal(OK)
	var level := _level(_client)
	_pump()
	OS.set_environment("COGITO_AUTHORITY_MOVEMENT", previous_env)
	_owner = _client.player_world.avatar_for(_client.local_player_id())
	_authority = _server.player_world.avatar_for(_client.local_player_id())
	_driver = Driver.new()
	_channel = ChannelProbe.new()
	_owner.actor.input_source = _driver
	_client.player_world.command_channel = _channel
	var plate := Area3D.new()
	plate.collision_layer = 0
	plate.collision_mask = 16
	var hull := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 5, 8)
	hull.shape = box
	plate.add_child(hull)
	_entries.clear()
	plate.body_entered.connect(_entries.append)
	level.add_child(plate)


func after_test() -> void:
	_ear = null
	super.after_test()
	Config.owner_prediction = _previous_switch
	get_tree().current_scene = _previous
	_root.free()


func _equip_rifle() -> WieldableItemPD:
	var slot := InventorySlotPD.new()
	slot.inventory_item = Rifle
	var bag := _authority.actor.inventory_data
	assert_int(Grid.insert(bag, slot, 1, false)).is_equal(1)
	var equipped := bag.find_slots(Rifle.name)[0] as InventorySlotPD
	_server.player_world.inventory.flush_actor(_authority.actor)
	_pump()
	var api := _client.player_world.inventory
	var index: int = equipped.origin_index
	var item_id := api.local.id_of(api.local.data.inventory_slots[index])
	api.dispatch(api.make_request("use", [index, item_id]))
	_pump()
	_shots = 0
	_client.player_world.combat.presented.connect(_combat_event)
	_ear = AudioTest.Recorder.new(_owner)
	return equipped.inventory_item


func _combat_event(_actor: CogitoPlayerAdvanced, event: StringName, _point: Vector3) -> void:
	_shots += int(event == &"fire")


func _verify_replay(block: NetOwnerState) -> void:
	var prediction := _owner.prediction
	var live_sequence := _owner.actor.last_consumed_sequence
	var samples := _driver.samples
	var packets := _channel.packets
	var position := _owner.actor.position
	var stamina := _owner.actor.stamina_attribute.value_current
	var oxygen: float = _owner.actor.player_attributes["oxygen"].value_current
	var health: float = _owner.actor.player_attributes["health"].value_current
	var noises := [_shots, _ear.jumps, _ear.feet.footsteps, _ear.feet.landings]
	var audio_tick: int = _owner.movement_audio._previous.tick
	var clip := _owner.actor.animationPlayer.current_animation
	var clip_time := _owner.actor.animationPlayer.current_animation_position if clip else 0.0
	var wield_seq := _owner.wield._predicted_sequence
	var shadow := Shadow.new(_authority.actor, block.tick, block)
	var expected := range(block.ack + 1, live_sequence + 1)
	var references: Array[CogitoMovementState] = []
	for seq in expected:
		var cmd := Channel.freeze(_driver.commands[seq])
		if block.input_blocked:
			cmd = CogitoPlayerCommand.new()
			cmd.has_control = false
			cmd.yaw = block.state.body_yaw
		shadow.advance(cmd)
		references.append(shadow.state.duplicate())
	var yaw := _owner.actor.body.rotation.y + 0.071
	_owner.actor.body.rotation.y = yaw
	prediction.begin_tick()
	assert_int(prediction.last_restore_tick).is_equal(block.tick)
	assert_array(prediction.last_replay).contains_exactly(expected)
	assert_int(_owner.actor.last_consumed_sequence).is_equal(live_sequence)
	assert_int(_driver.samples).is_equal(samples)
	assert_int(_channel.packets).is_equal(packets)
	assert_int(_owner.movement_audio._previous.tick).is_equal(audio_tick)
	assert_array([_shots, _ear.jumps, _ear.feet.footsteps, _ear.feet.landings]).is_equal(noises)
	assert_int(_owner.wield._predicted_sequence).is_equal(wield_seq)
	assert_str(_owner.actor.animationPlayer.current_animation).is_equal(clip)
	if clip:
		assert_float(_owner.actor.animationPlayer.current_animation_position).is_equal(clip_time)
	assert_float(_owner.actor.stamina_attribute.value_current).is_equal(stamina)
	assert_float(_owner.actor.player_attributes["oxygen"].value_current).is_equal(oxygen)
	assert_float(_owner.actor.player_attributes["health"].value_current).is_equal(health)
	assert_float(_owner.actor.body.rotation.y).is_equal_approx(yaw, 0.000001)
	assert_vector(_owner.actor.position).is_equal(position)
	var post := prediction.post_at(live_sequence)
	var actor := _owner.actor
	var head_pose := actor.head.transform
	head_pose.origin = post.head_position
	var corrected_root := prediction.solver.world_from_room * post.transform
	var expected_eye := corrected_root * actor.body.transform * actor.neck.transform * head_pose
	var ray := actor.player_interaction_component.interaction_raycast
	assert_bool(actor.get_aim_transform().is_equal_approx(expected_eye)).is_true()
	assert_bool(ray.global_position.is_equal_approx(expected_eye.origin)).is_true()
	for i in expected.size():
		shadow.state = references[i]
		var replayed := prediction.post_at(expected[i])
		shadow.compare_to(replayed)
		assert_vector(replayed.slide_vector).is_equal(shadow.state.slide_vector)
		assert_float(replayed.bunny_hop_speed).is_equal(shadow.state.bunny_hop_speed)
		assert_vector(replayed.head_offset).is_equal(shadow.state.head_offset)
	assert_dict(shadow.mismatches).is_empty()
	assert_float(shadow.pos_error).is_less_equal(0.00001)
	assert_float(shadow.vel_error).is_less_equal(0.00001)
	assert_float(shadow.eye_error).is_less_equal(0.00001)
	assert_float(shadow.stamina_error).is_less_equal(0.000001)
	assert_array(_entries).is_empty()
	print(
		"PR3 REPLAY tick=",
		block.tick,
		" ack=",
		block.ack,
		" sequences=",
		expected,
		" pos=",
		shadow.pos_error,
		" vel=",
		shadow.vel_error,
		" eye=",
		shadow.eye_error,
		" offset=",
		prediction.render_offset.length()
	)
	shadow.room.close()
	shadow.body.free()


func _stage_volume(point: Vector3) -> void:
	_authority.actor.position = point
	_authority.actor.main_velocity = Vector3.ZERO
	_authority.actor.velocity = Vector3.ZERO
	_server.player_world.mark_teleport(_client.local_player_id())
	for i in 60:
		await _ticks(1)
		var prediction := _owner.prediction
		if prediction.active and prediction.baseline.revision == _authority.revision:
			return
	fail("Volume staging revision did not become eligible")


func _push_in_volume(mode: int) -> void:
	_authority.actor.position.x += 0.30
	var tick := _server.player_world._tick
	for i in 24:
		await _ticks(1)
		var block := _owner.prediction.queued
		if block and block.tick > tick and block.state:
			assert_int(block.state.mode).is_equal(mode)
			assert_int(_owner.prediction.newest - block.ack).is_greater(0)
			var strokes := _ear.strokes
			_verify_replay(block)
			assert_int(_ear.strokes).is_equal(strokes)
			return
	fail("Missing authoritative volume checkpoint after push")


func _deliver(block: NetOwnerState) -> void:
	var frame := _owner.timeline.latest().duplicate()
	frame.tick = block.tick
	frame.ack = block.ack
	frame.owner_state = NetOwnerState.encode(block)
	_client.player_world._receive_pose(_client.local_player_id(), block.life, frame)


func _assert_rest() -> void:
	var gap := _owner.actor.position.distance_to(_authority.actor.position)
	assert_float(gap).is_less_equal(0.02)
	assert_float(_owner.actor.velocity.distance_to(_authority.actor.velocity)).is_less_equal(0.10)
	assert_array(_entries).is_empty()

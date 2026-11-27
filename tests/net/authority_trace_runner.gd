extends Node
## Fixed 60 Hz authority traces use the same room, sampler and prefab in each process.

const Footsteps := preload("../player/golden_footsteps.gd")
const Driver := preload("../player/golden_input.gd")
const MemorySuite := preload("memory_session_suite.gd")
const Room := preload("../player/golden_level.tscn")
const LANES := ["ground", "crouch", "toggle_roof", "stairs", "slide", "tired", "slope", "wall"]
var peers := {}
var jumps := 0


class NoiseRecorder:
	extends "res://addons/cogito/Networking/net_npc_listeners.gd"
	var count := 0

	func noise(actor: CogitoPlayer, magnitude: float) -> void:
		count += 1
		super.noise(actor, magnitude)


class Route:
	extends Driver

	func sample(actor: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
		var command := super.sample(actor, sequence)
		if lane == "slope" or lane == "wall":
			if sequence >= 30 and sequence < 100:
				command.move = Vector2(0.5, -1) if lane == "wall" else Vector2.UP
		return command


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for lane: String in LANES:
		await _lane(lane)
	get_tree().quit()


func _observe_feet(actor: CogitoPlayerAdvanced) -> Footsteps:
	var detector := actor.footstep_surface_detector
	var exports := {}
	for prop: Dictionary in detector.get_property_list():
		if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and prop.usage & PROPERTY_USAGE_STORAGE:
			exports[prop.name] = detector.get(prop.name)
	detector.set_script(Footsteps)
	for key: String in exports:
		detector.set(key, exports[key])
	return detector as Footsteps


func _sound(node: Node, jump_sound: AudioStream) -> void:
	if node is AudioStreamPlayer and node.stream == jump_sound:
		jumps += 1


func _lane(lane: String) -> void:
	var room := Room.instantiate() as Node3D
	get_tree().root.add_child(room)
	get_tree().current_scene = room
	if lane == "slope":
		var ramp := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(4, 1, 12)
		shape.shape = box
		ramp.position = Vector3(0, -0.45, -5)
		ramp.rotation.x = 0.12
		ramp.add_child(shape)
		room.add_child(ramp)
	CogitoNet.transport_factory = func(): return MemorySuite.MemoryTransport.new(peers, 1)
	var folder := "user://authority-trace/%s/%s" % [Time.get_ticks_usec(), lane]
	if CogitoNet.host({"save_dir": folder}) != OK:
		get_tree().quit(1)
		return
	var start: Vector3 = Driver.START.get(lane, Vector3.UP)
	if lane == "wall":
		start.x = 15
	var endpoint := CogitoNet.player_world
	endpoint.bind_level(room, Transform3D(Basis.IDENTITY, start), "arena")
	var actor := endpoint.local_actor
	var driver := Route.new()
	driver.lane = lane
	actor.input_source = driver
	actor.CAN_CLIMB_LEDGE = false
	if lane == "tired":
		actor.stamina_attribute.value_current = 5.05
	endpoint.npcs.set_script(NoiseRecorder)
	var listener := endpoint.npcs as NoiseRecorder
	var feet := _observe_feet(actor)
	var on_sound := _sound.bind(actor.jump_sound)
	CogitoAudio.child_entered_tree.connect(on_sound)
	jumps = 0
	var slides := 0
	var sliding := false
	var total := actor.authority_solve_count
	for tick: int in Driver.LENGTH.get(lane, 120):
		await get_tree().physics_frame
		await get_tree().process_frame
		var row := [
			actor.last_consumed_sequence,
			actor.position.x,
			actor.position.y,
			actor.position.z,
			actor.head.position.y,
			actor.velocity.length(),
			actor.current_moving_state,
			actor.current_body_posture_state,
			actor.standing_collision_shape.disabled,
			actor.stamina_attribute.value_current,
			actor.jumped_from_slide,
		]
		print("TRACE ", lane, " ", JSON.stringify(row))
		print("SOLVES ", lane, " ", tick, " ", actor.authority_solve_count - total)
		total = actor.authority_solve_count
		var playing := actor.slide_audio_player != null and actor.slide_audio_player.playing
		slides += int(playing and not sliding)
		sliding = playing
	var events := [feet.footsteps, feet.landings, jumps, slides, listener.count]
	print("EFFECTS ", lane, " ", JSON.stringify(events))
	var solves := actor.authority_movement.solves if actor.authority_movement else 0
	print("WRITERS ", lane, " ", solves, " ", total)
	CogitoAudio.child_entered_tree.disconnect(on_sound)
	get_tree().current_scene = self
	CogitoNet.disconnect_session()
	room.free()
	peers.clear()
	await get_tree().process_frame

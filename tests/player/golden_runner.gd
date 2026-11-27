extends Node
## Launch with --fixed-fps 60 so physics, idle chart delays, stamina, tweens and roll
## animation all advance by exactly 1/60 s, independently of host scheduling.

const Driver := preload("golden_input.gd")
const Footsteps := preload("golden_footsteps.gd")
const GoldenLevel := preload("golden_level.tscn")
const PlayerScene := preload("res://addons/cogito/PackedScenes/cogito_player_advanced.tscn")
const SeatScene := preload("res://addons/cogito/DemoScenes/DemoPrefabs/cogito_sittable.tscn")
const DIRECTORY := "res://tests/player/golden/"

var actor: CogitoPlayerAdvanced
var states: Array[Node]
var jumps := 0
var slides := 0
var slide_playing := false


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var traces := {}
	CogitoAudio.child_entered_tree.connect(_one_shot)
	for lap in 2:
		for lane: String in Driver.START:
			var trace := await _record(lane)
			if trace.is_empty():
				get_tree().quit(1)
				return
			if lap == 0:
				traces[lane] = trace
			elif not _matches(lane, traces[lane], trace):
				get_tree().quit(1)
				return
	var regenerate := "--regenerate" in OS.get_cmdline_user_args()
	var digests := PackedStringArray()
	for lane: String in traces:
		var path := DIRECTORY + lane + ".csv"
		var trace: String = traces[lane]
		if regenerate:
			var writer := FileAccess.open(path, FileAccess.WRITE)
			writer.store_string(trace)
			writer.close()
		elif not _matches(path, FileAccess.get_file_as_string(path), trace):
			get_tree().quit(1)
			return
		digests.append(trace.sha256_text())
	print("GOLDEN PASS ", ",".join(digests).sha256_text())
	get_tree().quit()


func _matches(label: String, reference: String, actual: String) -> bool:
	if reference == actual:
		return true
	var expected := reference.split("\n")
	var rows := actual.split("\n")
	for index in mini(rows.size(), expected.size()):
		if rows[index] != expected[index]:
			printerr(
				label, " line ", index + 1, " expected ", expected[index], " got ", rows[index]
			)
			break
	printerr("GOLDEN MISMATCH ", label, " lengths ", expected.size(), "/", rows.size())
	return false


func _one_shot(node: Node) -> void:
	if is_instance_valid(actor) and node is AudioStreamPlayer and node.stream == actor.jump_sound:
		jumps += 1


func _spawn(level: Node3D, lane: String) -> void:
	var driver := Driver.new()
	driver.lane = lane
	if lane == "seat":
		driver.seat = SeatScene.instantiate()
		driver.seat.position = Vector3(0, 1, -1.2)
		driver.seat.sit_area_behaviour = CogitoSittable.SitAreaBehaviour.NONE
		driver.seat.placement_on_leave = CogitoSittable.PlacementOnLeave.ORIGINAL
		driver.seat.interact_cooldown_duration = 0.0
		driver.seat.tween_duration = 0.05
		driver.seat.rotation_tween_duration = 0.05
		driver.seat.prompt_pos_mode = CogitoSittable.PromptPositionMode.MARKER
		driver.seat.prompt_marker = driver.seat.get_node("Look Marker")
		level.add_child(driver.seat)
	actor = PlayerScene.instantiate()
	actor.inventory_data = actor.inventory_data.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	actor.input_source = driver
	actor.position = Driver.START[lane]
	# Preserve the prefab's exported surface libraries when attaching the playback counter.
	var detector := actor.get_node("FootstepPlayer")
	var exports := {}
	for prop: Dictionary in detector.get_property_list():
		if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and prop.usage & PROPERTY_USAGE_STORAGE:
			exports[prop.name] = detector.get(prop.name)
	detector.set_script(Footsteps)
	for key: String in exports:
		detector.set(key, exports[key])
	level.add_child(actor)
	actor.TOGGLE_CROUCH = lane == "roll"
	actor.HEADBOBBLE = 1
	states = actor.state_chart.find_children("*", "StateChartState", true, false)
	seed(140)  # Advanced randomizes in _ready() on the offline path.
	jumps = 0
	slides = 0
	slide_playing = false


func _record(lane: String) -> String:
	var tree := get_tree()
	var level := GoldenLevel.instantiate() as Node3D
	tree.root.add_child(level)
	tree.current_scene = level
	await tree.process_frame
	_spawn(level, lane)
	var paths := PackedStringArray()
	for state: StateChartState in states:
		paths.append(str(actor.state_chart.get_path_to(state)))
	var rows := PackedStringArray(["# active-state bits: " + ",".join(paths)])
	(
		rows
		. append(
			(
				"tick,px,py,pz,vx,vy,vz,mx,my,mz,hx,hy,hz,ex,ey,ez,stamina,moving,posture,states,"
				+ "shapes,blocked,submerged,slide_jump,ledge_middle,ledge_final,steps,lands,jumps,slides"
			)
		)
	)
	for tick: int in Driver.LENGTH[lane]:
		await tree.physics_frame
		if lane == "platform":
			level.get_node("Platform").position.x = 22.0 + clampi(tick - 25, 0, 80) / 60.0
		await tree.process_frame
		if not is_equal_approx(get_process_delta_time(), 1.0 / 60.0):
			printerr("Golden movement requires --fixed-fps 60")
			return ""
		if actor.last_consumed_sequence != tick or Engine.physics_ticks_per_second != 60:
			printerr("Unexpected physics sample on ", lane, " tick ", tick)
			return ""
		rows.append(_row(tick))
	tree.current_scene = self
	level.free()
	await tree.physics_frame
	await tree.process_frame
	return "\n".join(rows) + "\n"


func _row(tick: int) -> String:
	var fields := PackedStringArray([str(tick)])
	for v: Vector3 in [
		actor.position,
		actor.velocity,
		actor.main_velocity,
		actor.head.position,
		actor.eyes.position,
	]:
		for component in 3:
			fields.append(str(roundi(v[component] * 100000)))
	fields.append(str(roundi(actor.stamina_attribute.value_current * 100000)))
	var active := 0
	for i in states.size():
		if states[i].active:
			active |= 1 << i
	var shapes := int(not actor.standing_collision_shape.disabled)
	shapes |= int(not actor.crouching_collision_shape.disabled) << 1
	var sound := actor.slide_audio_player and actor.slide_audio_player.playing
	if sound and not slide_playing:
		slides += 1
	slide_playing = sound
	var feet := actor.footstep_surface_detector as Footsteps
	for value: int in [
		actor.current_moving_state,
		actor.current_body_posture_state,
		active,
		shapes,
		int(actor.crouch_shapecast.is_colliding()),
		int(actor.swimming_head_shapecast.is_colliding()),
		int(actor.jumped_from_slide),
		int(actor.is_in_ledge_climbing_middle_stage),
		int(actor.is_in_ledge_climbing_final_stage),
		feet.footsteps,
		feet.landings,
		jumps,
		slides,
	]:
		fields.append(str(value))
	return ",".join(fields)

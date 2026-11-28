extends Node
## One owner, one authority, no clock synchronization. Sequence numbers join the two logs.

signal phase_complete(stamps: Dictionary)
signal physics_finished

const Snapshot := preload("res://addons/cogito/Networking/net_snapshot.gd")
const Avatar := preload("res://addons/cogito/Networking/net_avatar.gd")
const Facade := preload("res://addons/cogito/Networking/cogito_net.gd")
const ACTION := CogitoPlayerCommand.Action
const EPSILON := 0.0001

var facade: Facade
var avatar: Avatar
var driver := Driver.new()
var action := ""
var origin: float
var stamps := {}
var _completed := false
var _pre_render_position := 0.0


class Driver:
	extends CogitoPlayerInputSource
	signal sampled(sequence: int)
	var action := ""
	var remaining := 0
	var fresh := false

	func sample(actor: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
		var command := super.sample(actor, sequence)
		if remaining == 0:
			return command
		remaining -= 1
		match action:
			"walk":
				command.move = Vector2.UP
				command.yaw = 0.0
			"jump":
				command.held = 1 << ACTION.JUMP
			"crouch":
				command.held = 1 << ACTION.CROUCH
		command.toggle_crouch = false
		if fresh:
			fresh = false
			sampled.emit(sequence)
		return command


class ArrivalTimeline:
	extends Snapshot
	signal arrived(frame: Dictionary, usec: int)

	func _init(previous: Snapshot) -> void:
		_frames = previous._frames
		_arrival_usec = previous._arrival_usec
		_render_tick = previous._render_tick

	func push(frame: Dictionary) -> Acceptance:
		var result := super.push(frame)
		if result != Acceptance.REJECTED:
			arrived.emit(frame, _arrival_usec)
		return result


func attach(branch: Facade, owner_id: String) -> void:
	facade = branch
	avatar = branch.player_world.avatar_for(owner_id)
	process_physics_priority = 101  # NetPlayers captures at 100.
	process_priority = 101  # Observe the normal present() on the same render.
	if avatar.timeline:
		var observer := ArrivalTimeline.new(avatar.timeline)
		avatar.timeline = observer
		observer.arrived.connect(_arrived)
		avatar.actor.input_source = driver
		driver.sampled.connect(_sampled)
		branch.get_tree().process_frame.connect(_before_render)
	branch.add_child(self)


func arm(label: String, duration := 8) -> void:
	_completed = false
	action = label
	stamps = {"action": action}
	origin = coordinate()
	if avatar.timeline:
		driver.action = label
		driver.fresh = true
		driver.remaining = 1 if label == "jump" else duration


func coordinate() -> float:
	match action:
		"walk":
			return -avatar.actor.position.z
		"jump":
			return avatar.actor.position.y
		_:
			return -avatar.actor.head.position.y


func _sampled(sequence: int) -> void:
	stamps.seq = sequence
	stamps.sample_tick = Engine.get_physics_frames()
	stamps.sample_us = Time.get_ticks_usec()


func _arrived(frame: Dictionary, usec: int) -> void:
	if not stamps.has("sample_us") or stamps.has("arrival_us") or frame.ack < stamps.seq:
		return
	var value: float = -frame.height
	if action == "walk":
		value = -frame.position.z
	elif action == "jump":
		value = frame.position.y
	if value > origin + EPSILON:
		stamps.arrival_us = usec
		stamps.pose_tick = frame.tick
		stamps.pose_ack = frame.ack
		_complete()


func _physics_process(delta: float) -> void:
	if not is_instance_valid(avatar.actor):
		return
	if avatar.source and not action.is_empty() and not stamps.has("capture_tick"):
		var cmd := avatar.actor.current_command
		var pressed := cmd.move.y < 0 if action == "walk" else cmd.is_held(ACTION.JUMP)
		if action == "crouch":
			pressed = cmd.is_held(ACTION.CROUCH)
		if pressed and not stamps.has("consume_tick"):
			stamps.seq = avatar.actor.last_consumed_sequence
			stamps.consume_tick = facade.player_world._tick
		if stamps.has("consume_tick") and coordinate() > origin + EPSILON:
			if not stamps.has("effect_tick"):
				stamps.effect_tick = facade.player_world._tick
			# After a publication the endpoint has only the sub-tick remainder.
			if facade.player_world._elapsed < delta:
				stamps.capture_tick = facade.player_world._tick
				phase_complete.emit(stamps)
	physics_finished.emit()


func _before_render() -> void:
	if stamps.has("sample_us") and not stamps.has("render_us") and is_instance_valid(avatar.actor):
		_pre_render_position = coordinate()


func _process(_delta: float) -> void:
	if (
		not stamps.has("sample_us")
		or stamps.has("render_us")
		or not is_instance_valid(avatar.actor)
	):
		return
	var predicted := avatar.prediction != null and avatar.prediction.active
	var rendered := coordinate()
	if predicted and avatar.actor.camera:
		# The settled trial starts with a zero visual offset.
		rendered += _render_axis(avatar.prediction.render_offset)
	var changed := predicted or (stamps.has("arrival_us") and rendered > _pre_render_position)
	if rendered > origin + EPSILON and changed:
		stamps.predicted = predicted
		stamps.render_delta = rendered - (origin if predicted else _pre_render_position)
		stamps.render_us = Time.get_ticks_usec()
		stamps.render_frame = Engine.get_process_frames()
		stamps.screen_ms = (int(stamps.render_us) - int(stamps.sample_us)) / 1000.0
		_complete()


func _render_axis(offset: Vector3) -> float:
	if action == "walk":
		return -offset.z
	return offset.y if action == "jump" else -offset.y


func _complete() -> void:
	if not _completed and stamps.has("arrival_us") and stamps.has("render_us"):
		_completed = true
		phase_complete.emit(stamps)

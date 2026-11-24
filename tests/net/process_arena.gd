extends Node3D
## The process harness observes actual Advanced bodies. Each drive file requests another lap.

const CHANNEL := preload("res://addons/cogito/Networking/net_command_channel.gd")
const DRIVE_TICKS := 140

var _driver := Driver.new()
var _loss: LossChannel
var _control: String
var _generation := 0
var _clock := 0
var _order := 0
var _presentations := 0


class LossChannel:
	extends CHANNEL

	var muted := true

	func packet(command: CogitoPlayerCommand) -> PackedByteArray:
		if muted:
			return PackedByteArray()
		var data := super.packet(command)
		if command.sequence % 10 == 9:
			if CogitoPlayerCommand.Action.JUMP in command.edges:
				print("NET DROPPED JUMP ", command.sequence)
			return PackedByteArray()
		return data


class Driver:
	extends CogitoPlayerInputSource

	var progress := DRIVE_TICKS
	var jumped := false
	var doorway_ticks := 0

	func sample(actor: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
		var command := super.sample(actor, sequence)
		if doorway_ticks > 0:
			doorway_ticks -= 1
			command.yaw = 0.0
			command.move = Vector2.UP
			return command
		if progress >= DRIVE_TICKS:
			return command
		command.move = Vector2.UP if progress < 105 else Vector2.ZERO
		command.yaw = 0.0 if progress < 60 else PI / 2.0
		if progress >= 30 and sequence % 10 == 9 and not jumped:
			command.add_edge(CogitoPlayerCommand.Action.JUMP)
			command.add_edge(CogitoPlayerCommand.Action.JUMP, false)
			jumped = true
		progress += 1
		return command


func _ready() -> void:
	if not CogitoNet.player_world:
		# The memory-peer suites bind their own branch facade.
		set_physics_process(false)
		return
	_control = OS.get_environment("COGITO_TEST_CONTROL")
	CogitoNet.player_world.bind_level(self, Transform3D(Basis.IDENTITY, Vector3.UP), "arena")
	CogitoNet.player_world.interactions.result_received.connect(_result)
	CogitoNet.player_world.world.presented.connect(_presented)
	if not CogitoNet.is_server():
		_loss = LossChannel.new()
		CogitoNet.player_world.command_channel = _loss


func _physics_process(_delta: float) -> void:
	_clock += 1
	if not CogitoNet.is_online():
		return
	var local_actor := CogitoNet.local_player() as CogitoPlayerAdvanced
	if local_actor and local_actor.input_source != _driver:
		local_actor.input_source = _driver
	if local_actor and FileAccess.file_exists(_control.path_join("drive-%d" % (_generation + 1))):
		if _loss:
			_loss.muted = false
		_generation += 1
		_driver.progress = 0
		_driver.jumped = false
	if _clock % 4 != 0:
		return
	var file := _control.path_join("order-%d" % (_order + 1))
	if FileAccess.file_exists(file):
		_order += 1
		_execute(JSON.parse_string(FileAccess.get_file_as_string(file)))
	var actors := {}
	for record in CogitoNet.players():
		var avatar := CogitoNet.player_world.avatar_for(record.player_id)
		if avatar:
			var pos := avatar.actor.position
			actors[record.display_name] = [pos.x, pos.y, pos.z]
	var count := 0
	for child in get_children():
		if child is CogitoPlayer:
			count += 1
	var data := {
		"tick": _clock,
		"actors": actors,
		"count": count,
		"drive": _generation,
		"progress": _driver.progress,
		"order": _order,
		"walk": _driver.doorway_ticks,
		"epoch": CogitoNet.player_world.world.entities.epoch,
		"open": $Door.is_open,
		"door_revision": CogitoNet.player_world.world.revisions.get("level:door", 0),
		"linked": $LinkedDoor.is_open,
		"locked": $Keypad.is_locked,
		"keydoor_locked": $KeyDoor.is_locked,
		"keydoor_open": $KeyDoor.is_open,
		"events": _presentations,
	}
	print("NET POS ", JSON.stringify(data))


func _result(result: Dictionary) -> void:
	print("NET RESULT ", JSON.stringify(result))


func _presented(_id: String, _revision: int, _event: StringName) -> void:
	_presentations += 1


func _execute(order: Dictionary) -> void:
	match order.op:
		"stage":
			for record in CogitoNet.players():
				var actor := CogitoNet.player_world.avatar_for(record.player_id).actor
				var first: bool = record.display_name == order.first
				actor.position = Vector3(5.3 if first else 6.8, 0.1, -12.6)
				actor.velocity = Vector3.ZERO
				CogitoNet.player_world.mark_teleport(record.player_id)
		"walk":
			if _loss:
				_loss.muted = false
			_driver.doorway_ticks = 40
		"use":
			var api := CogitoNet.player_world.interactions
			var component := get_node(String(order.component)) as InteractionComponent
			var request := api.make_request(component, order.get("action", "interact"))
			if order.has("code"):
				request.payload = order.code
			api.dispatch(request)
			if order.get("retry", false):
				api.dispatch(request)

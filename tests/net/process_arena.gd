extends Node3D
## The process harness observes actual Advanced bodies. Each drive file requests another lap.

const CHANNEL := preload("res://addons/cogito/Networking/net_command_channel.gd")
const DRIVE_TICKS := 140

var _driver := Driver.new()
var _loss: LossChannel
var _control: String
var _generation := 0
var _clock := 0


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

	func sample(actor: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
		var command := super.sample(actor, sequence)
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
	_control = OS.get_environment("COGITO_TEST_CONTROL")
	CogitoNet.player_world.bind_level(self, Transform3D(Basis.IDENTITY, Vector3.UP), "arena")
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
	}
	print("NET POS ", JSON.stringify(data))

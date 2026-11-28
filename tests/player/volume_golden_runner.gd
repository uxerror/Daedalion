extends "golden_runner.gd"
## Additional fixed-fps routes use the same row and precision recorder as PR1a.

const EXPECTED := {
	"ladder": "4e4cd85bf115bbfa4dda64f27900ba119a0a18d3e942e9233b018e007a1a1544",
	"swim": "19c55ff362ae2c5fb0490df066c4af26c55bac6aa273b35ac203c16abbba7bb8"
}


class VolumeInput:
	extends CogitoPlayerInputSource
	var lane: String

	func sample(player: CogitoPlayer, seq: int) -> CogitoPlayerCommand:
		var cmd := super.sample(player, seq)
		if lane == "ladder":
			cmd.move = Vector2.UP if seq < 75 else Vector2.DOWN
			cmd.pitch = -0.8 if seq >= 46 and seq < 75 else 0.0
			if seq == 80:
				cmd.held = 1 << CogitoPlayerCommand.Action.JUMP
		else:
			cmd.held = 1 << CogitoPlayerCommand.Action.JUMP
			if seq >= 32 and seq < 67:
				cmd.held = 1 << CogitoPlayerCommand.Action.CROUCH
			if seq >= 72 and seq < 216:
				cmd.move = Vector2.UP
		return cmd


func _spawn(level: Node3D, lane: String) -> void:
	super._spawn(level, lane)
	var driver := VolumeInput.new()
	driver.lane = lane
	actor.input_source = driver


func _run() -> void:
	CogitoAudio.child_entered_tree.connect(_one_shot)
	var success := true
	for lane: String in EXPECTED:
		var rows := await _record(lane)
		var digest := (rows + fingerprint).sha256_text()
		print("VOLUME GOLDEN ", lane, " ", digest)
		success = success and not rows.is_empty() and digest == EXPECTED[lane]
	get_tree().quit(0 if success else 1)

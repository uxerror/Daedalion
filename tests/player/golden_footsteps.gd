extends FootstepSurfaceDetector
## Count actual playback requests, including consecutive steps with the same stream.

var footsteps := 0
var landings := 0


func _play_footstep(profile: AudioStreamRandomizer, interaction_type: String) -> void:
	if interaction_type == "footstep":
		footsteps += 1
	elif interaction_type == "landing":
		landings += 1
	super._play_footstep(profile, interaction_type)

@tool
extends StateChart
## Skip deferred initial entry when the level is loaded as a network replica.


func _enter_initial_state() -> void:
	if multiplayer.is_server():
		super()

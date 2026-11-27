@tool
extends StateChart
## Skip deferred initial entry when the level is loaded as a network replica.


func _enter_initial_state() -> void:
	if (
		is_inside_tree()
		and not CogitoPersistentId.is_disappearing(self)
		and multiplayer.is_server()
	):
		super()

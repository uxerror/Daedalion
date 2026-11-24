extends Control
## The normal build also accepts --server. Its menu must never enter the dedicated tree.


func _enter_tree() -> void:
	if CogitoNet.dedicated_boot:
		var menu := get_node("MainMenu")
		remove_child(menu)
		menu.free()

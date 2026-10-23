extends Area3D

func _on_body_entered(body):
	if body is CogitoPlayer :
		body.increase_attribute("visibility", 1, ConsumableItemPD.ValueType.CURRENT)
		

func _on_body_exited(body):
	if body is CogitoPlayer :
		body.decrease_attribute("visibility", 1)

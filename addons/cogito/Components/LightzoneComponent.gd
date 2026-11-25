extends Area3D

func _on_body_entered(body):
	if body is CogitoPlayer :
		if body.network_movement_only and body.visibility_attribute is CogitoVisibilityAttribute:
			if body.multiplayer.is_server():
				body.visibility_attribute.sample_zone(self, true)
			return
		body.increase_attribute("visibility", 1, ConsumableItemPD.ValueType.CURRENT)
		

func _on_body_exited(body):
	if body is CogitoPlayer :
		if body.network_movement_only and body.visibility_attribute is CogitoVisibilityAttribute:
			if body.multiplayer.is_server():
				body.visibility_attribute.sample_zone(self, false)
			return
		body.decrease_attribute("visibility", 1)

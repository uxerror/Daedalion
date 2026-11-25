extends CogitoAttribute
class_name CogitoVisibilityAttribute

func _ready():
	value_current = value_start
	
func check_current_visibility():
	attribute_changed.emit(attribute_name,value_current,value_max,true)


## Sample the authored light zones around this server avatar, including overlapping zones.
func sample_zone(zone: Area3D, entered: bool) -> void:
	var zones: Dictionary = get_meta(&"light_zones", {})
	if entered:
		zones[zone.get_instance_id()] = true
	else:
		zones.erase(zone.get_instance_id())
	set_meta(&"light_zones", zones)
	value_current = value_start + zones.size()


## Zone exit can occur while the dead avatar's meter is frozen.
func reset_after_respawn() -> void:
	var zones: Dictionary = get_meta(&"light_zones", {})
	value_current = value_start + zones.size()
	check_current_visibility()

## Abstract form of a CogitoFlag
extends Resource
class_name CogitoFlag

@export var flag_name: String

func check(flags: Dictionary) -> bool:
	return true

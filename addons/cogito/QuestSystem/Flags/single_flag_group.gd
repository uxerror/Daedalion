@tool
## Single flag group for simple logic when updating quest objectives
extends CogitoFlagGroup
class_name SingleFlagGroup

@export var flag: CogitoFlag

func get_flag_names() -> Array[String]:
	return [flag.flag_name]

## Test the single flag against the existing flags on the quest
func meets_criteria(quest_flags: Dictionary) -> bool:
	return flag.check(quest_flags)

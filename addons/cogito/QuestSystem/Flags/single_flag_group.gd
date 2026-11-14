@tool
## Single flag group for simple logic when updating quest objectives
extends CogitoFlagGroup
class_name SingleFlagGroup

@export var flag: CogitoFlag

func get_flag_names() -> Array[String]:
	return [flag.flag_name] if flag is not InventoryFlag else [""]

func get_numeric_descriptions(world_flags: Dictionary) -> Array[String]:
	var description: String = ""
	if flag is NumericFlag:
		var flag_data = flag as NumericFlag
		var current_value = world_flags.get(flag_data.flag_name, 0)
		description = flag.specific_objective_text + " (%s / %s)" % [current_value, flag_data.expected]
	return [description]

## Test the single flag against the existing flags on the quest
func meets_criteria(world_flags: Dictionary) -> bool:
	return flag.check(world_flags)
